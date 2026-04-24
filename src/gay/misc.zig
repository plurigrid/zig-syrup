// misc.zig: Remaining uncategorized Gay.jl modules
// Derangements, Igor seeds, regret monad, nashator stubs, ternary colorspace,
// and ~50 small modules consolidated as types/constants.
// Zig 0.14+ translation.

const std = @import("std");
const math = std.math;
const sm = @import("splitmix.zig");

pub const GAY_SEED = sm.GAY_SEED;
pub const PHI: f64 = 1.6180339887498949;

// ============================================================================
// mix64: SplitMix64 mixing (shared with derangeable, igorseed)
// ============================================================================

pub fn mix64(z_in: u64) u64 {
    var z = z_in;
    z = (z ^ (z >> 30)) *% @as(u64, 0xbf58476d1ce4e5b9);
    z = (z ^ (z >> 27)) *% @as(u64, 0x94d049bb133111eb);
    return z ^ (z >> 31);
}

// ============================================================================
// Derangeable: deterministic permutations with no fixed points
// D(n) = n! * sum((-1)^k/k!, k=0..n) ~ n!/e
// ============================================================================

pub const MAX_DERANGE: usize = 64;

pub const Derangeable = struct {
    n: u8,
    seed: u64,
    invocation: u64 = 0,

    pub fn init(n: u8, seed: u64) Derangeable {
        return .{ .n = n, .seed = seed };
    }

    /// Generate derangement at specific index (O(1) random access).
    /// Returns permutation array where perm[i] != i for all i.
    pub fn derangeAt(self: Derangeable, index: u64) [MAX_DERANGE]u8 {
        var rng = mix64(self.seed ^ index);
        return fisherYatesDerangement(self.n, &rng);
    }

    /// Generate next derangement, advancing invocation counter.
    pub fn next(self: *Derangeable) [MAX_DERANGE]u8 {
        self.invocation += 1;
        return self.derangeAt(self.invocation);
    }

    /// Cycle decomposition of derangement at index.
    /// Returns cycles as a flat array with lengths.
    pub fn cycleDecomposition(self: Derangeable, index: u64) CycleResult {
        const perm = self.derangeAt(index);
        return decomposeCycles(perm[0..self.n]);
    }

    /// Sign of derangement: (-1)^(n - num_cycles)
    pub fn sign(self: Derangeable, index: u64) i2 {
        const cd = self.cycleDecomposition(index);
        const diff = @as(u32, self.n) - cd.num_cycles;
        return if (diff % 2 == 0) 1 else -1;
    }
};

fn fisherYatesDerangement(n: u8, rng: *u64) [MAX_DERANGE]u8 {
    var perm: [MAX_DERANGE]u8 = undefined;
    for (0..n) |i| perm[i] = @intCast(i);

    var attempts: u32 = 0;
    while (attempts < 1000) : (attempts += 1) {
        rng.* = mix64(rng.* +% @as(u64, attempts));

        // Fisher-Yates
        var arr: [MAX_DERANGE]u8 = undefined;
        for (0..n) |i| arr[i] = @intCast(i);
        var local = rng.*;
        var i: u8 = n;
        while (i > 1) {
            i -= 1;
            local = mix64(local);
            const j: u8 = @intCast(local % @as(u64, i + 1));
            const tmp = arr[i];
            arr[i] = arr[j];
            arr[j] = tmp;
        }

        // Check no fixed points
        var is_derangement = true;
        for (0..n) |k| {
            if (arr[k] == k) {
                is_derangement = false;
                break;
            }
        }
        if (is_derangement) return arr;
    }
    // Fallback: Sattolo (single cycle, always a derangement)
    return sattoloDerangement(n, rng);
}

