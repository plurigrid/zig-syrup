/// Ghostty Interactive Execution (IX) - BIM (Basic Interaction Machine)
///
/// Bytecode VM for unification and pattern matching.
/// Designed for formal verification via Boxxy (Isabelle 2 proofs).
///
/// Architectural Goals:
/// - Provable semantics: Each instruction has formal specification
/// - Small instruction set: ~20 opcodes enable comprehensive proof coverage
/// - Deterministic execution: Pure functional evaluation (no side effects)
/// - OCapN integration: Closure bytecode can be serialized via Syrup
///
/// Instruction Set:
/// - Stack: push_const, push_var, pop
/// - Unification: unify, bind, deref (Martelli-Montanari algorithm)
/// - Control: call, ret, jump, jump_fail
/// - Memory: alloc, free, store, load
/// - Interaction: halt, fuse, schedule
///
/// Trit Classification: PLUS (+1) generation (creates interaction traces)

const std = @import("std");
const ghostty_ix = @import("ghostty_ix");

pub const ExecutionResult = ghostty_ix.ExecutionResult;
pub const Command = ghostty_ix.Command;

/// BIM Opcodes (small instruction set for formal verification)
pub const Opcode = enum(u8) {
    /// Stack operations
    push_const = 0,   // arg: constant value
    push_var = 1,     // arg: variable index
    pop = 2,          // no args
    dup = 3,          // duplicate top of stack

    /// Unification (Martelli-Montanari)
    unify = 10,       // unify top two stack items
    bind = 11,        // bind variable to value
    deref = 12,       // dereference variable
    occurs_check = 13, // check occurs-check constraint

    /// Control flow
    call = 20,        // arg: function/continuation ID
    ret = 21,         // return from function
    jump = 22,        // arg: instruction offset
    jump_fail = 23,   // jump if unification fails

    /// Memory
    alloc = 30,       // arg: size (allocate on heap)
    free = 31,        // arg: address
    store = 32,       // store stack top to memory
    load = 33,        // load from memory to stack

    /// Interaction (for integration with continuation system)
    fuse = 40,        // fuse two interaction traces
    schedule = 41,    // schedule for continuation
    call_extern = 42, // call external function

    /// Termination
    halt = 99,        // halt with success
};

/// BIM Value (can be constant, variable, or term)
pub const Value = union(enum) {
    const_int: i64,
    const_float: f64,
    const_str: []const u8,
    variable: u32,         // variable index
    term: Term,            // structured term for unification
};

/// Term for unification
pub const Term = struct {
    functor: []const u8,
    arity: u32,
    args: []const Term,

    pub fn eql(self: Term, other: Term) bool {
        if (!std.mem.eql(u8, self.functor, other.functor)) return false;
        if (self.arity != other.arity) return false;
        for (self.args, other.args) |a, b| {
            if (!a.eql(b)) return false;
        }
        return true;
    }
};

/// Bytecode instruction
pub const Instruction = struct {
    opcode: Opcode,
    arg: i32 = 0,

    pub fn encode(self: Instruction) u32 {
        return (@as(u32, @intFromEnum(self.opcode)) << 24) |
               (@as(u32, @bitCast(self.arg)) & 0xFFFFFF);
    }

    pub fn decode(bytecode: u32) Instruction {
        return Instruction{
            .opcode = @enumFromInt((bytecode >> 24) & 0xFF),
            .arg = @bitCast(@as(i32, @intCast(bytecode & 0xFFFFFF))),
        };
    }
};

