//! Luby Transform Fountain Codes
//!
//! Rateless erasure coding for air-gapped transport (QRTP).
//! Generates an unlimited stream of encoded blocks from K source blocks.
//! Any ~1.1K received blocks reconstruct the original K source blocks.
//!
//! Inspired by Orion Reed's QR Transfer Protocols:
//!   https://www.orionreed.com/posts/qrtp/
//!
//! Key properties:
//!   - Zero allocation in encode path (fixed-size blocks)
//!   - Three PRNG modes: SplitMix64 (Gay.jl bijection with SPI),
//!     Xoshiro256 (fast), ChaCha8 (CSPRNG for identity proofs)
//!   - SIMD XOR block combining where available
//!   - Decoder = adhesion_filter (Bumpus, StructuredDecompositions.jl):
//!     source blocks are bags, encoded blocks are adhesion spans,
//!     propagate() is sheaf-theoretic consistency filtering on the
//!     tree decomposition of block dependencies
//!
//! GF(3) trit: +1 (PLUS) — generates infinite encoded blocks from finite source

const std = @import("std");

// =============================================================================
// Constants
// =============================================================================

/// Maximum source blocks in a single message
pub const MAX_SOURCE_BLOCKS: usize = 256;

/// Block size in bytes (fits in a single QR code at medium ECC)
pub const DEFAULT_BLOCK_SIZE: usize = 256;

/// Maximum degree for Robust Soliton distribution
pub const MAX_DEGREE: usize = 64;

/// Overhead factor: need ~1.1K blocks to decode K source blocks
pub const OVERHEAD_FACTOR: f64 = 1.10;

// =============================================================================
// SplitMix64 Bijection (Gay.jl)
// =============================================================================
//
// Bijective mixing function with Strong Parallelism Invariance (SPI).
// Every UInt64 maps to exactly one UInt64 — invertible. This guarantees
// deterministic color/block selection regardless of execution order.
//
// Gay.jl reference: src/splittable.jl
// Constants: golden ratio fractional part × 2^64, Stafford's Mix13 multipliers.

pub const SplitMix64 = struct {
    /// Golden ratio constant: floor(2^64 / φ)
    pub const GOLDEN: u64 = 0x9e3779b97f4a7c15;
    /// Stafford Mix13 multiplier 1
    pub const MIX1: u64 = 0xbf58476d1ce4e5b9;
    /// Stafford Mix13 multiplier 2
    pub const MIX2: u64 = 0x94d049bb133111eb;

    /// Modular multiplicative inverse of MIX1 (mod 2^64)
    pub const MIX1_INV: u64 = modInverse64(MIX1);
    /// Modular multiplicative inverse of MIX2 (mod 2^64)
    pub const MIX2_INV: u64 = modInverse64(MIX2);

    state: u64,

    pub fn init(seed: u64) SplitMix64 {
        return .{ .state = seed };
    }

    /// Forward bijection: mix(x) → y. Deterministic, invertible.
    /// Matches Gay.jl's `splitmix64` / `sm64` exactly.
    pub fn mix(x: u64) u64 {
        var z = x +% GOLDEN;
        z = (z ^ (z >> 30)) *% MIX1;
        z = (z ^ (z >> 27)) *% MIX2;
        return z ^ (z >> 31);
    }

    /// Inverse bijection: unmix(mix(x)) == x. Gay.jl's `unmix`.
    /// Inverts XOR-shifts via iterative recovery, multiplications via modular inverse.
    pub fn unmix(z: u64) u64 {
        // Invert z ^ (z >> 31)
        var x = z;
        x ^= x >> 31;
        x ^= x >> 62;
        // Invert *MIX2
        x *%= MIX2_INV;
        // Invert x ^ (x >> 27)
        x ^= x >> 27;
        x ^= x >> 54;
        // Invert *MIX1
        x *%= MIX1_INV;
        // Invert x ^ (x >> 30)
        x ^= x >> 30;
        x ^= x >> 60;
        // Invert +GOLDEN
        x -%= GOLDEN;
        return x;
    }

    /// Stateful: advance state by GOLDEN, return mixed output.
    /// Matches GayRNG's state transition.
    pub fn next(self: *SplitMix64) u64 {
        const result = mix(self.state);
        self.state +%= GOLDEN;
        return result;
    }

    /// Returns a value in [0, bound).
    pub fn bounded(self: *SplitMix64, bound: u64) u64 {
        if (bound == 0) return 0;
        return self.next() % bound;
    }

    /// O(1) random access: color_at(seed, index). Gay.jl's `hash_color` pattern.
    /// SPI-compatible: same (seed, index) → same output regardless of call order.
    pub fn colorAt(seed: u64, index: u64) u64 {
        return mix(seed ^ index);
    }

    /// Compute modular multiplicative inverse mod 2^64 via Newton's method.
    /// Only valid for odd inputs (both MIX1 and MIX2 are odd).
    fn modInverse64(a: u64) u64 {
        @setEvalBranchQuota(10000);
        var x: u64 = a; // a*a ≡ 1 (mod 2^2) for odd a (since a^2 is odd)
        // Newton: x = x * (2 - a*x), doubling correct bits each iteration
        x *%= 2 -% a *% x; // 4 bits
        x *%= 2 -% a *% x; // 8 bits
        x *%= 2 -% a *% x; // 16 bits
        x *%= 2 -% a *% x; // 32 bits
        x *%= 2 -% a *% x; // 64 bits
        return x;
    }
};

