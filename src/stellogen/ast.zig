//! Stellogen AST - Core types for the logic-agnostic programming language
//! Based on Girard's transcendental syntax and Lafont's interaction nets

const std = @import("std");

/// Polarity of a ray - determines interaction compatibility
pub const Polarity = enum(i8) {
    pos = 1, // Producer/output (+)
    neg = -1, // Consumer/input (-)
    null = 0, // Neutral (no interaction)

    pub fn opposite(self: Polarity) Polarity {
        return switch (self) {
            .pos => .neg,
            .neg => .pos,
            .null => .null,
        };
    }

    pub fn compatible(self: Polarity, other: Polarity) bool {
        // Two rays interact iff they have opposite polarities
        // or at least one is neutral
        return (self == .pos and other == .neg) or
            (self == .neg and other == .pos) or
            self == .null or other == .null;
    }

    pub fn toGF3(self: Polarity) i8 {
        return @intFromEnum(self);
    }
};

/// Variable identifier with optional index for scoping
pub const VarId = struct {
    name: []const u8,
    index: ?u32 = null, // Index for alpha-renaming across stars

    pub fn eql(self: VarId, other: VarId) bool {
        return std.mem.eql(u8, self.name, other.name) and self.index == other.index;
    }

    pub fn hash(self: VarId) u64 {
        var h = std.hash.Wyhash.init(0);
        h.update(self.name);
        if (self.index) |i| h.update(std.mem.asBytes(&i));
        return h.final();
    }
};

/// Function identifier with polarity
pub const FuncId = struct {
    polarity: Polarity,
    name: []const u8,

    pub fn compatible(self: FuncId, other: FuncId) bool {
        return std.mem.eql(u8, self.name, other.name) and
            self.polarity.compatible(other.polarity);
    }
};

/// Term - the fundamental building block
/// Everything in Stellogen reduces to terms
pub const Term = union(enum) {
    variable: VarId,
    function: struct {
        id: FuncId,
        args: []const Term,
    },

    const Self = @This();

    pub fn isVar(self: Self) bool {
        return self == .variable;
    }

    pub fn isFunc(self: Self) bool {
        return self == .function;
    }

    pub fn polarity(self: Self) Polarity {
        return switch (self) {
            .variable => .null,
            .function => |f| f.id.polarity,
        };
    }

    /// Check if term contains a variable
    pub fn containsVar(self: Self, v: VarId) bool {
        return switch (self) {
            .variable => |vid| vid.eql(v),
            .function => |f| {
                for (f.args) |arg| {
                    if (arg.containsVar(v)) return true;
                }
                return false;
            },
        };
    }

    /// Deep equality check
    pub fn eql(self: Self, other: Self) bool {
        return switch (self) {
            .variable => |v| switch (other) {
                .variable => |ov| v.eql(ov),
                else => false,
            },
            .function => |f| switch (other) {
                .function => |of| {
                    if (!std.mem.eql(u8, f.id.name, of.id.name)) return false;
                    if (f.id.polarity != of.id.polarity) return false;
                    if (f.args.len != of.args.len) return false;
                    for (f.args, of.args) |a, b| {
                        if (!a.eql(b)) return false;
                    }
                    return true;
                },
                else => false,
            },
        };
    }
};

/// Ray = Term (with polarity implicit in function identifier)
pub const Ray = Term;

/// Constraint (ban) on unification
pub const Ban = union(enum) {
    inequality: struct { a: Ray, b: Ray }, // X ≠ Y
    incompatibility: struct { a: Ray, b: Ray }, // Cannot unify
};

/// Star - a block of rays with optional constraints
pub const Star = struct {
    content: []const Ray,
    bans: []const Ban = &.{},
    is_state: bool = false, // @-focused (target for interaction)

    pub fn isEmpty(self: Star) bool {
        return self.content.len == 0;
    }
};

/// Constellation - a group of stars (unordered)
pub const Constellation = struct {
    stars: []const Star,

    pub fn states(self: Constellation) []const Star {
        var result = std.ArrayList(Star).init(std.heap.page_allocator);
        for (self.stars) |s| {
            if (s.is_state) result.append(s) catch {};
        }
        return result.items;
    }

    pub fn actions(self: Constellation) []const Star {
        var result = std.ArrayList(Star).init(std.heap.page_allocator);
        for (self.stars) |s| {
            if (!s.is_state) result.append(s) catch {};
        }
        return result.items;
    }
};

/// High-level expression types
pub const Expr = union(enum) {
    raw: Term,
    call: []const u8, // #identifier
    focus: *const Expr, // @expr
    exec: struct {
        linear: bool, // exec (false) vs fire (true)
        constellation: *const Expr,
    },
    group: []const Expr,
    def: struct {
        name: []const u8,
        value: *const Expr,
    },
    show: []const Expr,
    expect: struct {
        left: *const Expr,
        right: *const Expr,
    },
    match: struct {
        left: *const Expr,
        right: *const Expr,
    },
    use: []const u8, // import file
    constellation: Constellation,
    star: Star,
};

/// Program = list of expressions
pub const Program = []const Expr;

/// Source location for error reporting
pub const SourceLoc = struct {
    line: u32,
    column: u32,
    file: ?[]const u8 = null,
};

/// Located expression wrapper
pub fn Located(comptime T: type) type {
    return struct {
        value: T,
        loc: ?SourceLoc = null,
    };
}

// ============================================================================
// Helper constructors
// ============================================================================

pub fn makeVar(name: []const u8) Term {
    return .{ .variable = .{ .name = name } };
}

pub fn makeIndexedVar(name: []const u8, index: u32) Term {
    return .{ .variable = .{ .name = name, .index = index } };
}

pub fn makeFunc(allocator: std.mem.Allocator, polarity: Polarity, name: []const u8, args: []const Term) !Term {
    const args_copy = try allocator.dupe(Term, args);
    return .{
        .function = .{
            .id = .{ .polarity = polarity, .name = name },
            .args = args_copy,
        },
    };
}

pub fn makeAtom(polarity: Polarity, name: []const u8) Term {
    return .{
        .function = .{
            .id = .{ .polarity = polarity, .name = name },
            .args = &.{},
        },
    };
}

// ============================================================================
// Tests
// ============================================================================

test "polarity compatibility" {
    try std.testing.expect(Polarity.pos.compatible(.neg));
    try std.testing.expect(Polarity.neg.compatible(.pos));
    try std.testing.expect(Polarity.null.compatible(.pos));
    try std.testing.expect(Polarity.null.compatible(.neg));
    try std.testing.expect(!Polarity.pos.compatible(.pos));
    try std.testing.expect(!Polarity.neg.compatible(.neg));
}

test "polarity to GF(3)" {
    try std.testing.expectEqual(@as(i8, 1), Polarity.pos.toGF3());
    try std.testing.expectEqual(@as(i8, -1), Polarity.neg.toGF3());
    try std.testing.expectEqual(@as(i8, 0), Polarity.null.toGF3());
}

test "term equality" {
    const x = makeVar("X");
    const y = makeVar("Y");
    const x2 = makeVar("X");

    try std.testing.expect(x.eql(x2));
    try std.testing.expect(!x.eql(y));
}

test "term contains var" {
    const x = makeVar("X");
    const vid = VarId{ .name = "X" };

    try std.testing.expect(x.containsVar(vid));
    try std.testing.expect(!x.containsVar(.{ .name = "Y" }));
}
