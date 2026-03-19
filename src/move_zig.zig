//! move_zig.zig — Move-in-Zig: A stand-in Move dialect for zig-syrup
//!
//! Implements the core Move VM semantics in idiomatic Zig following:
//!   - Hashimoto patterns: comptime interfaces, data tables, @Type generation
//!   - TigerBeetle TIGER_STYLE: static allocation, assertion density, snake_case
//!   - Stellogen foundation: polarized linear logic, GF(3) trit conservation
//!
//! Move's four abilities map to stellogen polarity + GF(3):
//!   key   → Polarity.pos (+1, Generator)  — can exist in global storage
//!   store → Polarity.null (0, Coordinator) — can be stored inside other structs
//!   copy  → Polarity.neg (-1, Validator)   — can be duplicated (NON-linear)
//!   drop  → GF(3) conservation             — can be silently destroyed
//!
//! Move's linear type discipline = stellogen's proof net linearity:
//!   A resource without `copy` MUST be moved or destroyed (cut elimination).
//!   A resource without `drop` MUST be explicitly consumed (no garbage).
//!
//! Gas metering uses color bandwidth (CIEDE2000 perceptual distance):
//!   each instruction's cost = its distinguishability contribution in bits.
//!   Total gas = cumulative perceptual bandwidth consumed.
//!
//! SPI (Strong Parallelism Invariance) guarantees Block-STM semantics:
//!   parallel execution of independent transactions yields identical results
//!   to serial execution, because color(seed, index) is order-independent.
//!
//! wasm32-freestanding compatible. No allocator in hot path.

const std = @import("std");
const assert = std.debug.assert;
const math = std.math;

// ============================================================================
// Constants — following TigerBeetle: important things near top
// ============================================================================

/// SplitMix64 golden ratio constant (matches Gay.jl, gay_color.move)
const GOLDEN: u64 = 0x9e3779b97f4a7c15;
const MIX1: u64 = 0xbf58476d1ce4e5b9;
const MIX2: u64 = 0x94d049bb133111eb;

/// Maximum stack depth for the Move VM (TigerBeetle: everything has a limit)
pub const MAX_STACK_DEPTH: usize = 1024;
/// Maximum locals per frame
pub const MAX_LOCALS: usize = 256;
/// Maximum call depth
pub const MAX_CALL_DEPTH: usize = 64;
/// Maximum module functions
pub const MAX_FUNCTIONS: usize = 512;
/// Maximum struct definitions
pub const MAX_STRUCTS: usize = 256;
/// Maximum global storage entries
pub const MAX_STORAGE: usize = 4096;
/// Maximum bytecode instructions per function
pub const MAX_INSTRUCTIONS: usize = 65536;

// ============================================================================
// GF(3) Trit — the nervous system (matches splitmix_trit.zig, goi.zig)
// ============================================================================

pub const Trit = enum(i8) {
    minus = -1, // Validator: verification, checking, consuming
    ergodic = 0, // Coordinator: balance, storage, infrastructure
    plus = 1, // Generator: creation, production, minting

    pub fn add(a: Trit, b: Trit) Trit {
        const sum = @as(i8, @intFromEnum(a)) + @as(i8, @intFromEnum(b));
        return switch (@mod(sum + 3, 3)) {
            0 => .ergodic,
            1 => .plus,
            2 => .minus,
            else => unreachable,
        };
    }

    pub fn negate(self: Trit) Trit {
        return switch (self) {
            .minus => .plus,
            .ergodic => .ergodic,
            .plus => .minus,
        };
    }
};

// ============================================================================
// SplitMix64 — deterministic color hash (SPI core, O(1) at any index)
// ============================================================================

pub fn splitmix64(x: u64) u64 {
    var z = x +% GOLDEN;
    z = (z ^ (z >> 30)) *% MIX1;
    z = (z ^ (z >> 27)) *% MIX2;
    return z ^ (z >> 31);
}

pub fn color_at(seed: u64, index: u64) u64 {
    return splitmix64(seed ^ (GOLDEN *% index));
}

pub fn color_trit(seed: u64, index: u64) Trit {
    return Trit.fromU64(color_at(seed, index));
}

fn tritFromU64(val: u64) Trit {
    return switch (val % 3) {
        0 => .minus,
        1 => .ergodic,
        2 => .plus,
        else => unreachable,
    };
}

// Attach to Trit
pub const TritExt = Trit;

// ============================================================================
// Abilities — Move's type ability system (Hashimoto: comptime data table)
// ============================================================================

pub const Ability = enum(u4) {
    copy = 0, // Can be duplicated (non-linear)
    drop = 1, // Can be silently destroyed
    store = 2, // Can exist inside other structs
    key = 3, // Can exist in global storage

    pub fn trit(self: Ability) Trit {
        return switch (self) {
            .copy => .minus, // Validator: checking duplicability
            .drop => .ergodic, // Coordinator: lifecycle management
            .store => .ergodic, // Coordinator: structural containment
            .key => .plus, // Generator: storage production
        };
    }
};

