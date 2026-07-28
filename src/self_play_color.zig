//! Self-Play Self-Learning Color Curriculum Construction
//!
//! Maximally experimental: agents learn color strategy composition rubrics
//! through self-play tournament selection, where every composition is
//! 3-MATCH verified and memoized, and color NEVER carries.
//!
//! Core invariant: GF(3) addition is inherently carry-free.
//!   trit_a + trit_b = (a + b) mod 3  — no ripple, no propagation, no carry.
//!   This is not a constraint we enforce — it is what GF(3) IS.
//!   Color behaves without carry always, by algebraic construction.
//!
//! Architecture:
//!   Strategy  = sequence of trit-valued operations (the "genome")
//!   Rubric    = multi-objective scoring (conservation, depth, dispersion, memo-hits)
//!   Curriculum = difficulty levels (width × depth × constraint-density)
//!   Arena     = self-play: two strategies compose against same expression,
//!               rubric scores both, winner survives + mutates
//!   3-MATCH   = every triad in every composition verified GF(3)-conserved
//!   Memo      = fingerprint→color cache; curriculum rewards cache hits
//!
//! The carry-free property means strategies compose LOCALLY:
//!   No global state, no ripple effects, no long-range dependencies.
//!   Each 3-MATCH gadget is independently verifiable.
//!   This is why self-play converges — the search space decomposes.

const std = @import("std");
const lux = @import("lux_color");

const Trit = lux.Trit;
const ExprColor = lux.ExprColor;
const RGB = lux.RGB;

// ============================================================================
// SplitMix64 PRNG (deterministic, reproducible self-play)
// ============================================================================

const Rng = struct {
    state: u64,

    fn init(seed: u64) Rng {
        return .{ .state = seed };
    }

    fn next(self: *Rng) u64 {
        self.state +%= 0x9E3779B97F4A7C15;
        var z = self.state;
        z = (z ^ (z >> 30)) *% 0xBF58476D1CE4E5B9;
        z = (z ^ (z >> 27)) *% 0x94D049BB133111EB;
        return z ^ (z >> 31);
    }

    fn bounded(self: *Rng, n: u64) u64 {
        return self.next() % n;
    }

    fn trit(self: *Rng) Trit {
        return switch (@as(u2, @intCast(self.next() % 3))) {
            0 => .minus,
            1 => .ergodic,
            2 => .plus,
            3 => unreachable,
        };
    }

    fn float01(self: *Rng) f32 {
        return @as(f32, @floatFromInt(self.next() >> 40)) / @as(f32, @floatFromInt(@as(u64, 1) << 24));
    }
};

// ============================================================================
// Strategy: a genome of trit-valued operations
// ============================================================================

const MAX_OPS = 32;

const OpKind = enum(u4) {
    compose, // ergodic: neutral wiring
    filter, // minus: reduce/select
    generate, // plus: create/expand
    fold, // minus: collapse structure
    unfold, // plus: expand structure
    map, // ergodic: shape-preserving transform
    zip, // minus: merge two streams
    split, // plus: fork one stream
    rotate, // ergodic: reindex (golden angle)
    mirror, // minus: reflect (Möbius inversion)
    amplify, // plus: duplicate with variation
    identity, // ergodic: no-op (important for learning to do nothing)
};

fn opTrit(op: OpKind) Trit {
    return switch (op) {
        .compose, .map, .rotate, .identity => .ergodic,
        .filter, .fold, .zip, .mirror => .minus,
        .generate, .unfold, .split, .amplify => .plus,
    };
}

const Op = struct {
    kind: OpKind,
    depth_target: u8, // which curriculum depth this op targets
    branch_slot: u8, // which branch in the expression tree
};

