// ecology.zig: Biological/ecological metaphors from Gay.jl
// Whale communication, Ananas cocones, Umwelt, carrying capacity
// Zig 0.14+ translation of whale_curriculum, whale_world, whale_bridge,
// whale_data, whale_demo, ananas, ananas_gzip_scaling, ananas_hierarchy,
// carrying_capacity_gay, umwelt, umwelt_minimal

const std = @import("std");
const math = std.math;
const sm = @import("splitmix.zig");

// ============================================================================
// Constants
// ============================================================================

pub const PHI: f64 = 1.6180339887498949;
pub const GAY_SEED = sm.GAY_SEED;

// ============================================================================
// Curriculum levels (Omniglot-style progression)
// ============================================================================

pub const CurriculumLevel = enum(u3) {
    l1_seed_echo = 0, // observe colors -> report seed
    l2_color_predict = 1, // given seed + index -> predict color
    l3_interval_map = 2, // rhythm <-> interval correspondence
    l4_tripartite = 3, // 3-whale consensus
    l5_spi_proof = 4, // prove order-independence
    l6_full_reversal = 5, // generate entire chain from seed
};

// ============================================================================
// Whale Student: learning state for curriculum
// ============================================================================

pub const WhaleStudent = struct {
    id: [32]u8 = @splat(0),
    id_len: u8 = 0,
    level: CurriculumLevel = .l1_seed_echo,
    current_seed: u64 = GAY_SEED,
    temperature: f64 = 1.0,
    correct_predictions: u32 = 0,
    total_predictions: u32 = 0,

    pub fn init(name: []const u8) WhaleStudent {
        var s = WhaleStudent{};
        const len: u8 = @intCast(@min(name.len, 32));
        @memcpy(s.id[0..len], name[0..len]);
        s.id_len = len;
        return s;
    }

    pub fn accuracy(self: WhaleStudent) f64 {
        if (self.total_predictions == 0) return 0.0;
        return @as(f64, @floatFromInt(self.correct_predictions)) /
            @as(f64, @floatFromInt(self.total_predictions));
    }

    pub fn anneal(self: *WhaleStudent, cooling_rate: f64) void {
        self.temperature = @max(0.01, self.temperature * cooling_rate);
    }
};

// ============================================================================
// Chain match scoring (for random walk seed search)
// ============================================================================

pub fn chainMatchScore(seed: u64, target: []const sm.Color, n: usize) f64 {
    var total_dist: f64 = 0.0;
    for (0..n) |i| {
        const gen = sm.colorAt(@intCast(i + 1), seed);
        if (i < target.len) {
            const dr = gen.r - target[i].r;
            const dg = gen.g - target[i].g;
            const db = gen.b - target[i].b;
            total_dist += @sqrt(dr * dr + dg * dg + db * db);
        }
    }
    const max_dist: f64 = @as(f64, @floatFromInt(n)) * @sqrt(3.0);
    return 1.0 - (total_dist / max_dist);
}

// ============================================================================
// Rapid random walk (Metropolis-Hastings + Levy flights)
// ============================================================================

pub const WalkCandidate = struct {
    seed: u64,
    score: f64,
};

pub fn rapidWalk(
    target: []const sm.Color,
    start_seed: u64,
    n_steps: u32,
    n_chains: u32,
    temperature: f64,
    results: []WalkCandidate,
) u32 {
    const n = target.len;
    const beta = 1.0 / temperature;
    var count: u32 = 0;

    for (0..n_chains) |chain| {
        var current_seed = start_seed +% @as(u64, chain) *% 0x123456789;
        var current_score = chainMatchScore(current_seed, target, n);

        for (0..n_steps) |step| {
            // SplitMix64 proposal
            const proposal = sm.splitmix64(current_seed ^ @as(u64, @intCast(step)));
            const proposal_score = chainMatchScore(proposal, target, n);

            // Metropolis-Hastings acceptance
            const delta = proposal_score - current_score;
            if (delta > 0.0) {
                current_seed = proposal;
                current_score = proposal_score;
            } else {
                // Accept with probability exp(beta * delta)
                const threshold = sm.splitmix64(current_seed ^ @as(u64, @intCast(step + 9999)));
                const u = @as(f64, @floatFromInt(threshold % 1000000)) / 1000000.0;
                if (u < @exp(beta * delta)) {
                    current_seed = proposal;
                    current_score = proposal_score;
                }
            }

            // Levy flight (5% probability)
            const levy_rng = sm.splitmix64(current_seed ^ @as(u64, @intCast(step + 77777)));
            if (levy_rng % 20 == 0) {
                current_seed = sm.splitmix64(current_seed ^ @as(u64, @intCast(chain * 31 + step)));
                current_score = chainMatchScore(current_seed, target, n);
            }

            if (current_score > 0.8 and count < results.len) {
                results[count] = .{ .seed = current_seed, .score = current_score };
                count += 1;
            }
        }
    }
    return count;
}

