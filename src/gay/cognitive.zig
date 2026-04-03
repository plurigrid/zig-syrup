// cognitive.zig: Cognitive Superposition + Metatheory Brushes
// Zig translation of Gay.jl cognitive_superposition.jl & metatheory_brushes.jl
//
// Cognitive superposition: quantum-inspired superposed color states,
// collapse on observation, entanglement between concepts.
// Metatheory brushes: rewriting rules as colored brush strokes,
// e-graph style equality saturation with color tracking.

const std = @import("std");
const math = std.math;
const splitmix = @import("splitmix.zig");
const Color = splitmix.Color;

// ============================================================================
// Complex number (f64)
// ============================================================================

pub const Complex = struct {
    re: f64,
    im: f64,

    pub const zero = Complex{ .re = 0, .im = 0 };
    pub const one = Complex{ .re = 1, .im = 0 };

    pub fn add(a: Complex, b: Complex) Complex {
        return .{ .re = a.re + b.re, .im = a.im + b.im };
    }

    pub fn sub(a: Complex, b: Complex) Complex {
        return .{ .re = a.re - b.re, .im = a.im - b.im };
    }

    pub fn mul(a: Complex, b: Complex) Complex {
        return .{
            .re = a.re * b.re - a.im * b.im,
            .im = a.re * b.im + a.im * b.re,
        };
    }

    pub fn scale(self: Complex, s: f64) Complex {
        return .{ .re = self.re * s, .im = self.im * s };
    }

    pub fn conj(self: Complex) Complex {
        return .{ .re = self.re, .im = -self.im };
    }

    pub fn abs2(self: Complex) f64 {
        return self.re * self.re + self.im * self.im;
    }

    pub fn fromReal(r: f64) Complex {
        return .{ .re = r, .im = 0 };
    }
};

// ============================================================================
// Grammar types
// ============================================================================

pub const GrammarType = enum(u8) {
    N, // Noun
    S, // Sentence
    NP, // Noun phrase
    VP, // Verb phrase
    X, // Generic / spider
};

// ============================================================================
// Hash color helper (mirrors splitmix)
// ============================================================================

fn hashColor(seed: u64, extra: u64) Color {
    const h = splitmix.splitmix64(seed ^ extra);
    const r: f64 = @as(f64, @floatFromInt(h & 0xFFFF)) / 65535.0;
    const g: f64 = @as(f64, @floatFromInt((h >> 16) & 0xFFFF)) / 65535.0;
    const b: f64 = @as(f64, @floatFromInt((h >> 32) & 0xFFFF)) / 65535.0;
    return .{ .r = r, .g = g, .b = b };
}

fn countOnes(x: u64) u7 {
    return @popCount(x);
}

// ============================================================================
// CognitiveState: Superposition of meanings
// ============================================================================

pub const MAX_DIM = 16;

pub const CognitiveState = struct {
    amplitudes: [MAX_DIM]Complex,
    basis_colors: [MAX_DIM]Color,
    dim: usize,
    fingerprint: u64,
    grammar_type: GrammarType,
    seed: u64,

    pub fn init(dim: usize, grammar_type: GrammarType, seed: u64) CognitiveState {
        var self = CognitiveState{
            .amplitudes = [_]Complex{Complex.zero} ** MAX_DIM,
            .basis_colors = [_]Color{.{ .r = 0, .g = 0, .b = 0 }} ** MAX_DIM,
            .dim = dim,
            .fingerprint = 0,
            .grammar_type = grammar_type,
            .seed = seed,
        };
        self.amplitudes[0] = Complex.one;

        var fp: u64 = 0;
        for (0..dim) |i| {
            self.basis_colors[i] = hashColor(seed, @as(u64, i) + 1);
            fp ^= splitmix.splitmix64(seed ^ (@as(u64, i) + 1));
        }
        self.fingerprint = fp;
        return self;
    }

    /// Collapse to definite basis state (deterministic via fingerprint)
    pub fn collapse(self: *const CognitiveState) struct { index: usize, color: Color } {
        // Probability distribution
        var total: f64 = 0;
        var probs: [MAX_DIM]f64 = [_]f64{0} ** MAX_DIM;
        for (0..self.dim) |i| {
            probs[i] = self.amplitudes[i].abs2();
            total += probs[i];
        }
        if (total < 1e-10) return .{ .index = 0, .color = self.basis_colors[0] };

        const r: f64 = @as(f64, @floatFromInt(self.fingerprint % 10000)) / 10000.0;
        var cumsum: f64 = 0;
        for (0..self.dim) |i| {
            cumsum += probs[i] / total;
            if (r < cumsum) return .{ .index = i, .color = self.basis_colors[i] };
        }
        return .{ .index = self.dim - 1, .color = self.basis_colors[self.dim - 1] };
    }
};

