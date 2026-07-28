//! World Morphism — 69-variety World→World' arrows
//!
//! 69 morphism types organized into 23/23/23 GF(3)-balanced buckets:
//!   MINUS  (-1): 23 validators   — destructive, contracting, verifying
//!   ERGODIC (0): 23 coordinators — equilibrating, mediating, routing
//!   PLUS   (+1): 23 generators   — constructive, expanding, creating
//!
//! Each morphism is an arrow f: WorldState → WorldState' that transforms
//! world state according to its variety's semantics. The GF(3) trit of the
//! morphism is conserved: applying a MINUS morphism followed by a PLUS
//! morphism yields an ERGODIC net effect.
//!
//! 23 × 3 = 69: the partition is clean, maximally oppositional.
//! 23 is the 9th prime, a Monster supersingular prime (23 | |M|),
//! and the number of "officially weird" objects in the Monster group.
//!
//! Composition: f ∘ g has trit = trit(f) + trit(g) in GF(3).
//! Identity morphism: variety 0 (Identity) has trit ERGODIC.
//!
//! Integration points:
//!   WorldState (world.zig)     — source/target of morphisms
//!   Trit (splitmix_trit.zig)   — GF(3) classification
//!   Quale (monster_walk.zig)   — shard-routed morphism dispatch
//!   Bisimulation (bisimulation.zig) — morphisms as LTS transitions

const std = @import("std");
const Allocator = std.mem.Allocator;
const world_mod = @import("world.zig");
const WorldState = world_mod.WorldState;
const World = world_mod.World;

