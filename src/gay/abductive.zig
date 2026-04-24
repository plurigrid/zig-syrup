// abductive.zig: Abductive testing for world teleportation
// Zig translation of Gay.jl's abductive.jl
//
// Given observed world colors, reason backwards to infer:
// - Source invader ID and seed
// - Derangement permutation applied
// - Tropical blend parameter t

const std = @import("std");
const math = std.math;
const splitmix = @import("splitmix.zig");

const Color = splitmix.Color;
const GAY_SEED = splitmix.GAY_SEED;
const GOLDEN = splitmix.GOLDEN;
const splitmix64 = splitmix.splitmix64;
const GayRng = splitmix.GayRng;
const colorAt = splitmix.colorAt;

// ============================================================================
// Color distance metrics
// ============================================================================

/// Euclidean distance in RGB space.
pub fn colorDistance(c1: Color, c2: Color) f64 {
    const dr = c1.r - c2.r;
    const dg = c1.g - c2.g;
    const db = c1.b - c2.b;
    return @sqrt(dr * dr + dg * dg + db * db);
}

/// Weighted distance approximating human perception (green-sensitive).
pub fn colorDistancePerceptual(c1: Color, c2: Color) f64 {
    const dr = c1.r - c2.r;
    const dg = c1.g - c2.g;
    const db = c1.b - c2.b;
    const r_mean = (c1.r + c2.r) / 2.0;
    return @sqrt((2.0 + r_mean) * dr * dr + 4.0 * dg * dg + (3.0 - r_mean) * db * db);
}

// ============================================================================
// Derangements: permutations with no fixed points
// ============================================================================

const Derangement = [3]u2;

/// The two cyclic derangements of 3 elements (no fixed points).
const DERANGEMENTS_3 = [2]Derangement{
    .{ 1, 2, 0 }, // R->G, G->B, B->R (cyclic left)
    .{ 2, 0, 1 }, // R->B, G->R, B->G (cyclic right)
};

/// Apply a derangement to permute RGB channels.
pub fn applyDerangement(c: Color, idx: u1) Color {
    const channels = [3]f64{ c.r, c.g, c.b };
    const perm = DERANGEMENTS_3[idx];
    return .{
        .r = channels[perm[0]],
        .g = channels[perm[1]],
        .b = channels[perm[2]],
    };
}

/// Invert a derangement. For cyclic permutations, apply the other one.
pub fn invertDerangement(c: Color, idx: u1) Color {
    return applyDerangement(c, 1 - idx);
}

// ============================================================================
// Tropical blend: min-plus semiring color interpolation
// ============================================================================

/// Tropical (min-plus) blend. Creates hard edges unlike linear interpolation.
pub fn tropicalBlend(c1: Color, c2: Color, t: f64) Color {
    const eps = 1e-10;
    const tr1 = -@log(@max(c1.r, eps));
    const tr2 = -@log(@max(c2.r, eps));
    const tg1 = -@log(@max(c1.g, eps));
    const tg2 = -@log(@max(c2.g, eps));
    const tb1 = -@log(@max(c1.b, eps));
    const tb2 = -@log(@max(c2.b, eps));

    const blend_r = @min(tr1 + t, tr2 + (1.0 - t));
    const blend_g = @min(tg1 + t, tg2 + (1.0 - t));
    const blend_b = @min(tb1 + t, tb2 + (1.0 - t));

    return .{
        .r = @exp(-blend_r),
        .g = @exp(-blend_g),
        .b = @exp(-blend_b),
    };
}

// ============================================================================
// Hash color: deterministic color from (id, seed) pair
// ============================================================================

/// Generate a color from an (id, seed) pair via splitmix64 mixing.
fn hashColor(id: u64, seed: u64) Color {
    const h = splitmix64(id ^ seed);
    const mask21: u64 = (1 << 21) - 1;
    const scale = 1.0 / @as(f64, @floatFromInt(mask21));
    return .{
        .r = @as(f64, @floatFromInt(h & mask21)) * scale,
        .g = @as(f64, @floatFromInt((h >> 21) & mask21)) * scale,
        .b = @as(f64, @floatFromInt((h >> 42) & mask21)) * scale,
    };
}

// ============================================================================
// Teleportation simulation
// ============================================================================

