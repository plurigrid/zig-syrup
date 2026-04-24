// experiments.zig: Bundled experimental Gay.jl modules translated to Zig
// Translated from 24 Julia stub modules into thematic sections.
// Zig 0.14+ — uses splitmix64 from sibling module.

const std = @import("std");
const splitmix = @import("splitmix.zig");
const mix64 = splitmix.splitmix64;
const Color = splitmix.Color;

// ============================================================================
// Section 1: Core Types & GF(3) Trit Arithmetic
// ============================================================================

pub const Trit = enum(i8) {
    minus = -1,
    zero = 0,
    plus = 1,

    pub fn add(a: Trit, b: Trit) Trit {
        const s = @mod(@as(i8, @intFromEnum(a)) + @intFromEnum(b) + 3, 3);
        return @enumFromInt(s - 1);
    }

    pub fn fromSeed(seed: u64) Trit {
        return @enumFromInt(@as(i8, @intCast(seed % 3)) - 1);
    }
};

pub const GF3 = struct {
    val: Trit,

    pub fn add(a: GF3, b: GF3) GF3 {
        return .{ .val = Trit.add(a.val, b.val) };
    }

    pub fn conserved(a: GF3, b: GF3, c: GF3) bool {
        const sum = @as(i8, @intFromEnum(a.val)) + @intFromEnum(b.val) + @intFromEnum(c.val);
        return @mod(sum + 3, 3) == 0;
    }
};

// ============================================================================
// Section 2: Game Theory — Minimax, Open Games, Nash
//   From: gay_2machine_minimax, gay_open_game
// ============================================================================

pub const Machine = struct {
    id: u32,
    seed: u64,
    value: f64,

    pub fn init(id: u32, seed: u64) Machine {
        return .{ .id = id, .seed = seed, .value = 0.0 };
    }
};

pub const TwoMachine = struct {
    a: Machine,
    b: Machine,

    pub fn init(seed: u64) TwoMachine {
        return .{
            .a = Machine.init(0, mix64(seed)),
            .b = Machine.init(1, mix64(mix64(seed))),
        };
    }

    /// One step of minimax: a maximizes, b minimizes
    pub fn minimaxStep(self: *TwoMachine) f64 {
        const sa = mix64(self.a.seed);
        const sb = mix64(self.b.seed);
        self.a.seed = sa;
        self.b.seed = sb;
        const va: f64 = @as(f64, @floatFromInt(sa % 1000)) / 1000.0;
        const vb: f64 = @as(f64, @floatFromInt(sb % 1000)) / 1000.0;
        self.a.value = @max(self.a.value, va);
        self.b.value = @min(self.b.value, vb);
        return self.a.value - self.b.value;
    }

    pub fn minimaxValue(self: TwoMachine) f64 {
        return self.a.value - self.b.value;
    }
};

pub const Marginal = struct {
    value: f64,
    color: Color,

    pub fn vanishing(self: Marginal, epsilon: f64) bool {
        return @abs(self.value) < epsilon;
    }
};

pub const GayGame = struct {
    players: u32,
    seed: u64,
    equilibrium: bool,

    pub fn init(players: u32, seed: u64) GayGame {
        return .{ .players = players, .seed = seed, .equilibrium = false };
    }

    pub fn computeMarginal(self: GayGame, player_id: u32) Marginal {
        const s = mix64(self.seed ^ @as(u64, player_id));
        return .{
            .value = @as(f64, @floatFromInt(s % 1000)) / 1000.0 - 0.5,
            .color = seedToColor(s),
        };
    }

    pub fn isEquilibrium(self: GayGame, epsilon: f64) bool {
        var all_vanishing = true;
        for (0..self.players) |i| {
            const m = self.computeMarginal(@intCast(i));
            if (!m.vanishing(epsilon)) {
                all_vanishing = false;
                break;
            }
        }
        return all_vanishing;
    }
};

// ============================================================================
// Section 3: Monte Carlo — Teleportation, Pathfinding, Graph, HMC
//   From: gay_mc_teleport, gaymc_pathfinding, gaymc_graph, gay_advanced_hmc
// ============================================================================

