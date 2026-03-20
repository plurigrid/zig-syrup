//! FinSet — Finite Sets and Functions in Zig
//!
//! The category FinSet: objects are finite sets {0, 1, ..., n-1},
//! morphisms are total functions between them.
//!
//! Core operations for StructuredDecompositions:
//!   - pullback(f, g): fiber product {(a,b) | f(a) = g(b)}
//!   - image(f): range of f as a subset embedding
//!   - compose(f, g): f ∘ g
//!   - restrict(f, indices): restrict domain to a subset
//!
//! The pullback in FinSet is set intersection — this is the engine
//! behind adhesion_filter's consistency refinement.
//!
//! All operations use explicit allocators. No hidden allocation.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// A finite set with n elements: {0, 1, ..., n-1}.
/// Objects in the category FinSet.
pub const FinSet = struct {
    size: u32,

    pub fn init(n: u32) FinSet {
        return .{ .size = n };
    }

    pub fn isEmpty(self: FinSet) bool {
        return self.size == 0;
    }

    pub fn eql(self: FinSet, other: FinSet) bool {
        return self.size == other.size;
    }
};

/// A total function f: {0..dom-1} -> {0..cod-1}.
/// Morphisms in the category FinSet.
/// map[i] = f(i) for each i in the domain.
pub const FinFunction = struct {
    domain: u32,
    codomain: u32,
    map: []const u32,

    /// Construct from a pre-built mapping. Caller owns the slice.
    pub fn init(domain: u32, codomain: u32, map: []const u32) FinFunction {
        std.debug.assert(map.len == domain);
        return .{ .domain = domain, .codomain = codomain, .map = map };
    }

    /// Apply the function: f(x)
    pub fn apply(self: FinFunction, x: u32) u32 {
        std.debug.assert(x < self.domain);
        return self.map[x];
    }

    /// Identity function on {0..n-1}
    pub fn identity(allocator: Allocator, n: u32) !FinFunction {
        const map = try allocator.alloc(u32, n);
        for (map, 0..) |*m, i| m.* = @intCast(i);
        return .{ .domain = n, .codomain = n, .map = map };
    }

    /// Free the map slice
    pub fn deinit(self: FinFunction, allocator: Allocator) void {
        allocator.free(self.map);
    }

    pub fn domainSet(self: FinFunction) FinSet {
        return FinSet.init(self.domain);
    }

    pub fn codomainSet(self: FinFunction) FinSet {
        return FinSet.init(self.codomain);
    }
};

/// Result of a pullback computation.
/// Given f: A -> C and g: B -> C, the pullback is:
///   P = {(a, b) | f(a) = g(b)}
///   with projections pi1: P -> A and pi2: P -> B
pub const PullbackCone = struct {
    apex: FinSet,
    leg1: FinFunction, // pi1: P -> A
    leg2: FinFunction, // pi2: P -> B

    pub fn deinit(self: PullbackCone, allocator: Allocator) void {
        self.leg1.deinit(allocator);
        self.leg2.deinit(allocator);
    }
};

/// Result of an image computation.
/// image(f) returns the subset embedding iota: im(f) -> codomain(f)
/// and the surjection onto: domain(f) -> im(f) such that f = iota ∘ onto.
pub const ImageResult = struct {
    image_set: FinSet,
    iota: FinFunction, // inclusion: im(f) ↪ codomain(f)
    onto: FinFunction, // surjection: domain(f) ↠ im(f)

    pub fn deinit(self: ImageResult, allocator: Allocator) void {
        self.iota.deinit(allocator);
        self.onto.deinit(allocator);
    }
};

/// Compute the pullback of f: A -> C and g: B -> C.
/// Returns P with legs pi1: P -> A, pi2: P -> B.
///
/// In FinSet, the pullback is the fiber product:
///   P = {(a, b) ∈ A × B | f(a) = g(b)}
///
/// This is the core of adhesion_filter — it computes the
/// intersection of solution spaces across an adhesion.
pub fn pullback(allocator: Allocator, f: FinFunction, g: FinFunction) !PullbackCone {
    std.debug.assert(f.codomain == g.codomain);

    // Build inverse image of g: for each c in C, store all b with g(b) = c
    const c_size = g.codomain;
    const g_inv = try allocator.alloc(std.ArrayListUnmanaged(u32), c_size);
    defer {
        for (g_inv) |*lst| lst.deinit(allocator);
        allocator.free(g_inv);
    }
    for (g_inv) |*lst| lst.* = .{};

    for (0..g.domain) |b| {
        try g_inv[g.map[b]].append(allocator, @intCast(b));
    }

    // Enumerate pairs (a, b) with f(a) = g(b)
    var pairs_a = std.ArrayListUnmanaged(u32){};
    defer pairs_a.deinit(allocator);
    var pairs_b = std.ArrayListUnmanaged(u32){};
    defer pairs_b.deinit(allocator);

    for (0..f.domain) |a| {
        const c = f.map[a];
        for (g_inv[c].items) |b| {
            try pairs_a.append(allocator, @intCast(a));
            try pairs_b.append(allocator, b);
        }
    }

    const p_size: u32 = @intCast(pairs_a.items.len);
    const leg1_map = try allocator.alloc(u32, p_size);
    const leg2_map = try allocator.alloc(u32, p_size);
    @memcpy(leg1_map, pairs_a.items);
    @memcpy(leg2_map, pairs_b.items);

    return .{
        .apex = FinSet.init(p_size),
        .leg1 = FinFunction.init(p_size, f.domain, leg1_map),
        .leg2 = FinFunction.init(p_size, g.domain, leg2_map),
    };
}

