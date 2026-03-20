//! Stellogen AST - Core types for the logic-agnostic programming language
//! Based on Girard's transcendental syntax and Lafont's interaction nets
//! Extended with N-ary Faces for Narya bridge

const std = @import("std");

/// Face of a cube - generalizes Polarity to n dimensions
/// Corresponds to Narya's dimension face (dim, endpoint)
pub const Face = struct {
    dim: u8, // Dimension index (0..255)
    endpoint: Endpoint,

    pub const Endpoint = enum(i8) {
        start = 1,   // +1 (pos/producer) - Narya e₀
        end = -1,    // -1 (neg/consumer) - Narya e₁
        interior = 0 // 0 (null/neutral) - Narya degeneracy
    };

    pub fn init(dim: u8, endpoint: Endpoint) Face {
        return .{ .dim = dim, .endpoint = endpoint };
    }

    /// Binary polarity constructor (legacy support, dim 0)
    pub fn fromPolarity(p: LegacyPolarity) Face {
        return switch (p) {
            .pos => init(0, .start),
            .neg => init(0, .end),
            .null => init(0, .interior),
        };
    }

    pub fn opposite(self: Face) Face {
        return .{
            .dim = self.dim,
            .endpoint = switch (self.endpoint) {
                .start => .end,
                .end => .start,
                .interior => .interior,
            },
        };
    }

    pub fn compatible(self: Face, other: Face) bool {
        // Dimensions must match for interaction
        if (self.dim != other.dim) return false;

        // Interior (degeneracy) interacts with everything in same dimension
        if (self.endpoint == .interior or other.endpoint == .interior) return true;

        // Otherwise, endpoints must be opposite (start <-> end)
        // e₀ meets e₁
        return self.endpoint != other.endpoint;
    }

    pub fn toGF3(self: Face) i8 {
        return @intFromEnum(self.endpoint);
    }
};

/// Legacy Polarity for backward compatibility references
pub const LegacyPolarity = enum(i8) {
    pos = 1,
    neg = -1,
    null = 0,
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

/// Function identifier with Face (generalized polarity)
pub const FuncId = struct {
    face: Face,
    name: []const u8,

    pub fn compatible(self: FuncId, other: FuncId) bool {
        return std.mem.eql(u8, self.name, other.name) and
            self.face.compatible(other.face);
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

    pub fn face(self: Self) Face {
        return switch (self) {
            .variable => Face.init(0, .interior), // Variables are neutral
            .function => |f| f.id.face,
        };
    }

    pub fn deinit(self: Self, allocator: std.mem.Allocator) void {
        switch (self) {
            .variable => {},
            .function => |f| {
                for (f.args) |arg| {
                    arg.deinit(allocator);
                }
                allocator.free(f.args);
            },
        }
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
                    // Face equality check
                    if (f.id.face.dim != of.id.face.dim) return false;
                    if (f.id.face.endpoint != of.id.face.endpoint) return false;
                    
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

/// Ray = Term (with face implicit in function identifier)
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

    pub fn deinit(self: Star, allocator: std.mem.Allocator) void {
        for (self.content) |ray| ray.deinit(allocator);
        allocator.free(self.content);
        allocator.free(self.bans);
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

    pub fn deinit(self: Constellation, allocator: std.mem.Allocator) void {
        for (self.stars) |s| s.deinit(allocator);
        allocator.free(self.stars);
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

pub fn makeFunc(allocator: std.mem.Allocator, face: Face, name: []const u8, args: []const Term) !Term {
    const args_copy = try allocator.dupe(Term, args);
    return .{
        .function = .{
            .id = .{ .face = face, .name = name },
            .args = args_copy,
        },
    };
}

pub fn makeAtom(face: Face, name: []const u8) Term {
    return .{
        .function = .{
            .id = .{ .face = face, .name = name },
            .args = &.{},
        },
    };
}

// ============================================================================
// Tests
// ============================================================================

test "Face compatibility" {
    // Dim 0
    const start0 = Face.init(0, .start); // +1
    const end0 = Face.init(0, .end);     // -1
    const int0 = Face.init(0, .interior); // 0

    // Dim 1
    const start1 = Face.init(1, .start);
    const end1 = Face.init(1, .end);

    // Compatible pairs (Dim 0)
    try std.testing.expect(start0.compatible(end0));
    try std.testing.expect(end0.compatible(start0));
    try std.testing.expect(int0.compatible(start0));
    try std.testing.expect(int0.compatible(end0));
    
    // Incompatible pairs (Dim 0)
    try std.testing.expect(!start0.compatible(start0));
    try std.testing.expect(!end0.compatible(end0));

    // Compatible pairs (Dim 1)
    try std.testing.expect(start1.compatible(end1));

    // Cross-dimension incompatibility
    try std.testing.expect(!start0.compatible(start1));
    try std.testing.expect(!start0.compatible(end1));
    // Even neutral/interior shouldn't cross dimensions unless we want universal neutral?
    // User spec: "self.dim == other.dim"
    try std.testing.expect(!int0.compatible(start1));
}

test "Face to GF(3)" {
    try std.testing.expectEqual(@as(i8, 1), Face.init(0, .start).toGF3());
    try std.testing.expectEqual(@as(i8, -1), Face.init(0, .end).toGF3());
    try std.testing.expectEqual(@as(i8, 0), Face.init(0, .interior).toGF3());
}

test "Legacy Polarity conversion" {
    const pos = Face.fromPolarity(.pos);
    try std.testing.expectEqual(@as(u8, 0), pos.dim);
    try std.testing.expectEqual(Face.Endpoint.start, pos.endpoint);
}

test "term equality with Face" {
    const x = makeVar("X");
    const y = makeVar("Y");
    const x2 = makeVar("X");

    try std.testing.expect(x.eql(x2));
    try std.testing.expect(!x.eql(y));
    
    // Test function equality with faces
    const f1 = makeAtom(Face.init(0, .start), "f");
    const f2 = makeAtom(Face.init(0, .start), "f");
    const f3 = makeAtom(Face.init(1, .start), "f"); // Different dim
    const f4 = makeAtom(Face.init(0, .end), "f");   // Different endpoint

    try std.testing.expect(f1.eql(f2));
    try std.testing.expect(!f1.eql(f3));
    try std.testing.expect(!f1.eql(f4));
}