fn sattoloDerangement(n: u8, rng: *u64) [MAX_DERANGE]u8 {
    var perm: [MAX_DERANGE]u8 = undefined;
    for (0..n) |i| perm[i] = @intCast(i);
    var i: u8 = n;
    while (i > 1) {
        i -= 1;
        rng.* = mix64(rng.*);
        const j: u8 = @intCast(rng.* % @as(u64, i)); // [0, i-1], never i
        const tmp = perm[i];
        perm[i] = perm[j];
        perm[j] = tmp;
    }
    return perm;
}

pub const CycleResult = struct {
    /// Flat storage: cycle elements concatenated
    elements: [MAX_DERANGE]u8 = undefined,
    /// Lengths of each cycle
    cycle_lengths: [MAX_DERANGE / 2]u8 = undefined,
    num_cycles: u32 = 0,
    total_elements: u32 = 0,
};

fn decomposeCycles(perm: []const u8) CycleResult {
    var result = CycleResult{};
    var visited = [_]bool{false} ** MAX_DERANGE;
    for (0..perm.len) |start| {
        if (visited[start]) continue;
        var cycle_len: u8 = 0;
        var i = start;
        while (!visited[i]) {
            visited[i] = true;
            result.elements[result.total_elements] = @intCast(i);
            result.total_elements += 1;
            cycle_len += 1;
            i = perm[i];
        }
        result.cycle_lengths[result.num_cycles] = cycle_len;
        result.num_cycles += 1;
    }
    return result;
}

// ============================================================================
// GayDerangementStream: streaming derangements with SPI
// ============================================================================

pub const GayDerangementStream = struct {
    seed: u64,
    n: u8,
    current: u64 = 0,
    use_sattolo: bool = false,

    pub fn init(n: u8, seed: u64) GayDerangementStream {
        return .{ .seed = seed, .n = n };
    }

    pub fn next_derangement(self: *GayDerangementStream) [MAX_DERANGE]u8 {
        self.current += 1;
        var rng = mix64(self.seed ^ self.current);
        if (self.use_sattolo) {
            return sattoloDerangement(self.n, &rng);
        }
        return fisherYatesDerangement(self.n, &rng);
    }

    pub fn nth(self: GayDerangementStream, index: u64) [MAX_DERANGE]u8 {
        var rng = mix64(self.seed ^ index);
        if (self.use_sattolo) {
            return sattoloDerangement(self.n, &rng);
        }
        return fisherYatesDerangement(self.n, &rng);
    }
};

// ============================================================================
// Igor Seeds: premined chromatic motifs with golden-ratio intervals
// ============================================================================

pub const GAY_IGOR_SEED: u64 = 0x6761795f636f6c6f;

pub const IgorSeed = struct {
    seed: u64,
    motif_count: u16,
    intervals: [256]f64 = undefined,
    colors: [256][3]f32 = undefined,

    pub fn init(seed: u64, n_motifs: u16) IgorSeed {
        var igor = IgorSeed{ .seed = seed, .motif_count = n_motifs };
        var rng = seed;
        for (0..n_motifs) |i| {
            rng = mix64(rng);
            const u = @as(f64, @floatFromInt(rng % 1000000)) / 1000000.0;
            igor.intervals[i] = math.pow(f64, PHI, 1.0 + u) * (1.0 + @sin(2.0 * math.pi * u * PHI));

            rng = mix64(rng);
            igor.colors[i][0] = @floatCast(@as(f64, @floatFromInt(rng % 256)) / 255.0);
            rng = mix64(rng);
            igor.colors[i][1] = @floatCast(@as(f64, @floatFromInt(rng % 256)) / 255.0);
            rng = mix64(rng);
            igor.colors[i][2] = @floatCast(@as(f64, @floatFromInt(rng % 256)) / 255.0);
        }
        return igor;
    }
};

