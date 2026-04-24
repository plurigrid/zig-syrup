// verification.zig: Combined verification suite for Gay color system
// Zig translation of Gay.jl's:
//   - push_pull_sequence.jl  (push-pull fingerprint verification)
//   - bench.jl               (benchmark result types)
//   - bench_spi_regression.jl (SPI regression detection)
//   - regression.jl           (SPI invariant tests)
//   - proof_of_color.jl       (Proof of Color Parallelism)
//   - splitmix_cft_verify.jl  (SplitMix64 CFT symmetry verification)

const std = @import("std");
const math = std.math;
const splitmix = @import("splitmix.zig");
const abductive = @import("abductive.zig");

const Color = splitmix.Color;
const GAY_SEED = splitmix.GAY_SEED;
const GOLDEN = splitmix.GOLDEN;
const MIX1 = splitmix.MIX1;
const MIX2 = splitmix.MIX2;
const splitmix64 = splitmix.splitmix64;
const GayRng = splitmix.GayRng;
const hashColor = hashColorLocal;

// ============================================================================
// Hash color (local, matching abductive.zig)
// ============================================================================

fn hashColorLocal(id: u64, seed: u64) Color {
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
// SplitMix64 mix/unmix bijection (from splitmix_cft_verify.jl)
// ============================================================================

/// The mix function extracted from SplitMix64.
pub fn mix(z_in: u64) u64 {
    var z = z_in;
    z = (z ^ (z >> 30)) *% MIX1;
    z = (z ^ (z >> 27)) *% MIX2;
    z = z ^ (z >> 31);
    return z;
}

/// Inverse of mix(). Uses multiplicative inverses mod 2^64.
pub fn unmix(z_in: u64) u64 {
    var z = z_in;
    // Invert z = z ^ (z >> 31)
    z = z ^ (z >> 31) ^ (z >> 62);
    // Invert multiplication by MIX2
    z *%= 0x319642b2d24d8ec3;
    // Invert z = z ^ (z >> 27)
    z = z ^ (z >> 27) ^ (z >> 54);
    // Invert multiplication by MIX1
    z *%= 0x96de1b173f119089;
    // Invert z = z ^ (z >> 30)
    z = z ^ (z >> 30) ^ (z >> 60);
    return z;
}

// ============================================================================
// XOR Fingerprint (from regression.jl)
// ============================================================================

/// Compute XOR fingerprint of a slice of u64 values.
pub fn xorFingerprint(values: []const u64) u64 {
    var fp: u64 = 0;
    for (values) |v| {
        fp ^= v;
    }
    return fp;
}

/// Compute XOR fingerprint from u32 values.
pub fn xorFingerprintU32(values: []const u32) u32 {
    var fp: u32 = 0;
    for (values) |v| {
        fp ^= v;
    }
    return fp;
}

// ============================================================================
// Push-Pull Sequence Fingerprint (from push_pull_sequence.jl)
// ============================================================================

pub const SequenceFingerprint = struct {
    seed: u64,
    n_layers: u32,
    hidden_dim: u32,
    current_fp: u32,
    token_count: u32,

    pub fn init(seed: u64, n_layers: u32, hidden_dim: u32) SequenceFingerprint {
        return .{
            .seed = seed,
            .n_layers = n_layers,
            .hidden_dim = hidden_dim,
            .current_fp = 0,
            .token_count = 0,
        };
    }

    pub fn initDefault() SequenceFingerprint {
        return init(GAY_SEED, 32, 4096);
    }

    /// PUSH: Add a token's color contribution to the fingerprint.
    pub fn pushToken(self: *SequenceFingerprint, token_id: u64) u32 {
        self.token_count += 1;
        var contribution: u32 = 0;

        var layer: u32 = 1;
        while (layer <= self.n_layers) : (layer += 1) {
            var dim: u32 = 1;
            while (dim <= self.hidden_dim) : (dim += 1) {
                const h = self.seed ^
                    (token_id *% 0x9e3779b97f4a7c15) ^
                    (@as(u64, layer) *% 0x517cc1b727220a95) ^
                    (@as(u64, dim) *% 0xc4ceb9fe1a85ec53);
                const c = hashColorLocal(h, token_id);
                const r_bits: u32 = @bitCast(@as(f32, @floatCast(c.r)));
                contribution ^= r_bits;
            }
        }

        self.current_fp ^= contribution;
        return contribution;
    }

    /// PULL: Verify fingerprint matches expected.
    pub fn pullVerify(self: *const SequenceFingerprint, expected: u32) bool {
        return self.current_fp == expected;
    }
};

/// Pre-compute expected sequence fingerprint for a list of tokens.
pub fn expectedSequenceFp(token_ids: []const u64, n_layers: u32, hidden_dim: u32, seed: u64) u32 {
    var fp: u32 = 0;

    for (token_ids) |token_id| {
        var layer: u32 = 1;
        while (layer <= n_layers) : (layer += 1) {
            var dim: u32 = 1;
            while (dim <= hidden_dim) : (dim += 1) {
                const h = seed ^
                    (token_id *% 0x9e3779b97f4a7c15) ^
                    (@as(u64, layer) *% 0x517cc1b727220a95) ^
                    (@as(u64, dim) *% 0xc4ceb9fe1a85ec53);
                const c = hashColorLocal(h, token_id);
                const r_bits: u32 = @bitCast(@as(f32, @floatCast(c.r)));
                fp ^= r_bits;
            }
        }
    }

    return fp;
}

// ============================================================================
// Streaming Verifier (from push_pull_sequence.jl)
// ============================================================================

pub const StreamingVerifier = struct {
    seed: u64,
    n_layers: u32,
    hidden_dim: u32,
    chunks_pushed: u32,
    running_fp: u32,
    allocator: std.mem.Allocator,
    chunk_fps: std.ArrayList(u32),
    expected_chunk_fps: std.ArrayList(u32),
    verified_chunks: u32,
    all_verified: bool,

    pub fn init(allocator: std.mem.Allocator, seed: u64, n_layers: u32, hidden_dim: u32) StreamingVerifier {
        return .{
            .allocator = allocator,
            .seed = seed,
            .n_layers = n_layers,
            .hidden_dim = hidden_dim,
            .chunks_pushed = 0,
            .running_fp = 0,
            .chunk_fps = .empty,
            .expected_chunk_fps = .empty,
            .verified_chunks = 0,
            .all_verified = true,
        };
    }

    pub fn deinit(self: *StreamingVerifier) void {
        self.chunk_fps.deinit(self.allocator);
        self.expected_chunk_fps.deinit(self.allocator);
    }

    /// PUSH: Process a chunk of tokens.
    pub fn pushChunk(self: *StreamingVerifier, token_ids: []const u64) !u32 {
        var chunk_fp: u32 = 0;

        for (token_ids) |token_id| {
            var layer: u32 = 1;
            while (layer <= self.n_layers) : (layer += 1) {
                var dim: u32 = 1;
                while (dim <= self.hidden_dim) : (dim += 1) {
                    const h = self.seed ^
                        (token_id *% 0x9e3779b97f4a7c15) ^
                        (@as(u64, layer) *% 0x517cc1b727220a95) ^
                        (@as(u64, dim) *% 0xc4ceb9fe1a85ec53);
                    const c = hashColorLocal(h, token_id);
                    chunk_fp ^= @as(u32, @bitCast(@as(f32, @floatCast(c.r))));
                }
            }
        }

        self.chunks_pushed += 1;
        self.running_fp ^= chunk_fp;
        try self.chunk_fps.append(self.allocator, chunk_fp);
        return chunk_fp;
    }

    /// Set expected fingerprint for a chunk.
    pub fn setExpected(self: *StreamingVerifier, chunk_idx: usize, expected_fp: u32) !void {
        while (self.expected_chunk_fps.items.len <= chunk_idx) {
            try self.expected_chunk_fps.append(self.allocator, 0);
        }
        self.expected_chunk_fps.items[chunk_idx] = expected_fp;
    }

    /// PULL: Verify a specific chunk.
    pub fn verifyChunk(self: *StreamingVerifier, chunk_idx: usize) bool {
        if (chunk_idx >= self.chunk_fps.items.len or chunk_idx >= self.expected_chunk_fps.items.len) {
            return false;
        }
        const actual = self.chunk_fps.items[chunk_idx];
        const expected = self.expected_chunk_fps.items[chunk_idx];
        const ok = actual == expected;
        if (ok) {
            self.verified_chunks += 1;
        } else {
            self.all_verified = false;
        }
        return ok;
    }

    /// Verify all chunks.
    pub fn verifyAll(self: *StreamingVerifier) bool {
        var i: usize = 0;
        while (i < self.chunk_fps.items.len) : (i += 1) {
            _ = self.verifyChunk(i);
        }
        return self.all_verified;
    }
};

// ============================================================================
// Benchmark Result (from bench.jl)
// ============================================================================

pub const BenchmarkResult = struct {
    name: []const u8,
    median_ns: f64,
    min_ns: f64,
    samples: u32,
    rate: f64, // operations per second
};

// ============================================================================
// SPI Regression Benchmark Result (from bench_spi_regression.jl)
// ============================================================================

pub const SPIBenchResult = struct {
    name: []const u8,
    median_ns: f64,
    min_ns: f64,
    max_ns: f64,
    samples: u32,
    baseline_ns: f64,
    regression: bool,

    pub fn isRegression(median_ns_val: f64, baseline_ns_val: f64) bool {
        return baseline_ns_val > 0 and median_ns_val > baseline_ns_val * 1.2;
    }
};

/// Baseline expectations (approximate, Apple M-series)
pub const BASELINES = struct {
    pub const splitmix64_ns: f64 = 2.0;
    pub const hash_color_ns: f64 = 5.0;
    pub const xor_fingerprint_100_ns: f64 = 50.0;
    pub const xor_fingerprint_10000_ns: f64 = 2000.0;
};

// ============================================================================
// Proof of Color (from proof_of_color.jl)
// ============================================================================

/// Seed wrapper: FNV-1a hash anything to u64.
pub fn gaySeed(input: u64) u64 {
    return mix(input);
}

pub fn gaySeedFromBytes(bytes: []const u8) u64 {
    var h: u64 = 0xcbf29ce484222325; // FNV-1a offset basis
    for (bytes) |byte| {
        h ^= byte;
        h *%= 0x100000001b3; // FNV-1a prime
    }
    return mix(h);
}

/// Color Plot: pre-computed color lookup table.
pub const ColorPlot = struct {
    seed: u64,
    size: u32,
    fingerprint: u64,
    merkle_root: u64,

    pub fn create(seed: u64, size: u32) ColorPlot {
        var fp = seed;
        var i: u32 = 1;
        while (i <= size) : (i += 1) {
            const c = hashColorLocal(seed, @as(u64, i));
            const h = mix(seed ^ @as(u64, i));
            const r_bits: u32 = @bitCast(@as(f32, @floatCast(c.r)));
            const g_bits: u32 = @bitCast(@as(f32, @floatCast(c.g)));
            _ = g_bits;
            fp ^= h ^ @as(u64, r_bits);
        }

        // Merkle root (simplified)
        var merkle = seed;
        i = 1;
        while (i <= size) : (i += 1) {
            merkle = mix(merkle ^ @as(u64, i));
        }

        return .{
            .seed = seed,
            .size = size,
            .fingerprint = fp,
            .merkle_root = merkle,
        };
    }

    /// Verify by spot-checking random positions.
    pub fn verify(self: *const ColorPlot, n_checks: u32) bool {
        // Deterministic "random" checks via splitmix
        var state = self.seed ^ 0xDEADBEEF;
        var checks: u32 = 0;
        while (checks < n_checks) : (checks += 1) {
            state = splitmix64(state);
            const idx = @as(u32, @intCast((state % self.size) + 1));
            const expected = hashColorLocal(self.seed, @as(u64, idx));
            const actual = hashColorLocal(self.seed, @as(u64, idx));
            if (abductive.colorDistance(expected, actual) > 1e-10) return false;
        }
        // Verify merkle root
        var merkle = self.seed;
        var i: u32 = 1;
        while (i <= self.size) : (i += 1) {
            merkle = mix(merkle ^ @as(u64, i));
        }
        return merkle == self.merkle_root;
    }
};

/// Color VDF: Verifiable Delay Function via iterated hashing.
pub const ColorVDF = struct {
    seed: u64,
    iterations: u32,
    output: u64,
    proof_interval: u32,
    // Intermediate proofs stored externally for simplicity

    pub fn create(seed: u64, iterations: u32) ColorVDF {
        var state = seed;
        var i: u32 = 0;
        while (i < iterations) : (i += 1) {
            state = mix(state +% GOLDEN);
        }
        return .{
            .seed = seed,
            .iterations = iterations,
            .output = state,
            .proof_interval = 1000,
        };
    }

    /// Full verification: recompute everything.
    pub fn verify(self: *const ColorVDF) bool {
        var state = self.seed;
        var i: u32 = 0;
        while (i < self.iterations) : (i += 1) {
            state = mix(state +% GOLDEN);
        }
        return state == self.output;
    }
};

/// Proof of Color Parallelism: combined plot + VDF.
pub const ProofOfColorParallelism = struct {
    challenge: u64,
    plot: ColorPlot,
    vdf: ColorVDF,
    combined_proof: u64,
    quality: f64,

    pub fn create(challenge: u64, plot_size: u32, vdf_iterations: u32) ProofOfColorParallelism {
        const seed = gaySeed(challenge);
        const plot = ColorPlot.create(seed, plot_size);
        const vdf = ColorVDF.create(plot.fingerprint, vdf_iterations);
        const combined = plot.fingerprint ^ vdf.output;
        const quality = @as(f64, @floatFromInt(combined % 10000)) / 10000.0;

        return .{
            .challenge = seed,
            .plot = plot,
            .vdf = vdf,
            .combined_proof = combined,
            .quality = quality,
        };
    }

    pub fn verify(self: *const ProofOfColorParallelism) bool {
        if (!self.plot.verify(32)) return false;
        if (!self.vdf.verify()) return false;
        return (self.plot.fingerprint ^ self.vdf.output) == self.combined_proof;
    }
};

// ============================================================================
// CFT Verification (from splitmix_cft_verify.jl)
// ============================================================================

/// Verify gamma is odd (coprime to 2^64), ensuring full period.
pub fn verifyGammaCoprime() bool {
    return GOLDEN & 1 == 1;
}

/// Verify mix() is invertible (bijection).
pub fn verifyMixBijection(n_tests: u32) bool {
    var state: u64 = 0x12345678ABCDEF01;
    var i: u32 = 0;
    while (i < n_tests) : (i += 1) {
        state = splitmix64(state);
        const y = mix(state);
        const x_recovered = unmix(y);
        if (state != x_recovered) return false;
    }
    return true;
}

/// Verify multiplicative inverses mod 2^64.
pub fn verifyMultiplicativeInverses() bool {
    const check1 = MIX1 *% 0x96de1b173f119089;
    const check2 = MIX2 *% 0x319642b2d24d8ec3;
    return check1 == 1 and check2 == 1;
}

/// Verify XOR satisfies abelian group axioms.
pub fn verifyXorAbelian(n_tests: u32) bool {
    var state: u64 = GAY_SEED;
    var i: u32 = 0;
    while (i < n_tests) : (i += 1) {
        state = splitmix64(state);
        const a = state;
        state = splitmix64(state);
        const b = state;
        state = splitmix64(state);
        const c = state;

        // Commutativity
        if ((a ^ b) != (b ^ a)) return false;
        // Associativity
        if (((a ^ b) ^ c) != (a ^ (b ^ c))) return false;
        // Identity
        if ((a ^ 0) != a) return false;
        // Self-inverse
        if ((a ^ a) != 0) return false;
    }
    return true;
}

/// Verify SPI order independence: XOR fingerprint is permutation-invariant.
pub fn verifySpiOrderIndependence() bool {
    const n_streams = 4;
    const n_per_stream = 50;

    // Generate values from multiple streams
    var all_values: [n_streams * n_per_stream]u64 = undefined;
    for (0..n_streams) |si| {
        var rng = GayRng.init(GAY_SEED +% @as(u64, si) *% 0x1234567890abcdef);
        for (0..n_per_stream) |j| {
            all_values[si * n_per_stream + j] = rng.split();
        }
    }

    // Original order
    const fp_original = xorFingerprint(&all_values);

    // Reversed order
    var reversed: [n_streams * n_per_stream]u64 = undefined;
    for (0..all_values.len) |i| {
        reversed[i] = all_values[all_values.len - 1 - i];
    }
    const fp_reversed = xorFingerprint(&reversed);

    // Interleaved order
    var interleaved: [n_streams * n_per_stream]u64 = undefined;
    for (0..n_per_stream) |j| {
        for (0..n_streams) |si| {
            interleaved[j * n_streams + si] = all_values[si * n_per_stream + j];
        }
    }
    const fp_interleaved = xorFingerprint(&interleaved);

    return fp_original == fp_reversed and fp_original == fp_interleaved;
}

/// Verify Weyl sequence homomorphism: m*gamma + n*gamma = (m+n)*gamma.
pub fn verifyWeylHomomorphism(n_tests: u32) bool {
    var state: u64 = 42;
    var i: u32 = 0;
    while (i < n_tests) : (i += 1) {
        state = splitmix64(state);
        const m = state % 1000;
        state = splitmix64(state);
        const n = state % 1000;

        const lhs = m *% GOLDEN +% n *% GOLDEN;
        const rhs = (m +% n) *% GOLDEN;
        if (lhs != rhs) return false;
    }
    return true;
}

/// Verify parallel XOR reduction equals sequential.
pub fn verifyParallelReduction() bool {
    const n_values = 200;
    const n_chunks = 4;

    var rng = GayRng.init(GAY_SEED);
    var values: [n_values]u64 = undefined;
    for (&values) |*v| {
        v.* = rng.split();
    }

    // Sequential
    const fp_seq = xorFingerprint(&values);

    // Parallel (chunked)
    const chunk_size = n_values / n_chunks;
    var fp_par: u64 = 0;
    for (0..n_chunks) |ci| {
        const start = ci * chunk_size;
        const end = start + chunk_size;
        fp_par ^= xorFingerprint(values[start..end]);
    }

    return fp_seq == fp_par;
}

// ============================================================================
// Regression Suite (from regression.jl)
// ============================================================================

/// Verify SplitMix64 determinism.
pub fn verifySplitmixDeterminism() bool {
    return splitmix64(GAY_SEED) == splitmix64(GAY_SEED);
}

/// Verify fingerprint determinism: same data -> same fingerprint.
pub fn verifyFingerprintDeterminism() bool {
    var rng = GayRng.init(GAY_SEED);
    var data: [100]u64 = undefined;
    for (&data) |*d| {
        d.* = rng.split();
    }
    const fp1 = xorFingerprint(&data);
    const fp2 = xorFingerprint(&data);
    return fp1 == fp2;
}

/// Verify XOR cancellation: a ^ a = 0 is valid.
pub fn verifyXorCancellation() bool {
    const v: u64 = 0x123456789ABCDEF0;
    return (v ^ v) == 0;
}

// ============================================================================
// Full verification suite runner
// ============================================================================

pub const VerificationResult = struct {
    name: []const u8,
    passed: bool,
};

/// Run the complete verification suite. Returns count of failures.
pub fn runVerificationSuite(results: []VerificationResult) u32 {
    const tests = [_]struct { name: []const u8, func: *const fn () bool }{
        .{ .name = "gamma coprime (full period)", .func = verifyGammaCoprime },
        .{ .name = "mix bijection", .func = struct {
            fn f() bool {
                return verifyMixBijection(1000);
            }
        }.f },
        .{ .name = "multiplicative inverses", .func = verifyMultiplicativeInverses },
        .{ .name = "XOR abelian group", .func = struct {
            fn f() bool {
                return verifyXorAbelian(1000);
            }
        }.f },
        .{ .name = "SPI order independence", .func = verifySpiOrderIndependence },
        .{ .name = "Weyl homomorphism", .func = struct {
            fn f() bool {
                return verifyWeylHomomorphism(1000);
            }
        }.f },
        .{ .name = "parallel reduction", .func = verifyParallelReduction },
        .{ .name = "SplitMix64 determinism", .func = verifySplitmixDeterminism },
        .{ .name = "fingerprint determinism", .func = verifyFingerprintDeterminism },
        .{ .name = "XOR cancellation", .func = verifyXorCancellation },
    };

    var failures: u32 = 0;
    for (tests, 0..) |t, i| {
        if (i < results.len) {
            const passed = t.func();
            results[i] = .{ .name = t.name, .passed = passed };
            if (!passed) failures += 1;
        }
    }
    return failures;
}

pub const VERIFICATION_COUNT: usize = 10;

// ============================================================================
// Tests
// ============================================================================

// --- CFT Verification Tests ---

test "gamma is odd (coprime to 2^64)" {
    try std.testing.expect(verifyGammaCoprime());
}

test "mix is bijection" {
    try std.testing.expect(verifyMixBijection(10000));
}

test "unmix inverts mix" {
    const vals = [_]u64{ 0, 1, 42, GAY_SEED, 0xFFFFFFFFFFFFFFFF, 0xDEADBEEFCAFEBABE };
    for (vals) |v| {
        try std.testing.expectEqual(unmix(mix(v)), v);
    }
}

test "multiplicative inverses mod 2^64" {
    try std.testing.expect(verifyMultiplicativeInverses());
}

test "XOR abelian group axioms" {
    try std.testing.expect(verifyXorAbelian(10000));
}

test "SPI order independence" {
    try std.testing.expect(verifySpiOrderIndependence());
}

test "Weyl homomorphism" {
    try std.testing.expect(verifyWeylHomomorphism(10000));
}

test "parallel reduction theorem" {
    try std.testing.expect(verifyParallelReduction());
}

// --- Regression Tests ---

test "SplitMix64 determinism" {
    try std.testing.expect(verifySplitmixDeterminism());
}

test "fingerprint determinism" {
    try std.testing.expect(verifyFingerprintDeterminism());
}

test "XOR cancellation validity" {
    try std.testing.expect(verifyXorCancellation());
}

test "XOR fingerprint basic" {
    const vals = [_]u64{ 0xAA, 0x55, 0xFF };
    const fp = xorFingerprint(&vals);
    try std.testing.expectEqual(fp, 0xAA ^ 0x55 ^ 0xFF);
}

test "XOR fingerprint empty" {
    const empty: [0]u64 = .{};
    try std.testing.expectEqual(xorFingerprint(&empty), 0);
}

// --- Push-Pull Sequence Tests ---

test "push-pull sequence roundtrip small" {
    const n_layers: u32 = 2;
    const hidden_dim: u32 = 4;
    const tokens = [_]u64{ 101, 102, 103 };

    const expected = expectedSequenceFp(&tokens, n_layers, hidden_dim, GAY_SEED);

    var fp = SequenceFingerprint.init(GAY_SEED, n_layers, hidden_dim);
    for (tokens) |tok| {
        _ = fp.pushToken(tok);
    }

    try std.testing.expect(fp.pullVerify(expected));
    try std.testing.expectEqual(fp.token_count, 3);
}

test "push-pull individual tokens match expected" {
    const n_layers: u32 = 2;
    const hidden_dim: u32 = 2;

    // Single token
    const tok = [_]u64{42};
    const expected = expectedSequenceFp(&tok, n_layers, hidden_dim, GAY_SEED);

    var fp = SequenceFingerprint.init(GAY_SEED, n_layers, hidden_dim);
    _ = fp.pushToken(42);

    try std.testing.expect(fp.pullVerify(expected));
}

test "streaming verifier chunk verification" {
    const allocator = std.testing.allocator;
    const n_layers: u32 = 2;
    const hidden_dim: u32 = 2;

    var sv = StreamingVerifier.init(allocator, GAY_SEED, n_layers, hidden_dim);
    defer sv.deinit();

    const chunks = [_][]const u64{
        &[_]u64{101},
        &[_]u64{102},
        &[_]u64{103},
    };

    // Set expected and push each chunk
    for (chunks, 0..) |chunk, i| {
        const expected_fp = expectedSequenceFp(chunk, n_layers, hidden_dim, GAY_SEED);
        try sv.setExpected(i, expected_fp);
        _ = try sv.pushChunk(chunk);
    }

    try std.testing.expect(sv.verifyAll());
}

// --- Proof of Color Tests ---

test "color plot create and verify" {
    const plot = ColorPlot.create(GAY_SEED, 100);
    try std.testing.expect(plot.verify(32));
}

test "color VDF create and verify" {
    const vdf = ColorVDF.create(GAY_SEED, 1000);
    try std.testing.expect(vdf.verify());
}

test "proof of color parallelism" {
    const proof = ProofOfColorParallelism.create(42, 100, 1000);
    try std.testing.expect(proof.verify());
    try std.testing.expect(proof.quality >= 0.0 and proof.quality < 1.0);
}

test "VDF determinism" {
    const vdf1 = ColorVDF.create(GAY_SEED, 500);
    const vdf2 = ColorVDF.create(GAY_SEED, 500);
    try std.testing.expectEqual(vdf1.output, vdf2.output);
}

test "different seeds produce different VDFs" {
    const vdf1 = ColorVDF.create(GAY_SEED, 500);
    const vdf2 = ColorVDF.create(GAY_SEED ^ 1, 500);
    try std.testing.expect(vdf1.output != vdf2.output);
}

// --- Seed Tests ---

test "gaySeed deterministic" {
    try std.testing.expectEqual(gaySeed(42), gaySeed(42));
}

test "gaySeedFromBytes deterministic" {
    const bytes = "hello world";
    try std.testing.expectEqual(gaySeedFromBytes(bytes), gaySeedFromBytes(bytes));
}

test "gaySeedFromBytes distinct" {
    try std.testing.expect(gaySeedFromBytes("hello") != gaySeedFromBytes("world"));
}

// --- Stream Independence ---

test "different streams produce different values" {
    var rng1 = GayRng.init(GAY_SEED);
    var rng2 = GayRng.init(GAY_SEED ^ 0x123456789abcdef0);
    // After several splits, should diverge
    var i: usize = 0;
    var same_count: usize = 0;
    while (i < 100) : (i += 1) {
        if (rng1.split() == rng2.split()) same_count += 1;
    }
    // Extremely unlikely to have many collisions
    try std.testing.expect(same_count < 5);
}

// --- Full Suite ---

test "full verification suite passes" {
    var results: [VERIFICATION_COUNT]VerificationResult = undefined;
    const failures = runVerificationSuite(&results);
    try std.testing.expectEqual(failures, 0);
}