/// Create superposition of two states with real weights
pub fn superpose(a: *const CognitiveState, b: *const CognitiveState, wa: f64, wb: f64) CognitiveState {
    var result = a.*;
    const dim = a.dim;

    for (0..dim) |i| {
        result.amplitudes[i] = Complex.add(
            a.amplitudes[i].scale(wa),
            b.amplitudes[i].scale(wb),
        );
    }

    // Normalize
    var norm: f64 = 0;
    for (0..dim) |i| norm += result.amplitudes[i].abs2();
    norm = @sqrt(norm);
    if (norm > 1e-10) {
        for (0..dim) |i| result.amplitudes[i] = result.amplitudes[i].scale(1.0 / norm);
    }

    result.fingerprint = a.fingerprint ^ b.fingerprint;
    return result;
}

// ============================================================================
// Entailment / Induction / Abduction
// ============================================================================

/// Degree of entailment in [0, 1]
pub fn entails(premise: *const CognitiveState, conclusion: *const CognitiveState) f64 {
    const dim = @min(premise.dim, conclusion.dim);
    var overlap = Complex.zero;
    for (0..dim) |i| {
        overlap = Complex.add(overlap, Complex.mul(premise.amplitudes[i].conj(), conclusion.amplitudes[i]));
    }
    const fp_xor = premise.fingerprint ^ conclusion.fingerprint;
    const hamming: f64 = @floatFromInt(countOnes(fp_xor));
    const chromatic_compat = 1.0 - hamming / 64.0;
    return (overlap.abs2() + chromatic_compat) / 2.0;
}

/// Inductive inference score
pub fn induces(evidence: *const CognitiveState, hypothesis: *const CognitiveState) f64 {
    // Color distance of strongest basis states
    var max_e: f64 = 0;
    var ei: usize = 0;
    for (0..evidence.dim) |i| {
        const a2 = evidence.amplitudes[i].abs2();
        if (a2 > max_e) {
            max_e = a2;
            ei = i;
        }
    }
    var max_h: f64 = 0;
    var hi: usize = 0;
    for (0..hypothesis.dim) |i| {
        const a2 = hypothesis.amplitudes[i].abs2();
        if (a2 > max_h) {
            max_h = a2;
            hi = i;
        }
    }
    const ec = evidence.basis_colors[ei];
    const hc = hypothesis.basis_colors[hi];
    const dr = ec.r - hc.r;
    const dg = ec.g - hc.g;
    const db = ec.b - hc.b;
    const dist = @sqrt(dr * dr + dg * dg + db * db);
    return 1.0 - dist / @sqrt(3.0);
}

/// Abductive inference score
pub fn abduces(observation: *const CognitiveState, cause: *const CognitiveState) f64 {
    const cause_entropy: f64 = @as(f64, @floatFromInt(countOnes(cause.fingerprint))) / 64.0;
    const obs_entropy: f64 = @as(f64, @floatFromInt(countOnes(observation.fingerprint))) / 64.0;
    const simplicity_bonus = @max(0.0, obs_entropy - cause_entropy);

    const dim = @min(cause.dim, observation.dim);
    var overlap = Complex.zero;
    for (0..dim) |i| {
        overlap = Complex.add(overlap, Complex.mul(cause.amplitudes[i].conj(), observation.amplitudes[i]));
    }
    return (overlap.abs2() + simplicity_bonus) / 2.0;
}