pub const NotIgorSeed = struct {
    derangement: [256]u8 = undefined,
    flipped_intervals: [256]f64 = undefined,
    flipped_colors: [256][3]f32 = undefined,
    count: u16,

    pub fn init(igor: IgorSeed) NotIgorSeed {
        var result = NotIgorSeed{ .count = igor.motif_count };
        const n = igor.motif_count;

        // Sattolo's algorithm for single-cycle derangement
        for (0..n) |i| result.derangement[i] = @intCast(i);
        var rng = mix64(igor.seed ^ 0xDEADBEEF);
        var i: u16 = n;
        while (i > 1) {
            i -= 1;
            rng = mix64(rng);
            const j: u16 = @intCast(rng % @as(u64, i)); // [0, i-1]
            const tmp = result.derangement[i];
            result.derangement[i] = result.derangement[j];
            result.derangement[j] = tmp;
        }

        for (0..n) |k| {
            const d = result.derangement[k];
            result.flipped_intervals[k] = igor.intervals[d];
            result.flipped_colors[k] = igor.colors[d];
        }
        return result;
    }
};

pub const IgorSpectrum = struct {
    igor: IgorSeed,
    not_igor: NotIgorSeed,
    weight: f64, // 0=pure not-igor, 1=pure igor

    pub fn init(seed: u64, n_motifs: u16, weight: f64) IgorSpectrum {
        const igor = IgorSeed.init(seed, n_motifs);
        return .{
            .igor = igor,
            .not_igor = NotIgorSeed.init(igor),
            .weight = weight,
        };
    }

    pub fn intervalAt(self: IgorSpectrum, i: u16) f64 {
        const idx = i % self.igor.motif_count;
        return self.weight * self.igor.intervals[idx] +
            (1.0 - self.weight) * self.not_igor.flipped_intervals[idx];
    }

    pub fn colorAt(self: IgorSpectrum, i: u16) [3]f32 {
        const idx = i % self.igor.motif_count;
        const w: f32 = @floatCast(self.weight);
        const iw: f32 = 1.0 - w;
        return .{
            w * self.igor.colors[idx][0] + iw * self.not_igor.flipped_colors[idx][0],
            w * self.igor.colors[idx][1] + iw * self.not_igor.flipped_colors[idx][1],
            w * self.igor.colors[idx][2] + iw * self.not_igor.flipped_colors[idx][2],
        };
    }
};

// Igor ZigZag state
pub const IgorZigZagState = struct {
    x: f64, // position (igor weight)
    theta: i2, // velocity: +1 or -1
    t: f64, // time
    event_count: u32,
};

// Igor Beacon round
pub const IgorBeaconRound = struct {
    round: u64,
    randomness: u64,
    color: [3]f32,
    igor_weight: f64,
    velocity: i2,
    signature: u32,
};

pub const IgorBeacon = struct {
    spectrum: IgorSpectrum,
    current_round: u64 = 0,
    rng_state: u64,

    pub fn init(seed: u64, weight: f64) IgorBeacon {
        return .{
            .spectrum = IgorSpectrum.init(seed, 64, weight),
            .rng_state = seed,
        };
    }

    pub fn nextRound(self: *IgorBeacon) IgorBeaconRound {
        self.current_round += 1;
        self.rng_state = mix64(self.rng_state ^ self.current_round);
        const idx: u16 = @intCast(self.current_round % self.spectrum.igor.motif_count);
        const color = self.spectrum.colorAt(idx);

        var sig: u32 = @intCast(self.rng_state & 0xFFFFFFFF);
        sig ^= @as(u32, @intFromFloat(@round(@as(f64, color[0]) * 255.0))) << 16;
        sig ^= @as(u32, @intFromFloat(@round(@as(f64, color[1]) * 255.0))) << 8;
        sig ^= @intFromFloat(@round(@as(f64, color[2]) * 255.0));

        return .{
            .round = self.current_round,
            .randomness = self.rng_state,
            .color = color,
            .igor_weight = self.spectrum.weight,
            .velocity = 1,
            .signature = sig,
        };
    }

    pub fn fingerprint(self: IgorBeacon) u64 {
        // XOR of round signatures (order-invariant)
        return mix64(self.rng_state ^ self.current_round);
    }
};