pub const TeleportationResult = struct {
    id: u64,
    seed: u64,
    source: Color,
    derangement: u1,
    deranged: Color,
    world_base: Color,
    tropical_t: f64,
    world: Color,
    spin: i2, // +1 or -1
};

/// Forward-simulate the full teleportation path for an invader.
pub fn simulateTeleportation(id: u64, seed: u64) TeleportationResult {
    const source = hashColor(id, seed);
    const derange_idx: u1 = @intCast(id % 2);
    const deranged = applyDerangement(source, derange_idx);

    const world_seed = splitmix64(seed ^ (id *% GOLDEN));
    const world_base = hashColor(world_seed & 0xFFFFFF, seed);

    const t: f64 = @as(f64, @floatFromInt(id % 100)) / 100.0;
    const world = tropicalBlend(deranged, world_base, t);

    const spin: i2 = if (((id ^ (id >> 16)) & 1) == 0) 1 else -1;

    return .{
        .id = id,
        .seed = seed,
        .source = source,
        .derangement = derange_idx,
        .deranged = deranged,
        .world_base = world_base,
        .tropical_t = t,
        .world = world,
        .spin = spin,
    };
}

// ============================================================================
// Abductive hypothesis
// ============================================================================

pub const AbductiveHypothesis = struct {
    id: u64,
    seed: u64,
    derangement_idx: u1,
    tropical_t: f64,
    confidence: f64,
    source_color: Color,
    predicted_world: Color,
};

// ============================================================================
// Abductive inference: reason backwards from observed world color
// ============================================================================

/// Given an observed world color, find the most likely invader IDs.
/// Returns hypotheses sorted by confidence (descending). Caller owns returned slice.
pub fn abduceInvader(
    allocator: std.mem.Allocator,
    observed: Color,
    seed: u64,
    search_start: u64,
    search_end: u64,
    top_k: usize,
) ![]AbductiveHypothesis {
    var list: std.ArrayList(AbductiveHypothesis) = .empty;
    defer list.deinit(allocator);

    var id = search_start;
    while (id <= search_end) : (id += 1) {
        if (id == 0) continue;
        const sim = simulateTeleportation(id, seed);
        const dist = colorDistance(observed, sim.world);
        const confidence = 1.0 / (1.0 + dist);

        try list.append(allocator, .{
            .id = sim.id,
            .seed = seed,
            .derangement_idx = sim.derangement,
            .tropical_t = sim.tropical_t,
            .confidence = confidence,
            .source_color = sim.source,
            .predicted_world = sim.world,
        });
    }

    // Sort by confidence descending
    const items = list.items;
    std.mem.sort(AbductiveHypothesis, items, {}, struct {
        fn cmp(_: void, a: AbductiveHypothesis, b: AbductiveHypothesis) bool {
            return a.confidence > b.confidence;
        }
    }.cmp);

    const count = @min(top_k, items.len);
    const result = try allocator.alloc(AbductiveHypothesis, count);
    @memcpy(result, items[0..count]);
    return result;
}

/// Given an observed source color, find the exact invader ID.
pub fn abduceFromSource(
    observed: Color,
    seed: u64,
    search_start: u64,
    search_end: u64,
    tolerance: f64,
) ?u64 {
    var id = search_start;
    while (id <= search_end) : (id += 1) {
        if (id == 0) continue;
        const source = hashColor(id, seed);
        if (colorDistance(observed, source) < tolerance) {
            return id;
        }
    }
    return null;
}

// ============================================================================
// Teleportation property tests
// ============================================================================

pub const TeleportationProperty = enum {
    spi_determinism,
    derangement_bijectivity,
    tropical_idempotence,
    spin_consistency,
};