// ============================================================================
// BraidedSuperposition
// ============================================================================

pub const BraidedSuperposition = struct {
    left: CognitiveState,
    right: CognitiveState,
    braid_phase: Complex,
    fingerprint: u64,
};

pub fn cognitiveTensor(a: *const CognitiveState, b: *const CognitiveState) BraidedSuperposition {
    const fp = a.fingerprint ^ b.fingerprint;
    const angle = @as(f64, @floatFromInt(fp % 1000)) / 1000.0 * 2.0 * math.pi;
    return .{
        .left = a.*,
        .right = b.*,
        .braid_phase = .{ .re = @cos(angle), .im = @sin(angle) },
        .fingerprint = fp,
    };
}

pub fn braid(bs: *const BraidedSuperposition) BraidedSuperposition {
    return .{
        .left = bs.right,
        .right = bs.left,
        .braid_phase = bs.braid_phase.conj(),
        .fingerprint = splitmix.splitmix64(bs.fingerprint ^ 0xB8A1D1),
    };
}

// ============================================================================
// Frobenius spider (merge n inputs -> m outputs)
// ============================================================================

pub fn spiderMerge(inputs: []const CognitiveState, seed: u64) CognitiveState {
    var result = CognitiveState.init(if (inputs.len > 0) inputs[0].dim else 4, .X, seed);
    if (inputs.len == 0) return result;

    const dim = inputs[0].dim;
    result.dim = dim;

    // Sum all amplitudes
    for (0..dim) |i| {
        var sum = Complex.zero;
        for (inputs) |inp| sum = Complex.add(sum, inp.amplitudes[i]);
        result.amplitudes[i] = sum;
    }

    // Normalize
    var norm: f64 = 0;
    for (0..dim) |i| norm += result.amplitudes[i].abs2();
    norm = @sqrt(norm);
    if (norm > 1e-10) {
        for (0..dim) |i| result.amplitudes[i] = result.amplitudes[i].scale(1.0 / norm);
    }

    var fp: u64 = 0;
    for (inputs) |inp| fp ^= inp.fingerprint;
    result.fingerprint = fp;

    for (0..dim) |j| {
        result.basis_colors[j] = hashColor(seed, fp ^ (@as(u64, j) + 1));
    }
    return result;
}

pub fn spiderSplit(input: *const CognitiveState, n_out: usize, seed: u64) [MAX_DIM]CognitiveState {
    var outputs: [MAX_DIM]CognitiveState = undefined;
    for (0..n_out) |i| {
        outputs[i] = input.*;
        const out_fp = splitmix.splitmix64(input.fingerprint ^ (@as(u64, i) + 1));
        outputs[i].fingerprint = out_fp;
        for (0..input.dim) |j| {
            outputs[i].basis_colors[j] = hashColor(seed, out_fp ^ (@as(u64, j) + 1));
        }
    }
    return outputs;
}

// ============================================================================
// Chromatic Active Inference
// ============================================================================

pub const MAX_BELIEFS = 8;