// =============================================================================
// Three-Mode PRNG: SplitMix64 | Xoshiro256 | ChaCha8
// =============================================================================

pub const PrngMode = enum {
    /// SplitMix64 bijection (Gay.jl) — SPI-compatible, invertible. Default.
    splitmix,
    /// Xoshiro256++ — fast, non-cryptographic.
    xoshiro,
    /// ChaCha8 with forward security — CSPRNG for passport.gay identity proofs.
    chacha,
};

/// Deterministic PRNG for reproducible block selection.
/// Same seed + block_index → same degree + source selection on both sides.
pub const Prng = union(PrngMode) {
    splitmix: SplitMix64,
    xoshiro: std.Random.Xoshiro256,
    chacha: std.Random.ChaCha,

    /// Initialize with SplitMix64 (Gay.jl bijection, SPI default).
    pub fn initSplitMix(seed: u64) Prng {
        return .{ .splitmix = SplitMix64.init(seed) };
    }

    /// Initialize with Xoshiro256++ (fast).
    pub fn initXoshiro(seed: u64) Prng {
        return .{ .xoshiro = std.Random.Xoshiro256.init(seed) };
    }

    /// Initialize with ChaCha8 CSPRNG.
    /// Expands u64 seed to 32-byte key via SplitMix64 (same expansion Xoshiro uses).
    pub fn initChaCha(seed: u64) Prng {
        var sm = std.Random.SplitMix64.init(seed);
        var key: [std.Random.ChaCha.secret_seed_length]u8 = undefined;
        inline for (0..4) |i| {
            const v = sm.next();
            key[i * 8 ..][0..8].* = @bitCast(v);
        }
        return .{ .chacha = std.Random.ChaCha.init(key) };
    }

    /// Initialize with the given mode.
    pub fn init(mode: PrngMode, seed: u64) Prng {
        return switch (mode) {
            .splitmix => initSplitMix(seed),
            .xoshiro => initXoshiro(seed),
            .chacha => initChaCha(seed),
        };
    }

    /// Next u64.
    pub fn next(self: *Prng) u64 {
        return switch (self.*) {
            .splitmix => |*s| s.next(),
            .xoshiro => |*x| x.next(),
            .chacha => |*c| c.random().int(u64),
        };
    }

    /// Returns a value in [0, bound).
    pub fn bounded(self: *Prng, bound: u64) u64 {
        if (bound == 0) return 0;
        return self.next() % bound;
    }

    /// Get the active PRNG kind.
    pub fn activeMode(self: *const Prng) PrngMode {
        return self.*;
    }
};

// =============================================================================
// Robust Soliton Distribution
// =============================================================================