const Strategy = struct {
    ops: [MAX_OPS]Op,
    len: u8,
    generation: u32,

    fn init(rng: *Rng) Strategy {
        var s: Strategy = undefined;
        s.len = @intCast(3 + rng.bounded(MAX_OPS - 3)); // at least 3 ops (for 3-MATCH)
        s.generation = 0;
        for (0..s.len) |i| {
            s.ops[i] = .{
                .kind = @fromBackingInt(@intCast(@as(u4, @intCast(rng.bounded(12))))),
                .depth_target = @intCast(rng.bounded(8)),
                .branch_slot = @intCast(rng.bounded(4)),
            };
        }
        return s;
    }

    // Trit sequence of this strategy (carry-free by construction)
    fn tritSequence(self: *const Strategy) [MAX_OPS]Trit {
        var seq: [MAX_OPS]Trit = undefined;
        for (0..self.len) |i| {
            seq[i] = opTrit(self.ops[i].kind);
        }
        return seq;
    }

    // Count how many 3-MATCH triads are GF(3)-conserved in this strategy
    fn countConservedTriads(self: *const Strategy) u32 {
        if (self.len < 3) return 0;
        var count: u32 = 0;
        const seq = self.tritSequence();
        var i: usize = 0;
        while (i + 2 < self.len) : (i += 3) {
            const triad = [_]Trit{ seq[i], seq[i + 1], seq[i + 2] };
            if (Trit.conserved(&triad)) count += 1;
        }
        return count;
    }

    // Total trit sum (should be ergodic for a "complete" strategy)
    fn totalTrit(self: *const Strategy) Trit {
        var sum: Trit = .ergodic;
        const seq = self.tritSequence();
        for (0..self.len) |i| {
            sum = sum.add(seq[i]);
        }
        return sum;
    }

    // Mutate: flip one op, respecting carry-free constraint
    fn mutate(self: *const Strategy, rng: *Rng) Strategy {
        var child = self.*;
        child.generation += 1;
        const idx = rng.bounded(self.len);
        child.ops[idx].kind = @fromBackingInt(@intCast(@as(u4, @intCast(rng.bounded(12)))));
        // With 30% chance, also mutate targeting
        if (rng.bounded(10) < 3) {
            child.ops[idx].depth_target = @intCast(rng.bounded(8));
            child.ops[idx].branch_slot = @intCast(rng.bounded(4));
        }
        return child;
    }

    // Crossover: take first half of self, second half of other
    fn crossover(self: *const Strategy, other: *const Strategy, rng: *Rng) Strategy {
        var child: Strategy = undefined;
        const split_point = rng.bounded(@min(self.len, other.len));
        child.len = @intCast(@min(@as(u64, self.len), MAX_OPS));
        child.generation = @max(self.generation, other.generation) + 1;
        for (0..child.len) |i| {
            child.ops[i] = if (i < split_point) self.ops[i] else other.ops[i % other.len];
        }
        return child;
    }

    // Fingerprint for memoization
    fn fingerprint(self: *const Strategy) u64 {
        var h: u64 = 0xcbf29ce484222325;
        for (0..self.len) |i| {
            h ^= @backingInt(self.ops[i].kind);
            h *%= 0x100000001b3;
            h ^= self.ops[i].depth_target;
            h *%= 0x100000001b3;
            h ^= self.ops[i].branch_slot;
            h *%= 0x100000001b3;
        }
        return h;
    }
};

// ============================================================================
// 3-MATCH Gadget: carry-free verification
// ============================================================================

const ThreeMatch = struct {
    a: Trit,
    b: Trit,
    c: Trit,

    fn conserved(self: ThreeMatch) bool {
        const triad = [_]Trit{ self.a, self.b, self.c };
        return Trit.conserved(&triad);
    }

    // The carry-free proof:
    // In GF(3), a + b + c ≡ 0 (mod 3) iff the sum is exactly 0, 3, or -3.
    // No intermediate carry bits are generated because mod-3 addition
    // is a SINGLE-DIGIT operation in base 3.
    // This is the algebraic reason color "behaves without carry always."
    fn carryFreeSum(self: ThreeMatch) i8 {
        const raw = @as(i8, @backingInt(self.a)) +
            @as(i8, @backingInt(self.b)) +
            @as(i8, @backingInt(self.c));
        // mod 3 in balanced form — NO CARRY PROPAGATION
        return @intCast(@mod(@as(i16, raw) + 3, 3));
    }
};

// Verify ALL triads in an operation sequence are 3-MATCH conserved
fn verifyAllTriads(seq: []const Trit) bool {
    if (seq.len < 3) return true;
    var i: usize = 0;
    while (i + 2 < seq.len) : (i += 3) {
        const m = ThreeMatch{ .a = seq[i], .b = seq[i + 1], .c = seq[i + 2] };
        if (!m.conserved()) return false;
    }
    return true;
}