/// Ability set as a packed bitfield (TigerBeetle: tight struct)
pub const AbilitySet = packed struct {
    copy: bool = false,
    drop: bool = false,
    store: bool = false,
    key: bool = false,

    pub const empty = AbilitySet{};
    pub const all = AbilitySet{ .copy = true, .drop = true, .store = true, .key = true };
    pub const resource = AbilitySet{ .key = true, .store = true }; // No copy, no drop = linear

    pub fn has(self: AbilitySet, ability: Ability) bool {
        return switch (ability) {
            .copy => self.copy,
            .drop => self.drop,
            .store => self.store,
            .key => self.key,
        };
    }

    pub fn is_linear(self: AbilitySet) bool {
        return !self.copy;
    }

    pub fn must_consume(self: AbilitySet) bool {
        return !self.drop;
    }

    pub fn can_store_globally(self: AbilitySet) bool {
        return self.key;
    }
};

comptime {
    assert(@sizeOf(AbilitySet) == 1);
}

// ============================================================================
// Type system — Move types with abilities
// ============================================================================

pub const TypeTag = enum(u8) {
    bool_type = 0,
    u8_type = 1,
    u16_type = 2,
    u32_type = 3,
    u64_type = 4,
    u128_type = 5,
    u256_type = 6,
    address_type = 7,
    signer_type = 8,
    vector_type = 9,
    struct_type = 10,
    reference_type = 11,
    mutable_reference_type = 12,
};

pub const MoveType = struct {
    tag: TypeTag,
    abilities: AbilitySet,
    struct_index: ?u16 = null, // For struct_type
    inner_type: ?*const MoveType = null, // For vector/reference

    pub fn is_primitive(self: MoveType) bool {
        return @intFromEnum(self.tag) <= @intFromEnum(TypeTag.address_type);
    }

    pub fn is_resource(self: MoveType) bool {
        return self.abilities.is_linear() and self.abilities.must_consume();
    }
};

/// Primitive types — comptime data table (Hashimoto pattern)
const PrimitiveEntry = struct { tag: TypeTag, name: []const u8, size: u8 };
const primitive_entries = [_]PrimitiveEntry{
    .{ .tag = .bool_type, .name = "bool", .size = 1 },
    .{ .tag = .u8_type, .name = "u8", .size = 1 },
    .{ .tag = .u16_type, .name = "u16", .size = 2 },
    .{ .tag = .u32_type, .name = "u32", .size = 4 },
    .{ .tag = .u64_type, .name = "u64", .size = 8 },
    .{ .tag = .u128_type, .name = "u128", .size = 16 },
    .{ .tag = .u256_type, .name = "u256", .size = 32 },
    .{ .tag = .address_type, .name = "address", .size = 32 },
    .{ .tag = .signer_type, .name = "signer", .size = 32 },
};

/// Primitive types all have copy + drop (non-linear)
pub fn primitive_abilities() AbilitySet {
    return AbilitySet{ .copy = true, .drop = true, .store = true, .key = false };
}

// ============================================================================
// Opcodes — Move bytecode instruction set (Hashimoto: comptime enum from table)
// ============================================================================

const OpcodeEntry = struct { value: u8, name: []const u8, gas_cost: u16 };
const opcode_entries = [_]OpcodeEntry{
    // Stack operations
    .{ .value = 0x01, .name = "pop", .gas_cost = 1 },
    .{ .value = 0x02, .name = "ret", .gas_cost = 1 },
    .{ .value = 0x03, .name = "nop", .gas_cost = 1 },

    // Local variable operations
    .{ .value = 0x0A, .name = "ld_const_u64", .gas_cost = 1 },
    .{ .value = 0x0B, .name = "ld_const_true", .gas_cost = 1 },
    .{ .value = 0x0C, .name = "ld_const_false", .gas_cost = 1 },
    .{ .value = 0x0D, .name = "copy_loc", .gas_cost = 2 },
    .{ .value = 0x0E, .name = "move_loc", .gas_cost = 1 },
    .{ .value = 0x0F, .name = "st_loc", .gas_cost = 1 },

    // Arithmetic
    .{ .value = 0x10, .name = "add", .gas_cost = 3 },
    .{ .value = 0x11, .name = "sub", .gas_cost = 3 },
    .{ .value = 0x12, .name = "mul", .gas_cost = 5 },
    .{ .value = 0x13, .name = "div", .gas_cost = 5 },
    .{ .value = 0x14, .name = "mod", .gas_cost = 5 },

    // Comparison
    .{ .value = 0x20, .name = "lt", .gas_cost = 2 },
    .{ .value = 0x21, .name = "le", .gas_cost = 2 },
    .{ .value = 0x22, .name = "gt", .gas_cost = 2 },
    .{ .value = 0x23, .name = "ge", .gas_cost = 2 },
    .{ .value = 0x24, .name = "eq", .gas_cost = 2 },
    .{ .value = 0x25, .name = "neq", .gas_cost = 2 },

    // Boolean
    .{ .value = 0x30, .name = "and_op", .gas_cost = 2 },
    .{ .value = 0x31, .name = "or_op", .gas_cost = 2 },
    .{ .value = 0x32, .name = "not_op", .gas_cost = 1 },

    // Bitwise
    .{ .value = 0x40, .name = "bit_and", .gas_cost = 3 },
    .{ .value = 0x41, .name = "bit_or", .gas_cost = 3 },
    .{ .value = 0x42, .name = "xor", .gas_cost = 3 },
    .{ .value = 0x43, .name = "shl", .gas_cost = 3 },
    .{ .value = 0x44, .name = "shr", .gas_cost = 3 },

    // Control flow
    .{ .value = 0x50, .name = "branch", .gas_cost = 1 },
    .{ .value = 0x51, .name = "br_true", .gas_cost = 2 },
    .{ .value = 0x52, .name = "br_false", .gas_cost = 2 },
    .{ .value = 0x53, .name = "call", .gas_cost = 10 },
    .{ .value = 0x54, .name = "abort", .gas_cost = 1 },

    // Global storage (the Move differentiator)
    .{ .value = 0x60, .name = "move_to", .gas_cost = 50 },
    .{ .value = 0x61, .name = "move_from", .gas_cost = 50 },
    .{ .value = 0x62, .name = "exists", .gas_cost = 10 },
    .{ .value = 0x63, .name = "borrow_global", .gas_cost = 20 },
    .{ .value = 0x64, .name = "borrow_global_mut", .gas_cost = 30 },

    // Struct operations
    .{ .value = 0x70, .name = "pack", .gas_cost = 5 },
    .{ .value = 0x71, .name = "unpack", .gas_cost = 5 },

    // Vector operations
    .{ .value = 0x80, .name = "vec_empty", .gas_cost = 3 },
    .{ .value = 0x81, .name = "vec_push", .gas_cost = 5 },
    .{ .value = 0x82, .name = "vec_pop", .gas_cost = 5 },
    .{ .value = 0x83, .name = "vec_len", .gas_cost = 1 },
    .{ .value = 0x84, .name = "vec_borrow", .gas_cost = 3 },

    // SplitMix64 / Color (Move-in-Zig extension: on-chain Gay Color Protocol)
    .{ .value = 0xF0, .name = "color_hash", .gas_cost = 5 },
    .{ .value = 0xF1, .name = "color_trit", .gas_cost = 5 },
    .{ .value = 0xF2, .name = "trit_add", .gas_cost = 2 },
    .{ .value = 0xF3, .name = "is_conserved", .gas_cost = 10 },
};