/// Sample degree from Ideal Soliton distribution.
/// Returns d in [1, k] with P(d=1) = 1/k, P(d=i) = 1/(i*(i-1)) for i>=2.
pub fn sampleDegree(prng: *Prng, k: usize) usize {
    if (k <= 1) return 1;

    // Uniform random in (0, 1)
    const r = @as(f64, @floatFromInt(prng.next() >> 11)) / @as(f64, @floatFromInt(@as(u64, 1) << 53));

    // Inverse CDF sampling of Ideal Soliton
    // P(d=1) = 1/k
    const p1 = 1.0 / @as(f64, @floatFromInt(k));
    if (r < p1) return 1;

    // P(d=i) = 1/(i*(i-1)) for i = 2..k
    var cumulative: f64 = p1;
    var i: usize = 2;
    while (i <= k) : (i += 1) {
        const fi = @as(f64, @floatFromInt(i));
        cumulative += 1.0 / (fi * (fi - 1.0));
        if (r < cumulative) return i;
    }

    return k; // Fallback (rounding)
}

/// Select `degree` unique source indices from [0, k) using Fisher-Yates partial shuffle.
pub fn selectSources(
    prng: *Prng,
    k: usize,
    degree: usize,
    out: []usize,
) usize {
    const actual_degree = @min(degree, @min(k, out.len));

    // Initialize candidates [0..k)
    var candidates: [MAX_SOURCE_BLOCKS]usize = undefined;
    for (0..k) |i| {
        candidates[i] = i;
    }

    // Partial Fisher-Yates shuffle
    for (0..actual_degree) |i| {
        const remaining = k - i;
        const j = i + @as(usize, @intCast(prng.bounded(@intCast(remaining))));
        // Swap
        const tmp = candidates[i];
        candidates[i] = candidates[j];
        candidates[j] = tmp;
        out[i] = candidates[i];
    }

    return actual_degree;
}

// =============================================================================
// XOR Block Combining
// =============================================================================

/// XOR two blocks into dst. Uses SIMD where available.
pub fn xorBlocks(dst: []u8, src: []const u8) void {
    const len = @min(dst.len, src.len);

    // SIMD path: process 16 bytes at a time
    const vec_len = 16;
    const full_vecs = len / vec_len;
    var i: usize = 0;

    while (i < full_vecs * vec_len) : (i += vec_len) {
        const d: @Vector(vec_len, u8) = dst[i..][0..vec_len].*;
        const s: @Vector(vec_len, u8) = src[i..][0..vec_len].*;
        dst[i..][0..vec_len].* = d ^ s;
    }

    // Scalar tail
    while (i < len) : (i += 1) {
        dst[i] ^= src[i];
    }
}

// =============================================================================
// Encoded Block
// =============================================================================

/// An encoded (fountain) block: XOR of `degree` source blocks.
pub const EncodedBlock = struct {
    /// Session seed for deterministic regeneration
    seed: u64,
    /// Block index in the fountain stream (0, 1, 2, ...)
    block_index: u32,
    /// Number of source blocks in this message
    num_source_blocks: u16,
    /// Degree (number of source blocks XOR'd together)
    degree: u8,
    /// Indices of source blocks combined (up to MAX_DEGREE)
    source_indices: [MAX_DEGREE]u16 = undefined,
    /// Encoded payload (XOR of selected source blocks)
    payload: [DEFAULT_BLOCK_SIZE]u8 = undefined,
    /// Actual payload length
    payload_len: usize = 0,
};

// =============================================================================
// Encoder
// =============================================================================

