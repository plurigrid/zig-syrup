//! Stellogen Code Generator - WASM32 bytecode generation
//! Compiles Stellogen AST to WebAssembly binary format

const std = @import("std");
const ast = @import("ast.zig");
const Term = ast.Term;
const Star = ast.Star;
const Constellation = ast.Constellation;
const Expr = ast.Expr;
const Polarity = ast.Polarity;

// ============================================================================
// WASM Binary Format Constants
// ============================================================================

const WASM_MAGIC = [_]u8{ 0x00, 0x61, 0x73, 0x6D }; // \0asm
const WASM_VERSION = [_]u8{ 0x01, 0x00, 0x00, 0x00 }; // version 1

const SectionId = enum(u8) {
    custom = 0,
    type = 1,
    import = 2,
    function = 3,
    table = 4,
    memory = 5,
    global = 6,
    @"export" = 7,
    start = 8,
    element = 9,
    code = 10,
    data = 11,
};

const Opcode = enum(u8) {
    // Control
    @"unreachable" = 0x00,
    nop = 0x01,
    block = 0x02,
    loop = 0x03,
    if_ = 0x04,
    else_ = 0x05,
    end = 0x0B,
    br = 0x0C,
    br_if = 0x0D,
    br_table = 0x0E,
    return_ = 0x0F,
    call = 0x10,
    call_indirect = 0x11,

    // Parametric
    drop = 0x1A,
    select = 0x1B,

    // Variable
    local_get = 0x20,
    local_set = 0x21,
    local_tee = 0x22,
    global_get = 0x23,
    global_set = 0x24,

    // Memory
    i32_load = 0x28,
    i32_store = 0x36,

    // Constants
    i32_const = 0x41,
    i64_const = 0x42,
    f32_const = 0x43,
    f64_const = 0x44,

    // Comparison
    i32_eqz = 0x45,
    i32_eq = 0x46,
    i32_ne = 0x47,
    i32_lt_s = 0x48,
    i32_lt_u = 0x49,
    i32_gt_s = 0x4A,
    i32_gt_u = 0x4B,
    i32_le_s = 0x4C,
    i32_le_u = 0x4D,
    i32_ge_s = 0x4E,
    i32_ge_u = 0x4F,

    // Arithmetic
    i32_add = 0x6A,
    i32_sub = 0x6B,
    i32_mul = 0x6C,
    i32_div_s = 0x6D,
    i32_div_u = 0x6E,
    i32_rem_s = 0x6F,
    i32_rem_u = 0x70,
    i32_and = 0x71,
    i32_or = 0x72,
    i32_xor = 0x73,
    i32_shl = 0x74,
    i32_shr_s = 0x75,
    i32_shr_u = 0x76,
};

const ValueType = enum(u8) {
    i32 = 0x7F,
    i64 = 0x7E,
    f32 = 0x7D,
    f64 = 0x7C,
    funcref = 0x70,
    externref = 0x6F,
};

// ============================================================================
// WASM Bytecode Builder
// ============================================================================