/// Compute the image of a FinFunction f: A -> B.
/// Returns (im(f), iota: im(f) ↪ B, onto: A ↠ im(f)).
///
/// After pullback, adhesion_filter takes the image of each leg
/// to project back down to the bags.
pub fn image(allocator: Allocator, f: FinFunction) !ImageResult {
    // Collect unique values in f's range
    var seen = std.AutoHashMap(u32, u32).init(allocator);
    defer seen.deinit();

    var img_elements = std.ArrayListUnmanaged(u32){};
    defer img_elements.deinit(allocator);

    for (0..f.domain) |i| {
        const val = f.map[i];
        if (!seen.contains(val)) {
            try seen.put(val, @intCast(img_elements.items.len));
            try img_elements.append(allocator, val);
        }
    }

    const img_size: u32 = @intCast(img_elements.items.len);

    // iota: im(f) -> codomain(f), the inclusion
    const iota_map = try allocator.alloc(u32, img_size);
    @memcpy(iota_map, img_elements.items);

    // onto: domain(f) -> im(f), the surjection
    const onto_map = try allocator.alloc(u32, f.domain);
    for (0..f.domain) |i| {
        onto_map[i] = seen.get(f.map[i]).?;
    }

    return .{
        .image_set = FinSet.init(img_size),
        .iota = FinFunction.init(img_size, f.codomain, iota_map),
        .onto = FinFunction.init(f.domain, img_size, onto_map),
    };
}

/// Compose two FinFunctions: (g ∘ f)(x) = g(f(x))
/// f: A -> B, g: B -> C => g ∘ f: A -> C
pub fn compose(allocator: Allocator, f: FinFunction, g: FinFunction) !FinFunction {
    std.debug.assert(f.codomain == g.domain);
    const map = try allocator.alloc(u32, f.domain);
    for (0..f.domain) |i| {
        map[i] = g.map[f.map[i]];
    }
    return FinFunction.init(f.domain, g.codomain, map);
}

/// Restrict a function to a subset of its domain.
/// Given f: A -> B and indices ⊂ A, returns f|_indices: |indices| -> B.
pub fn restrict(allocator: Allocator, f: FinFunction, indices: []const u32) !FinFunction {
    const map = try allocator.alloc(u32, indices.len);
    for (indices, 0..) |idx, i| {
        std.debug.assert(idx < f.domain);
        map[i] = f.map[idx];
    }
    return FinFunction.init(@intCast(indices.len), f.codomain, map);
}

// ============================================================================
// Syrup Serialization
// ============================================================================

const syrup = @import("syrup");

/// Serialize a FinSet to Syrup: <'finset size>
pub fn finsetToSyrup(fs: FinSet, allocator: Allocator) !syrup.Value {
    const label = try allocator.create(syrup.Value);
    label.* = .{ .symbol = "finset" };
    const fields = try allocator.alloc(syrup.Value, 1);
    fields[0] = .{ .integer = @intCast(fs.size) };
    return .{ .record = .{ .label = label, .fields = fields } };
}

/// Serialize a FinFunction to Syrup: <'finfun domain codomain [map...]>
pub fn finfunToSyrup(ff: FinFunction, allocator: Allocator) !syrup.Value {
    const label = try allocator.create(syrup.Value);
    label.* = .{ .symbol = "finfun" };
    const map_vals = try allocator.alloc(syrup.Value, ff.domain);
    for (0..ff.domain) |i| {
        map_vals[i] = .{ .integer = @intCast(ff.map[i]) };
    }
    const fields = try allocator.alloc(syrup.Value, 3);
    fields[0] = .{ .integer = @intCast(ff.domain) };
    fields[1] = .{ .integer = @intCast(ff.codomain) };
    fields[2] = .{ .list = map_vals };
    return .{ .record = .{ .label = label, .fields = fields } };
}

// ============================================================================
// Tests
// ============================================================================

test "FinSet basic" {
    const a = FinSet.init(5);
    try std.testing.expectEqual(@as(u32, 5), a.size);
    try std.testing.expect(!a.isEmpty());
    try std.testing.expect(FinSet.init(0).isEmpty());
    try std.testing.expect(a.eql(FinSet.init(5)));
    try std.testing.expect(!a.eql(FinSet.init(3)));
}

test "FinFunction identity" {
    const allocator = std.testing.allocator;
    const id = try FinFunction.identity(allocator, 5);
    defer id.deinit(allocator);
    for (0..5) |i| {
        try std.testing.expectEqual(@as(u32, @intCast(i)), id.apply(@intCast(i)));
    }
}