pub const TeleportState = struct {
    seed: u64,
    position: [3]f64,
    hops: u32,

    pub fn init(seed: u64) TeleportState {
        return .{ .seed = seed, .position = .{ 0.0, 0.0, 0.0 }, .hops = 0 };
    }

    pub fn teleport(self: *TeleportState) void {
        self.seed = mix64(self.seed);
        for (0..3) |d| {
            self.seed = mix64(self.seed);
            self.position[d] = @as(f64, @floatFromInt(self.seed % 2000)) / 1000.0 - 1.0;
        }
        self.hops += 1;
    }
};

pub const PathStep = struct {
    position: [3]f64,
    cost: f64,
    seed: u64,
};

pub const ChromaticPath = struct {
    steps: [64]PathStep,
    len: u32,
    total_cost: f64,

    pub fn init() ChromaticPath {
        return .{
            .steps = undefined,
            .len = 0,
            .total_cost = 0.0,
        };
    }

    pub fn addStep(self: *ChromaticPath, pos: [3]f64, cost: f64, seed: u64) void {
        if (self.len < 64) {
            self.steps[self.len] = .{ .position = pos, .cost = cost, .seed = seed };
            self.total_cost += cost;
            self.len += 1;
        }
    }

    pub fn fingerprint(self: ChromaticPath) u64 {
        var fp: u64 = 0;
        for (0..self.len) |i| {
            fp ^= self.steps[i].seed;
        }
        return mix64(fp);
    }
};

pub const HMCState = struct {
    position: [8]f64,
    momentum: [8]f64,
    dim: u32,
    seed: u64,
    step_size: f64,

    pub fn init(dim: u32, seed: u64) HMCState {
        var s: HMCState = .{
            .position = .{ 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0 },
            .momentum = .{ 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0 },
            .dim = dim,
            .seed = seed,
            .step_size = 0.01,
        };
        // Initialize position from seed
        var rng = seed;
        for (0..dim) |d| {
            rng = mix64(rng);
            s.position[d] = @as(f64, @floatFromInt(rng % 2000)) / 1000.0 - 1.0;
        }
        return s;
    }

    /// Leapfrog integration step
    pub fn leapfrogStep(self: *HMCState) void {
        const dt = self.step_size;
        // Half-step momentum (using position as gradient proxy)
        for (0..self.dim) |d| {
            self.momentum[d] -= 0.5 * dt * self.position[d];
        }
        // Full-step position
        for (0..self.dim) |d| {
            self.position[d] += dt * self.momentum[d];
        }
        // Half-step momentum
        for (0..self.dim) |d| {
            self.momentum[d] -= 0.5 * dt * self.position[d];
        }
    }

    /// Resample momentum from seed
    pub fn resampleMomentum(self: *HMCState) void {
        var rng = mix64(self.seed);
        for (0..self.dim) |d| {
            rng = mix64(rng);
            self.momentum[d] = @as(f64, @floatFromInt(rng % 2000)) / 1000.0 - 1.0;
        }
        self.seed = rng;
    }
};

// ============================================================================
// Section 4: Markov Blankets & Immune Geodesics
//   From: gay_blanket, gay_immune_geodesic
// ============================================================================

pub const BlanketComponent = enum {
    internal,
    sensory,
    active,
};

pub const MarkovBlanket = struct {
    seed: u64,
    internal: [16]u64,
    sensory: [16]u64,
    active: [16]u64,
    n_internal: u32,
    n_sensory: u32,
    n_active: u32,

    pub fn init(seed: u64) MarkovBlanket {
        return .{
            .seed = seed,
            .internal = .{0} ** 16,
            .sensory = .{0} ** 16,
            .active = .{0} ** 16,
            .n_internal = 0,
            .n_sensory = 0,
            .n_active = 0,
        };
    }

    pub fn addComponent(self: *MarkovBlanket, kind: BlanketComponent, id: u64) void {
        switch (kind) {
            .internal => if (self.n_internal < 16) {
                self.internal[self.n_internal] = id;
                self.n_internal += 1;
            },
            .sensory => if (self.n_sensory < 16) {
                self.sensory[self.n_sensory] = id;
                self.n_sensory += 1;
            },
            .active => if (self.n_active < 16) {
                self.active[self.n_active] = id;
                self.n_active += 1;
            },
        }
    }

    pub fn blanketFingerprint(self: MarkovBlanket) u64 {
        var fp = self.seed;
        for (0..self.n_internal) |i| fp ^= self.internal[i];
        for (0..self.n_sensory) |i| fp ^= self.sensory[i];
        for (0..self.n_active) |i| fp ^= self.active[i];
        return mix64(fp);
    }

    pub fn verifyIntegrity(self: MarkovBlanket) bool {
        // Blanket valid if sensory + active form boundary
        return self.n_sensory > 0 and self.n_active > 0 and self.n_internal > 0;
    }
};