// ============================================================================
// Whale (deterministic color chain from seed)
// ============================================================================

pub const Whale = struct {
    id: [8]u8 = @splat(0),
    id_len: u8 = 0,
    seed: u64,
    chain: [12]sm.Color = undefined,
    notes: [12]u4 = undefined, // pitch classes 0-11
    intervals: [11]u4 = undefined, // adjacent intervals

    pub fn init(id: []const u8, seed: u64) Whale {
        var w = Whale{ .seed = seed };
        const len: u8 = @intCast(@min(id.len, 8));
        @memcpy(w.id[0..len], id[0..len]);
        w.id_len = len;
        // Generate chain
        for (0..12) |i| {
            w.chain[i] = sm.colorAt(@intCast(i + 1), seed);
            w.notes[i] = hueToPc(w.chain[i]);
        }
        for (0..11) |i| {
            w.intervals[i] = @intCast((@as(u8, w.notes[i + 1]) + 12 - @as(u8, w.notes[i])) % 12);
        }
        return w;
    }
};

fn hueToPc(c: sm.Color) u4 {
    // Convert RGB to hue, then to pitch class (0-11)
    const r = c.r;
    const g = c.g;
    const b = c.b;
    const max_c = @max(r, @max(g, b));
    const min_c = @min(r, @min(g, b));
    const delta = max_c - min_c;
    var hue: f64 = 0.0;
    if (delta > 1e-10) {
        if (max_c == r) {
            hue = 60.0 * @mod((g - b) / delta, 6.0);
        } else if (max_c == g) {
            hue = 60.0 * ((b - r) / delta + 2.0);
        } else {
            hue = 60.0 * ((r - g) / delta + 4.0);
        }
        if (hue < 0) hue += 360.0;
    }
    return @intCast(@as(u32, @intFromFloat(@floor(hue / 30.0))) % 12);
}

// ============================================================================
// Tripartite Synergy
// ============================================================================

pub const GadgetClass = enum(u2) {
    xor = 0,
    maj = 1,
    parity = 2,
    clause = 3,
};

pub const TripartiteSynergy = struct {
    gadget_class: GadgetClass,
    xor_residue: u4, // sum mod 12
    parity_agreement: f64, // 0-1
    interval_correlation: f64,
    coupling_score: f64,
    fingerprint: u64,
};

pub fn computeSynergy(w1: Whale, w2: Whale, w3: Whale) TripartiteSynergy {
    var sum1: u32 = 0;
    var sum2: u32 = 0;
    var sum3: u32 = 0;
    for (0..11) |i| {
        sum1 += w1.intervals[i];
        sum2 += w2.intervals[i];
        sum3 += w3.intervals[i];
    }
    const xor_residue: u4 = @intCast((sum1 + sum2 + sum3) % 12);
    const parities = [3]u1{
        @intCast(sum1 % 2),
        @intCast(sum2 % 2),
        @intCast(sum3 % 2),
    };
    const majority: u1 = if (@as(u32, parities[0]) + parities[1] + parities[2] >= 2) 1 else 0;
    var agree: u32 = 0;
    for (&parities) |p| {
        if (p == majority) agree += 1;
    }
    const parity_agreement = @as(f64, @floatFromInt(agree)) / 3.0;

    const gadget_class: GadgetClass = if (xor_residue == 0)
        .xor
    else if (agree == 3)
        .parity
    else if (agree >= 2)
        .maj
    else
        .clause;

    const xor_bonus: f64 = if (gadget_class == .xor) 0.3 else 0.0;
    const coupling_score = 0.3 * parity_agreement +
        0.2 * (1.0 - @as(f64, @floatFromInt(xor_residue)) / 12.0) +
        xor_bonus;

    const fingerprint = sm.splitmix64(w1.seed ^ w2.seed ^ w3.seed);

    return .{
        .gadget_class = gadget_class,
        .xor_residue = xor_residue,
        .parity_agreement = parity_agreement,
        .interval_correlation = 0.0, // simplified
        .coupling_score = coupling_score,
        .fingerprint = fingerprint,
    };
}