pub const ChromaticActiveInference = struct {
    beliefs: [MAX_BELIEFS]CognitiveState,
    belief_names: [MAX_BELIEFS]u64, // name hashes
    n_beliefs: usize,
    fingerprint: u64,
    free_energy: f64,
    seed: u64,

    pub fn init(seed: u64) ChromaticActiveInference {
        return .{
            .beliefs = undefined,
            .belief_names = [_]u64{0} ** MAX_BELIEFS,
            .n_beliefs = 0,
            .fingerprint = seed,
            .free_energy = 0,
            .seed = seed,
        };
    }

    pub fn addBelief(self: *ChromaticActiveInference, name_hash: u64, state: CognitiveState) void {
        if (self.n_beliefs >= MAX_BELIEFS) return;
        self.beliefs[self.n_beliefs] = state;
        self.belief_names[self.n_beliefs] = name_hash;
        self.n_beliefs += 1;
        self.fingerprint ^= state.fingerprint;
    }

    pub fn predictionError(self: *const ChromaticActiveInference, observation_fp: u64) f64 {
        const error_fp = self.fingerprint ^ observation_fp;
        return @as(f64, @floatFromInt(countOnes(error_fp))) / 64.0;
    }

    pub fn dynamicSufficiency(self: *const ChromaticActiveInference) struct { fingerprint: u64, color: Color } {
        return .{
            .fingerprint = self.fingerprint,
            .color = hashColor(self.seed, self.fingerprint),
        };
    }
};

// ============================================================================
// XOR conservation verification
// ============================================================================

pub fn verifyParallelConservation(seed: u64, n_trials: usize) bool {
    var fps: [256]u64 = undefined;
    const n = @min(n_trials, 256);
    for (0..n) |i| fps[i] = splitmix.splitmix64(seed ^ @as(u64, i));

    // Commutativity
    for (0..n - 1) |i| {
        if ((fps[i] ^ fps[i + 1]) != (fps[i + 1] ^ fps[i])) return false;
    }
    // Identity
    for (0..n) |i| {
        if ((fps[i] ^ 0) != fps[i]) return false;
    }
    // Idempotence
    for (0..n) |i| {
        if ((fps[i] ^ fps[i]) != 0) return false;
    }
    return true;
}

// ============================================================================
// METATHEORY BRUSHES
// ============================================================================

pub const BrushColor = struct {
    r: f32,
    g: f32,
    b: f32,
    a: f32, // alpha / blend weight

    pub fn init(r: f32, g: f32, b: f32) BrushColor {
        return .{ .r = r, .g = g, .b = b, .a = 1.0 };
    }

    pub fn blend(c1: BrushColor, c2: BrushColor) BrushColor {
        const total = c1.a + c2.a;
        if (total < 0.001) return .{ .r = 0.5, .g = 0.5, .b = 0.5, .a = 0 };
        return .{
            .r = (c1.r * c1.a + c2.r * c2.a) / total,
            .g = (c1.g * c1.a + c2.g * c2.a) / total,
            .b = (c1.b * c1.a + c2.b * c2.a) / total,
            .a = @min(1.0, total),
        };
    }

    pub fn distance(a: BrushColor, b: BrushColor) f32 {
        const dr = a.r - b.r;
        const dg = a.g - b.g;
        const db = a.b - b.b;
        return @sqrt(dr * dr + dg * dg + db * db);
    }
};

fn mix64(x: u64) u64 {
    return splitmix.splitmix64(x);
}

fn brushColorFromSeed(state: *u64) BrushColor {
    state.* = mix64(state.*);
    const r: f32 = @floatFromInt(state.* % 256);
    state.* = mix64(state.*);
    const g: f32 = @floatFromInt(state.* % 256);
    state.* = mix64(state.*);
    const b: f32 = @floatFromInt(state.* % 256);
    return .{ .r = r / 255.0, .g = g / 255.0, .b = b / 255.0, .a = 1.0 };
}

// ============================================================================
// SheafifiedBrush: Local-to-Global consistency
// ============================================================================

pub const MAX_OPENS = 16;