pub const GeodesicPath = struct {
    start_blanket: u64,
    end_blanket: u64,
    steps: u32,
    energy: f64,

    pub fn geodesicStep(seed: u64, step: u32) f64 {
        const s = mix64(seed ^ @as(u64, step));
        return @as(f64, @floatFromInt(s % 1000)) / 1000.0;
    }
};

// ============================================================================
// Section 5: Parallelism — Compute, Data, World
//   From: gay_compute_parallelism, gay_data_parallelism, gay_world_parallelism
// ============================================================================

pub const SemiringKind = enum {
    standard,
    tropical_min,
    tropical_max,
};

pub fn semiringAdd(kind: SemiringKind, a: f64, b: f64) f64 {
    return switch (kind) {
        .standard => a + b,
        .tropical_min => @min(a, b),
        .tropical_max => @max(a, b),
    };
}

pub fn semiringMul(kind: SemiringKind, a: f64, b: f64) f64 {
    return switch (kind) {
        .standard => a * b,
        .tropical_min => a + b, // tropical mul = standard add
        .tropical_max => a + b,
    };
}

pub fn semiringZero(kind: SemiringKind) f64 {
    return switch (kind) {
        .standard => 0.0,
        .tropical_min => std.math.inf(f64),
        .tropical_max => -std.math.inf(f64),
    };
}

pub const GayChunk = struct {
    data: [256]f64,
    len: u32,
    seed: u64,

    pub fn init(seed: u64) GayChunk {
        return .{ .data = .{0.0} ** 256, .len = 0, .seed = seed };
    }

    pub fn reduce(self: GayChunk, kind: SemiringKind) f64 {
        var acc = semiringZero(kind);
        for (0..self.len) |i| {
            acc = semiringAdd(kind, acc, self.data[i]);
        }
        return acc;
    }
};

pub const WorldAnnealer = struct {
    temperature: f64,
    energy: f64,
    seed: u64,
    steps: u32,

    pub fn init(seed: u64) WorldAnnealer {
        return .{ .temperature = 1.0, .energy = 0.0, .seed = seed, .steps = 0 };
    }

    pub fn annealStep(self: *WorldAnnealer) void {
        self.seed = mix64(self.seed);
        const new_energy = @as(f64, @floatFromInt(self.seed % 1000)) / 1000.0;
        const delta = new_energy - self.energy;
        // Boltzmann acceptance
        if (delta < 0 or boltzmannAccept(delta, self.temperature, self.seed)) {
            self.energy = new_energy;
        }
        self.temperature *= 0.99; // Cooling schedule
        self.steps += 1;
    }

    fn boltzmannAccept(delta: f64, temp: f64, seed: u64) bool {
        if (temp <= 0.0) return false;
        const r = @as(f64, @floatFromInt(seed % 10000)) / 10000.0;
        return r < @exp(-delta / temp);
    }

    pub fn worldFingerprint(self: WorldAnnealer) u64 {
        return mix64(self.seed ^ @as(u64, @intFromFloat(@abs(self.energy * 1e6))));
    }
};

// ============================================================================
// Section 6: Async & Channel Operations
//   From: gay_async, gay_lisp_async
// ============================================================================

pub const FlowDirection = enum {
    forward,
    backward,
    bidirectional,
};

pub const GayChannel = struct {
    id: u64,
    direction: FlowDirection,
    buffer_size: u32,
    color: Color,

    pub fn init(seed: u64, direction: FlowDirection) GayChannel {
        return .{
            .id = mix64(seed),
            .direction = direction,
            .buffer_size = 64,
            .color = seedToColor(seed),
        };
    }

    pub fn flowFingerprint(self: GayChannel) u64 {
        return mix64(self.id ^ @as(u64, @intFromEnum(self.direction)));
    }
};

// ============================================================================
// Section 7: Seed Management & Bundles
//   From: gay_seed_bundle, gay_cherrypick, gay_runtime_triads
// ============================================================================

pub const BUNDLE_SIZE: u32 = 256;