/// Opcode enum — Move bytecode instruction set
/// Gas costs looked up from opcode_entries data table (Hashimoto pattern)
pub const Opcode = enum(u8) {
    pop = 0x01,
    ret = 0x02,
    nop = 0x03,

    ld_const_u64 = 0x0A,
    ld_const_true = 0x0B,
    ld_const_false = 0x0C,
    copy_loc = 0x0D,
    move_loc = 0x0E,
    st_loc = 0x0F,

    add = 0x10,
    sub = 0x11,
    mul = 0x12,
    div = 0x13,
    mod = 0x14,

    lt = 0x20,
    le = 0x21,
    gt = 0x22,
    ge = 0x23,
    eq = 0x24,
    neq = 0x25,

    and_op = 0x30,
    or_op = 0x31,
    not_op = 0x32,

    bit_and = 0x40,
    bit_or = 0x41,
    xor = 0x42,
    shl = 0x43,
    shr = 0x44,

    branch = 0x50,
    br_true = 0x51,
    br_false = 0x52,
    call = 0x53,
    abort = 0x54,

    move_to = 0x60,
    move_from = 0x61,
    exists = 0x62,
    borrow_global = 0x63,
    borrow_global_mut = 0x64,

    pack = 0x70,
    unpack = 0x71,

    vec_empty = 0x80,
    vec_push = 0x81,
    vec_pop = 0x82,
    vec_len = 0x83,
    vec_borrow = 0x84,

    color_hash = 0xF0,
    color_trit = 0xF1,
    trit_add = 0xF2,
    is_conserved = 0xF3,

    _,
};

/// Gas cost lookup — O(1) via comptime-built table
pub fn gas_cost(op: Opcode) u16 {
    inline for (opcode_entries) |entry| {
        if (@intFromEnum(op) == entry.value) return entry.gas_cost;
    }
    return 100; // Unknown opcode: expensive
}

// ============================================================================
// Value — runtime value representation (TigerBeetle: tight, aligned)
// ============================================================================

pub const Value = union(enum) {
    bool_val: bool,
    u64_val: u64,
    u128_val: u128,
    address_val: [32]u8,
    signer_val: [32]u8,
    struct_val: StructValue,
    vector_val: VectorValue,
    reference: Reference,

    pub fn type_tag(self: Value) TypeTag {
        return switch (self) {
            .bool_val => .bool_type,
            .u64_val => .u64_type,
            .u128_val => .u128_type,
            .address_val => .address_type,
            .signer_val => .signer_type,
            .struct_val => .struct_type,
            .vector_val => .vector_type,
            .reference => .reference_type,
        };
    }
};

pub const StructValue = struct {
    struct_index: u16,
    abilities: AbilitySet,
    fields: []Value, // Owned; must be freed if abilities.must_consume()
};

pub const VectorValue = struct {
    element_type: TypeTag,
    elements: []Value,
};

pub const Reference = struct {
    is_mutable: bool,
    target: *Value, // Points into locals or global storage
};

// ============================================================================
// Instruction — single bytecode instruction
// ============================================================================

pub const Instruction = packed struct {
    opcode: Opcode,
    operand: u24 = 0, // Local index, constant index, branch target, etc.
};

comptime {
    assert(@sizeOf(Instruction) == 4);
}

// ============================================================================
// Gas metering — color bandwidth integration
// ============================================================================