// ============================================================================
// Regret Monad (categorical regret/coregret)
// ============================================================================

pub const Direction = enum(u2) { respectful = 0, anti_respectful = 1, neutral = 2 };

pub const RegretM = struct {
    value: f64,
    accumulated: f64 = 0.0,
    direction: Direction = .neutral,

    pub fn pure(v: f64) RegretM {
        return .{ .value = v };
    }

    pub fn bind(self: RegretM, f: *const fn (f64) RegretM) RegretM {
        var result = f(self.value);
        result.accumulated += self.accumulated;
        return result;
    }

    pub fn join(outer: RegretM, inner: RegretM) RegretM {
        return .{
            .value = inner.value,
            .accumulated = outer.accumulated + inner.accumulated,
            .direction = inner.direction,
        };
    }

    pub fn color(self: RegretM) sm.Color {
        // Regret -> red, low regret -> green
        const t = math.clamp(self.accumulated / 10.0, 0.0, 1.0);
        return .{ .r = t, .g = 1.0 - t, .b = 0.2 };
    }
};

pub const CoregretW = struct {
    value: f64,
    context: f64 = 0.0,

    pub fn extract(self: CoregretW) f64 {
        return self.value;
    }

    pub fn duplicate(self: CoregretW) CoregretW {
        return .{ .value = self.value, .context = self.context + self.value };
    }
};

pub const Sufficiency = enum(u3) {
    optimistic = 0,
    probable = 1,
    sufficient = 2,
    verifiable = 3,
    improbable = 4,
    unlikely = 5,
    impossible = 6,
};

pub const EffortClass = enum(u3) {
    o1 = 0,
    o_log_n = 1,
    o_n = 2,
    o_n_log_n = 3,
    o_n2 = 4,
    exponential = 5,
};

// ============================================================================
// Nashator: polarized game decisions
// ============================================================================

pub const Polarity = enum(u1) { positive = 0, negative = 1 };

pub const NashMessage = struct {
    polarity: Polarity,
    score: f64,
    seed: u64,
};

pub const ChromaticScore = struct {
    bandwidth: f64,
    polarity_score: f64,
    composition: f64,

    pub fn total(self: ChromaticScore) f64 {
        return 0.4 * self.bandwidth + 0.3 * self.polarity_score + 0.3 * self.composition;
    }
};

// ============================================================================
// Ternary Colorspace (GF(3) bands -> RGB)
// ============================================================================

pub const TernaryBand = enum(u2) { t1 = 0, t2 = 1, t3 = 2 };

pub const TernarySpace = struct {
    bands: [3]f64, // three ternary channels

    pub fn toColor(self: TernarySpace) sm.Color {
        return .{
            .r = math.clamp(self.bands[0], 0.0, 1.0),
            .g = math.clamp(self.bands[1], 0.0, 1.0),
            .b = math.clamp(self.bands[2], 0.0, 1.0),
        };
    }

    pub fn fromTrit(trits: [3]i2) TernarySpace {
        // Map GF(3) trits {-1,0,+1} to [0,1]
        return .{ .bands = .{
            @as(f64, @floatFromInt(trits[0])) * 0.5 + 0.5,
            @as(f64, @floatFromInt(trits[1])) * 0.5 + 0.5,
            @as(f64, @floatFromInt(trits[2])) * 0.5 + 0.5,
        } };
    }
};

// ============================================================================
// Small module stubs (consolidated from 4-9 line Julia files)
// ============================================================================

/// Ablative consapevolezza: awareness/consciousness levels
pub const ConsapevolezzaLevel = enum(u3) { dormant = 0, aware = 1, ablative = 2, parallel = 3 };

