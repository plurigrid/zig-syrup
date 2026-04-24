//! Concrete polynomial functors with explicit module action composition (triangleleft).
//!
//! A concrete polynomial is represented as a finite list of position arities:
//!   P(X) = sum_{i in positions} X^{arity[i]}
//!
//! Composition (triangleleft):
//!   (P triangleleft Q)(X) = sum_{p in P.pos} product_{d in P.dir(p)} Q(X)
//!
//! For a position with arity `a`, each composed position corresponds to a
//! function [0..a) -> Q.pos. Its resulting arity is the sum of selected
//! Q-direction counts.

const std = @import("std");

const Allocator = std.mem.Allocator;

pub const PolyError = error{
    InvalidPolynomial,
    ArithmeticOverflow,
    PositionOutOfRange,
    OutOfMemory,
};

/// Borrowed polynomial view.
pub const Poly = struct {
    name: []const u8,
    arities: []const usize,

    pub fn isValid(self: Poly) bool {
        return self.arities.len > 0;
    }

    pub fn positionCount(self: Poly) usize {
        return self.arities.len;
    }

    pub fn directionsAt(self: Poly, position: usize) PolyError!usize {
        if (position >= self.arities.len) return error.PositionOutOfRange;
        return self.arities[position];
    }

    pub fn eql(a: Poly, b: Poly) bool {
        return std.mem.eql(usize, a.arities, b.arities);
    }
};

/// Owned polynomial value produced by constructors/composition.
pub const OwnedPoly = struct {
    name: []const u8,
    arities: []usize,
    allocator: Allocator,

    pub fn asPoly(self: *const OwnedPoly) Poly {
        return .{
            .name = self.name,
            .arities = self.arities,
        };
    }

    pub fn deinit(self: *OwnedPoly) void {
        self.allocator.free(self.arities);
        self.* = undefined;
    }
};

/// Identity polynomial y = X.
/// One position with one direction.
pub const y = Poly{
    .name = "y",
    .arities = &[_]usize{1},
};

fn checkedAdd(a: usize, b: usize) PolyError!usize {
    const sum, const overflow = @addWithOverflow(a, b);
    if (overflow != 0) return error.ArithmeticOverflow;
    return sum;
}

fn checkedMul(a: usize, b: usize) PolyError!usize {
    const product, const overflow = @mulWithOverflow(a, b);
    if (overflow != 0) return error.ArithmeticOverflow;
    return product;
}

fn checkedPow(base: usize, exp: usize) PolyError!usize {
    var acc: usize = 1;
    var i: usize = 0;
    while (i < exp) : (i += 1) {
        acc = try checkedMul(acc, base);
    }
    return acc;
}

/// Count how many positions result from composing a single p-position arity.
fn composedPositionCountForArity(q_positions: usize, p_arity: usize) PolyError!usize {
    // Number of functions [0..p_arity) -> [0..q_positions) = q_positions^p_arity.
    return checkedPow(q_positions, p_arity);
}

/// Enumerate composed arities for a single p-position with arity `p_arity`.
fn fillComposedAritiesForPosition(
    out: []usize,
    offset: usize,
    q: Poly,
    p_arity: usize,
) PolyError!void {
    const q_positions = q.positionCount();
    const count = try composedPositionCountForArity(q_positions, p_arity);

    // Each index encodes one function in base-|Q.pos|.
    var encoded: usize = 0;
    while (encoded < count) : (encoded += 1) {
        var code = encoded;
        var dir_sum: usize = 0;

        var d: usize = 0;
        while (d < p_arity) : (d += 1) {
            const q_pos = code % q_positions;
            code /= q_positions;
            dir_sum = try checkedAdd(dir_sum, q.arities[q_pos]);
        }

        out[offset + encoded] = dir_sum;
    }
}