/// GF(3) trit for morphism classification.
pub const Trit = enum(i8) {
    minus = -1,
    ergodic = 0,
    plus = 1,

    pub fn add(a: Trit, b: Trit) Trit {
        const sum = @as(i8, @backingInt(a)) + @as(i8, @backingInt(b));
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

    pub fn name(self: Trit) []const u8 {
        return switch (self) {
            .minus => "MINUS",
            .ergodic => "ERGODIC",
            .plus => "PLUS",
        };
    }
};

/// 69 morphism varieties.
/// Indices 0-22: MINUS (-1) validators
/// Indices 23-45: ERGODIC (0) coordinators
/// Indices 46-68: PLUS (+1) generators
pub const Variety = enum(u8) {
    // ====== MINUS (-1): Validators — destructive, contracting, verifying ======
    // 0-22
    Annihilate = 0,
    Collapse,
    Prune,
    Decay,
    Absorb,
    Compress,
    Filter,
    Reduce,
    Distill,
    Extract,
    Negate,
    Invalidate,
    Revoke,
    Forget,
    Erode,
    Consume,
    Dissolve,
    Retract,
    Censor,
    Quarantine,
    Freeze,
    Seal,
    Audit,

    // ====== ERGODIC (0): Coordinators — equilibrating, mediating, routing ======
    // 23-45
    Identity,
    Permute,
    Rotate,
    Mirror,
    Translate,
    Balance,
    Normalize,
    Synchronize,
    Mediate,
    Reconcile,
    Arbitrate,
    Route,
    Bridge,
    Relay,
    Witness,
    Notarize,
    Checkpoint,
    Snapshot,
    Replicate,
    Shard,
    Reindex,
    Calibrate,
    Equilibrate,

    // ====== PLUS (+1): Generators — constructive, expanding, creating ======
    // 46-68
    Create,
    Expand,
    Fork,
    Spawn,
    Grow,
    Synthesize,
    Compose,
    Merge,
    Amplify,
    Enrich,
    Empower,
    Unlock,
    Ignite,
    Bloom,
    Evolve,
    Mutate,
    Bifurcate,
    Crystallize,
    Propagate,
    Radiate,
    Catalyze,
    Transfigure,
    Transcend,

    pub fn index(self: Variety) u8 {
        return @backingInt(self);
    }

    pub fn trit(self: Variety) Trit {
        const idx = self.index();
        if (idx < 23) return .minus;
        if (idx < 46) return .ergodic;
        return .plus;
    }

    pub fn bucket(self: Variety) u8 {
        const idx = self.index();
        if (idx < 23) return 0;
        if (idx < 46) return 1;
        return 2;
    }

    /// Position within the bucket (0-22).
    pub fn bucketOffset(self: Variety) u8 {
        const idx = self.index();
        if (idx < 23) return idx;
        if (idx < 46) return idx - 23;
        return idx - 46;
    }

    pub fn name(self: Variety) []const u8 {
        return @tagName(self);
    }

    /// From raw index 0-68.
    pub fn fromIndex(idx: u8) !Variety {
        if (idx > 68) return error.InvalidVariety;
        return @fromBackingInt(@intCast(idx));
    }

    /// Opposite variety: same bucket offset, opposite trit bucket.
    /// MINUS(n) ↔ PLUS(n), ERGODIC(n) ↔ ERGODIC(n) (self-dual).
    pub fn opposite(self: Variety) Variety {
        const offset = self.bucketOffset();
        return switch (self.trit()) {
            .minus => @fromBackingInt(@intCast(46 + offset)),
            .plus => @fromBackingInt(@intCast(offset)),
            .ergodic => self,
        };
    }

    /// Composition variety: GF(3) addition of trits selects bucket,
    /// bucket offset is the sum of offsets mod 23.
    pub fn compose(self: Variety, other: Variety) Variety {
        const result_trit = Trit.add(self.trit(), other.trit());
        const result_offset = (self.bucketOffset() + other.bucketOffset()) % 23;
        const base: u8 = switch (result_trit) {
            .minus => 0,
            .ergodic => 23,
            .plus => 46,
        };
        return @fromBackingInt(@intCast(base + result_offset));
    }
};

/// A morphism arrow f: WorldState → WorldState'.
/// Payload uses i64 for simplicity; richer payloads go through World.setParam.
pub const Morphism = struct {
    variety: Variety,
    /// Optional key the morphism acts on (null = whole-state morphism).
    target_key: ?[]const u8,
    /// Optional integer payload for parameterized morphisms.
    int_payload: ?i64,
    /// Source state hash (for provenance tracking).
    source_hash: [32]u8,
    /// Timestamp of morphism application.
    timestamp: i64,

    /// Apply this morphism to a world state, producing a new state.
    pub fn apply(self: *const Morphism, state: *WorldState) !*WorldState {
        return switch (self.variety.trit()) {
            .minus => self.applyMinus(state),
            .ergodic => self.applyErgodic(state),
            .plus => self.applyPlus(state),
        };
    }

    fn applyMinus(self: *const Morphism, state: *WorldState) !*WorldState {
        if (self.target_key) |key| {
            return try state.set(key, .Null);
        }
        return try WorldState.init(state.allocator);
    }

    fn applyErgodic(self: *const Morphism, state: *WorldState) !*WorldState {
        if (self.variety == .Identity) {
            state.ref_count += 1;
            return state;
        }
        if (self.target_key) |key| {
            if (self.int_payload) |val| {
                return try state.set(key, .{ .Int = val });
            }
        }
        state.ref_count += 1;
        return state;
    }

    fn applyPlus(self: *const Morphism, state: *WorldState) !*WorldState {
        if (self.target_key) |key| {
            if (self.int_payload) |val| {
                return try state.set(key, .{ .Int = val });
            }
        }
        return try state.set("__morphism_plus", .{ .Int = @as(i64, self.variety.index()) });
    }
};

/// Arrow: a typed edge in the category of worlds.
/// source --[variety]--> target
pub const Arrow = struct {
    variety: Variety,
    source_hash: [32]u8,
    target_hash: [32]u8,

    pub fn trit(self: Arrow) Trit {
        return self.variety.trit();
    }

    /// Two arrows are composable if the target of the first equals
    /// the source of the second.
    pub fn composable(self: Arrow, other: Arrow) bool {
        return std.mem.eql(u8, &self.target_hash, &other.source_hash);
    }

    /// Compose two arrows: self then other.
    pub fn compose(self: Arrow, other: Arrow) !Arrow {
        if (!self.composable(other)) return error.NonComposable;
        return .{
            .variety = self.variety.compose(other.variety),
            .source_hash = self.source_hash,
            .target_hash = other.target_hash,
        };
    }
};

/// Create a morphism of the given variety targeting a specific key.
pub fn morphism(variety: Variety, key: ?[]const u8, int_payload: ?i64) Morphism {
    return .{
        .variety = variety,
        .target_key = key,
        .int_payload = int_payload,
        .source_hash = undefined,
        .timestamp = std.time.milliTimestamp(),
    };
}

/// Apply a morphism to a WorldState, returning the arrow and new state.
pub fn applyMorphism(
    m: *const Morphism,
    source: *WorldState,
) !struct { arrow: Arrow, target: *WorldState } {
    var mut_m = m.*;
    mut_m.source_hash = source.hash;
    const target = try mut_m.apply(source);
    return .{
        .arrow = .{
            .variety = m.variety,
            .source_hash = source.hash,
            .target_hash = target.hash,
        },
        .target = target,
    };
}

/// Chain: a sequence of composable arrows.
pub const Chain = struct {
    arrows: std.ArrayListUnmanaged(Arrow),
    allocator: Allocator,

    pub fn init(allocator: Allocator) Chain {
        return .{ .arrows = .{}, .allocator = allocator };
    }

    pub fn deinit(self: *Chain) void {
        self.arrows.deinit(self.allocator);
    }

    pub fn append(self: *Chain, arrow: Arrow) !void {
        if (self.arrows.items.len > 0) {
            const last = self.arrows.items[self.arrows.items.len - 1];
            if (!last.composable(arrow)) return error.NonComposable;
        }
        try self.arrows.append(self.allocator, arrow);
    }

    /// Net trit of the entire chain.
    pub fn netTrit(self: *const Chain) Trit {
        var acc: Trit = .ergodic;
        for (self.arrows.items) |a| {
            acc = Trit.add(acc, a.trit());
        }
        return acc;
    }

    /// Is the chain GF(3)-balanced (net trit = 0)?
    pub fn isBalanced(self: *const Chain) bool {
        return self.netTrit() == .ergodic;
    }

    /// Collapse the chain into a single composed arrow.
    pub fn collapse(self: *const Chain) !Arrow {
        if (self.arrows.items.len == 0) return error.EmptyChain;
        var result = self.arrows.items[0];
        for (self.arrows.items[1..]) |a| {
            result = try result.compose(a);
        }
        return result;
    }

    pub fn len(self: *const Chain) usize {
        return self.arrows.items.len;
    }
};

/// Bucket statistics for the 69 varieties.
pub const BucketStats = struct {
    minus_count: u32 = 0,
    ergodic_count: u32 = 0,
    plus_count: u32 = 0,

    pub fn total(self: BucketStats) u32 {
        return self.minus_count + self.ergodic_count + self.plus_count;
    }

    pub fn isBalanced(self: BucketStats) bool {
        return self.minus_count == self.ergodic_count and self.ergodic_count == self.plus_count;
    }

    pub fn netTrit(self: BucketStats) Trit {
        const sum = @as(i64, self.plus_count) - @as(i64, self.minus_count);
        const r = @mod(sum + 3000000, 3);
        return switch (r) {
            0 => .ergodic,
            1 => .plus,
            2 => .minus,
            else => unreachable,
        };
    }
};

/// Count varieties by bucket.
pub fn bucketStats() BucketStats {
    var stats = BucketStats{};
    var i: u8 = 0;
    while (i < 69) : (i += 1) {
        const v: Variety = @fromBackingInt(@intCast(i));
        switch (v.trit()) {
            .minus => stats.minus_count += 1,
            .ergodic => stats.ergodic_count += 1,
            .plus => stats.plus_count += 1,
        }
    }
    return stats;
}

/// Select a morphism variety by SplitMix64 deterministic dispatch.
/// Same seed + index → same variety. SPI-compatible.
pub fn varietyAt(seed: u64, index: u64) Variety {
    const GOLDEN: u64 = 0x9e3779b97f4a7c15;
    const MIX1: u64 = 0xbf58476d1ce4e5b9;
    const MIX2: u64 = 0x94d049bb133111eb;
    const state = seed +% (GOLDEN *% index);
    var z = state;
    z = (z ^ (z >> 30)) *% MIX1;
    z = (z ^ (z >> 27)) *% MIX2;
    z = z ^ (z >> 31);
    return @fromBackingInt(@intCast(@as(u8, @intCast(z % 69))));
}

/// Select a variety constrained to a specific trit bucket.
pub fn varietyInBucket(seed: u64, index: u64, bucket_trit: Trit) Variety {
    const GOLDEN: u64 = 0x9e3779b97f4a7c15;
    const MIX1: u64 = 0xbf58476d1ce4e5b9;
    const MIX2: u64 = 0x94d049bb133111eb;
    const state = seed +% (GOLDEN *% index);
    var z = state;
    z = (z ^ (z >> 30)) *% MIX1;
    z = (z ^ (z >> 27)) *% MIX2;
    z = z ^ (z >> 31);
    const offset: u8 = @intCast(z % 23);
    const base: u8 = switch (bucket_trit) {
        .minus => 0,
        .ergodic => 23,
        .plus => 46,
    };
    return @fromBackingInt(@intCast(base + offset));
}

// ============================================================================
// Tests
// ============================================================================

test "69 varieties exist" {
    var i: u8 = 0;
    while (i < 69) : (i += 1) {
        const v: Variety = @fromBackingInt(@intCast(i));
        _ = v.name();
    }
}

test "23/23/23 bucket partition" {
    const stats = bucketStats();
    try std.testing.expectEqual(@as(u32, 23), stats.minus_count);
    try std.testing.expectEqual(@as(u32, 23), stats.ergodic_count);
    try std.testing.expectEqual(@as(u32, 23), stats.plus_count);
    try std.testing.expectEqual(@as(u32, 69), stats.total());
    try std.testing.expect(stats.isBalanced());
}

test "trit classification" {
    // First bucket: MINUS
    try std.testing.expectEqual(Trit.minus, Variety.Annihilate.trit());
    try std.testing.expectEqual(Trit.minus, Variety.Audit.trit());
    // Second bucket: ERGODIC
    try std.testing.expectEqual(Trit.ergodic, Variety.Identity.trit());
    try std.testing.expectEqual(Trit.ergodic, Variety.Equilibrate.trit());
    // Third bucket: PLUS
    try std.testing.expectEqual(Trit.plus, Variety.Create.trit());
    try std.testing.expectEqual(Trit.plus, Variety.Transcend.trit());
}

test "opposite morphisms" {
    // MINUS ↔ PLUS at same offset
    try std.testing.expectEqual(Variety.Create, Variety.Annihilate.opposite());
    try std.testing.expectEqual(Variety.Annihilate, Variety.Create.opposite());
    // ERGODIC is self-dual
    try std.testing.expectEqual(Variety.Identity, Variety.Identity.opposite());
    // Opposite of opposite is self
    var i: u8 = 0;
    while (i < 69) : (i += 1) {
        const v: Variety = @fromBackingInt(@intCast(i));
        try std.testing.expectEqual(v, v.opposite().opposite());
    }
}

test "composition trit is GF(3) additive" {
    // MINUS + PLUS = ERGODIC
    const composed = Variety.Annihilate.compose(Variety.Create);
    try std.testing.expectEqual(Trit.ergodic, composed.trit());
    // PLUS + PLUS = MINUS
    const pp = Variety.Create.compose(Variety.Expand);
    try std.testing.expectEqual(Trit.minus, pp.trit());
    // ERGODIC + anything = anything
    const ei = Variety.Identity.compose(Variety.Create);
    try std.testing.expectEqual(Trit.plus, ei.trit());
}

test "identity morphism" {
    try std.testing.expectEqual(Trit.ergodic, Variety.Identity.trit());
    try std.testing.expectEqual(@as(u8, 23), Variety.Identity.index());
}

test "bucket offset" {
    try std.testing.expectEqual(@as(u8, 0), Variety.Annihilate.bucketOffset());
    try std.testing.expectEqual(@as(u8, 22), Variety.Audit.bucketOffset());
    try std.testing.expectEqual(@as(u8, 0), Variety.Identity.bucketOffset());
    try std.testing.expectEqual(@as(u8, 22), Variety.Equilibrate.bucketOffset());
    try std.testing.expectEqual(@as(u8, 0), Variety.Create.bucketOffset());
    try std.testing.expectEqual(@as(u8, 22), Variety.Transcend.bucketOffset());
}

test "variety from index roundtrip" {
    var i: u8 = 0;
    while (i < 69) : (i += 1) {
        const v = try Variety.fromIndex(i);
        try std.testing.expectEqual(i, v.index());
    }
    try std.testing.expectError(error.InvalidVariety, Variety.fromIndex(69));
    try std.testing.expectError(error.InvalidVariety, Variety.fromIndex(255));
}

test "varietyAt is deterministic (SPI)" {
    const v1 = varietyAt(1069, 42);
    const v2 = varietyAt(1069, 42);
    try std.testing.expectEqual(v1, v2);
    // Different index → likely different variety
    _ = varietyAt(1069, 43);
}

test "varietyInBucket constrains to bucket" {
    var i: u64 = 0;
    while (i < 100) : (i += 1) {
        const vm = varietyInBucket(42, i, .minus);
        try std.testing.expectEqual(Trit.minus, vm.trit());
        const ve = varietyInBucket(42, i, .ergodic);
        try std.testing.expectEqual(Trit.ergodic, ve.trit());
        const vp = varietyInBucket(42, i, .plus);
        try std.testing.expectEqual(Trit.plus, vp.trit());
    }
}

test "apply identity morphism preserves state" {
    const allocator = std.testing.allocator;
    var state = try WorldState.init(allocator);
    defer state.deinit();

    var s2 = try state.set("x", .{ .Int = 42 });
    defer s2.deinit();

    const m = morphism(.Identity, null, null);
    const result = try applyMorphism(&m, s2);
    defer result.target.deinit();

    try std.testing.expect(s2.eql(result.target));
    try std.testing.expectEqual(Trit.ergodic, result.arrow.trit());
}

test "apply plus morphism creates value" {
    const allocator = std.testing.allocator;
    var state = try WorldState.init(allocator);
    defer state.deinit();

    const m = morphism(.Create, "new_key", 99);
    const result = try applyMorphism(&m, state);
    defer result.target.deinit();

    try std.testing.expectEqual(@as(i64, 99), result.target.get("new_key").?.Int);
    try std.testing.expectEqual(Trit.plus, result.arrow.trit());
}

test "apply minus morphism nullifies value" {
    const allocator = std.testing.allocator;
    var state = try WorldState.init(allocator);
    defer state.deinit();

    var s2 = try state.set("doomed", .{ .Int = 666 });
    defer s2.deinit();

    const m = morphism(.Annihilate, "doomed", null);
    const result = try applyMorphism(&m, s2);
    defer result.target.deinit();

    // MINUS morphism nullifies the key
    try std.testing.expect(result.target.get("doomed").? == .Null);
    try std.testing.expectEqual(Trit.minus, result.arrow.trit());
}

test "arrow composition" {
    const a1 = Arrow{
        .variety = .Create,
        .source_hash = @splat(0),
        .target_hash = @splat(1),
    };
    const a2 = Arrow{
        .variety = .Annihilate,
        .source_hash = @splat(1),
        .target_hash = @splat(2),
    };
    const composed = try a1.compose(a2);
    try std.testing.expectEqual(Trit.ergodic, composed.trit());
    try std.testing.expect(std.mem.eql(u8, &a1.source_hash, &composed.source_hash));
    try std.testing.expect(std.mem.eql(u8, &a2.target_hash, &composed.target_hash));
}

test "arrow non-composable" {
    const a1 = Arrow{
        .variety = .Create,
        .source_hash = @splat(0),
        .target_hash = @splat(1),
    };
    const a2 = Arrow{
        .variety = .Annihilate,
        .source_hash = @splat(99),
        .target_hash = @splat(2),
    };
    try std.testing.expectError(error.NonComposable, a1.compose(a2));
}

test "chain balance" {
    const allocator = std.testing.allocator;
    var chain = Chain.init(allocator);
    defer chain.deinit();

    // PLUS → MINUS → ERGODIC net = PLUS + MINUS = ERGODIC
    try chain.append(.{
        .variety = .Create,
        .source_hash = @splat(0),
        .target_hash = @splat(1),
    });
    try chain.append(.{
        .variety = .Annihilate,
        .source_hash = @splat(1),
        .target_hash = @splat(2),
    });

    try std.testing.expect(chain.isBalanced());
    try std.testing.expectEqual(@as(usize, 2), chain.len());

    const collapsed = try chain.collapse();
    try std.testing.expectEqual(Trit.ergodic, collapsed.trit());
}

test "chain rejects non-composable append" {
    const allocator = std.testing.allocator;
    var chain = Chain.init(allocator);
    defer chain.deinit();

    try chain.append(.{
        .variety = .Create,
        .source_hash = @splat(0),
        .target_hash = @splat(1),
    });
    try std.testing.expectError(error.NonComposable, chain.append(.{
        .variety = .Annihilate,
        .source_hash = @splat(99),
        .target_hash = @splat(2),
    }));
}

test "GF(3) trit arithmetic on varieties" {
    // Exhaustive: for all 69×69 pairs, compose trit equals GF(3) sum
    var i: u8 = 0;
    while (i < 69) : (i += 1) {
        var j: u8 = 0;
        while (j < 69) : (j += 1) {
            const vi: Variety = @fromBackingInt(@intCast(i));
            const vj: Variety = @fromBackingInt(@intCast(j));
            const composed = vi.compose(vj);
            const expected_trit = Trit.add(vi.trit(), vj.trit());
            try std.testing.expectEqual(expected_trit, composed.trit());
        }
    }
}

test "maximally oppositional: every MINUS has a PLUS opposite" {
    var i: u8 = 0;
    while (i < 23) : (i += 1) {
        const minus_v: Variety = @fromBackingInt(@intCast(i));
        const opp = minus_v.opposite();
        try std.testing.expectEqual(Trit.plus, opp.trit());
        try std.testing.expectEqual(minus_v.bucketOffset(), opp.bucketOffset());
        // Composing with opposite yields ERGODIC
        const composed = minus_v.compose(opp);
        try std.testing.expectEqual(Trit.ergodic, composed.trit());
    }
}