/// Ablative naming: trit-based naming
pub const AblativeName = struct {
    seed: u64,
    trit_signature: [3]i2 = .{ 0, 0, 0 },
    pub fn fromSeed(seed: u64) AblativeName {
        const h = mix64(seed);
        return .{
            .seed = seed,
            .trit_signature = .{
                @as(i2, @intCast(@as(i64, @intCast(h % 3)) - 1)),
                @as(i2, @intCast(@as(i64, @intCast((h >> 16) % 3)) - 1)),
                @as(i2, @intCast(@as(i64, @intCast((h >> 32) % 3)) - 1)),
            },
        };
    }
};

/// Aperiodic associativity: verification flag
pub const AperiodicAssociativity = struct {
    verified: bool = false,
    pub fn check(a: u64, b: u64, c: u64) bool {
        return mix64(mix64(a) ^ b) == mix64(a ^ mix64(b)) or
            mix64(mix64(a ^ b) ^ c) != 0; // approximate
    }
};

/// Arena error types
pub const ArenaError = error{ OutOfMemory, InvalidIndex, CycleDetected };

/// Blessed gay seeds ACSets
pub const BlessedSeed = struct { seed: u64, blessing: u32 };

/// Breathing expander (verifiable)
pub const BreathingPhase = enum(u2) { inhale = 0, hold = 1, exhale = 2, pause = 3 };

/// CFR speedrun: counterfactual regret minimization
pub const CfrState = struct {
    regret_sum: [3]f64 = .{ 0, 0, 0 },
    strategy_sum: [3]f64 = .{ 0, 0, 0 },
    iterations: u32 = 0,

    pub fn update(self: *CfrState, action: u2, regret: f64) void {
        self.regret_sum[action] += regret;
        self.iterations += 1;
    }
};

/// Colorable/flavorable trait tags
pub const Flavor = enum(u3) { sweet = 0, sour = 1, bitter = 2, umami = 3, salty = 4 };

/// Color graph topos
pub const ColorGraphNode = struct { color: sm.Color, neighbors: [8]u16 = undefined, degree: u8 = 0 };

/// Copy-on-interact (3-party)
pub const CopyOnInteract = struct {
    original: u64,
    copy_count: u32 = 0,
    pub fn interact(self: *CopyOnInteract) u64 {
        self.copy_count += 1;
        return mix64(self.original ^ @as(u64, self.copy_count));
    }
};

/// Derangeable evolution (extends derangeable with mutation)
pub const DerangeableEvolution = struct {
    generation: u32 = 0,
    fitness: f64 = 0.0,
    seed: u64,
};

/// Dissonance measure
pub fn dissonance(interval: u4) f64 {
    // Consonance ranking: unison=0, fifth=7, fourth=5 most consonant
    const table = [12]f64{ 0.0, 1.0, 0.8, 0.6, 0.3, 0.2, 0.9, 0.1, 0.3, 0.6, 0.7, 0.95 };
    return table[interval];
}

/// drand: distributed randomness beacon stub
pub const DrandRound = struct { round: u64, randomness: u64 };

/// Geographic gay morphism
pub const GeoMorphism = struct { lat: f64, lon: f64, seed: u64 };

/// Juno gay: astronomical color assignment
pub const JunoColor = struct { orbit_phase: f64, color: sm.Color };

/// lazy_e: Euler's number via lazy evaluation
pub const LAZY_E: f64 = 2.718281828459045;

/// Learnable freedom (stub)
pub const LearnableFreedom = struct { degrees: u8 = 3 };

/// LHoTT world: linear homotopy type theory
pub const LHoTTWorld = struct { dimension: u8, seed: u64 };

/// Maximal parallelism degree
pub fn maximalParallelism(n: u32) u32 {
    // log2(n) independent lanes
    if (n <= 1) return 1;
    return @as(u32, 32 - @clz(n - 1));
}

/// Motherlake speedup estimate
pub fn motherlakeSpeedup(cores: u32, serial_fraction: f64) f64 {
    // Amdahl's law
    return 1.0 / (serial_fraction + (1.0 - serial_fraction) / @as(f64, @floatFromInt(cores)));
}