/// Composition P triangleleft Q.
pub fn compose(allocator: Allocator, p: Poly, q: Poly) PolyError!OwnedPoly {
    if (!p.isValid() or !q.isValid()) return error.InvalidPolynomial;

    const q_positions = q.positionCount();
    var total_positions: usize = 0;
    for (p.arities) |p_arity| {
        const count = try composedPositionCountForArity(q_positions, p_arity);
        total_positions = try checkedAdd(total_positions, count);
    }

    const arities = try allocator.alloc(usize, total_positions);
    errdefer allocator.free(arities);

    var offset: usize = 0;
    for (p.arities) |p_arity| {
        const count = try composedPositionCountForArity(q_positions, p_arity);
        try fillComposedAritiesForPosition(arities, offset, q, p_arity);
        offset += count;
    }

    return .{
        .name = "triangleleft",
        .arities = arities,
        .allocator = allocator,
    };
}

/// Alias for composition using categorical naming.
pub fn triangleleft(allocator: Allocator, p: Poly, q: Poly) PolyError!OwnedPoly {
    return compose(allocator, p, q);
}

/// Dirichlet tensor P (x) Q.
/// (P (x) Q).pos = P.pos x Q.pos; (P (x) Q).dir(pp, qp) = P.dir(pp) * Q.dir(qp).
pub fn tensor(allocator: Allocator, p: Poly, q: Poly) PolyError!OwnedPoly {
    if (!p.isValid() or !q.isValid()) return error.InvalidPolynomial;

    const total_positions = try checkedMul(p.positionCount(), q.positionCount());
    const arities = try allocator.alloc(usize, total_positions);
    errdefer allocator.free(arities);

    var idx: usize = 0;
    for (p.arities) |p_arity| {
        for (q.arities) |q_arity| {
            arities[idx] = try checkedMul(p_arity, q_arity);
            idx += 1;
        }
    }

    return .{
        .name = "tensor",
        .arities = arities,
        .allocator = allocator,
    };
}

test "left unit: y triangleleft p == p" {
    const allocator = std.testing.allocator;

    const p = Poly{
        .name = "p",
        .arities = &[_]usize{ 0, 2, 4, 1 },
    };

    var left = try triangleleft(allocator, y, p);
    defer left.deinit();

    try std.testing.expect(Poly.eql(left.asPoly(), p));
}

test "right unit: p triangleleft y == p" {
    const allocator = std.testing.allocator;

    const p = Poly{
        .name = "p",
        .arities = &[_]usize{ 3, 1, 0, 2 },
    };

    var right = try triangleleft(allocator, p, y);
    defer right.deinit();

    try std.testing.expect(Poly.eql(right.asPoly(), p));
}

test "tensor left unit: y (x) p == p" {
    const allocator = std.testing.allocator;

    const p = Poly{
        .name = "p",
        .arities = &[_]usize{ 0, 2, 4, 1 },
    };

    var left = try tensor(allocator, y, p);
    defer left.deinit();

    try std.testing.expect(Poly.eql(left.asPoly(), p));
}

test "tensor right unit: p (x) y == p" {
    const allocator = std.testing.allocator;

    const p = Poly{
        .name = "p",
        .arities = &[_]usize{ 3, 1, 0, 2 },
    };

    var right = try tensor(allocator, p, y);
    defer right.deinit();

    try std.testing.expect(Poly.eql(right.asPoly(), p));
}

test "tensor arity product is concrete" {
    const allocator = std.testing.allocator;

    const p = Poly{
        .name = "p",
        .arities = &[_]usize{ 2, 3 },
    };
    const q = Poly{
        .name = "q",
        .arities = &[_]usize{ 1, 4 },
    };

    var out = try tensor(allocator, p, q);
    defer out.deinit();

    // p.pos=2, q.pos=2 => 4 positions, each arity = p_arity * q_arity.
    // (2,1)=2, (2,4)=8, (3,1)=3, (3,4)=12
    try std.testing.expectEqual(@as(usize, 4), out.arities.len);
    try std.testing.expectEqualSlices(usize, &[_]usize{ 2, 8, 3, 12 }, out.arities);
}