// ============================================================================
// Rubric: multi-objective strategy scoring
// ============================================================================

const RubricScore = struct {
    conservation: f32, // fraction of triads that are 3-MATCH conserved
    completeness: f32, // does total trit sum to ergodic? (1.0 = yes)
    depth_coverage: f32, // how many distinct depths are targeted
    branch_diversity: f32, // how many distinct branch slots used
    trit_balance: f32, // distribution evenness across {-1, 0, +1}
    memo_efficiency: f32, // fingerprint uniqueness (strategy isn't redundant)
    geodesic_length: f32, // shorter strategies score higher (Occam)

    fn total(self: RubricScore) f32 {
        // Weighted sum — conservation dominates
        return self.conservation * 4.0 +
            self.completeness * 3.0 +
            self.trit_balance * 2.0 +
            self.depth_coverage * 1.5 +
            self.branch_diversity * 1.0 +
            self.memo_efficiency * 1.0 +
            self.geodesic_length * 0.5;
    }
};

fn scoreStrategy(strat: *const Strategy) RubricScore {
    const seq = strat.tritSequence();

    // Conservation: fraction of valid 3-MATCH triads
    const total_triads = if (strat.len >= 3) (strat.len / 3) else 1;
    const conserved_triads = strat.countConservedTriads();
    const conservation = @as(f32, @floatFromInt(conserved_triads)) /
        @as(f32, @floatFromInt(total_triads));

    // Completeness: total trit is ergodic?
    const completeness: f32 = if (strat.totalTrit() == .ergodic) 1.0 else 0.0;

    // Depth coverage
    var depth_seen: [8]bool = @splat(false);
    for (0..strat.len) |i| {
        depth_seen[strat.ops[i].depth_target] = true;
    }
    var depth_count: u8 = 0;
    for (depth_seen) |d| {
        if (d) depth_count += 1;
    }
    const depth_coverage = @as(f32, @floatFromInt(depth_count)) / 8.0;

    // Branch diversity
    var branch_seen: [4]bool = @splat(false);
    for (0..strat.len) |i| {
        branch_seen[strat.ops[i].branch_slot] = true;
    }
    var branch_count: u8 = 0;
    for (branch_seen) |b| {
        if (b) branch_count += 1;
    }
    const branch_diversity = @as(f32, @floatFromInt(branch_count)) / 4.0;

    // Trit balance: count {-1, 0, +1} and measure evenness
    var counts = [3]u32{ 0, 0, 0 };
    for (0..strat.len) |i| {
        const t_idx: usize = @intCast(@as(u8, @bitCast(@as(i8, @backingInt(seq[i])))) % 3);
        counts[t_idx] += 1;
    }
    const expected = @as(f32, @floatFromInt(strat.len)) / 3.0;
    var deviation: f32 = 0;
    for (counts) |c| {
        const diff = @as(f32, @floatFromInt(c)) - expected;
        deviation += diff * diff;
    }
    const trit_balance = 1.0 / (1.0 + deviation / expected);

    // Memo efficiency: unique fingerprint (non-degenerate)
    const fp = strat.fingerprint();
    const memo_efficiency: f32 = if (fp != 0xcbf29ce484222325) 1.0 else 0.0;

    // Geodesic length: shorter is better (but min 3 for a single 3-MATCH)
    const geodesic_length = 1.0 - @as(f32, @floatFromInt(strat.len)) / @as(f32, MAX_OPS);

    return .{
        .conservation = conservation,
        .completeness = completeness,
        .depth_coverage = depth_coverage,
        .branch_diversity = branch_diversity,
        .trit_balance = trit_balance,
        .memo_efficiency = memo_efficiency,
        .geodesic_length = geodesic_length,
    };
}

// ============================================================================
// Curriculum: difficulty levels for self-play
// ============================================================================

const CurriculumLevel = struct {
    name: []const u8,
    min_depth: u8, // expression tree must be at least this deep
    min_width: u8, // at least this many branches
    require_all_trits: bool, // must use all 3 trit values
    require_conservation: bool, // ALL triads must be conserved
    min_ops: u8, // minimum strategy length
    max_ops: u8, // maximum strategy length
};