/// BIM Virtual Machine
pub const BIM = struct {
    allocator: std.mem.Allocator,
    /// Bytecode instructions
    code: std.ArrayListUnmanaged(Instruction) = .{},
    /// Execution stack
    stack: std.ArrayListUnmanaged(Value) = .{},
    /// Variable bindings
    bindings: std.AutoHashMapUnmanaged(u32, Value) = .{},
    /// Program counter
    pc: u32 = 0,
    /// Execution trace (for verification)
    trace: std.ArrayListUnmanaged(Instruction) = .{},
    /// Whether execution succeeded
    success: bool = true,

    pub fn init(allocator: std.mem.Allocator) BIM {
        return BIM{
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *BIM) void {
        self.code.deinit(self.allocator);
        self.stack.deinit(self.allocator);
        self.bindings.deinit(self.allocator);
        self.trace.deinit(self.allocator);
    }

    /// Load bytecode
    pub fn load(self: *BIM, bytecode: []const u8) !void {
        // Parse bytecode (4 bytes per instruction)
        var i: usize = 0;
        while (i + 4 <= bytecode.len) {
            const instr_bytes: [4]u8 = bytecode[i .. i + 4][0..4].*;
            const instr_u32 = std.mem.readInt(u32, &instr_bytes, .big);
            const instr = Instruction.decode(instr_u32);
            try self.code.append(self.allocator, instr);
            i += 4;
        }
    }

    /// Execute bytecode until halt or error
    pub fn execute(self: *BIM) !void {
        while (self.pc < self.code.items.len and self.success) {
            const instr = self.code.items[self.pc];
            try self.trace.append(self.allocator, instr);

            switch (instr.opcode) {
                .push_const => {
                    try self.stack.append(self.allocator, .{ .const_int = instr.arg });
                    self.pc += 1;
                },
                .push_var => {
                    const var_idx = @as(u32, @intCast(instr.arg));
                    if (self.bindings.get(var_idx)) |val| {
                        try self.stack.append(self.allocator, val);
                    } else {
                        try self.stack.append(self.allocator, .{ .variable = var_idx });
                    }
                    self.pc += 1;
                },
                .pop => {
                    if (self.stack.items.len > 0) {
                        _ = self.stack.pop();
                    } else {
                        self.success = false;
                    }
                    self.pc += 1;
                },
                .unify => {
                    if (self.stack.items.len >= 2) {
                        const v2 = self.stack.pop();
                        const v1 = self.stack.pop();
                        if (self.unifyValues(v1, v2)) {
                            // Success: continue
                            self.pc += 1;
                        } else {
                            // Failure: mark failure
                            self.success = false;
                        }
                    } else {
                        self.success = false;
                    }
                },
                .halt => {
                    self.success = true;
                    self.pc = @as(u32, @intCast(self.code.items.len));
                },
                else => {
                    self.pc += 1;
                },
            }
        }
    }

    /// Unify two values (simplified)
    fn unifyValues(self: *BIM, v1: Value, v2: Value) bool {
        _ = self;
        return switch (v1) {
            .const_int => |i1| switch (v2) {
                .const_int => |i2| i1 == i2,
                else => false,
            },
            .variable => |var_idx| {
                // Bind variable to value (simplified)
                _ = var_idx;
                return true;
            },
            else => false,
        };
    }

    /// Get execution trace as ExecutionResult
    pub fn getTrace(self: BIM, allocator: std.mem.Allocator) ![]u8 {
        var trace_buf = std.ArrayList(u8).init(allocator);
        defer trace_buf.deinit();

        for (self.trace.items) |instr| {
            const line = try std.fmt.allocPrint(
                allocator,
                "{} (arg={})\n",
                .{ @intFromEnum(instr.opcode), instr.arg },
            );
            defer allocator.free(line);
            try trace_buf.appendSlice(line);
        }

        return trace_buf.toOwnedSlice();
    }
};

/// BIM Executor for IX
pub const BIMExecutor = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) BIMExecutor {
        return BIMExecutor{
            .allocator = allocator,
        };
    }

    /// Execute BIM bytecode from command
    pub fn execute(self: BIMExecutor, cmd: Command) !ExecutionResult {
        var vm = BIM.init(self.allocator);
        defer vm.deinit();

        // For now: treat args as bytecode hex string
        const bytecode = if (cmd.args.len > 0)
            try self.allocator.dupe(u8, cmd.args)
        else
            try self.allocator.dupe(u8, "");

        defer self.allocator.free(bytecode);

        // Load and execute (simplified: just load, don't execute yet)
        // In full implementation: parse hex string to bytecode
        _ = try vm.execute();

        // Get trace
        const trace = try vm.getTrace(self.allocator);

        var output_buf: [512]u8 = undefined;
        const output = try std.fmt.bufPrint(&output_buf,
            "BIM execution: success={}, trace_len={}",
            .{ vm.success, vm.trace.items.len },
        );

        const owned_output = try self.allocator.dupe(u8, output);

        return ExecutionResult{
            .success = vm.success,
            .output = owned_output,
            .error_message = if (!vm.success) "execution failed" else null,
            .next_state = trace,
            .colors_updated = false,
            .spatial_changed = false,
        };
    }
};

// Tests
pub const testing = struct {
    pub fn testPushPop(allocator: std.mem.Allocator) !void {
        var vm = BIM.init(allocator);
        defer vm.deinit();

        try vm.code.append(allocator, Instruction{ .opcode = .push_const, .arg = 42 });
        try vm.code.append(allocator, Instruction{ .opcode = .halt });

        try vm.execute();

        try std.testing.expect(vm.success);
        try std.testing.expect(vm.stack.items.len == 1);
    }

    pub fn testUnification(allocator: std.mem.Allocator) !void {
        var vm = BIM.init(allocator);
        defer vm.deinit();

        try vm.code.append(allocator, Instruction{ .opcode = .push_const, .arg = 10 });
        try vm.code.append(allocator, Instruction{ .opcode = .push_const, .arg = 10 });
        try vm.code.append(allocator, Instruction{ .opcode = .unify });
        try vm.code.append(allocator, Instruction{ .opcode = .halt });

        try vm.execute();

        try std.testing.expect(vm.success);
    }

    pub fn testExecutionTrace(allocator: std.mem.Allocator) !void {
        var vm = BIM.init(allocator);
        defer vm.deinit();

        try vm.code.append(allocator, Instruction{ .opcode = .push_const, .arg = 1 });
        try vm.code.append(allocator, Instruction{ .opcode = .halt });

        try vm.execute();

        const trace = try vm.getTrace(allocator);
        defer allocator.free(trace);

        try std.testing.expect(trace.len > 0);
    }
};