/// Fountain encoder: generates infinite encoded blocks from K source blocks.
pub const Encoder = struct {
    /// Source data split into blocks
    source_blocks: [MAX_SOURCE_BLOCKS][DEFAULT_BLOCK_SIZE]u8 = undefined,
    source_lengths: [MAX_SOURCE_BLOCKS]usize = undefined,
    num_blocks: usize = 0,
    /// Session seed (deterministic: receiver reproduces same PRNG sequence)
    seed: u64,
    /// Next block index to generate
    next_index: u32 = 0,
    /// PRNG mode (splitmix = SPI default, xoshiro = fast, chacha = CSPRNG)
    prng_mode: PrngMode = .splitmix,

    /// Initialize encoder from a contiguous payload (SplitMix64 default).
    pub fn init(seed: u64, payload: []const u8) Encoder {
        return initWithMode(seed, payload, .splitmix);
    }

    /// Initialize encoder with explicit PRNG mode.
    pub fn initWithMode(seed: u64, payload: []const u8, mode: PrngMode) Encoder {
        var enc = Encoder{ .seed = seed, .prng_mode = mode };

        var offset: usize = 0;
        while (offset < payload.len and enc.num_blocks < MAX_SOURCE_BLOCKS) {
            const remaining = payload.len - offset;
            const chunk_len = @min(remaining, DEFAULT_BLOCK_SIZE);

            @memset(&enc.source_blocks[enc.num_blocks], 0);
            @memcpy(enc.source_blocks[enc.num_blocks][0..chunk_len], payload[offset .. offset + chunk_len]);
            enc.source_lengths[enc.num_blocks] = chunk_len;
            enc.num_blocks += 1;
            offset += chunk_len;
        }

        return enc;
    }

    /// Initialize encoder from pre-split blocks.
    pub fn initFromBlocks(seed: u64, blocks: []const []const u8) Encoder {
        var enc = Encoder{ .seed = seed };

        for (blocks) |block| {
            if (enc.num_blocks >= MAX_SOURCE_BLOCKS) break;
            @memset(&enc.source_blocks[enc.num_blocks], 0);
            const len = @min(block.len, DEFAULT_BLOCK_SIZE);
            @memcpy(enc.source_blocks[enc.num_blocks][0..len], block[0..len]);
            enc.source_lengths[enc.num_blocks] = len;
            enc.num_blocks += 1;
        }

        return enc;
    }

    /// Generate the next encoded block.
    pub fn nextBlock(self: *Encoder) EncodedBlock {
        var block = EncodedBlock{
            .seed = self.seed,
            .block_index = self.next_index,
            .num_source_blocks = @intCast(self.num_blocks),
            .degree = 0,
        };

        // Deterministic PRNG seeded by (session_seed XOR block_index)
        var prng = Prng.init(self.prng_mode, self.seed ^ @as(u64, self.next_index));

        // Sample degree from Soliton distribution
        const degree = sampleDegree(&prng, self.num_blocks);
        block.degree = @intCast(degree);

        // Select source block indices
        var indices: [MAX_DEGREE]usize = undefined;
        const actual = selectSources(&prng, self.num_blocks, degree, &indices);

        // XOR selected source blocks together
        @memset(&block.payload, 0);
        var max_len: usize = 0;
        for (0..actual) |i| {
            const src_idx = indices[i];
            block.source_indices[i] = @intCast(src_idx);
            xorBlocks(&block.payload, &self.source_blocks[src_idx]);
            max_len = @max(max_len, self.source_lengths[src_idx]);
        }
        block.payload_len = max_len;

        self.next_index += 1;
        return block;
    }

    /// Number of source blocks
    pub fn sourceCount(self: *const Encoder) usize {
        return self.num_blocks;
    }
};

// =============================================================================
// Decoder
// =============================================================================

/// Decoder state for a single source block.
const SourceBlockState = enum {
    /// Not yet recovered
    unknown,
    /// Recovered (value known)
    known,
};

