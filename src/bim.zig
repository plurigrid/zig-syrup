//! BIM: Basic Interaction Machine
//!
//! A minimal bytecode VM for Stellogen's stellar resolution.
//! Designed for deterministic term unification without backtracking.
//!
//! Reference: https://github.com/engboris/stellogen/issues/19

const std = @import("std");
const Allocator = std.mem.Allocator;

// =============================================================================
// Instruction Set
// =============================================================================

pub const Opcode = enum(u8) {
    // Stack operations
    push_var, // Push variable X_idx
    push_const, // Push constant from pool
    push_term, // Construct term from stack (arity follows)
    pop, // Discard top

    // Unification (core of stellar resolution)
    unify, // Unify top two, push result or fail
    bind, // Extend substitution
    deref, // Chase substitution chain

    // Control flow
    call, // Enter constellation
    ret, // Return
    jump, // Unconditional jump
    jump_fail, // Jump if top is FAIL

    // Fusion scheduling
    fuse, // Attempt ray unification between two stars
    schedule, // Set scheduling mode

    // FFI escape
    @"extern", // Call registered native function

    // Termination
    halt,
};

pub const Instruction = struct {
    op: Opcode,
    arg1: u16 = 0,
    arg2: u16 = 0,
};

// =============================================================================
// Term Representation
// =============================================================================

pub const TermTag = enum(u8) {
    variable, // Unbound variable X_n
    constant, // Atom or number
    compound, // f(t1, ..., tn)
    fail, // Unification failure marker
};

pub const Term = struct {
    tag: TermTag,
    /// For variable: index. For constant: pool index. For compound: functor index.
    head: u32,
    /// For compound: slice into args arena
    args: []const Term = &.{},

    pub fn isVar(self: Term) bool {
        return self.tag == .variable;
    }

    pub fn isFail(self: Term) bool {
        return self.tag == .fail;
    }

    pub fn eql(a: Term, b: Term) bool {
        if (a.tag != b.tag or a.head != b.head) return false;
        if (a.args.len != b.args.len) return false;
        for (a.args, b.args) |x, y| {
            if (!eql(x, y)) return false;
        }
        return true;
    }
};

pub const FAIL: Term = .{ .tag = .fail, .head = 0 };

// =============================================================================
// Substitution (Linear Environment)
// =============================================================================