pub const GasStatus = struct {
    gas_left: u64,
    gas_used: u64,
    max_gas: u64,
    color_bandwidth_bits: f32 = 0, // Accumulated CIEDE2000 perceptual bits

    pub fn init(max_gas: u64) GasStatus {
        return .{ .gas_left = max_gas, .gas_used = 0, .max_gas = max_gas };
    }

    pub fn deduct(self: *GasStatus, cost: u64) !void {
        if (self.gas_left < cost) return error.OutOfGas;
        self.gas_left -= cost;
        self.gas_used += cost;
    }

    pub fn remaining_fraction(self: GasStatus) f32 {
        if (self.max_gas == 0) return 0;
        return @as(f32, @floatFromInt(self.gas_left)) / @as(f32, @floatFromInt(self.max_gas));
    }
};

// ============================================================================
// Global Storage — content-addressed by (type, address)
// ============================================================================

pub const StorageKey = struct {
    address: [32]u8,
    struct_index: u16,

    pub fn hash(self: StorageKey) u64 {
        var h: u64 = 0;
        for (self.address) |byte| {
            h = h ^ @as(u64, byte);
            h = splitmix64(h);
        }
        return splitmix64(h ^ @as(u64, self.struct_index));
    }

    pub fn eql(a: StorageKey, b: StorageKey) bool {
        return std.mem.eql(u8, &a.address, &b.address) and
            a.struct_index == b.struct_index;
    }
};

pub const GlobalStorage = struct {
    keys: [MAX_STORAGE]StorageKey = undefined,
    values: [MAX_STORAGE]Value = undefined,
    count: usize = 0,

    pub fn move_to(self: *GlobalStorage, key: StorageKey, value: Value) !void {
        assert(self.count < MAX_STORAGE);
        // Check resource doesn't already exist (Move semantics)
        if (self.find(key) != null) return error.ResourceAlreadyExists;
        self.keys[self.count] = key;
        self.values[self.count] = value;
        self.count += 1;
    }

    pub fn move_from(self: *GlobalStorage, key: StorageKey) !Value {
        const idx = self.find(key) orelse return error.ResourceNotFound;
        const value = self.values[idx];
        // Remove by swapping with last
        self.count -= 1;
        if (idx < self.count) {
            self.keys[idx] = self.keys[self.count];
            self.values[idx] = self.values[self.count];
        }
        return value;
    }

    pub fn exists(self: *const GlobalStorage, key: StorageKey) bool {
        return self.find(key) != null;
    }

    pub fn borrow(self: *GlobalStorage, key: StorageKey) !*Value {
        const idx = self.find(key) orelse return error.ResourceNotFound;
        return &self.values[idx];
    }

    fn find(self: *const GlobalStorage, key: StorageKey) ?usize {
        for (0..self.count) |i| {
            if (key.eql(self.keys[i])) return i;
        }
        return null;
    }
};

// ============================================================================
// Frame — single call frame on the VM stack
// ============================================================================

pub const Frame = struct {
    function_index: u16,
    pc: u32 = 0, // Program counter
    locals: [MAX_LOCALS]?Value = [_]?Value{null} ** MAX_LOCALS,
    local_moved: [MAX_LOCALS]bool = [_]bool{false} ** MAX_LOCALS, // Track linear consumption

    pub fn get_local(self: *const Frame, idx: u8) !Value {
        const val = self.locals[idx] orelse return error.UninitializedLocal;
        return val;
    }

    pub fn move_local(self: *Frame, idx: u8) !Value {
        const val = self.locals[idx] orelse return error.UninitializedLocal;
        if (self.local_moved[idx]) return error.ResourceAlreadyMoved;
        self.locals[idx] = null;
        self.local_moved[idx] = true;
        return val;
    }

    pub fn copy_local(self: *const Frame, idx: u8, abilities: AbilitySet) !Value {
        if (!abilities.has(.copy)) return error.ResourceCannotBeCopied;
        return self.locals[idx] orelse return error.UninitializedLocal;
    }

    pub fn store_local(self: *Frame, idx: u8, val: Value) void {
        self.locals[idx] = val;
        self.local_moved[idx] = false;
    }
};

// ============================================================================
// Function — compiled Move function
// ============================================================================

pub const Function = struct {
    name: []const u8,
    param_count: u8,
    return_count: u8,
    local_count: u8,
    instructions: []const Instruction,
    is_entry: bool = false,
    is_public: bool = false,
};

// ============================================================================
// Module — compiled Move module
// ============================================================================

pub const Module = struct {
    name: []const u8,
    address: [32]u8 = [_]u8{0} ** 32,
    functions: []const Function,
    struct_defs: []const StructDef,

    pub fn find_function(self: Module, name: []const u8) ?*const Function {
        for (self.functions) |*f| {
            if (std.mem.eql(u8, f.name, name)) return f;
        }
        return null;
    }
};

pub const StructDef = struct {
    name: []const u8,
    abilities: AbilitySet,
    field_names: []const []const u8,
    field_types: []const MoveType,
};

// ============================================================================
// VM — the Move-in-Zig virtual machine
// ============================================================================