pub const SheafifiedBrush = struct {
    seed: u64,
    n_opens: usize,
    total_size: usize,
    cover_start: [MAX_OPENS]usize,
    cover_end: [MAX_OPENS]usize,
    local_sections: [MAX_OPENS]BrushColor,
    overlap_matrix: [MAX_OPENS][MAX_OPENS]bool,

    pub fn init(seed: u64, n_opens: usize, total_size: usize) SheafifiedBrush {
        var self: SheafifiedBrush = undefined;
        self.seed = seed;
        self.n_opens = @min(n_opens, MAX_OPENS);
        self.total_size = total_size;
        self.overlap_matrix = [_][MAX_OPENS]bool{[_]bool{false} ** MAX_OPENS} ** MAX_OPENS;

        var rng = seed;
        for (0..self.n_opens) |i| {
            rng = mix64(rng);
            const start = 1 + @as(usize, @intCast(rng % @as(u64, total_size)));
            rng = mix64(rng);
            const len = 1 + @as(usize, @intCast(rng % @as(u64, total_size / 2)));
            self.cover_start[i] = start;
            self.cover_end[i] = @min(start + len - 1, total_size);
        }

        for (0..self.n_opens) |i| {
            self.local_sections[i] = brushColorFromSeed(&rng);
        }

        // Compute overlaps
        for (0..self.n_opens) |i| {
            for (0..self.n_opens) |j| {
                if (i != j) {
                    const overlap = self.cover_start[i] <= self.cover_end[j] and
                        self.cover_start[j] <= self.cover_end[i];
                    self.overlap_matrix[i][j] = overlap;
                }
            }
        }

        return self;
    }

    pub fn isConsistent(self: *const SheafifiedBrush, tolerance: f32) bool {
        for (0..self.n_opens) |i| {
            for (0..self.n_opens) |j| {
                if (self.overlap_matrix[i][j]) {
                    if (self.local_sections[i].distance(self.local_sections[j]) > tolerance) {
                        return false;
                    }
                }
            }
        }
        return true;
    }

    pub fn glueSections(self: *const SheafifiedBrush) ?BrushColor {
        if (!self.isConsistent(0.3)) return null;

        var r: f32 = 0;
        var g: f32 = 0;
        var b: f32 = 0;
        var total_weight: f32 = 0;
        for (0..self.n_opens) |i| {
            const w: f32 = @floatFromInt(self.cover_end[i] - self.cover_start[i] + 1);
            r += self.local_sections[i].r * w;
            g += self.local_sections[i].g * w;
            b += self.local_sections[i].b * w;
            total_weight += w;
        }
        if (total_weight > 0) {
            return BrushColor.init(r / total_weight, g / total_weight, b / total_weight);
        }
        return BrushColor.init(0.5, 0.5, 0.5);
    }
};

// ============================================================================
// StackifiedBrush: Descent to equivalence classes
// ============================================================================

pub const MAX_GROUP = 8;
pub const MAX_COLORS = 16;

pub const StackifiedBrush = struct {
    seed: u64,
    group_order: usize,
    n_colors: usize,
    representatives: [MAX_COLORS]BrushColor,
    action_matrix: [MAX_GROUP][MAX_COLORS]usize, // g * c -> index

    pub fn init(seed: u64, group_order: usize, n_colors: usize) StackifiedBrush {
        var self: StackifiedBrush = undefined;
        self.seed = seed;
        self.group_order = @min(group_order, MAX_GROUP);
        self.n_colors = @min(n_colors, MAX_COLORS);

        var rng = seed;
        for (0..self.n_colors) |i| {
            self.representatives[i] = brushColorFromSeed(&rng);
        }

        // Random permutation action
        for (0..self.group_order) |g_idx| {
            // Start with identity
            for (0..self.n_colors) |c| self.action_matrix[g_idx][c] = c;
            // Fisher-Yates shuffle
            var i = self.n_colors;
            while (i > 1) {
                i -= 1;
                rng = mix64(rng ^ @as(u64, g_idx));
                const j = @as(usize, @intCast(rng % @as(u64, i + 1)));
                const tmp = self.action_matrix[g_idx][i];
                self.action_matrix[g_idx][i] = self.action_matrix[g_idx][j];
                self.action_matrix[g_idx][j] = tmp;
            }
        }

        return self;
    }

    pub fn act(self: *const StackifiedBrush, g: usize, c: usize) usize {
        return self.action_matrix[g % self.group_order][c % self.n_colors];
    }

    const OrbitResult = struct { members: [MAX_COLORS]usize, len: usize };

    /// Find orbit of color c under group action
    pub fn equivalenceClass(self: *const StackifiedBrush, c: usize) OrbitResult {
        var result: OrbitResult = .{
            .members = [_]usize{0} ** MAX_COLORS,
            .len = 0,
        };
        // Collect orbit
        for (0..self.group_order) |g| {
            const img = self.act(g, c);
            // Check if already present
            var found = false;
            for (0..result.len) |k| {
                if (result.members[k] == img) {
                    found = true;
                    break;
                }
            }
            if (!found and result.len < MAX_COLORS) {
                result.members[result.len] = img;
                result.len += 1;
            }
        }
        return result;
    }

    pub fn areEquivalent(self: *const StackifiedBrush, c1: usize, c2: usize) bool {
        const orbit = self.equivalenceClass(c1);
        for (0..orbit.len) |k| {
            if (orbit.members[k] == c2) return true;
        }
        return false;
    }

    pub fn descentColor(self: *const StackifiedBrush, c: usize) BrushColor {
        const orbit = self.equivalenceClass(c);
        var min_idx: usize = orbit.members[0];
        for (1..orbit.len) |k| {
            if (orbit.members[k] < min_idx) min_idx = orbit.members[k];
        }
        return self.representatives[min_idx % self.n_colors];
    }
};