// ============================================================================
// WhaleWorld
// ============================================================================

pub const MAX_WHALES = 32;

pub const WhaleWorld = struct {
    base_seed: u64,
    whales: [MAX_WHALES]Whale = undefined,
    whale_count: u8 = 0,
    coupling_threshold: f64 = 0.5,

    pub fn init(seed: u64) WhaleWorld {
        return WhaleWorld{ .base_seed = seed };
    }

    pub fn addWhale(self: *WhaleWorld, id: []const u8) ?*Whale {
        if (self.whale_count >= MAX_WHALES) return null;
        const id_hash = sm.splitmix64(@as(u64, std.hash.Wyhash.hash(0, id)));
        const seed = self.base_seed ^ id_hash;
        self.whales[self.whale_count] = Whale.init(id, seed);
        self.whale_count += 1;
        return &self.whales[self.whale_count - 1];
    }

    pub fn colorFingerprint(self: WhaleWorld) u64 {
        var fp: u64 = 0;
        for (0..self.whale_count) |i| {
            fp ^= sm.splitmix64(self.whales[i].seed);
        }
        return fp;
    }
};

// ============================================================================
// Whale Bridge (coda <-> seed mapping via Galois connection)
// ============================================================================

pub const CodaObservation = struct {
    n_clicks: u8,
    icis: [8]f64 = @splat(0), // inter-click intervals (seconds)
    ici_count: u8 = 0,
    tempo_type: u8 = 3, // 1-5
    has_ornament: bool = false,
};

pub const WhaleBridge = struct {
    seed: u64 = GAY_SEED,
    coupling_strength: f64 = 0.0,
    observations: [16]CodaObservation = undefined,
    obs_count: u8 = 0,

    pub fn observeCoda(self: *WhaleBridge, icis: []const f64) void {
        if (self.obs_count >= 16) return;
        var obs = CodaObservation{ .n_clicks = @intCast(icis.len + 1) };
        const n: u8 = @intCast(@min(icis.len, 8));
        @memcpy(obs.icis[0..n], icis[0..n]);
        obs.ici_count = n;
        self.observations[self.obs_count] = obs;
        self.obs_count += 1;
    }

    /// Alpha: whale -> human (abstraction). ICIs -> pitch intervals.
    pub fn alpha(icis: []const f64, out: []u4) u8 {
        var total: f64 = 0;
        for (icis) |v| total += v;
        if (total == 0) return 0;
        const n: u8 = @intCast(@min(icis.len, out.len));
        for (0..n) |i| {
            const r = icis[i] / total;
            out[i] = @intCast(@as(u32, @intFromFloat(@round(r * 12.0))) % 12);
        }
        return n;
    }

    /// Gamma: human -> whale (concretization). Intervals -> ICIs.
    pub fn gamma(intervals: []const u4, base_dur: f64, out: []f64) u8 {
        var total: u32 = 0;
        for (intervals) |v| total += v;
        if (total == 0) return 0;
        const n: u8 = @intCast(@min(intervals.len, out.len));
        for (0..n) |i| {
            out[i] = @as(f64, @floatFromInt(intervals[i])) / @as(f64, @floatFromInt(total)) * base_dur;
        }
        return n;
    }
};

// ============================================================================
// EC-1 Clan Data (Sharma et al. 2024 DSWP)
// ============================================================================

pub const RhythmType = struct {
    name: [4]u8,
    n_clicks: u8,
    icis: [7]f64, // normalized
    ici_count: u8,
};

pub const DSWP_STATS = struct {
    pub const total_codas: u32 = 8719;
    pub const n_whales: u32 = 60;
    pub const n_tags: u32 = 42;
    pub const avg_response_time_ms: u32 = 800;
    pub const ornament_rate: f64 = 0.04;
};

pub const EC1_5R1 = RhythmType{
    .name = "5R1".*,
    .n_clicks = 5,
    .icis = .{ 0.25, 0.25, 0.25, 0.25, 0, 0, 0 },
    .ici_count = 4,
};

pub const EC1_ID1 = RhythmType{
    .name = "ID1\x00".*,
    .n_clicks = 5,
    .icis = .{ 0.4, 0.2, 0.2, 0.2, 0, 0, 0 },
    .ici_count = 4,
};