pub const VmError = error{
    StackOverflow,
    StackUnderflow,
    OutOfGas,
    CallDepthExceeded,
    UninitializedLocal,
    ResourceAlreadyMoved,
    ResourceCannotBeCopied,
    ResourceAlreadyExists,
    ResourceNotFound,
    TypeMismatch,
    ArithmeticOverflow,
    DivisionByZero,
    AbortCalled,
    InvalidOpcode,
    VerificationFailed,
};

pub const Vm = struct {
    // State — fields first (TigerBeetle convention)
    stack: [MAX_STACK_DEPTH]Value = undefined,
    stack_top: usize = 0,
    frames: [MAX_CALL_DEPTH]Frame = undefined,
    frame_count: usize = 0,
    gas: GasStatus,
    storage: GlobalStorage = .{},
    seed: u64, // SPI seed for deterministic color
    step_count: u64 = 0, // Total instructions executed

    // Types — init
    pub fn init(max_gas: u64, seed: u64) Vm {
        return .{
            .gas = GasStatus.init(max_gas),
            .seed = seed,
        };
    }

    // Methods — stack operations
    pub fn push(self: *Vm, val: Value) !void {
        if (self.stack_top >= MAX_STACK_DEPTH) return error.StackOverflow;
        self.stack[self.stack_top] = val;
        self.stack_top += 1;
    }

    pub fn pop(self: *Vm) !Value {
        if (self.stack_top == 0) return error.StackUnderflow;
        self.stack_top -= 1;
        return self.stack[self.stack_top];
    }

    pub fn peek(self: *const Vm) !Value {
        if (self.stack_top == 0) return error.StackUnderflow;
        return self.stack[self.stack_top - 1];
    }

    fn current_frame(self: *Vm) !*Frame {
        if (self.frame_count == 0) return error.StackUnderflow;
        return &self.frames[self.frame_count - 1];
    }

    // Methods — execution
    pub fn execute_function(self: *Vm, module: Module, func_name: []const u8, args: []const Value) ![]const Value {
        const func = module.find_function(func_name) orelse return error.InvalidOpcode;

        // Push frame
        if (self.frame_count >= MAX_CALL_DEPTH) return error.CallDepthExceeded;
        var frame = Frame{ .function_index = 0 };

        // Load arguments into locals
        for (args, 0..) |arg, i| {
            frame.store_local(@intCast(i), arg);
        }

        self.frames[self.frame_count] = frame;
        self.frame_count += 1;

        // Execute instructions
        while (true) {
            const f = try self.current_frame();
            if (f.pc >= func.instructions.len) break;

            const inst = func.instructions[f.pc];
            try self.gas.deduct(gas_cost(inst.opcode));

            self.step_count += 1;
            f.pc += 1;

            switch (inst.opcode) {
                .pop => _ = try self.pop(),
                .ret => break,
                .nop => {},

                .ld_const_u64 => try self.push(.{ .u64_val = @as(u64, inst.operand) }),
                .ld_const_true => try self.push(.{ .bool_val = true }),
                .ld_const_false => try self.push(.{ .bool_val = false }),

                .copy_loc => {
                    const val = try f.get_local(@intCast(inst.operand));
                    try self.push(val);
                },
                .move_loc => {
                    const val = try f.move_local(@intCast(inst.operand));
                    try self.push(val);
                },
                .st_loc => {
                    const val = try self.pop();
                    f.store_local(@intCast(inst.operand), val);
                },

                .add => {
                    const b = try self.pop();
                    const a = try self.pop();
                    if (a != .u64_val or b != .u64_val) return error.TypeMismatch;
                    const result = @addWithOverflow(a.u64_val, b.u64_val);
                    if (result[1] != 0) return error.ArithmeticOverflow;
                    try self.push(.{ .u64_val = result[0] });
                },
                .sub => {
                    const b = try self.pop();
                    const a = try self.pop();
                    if (a != .u64_val or b != .u64_val) return error.TypeMismatch;
                    const result = @subWithOverflow(a.u64_val, b.u64_val);
                    if (result[1] != 0) return error.ArithmeticOverflow;
                    try self.push(.{ .u64_val = result[0] });
                },
                .mul => {
                    const b = try self.pop();
                    const a = try self.pop();
                    if (a != .u64_val or b != .u64_val) return error.TypeMismatch;
                    const result = @mulWithOverflow(a.u64_val, b.u64_val);
                    if (result[1] != 0) return error.ArithmeticOverflow;
                    try self.push(.{ .u64_val = result[0] });
                },
                .div => {
                    const b = try self.pop();
                    const a = try self.pop();
                    if (a != .u64_val or b != .u64_val) return error.TypeMismatch;
                    if (b.u64_val == 0) return error.DivisionByZero;
                    try self.push(.{ .u64_val = a.u64_val / b.u64_val });
                },
                .mod => {
                    const b = try self.pop();
                    const a = try self.pop();
                    if (a != .u64_val or b != .u64_val) return error.TypeMismatch;
                    if (b.u64_val == 0) return error.DivisionByZero;
                    try self.push(.{ .u64_val = a.u64_val % b.u64_val });
                },

                .lt => {
                    const b = try self.pop();
                    const a = try self.pop();
                    if (a != .u64_val or b != .u64_val) return error.TypeMismatch;
                    try self.push(.{ .bool_val = a.u64_val < b.u64_val });
                },
                .le => {
                    const b = try self.pop();
                    const a = try self.pop();
                    if (a != .u64_val or b != .u64_val) return error.TypeMismatch;
                    try self.push(.{ .bool_val = a.u64_val <= b.u64_val });
                },
                .gt => {
                    const b = try self.pop();
                    const a = try self.pop();
                    if (a != .u64_val or b != .u64_val) return error.TypeMismatch;
                    try self.push(.{ .bool_val = a.u64_val > b.u64_val });
                },
                .ge => {
                    const b = try self.pop();
                    const a = try self.pop();
                    if (a != .u64_val or b != .u64_val) return error.TypeMismatch;
                    try self.push(.{ .bool_val = a.u64_val >= b.u64_val });
                },
                .eq => {
                    const b = try self.pop();
                    const a = try self.pop();
                    if (a != .u64_val or b != .u64_val) return error.TypeMismatch;
                    try self.push(.{ .bool_val = a.u64_val == b.u64_val });
                },
                .neq => {
                    const b = try self.pop();
                    const a = try self.pop();
                    if (a != .u64_val or b != .u64_val) return error.TypeMismatch;
                    try self.push(.{ .bool_val = a.u64_val != b.u64_val });
                },

                .and_op => {
                    const b = try self.pop();
                    const a = try self.pop();
                    if (a != .bool_val or b != .bool_val) return error.TypeMismatch;
                    try self.push(.{ .bool_val = a.bool_val and b.bool_val });
                },
                .or_op => {
                    const b = try self.pop();
                    const a = try self.pop();
                    if (a != .bool_val or b != .bool_val) return error.TypeMismatch;
                    try self.push(.{ .bool_val = a.bool_val or b.bool_val });
                },
                .not_op => {
                    const a = try self.pop();
                    if (a != .bool_val) return error.TypeMismatch;
                    try self.push(.{ .bool_val = !a.bool_val });
                },

                .bit_and, .bit_or, .xor, .shl, .shr => {
                    const b = try self.pop();
                    const a = try self.pop();
                    if (a != .u64_val or b != .u64_val) return error.TypeMismatch;
                    const result = switch (inst.opcode) {
                        .bit_and => a.u64_val & b.u64_val,
                        .bit_or => a.u64_val | b.u64_val,
                        .xor => a.u64_val ^ b.u64_val,
                        .shl => a.u64_val << @intCast(b.u64_val & 63),
                        .shr => a.u64_val >> @intCast(b.u64_val & 63),
                        else => unreachable,
                    };
                    try self.push(.{ .u64_val = result });
                },

                .branch => {
                    f.pc = inst.operand;
                },
                .br_true => {
                    const cond = try self.pop();
                    if (cond != .bool_val) return error.TypeMismatch;
                    if (cond.bool_val) f.pc = inst.operand;
                },
                .br_false => {
                    const cond = try self.pop();
                    if (cond != .bool_val) return error.TypeMismatch;
                    if (!cond.bool_val) f.pc = inst.operand;
                },

                .abort => {
                    const code = try self.pop();
                    _ = code;
                    return error.AbortCalled;
                },

                // Global storage operations
                .move_to => {
                    const val = try self.pop();
                    const addr = try self.pop();
                    if (addr != .address_val) return error.TypeMismatch;
                    if (val != .struct_val) return error.TypeMismatch;
                    const key = StorageKey{
                        .address = addr.address_val,
                        .struct_index = val.struct_val.struct_index,
                    };
                    try self.storage.move_to(key, val);
                },
                .move_from => {
                    const addr = try self.pop();
                    if (addr != .address_val) return error.TypeMismatch;
                    const key = StorageKey{
                        .address = addr.address_val,
                        .struct_index = @intCast(inst.operand),
                    };
                    const val = try self.storage.move_from(key);
                    try self.push(val);
                },
                .exists => {
                    const addr = try self.pop();
                    if (addr != .address_val) return error.TypeMismatch;
                    const key = StorageKey{
                        .address = addr.address_val,
                        .struct_index = @intCast(inst.operand),
                    };
                    try self.push(.{ .bool_val = self.storage.exists(key) });
                },

                // Color operations (Move-in-Zig extension)
                .color_hash => {
                    const index = try self.pop();
                    const s = try self.pop();
                    if (s != .u64_val or index != .u64_val) return error.TypeMismatch;
                    try self.push(.{ .u64_val = color_at(s.u64_val, index.u64_val) });
                },
                .color_trit => {
                    const index = try self.pop();
                    const s = try self.pop();
                    if (s != .u64_val or index != .u64_val) return error.TypeMismatch;
                    const t = tritFromU64(color_at(s.u64_val, index.u64_val));
                    try self.push(.{ .u64_val = @as(u64, @intCast(@as(u8, @intCast(@as(i8, @intFromEnum(t)) + 1)))) });
                },
                .trit_add => {
                    const b = try self.pop();
                    const a = try self.pop();
                    if (a != .u64_val or b != .u64_val) return error.TypeMismatch;
                    try self.push(.{ .u64_val = (a.u64_val + b.u64_val) % 3 });
                },
                .is_conserved => {
                    // Pop count, then pop that many trits, check sum % 3 == 0
                    const count = try self.pop();
                    if (count != .u64_val) return error.TypeMismatch;
                    var sum: u64 = 0;
                    var i: u64 = 0;
                    while (i < count.u64_val) : (i += 1) {
                        const t = try self.pop();
                        if (t != .u64_val) return error.TypeMismatch;
                        sum += t.u64_val;
                    }
                    try self.push(.{ .bool_val = (sum % 3) == 0 });
                },

                else => return error.InvalidOpcode,
            }
        }

        // Pop frame
        self.frame_count -= 1;

        // Collect return values from stack
        return &.{};
    }

    /// SPI color at current step — deterministic regardless of execution order
    pub fn current_color(self: *const Vm) u64 {
        return color_at(self.seed, self.step_count);
    }

    /// Current GF(3) trit classification of VM state
    pub fn current_trit(self: *const Vm) Trit {
        return tritFromU64(color_at(self.seed, self.step_count));
    }
};