/// Test whether a teleportation satisfies a given property.
pub fn testProperty(prop: TeleportationProperty, id: u64, seed: u64) bool {
    switch (prop) {
        .spi_determinism => {
            const sim1 = simulateTeleportation(id, seed);
            const sim2 = simulateTeleportation(id, seed);
            return colorDistance(sim1.world, sim2.world) < 1e-15;
        },
        .derangement_bijectivity => {
            const sim = simulateTeleportation(id, seed);
            const recovered = invertDerangement(sim.deranged, sim.derangement);
            return colorDistance(sim.source, recovered) < 1e-10;
        },
        .tropical_idempotence => {
            const sim = simulateTeleportation(id, seed);
            const blend_0 = tropicalBlend(sim.deranged, sim.deranged, 0.0);
            const blend_1 = tropicalBlend(sim.deranged, sim.deranged, 1.0);
            return colorDistance(blend_0, blend_1) < 0.5;
        },
        .spin_consistency => {
            const sim = simulateTeleportation(id, seed);
            const expected_spin: i2 = if (((id ^ (id >> 16)) & 1) == 0) 1 else -1;
            return sim.spin == expected_spin;
        },
    }
}

/// Test all properties for an invader. Returns true if all pass.
pub fn testAllProperties(id: u64, seed: u64) bool {
    inline for (std.meta.fields(TeleportationProperty)) |field| {
        const prop: TeleportationProperty = @enumFromInt(field.value);
        if (!testProperty(prop, id, seed)) return false;
    }
    return true;
}

// ============================================================================
// World Navigator: stateful exploration of invader-world space
// ============================================================================

pub const WorldNavigator = struct {
    allocator: std.mem.Allocator,
    current_id: u64,
    seed: u64,
    history: std.ArrayList(u64),

    pub fn init(allocator: std.mem.Allocator, seed: u64) WorldNavigator {
        return .{
            .allocator = allocator,
            .current_id = 1,
            .seed = seed,
            .history = .empty,
        };
    }

    pub fn deinit(self: *WorldNavigator) void {
        self.history.deinit(self.allocator);
    }

    /// Teleport to a specific invader's world. Records history.
    pub fn teleport(self: *WorldNavigator, id: u64) !TeleportationResult {
        try self.history.append(self.allocator, self.current_id);
        self.current_id = id;
        return self.currentWorld();
    }

    /// Return to previous world.
    pub fn back(self: *WorldNavigator) !TeleportationResult {
        self.current_id = self.history.pop().?;
        return self.currentWorld();
    }

    /// Get current world simulation.
    pub fn currentWorld(self: *const WorldNavigator) TeleportationResult {
        return simulateTeleportation(self.current_id, self.seed);
    }
};

// ============================================================================
// Abductive test result
// ============================================================================

pub const AbductiveTestResult = struct {
    property: TeleportationProperty,
    passed: bool,
    id: u64,
    seed: u64,
};

/// Abductive roundtrip test: can we abduce an invader from its own world color?
pub fn abductiveRoundtripTest(allocator: std.mem.Allocator, id: u64, seed: u64) !bool {
    const sim = simulateTeleportation(id, seed);
    const start = if (id > 100) id - 100 else 1;
    const end = id + 100;
    const hypotheses = try abduceInvader(allocator, sim.world, seed, start, end, 1);
    defer allocator.free(hypotheses);

    if (hypotheses.len == 0) return false;
    return hypotheses[0].id == id;
}

// ============================================================================
// Tests
// ============================================================================

test "color distance basic" {
    const black = Color{ .r = 0, .g = 0, .b = 0 };
    const white = Color{ .r = 1, .g = 1, .b = 1 };
    const d = colorDistance(black, white);
    try std.testing.expectApproxEqAbs(d, @sqrt(3.0), 0.001);
}

test "color distance self is zero" {
    const c = Color{ .r = 0.5, .g = 0.3, .b = 0.7 };
    try std.testing.expectApproxEqAbs(colorDistance(c, c), 0.0, 1e-15);
}

test "derangement no fixed points" {
    const c = Color{ .r = 0.1, .g = 0.5, .b = 0.9 };
    for (0..2) |idx| {
        const d = applyDerangement(c, @intCast(idx));
        // No channel maps to itself
        try std.testing.expect(@abs(d.r - c.r) > 0.01 or @abs(d.g - c.g) > 0.01 or @abs(d.b - c.b) > 0.01);
    }
}

test "derangement invertibility" {
    const c = Color{ .r = 0.2, .g = 0.4, .b = 0.8 };
    for (0..2) |idx| {
        const i: u1 = @intCast(idx);
        const d = applyDerangement(c, i);
        const recovered = invertDerangement(d, i);
        try std.testing.expectApproxEqAbs(c.r, recovered.r, 1e-10);
        try std.testing.expectApproxEqAbs(c.g, recovered.g, 1e-10);
        try std.testing.expectApproxEqAbs(c.b, recovered.b, 1e-10);
    }
}