/// Fountain decoder: accumulates encoded blocks to recover source.
pub const Decoder = struct {
    /// Recovered source blocks
    source_blocks: [MAX_SOURCE_BLOCKS][DEFAULT_BLOCK_SIZE]u8 = undefined,
    source_lengths: [MAX_SOURCE_BLOCKS]usize = undefined,
    /// State of each source block
    state: [MAX_SOURCE_BLOCKS]SourceBlockState = undefined,
    /// Number of source blocks expected
    num_blocks: usize = 0,
    /// Number of source blocks recovered so far
    num_recovered: usize = 0,
    /// Session seed
    seed: u64,
    /// PRNG mode (must match encoder)
    prng_mode: PrngMode = .splitmix,
    /// Buffer for unresolved encoded blocks (belief propagation)
    pending: [MAX_SOURCE_BLOCKS * 4]PendingBlock = undefined,
    pending_count: usize = 0,

    const PendingBlock = struct {
        payload: [DEFAULT_BLOCK_SIZE]u8 = undefined,
        payload_len: usize = 0,
        indices: [MAX_DEGREE]u16 = undefined,
        degree: u8 = 0,
        /// Number of unknown source blocks this depends on
        unresolved: u8 = 0,
    };

    /// Initialize decoder (SplitMix64 default).
    pub fn init(seed: u64, num_blocks: usize) Decoder {
        return initWithMode(seed, num_blocks, .splitmix);
    }

    /// Initialize decoder with explicit PRNG mode.
    pub fn initWithMode(seed: u64, num_blocks: usize, mode: PrngMode) Decoder {
        var dec = Decoder{
            .seed = seed,
            .num_blocks = num_blocks,
            .prng_mode = mode,
        };
        for (0..MAX_SOURCE_BLOCKS) |i| {
            dec.state[i] = .unknown;
            dec.source_lengths[i] = 0;
        }
        return dec;
    }

    /// Process an incoming encoded block. Returns true if new source blocks were recovered.
    pub fn processBlock(self: *Decoder, block: *const EncodedBlock) bool {
        if (block.num_source_blocks != @as(u16, @intCast(self.num_blocks))) return false;

        // Re-derive source indices from seed + block_index
        var prng = Prng.init(self.prng_mode, block.seed ^ @as(u64, block.block_index));
        const degree = sampleDegree(&prng, self.num_blocks);
        var indices: [MAX_DEGREE]usize = undefined;
        const actual = selectSources(&prng, self.num_blocks, degree, &indices);

        // Copy payload for processing
        var payload: [DEFAULT_BLOCK_SIZE]u8 = undefined;
        @memcpy(&payload, &block.payload);
        const payload_len = block.payload_len;

        // XOR out any already-known source blocks
        var unknown_count: u8 = 0;
        var unknown_indices: [MAX_DEGREE]u16 = undefined;
        for (0..actual) |i| {
            const idx = indices[i];
            if (self.state[idx] == .known) {
                // XOR out the known block
                xorBlocks(&payload, &self.source_blocks[idx]);
            } else {
                unknown_indices[unknown_count] = @intCast(idx);
                unknown_count += 1;
            }
        }

        if (unknown_count == 0) {
            // All source blocks already known — redundant block
            return false;
        } else if (unknown_count == 1) {
            // Exactly one unknown — solve it directly
            const idx = unknown_indices[0];
            @memcpy(&self.source_blocks[idx], &payload);
            self.source_lengths[idx] = payload_len;
            self.state[idx] = .known;
            self.num_recovered += 1;

            // Propagate: check if any pending blocks can now be resolved
            return self.propagate();
        } else {
            // Multiple unknowns — buffer for later
            if (self.pending_count < self.pending.len) {
                var pb = &self.pending[self.pending_count];
                @memcpy(&pb.payload, &payload);
                pb.payload_len = payload_len;
                pb.degree = unknown_count;
                for (0..unknown_count) |i| {
                    pb.indices[i] = unknown_indices[i];
                }
                pb.unresolved = unknown_count;
                self.pending_count += 1;
            }
            return false;
        }
    }

    /// Adhesion filter (Bumpus, StructuredDecompositions.jl):
    /// When a source block (bag) becomes known, check pending encoded
    /// blocks (adhesion spans) for newly solvable ones. Each degree-1
    /// adhesion yields a direct solve; the consistency check propagates
    /// through the tree decomposition of block dependencies.
    ///
    /// Sheaf analogy: source blocks = bags, encoded blocks = adhesion spans,
    /// XOR = pullback projection, contradiction = empty bag (decode failure).
    fn propagate(self: *Decoder) bool {
        var progress = true;
        var any_new = true; // We already recovered one

        while (progress) {
            progress = false;
            var i: usize = 0;
            while (i < self.pending_count) {
                var pb = &self.pending[i];
                if (pb.unresolved == 0) {
                    // Already fully resolved — remove
                    self.removePending(i);
                    continue;
                }

                // XOR out newly known blocks
                var new_unknown: u8 = 0;
                var new_indices: [MAX_DEGREE]u16 = undefined;
                var j: u8 = 0;
                while (j < pb.degree) : (j += 1) {
                    const idx = pb.indices[j];
                    if (self.state[idx] == .known) {
                        xorBlocks(&pb.payload, &self.source_blocks[idx]);
                    } else {
                        new_indices[new_unknown] = idx;
                        new_unknown += 1;
                    }
                }
                pb.unresolved = new_unknown;
                pb.degree = new_unknown;
                for (0..new_unknown) |k| {
                    pb.indices[k] = new_indices[k];
                }

                if (new_unknown == 1) {
                    // Solve!
                    const idx = new_indices[0];
                    @memcpy(&self.source_blocks[idx], &pb.payload);
                    self.source_lengths[idx] = pb.payload_len;
                    self.state[idx] = .known;
                    self.num_recovered += 1;
                    self.removePending(i);
                    progress = true;
                    any_new = true;
                    continue;
                }

                i += 1;
            }
        }

        return any_new;
    }

    fn removePending(self: *Decoder, idx: usize) void {
        if (self.pending_count > 0) {
            self.pending[idx] = self.pending[self.pending_count - 1];
            self.pending_count -= 1;
        }
    }

    /// Public alias for the adhesion filter (StructuredDecompositions.jl naming).
    /// Call after processBlock to trigger sheaf-theoretic consistency propagation.
    pub fn adhesionFilter(self: *Decoder) bool {
        return self.propagate();
    }

    /// Check if all source blocks have been recovered.
    pub fn isComplete(self: *const Decoder) bool {
        return self.num_recovered >= self.num_blocks;
    }

    /// Get the number of recovered source blocks.
    pub fn recoveredCount(self: *const Decoder) usize {
        return self.num_recovered;
    }

    /// Reassemble the original payload from recovered source blocks.
    /// Returns the total length written, or null if not yet complete.
    pub fn reassemble(self: *const Decoder, out: []u8) ?usize {
        if (!self.isComplete()) return null;

        var written: usize = 0;
        for (0..self.num_blocks) |i| {
            const len = self.source_lengths[i];
            if (written + len > out.len) return null;
            @memcpy(out[written .. written + len], self.source_blocks[i][0..len]);
            written += len;
        }
        return written;
    }
};