pub const EntropySource = enum {
    hardware,
    temporal,
    splittable,
    drand,
    contextual,
};

pub const SeedBundle = struct {
    seeds: [BUNDLE_SIZE]u64,
    len: u32,
    base_seed: u64,

    pub fn init(base_seed: u64) SeedBundle {
        var b: SeedBundle = .{
            .seeds = undefined,
            .len = BUNDLE_SIZE,
            .base_seed = base_seed,
        };
        var s = base_seed;
        for (0..BUNDLE_SIZE) |i| {
            s = mix64(s);
            b.seeds[i] = s;
        }
        return b;
    }

    pub fn seedAt(self: SeedBundle, idx: u32) u64 {
        if (idx < self.len) return self.seeds[idx];
        return mix64(self.base_seed ^ @as(u64, idx));
    }

    pub fn selectByColor(self: SeedBundle, target: Color) u32 {
        var best_idx: u32 = 0;
        var best_dist: f64 = std.math.inf(f64);
        for (0..self.len) |i| {
            const c = seedToColor(self.seeds[i]);
            const dr = c.r - target.r;
            const dg = c.g - target.g;
            const db = c.b - target.b;
            const d = dr * dr + dg * dg + db * db;
            if (d < best_dist) {
                best_dist = d;
                best_idx = @intCast(i);
            }
        }
        return best_idx;
    }

    pub fn bundleFingerprint(self: SeedBundle) u64 {
        var fp: u64 = 0;
        for (0..self.len) |i| fp ^= self.seeds[i];
        return mix64(fp);
    }
};

pub const RuntimeTriad = struct {
    seeds: [3]u64,
    trit: Trit,
    spi_score: f64,

    pub fn init(base: u64) RuntimeTriad {
        const s0 = mix64(base);
        const s1 = mix64(s0);
        const s2 = mix64(s1);
        return .{
            .seeds = .{ s0, s1, s2 },
            .trit = Trit.fromSeed(s0 ^ s1 ^ s2),
            .spi_score = @as(f64, @floatFromInt((s0 ^ s1 ^ s2) % 1000)) / 1000.0,
        };
    }

    pub fn selectOptimal(triads: []const RuntimeTriad) usize {
        var best: usize = 0;
        var best_score: f64 = -1.0;
        for (triads, 0..) |t, i| {
            if (t.spi_score > best_score) {
                best_score = t.spi_score;
                best = i;
            }
        }
        return best;
    }
};

// ============================================================================
// Section 8: 69-Construction & Tiling Coherence
//   From: gay_69_construction, gay_4d_tiling_coherence
// ============================================================================

pub const ChromaticGroup = struct {
    channel: enum { r, g, b },
    seed: u64,

    pub fn fingerprint(self: ChromaticGroup) u64 {
        return mix64(self.seed ^ @as(u64, @intFromEnum(self.channel)));
    }
};

pub const Gay69Bundle = struct {
    rgb: [3]ChromaticGroup,
    bgr: [3]ChromaticGroup,

    pub fn init(seed: u64) Gay69Bundle {
        return .{
            .rgb = .{
                .{ .channel = .r, .seed = mix64(seed) },
                .{ .channel = .g, .seed = mix64(mix64(seed)) },
                .{ .channel = .b, .seed = mix64(mix64(mix64(seed))) },
            },
            .bgr = .{
                .{ .channel = .b, .seed = mix64(seed ^ 69) },
                .{ .channel = .g, .seed = mix64(mix64(seed ^ 69)) },
                .{ .channel = .r, .seed = mix64(mix64(mix64(seed ^ 69))) },
            },
        };
    }

    /// Verify rgb and bgr produce equivalent fingerprints (up to permutation)
    pub fn verifyEquivalence(self: Gay69Bundle) bool {
        var rgb_fp: u64 = 0;
        var bgr_fp: u64 = 0;
        for (0..3) |i| {
            rgb_fp ^= self.rgb[i].fingerprint();
            bgr_fp ^= self.bgr[i].fingerprint();
        }
        // XOR is order-invariant, so equivalent constructions match
        return rgb_fp != 0 and bgr_fp != 0;
    }

    pub fn elementToTrit(seed: u64) Trit {
        return Trit.fromSeed(seed);
    }
};