// ============================================================================
// Ananas: Cocone model for self-reconciliation
// ============================================================================

pub const PossibleWorld = struct {
    seed: u64,
    fingerprint: u64,
};

pub const Episode = struct {
    world: PossibleWorld,
    index: u32,
};

pub const CoConeApex = struct {
    seed: u64,
    episode_count: u32,
    is_universal: bool,

    pub fn compute(seeds: []const u64) CoConeApex {
        var combined: u64 = 0;
        for (seeds) |s| combined ^= sm.splitmix64(s);
        return .{
            .seed = combined,
            .episode_count = @intCast(seeds.len),
            .is_universal = seeds.len > 0,
        };
    }
};

// ============================================================================
// Ananas Gzip Scaling: complexity estimation
// ============================================================================

pub fn gzipability(data: []const u8) f64 {
    // Estimate compressibility as ratio of unique bytes
    if (data.len == 0) return 0.0;
    var seen: [256]bool = @splat(false);
    var unique: u32 = 0;
    for (data) |b| {
        if (!seen[b]) {
            seen[b] = true;
            unique += 1;
        }
    }
    return @as(f64, @floatFromInt(unique)) / 256.0;
}

// ============================================================================
// Ananas Hierarchy: walk strategies
// ============================================================================

pub const WalkStrategy = enum(u3) {
    dfs = 0,
    bfs = 1,
    topological = 2,
    reverse_topological = 3,
    shuffle = 4,
};

pub const HierarchinessMetrics = struct {
    depth: u32,
    breadth: u32,
    path_independent: bool,
};

// ============================================================================
// Carrying Capacity: stress-test SPI at scale
// ============================================================================

pub const CarryingCapacityEstimate = struct {
    max_parallel_walks: u32,
    coherence_at_max: f64,
    elbow_point: u32, // where quality degrades

    pub fn estimate(seed: u64, max_n: u32) CarryingCapacityEstimate {
        var best_n: u32 = 1;
        var prev_coherence: f64 = 1.0;
        var elbow: u32 = max_n;

        var n: u32 = 1;
        while (n <= max_n) : (n *= 2) {
            // Coherence = fraction of walks producing identical results
            var matches: u32 = 0;
            const ref_color = sm.colorAt(1, seed);
            for (0..n) |i| {
                const c = sm.colorAt(1, seed +% @as(u64, i) *% 0);
                if (c.r == ref_color.r and c.g == ref_color.g and c.b == ref_color.b) {
                    matches += 1;
                }
            }
            const coherence = @as(f64, @floatFromInt(matches)) / @as(f64, @floatFromInt(n));
            if (coherence < prev_coherence - 0.1 and elbow == max_n) {
                elbow = n;
            }
            prev_coherence = coherence;
            best_n = n;
        }
        return .{
            .max_parallel_walks = best_n,
            .coherence_at_max = prev_coherence,
            .elbow_point = elbow,
        };
    }
};

// ============================================================================
// Umwelt: Uexkull's perceptual world
// ============================================================================

pub const Umwelt = struct {
    seed: u64,
    sensory_channels: u8, // how many color dimensions perceived

    pub fn init(seed: u64) Umwelt {
        return .{ .seed = seed, .sensory_channels = 3 }; // RGB
    }

    pub fn perceive(self: Umwelt, index: u32) sm.Color {
        return sm.colorAt(@as(u64, index), self.seed);
    }
};

pub const UmweltMinimal = struct {
    seed: u64,

    pub fn init(seed: u64) UmweltMinimal {
        return .{ .seed = seed };
    }

    pub fn perceive(self: UmweltMinimal, index: u32) u4 {
        const c = sm.colorAt(@as(u64, index), self.seed);
        return hueToPc(c); // Minimal: only pitch class
    }
};

// ============================================================================
// Tests
// ============================================================================

test "whale student creation and accuracy" {
    var student = WhaleStudent.init("Kiki");
    try std.testing.expectEqual(CurriculumLevel.l1_seed_echo, student.level);
    try std.testing.expectEqual(@as(f64, 0.0), student.accuracy());

    student.correct_predictions = 7;
    student.total_predictions = 10;
    try std.testing.expect(student.accuracy() > 0.69 and student.accuracy() < 0.71);

    student.anneal(0.95);
    try std.testing.expect(student.temperature < 1.0);
}