pub const Substitution = struct {
    bindings: std.AutoHashMapUnmanaged(u32, Term),
    allocator: Allocator,

    pub fn init(allocator: Allocator) Substitution {
        return .{
            .bindings = .{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Substitution) void {
        self.bindings.deinit(self.allocator);
    }

    pub fn bind(self: *Substitution, var_idx: u32, term: Term) !void {
        try self.bindings.put(self.allocator, var_idx, term);
    }

    pub fn lookup(self: *const Substitution, var_idx: u32) ?Term {
        return self.bindings.get(var_idx);
    }

    /// Chase substitution chain to ground term
    pub fn deref(self: *const Substitution, term: Term) Term {
        if (term.tag != .variable) return term;
        if (self.lookup(term.head)) |bound| {
            return self.deref(bound);
        }
        return term; // Unbound variable
    }
};

// =============================================================================
// Unification Algorithm
// =============================================================================

pub fn unify(allocator: Allocator, subst: *Substitution, t1: Term, t2: Term) !Term {
    const a = subst.deref(t1);
    const b = subst.deref(t2);

    // Both are the same term
    if (Term.eql(a, b)) return a;

    // Variable binding
    if (a.isVar()) {
        if (occursCheck(a.head, b, subst)) return FAIL;
        try subst.bind(a.head, b);
        return b;
    }
    if (b.isVar()) {
        if (occursCheck(b.head, a, subst)) return FAIL;
        try subst.bind(b.head, a);
        return a;
    }

    // Compound unification
    if (a.tag == .compound and b.tag == .compound) {
        if (a.head != b.head) return FAIL; // Different functors
        if (a.args.len != b.args.len) return FAIL; // Different arity

        var unified_args = try allocator.alloc(Term, a.args.len);
        for (a.args, b.args, 0..) |arg_a, arg_b, i| {
            const unified = try unify(allocator, subst, arg_a, arg_b);
            if (unified.isFail()) {
                allocator.free(unified_args);
                return FAIL;
            }
            unified_args[i] = unified;
        }
        return Term{ .tag = .compound, .head = a.head, .args = unified_args };
    }

    // Constants must be equal (already checked via eql)
    return FAIL;
}

fn occursCheck(var_idx: u32, term: Term, subst: *const Substitution) bool {
    const t = subst.deref(term);
    if (t.tag == .variable) return t.head == var_idx;
    if (t.tag == .compound) {
        for (t.args) |arg| {
            if (occursCheck(var_idx, arg, subst)) return true;
        }
    }
    return false;
}

// =============================================================================
// Virtual Machine
// =============================================================================

pub const VM = struct {
    allocator: Allocator,
    stack: std.ArrayListUnmanaged(Term),
    subst: Substitution,
    code: []const Instruction,
    pc: usize,
    const_pool: []const Term,
    ffi_table: std.StringHashMapUnmanaged(FfiFn),

    pub const FfiFn = *const fn (*VM) void;

    pub fn init(allocator: Allocator, code: []const Instruction, const_pool: []const Term) VM {
        return .{
            .allocator = allocator,
            .stack = .{},
            .subst = Substitution.init(allocator),
            .code = code,
            .pc = 0,
            .const_pool = const_pool,
            .ffi_table = .{},
        };
    }

    pub fn deinit(self: *VM) void {
        self.stack.deinit(self.allocator);
        self.subst.deinit();
        self.ffi_table.deinit(self.allocator);
    }

    pub fn register(self: *VM, name: []const u8, func: FfiFn) !void {
        try self.ffi_table.put(self.allocator, name, func);
    }

    pub fn push(self: *VM, term: Term) !void {
        try self.stack.append(self.allocator, term);
    }

    pub fn pop(self: *VM) ?Term {
        if (self.stack.items.len == 0) return null;
        return self.stack.pop();
    }

    pub fn peek(self: *VM) ?Term {
        if (self.stack.items.len == 0) return null;
        return self.stack.items[self.stack.items.len - 1];
    }

    pub fn run(self: *VM) !?Term {
        while (self.pc < self.code.len) {
            const instr = self.code[self.pc];
            self.pc += 1;

            switch (instr.op) {
                .push_var => {
                    try self.push(Term{ .tag = .variable, .head = instr.arg1 });
                },
                .push_const => {
                    if (instr.arg1 < self.const_pool.len) {
                        try self.push(self.const_pool[instr.arg1]);
                    }
                },
                .push_term => {
                    const arity = instr.arg1;
                    var args = try self.allocator.alloc(Term, arity);
                    var i: usize = 0;
                    while (i < arity) : (i += 1) {
                        args[arity - 1 - i] = self.pop() orelse return error.StackUnderflow;
                    }
                    const functor = self.pop() orelse return error.StackUnderflow;
                    try self.push(Term{ .tag = .compound, .head = functor.head, .args = args });
                },
                .pop => {
                    _ = self.pop();
                },
                .unify => {
                    const b = self.pop() orelse return error.StackUnderflow;
                    const a = self.pop() orelse return error.StackUnderflow;
                    const result = try unify(self.allocator, &self.subst, a, b);
                    try self.push(result);
                },
                .deref => {
                    if (self.pop()) |term| {
                        try self.push(self.subst.deref(term));
                    }
                },
                .jump => {
                    self.pc = instr.arg1;
                },
                .jump_fail => {
                    if (self.peek()) |top| {
                        if (top.isFail()) {
                            self.pc = instr.arg1;
                        }
                    }
                },
                .halt => {
                    return self.pop();
                },
                else => {
                    // TODO: implement remaining opcodes
                },
            }
        }
        return self.pop();
    }
};

// =============================================================================
// Tests
// =============================================================================

test "unify identical constants" {
    const allocator = std.testing.allocator;
    var subst = Substitution.init(allocator);
    defer subst.deinit();

    const a = Term{ .tag = .constant, .head = 42 };
    const b = Term{ .tag = .constant, .head = 42 };
    const result = try unify(allocator, &subst, a, b);

    try std.testing.expect(!result.isFail());
    try std.testing.expectEqual(@as(u32, 42), result.head);
}

test "unify different constants fails" {
    const allocator = std.testing.allocator;
    var subst = Substitution.init(allocator);
    defer subst.deinit();

    const a = Term{ .tag = .constant, .head = 1 };
    const b = Term{ .tag = .constant, .head = 2 };
    const result = try unify(allocator, &subst, a, b);

    try std.testing.expect(result.isFail());
}

test "unify variable with constant" {
    const allocator = std.testing.allocator;
    var subst = Substitution.init(allocator);
    defer subst.deinit();

    const x = Term{ .tag = .variable, .head = 0 };
    const c = Term{ .tag = .constant, .head = 99 };
    const result = try unify(allocator, &subst, x, c);

    try std.testing.expect(!result.isFail());
    try std.testing.expectEqual(@as(u32, 99), result.head);

    // Check substitution
    const bound = subst.lookup(0);
    try std.testing.expect(bound != null);
    try std.testing.expectEqual(@as(u32, 99), bound.?.head);
}

test "VM push and unify" {
    const allocator = std.testing.allocator;

    const code = [_]Instruction{
        .{ .op = .push_const, .arg1 = 0 },
        .{ .op = .push_const, .arg1 = 0 },
        .{ .op = .unify },
        .{ .op = .halt },
    };
    const pool = [_]Term{
        Term{ .tag = .constant, .head = 42 },
    };

    var vm = VM.init(allocator, &code, &pool);
    defer vm.deinit();

    const result = try vm.run();
    try std.testing.expect(result != null);
    try std.testing.expect(!result.?.isFail());
    try std.testing.expectEqual(@as(u32, 42), result.?.head);
}

test "VM unify different fails" {
    const allocator = std.testing.allocator;

    const code = [_]Instruction{
        .{ .op = .push_const, .arg1 = 0 },
        .{ .op = .push_const, .arg1 = 1 },
        .{ .op = .unify },
        .{ .op = .halt },
    };
    const pool = [_]Term{
        Term{ .tag = .constant, .head = 1 },
        Term{ .tag = .constant, .head = 2 },
    };

    var vm = VM.init(allocator, &code, &pool);
    defer vm.deinit();

    const result = try vm.run();
    try std.testing.expect(result != null);
    try std.testing.expect(result.?.isFail());
}