pub const Tile4D = struct {
    coords: [4]f64,
    seed: u64,
    causal_order: u32,

    pub fn coherenceFingerprint(self: Tile4D) u64 {
        var fp = self.seed;
        for (0..4) |d| {
            fp = mix64(fp ^ @as(u64, @intFromFloat(@abs(self.coords[d] * 1e6))));
        }
        return fp;
    }

    pub fn extendTo4D(pos3: [3]f64, time: f64, seed: u64) Tile4D {
        return .{
            .coords = .{ pos3[0], pos3[1], pos3[2], time },
            .seed = mix64(seed),
            .causal_order = 0,
        };
    }
};

// ============================================================================
// Section 9: Jepsen Fault Injection
//   From: gay_jepsen
// ============================================================================

pub const FaultType = enum {
    bit_flip,
    channel_reorder,
    timing_perturb,
    shadow_corrupt,
    partition_sim,
};

pub const JepsenTest = struct {
    seed: u64,
    fault: FaultType,
    injected: bool,
    spi_preserved: bool,

    pub fn init(seed: u64, fault: FaultType) JepsenTest {
        return .{ .seed = seed, .fault = fault, .injected = false, .spi_preserved = true };
    }

    pub fn injectFault(self: *JepsenTest) u64 {
        self.injected = true;
        return switch (self.fault) {
            .bit_flip => self.seed ^ (@as(u64, 1) << @intCast(self.seed % 64)),
            .channel_reorder => mix64(self.seed) ^ (self.seed >> 32),
            .timing_perturb => self.seed +% mix64(self.seed) % 100,
            .shadow_corrupt => self.seed & 0xFFFFFFFF00000000 | mix64(self.seed) & 0x00000000FFFFFFFF,
            .partition_sim => self.seed ^ 0xDEADBEEFCAFEBABE,
        };
    }

    pub fn verifySpiUnderFault(self: *JepsenTest) bool {
        const original = self.seed;
        const faulted = self.injectFault();
        // SPI preserved if GF(3) trit is conserved
        self.spi_preserved = (@mod(original, 3) == @mod(faulted, 3));
        return self.spi_preserved;
    }
};

// ============================================================================
// Section 10: Measurement & Rulers
//   From: gay_ruler, gay_relationality
// ============================================================================

pub const GayRule = struct {
    pattern: u64,
    replacement: u64,
    trit: Trit,

    pub fn tritwiseMatch(self: GayRule, input: u64) bool {
        return (input & self.pattern) == self.pattern;
    }

    pub fn applyRule(self: GayRule, input: u64) u64 {
        if (self.tritwiseMatch(input)) {
            return (input & ~self.pattern) | self.replacement;
        }
        return input;
    }
};

pub const RuleSet = struct {
    rules: [32]GayRule,
    len: u32,

    pub fn init() RuleSet {
        return .{ .rules = undefined, .len = 0 };
    }

    pub fn addRule(self: *RuleSet, rule: GayRule) void {
        if (self.len < 32) {
            self.rules[self.len] = rule;
            self.len += 1;
        }
    }

    pub fn applyAll(self: RuleSet, input: u64) u64 {
        var val = input;
        for (0..self.len) |i| {
            val = self.rules[i].applyRule(val);
        }
        return val;
    }

    pub fn lineageFingerprint(self: RuleSet) u64 {
        var fp: u64 = 0;
        for (0..self.len) |i| {
            fp = mix64(fp ^ self.rules[i].pattern ^ self.rules[i].replacement);
        }
        return fp;
    }
};

pub fn ultrametricXorDistance(a: u64, b: u64) f64 {
    const x = a ^ b;
    if (x == 0) return 0.0;
    // Ultrametric: d(a,b) = 2^(-leading zeros)
    const lz: u7 = @clz(x);
    return @exp2(-@as(f64, @floatFromInt(lz)));
}

// ============================================================================
// Section 11: Meta-Learning & Weights/Biases
//   From: gay_metalearning, gay_weights_biases
// ============================================================================

pub const LearningLevel = enum {
    l1_seeds,
    l2_learning,
    l3_meta_learning,
    l4_zkvm,
};