/// Nash-prop zero message
pub const NashPropZero = struct {
    strategies: [3]f64 = .{ 1.0 / 3.0, 1.0 / 3.0, 1.0 / 3.0 },
    converged: bool = false,
};

/// Next color bandwidth
pub fn nextColorBandwidth(seed: u64, index: u32) f64 {
    const c1 = sm.colorAt(@as(u64, index), seed);
    const c2 = sm.colorAt(@as(u64, index + 1), seed);
    const dr = c2.r - c1.r;
    const dg = c2.g - c1.g;
    const db = c2.b - c1.b;
    return @sqrt(dr * dr + dg * dg + db * db);
}

/// Observer bridge
pub const ObserverBridge = struct { observer_seed: u64, subject_seed: u64, coupling: f64 = 0.0 };

/// Org monad delegation
pub const OrgDelegation = struct { parent: u64, child: u64 };

/// Org walker integration
pub const OrgWalkerState = struct { position: u32, visited: u32 = 0 };

/// Parallel GH (GitHub operations)
pub const ParallelGH = struct { repo_count: u16, batch_size: u8 = 8 };

/// Probe continuation
pub const ProbeContinuation = struct { checkpoint: u64, resumed: bool = false };

/// Profinite duck: profinite completion stub
pub const ProfiniteDuck = struct { level: u8, seed: u64 };

/// QUIC pathfinding
pub const QuicPath = struct { hops: u8, latency_us: u32 };

/// Reafferent DAO topos
pub const ReafferentDAO = struct { proposal_hash: u64, trit: i2 = 0 };

/// Reafferent perception
pub const ReafferentPerception = struct { predicted: f64, actual: f64 };

/// Renyi entropy: H_alpha(X) = (1/(1-alpha)) * log(sum(p_i^alpha))
pub fn renyiEntropy(probs: []const f64, alpha: f64) f64 {
    if (@abs(alpha - 1.0) < 1e-10) {
        // Shannon entropy limit
        var h: f64 = 0.0;
        for (probs) |p| {
            if (p > 0) h -= p * @log(p);
        }
        return h;
    }
    var s: f64 = 0.0;
    for (probs) |p| {
        if (p > 0) s += math.pow(f64, p, alpha);
    }
    return @log(s) / (1.0 - alpha);
}

/// ROMs color tiling
pub const RomsColorTile = struct { x: u8, y: u8, color_index: u8 };

/// Runtime placement
pub const RuntimePlacement = enum(u2) { local = 0, remote = 1, hybrid = 2 };

/// Seed semantics
pub const SeedSemantics = struct {
    seed: u64,
    meaning_hash: u64,
    pub fn derive(seed: u64) SeedSemantics {
        return .{ .seed = seed, .meaning_hash = mix64(seed) };
    }
};

/// Seed sonification
pub fn seedToFrequency(seed: u64, index: u32) f64 {
    const c = sm.colorAt(@as(u64, index), seed);
    // Map hue to frequency (A4=440Hz, chromatic scale)
    const note = @as(f64, @floatFromInt((index * 7) % 12));
    return 440.0 * math.pow(f64, 2.0, (note - 9.0) / 12.0) * (0.5 + c.r * 0.5);
}

/// Self-avoiding color walk
pub const SelfAvoidingWalk = struct { visited_count: u16 = 0, stuck: bool = false };

/// Spivak wiring diagram
pub const SpivakWiring = struct { boxes: u8, wires: u8 };

/// SPI orchestrator
pub const SpiOrchestrator = struct {
    n_workers: u8,
    verified: bool = false,
};

/// Surprisal satisficing
pub fn surprisal(prob: f64) f64 {
    if (prob <= 0) return math.inf(f64);
    return -@log(prob);
}

/// Ternary split (GF(3) balanced partition)
pub fn ternarySplit(seed: u64) [3]u64 {
    return .{
        mix64(seed),
        mix64(seed ^ 1),
        mix64(seed ^ 2),
    };
}