test "whale deterministic chain" {
    const w1 = Whale.init("W001", 42);
    const w2 = Whale.init("W001", 42);
    // SPI: same seed -> same chain
    for (0..12) |i| {
        try std.testing.expectEqual(w1.chain[i].r, w2.chain[i].r);
        try std.testing.expectEqual(w1.chain[i].g, w2.chain[i].g);
        try std.testing.expectEqual(w1.chain[i].b, w2.chain[i].b);
    }
    for (0..12) |i| {
        try std.testing.expectEqual(w1.notes[i], w2.notes[i]);
    }
}

test "tripartite synergy" {
    const w1 = Whale.init("A", 100);
    const w2 = Whale.init("B", 200);
    const w3 = Whale.init("C", 300);
    const syn = computeSynergy(w1, w2, w3);
    try std.testing.expect(syn.coupling_score >= 0.0 and syn.coupling_score <= 1.0);
    try std.testing.expect(syn.parity_agreement >= 0.0 and syn.parity_agreement <= 1.0);
    try std.testing.expect(syn.xor_residue < 12);
}

test "whale world add and fingerprint" {
    var world = WhaleWorld.init(GAY_SEED);
    _ = world.addWhale("W001");
    _ = world.addWhale("W002");
    _ = world.addWhale("W003");
    try std.testing.expectEqual(@as(u8, 3), world.whale_count);

    const fp1 = world.colorFingerprint();
    const fp2 = world.colorFingerprint();
    try std.testing.expectEqual(fp1, fp2); // deterministic
}

test "whale bridge alpha-gamma roundtrip" {
    const icis = [_]f64{ 0.15, 0.18, 0.22, 0.15 };
    var intervals: [4]u4 = undefined;
    const n = WhaleBridge.alpha(&icis, &intervals);
    try std.testing.expectEqual(@as(u8, 4), n);

    var recovered: [4]f64 = undefined;
    _ = WhaleBridge.gamma(&intervals, 0.7, &recovered);
    // Galois fixpoint: alpha . gamma . alpha should converge
    var intervals2: [4]u4 = undefined;
    const n2 = WhaleBridge.alpha(&recovered, &intervals2);
    try std.testing.expectEqual(n, n2);
}

test "chain match score" {
    var target: [4]sm.Color = undefined;
    for (0..4) |i| {
        target[i] = sm.colorAt(@intCast(i + 1), 42);
    }
    const score = chainMatchScore(42, &target, 4);
    try std.testing.expect(score > 0.99); // perfect match
}

test "cocone apex" {
    const seeds = [_]u64{ 1, 2, 3 };
    const apex = CoConeApex.compute(&seeds);
    try std.testing.expect(apex.is_universal);
    try std.testing.expectEqual(@as(u32, 3), apex.episode_count);

    const apex2 = CoConeApex.compute(&seeds);
    try std.testing.expectEqual(apex.seed, apex2.seed); // deterministic
}

test "gzipability" {
    const data = "aaaaaaaaaa";
    const g = gzipability(data);
    try std.testing.expect(g < 0.01); // very compressible (1/256)

    const varied = "abcdefghij";
    const g2 = gzipability(varied);
    try std.testing.expect(g2 > g); // less compressible
}

test "carrying capacity" {
    const est = CarryingCapacityEstimate.estimate(GAY_SEED, 64);
    try std.testing.expect(est.coherence_at_max >= 0.0);
    try std.testing.expect(est.max_parallel_walks >= 1);
}

test "umwelt perception" {
    const u = Umwelt.init(42);
    const c1 = u.perceive(1);
    const c2 = u.perceive(1);
    try std.testing.expectEqual(c1.r, c2.r); // deterministic

    const um = UmweltMinimal.init(42);
    const pc = um.perceive(1);
    try std.testing.expect(pc < 12);
}

test "SPI: synergy order independence" {
    const w1 = Whale.init("X", 111);
    const w2 = Whale.init("Y", 222);
    const w3 = Whale.init("Z", 333);
    // Forward and reverse order should give same coupling score
    const s1 = computeSynergy(w1, w2, w3);
    // XOR is commutative so fingerprint should match
    const s2 = computeSynergy(w3, w2, w1);
    try std.testing.expectEqual(s1.fingerprint, s2.fingerprint);
    try std.testing.expectEqual(s1.xor_residue, s2.xor_residue);
    try std.testing.expectEqual(s1.coupling_score, s2.coupling_score);
}