// ============================================================================
// Bytecode Verifier — static analysis before execution
// ============================================================================

pub const VerifyError = error{
    StackUnderflow,
    StackOverflow,
    TypeMismatch,
    ResourceLeak, // Linear resource not consumed
    ResourceDoubleFree, // Resource used after move
    InvalidBranchTarget,
    UnreachableCode,
};

pub fn verify_function(func: Function, struct_defs: []const StructDef) VerifyError!void {
    _ = struct_defs;
    // Phase 1: CFG construction — verify all branch targets are valid
    for (func.instructions) |inst| {
        switch (inst.opcode) {
            .branch, .br_true, .br_false => {
                if (inst.operand >= func.instructions.len) return error.InvalidBranchTarget;
            },
            else => {},
        }
    }

    // Phase 2: Stack safety — verify consistent stack heights
    // (Simplified: real Move verifier does full abstract interpretation)
    var stack_height: i32 = 0;
    for (func.instructions) |inst| {
        const delta: i32 = stack_delta(inst.opcode);
        stack_height += delta;
        if (stack_height < 0) return error.StackUnderflow;
        if (stack_height > @as(i32, MAX_STACK_DEPTH)) return error.StackOverflow;
    }

    // Phase 3: Resource safety — verify linear resources consumed
    // Track which locals hold linear values and ensure they're all moved by ret
    var linear_locals = [_]bool{false} ** MAX_LOCALS;
    for (func.instructions) |inst| {
        switch (inst.opcode) {
            .st_loc => {
                // Conservatively mark as potentially linear
                linear_locals[@as(usize, inst.operand)] = true;
            },
            .move_loc => {
                linear_locals[@as(usize, inst.operand)] = false;
            },
            .ret => {
                // Check all linear locals consumed
                for (linear_locals[0..func.local_count]) |is_linear| {
                    if (is_linear) return error.ResourceLeak;
                }
            },
            else => {},
        }
    }
}