// ============================================================================
// CondensifiedBrush: Profinite completion
// ============================================================================

pub const MAX_LEVELS = 5;
pub const MAX_LEVEL_COLORS = 243; // 3^5

pub const CondensifiedBrush = struct {
    seed: u64,
    prime: usize,
    levels: usize,
    approximations: [MAX_LEVELS][MAX_LEVEL_COLORS]BrushColor,
    level_sizes: [MAX_LEVELS]usize,

    pub fn init(seed: u64, prime: usize, levels: usize) CondensifiedBrush {
        var self: CondensifiedBrush = undefined;
        self.seed = seed;
        self.prime = prime;
        self.levels = @min(levels, MAX_LEVELS);

        var rng = seed;
        for (0..self.levels) |n| {
            var n_colors: usize = 1;
            for (0..n + 1) |_| n_colors *= prime;
            self.level_sizes[n] = @min(n_colors, MAX_LEVEL_COLORS);

            for (0..self.level_sizes[n]) |i| {
                rng = mix64(rng ^ @as(u64, n + 1) ^ @as(u64, i + 1));
                const r: f32 = @floatFromInt(rng % 256);
                rng = mix64(rng);
                const g: f32 = @floatFromInt(rng % 256);
                rng = mix64(rng);
                const b: f32 = @floatFromInt(rng % 256);
                self.approximations[n][i] = BrushColor.init(r / 255.0, g / 255.0, b / 255.0);
            }
        }

        return self;
    }

    pub fn projectDown(self: *const CondensifiedBrush, c_idx: usize, from_level: usize) usize {
        if (from_level == 0) return 0;
        return c_idx % self.level_sizes[from_level - 1];
    }

    pub fn limitColor(self: *const CondensifiedBrush, idx: usize) BrushColor {
        const finest = self.levels - 1;
        return self.approximations[finest][idx % self.level_sizes[finest]];
    }
};

// ============================================================================
// Reafference: Self vs External signals
// ============================================================================

pub const Reafference = struct {
    efferent_copy: f64,
    actual_input: f64,
    threshold: f64,

    pub fn isReafferent(self: *const Reafference) bool {
        return @abs(self.efferent_copy - self.actual_input) < self.threshold;
    }

    pub fn isExafferent(self: *const Reafference) bool {
        return !self.isReafferent();
    }

    pub fn color(self: *const Reafference) BrushColor {
        if (self.isReafferent()) {
            return BrushColor.init(0.0, 0.8, 0.2); // Green (self)
        } else {
            return BrushColor.init(0.8, 0.2, 0.0); // Red (other)
        }
    }
};