// =============================================================================
// Tests
// =============================================================================

// --- SplitMix64 bijection tests (Gay.jl) ---

test "splitmix64 bijection: unmix(mix(x)) == x" {
    // Verify the inverse property for diverse inputs
    const test_values = [_]u64{
        0, 1, 42, 0xDEADBEEF, 0xCAFEBABE,
        0xFFFFFFFFFFFFFFFF, 0x9e3779b97f4a7c15,
        0x0123456789ABCDEF, 0xFEDCBA9876543210,
    };
    for (test_values) |x| {
        try std.testing.expectEqual(x, SplitMix64.unmix(SplitMix64.mix(x)));
    }
}

test "splitmix64 bijection: mix(unmix(y)) == y" {
    const test_values = [_]u64{ 0, 1, 99, 0xBEEF, 0x42424242, 0xFFFFFFFF00000000 };
    for (test_values) |y| {
        try std.testing.expectEqual(y, SplitMix64.mix(SplitMix64.unmix(y)));
    }
}

test "splitmix64 modular inverse verification" {
    // MIX1 * MIX1_INV ≡ 1 (mod 2^64)
    try std.testing.expectEqual(@as(u64, 1), SplitMix64.MIX1 *% SplitMix64.MIX1_INV);
    // MIX2 * MIX2_INV ≡ 1 (mod 2^64)
    try std.testing.expectEqual(@as(u64, 1), SplitMix64.MIX2 *% SplitMix64.MIX2_INV);
}

test "splitmix64 colorAt SPI (order-independent)" {
    const seed: u64 = 0x6A7;
    // colorAt is deterministic: same (seed, index) → same output
    const c0 = SplitMix64.colorAt(seed, 0);
    const c1 = SplitMix64.colorAt(seed, 1);
    const c2 = SplitMix64.colorAt(seed, 2);
    // Call again in different order — SPI guarantee
    try std.testing.expectEqual(c2, SplitMix64.colorAt(seed, 2));
    try std.testing.expectEqual(c0, SplitMix64.colorAt(seed, 0));
    try std.testing.expectEqual(c1, SplitMix64.colorAt(seed, 1));
    // Different indices produce different colors
    try std.testing.expect(c0 != c1);
    try std.testing.expect(c1 != c2);
}