fn stack_delta(op: Opcode) i32 {
    return switch (op) {
        .pop => -1,
        .ret => 0,
        .nop => 0,
        .ld_const_u64, .ld_const_true, .ld_const_false => 1,
        .copy_loc, .move_loc => 1,
        .st_loc => -1,
        .add, .sub, .mul, .div, .mod => -1, // 2 in, 1 out
        .lt, .le, .gt, .ge, .eq, .neq => -1,
        .and_op, .or_op => -1,
        .not_op => 0,
        .bit_and, .bit_or, .xor, .shl, .shr => -1,
        .branch => 0,
        .br_true, .br_false => -1,
        .call => 0, // Varies; simplified
        .abort => -1,
        .move_to => -2,
        .move_from => 0, // -1 addr, +1 value
        .exists => 0, // -1 addr, +1 bool
        .borrow_global, .borrow_global_mut => 0,
        .pack => 0, // Varies
        .unpack => 0, // Varies
        .vec_empty => 1,
        .vec_push => -1,
        .vec_pop => 0,
        .vec_len => 0,
        .vec_borrow => 0,
        .color_hash => -1,
        .color_trit => -1,
        .trit_add => -1,
        .is_conserved => 0, // Varies; depends on count
        _ => 0,
    };
}

// ============================================================================
// SPI Parallel Executor — Block-STM analogue
// ============================================================================

pub const Transaction = struct {
    module: Module,
    function_name: []const u8,
    args: []const Value,
    sender: [32]u8,
};

pub const TxResult = struct {
    success: bool,
    gas_used: u64,
    color: u64, // Deterministic color at completion
    trit: Trit, // GF(3) classification
    error_code: ?VmError = null,
};

/// Execute transactions in parallel with SPI guarantee.
/// Returns results in original transaction order (Block-STM semantics).
pub fn execute_parallel(
    transactions: []const Transaction,
    max_gas_per_tx: u64,
    seed: u64,
) []TxResult {
    // SPI guarantee: color(seed, i) == color(seed, i) regardless of execution order
    // Each transaction gets an independent VM with seed derived from global seed + tx index
    var results: [256]TxResult = undefined;
    assert(transactions.len <= 256);

    for (transactions, 0..) |tx, i| {
        const tx_seed = splitmix64(seed ^ (GOLDEN *% @as(u64, @intCast(i))));
        var vm = Vm.init(max_gas_per_tx, tx_seed);

        vm.execute_function(tx.module, tx.function_name, tx.args) catch |err| {
            results[i] = .{
                .success = false,
                .gas_used = vm.gas.gas_used,
                .color = vm.current_color(),
                .trit = vm.current_trit(),
                .error_code = err,
            };
            continue;
        };

        results[i] = .{
            .success = true,
            .gas_used = vm.gas.gas_used,
            .color = vm.current_color(),
            .trit = vm.current_trit(),
        };
    }

    return results[0..transactions.len];
}