pub const WasmBuilder = struct {
    allocator: std.mem.Allocator,
    output: std.ArrayListUnmanaged(u8),

    // Section buffers
    types: std.ArrayListUnmanaged(u8),
    imports: std.ArrayListUnmanaged(u8),
    functions: std.ArrayListUnmanaged(u8),
    tables: std.ArrayListUnmanaged(u8),
    memories: std.ArrayListUnmanaged(u8),
    globals: std.ArrayListUnmanaged(u8),
    exports: std.ArrayListUnmanaged(u8),
    code: std.ArrayListUnmanaged(u8),
    data: std.ArrayListUnmanaged(u8),

    // Counters
    type_count: u32 = 0,
    func_count: u32 = 0,
    import_func_count: u32 = 0,
    global_count: u32 = 0,
    export_count: u32 = 0,

    // Symbol table
    symbols: std.StringHashMap(SymbolInfo),

    const SymbolInfo = struct {
        kind: enum { func, global, local },
        index: u32,
        type_idx: u32 = 0,
    };

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .output = .{},
            .types = .{},
            .imports = .{},
            .functions = .{},
            .tables = .{},
            .memories = .{},
            .globals = .{},
            .exports = .{},
            .code = .{},
            .data = .{},
            .symbols = std.StringHashMap(SymbolInfo).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.output.deinit(self.allocator);
        self.types.deinit(self.allocator);
        self.imports.deinit(self.allocator);
        self.functions.deinit(self.allocator);
        self.tables.deinit(self.allocator);
        self.memories.deinit(self.allocator);
        self.globals.deinit(self.allocator);
        self.exports.deinit(self.allocator);
        self.code.deinit(self.allocator);
        self.data.deinit(self.allocator);
        self.symbols.deinit();
    }

    // LEB128 encoding for unsigned integers
    fn writeU32Leb128(allocator: std.mem.Allocator, list: *std.ArrayListUnmanaged(u8), value: u32) !void {
        var v = value;
        while (true) {
            const byte: u8 = @truncate(v & 0x7F);
            v >>= 7;
            if (v == 0) {
                try list.append(allocator, byte);
                break;
            } else {
                try list.append(allocator, byte | 0x80);
            }
        }
    }

    // LEB128 encoding for signed integers
    fn writeS32Leb128(allocator: std.mem.Allocator, list: *std.ArrayListUnmanaged(u8), value: i32) !void {
        var v = value;
        while (true) {
            const byte: u8 = @truncate(@as(u32, @bitCast(v)) & 0x7F);
            v >>= 7;
            const more = !(
                (v == 0 and (byte & 0x40) == 0) or
                (v == -1 and (byte & 0x40) != 0)
            );
            if (more) {
                try list.append(allocator, byte | 0x80);
            } else {
                try list.append(allocator, byte);
                break;
            }
        }
    }

    fn writeName(allocator: std.mem.Allocator, list: *std.ArrayListUnmanaged(u8), name: []const u8) !void {
        try writeU32Leb128(allocator, list, @intCast(name.len));
        try list.appendSlice(allocator, name);
    }

    fn writeSection(self: *Self, id: SectionId, content: []const u8) !void {
        try self.output.append(self.allocator, @intFromEnum(id));
        try writeU32Leb128(self.allocator, &self.output, @intCast(content.len));
        try self.output.appendSlice(self.allocator, content);
    }

    // ========================================================================
    // Type section
    // ========================================================================

    /// Add a function type (params -> results)
    pub fn addFuncType(self: *Self, params: []const ValueType, results: []const ValueType) !u32 {
        const idx = self.type_count;
        self.type_count += 1;

        // func type marker
        try self.types.append(self.allocator, 0x60);

        // params
        try writeU32Leb128(self.allocator, &self.types, @intCast(params.len));
        for (params) |p| {
            try self.types.append(self.allocator, @intFromEnum(p));
        }

        // results
        try writeU32Leb128(self.allocator, &self.types, @intCast(results.len));
        for (results) |r| {
            try self.types.append(self.allocator, @intFromEnum(r));
        }

        return idx;
    }

    // ========================================================================
    // Import section
    // ========================================================================

    /// Import a function
    pub fn addImportFunc(self: *Self, module: []const u8, name: []const u8, type_idx: u32) !u32 {
        const idx = self.import_func_count;
        self.import_func_count += 1;

        try writeName(self.allocator, &self.imports, module);
        try writeName(self.allocator, &self.imports, name);
        try self.imports.append(self.allocator, 0x00); // func import
        try writeU32Leb128(self.allocator, &self.imports, type_idx);

        try self.symbols.put(name, .{ .kind = .func, .index = idx, .type_idx = type_idx });

        return idx;
    }

    // ========================================================================
    // Memory section
    // ========================================================================

    /// Add memory (pages)
    pub fn addMemory(self: *Self, min_pages: u32, max_pages: ?u32) !void {
        if (max_pages) |max| {
            try self.memories.append(self.allocator, 0x01); // has max
            try writeU32Leb128(self.allocator, &self.memories, min_pages);
            try writeU32Leb128(self.allocator, &self.memories, max);
        } else {
            try self.memories.append(self.allocator, 0x00); // no max
            try writeU32Leb128(self.allocator, &self.memories, min_pages);
        }
    }

    // ========================================================================
    // Global section
    // ========================================================================

    /// Add a global variable
    pub fn addGlobal(self: *Self, name: []const u8, val_type: ValueType, mutable: bool, init_value: i32) !u32 {
        const idx = self.global_count;
        self.global_count += 1;

        try self.globals.append(self.allocator, @intFromEnum(val_type));
        try self.globals.append(self.allocator, if (mutable) 0x01 else 0x00);

        // Init expression
        try self.globals.append(self.allocator, @intFromEnum(Opcode.i32_const));
        try writeS32Leb128(self.allocator, &self.globals, init_value);
        try self.globals.append(self.allocator, @intFromEnum(Opcode.end));

        try self.symbols.put(name, .{ .kind = .global, .index = idx });

        return idx;
    }

    // ========================================================================
    // Export section
    // ========================================================================

    /// Export a function
    pub fn addExportFunc(self: *Self, name: []const u8, func_idx: u32) !void {
        self.export_count += 1;
        try writeName(self.allocator, &self.exports, name);
        try self.exports.append(self.allocator, 0x00); // func export
        try writeU32Leb128(self.allocator, &self.exports, func_idx);
    }

    /// Export memory
    pub fn addExportMemory(self: *Self, name: []const u8, mem_idx: u32) !void {
        self.export_count += 1;
        try writeName(self.allocator, &self.exports, name);
        try self.exports.append(self.allocator, 0x02); // memory export
        try writeU32Leb128(self.allocator, &self.exports, mem_idx);
    }

    // ========================================================================
    // Function section
    // ========================================================================

    /// Declare a function (type index)
    pub fn addFunction(self: *Self, name: []const u8, type_idx: u32) !u32 {
        const idx = self.import_func_count + self.func_count;
        self.func_count += 1;

        try writeU32Leb128(self.allocator, &self.functions, type_idx);
        try self.symbols.put(name, .{ .kind = .func, .index = idx, .type_idx = type_idx });

        return idx;
    }

    // ========================================================================
    // Code section
    // ========================================================================

    /// Begin a function body
    pub fn beginFuncBody(self: *Self, locals: []const struct { count: u32, type: ValueType }) !void {
        // We'll write directly to code buffer
        // The function body will be finished by endFuncBody

        // Local declarations
        try writeU32Leb128(self.allocator, &self.code, @intCast(locals.len));
        for (locals) |local| {
            try writeU32Leb128(self.allocator, &self.code, local.count);
            try self.code.append(self.allocator, @intFromEnum(local.type));
        }
    }

    /// Emit an opcode
    pub fn emit(self: *Self, op: Opcode) !void {
        try self.code.append(self.allocator, @intFromEnum(op));
    }

    /// Emit opcode with i32 immediate
    pub fn emitI32(self: *Self, op: Opcode, val: i32) !void {
        try self.code.append(self.allocator, @intFromEnum(op));
        try writeS32Leb128(self.allocator, &self.code, val);
    }

    /// Emit opcode with u32 immediate
    pub fn emitU32(self: *Self, op: Opcode, val: u32) !void {
        try self.code.append(self.allocator, @intFromEnum(op));
        try writeU32Leb128(self.allocator, &self.code, val);
    }

    /// End a function body
    pub fn endFuncBody(self: *Self) !void {
        try self.emit(.end);
    }

    // ========================================================================
    // Data section
    // ========================================================================

    /// Add passive data segment
    pub fn addData(self: *Self, bytes: []const u8) !u32 {
        const offset: u32 = @intCast(self.data.items.len);

        // Memory index 0, offset expression
        try self.data.append(self.allocator, 0x00);
        try self.data.append(self.allocator, @intFromEnum(Opcode.i32_const));
        try writeS32Leb128(self.allocator, &self.data, @intCast(offset));
        try self.data.append(self.allocator, @intFromEnum(Opcode.end));

        // Data bytes
        try writeU32Leb128(self.allocator, &self.data, @intCast(bytes.len));
        try self.data.appendSlice(self.allocator, bytes);

        return offset;
    }

    // ========================================================================
    // Finalize
    // ========================================================================

    /// Generate the final WASM binary
    pub fn finalize(self: *Self) ![]const u8 {
        // Clear output
        self.output.clearRetainingCapacity();

        // Magic and version
        try self.output.appendSlice(self.allocator, &WASM_MAGIC);
        try self.output.appendSlice(self.allocator, &WASM_VERSION);

        // Type section
        if (self.type_count > 0) {
            var type_section = std.ArrayListUnmanaged(u8){};
            defer type_section.deinit(self.allocator);
            try writeU32Leb128(self.allocator, &type_section, self.type_count);
            try type_section.appendSlice(self.allocator, self.types.items);
            try self.writeSection(.type, type_section.items);
        }

        // Import section
        if (self.import_func_count > 0) {
            var import_section = std.ArrayListUnmanaged(u8){};
            defer import_section.deinit(self.allocator);
            try writeU32Leb128(self.allocator, &import_section, self.import_func_count);
            try import_section.appendSlice(self.allocator, self.imports.items);
            try self.writeSection(.import, import_section.items);
        }

        // Function section
        if (self.func_count > 0) {
            var func_section = std.ArrayListUnmanaged(u8){};
            defer func_section.deinit(self.allocator);
            try writeU32Leb128(self.allocator, &func_section, self.func_count);
            try func_section.appendSlice(self.allocator, self.functions.items);
            try self.writeSection(.function, func_section.items);
        }

        // Memory section
        if (self.memories.items.len > 0) {
            var mem_section = std.ArrayListUnmanaged(u8){};
            defer mem_section.deinit(self.allocator);
            try writeU32Leb128(self.allocator, &mem_section, 1); // one memory
            try mem_section.appendSlice(self.allocator, self.memories.items);
            try self.writeSection(.memory, mem_section.items);
        }

        // Global section
        if (self.global_count > 0) {
            var global_section = std.ArrayListUnmanaged(u8){};
            defer global_section.deinit(self.allocator);
            try writeU32Leb128(self.allocator, &global_section, self.global_count);
            try global_section.appendSlice(self.allocator, self.globals.items);
            try self.writeSection(.global, global_section.items);
        }

        // Export section
        if (self.export_count > 0) {
            var export_section = std.ArrayListUnmanaged(u8){};
            defer export_section.deinit(self.allocator);
            try writeU32Leb128(self.allocator, &export_section, self.export_count);
            try export_section.appendSlice(self.allocator, self.exports.items);
            try self.writeSection(.@"export", export_section.items);
        }

        // Code section
        if (self.func_count > 0) {
            // For now, wrap each function body
            var code_section = std.ArrayListUnmanaged(u8){};
            defer code_section.deinit(self.allocator);
            try writeU32Leb128(self.allocator, &code_section, self.func_count);

            // Single function body (size + content)
            try writeU32Leb128(self.allocator, &code_section, @intCast(self.code.items.len));
            try code_section.appendSlice(self.allocator, self.code.items);

            try self.writeSection(.code, code_section.items);
        }

        // Data section
        if (self.data.items.len > 0) {
            var data_section = std.ArrayListUnmanaged(u8){};
            defer data_section.deinit(self.allocator);
            try writeU32Leb128(self.allocator, &data_section, 1); // one data segment
            try data_section.appendSlice(self.allocator, self.data.items);
            try self.writeSection(.data, data_section.items);
        }

        return self.output.items;
    }
};