// --- Three-mode PRNG tests ---

test "splitmix prng deterministic" {
    var prng1 = Prng.initSplitMix(42);
    var prng2 = Prng.initSplitMix(42);
    for (0..100) |_| {
        try std.testing.expectEqual(prng1.next(), prng2.next());
    }
}

test "xoshiro prng deterministic" {
    var prng1 = Prng.initXoshiro(42);
    var prng2 = Prng.initXoshiro(42);
    for (0..100) |_| {
        try std.testing.expectEqual(prng1.next(), prng2.next());
    }
}

test "chacha prng deterministic" {
    var prng1 = Prng.initChaCha(42);
    var prng2 = Prng.initChaCha(42);
    for (0..100) |_| {
        try std.testing.expectEqual(prng1.next(), prng2.next());
    }
}

test "three modes diverge from same seed" {
    var s = Prng.initSplitMix(42);
    var x = Prng.initXoshiro(42);
    var c = Prng.initChaCha(42);
    const sv = s.next();
    const xv = x.next();
    const cv = c.next();
    try std.testing.expect(sv != xv);
    try std.testing.expect(xv != cv);
    try std.testing.expect(sv != cv);
}

test "different seeds diverge" {
    var prng1 = Prng.initSplitMix(42);
    var prng2 = Prng.initSplitMix(43);
    try std.testing.expect(prng1.next() != prng2.next());
}

test "sampleDegree returns valid range" {
    var prng = Prng.initSplitMix(1234);
    for (0..1000) |_| {
        const d = sampleDegree(&prng, 10);
        try std.testing.expect(d >= 1 and d <= 10);
    }
}

test "sampleDegree k=1 always returns 1" {
    var prng = Prng.initSplitMix(999);
    for (0..100) |_| {
        try std.testing.expectEqual(@as(usize, 1), sampleDegree(&prng, 1));
    }
}

test "selectSources unique indices" {
    var prng = Prng.initSplitMix(5678);
    var indices: [MAX_DEGREE]usize = undefined;
    const n = selectSources(&prng, 10, 5, &indices);
    try std.testing.expectEqual(@as(usize, 5), n);

    // Check uniqueness
    for (0..n) |i| {
        for (i + 1..n) |j| {
            try std.testing.expect(indices[i] != indices[j]);
        }
        try std.testing.expect(indices[i] < 10);
    }
}

test "xorBlocks SIMD" {
    var a = [_]u8{ 0xFF, 0x00, 0xAA, 0x55 } ++ [_]u8{0} ** 28;
    const b = [_]u8{ 0x0F, 0xF0, 0x55, 0xAA } ++ [_]u8{0} ** 28;
    xorBlocks(&a, &b);
    try std.testing.expectEqual(@as(u8, 0xF0), a[0]);
    try std.testing.expectEqual(@as(u8, 0xF0), a[1]);
    try std.testing.expectEqual(@as(u8, 0xFF), a[2]);
    try std.testing.expectEqual(@as(u8, 0xFF), a[3]);
}

test "encode single block (degree 1 passthrough)" {
    const data = "hello fountain codes!";
    var enc = Encoder.init(42, data);
    try std.testing.expectEqual(@as(usize, 1), enc.num_blocks);

    // With K=1, every encoded block has degree 1 → passthrough
    const block = enc.nextBlock();
    try std.testing.expectEqual(@as(u8, 1), block.degree);
    try std.testing.expectEqualSlices(u8, data, block.payload[0..data.len]);
}

test "encode-decode round trip small" {
    const data = "The quick brown fox jumps over the lazy dog";
    const seed: u64 = 0xDEADBEEF;
    var enc = Encoder.init(seed, data);
    const k = enc.sourceCount();

    var dec = Decoder.init(seed, k);

    // Feed encoded blocks until decoded
    var blocks_sent: u32 = 0;
    while (!dec.isComplete()) : (blocks_sent += 1) {
        const block = enc.nextBlock();
        _ = dec.processBlock(&block);

        // Safety: don't infinite loop
        if (blocks_sent > k * 10) break;
    }

    try std.testing.expect(dec.isComplete());

    var out: [1024]u8 = undefined;
    const len = dec.reassemble(&out).?;
    try std.testing.expectEqualSlices(u8, data, out[0..len]);
}