pub const ReafferenceState = struct {
    reafferent_count: usize,
    exafferent_count: usize,
    threshold: f64,

    pub fn init(threshold: f64) ReafferenceState {
        return .{ .reafferent_count = 0, .exafferent_count = 0, .threshold = threshold };
    }

    pub fn observe(self: *ReafferenceState, prediction: f64, observation: f64) void {
        const r = Reafference{ .efferent_copy = prediction, .actual_input = observation, .threshold = self.threshold };
        if (r.isReafferent()) {
            self.reafferent_count += 1;
        } else {
            self.exafferent_count += 1;
        }
    }

    pub fn ratio(self: *const ReafferenceState) f64 {
        const total = self.reafferent_count + self.exafferent_count;
        if (total == 0) return 0.5;
        return @as(f64, @floatFromInt(self.reafferent_count)) / @as(f64, @floatFromInt(total));
    }
};

// ============================================================================
// MetatheoryTriple: Combined brushes
// ============================================================================

pub const MetatheoryTriple = struct {
    sheafified: SheafifiedBrush,
    stackified: StackifiedBrush,
    condensified: CondensifiedBrush,
    seed: u64,

    pub fn init(seed: u64, size: usize) MetatheoryTriple {
        return .{
            .sheafified = SheafifiedBrush.init(seed, size / 2, size),
            .stackified = StackifiedBrush.init(mix64(seed), 3, size),
            .condensified = CondensifiedBrush.init(mix64(mix64(seed)), 3, 4),
            .seed = seed,
        };
    }
};

// ============================================================================
// Tests
// ============================================================================

test "CognitiveState init and collapse" {
    const state = CognitiveState.init(4, .N, splitmix.GAY_SEED);
    try std.testing.expectEqual(@as(usize, 4), state.dim);
    try std.testing.expect(state.amplitudes[0].re == 1.0);
    try std.testing.expect(state.amplitudes[1].re == 0.0);
    try std.testing.expect(state.fingerprint != 0);

    const result = state.collapse();
    try std.testing.expect(result.index == 0); // |0> state collapses to 0
}

test "superpose preserves fingerprint XOR" {
    const a = CognitiveState.init(4, .N, splitmix.GAY_SEED);
    const b = CognitiveState.init(4, .N, splitmix.GAY_SEED ^ 0x1111);
    const sup = superpose(&a, &b, 0.7, 0.3);
    try std.testing.expectEqual(a.fingerprint ^ b.fingerprint, sup.fingerprint);
}

test "entails returns value in [0,1]" {
    const a = CognitiveState.init(4, .N, splitmix.GAY_SEED);
    const b = CognitiveState.init(4, .N, splitmix.GAY_SEED ^ 0xD06);
    const score = entails(&a, &b);
    try std.testing.expect(score >= 0.0 and score <= 1.0);
}

test "induces returns value in [0,1]" {
    const a = CognitiveState.init(4, .N, splitmix.GAY_SEED);
    const b = CognitiveState.init(4, .N, splitmix.GAY_SEED ^ 0xA171A1);
    const score = induces(&a, &b);
    try std.testing.expect(score >= 0.0 and score <= 1.0);
}

test "abduces returns value in [0,1]" {
    const a = CognitiveState.init(4, .N, splitmix.GAY_SEED);
    const b = CognitiveState.init(4, .N, splitmix.GAY_SEED ^ 0x1111);
    const score = abduces(&a, &b);
    try std.testing.expect(score >= 0.0 and score <= 1.0);
}

test "braid is involutive on fingerprints" {
    const a = CognitiveState.init(4, .N, splitmix.GAY_SEED);
    const b = CognitiveState.init(4, .N, splitmix.GAY_SEED ^ 0x1111);
    const ab = cognitiveTensor(&a, &b);
    const ba = braid(&ab);
    const ab2 = braid(&ba);
    // After double braid, left should match original left
    try std.testing.expectEqual(a.fingerprint, ab2.left.fingerprint);
}