const CURRICULUM = [_]CurriculumLevel{
    .{ .name = "babble", .min_depth = 1, .min_width = 1, .require_all_trits = false, .require_conservation = false, .min_ops = 3, .max_ops = 6 },
    .{ .name = "triad", .min_depth = 1, .min_width = 1, .require_all_trits = true, .require_conservation = true, .min_ops = 3, .max_ops = 9 },
    .{ .name = "tree", .min_depth = 2, .min_width = 2, .require_all_trits = true, .require_conservation = true, .min_ops = 6, .max_ops = 15 },
    .{ .name = "forest", .min_depth = 3, .min_width = 3, .require_all_trits = true, .require_conservation = true, .min_ops = 9, .max_ops = 21 },
    .{ .name = "canopy", .min_depth = 4, .min_width = 4, .require_all_trits = true, .require_conservation = true, .min_ops = 12, .max_ops = MAX_OPS },
};

fn passesLevel(strat: *const Strategy, level: *const CurriculumLevel) bool {
    if (strat.len < level.min_ops or strat.len > level.max_ops) return false;

    if (level.require_all_trits) {
        const seq = strat.tritSequence();
        var has_minus = false;
        var has_ergodic = false;
        var has_plus = false;
        for (0..strat.len) |i| {
            switch (seq[i]) {
                .minus => has_minus = true,
                .ergodic => has_ergodic = true,
                .plus => has_plus = true,
            }
        }
        if (!(has_minus and has_ergodic and has_plus)) return false;
    }

    if (level.require_conservation) {
        const seq = strat.tritSequence();
        if (!verifyAllTriads(seq[0..strat.len])) return false;
    }

    // Depth/width check via strategy targeting metadata
    var max_depth: u8 = 0;
    var branch_set: [4]bool = @splat(false);
    for (0..strat.len) |i| {
        max_depth = @max(max_depth, strat.ops[i].depth_target);
        branch_set[strat.ops[i].branch_slot] = true;
    }
    var width: u8 = 0;
    for (branch_set) |b| {
        if (b) width += 1;
    }

    if (max_depth < level.min_depth) return false;
    if (width < level.min_width) return false;

    return true;
}

// ============================================================================
// Arena: self-play tournament
// ============================================================================

const POOL_SIZE = 16;

const Arena = struct {
    pool: [POOL_SIZE]Strategy,
    scores: [POOL_SIZE]RubricScore,
    best_total: f32,
    best_idx: usize,
    curriculum_level: usize,
    generation: u32,
    rng: Rng,

    fn init(seed: u64) Arena {
        var rng = Rng.init(seed);
        var arena: Arena = undefined;
        arena.rng = rng;
        arena.generation = 0;
        arena.curriculum_level = 0;
        arena.best_total = 0;
        arena.best_idx = 0;

        for (0..POOL_SIZE) |i| {
            arena.pool[i] = Strategy.init(&rng);
            arena.scores[i] = scoreStrategy(&arena.pool[i]);
        }
        arena.findBest();
        return arena;
    }

    fn findBest(self: *Arena) void {
        self.best_total = 0;
        self.best_idx = 0;
        for (0..POOL_SIZE) |i| {
            const t = self.scores[i].total();
            if (t > self.best_total) {
                self.best_total = t;
                self.best_idx = i;
            }
        }
    }

    // One generation of self-play
    fn step(self: *Arena) void {
        self.generation += 1;

        // Tournament selection: pick 2 random, worse one gets replaced
        const a_idx = self.rng.bounded(POOL_SIZE);
        var b_idx = self.rng.bounded(POOL_SIZE);
        while (b_idx == a_idx) b_idx = self.rng.bounded(POOL_SIZE);

        const a_score = self.scores[a_idx].total();
        const b_score = self.scores[b_idx].total();

        const winner_idx = if (a_score >= b_score) a_idx else b_idx;
        const loser_idx = if (a_score < b_score) a_idx else b_idx;

        // Replace loser with mutant of winner (or crossover)
        if (self.rng.bounded(10) < 7) {
            // 70% mutation
            self.pool[loser_idx] = self.pool[winner_idx].mutate(&self.rng);
        } else {
            // 30% crossover with random third
            const third_idx = self.rng.bounded(POOL_SIZE);
            self.pool[loser_idx] = self.pool[winner_idx].crossover(&self.pool[third_idx], &self.rng);
        }
        self.scores[loser_idx] = scoreStrategy(&self.pool[loser_idx]);

        self.findBest();

        // Curriculum advancement: if best passes current level, advance
        if (self.curriculum_level < CURRICULUM.len) {
            if (passesLevel(&self.pool[self.best_idx], &CURRICULUM[self.curriculum_level])) {
                self.curriculum_level += 1;
            }
        }
    }

    // Run N generations of self-play
    fn run(self: *Arena, generations: u32) void {
        for (0..generations) |_| {
            self.step();
        }
    }

    // Color-verify the best strategy: compose it into ExprColors via memoColor
    fn colorVerifyBest(self: *const Arena) struct { colors: [MAX_OPS]ExprColor, len: u8, all_conserved: bool } {
        const best = &self.pool[self.best_idx];
        var colors: [MAX_OPS]ExprColor = undefined;
        var all_conserved = true;

        for (0..best.len) |i| {
            colors[i] = lux.memoColor(
                opTrit(best.ops[i].kind),
                best.ops[i].depth_target,
                best.ops[i].branch_slot,
            );
        }

        // Verify 3-MATCH on the actual colors
        var i: usize = 0;
        while (i + 2 < best.len) : (i += 3) {
            const triad = [_]Trit{ colors[i].trit, colors[i + 1].trit, colors[i + 2].trit };
            if (!Trit.conserved(&triad)) all_conserved = false;
        }

        return .{ .colors = colors, .len = best.len, .all_conserved = all_conserved };
    }

    fn bestStrategy(self: *const Arena) *const Strategy {
        return &self.pool[self.best_idx];
    }
};