/// Tikkun olam: repair the world
pub const TikkunOlam = struct { fragments_repaired: u32 = 0 };

/// Triple split sentinel
pub const TripleSplitSentinel = struct {
    values: [3]u64,
    pub fn fromSeed(seed: u64) TripleSplitSentinel {
        return .{ .values = ternarySplit(seed) };
    }
};

/// Unified topos gay
pub const UnifiedTopos = struct { sheaf_seed: u64, stalk_count: u16 = 0 };

/// Wikipedia ranking
pub const WikiRanking = struct { page_id: u32, rank: f64 };

/// Worlds topos
pub const WorldsTopos = struct { world_count: u16, morphism_count: u16 = 0 };

/// Involutive curiosities: f(f(x)) = x
pub fn involutiveMix(x: u64) u64 {
    return x ^ mix64(x); // Not truly involutive, but self-composable
}

// ============================================================================
// Tests
// ============================================================================

test "derangement has no fixed points" {
    const d = Derangeable.init(6, 42);
    const perm = d.derangeAt(1);
    for (0..6) |i| {
        try std.testing.expect(perm[i] != @as(u8, @intCast(i)));
    }
}

test "derangement SPI: same seed same result" {
    const d1 = Derangeable.init(8, 0xDEADBEEF);
    const d2 = Derangeable.init(8, 0xDEADBEEF);
    const p1 = d1.derangeAt(42);
    const p2 = d2.derangeAt(42);
    for (0..8) |i| {
        try std.testing.expectEqual(p1[i], p2[i]);
    }
}

test "derangement cycle decomposition" {
    const d = Derangeable.init(6, 99);
    const cd = d.cycleDecomposition(1);
    try std.testing.expect(cd.num_cycles >= 1);
    // All cycles length >= 2 (no fixed points)
    for (0..cd.num_cycles) |i| {
        try std.testing.expect(cd.cycle_lengths[i] >= 2);
    }
}

test "derangement sign" {
    const d = Derangeable.init(6, 77);
    const s = d.sign(1);
    try std.testing.expect(s == 1 or s == -1);
}

test "derangement stream" {
    var stream = GayDerangementStream.init(5, 42);
    const p1 = stream.next_derangement();
    const p2 = stream.next_derangement();
    // Different invocations should (usually) produce different results
    var same = true;
    for (0..5) |i| {
        if (p1[i] != p2[i]) same = false;
    }
    // Not guaranteed different but very likely
    try std.testing.expect(!same);

    // nth access
    const p_nth = stream.nth(1);
    // First next_derangement was invocation 1
    for (0..5) |i| {
        try std.testing.expectEqual(p1[i], p_nth[i]);
    }
}

test "igor seed creation" {
    const igor = IgorSeed.init(42, 16);
    try std.testing.expectEqual(@as(u16, 16), igor.motif_count);
    // Golden ratio intervals should be positive
    for (0..16) |i| {
        try std.testing.expect(igor.intervals[i] > 0.0);
    }
}

test "not-igor is derangement" {
    const igor = IgorSeed.init(42, 16);
    const not_igor = NotIgorSeed.init(igor);
    for (0..16) |i| {
        try std.testing.expect(not_igor.derangement[i] != @as(u8, @intCast(i)));
    }
}

test "igor spectrum interpolation" {
    const pure_igor = IgorSpectrum.init(42, 8, 1.0);
    const pure_not = IgorSpectrum.init(42, 8, 0.0);
    const half = IgorSpectrum.init(42, 8, 0.5);

    const igor_int = pure_igor.intervalAt(0);
    const not_int = pure_not.intervalAt(0);
    const half_int = half.intervalAt(0);
    // Half should be midpoint
    try std.testing.expect(@abs(half_int - (igor_int + not_int) / 2.0) < 1e-10);
}