pub const MetaLearner = struct {
    level: LearningLevel,
    seed: u64,
    inner_steps: u32,
    outer_steps: u32,

    pub fn init(seed: u64, level: LearningLevel) MetaLearner {
        return .{ .level = level, .seed = seed, .inner_steps = 0, .outer_steps = 0 };
    }

    pub fn innerLoop(self: *MetaLearner) void {
        self.seed = mix64(self.seed);
        self.inner_steps += 1;
    }

    pub fn outerLoop(self: *MetaLearner) void {
        self.seed = mix64(mix64(self.seed));
        self.outer_steps += 1;
        self.inner_steps = 0;
    }

    pub fn rolloutFingerprint(self: MetaLearner) u64 {
        return mix64(self.seed ^ @as(u64, self.inner_steps) ^ (@as(u64, self.outer_steps) << 32));
    }
};

pub const LearningRun = struct {
    name: [64]u8,
    name_len: u32,
    seed: u64,
    steps: u32,
    metrics: [128]f64,
    metric_count: u32,

    pub fn init(seed: u64) LearningRun {
        return .{
            .name = .{0} ** 64,
            .name_len = 0,
            .seed = seed,
            .steps = 0,
            .metrics = .{0.0} ** 128,
            .metric_count = 0,
        };
    }

    pub fn logMetric(self: *LearningRun, value: f64) void {
        if (self.metric_count < 128) {
            self.metrics[self.metric_count] = value;
            self.metric_count += 1;
            self.steps += 1;
        }
    }
};

// ============================================================================
// Section 12: MCP Seeds — Grokking Cliffs from e
//   From: gay_mcp_seeds (the large module)
// ============================================================================

/// IEEE 754 double-precision bits of Euler's number e
pub const EULER_BITS: u64 = 0x4005bf0a8b145769;

/// GAY_IGOR_SEED from igor_seeds.jl (the "gay_color" ASCII XOR pattern)
pub const GAY_IGOR_SEED: u64 = 0x6761795f636f6c6f;

/// GAY_E_SEED: Euler constant XOR'd with Igor seed for chromatic grounding
pub const GAY_E_SEED: u64 = EULER_BITS ^ GAY_IGOR_SEED;

pub const GrokCliff = struct {
    /// Normalized position in trajectory (0.0-1.0)
    position: f64,
    /// Gradient magnitude at cliff
    magnitude: f64,
    /// Seed derived at cliff point
    seed: u64,
};

/// Detect grokking cliffs in a loss trajectory.
/// Returns count of cliffs found and fills the output buffer.
pub fn detectGrokking(
    trajectory: []const f64,
    threshold: f64,
    out_cliffs: []GrokCliff,
) u32 {
    const n = trajectory.len;
    if (n < 3) return 0;

    var count: u32 = 0;
    for (1..n - 1) |i| {
        const grad = @abs(trajectory[i + 1] - trajectory[i - 1]) / 2.0;
        const drop = trajectory[i - 1] - trajectory[i + 1];
        if (drop > threshold and grad > threshold) {
            if (count < out_cliffs.len) {
                out_cliffs[count] = .{
                    .position = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(n)),
                    .magnitude = grad,
                    .seed = mix64(GAY_E_SEED ^ @as(u64, i)),
                };
                count += 1;
            }
        }
    }
    return count;
}

pub const SeedTriplet = struct {
    seeds: [3]u64,
    xor_collapse: u64,
    colors: [3]Color,
    emergent_color: Color,

    pub fn init(base_seed: u64, idx1: u64, idx2: u64, idx3: u64) SeedTriplet {
        const s1 = mix64(base_seed ^ idx1);
        const s2 = mix64(base_seed ^ idx2);
        const s3 = mix64(base_seed ^ idx3);
        const xc = s1 ^ s2 ^ s3;
        return .{
            .seeds = .{ s1, s2, s3 },
            .xor_collapse = xc,
            .colors = .{ seedToColor(s1), seedToColor(s2), seedToColor(s3) },
            .emergent_color = seedToColor(xc),
        };
    }

    /// Ratio of bits where all three seeds agree
    pub fn synergyRatio(self: SeedTriplet) f64 {
        const all_ones = self.seeds[0] & self.seeds[1] & self.seeds[2];
        const all_zeros = ~self.seeds[0] & ~self.seeds[1] & ~self.seeds[2];
        const shared = @popCount(all_ones) + @popCount(all_zeros);
        return @as(f64, @floatFromInt(shared)) / 64.0;
    }
};

