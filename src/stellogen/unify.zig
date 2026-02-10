//! Stellogen Unification - Robinson's algorithm for term unification
//! Core of the interaction semantics

const std = @import("std");
const ast = @import("ast.zig");
const Term = ast.Term;
const VarId = ast.VarId;
const FuncId = ast.FuncId;

/// Substitution: mapping from variables to terms
pub const Substitution = struct {
    bindings: std.AutoHashMap(u64, Term),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Substitution {
        return .{
            .bindings = std.AutoHashMap(u64, Term).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Substitution) void {
        self.bindings.deinit();
    }

    pub fn put(self: *Substitution, v: VarId, t: Term) !void {
        try self.bindings.put(v.hash(), t);
    }

    pub fn get(self: *const Substitution, v: VarId) ?Term {
        return self.bindings.get(v.hash());
    }

    pub fn contains(self: *const Substitution, v: VarId) bool {
        return self.bindings.contains(v.hash());
    }

    /// Apply substitution to a term
    pub fn apply(self: *const Substitution, term: Term) !Term {
        return switch (term) {
            .variable => |v| {
                if (self.get(v)) |bound| {
                    return self.apply(bound);
                }
                return term;
            },
            .function => |f| {
                var new_args = try self.allocator.alloc(Term, f.args.len);
                for (f.args, 0..) |arg, i| {
                    new_args[i] = try self.apply(arg);
                }
                return .{
                    .function = .{
                        .id = f.id,
                        .args = new_args,
                    },
                };
            },
        };
    }

    /// Compose two substitutions: self ∘ other
    pub fn compose(self: *Substitution, other: *const Substitution) !void {
        // Apply self to all bindings in other, then merge
        var it = other.bindings.iterator();
        while (it.next()) |entry| {
            const applied = try self.apply(entry.value_ptr.*);
            try self.bindings.put(entry.key_ptr.*, applied);
        }
    }

    pub fn isEmpty(self: *const Substitution) bool {
        return self.bindings.count() == 0;
    }
};

/// Unification error types
pub const UnifyError = error{
    OccursCheck, // Circular binding detected
    Clash, // Incompatible function symbols
    ArityMismatch, // Different argument counts
    OutOfMemory,
};

/// Unification problem: list of term pairs to solve
pub const Problem = std.ArrayListUnmanaged(struct { Term, Term });

/// Robinson's unification algorithm
/// Returns the most general unifier (MGU) or null if unification fails
pub fn unify(allocator: std.mem.Allocator, t1: Term, t2: Term) UnifyError!?Substitution {
    var problem = Problem{};
    defer problem.deinit(allocator);
    try problem.append(allocator, .{ t1, t2 });

    var subst = Substitution.init(allocator);
    errdefer subst.deinit();

    while (problem.items.len > 0) {
        const pair = problem.pop().?;
        const left = pair[0];
        const right = pair[1];

        // Rule 1: Clear - identical terms
        if (left.eql(right)) continue;

        // Rule 2: Variable elimination
        switch (left) {
            .variable => |v| {
                // Occurs check
                if (right.containsVar(v)) return UnifyError.OccursCheck;
                // Bind and propagate
                try subst.put(v, right);
                // Apply to remaining problem
                for (problem.items) |*p| {
                    p[0] = try subst.apply(p[0]);
                    p[1] = try subst.apply(p[1]);
                }
                continue;
            },
            else => {},
        }

        switch (right) {
            .variable => |v| {
                // Occurs check
                if (left.containsVar(v)) return UnifyError.OccursCheck;
                // Bind and propagate
                try subst.put(v, left);
                // Apply to remaining problem
                for (problem.items) |*p| {
                    p[0] = try subst.apply(p[0]);
                    p[1] = try subst.apply(p[1]);
                }
                continue;
            },
            else => {},
        }

        // Rule 3: Function decomposition
        switch (left) {
            .function => |f1| {
                switch (right) {
                    .function => |f2| {
                        // Check compatibility (same name, compatible polarity)
                        if (!f1.id.compatible(f2.id)) return null;
                        if (f1.args.len != f2.args.len) return UnifyError.ArityMismatch;

                        // Add argument pairs to problem
                        for (f1.args, f2.args) |a1, a2| {
                            try problem.append(allocator, .{ a1, a2 });
                        }
                    },
                    else => return null,
                }
            },
            else => return null,
        }
    }

    return subst;
}

/// Check if two terms can unify (without computing the substitution)
pub fn canUnify(allocator: std.mem.Allocator, t1: Term, t2: Term) bool {
    if (unify(allocator, t1, t2)) |sub_opt| {
        if (sub_opt) |*sub| {
            var s = sub;
            s.deinit();
            return true;
        }
    } else |_| {}
    return false;
}

// ============================================================================
// Tests
// ============================================================================

test "unify identical terms" {
    const allocator = std.testing.allocator;
    const x = ast.makeVar("X");

    const result = try unify(allocator, x, x);
    try std.testing.expect(result != null);
    var sub = result.?;
    defer sub.deinit();
    try std.testing.expect(sub.isEmpty());
}

test "unify variable with term" {
    const allocator = std.testing.allocator;
    const x = ast.makeVar("X");
    const a = ast.makeAtom(.null, "a");

    const result = try unify(allocator, x, a);
    try std.testing.expect(result != null);
    var sub = result.?;
    defer sub.deinit();

    const bound = sub.get(.{ .name = "X" });
    try std.testing.expect(bound != null);
    try std.testing.expect(bound.?.eql(a));
}

test "unify function terms" {
    const allocator = std.testing.allocator;

    // f(X) and f(a)
    const x = ast.makeVar("X");
    const a = ast.makeAtom(.null, "a");
    const fx = try ast.makeFunc(allocator, .null, "f", &.{x});
    const fa = try ast.makeFunc(allocator, .null, "f", &.{a});

    const result = try unify(allocator, fx, fa);
    try std.testing.expect(result != null);
    var sub = result.?;
    defer sub.deinit();

    const bound = sub.get(.{ .name = "X" });
    try std.testing.expect(bound != null);
}

test "unify fails on different functions" {
    const allocator = std.testing.allocator;

    const a = ast.makeAtom(.null, "a");
    const b = ast.makeAtom(.null, "b");

    const result = try unify(allocator, a, b);
    try std.testing.expect(result == null);
}

test "unify fails on occurs check" {
    const allocator = std.testing.allocator;

    // X and f(X) should fail
    const x = ast.makeVar("X");
    const fx = try ast.makeFunc(allocator, .null, "f", &.{x});

    const result = unify(allocator, x, fx);
    try std.testing.expect(result == UnifyError.OccursCheck);
}

test "unify with polarities" {
    const allocator = std.testing.allocator;

    // +f(X) and -f(a) should unify (opposite polarities)
    const x = ast.makeVar("X");
    const a = ast.makeAtom(.null, "a");
    const pos_fx = try ast.makeFunc(allocator, .pos, "f", &.{x});
    const neg_fa = try ast.makeFunc(allocator, .neg, "f", &.{a});

    const result = try unify(allocator, pos_fx, neg_fa);
    try std.testing.expect(result != null);
    var sub = result.?;
    defer sub.deinit();
}