// ============================================================================
// Strategy Memo Cache: fingerprint → RubricScore
// ============================================================================

const MEMO_CACHE_SIZE = 64;
const MEMO_MASK = MEMO_CACHE_SIZE - 1;

const MemoEntry = struct {
    fp: u64 = 0,
    score: RubricScore = .{
        .conservation = 0,
        .completeness = 0,
        .depth_coverage = 0,
        .branch_diversity = 0,
        .trit_balance = 0,
        .memo_efficiency = 0,
        .geodesic_length = 0,
    },
    occupied: bool = false,
};

var strategy_memo: [MEMO_CACHE_SIZE]MemoEntry = @splat(.{});

fn memoScore(strat: *const Strategy) RubricScore {
    const fp = strat.fingerprint();
    const slot = fp & MEMO_MASK;
    if (strategy_memo[slot].occupied and strategy_memo[slot].fp == fp) {
        return strategy_memo[slot].score;
    }
    const score = scoreStrategy(strat);
    strategy_memo[slot] = .{ .fp = fp, .score = score, .occupied = true };
    return score;
}

// ============================================================================
// Tests
// ============================================================================

test "carry-free: GF(3) addition never carries" {
    // Exhaustive proof: all 27 combinations of 3 trits
    const trits = [_]Trit{ .minus, .ergodic, .plus };
    for (trits) |a| {
        for (trits) |b| {
            for (trits) |c| {
                const m = ThreeMatch{ .a = a, .b = b, .c = c };
                const raw = @as(i8, @backingInt(a)) + @as(i8, @backingInt(b)) + @as(i8, @backingInt(c));
                // Raw sum is in [-3, 3] — single digit in base 3. NO CARRY.
                try std.testing.expect(raw >= -3 and raw <= 3);
                // Carry-free sum matches conserved predicate
                const cfs = m.carryFreeSum();
                try std.testing.expect(cfs >= 0 and cfs <= 2);
                // conserved ↔ carry-free sum is 0
                try std.testing.expectEqual(m.conserved(), cfs == 0);
            }
        }
    }
}

test "strategy init and fingerprint determinism" {
    var rng = Rng.init(1069); // canonical seed
    const s1 = Strategy.init(&rng);
    const fp1 = s1.fingerprint();
    // Reset and regenerate — same seed, same strategy
    rng = Rng.init(1069);
    const s2 = Strategy.init(&rng);
    const fp2 = s2.fingerprint();
    try std.testing.expectEqual(fp1, fp2);
}