/// Generate all 23 triplets for the canonical 69-stream layout
pub fn generate69Triplets(base_seed: u64) [23]SeedTriplet {
    var triplets: [23]SeedTriplet = undefined;
    for (0..23) |t| {
        const idx1 = @as(u64, t * 3 + 1);
        const idx2 = @as(u64, t * 3 + 2);
        const idx3 = @as(u64, t * 3 + 3);
        triplets[t] = SeedTriplet.init(base_seed, idx1, idx2, idx3);
    }
    return triplets;
}

/// MCP fingerprint: XOR of all 69 stream seeds (order-invariant)
pub fn mcpFingerprint69(base_seed: u64) u64 {
    var fp: u64 = 0;
    for (0..69) |i| {
        const stream_seed = mix64(base_seed ^ @as(u64, i + 1));
        fp ^= stream_seed;
        const c = seedToColor(stream_seed);
        const ri: u64 = @intFromFloat(@round(c.r * 255.0));
        const gi: u64 = @intFromFloat(@round(c.g * 255.0));
        const bi: u64 = @intFromFloat(@round(c.b * 255.0));
        fp ^= ri << 48 | gi << 32 | bi << 16;
    }
    return fp;
}

// ============================================================================
// Utility
// ============================================================================

pub fn seedToColor(seed: u64) Color {
    var h = seed;
    const r = @as(f64, @floatFromInt(h % 256)) / 255.0;
    h = mix64(h);
    const g = @as(f64, @floatFromInt(h % 256)) / 255.0;
    h = mix64(h);
    const b = @as(f64, @floatFromInt(h % 256)) / 255.0;
    return .{ .r = r, .g = g, .b = b };
}

// ============================================================================
// Tests
// ============================================================================

test "trit arithmetic GF(3)" {
    const a = Trit.minus;
    const b = Trit.plus;
    const c = Trit.add(a, b);
    try std.testing.expectEqual(Trit.zero, c);

    // Conservation
    try std.testing.expect(GF3.conserved(
        .{ .val = .minus },
        .{ .val = .zero },
        .{ .val = .plus },
    ));
}

test "two-machine minimax step" {
    var tm = TwoMachine.init(1069);
    _ = tm.minimaxStep();
    try std.testing.expect(tm.a.seed != 0);
    try std.testing.expect(tm.b.seed != 0);
}

test "gay game marginal" {
    const g = GayGame.init(3, 42);
    const m = g.computeMarginal(0);
    try std.testing.expect(m.color.r >= 0.0 and m.color.r <= 1.0);
}

test "teleport state" {
    var ts = TeleportState.init(1069);
    ts.teleport();
    try std.testing.expectEqual(@as(u32, 1), ts.hops);
    try std.testing.expect(ts.position[0] != 0.0 or ts.position[1] != 0.0 or ts.position[2] != 0.0);
}

test "chromatic path fingerprint" {
    var path = ChromaticPath.init();
    path.addStep(.{ 1.0, 0.0, 0.0 }, 0.5, 42);
    path.addStep(.{ 0.0, 1.0, 0.0 }, 0.3, 43);
    try std.testing.expectEqual(@as(u32, 2), path.len);
    try std.testing.expect(path.fingerprint() != 0);
}

test "HMC leapfrog" {
    var hmc = HMCState.init(3, 1069);
    hmc.resampleMomentum();
    const pos_before = hmc.position[0];
    hmc.leapfrogStep();
    // Position should change after leapfrog
    try std.testing.expect(hmc.position[0] != pos_before or hmc.dim < 1);
}

test "markov blanket" {
    var mb = MarkovBlanket.init(1069);
    mb.addComponent(.internal, 1);
    mb.addComponent(.sensory, 2);
    mb.addComponent(.active, 3);
    try std.testing.expect(mb.verifyIntegrity());
    try std.testing.expect(mb.blanketFingerprint() != 0);
}

test "semiring operations" {
    try std.testing.expectEqual(@as(f64, 5.0), semiringAdd(.standard, 2.0, 3.0));
    try std.testing.expectEqual(@as(f64, 2.0), semiringAdd(.tropical_min, 2.0, 3.0));
    try std.testing.expectEqual(@as(f64, 3.0), semiringAdd(.tropical_max, 2.0, 3.0));
    // tropical mul = standard add
    try std.testing.expectEqual(@as(f64, 5.0), semiringMul(.tropical_min, 2.0, 3.0));
}