test "encode-decode round trip multi-block" {
    // Create a payload that spans multiple blocks
    var data: [DEFAULT_BLOCK_SIZE * 4]u8 = undefined;
    for (&data, 0..) |*b, i| {
        b.* = @intCast(i % 251); // Prime modulus for variety
    }

    const seed: u64 = 0xCAFEBABE;
    var enc = Encoder.init(seed, &data);
    const k = enc.sourceCount();
    try std.testing.expectEqual(@as(usize, 4), k);

    var dec = Decoder.init(seed, k);

    var blocks_sent: u32 = 0;
    while (!dec.isComplete()) : (blocks_sent += 1) {
        const block = enc.nextBlock();
        _ = dec.processBlock(&block);
        if (blocks_sent > k * 20) break;
    }

    try std.testing.expect(dec.isComplete());

    var out: [DEFAULT_BLOCK_SIZE * 4]u8 = undefined;
    const len = dec.reassemble(&out).?;
    try std.testing.expectEqual(data.len, len);
    try std.testing.expectEqualSlices(u8, &data, out[0..len]);
}

test "chacha round trip (passport.gay identity proof)" {
    // ChaCha mode: CSPRNG for air-gapped identity verification
    const data = "proof-of-brain commitment: passport.gay identity via QRTP";
    const seed: u64 = 0xDA55;
    var enc = Encoder.initWithMode(seed, data, .chacha);
    const k = enc.sourceCount();

    var dec = Decoder.initWithMode(seed, k, .chacha);

    var blocks_sent: u32 = 0;
    while (!dec.isComplete()) : (blocks_sent += 1) {
        const block = enc.nextBlock();
        _ = dec.processBlock(&block);
        if (blocks_sent > k * 10) break;
    }

    try std.testing.expect(dec.isComplete());
    var out: [1024]u8 = undefined;
    const len = dec.reassemble(&out).?;
    try std.testing.expectEqualSlices(u8, data, out[0..len]);
}

test "chacha multi-block round trip" {
    var data: [DEFAULT_BLOCK_SIZE * 3]u8 = undefined;
    for (&data, 0..) |*b, i| b.* = @intCast(i % 197);

    const seed: u64 = 0xC8AC;
    var enc = Encoder.initWithMode(seed, &data, .chacha);
    const k = enc.sourceCount();

    var dec = Decoder.initWithMode(seed, k, .chacha);

    var blocks_sent: u32 = 0;
    while (!dec.isComplete()) : (blocks_sent += 1) {
        const block = enc.nextBlock();
        _ = dec.processBlock(&block);
        if (blocks_sent > k * 20) break;
    }

    try std.testing.expect(dec.isComplete());
    var out: [DEFAULT_BLOCK_SIZE * 3]u8 = undefined;
    const len = dec.reassemble(&out).?;
    try std.testing.expectEqualSlices(u8, &data, out[0..len]);
}

test "decoder not complete without enough blocks" {
    const data = "short";
    const seed: u64 = 999;
    var enc = Encoder.init(seed, data);
    const k = enc.sourceCount();

    var dec = Decoder.init(seed, k);
    // Don't send any blocks
    try std.testing.expect(!dec.isComplete());
    try std.testing.expect(dec.reassemble(&[_]u8{}) == null);

    // Send one block (should complete for K=1)
    const block = enc.nextBlock();
    _ = dec.processBlock(&block);
    try std.testing.expect(dec.isComplete());
}

test "redundant blocks are harmless" {
    const data = "abc";
    const seed: u64 = 42;
    var enc = Encoder.init(seed, data);
    const k = enc.sourceCount();

    var dec = Decoder.init(seed, k);

    // Send way more blocks than needed
    for (0..50) |_| {
        const block = enc.nextBlock();
        _ = dec.processBlock(&block);
    }

    try std.testing.expect(dec.isComplete());
    var out: [256]u8 = undefined;
    const len = dec.reassemble(&out).?;
    try std.testing.expectEqualSlices(u8, data, out[0..len]);
}