test "tensor is strictly associative in arity order: (p (x) q) (x) r == p (x) (q (x) r)" {
    const allocator = std.testing.allocator;

    const p = Poly{ .name = "p", .arities = &[_]usize{ 2, 3 } };
    const q = Poly{ .name = "q", .arities = &[_]usize{ 1, 4 } };
    const r = Poly{ .name = "r", .arities = &[_]usize{ 5, 1, 2 } };

    var pq = try tensor(allocator, p, q);
    defer pq.deinit();
    var left = try tensor(allocator, pq.asPoly(), r);
    defer left.deinit();

    var qr = try tensor(allocator, q, r);
    defer qr.deinit();
    var right = try tensor(allocator, p, qr.asPoly());
    defer right.deinit();

    // Both nested-loop enumerations walk (pp, qp, rp) in the same lex order, so
    // associativity holds byte-for-byte — not just up to iso.
    try std.testing.expect(Poly.eql(left.asPoly(), right.asPoly()));
    try std.testing.expectEqual(@as(usize, 12), left.arities.len);
}

test "triangleleft is associative up to multiset iso: (p <| q) <| r ~= p <| (q <| r)" {
    const allocator = std.testing.allocator;

    const p = Poly{ .name = "p", .arities = &[_]usize{ 2, 1 } };
    const q = Poly{ .name = "q", .arities = &[_]usize{ 1, 2 } };
    const r = Poly{ .name = "r", .arities = &[_]usize{ 1, 1 } };

    var pq = try triangleleft(allocator, p, q);
    defer pq.deinit();
    var left = try triangleleft(allocator, pq.asPoly(), r);
    defer left.deinit();

    var qr = try triangleleft(allocator, q, r);
    defer qr.deinit();
    var right = try triangleleft(allocator, p, qr.asPoly());
    defer right.deinit();

    // ◁ associativity is strict in the category of polynomial functors, but the
    // concrete function-enumeration order in `compose` differs between left-
    // and right-association. Check equality at the multiset-of-arities level.
    try std.testing.expectEqual(left.arities.len, right.arities.len);

    const left_sorted = try allocator.dupe(usize, left.arities);
    defer allocator.free(left_sorted);
    const right_sorted = try allocator.dupe(usize, right.arities);
    defer allocator.free(right_sorted);
    std.mem.sort(usize, left_sorted, {}, std.sort.asc(usize));
    std.mem.sort(usize, right_sorted, {}, std.sort.asc(usize));
    try std.testing.expectEqualSlices(usize, left_sorted, right_sorted);
}

test "tensor total-direction distribution: total(p (x) q) == total(p) * total(q)" {
    const allocator = std.testing.allocator;

    const p = Poly{ .name = "p", .arities = &[_]usize{ 2, 3, 1 } };
    const q = Poly{ .name = "q", .arities = &[_]usize{ 4, 2 } };

    var pq = try tensor(allocator, p, q);
    defer pq.deinit();

    var p_total: usize = 0;
    for (p.arities) |a| p_total += a;
    var q_total: usize = 0;
    for (q.arities) |a| q_total += a;
    var pq_total: usize = 0;
    for (pq.arities) |a| pq_total += a;

    try std.testing.expectEqual(p_total * q_total, pq_total);
}

test "triangleleft arity expansion is concrete and deterministic" {
    const allocator = std.testing.allocator;

    const p = Poly{
        .name = "p",
        .arities = &[_]usize{2},
    };
    const q = Poly{
        .name = "q",
        .arities = &[_]usize{ 1, 3 },
    };

    var composed = try triangleleft(allocator, p, q);
    defer composed.deinit();

    // One p-position with arity 2 => |Q.pos|^2 = 4 positions.
    // Encoded maps (base 2 over two holes):
    // 00 -> 1+1 = 2
    // 01 -> 3+1 = 4
    // 10 -> 1+3 = 4
    // 11 -> 3+3 = 6
    try std.testing.expectEqual(@as(usize, 4), composed.arities.len);
    try std.testing.expectEqualSlices(usize, &[_]usize{ 2, 4, 4, 6 }, composed.arities);
}