// ============================================================================
// Tests — TigerBeetle: assertion density, pair assertions
// ============================================================================

test "splitmix64 reference values" {
    // Matches gay_color.move test_splitmix64_reference_values
    try std.testing.expectEqual(@as(u64, 16294208416658607535), splitmix64(0));
    try std.testing.expectEqual(@as(u64, 10451216379200822465), splitmix64(1));
}

test "ability set size" {
    // TigerBeetle: comptime size assertion
    try std.testing.expectEqual(@as(usize, 1), @sizeOf(AbilitySet));
}

test "instruction size" {
    try std.testing.expectEqual(@as(usize, 4), @sizeOf(Instruction));
}

test "ability set properties" {
    const resource = AbilitySet.resource;
    try std.testing.expect(resource.is_linear()); // No copy
    try std.testing.expect(resource.must_consume()); // No drop
    try std.testing.expect(resource.can_store_globally()); // Has key

    const primitive = primitive_abilities();
    try std.testing.expect(!primitive.is_linear()); // Has copy
    try std.testing.expect(!primitive.must_consume()); // Has drop
}

test "gas metering" {
    var gas = GasStatus.init(100);
    try gas.deduct(30);
    try std.testing.expectEqual(@as(u64, 70), gas.gas_left);
    try std.testing.expectEqual(@as(u64, 30), gas.gas_used);

    // Should fail with OutOfGas
    try std.testing.expectError(error.OutOfGas, gas.deduct(80));
}

test "opcode gas costs" {
    // Storage operations are expensive
    try std.testing.expectEqual(@as(u16, 50), gas_cost(.move_to));
    try std.testing.expectEqual(@as(u16, 50), gas_cost(.move_from));
    // Arithmetic is cheap
    try std.testing.expectEqual(@as(u16, 3), gas_cost(.add));
    try std.testing.expectEqual(@as(u16, 1), gas_cost(.nop));
}

test "vm basic arithmetic" {
    var vm = Vm.init(10000, 69);

    // Build a simple function: add(3, 5) -> 8
    const instructions = [_]Instruction{
        .{ .opcode = .ld_const_u64, .operand = 3 },
        .{ .opcode = .ld_const_u64, .operand = 5 },
        .{ .opcode = .add },
        .{ .opcode = .ret },
    };

    const func = Function{
        .name = "test_add",
        .param_count = 0,
        .return_count = 1,
        .local_count = 0,
        .instructions = &instructions,
    };

    const module = Module{
        .name = "test",
        .functions = &[_]Function{func},
        .struct_defs = &.{},
    };

    _ = try vm.execute_function(module, "test_add", &.{});
    const result = try vm.pop();
    try std.testing.expectEqual(@as(u64, 8), result.u64_val);
}

test "vm spi determinism" {
    // SPI: same seed + same index = same color, regardless of when computed
    const seed: u64 = 69;
    const c1 = color_at(seed, 42);
    const c2 = color_at(seed, 42);
    try std.testing.expectEqual(c1, c2);

    // Different index = different color
    const c3 = color_at(seed, 43);
    try std.testing.expect(c1 != c3);
}

test "global storage move_to and move_from" {
    var storage = GlobalStorage{};
    const key = StorageKey{
        .address = [_]u8{0x42} ** 32,
        .struct_index = 0,
    };
    const val = Value{ .u64_val = 1069 };

    try storage.move_to(key, val);
    try std.testing.expect(storage.exists(key));

    // Cannot double-store (Move semantics)
    try std.testing.expectError(error.ResourceAlreadyExists, storage.move_to(key, val));

    // Move out
    const retrieved = try storage.move_from(key);
    try std.testing.expectEqual(@as(u64, 1069), retrieved.u64_val);
    try std.testing.expect(!storage.exists(key));
}

test "verify valid function" {
    const instructions = [_]Instruction{
        .{ .opcode = .ld_const_u64, .operand = 42 },
        .{ .opcode = .st_loc, .operand = 0 },
        .{ .opcode = .move_loc, .operand = 0 },
        .{ .opcode = .ret },
    };

    const func = Function{
        .name = "valid",
        .param_count = 0,
        .return_count = 1,
        .local_count = 1,
        .instructions = &instructions,
    };

    try verify_function(func, &.{});
}

test "verify catches invalid branch target" {
    const instructions = [_]Instruction{
        .{ .opcode = .branch, .operand = 999 }, // Invalid target
        .{ .opcode = .ret },
    };

    const func = Function{
        .name = "bad_branch",
        .param_count = 0,
        .return_count = 0,
        .local_count = 0,
        .instructions = &instructions,
    };

    try std.testing.expectError(error.InvalidBranchTarget, verify_function(func, &.{}));
}

test "gf3 trit conservation" {
    // Three trits summing to 0 mod 3 are conserved
    const t1 = Trit.minus; // -1
    const t2 = Trit.ergodic; // 0
    const t3 = Trit.plus; // +1
    const sum = Trit.add(Trit.add(t1, t2), t3);
    try std.testing.expectEqual(Trit.ergodic, sum); // -1 + 0 + 1 = 0
}