test "tropical blend self-blend" {
    const c = Color{ .r = 0.5, .g = 0.3, .b = 0.7 };
    const b0 = tropicalBlend(c, c, 0.0);
    const b1 = tropicalBlend(c, c, 1.0);
    try std.testing.expect(colorDistance(b0, b1) < 0.5);
}

test "simulate teleportation determinism" {
    const sim1 = simulateTeleportation(42, GAY_SEED);
    const sim2 = simulateTeleportation(42, GAY_SEED);
    try std.testing.expectApproxEqAbs(sim1.world.r, sim2.world.r, 1e-15);
    try std.testing.expectApproxEqAbs(sim1.world.g, sim2.world.g, 1e-15);
    try std.testing.expectApproxEqAbs(sim1.world.b, sim2.world.b, 1e-15);
}

test "all properties hold for sample invaders" {
    const ids = [_]u64{ 1, 7, 42, 100, 999, 12345 };
    for (ids) |id| {
        try std.testing.expect(testAllProperties(id, GAY_SEED));
    }
}

test "spi determinism property" {
    var i: u64 = 1;
    while (i <= 50) : (i += 1) {
        try std.testing.expect(testProperty(.spi_determinism, i, GAY_SEED));
    }
}

test "derangement bijectivity property" {
    var i: u64 = 1;
    while (i <= 50) : (i += 1) {
        try std.testing.expect(testProperty(.derangement_bijectivity, i, GAY_SEED));
    }
}

test "spin consistency property" {
    var i: u64 = 1;
    while (i <= 50) : (i += 1) {
        try std.testing.expect(testProperty(.spin_consistency, i, GAY_SEED));
    }
}

test "abduce from source exact match" {
    const source = hashColor(42, GAY_SEED);
    const found = abduceFromSource(source, GAY_SEED, 1, 100, 1e-6);
    try std.testing.expectEqual(found, 42);
}

test "abduce invader roundtrip" {
    const allocator = std.testing.allocator;
    try std.testing.expect(try abductiveRoundtripTest(allocator, 42, GAY_SEED));
    try std.testing.expect(try abductiveRoundtripTest(allocator, 1, GAY_SEED));
    try std.testing.expect(try abductiveRoundtripTest(allocator, 99, GAY_SEED));
}

test "world navigator teleport and back" {
    var nav = WorldNavigator.init(std.testing.allocator, GAY_SEED);
    defer nav.deinit();

    const w1 = nav.currentWorld();
    try std.testing.expectEqual(w1.id, 1);

    _ = try nav.teleport(42);
    const w2 = nav.currentWorld();
    try std.testing.expectEqual(w2.id, 42);

    _ = try nav.back();
    const w3 = nav.currentWorld();
    try std.testing.expectEqual(w3.id, 1);
}

test "different seeds produce different worlds" {
    const sim1 = simulateTeleportation(42, GAY_SEED);
    const sim2 = simulateTeleportation(42, GAY_SEED ^ 0xFF);
    try std.testing.expect(colorDistance(sim1.world, sim2.world) > 0.01);
}

test "tropical blend boundary values" {
    const c1 = Color{ .r = 0.2, .g = 0.4, .b = 0.6 };
    const c2 = Color{ .r = 0.8, .g = 0.6, .b = 0.4 };
    // t=0 should favor c2 (second term has +0), t=1 should favor c1
    const b0 = tropicalBlend(c1, c2, 0.0);
    const b1 = tropicalBlend(c1, c2, 1.0);
    try std.testing.expect(b0.r > 0.0 and b0.r < 1.0);
    try std.testing.expect(b1.r > 0.0 and b1.r < 1.0);
}

test "perceptual distance differs from euclidean" {
    const c1 = Color{ .r = 0.5, .g = 0.0, .b = 0.0 };
    const c2 = Color{ .r = 0.0, .g = 0.5, .b = 0.0 };
    const d_euc = colorDistance(c1, c2);
    const d_per = colorDistancePerceptual(c1, c2);
    // Perceptual weights green more, so distances should differ
    try std.testing.expect(@abs(d_euc - d_per) > 0.01);
}