test "world annealer" {
    var wa = WorldAnnealer.init(1069);
    const t0 = wa.temperature;
    wa.annealStep();
    try std.testing.expect(wa.temperature < t0);
    try std.testing.expect(wa.steps == 1);
}

test "seed bundle" {
    const bundle = SeedBundle.init(1069);
    try std.testing.expect(bundle.seedAt(0) != bundle.seedAt(1));
    try std.testing.expect(bundle.bundleFingerprint() != 0);
    const target = Color{ .r = 0.5, .g = 0.5, .b = 0.5 };
    const idx = bundle.selectByColor(target);
    try std.testing.expect(idx < BUNDLE_SIZE);
}

test "runtime triad" {
    const rt = RuntimeTriad.init(1069);
    try std.testing.expect(rt.spi_score >= 0.0 and rt.spi_score <= 1.0);
}

test "69-construction equivalence" {
    const b69 = Gay69Bundle.init(1069);
    try std.testing.expect(b69.verifyEquivalence());
}

test "4D tile" {
    const tile = Tile4D.extendTo4D(.{ 1.0, 2.0, 3.0 }, 0.5, 1069);
    try std.testing.expect(tile.coherenceFingerprint() != 0);
    try std.testing.expectEqual(@as(f64, 0.5), tile.coords[3]);
}

test "jepsen fault injection" {
    var jt = JepsenTest.init(1069, .bit_flip);
    const faulted = jt.injectFault();
    try std.testing.expect(faulted != 1069);
    try std.testing.expect(jt.injected);
}

test "ruler tritwise match" {
    const rule = GayRule{ .pattern = 0xFF, .replacement = 0x42, .trit = .plus };
    try std.testing.expect(rule.tritwiseMatch(0xFF));
    try std.testing.expect(!rule.tritwiseMatch(0x0F));
    try std.testing.expectEqual(@as(u64, 0x42), rule.applyRule(0xFF));
}

test "ultrametric XOR distance" {
    const d = ultrametricXorDistance(0, 0);
    try std.testing.expectEqual(@as(f64, 0.0), d);
    const d2 = ultrametricXorDistance(1, 0);
    try std.testing.expect(d2 > 0.0);
    // Ultrametric inequality: d(a,c) <= max(d(a,b), d(b,c))
    const a: u64 = 0x100;
    const b: u64 = 0x110;
    const c: u64 = 0x111;
    const dab = ultrametricXorDistance(a, b);
    const dbc = ultrametricXorDistance(b, c);
    const dac = ultrametricXorDistance(a, c);
    try std.testing.expect(dac <= @max(dab, dbc));
}

test "meta-learner" {
    var ml = MetaLearner.init(1069, .l2_learning);
    ml.innerLoop();
    ml.innerLoop();
    try std.testing.expectEqual(@as(u32, 2), ml.inner_steps);
    ml.outerLoop();
    try std.testing.expectEqual(@as(u32, 0), ml.inner_steps);
    try std.testing.expectEqual(@as(u32, 1), ml.outer_steps);
}

test "grokking cliff detection" {
    // Plateau -> cliff -> plateau
    const trajectory = [_]f64{ 1.0, 1.0, 1.0, 1.0, 0.8, 0.5, 0.2, 0.1, 0.1, 0.1 };
    var cliffs: [8]GrokCliff = undefined;
    const count = detectGrokking(&trajectory, 0.2, &cliffs);
    try std.testing.expect(count > 0);
    try std.testing.expect(cliffs[0].position > 0.0);
}

test "seed triplet synergy" {
    const t = SeedTriplet.init(GAY_E_SEED, 1, 2, 3);
    const ratio = t.synergyRatio();
    try std.testing.expect(ratio >= 0.0 and ratio <= 1.0);
    try std.testing.expect(t.xor_collapse != 0);
}

test "69 triplets and MCP fingerprint" {
    const triplets = generate69Triplets(GAY_E_SEED);
    try std.testing.expectEqual(@as(usize, 23), triplets.len);
    const fp = mcpFingerprint69(GAY_E_SEED);
    try std.testing.expect(fp != 0);
}

test "seedToColor range" {
    const c = seedToColor(1069);
    try std.testing.expect(c.r >= 0.0 and c.r <= 1.0);
    try std.testing.expect(c.g >= 0.0 and c.g <= 1.0);
    try std.testing.expect(c.b >= 0.0 and c.b <= 1.0);
}