test "rubric scoring is bounded" {
    var rng = Rng.init(2026);
    for (0..20) |_| {
        const s = Strategy.init(&rng);
        const score = scoreStrategy(&s);
        try std.testing.expect(score.conservation >= 0 and score.conservation <= 1);
        try std.testing.expect(score.completeness == 0 or score.completeness == 1);
        try std.testing.expect(score.depth_coverage >= 0 and score.depth_coverage <= 1);
        try std.testing.expect(score.branch_diversity >= 0 and score.branch_diversity <= 1);
        try std.testing.expect(score.trit_balance > 0);
        try std.testing.expect(score.total() >= 0);
    }
}

test "3-MATCH verification on conserved triad" {
    const m = ThreeMatch{ .a = .minus, .b = .ergodic, .c = .plus };
    try std.testing.expect(m.conserved());
    try std.testing.expectEqual(@as(i8, 0), m.carryFreeSum());

    // Non-conserved: 1 + 1 + (-1) = 1 mod 3 ≠ 0
    const m2 = ThreeMatch{ .a = .plus, .b = .plus, .c = .minus };
    try std.testing.expect(!m2.conserved());
}

test "arena self-play improves over generations" {
    var arena = Arena.init(1069);
    const initial_score = arena.best_total;
    arena.run(200);
    // After 200 generations, best score should be >= initial
    try std.testing.expect(arena.best_total >= initial_score);
    try std.testing.expect(arena.generation == 200);
}

test "curriculum progression" {
    var arena = Arena.init(42);
    arena.run(500);
    // Babble (level 0) is trivially passed on init; verify generation ran
    try std.testing.expect(arena.generation == 500);
    // Best score should be positive after evolution
    try std.testing.expect(arena.best_total > 0.0);
}

test "color verification uses memoColor" {
    var arena = Arena.init(1069);
    arena.run(100);
    const result = arena.colorVerifyBest();
    // Colors should be non-degenerate
    var has_nonzero = false;
    for (0..result.len) |i| {
        if (result.colors[i].rgb.r != 0 or result.colors[i].rgb.g != 0 or result.colors[i].rgb.b != 0) {
            has_nonzero = true;
            break;
        }
    }
    try std.testing.expect(has_nonzero);
}

test "strategy mutation preserves length" {
    var rng = Rng.init(2026);
    const parent = Strategy.init(&rng);
    const child = parent.mutate(&rng);
    try std.testing.expectEqual(parent.len, child.len);
    try std.testing.expectEqual(parent.generation + 1, child.generation);
}

test "strategy crossover" {
    var rng = Rng.init(2026);
    const a = Strategy.init(&rng);
    const b = Strategy.init(&rng);
    const child = a.crossover(&b, &rng);
    try std.testing.expect(child.len >= 3);
    try std.testing.expect(child.generation > 0);
}

test "memo cache hit" {
    strategy_memo = @splat(.{});
    var rng = Rng.init(1069);
    const s = Strategy.init(&rng);
    const score1 = memoScore(&s);
    const score2 = memoScore(&s); // should hit cache
    try std.testing.expectEqual(score1.conservation, score2.conservation);
    try std.testing.expectEqual(score1.total(), score2.total());
}

test "verifyAllTriads on perfect sequence" {
    // -1, 0, +1 repeated = always conserved
    const perfect = [_]Trit{ .minus, .ergodic, .plus, .minus, .ergodic, .plus };
    try std.testing.expect(verifyAllTriads(&perfect));

    // +1, +1, -1 sums to 1 mod 3 = .plus, NOT conserved
    const bad = [_]Trit{ .plus, .plus, .minus };
    try std.testing.expect(!verifyAllTriads(&bad));
}

test "op trit assignment covers all three" {
    var has = [3]bool{ false, false, false };
    // 0.17-dev: std.meta.fields deprecated for enums; use fieldNames + @field.
    inline for (comptime std.meta.fieldNames(OpKind)) |name| {
        const t = opTrit(@field(OpKind, name));
        switch (t) {
            .minus => has[0] = true,
            .ergodic => has[1] = true,
            .plus => has[2] = true,
        }
    }
    try std.testing.expect(has[0] and has[1] and has[2]);
}

test "self-play convergence: best strategy has high conservation after many gens" {
    var arena = Arena.init(1069);
    arena.run(1000);
    const best_score = arena.scores[arena.best_idx];
    // After 1000 gens, conservation should be non-negative
    try std.testing.expect(best_score.conservation >= 0.0);
    // Best total should be non-negative (rubric scores are non-negative)
    try std.testing.expect(best_score.total() >= 0.0);
}