test "spider merge then split" {
    const a = CognitiveState.init(4, .N, splitmix.GAY_SEED);
    const b = CognitiveState.init(4, .N, splitmix.GAY_SEED ^ 0x1111);
    const inputs = [_]CognitiveState{ a, b };
    const merged = spiderMerge(&inputs, splitmix.GAY_SEED);
    const splits = spiderSplit(&merged, 2, splitmix.GAY_SEED);
    try std.testing.expectEqual(merged.dim, splits[0].dim);
    try std.testing.expectEqual(merged.dim, splits[1].dim);
}

test "XOR conservation laws" {
    try std.testing.expect(verifyParallelConservation(splitmix.GAY_SEED, 100));
}

test "ChromaticActiveInference prediction error" {
    var cai = ChromaticActiveInference.init(splitmix.GAY_SEED);
    const state = CognitiveState.init(4, .N, splitmix.GAY_SEED);
    cai.addBelief(0x1234, state);
    const pe = cai.predictionError(splitmix.GAY_SEED ^ 0xFFFF);
    try std.testing.expect(pe >= 0.0 and pe <= 1.0);
}

test "BrushColor blend" {
    const c1 = BrushColor.init(1.0, 0.0, 0.0);
    const c2 = BrushColor.init(0.0, 1.0, 0.0);
    const blended = BrushColor.blend(c1, c2);
    try std.testing.expect(@abs(blended.r - 0.5) < 0.01);
    try std.testing.expect(@abs(blended.g - 0.5) < 0.01);
}

test "SheafifiedBrush init" {
    const brush = SheafifiedBrush.init(splitmix.GAY_SEED, 4, 20);
    try std.testing.expectEqual(@as(usize, 4), brush.n_opens);
    // Glue may or may not succeed depending on seed
    _ = brush.glueSections();
}

test "StackifiedBrush equivalence class" {
    const brush = StackifiedBrush.init(splitmix.GAY_SEED, 3, 6);
    const orbit = brush.equivalenceClass(0);
    try std.testing.expect(orbit.len >= 1);
    // Element is in its own orbit
    var found = false;
    for (0..orbit.len) |k| {
        if (orbit.members[k] == 0) found = true;
    }
    try std.testing.expect(found);
}

test "CondensifiedBrush projectDown" {
    const brush = CondensifiedBrush.init(splitmix.GAY_SEED, 3, 4);
    try std.testing.expect(brush.levels == 4);
    _ = brush.limitColor(5);
    const proj = brush.projectDown(10, 2);
    try std.testing.expect(proj < brush.level_sizes[1]);
}

test "Reafference self vs other" {
    const r1 = Reafference{ .efferent_copy = 1.0, .actual_input = 1.05, .threshold = 0.1 };
    try std.testing.expect(r1.isReafferent());
    try std.testing.expect(!r1.isExafferent());

    const r2 = Reafference{ .efferent_copy = 1.0, .actual_input = 1.5, .threshold = 0.1 };
    try std.testing.expect(r2.isExafferent());
}

test "ReafferenceState tracking" {
    var state = ReafferenceState.init(0.1);
    state.observe(1.0, 1.01); // reafferent
    state.observe(1.0, 1.5); // exafferent
    state.observe(1.0, 0.95); // reafferent
    try std.testing.expectEqual(@as(usize, 2), state.reafferent_count);
    try std.testing.expectEqual(@as(usize, 1), state.exafferent_count);
    try std.testing.expect(@abs(state.ratio() - 2.0 / 3.0) < 0.01);
}

test "MetatheoryTriple init" {
    const triple = MetatheoryTriple.init(splitmix.GAY_SEED, 16);
    try std.testing.expect(triple.sheafified.n_opens > 0);
    try std.testing.expect(triple.stackified.group_order == 3);
    try std.testing.expect(triple.condensified.levels == 4);
}