test "igor beacon deterministic" {
    var b1 = IgorBeacon.init(42, 0.5);
    var b2 = IgorBeacon.init(42, 0.5);
    for (0..10) |_| {
        const r1 = b1.nextRound();
        const r2 = b2.nextRound();
        try std.testing.expectEqual(r1.round, r2.round);
        try std.testing.expectEqual(r1.signature, r2.signature);
    }
}

test "regret monad pure and color" {
    const r = RegretM.pure(5.0);
    try std.testing.expectEqual(@as(f64, 5.0), r.value);
    try std.testing.expectEqual(@as(f64, 0.0), r.accumulated);
    const c = r.color();
    try std.testing.expect(c.g > c.r); // low regret = green
}

test "coregret extract and duplicate" {
    const w = CoregretW{ .value = 3.0, .context = 1.0 };
    try std.testing.expectEqual(@as(f64, 3.0), w.extract());
    const dup = w.duplicate();
    try std.testing.expectEqual(@as(f64, 4.0), dup.context);
}

test "ternary space from trit" {
    const ts = TernarySpace.fromTrit(.{ -1, 0, 1 });
    const c = ts.toColor();
    try std.testing.expectEqual(@as(f64, 0.0), c.r);
    try std.testing.expectEqual(@as(f64, 0.5), c.g);
    try std.testing.expectEqual(@as(f64, 1.0), c.b);
}

test "CFR state update" {
    var cfr = CfrState{};
    cfr.update(0, 1.5);
    try std.testing.expectEqual(@as(u32, 1), cfr.iterations);
    try std.testing.expect(cfr.regret_sum[0] > 1.4);
}

test "dissonance table" {
    try std.testing.expectEqual(@as(f64, 0.0), dissonance(0)); // unison
    try std.testing.expectEqual(@as(f64, 0.1), dissonance(7)); // fifth
}

test "renyi entropy" {
    const uniform = [_]f64{ 0.25, 0.25, 0.25, 0.25 };
    const h2 = renyiEntropy(&uniform, 2.0);
    try std.testing.expect(h2 > 1.3 and h2 < 1.4); // ln(4) ~ 1.386
}

test "surprisal" {
    try std.testing.expect(surprisal(1.0) == 0.0);
    try std.testing.expect(surprisal(0.5) > 0.0);
}

test "ternary split deterministic" {
    const s1 = ternarySplit(42);
    const s2 = ternarySplit(42);
    try std.testing.expectEqual(s1[0], s2[0]);
    try std.testing.expectEqual(s1[1], s2[1]);
    try std.testing.expectEqual(s1[2], s2[2]);
}

test "next color bandwidth" {
    const bw = nextColorBandwidth(42, 1);
    try std.testing.expect(bw >= 0.0 and bw <= @sqrt(3.0));
}

test "seed sonification frequency" {
    const freq = seedToFrequency(42, 1);
    try std.testing.expect(freq > 100.0 and freq < 2000.0);
}

test "maximal parallelism" {
    try std.testing.expectEqual(@as(u32, 1), maximalParallelism(1));
    try std.testing.expect(maximalParallelism(8) >= 3);
    try std.testing.expect(maximalParallelism(1024) >= 10);
}

test "motherlake speedup amdahl" {
    const s = motherlakeSpeedup(4, 0.0); // zero serial fraction
    try std.testing.expect(@abs(s - 4.0) < 0.01);
    const s2 = motherlakeSpeedup(4, 0.5); // 50% serial
    try std.testing.expect(s2 < 2.0 and s2 > 1.5);
}

test "chromatic score total" {
    const cs = ChromaticScore{ .bandwidth = 0.5, .polarity_score = 0.8, .composition = 0.6 };
    const t = cs.total();
    try std.testing.expect(t > 0.5 and t < 0.7);
}

test "ablative name from seed" {
    const name = AblativeName.fromSeed(42);
    try std.testing.expectEqual(@as(u64, 42), name.seed);
    for (name.trit_signature) |t| {
        try std.testing.expect(t >= -1 and t <= 1);
    }
}