test "pullback computes fiber product" {
    const allocator = std.testing.allocator;

    // f: {0,1,2} -> {0,1}, f = [0, 1, 0]
    // g: {0,1} -> {0,1}, g = [0, 1]
    // Pullback: {(a,b) | f(a)=g(b)} = {(0,0),(2,0),(1,1)}
    const f_map = try allocator.alloc(u32, 3);
    defer allocator.free(f_map);
    f_map[0] = 0;
    f_map[1] = 1;
    f_map[2] = 0;
    const f = FinFunction.init(3, 2, f_map);

    const g_map = try allocator.alloc(u32, 2);
    defer allocator.free(g_map);
    g_map[0] = 0;
    g_map[1] = 1;
    const g = FinFunction.init(2, 2, g_map);

    const pb = try pullback(allocator, f, g);
    defer pb.deinit(allocator);

    // P has 3 elements
    try std.testing.expectEqual(@as(u32, 3), pb.apex.size);

    // Verify f(pi1(p)) = g(pi2(p)) for all p in P
    for (0..pb.apex.size) |p| {
        const a = pb.leg1.apply(@intCast(p));
        const b = pb.leg2.apply(@intCast(p));
        try std.testing.expectEqual(f.apply(a), g.apply(b));
    }
}

test "pullback empty when no matches" {
    const allocator = std.testing.allocator;

    // f: {0} -> {0,1}, f = [0]
    // g: {0} -> {0,1}, g = [1]
    // No pairs satisfy f(a) = g(b)
    const f_map = try allocator.alloc(u32, 1);
    defer allocator.free(f_map);
    f_map[0] = 0;
    const f = FinFunction.init(1, 2, f_map);

    const g_map = try allocator.alloc(u32, 1);
    defer allocator.free(g_map);
    g_map[0] = 1;
    const g = FinFunction.init(1, 2, g_map);

    const pb = try pullback(allocator, f, g);
    defer pb.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 0), pb.apex.size);
}

test "image computes range" {
    const allocator = std.testing.allocator;

    // f: {0,1,2,3} -> {0,1,2,3,4}, f = [1, 3, 1, 3]
    // image = {1, 3}, size 2
    const f_map = try allocator.alloc(u32, 4);
    defer allocator.free(f_map);
    f_map[0] = 1;
    f_map[1] = 3;
    f_map[2] = 1;
    f_map[3] = 3;
    const f = FinFunction.init(4, 5, f_map);

    const img = try image(allocator, f);
    defer img.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 2), img.image_set.size);

    // iota maps into the codomain
    for (0..img.image_set.size) |i| {
        try std.testing.expect(img.iota.apply(@intCast(i)) < f.codomain);
    }

    // f = iota ∘ onto
    for (0..f.domain) |x| {
        const via_factor = img.iota.apply(img.onto.apply(@intCast(x)));
        try std.testing.expectEqual(f.apply(@intCast(x)), via_factor);
    }
}

test "compose" {
    const allocator = std.testing.allocator;

    // f: {0,1} -> {0,1,2}, f = [2, 0]
    // g: {0,1,2} -> {0,1}, g = [1, 0, 1]
    // g∘f: {0,1} -> {0,1}, g∘f = [g(2), g(0)] = [1, 1]
    const f_map = try allocator.alloc(u32, 2);
    defer allocator.free(f_map);
    f_map[0] = 2;
    f_map[1] = 0;

    const g_map = try allocator.alloc(u32, 3);
    defer allocator.free(g_map);
    g_map[0] = 1;
    g_map[1] = 0;
    g_map[2] = 1;

    const f = FinFunction.init(2, 3, f_map);
    const g = FinFunction.init(3, 2, g_map);

    const gf = try compose(allocator, f, g);
    defer gf.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 1), gf.apply(0));
    try std.testing.expectEqual(@as(u32, 1), gf.apply(1));
}

test "restrict to subset" {
    const allocator = std.testing.allocator;

    const f_map = try allocator.alloc(u32, 4);
    defer allocator.free(f_map);
    f_map[0] = 10;
    f_map[1] = 20;
    f_map[2] = 30;
    f_map[3] = 40;
    const f = FinFunction.init(4, 50, f_map);

    const indices = [_]u32{ 1, 3 };
    const r = try restrict(allocator, f, &indices);
    defer r.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 2), r.domain);
    try std.testing.expectEqual(@as(u32, 20), r.apply(0));
    try std.testing.expectEqual(@as(u32, 40), r.apply(1));
}

test "syrup roundtrip FinSet" {
    const allocator = std.testing.allocator;
    const fs = FinSet.init(42);
    const val = try finsetToSyrup(fs, allocator);
    defer val.deinitContainers(allocator);

    try std.testing.expectEqual(syrup.Value.record, std.meta.activeTag(val));
    try std.testing.expect(std.mem.eql(u8, val.record.label.symbol, "finset"));
    try std.testing.expectEqual(@as(i64, 42), val.record.fields[0].integer);
}