// ============================================================================
// Stellogen to WASM Compiler
// ============================================================================

pub const Compiler = struct {
    allocator: std.mem.Allocator,
    wasm: WasmBuilder,

    // Runtime type indices
    unify_type: u32 = 0,
    fuse_type: u32 = 0,
    exec_type: u32 = 0,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) !Self {
        var self = Self{
            .allocator = allocator,
            .wasm = WasmBuilder.init(allocator),
        };

        // Set up runtime types
        try self.setupRuntime();

        return self;
    }

    pub fn deinit(self: *Self) void {
        self.wasm.deinit();
    }

    fn setupRuntime(self: *Self) !void {
        // Memory for term heap
        try self.wasm.addMemory(16, 256); // 1MB to 16MB

        // Heap pointer global
        _ = try self.wasm.addGlobal("$heap_ptr", .i32, true, 0);

        // Function types for runtime
        // unify: (term_a: i32, term_b: i32) -> i32 (substitution ptr or 0)
        self.unify_type = try self.wasm.addFuncType(&.{ .i32, .i32 }, &.{.i32});

        // fuse: (state: i32, action: i32) -> i32 (merged star ptr or 0)
        self.fuse_type = try self.wasm.addFuncType(&.{ .i32, .i32 }, &.{.i32});

        // exec: (constellation: i32, linear: i32) -> i32 (result constellation)
        self.exec_type = try self.wasm.addFuncType(&.{ .i32, .i32 }, &.{.i32});
    }

    /// Compile a term to WASM (returns heap offset)
    fn compileTerm(self: *Self, term: Term) !void {
        switch (term) {
            .variable => |v| {
                // Allocate variable node: [tag=0, name_len, name_bytes...]
                try self.wasm.emitI32(.i32_const, 0); // tag for variable
                try self.wasm.emit(.i32_store);

                // Store name length
                try self.wasm.emitI32(.i32_const, @intCast(v.name.len));
                try self.wasm.emit(.i32_store);

                // Store name bytes (simplified - would need memory copy)
            },
            .function => |f| {
                // Allocate function node: [tag=1, polarity, name_len, name_bytes, arg_count, args...]
                try self.wasm.emitI32(.i32_const, 1); // tag for function
                try self.wasm.emit(.i32_store);

                try self.wasm.emitI32(.i32_const, @intFromEnum(f.id.polarity));
                try self.wasm.emit(.i32_store);

                try self.wasm.emitI32(.i32_const, @intCast(f.id.name.len));
                try self.wasm.emit(.i32_store);

                try self.wasm.emitI32(.i32_const, @intCast(f.args.len));
                try self.wasm.emit(.i32_store);

                // Compile arguments recursively
                for (f.args) |arg| {
                    try self.compileTerm(arg);
                }
            },
        }
    }

    /// Compile an expression
    pub fn compileExpr(self: *Self, expr: Expr) !void {
        switch (expr) {
            .raw => |term| {
                try self.compileTerm(term);
            },
            .constellation => |c| {
                // Compile constellation
                for (c.stars) |star| {
                    for (star.content) |ray| {
                        try self.compileTerm(ray);
                    }
                }
            },
            .exec => |e| {
                try self.compileExpr(e.constellation.*);
                try self.wasm.emitI32(.i32_const, if (e.linear) 1 else 0);
                // Call exec runtime
            },
            .def => |d| {
                try self.compileExpr(d.value.*);
                // Store in global (name tracked in symbol table)
            },
            .call => |name| {
                // Look up definition
                _ = name;
            },
            .focus => |e| {
                try self.compileExpr(e.*);
                // Mark as state
            },
            else => {},
        }
    }

    /// Compile a program
    pub fn compileProgram(self: *Self, program: []const Expr) ![]const u8 {
        // Add main function
        const main_type = try self.wasm.addFuncType(&.{}, &.{.i32});
        const main_idx = try self.wasm.addFunction("main", main_type);
        try self.wasm.addExportFunc("main", main_idx);
        try self.wasm.addExportMemory("memory", 0);

        // Begin function body
        try self.wasm.beginFuncBody(&.{
            .{ .count = 4, .type = .i32 }, // 4 local i32s
        });

        // Compile each expression
        for (program) |expr| {
            try self.compileExpr(expr);
        }

        // Return 0 (success)
        try self.wasm.emitI32(.i32_const, 0);
        try self.wasm.endFuncBody();

        return self.wasm.finalize();
    }
};

// ============================================================================
// Tests
// ============================================================================

test "wasm builder generates valid header" {
    const allocator = std.testing.allocator;

    var builder = WasmBuilder.init(allocator);
    defer builder.deinit();

    // Add a simple function
    const type_idx = try builder.addFuncType(&.{}, &.{.i32});
    const func_idx = try builder.addFunction("test", type_idx);
    try builder.addExportFunc("test", func_idx);

    try builder.beginFuncBody(&.{});
    try builder.emitI32(.i32_const, 42);
    try builder.endFuncBody();

    const wasm = try builder.finalize();

    // Check magic number
    try std.testing.expectEqualSlices(u8, &WASM_MAGIC, wasm[0..4]);
    try std.testing.expectEqualSlices(u8, &WASM_VERSION, wasm[4..8]);
}

test "compiler initialization" {
    const allocator = std.testing.allocator;

    var compiler = try Compiler.init(allocator);
    defer compiler.deinit();

    // Should have set up runtime
    try std.testing.expect(compiler.unify_type != compiler.fuse_type);
}
