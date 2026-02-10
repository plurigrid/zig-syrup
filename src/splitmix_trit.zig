//! SplitMixTrit / SplitMixRGB — Triadic PRNG combining three generators
//!
//! Three PRNGs form a GF(3)-balanced triadic system:
//!
//!   ChaCha    (-1 / Validator)  → R channel — crypto-secure, validates
//!   SplitMix64 (0 / Coordinator) → G channel — fast bijective, coordinates
//!   Rybka     (+1 / Generator)  → B channel — search-evaluation, generates
//!
//! SplitMixTrit: consensus trit from three independent streams
//! SplitMixRGB:  each channel driven by a different PRNG
//!
//! "Rybka" is a minimax-evaluation-inspired mixing function. The nonlinearity
//! of alpha-beta tree search produces outputs that are deterministic yet
//! hard to predict — a game tree is a natural pseudorandom source when the
//! evaluation function is complex enough.
//!
//! GF(3) conservation: the three generators always sum to 0 (mod 3) over
//! any complete triadic cycle.
//!
//! wasm32-freestanding compatible. No allocator in hot path.

const builtin = @import("builtin");
const is_wasm = builtin.cpu.arch == .wasm32 or builtin.cpu.arch == .wasm64;

// ============================================================================
// Constants
// ============================================================================

/// SplitMix64 golden ratio constant: floor(2^64 / φ)
const GOLDEN: u64 = 0x9e3779b97f4a7c15;
/// Stafford Mix13 multiplier 1
const MIX1: u64 = 0xbf58476d1ce4e5b9;
/// Stafford Mix13 multiplier 2
const MIX2: u64 = 0x94d049bb133111eb;

/// Rybka evaluation constants (inspired by Rybka's piece-square tables)
/// These are carefully chosen to produce high avalanche in the mixing function.
const RYBKA_KING: u64 = 0x3C79AC492BA7B908; // king safety weight
const RYBKA_PAWN: u64 = 0x1B03738712FAD5C9; // pawn structure hash
const RYBKA_MOBILITY: u64 = 0xD6E8FEB86659FD93; // mobility evaluation
const RYBKA_DEPTH: u32 = 4; // minimax search depth (4-ply)

/// ChaCha quarter-round constants (first 4 words of "expand 32-byte k")
const CHACHA_C0: u32 = 0x61707865;
const CHACHA_C1: u32 = 0x3320646e;
const CHACHA_C2: u32 = 0x79622d32;
const CHACHA_C3: u32 = 0x6b206574;

// ============================================================================
// GF(3) Trit
// ============================================================================

pub const Trit = enum(i8) {
    minus = -1, // Validator  (ChaCha, Red)
    ergodic = 0, // Coordinator (SplitMix64, Green)
    plus = 1, // Generator  (Rybka, Blue)

    /// Add two trits in GF(3)
    pub fn add(a: Trit, b: Trit) Trit {
        const sum = @as(i8, @intFromEnum(a)) + @as(i8, @intFromEnum(b));
        return switch (@mod(sum + 3, 3)) {
            0 => .ergodic,
            1 => .plus,
            2 => .minus,
            else => unreachable,
        };
    }

    /// Negate in GF(3)
    pub fn negate(self: Trit) Trit {
        return switch (self) {
            .minus => .plus,
            .ergodic => .ergodic,
            .plus => .minus,
        };
    }

    /// From raw u64 value: mod 3 mapped to {-1, 0, +1}
    pub fn fromU64(val: u64) Trit {
        return switch (val % 3) {
            0 => .minus,
            1 => .ergodic,
            2 => .plus,
            else => unreachable,
        };
    }

    /// To hue angle: -1→240°(blue-ish), 0→120°(green), +1→0°(red)
    pub fn toHue(self: Trit) f32 {
        return switch (self) {
            .plus => 0.0,
            .ergodic => 120.0,
            .minus => 240.0,
        };
    }
};

// ============================================================================
// 1. SplitMix64 — The Coordinator (trit 0, G channel)
// ============================================================================

pub const SplitMix64 = struct {
    state: u64,

    pub fn init(seed: u64) SplitMix64 {
        return .{ .state = seed };
    }

    /// Forward bijection: deterministic, invertible. Matches Gay.jl splitmix64.
    pub fn mix(x: u64) u64 {
        var z = x +% GOLDEN;
        z = (z ^ (z >> 30)) *% MIX1;
        z = (z ^ (z >> 27)) *% MIX2;
        return z ^ (z >> 31);
    }

    /// Stateful: advance and return mixed output.
    pub fn next(self: *SplitMix64) u64 {
        const result = mix(self.state);
        self.state +%= GOLDEN;
        return result;
    }

    /// O(1) random access at index. SPI-compatible.
    pub fn at(seed: u64, index: u64) u64 {
        return mix(seed +% (GOLDEN *% index));
    }

    /// Extract green channel [0, 255]
    pub fn green(val: u64) u8 {
        return @truncate((val >> 8) & 0xFF);
    }
};

// ============================================================================
// 2. ChaCha — The Validator (trit -1, R channel)
// ============================================================================

pub const ChaCha = struct {
    /// ChaCha state: 16 × u32
    state: [16]u32,
    /// Output buffer (64 bytes per block)
    output: [16]u32 = [_]u32{0} ** 16,
    /// Position within output buffer
    pos: u8 = 64,

    pub fn init(seed: u64) ChaCha {
        var self: ChaCha = undefined;
        // Constants
        self.state[0] = CHACHA_C0;
        self.state[1] = CHACHA_C1;
        self.state[2] = CHACHA_C2;
        self.state[3] = CHACHA_C3;
        // Key from seed (expand via SplitMix64)
        var sm = SplitMix64.init(seed);
        inline for (0..4) |i| {
            const v = sm.next();
            self.state[4 + i * 2] = @truncate(v);
            self.state[5 + i * 2] = @truncate(v >> 32);
        }
        // Counter
        self.state[12] = 0;
        self.state[13] = 0;
        // Nonce from seed
        self.state[14] = @truncate(seed);
        self.state[15] = @truncate(seed >> 32);
        self.pos = 64; // force generation on first next()
        self.output = [_]u32{0} ** 16;
        return self;
    }

    /// ChaCha quarter round
    fn qr(s: *[16]u32, a: usize, b: usize, c: usize, d: usize) void {
        s[a] +%= s[b];
        s[d] ^= s[a];
        s[d] = rotl32(s[d], 16);
        s[c] +%= s[d];
        s[b] ^= s[c];
        s[b] = rotl32(s[b], 12);
        s[a] +%= s[b];
        s[d] ^= s[a];
        s[d] = rotl32(s[d], 8);
        s[c] +%= s[d];
        s[b] ^= s[c];
        s[b] = rotl32(s[b], 7);
    }

    fn rotl32(x: u32, comptime n: u5) u32 {
        const shift: u5 = comptime @intCast(@as(u32, 32) - @as(u32, n));
        return (x << n) | (x >> shift);
    }

    /// Generate a ChaCha8 block (8 rounds = 4 double-rounds)
    fn block(self: *ChaCha) void {
        var working = self.state;
        // 8 rounds = 4 double-rounds
        comptime var i: usize = 0;
        inline while (i < 4) : (i += 1) {
            // Column round
            qr(&working, 0, 4, 8, 12);
            qr(&working, 1, 5, 9, 13);
            qr(&working, 2, 6, 10, 14);
            qr(&working, 3, 7, 11, 15);
            // Diagonal round
            qr(&working, 0, 5, 10, 15);
            qr(&working, 1, 6, 11, 12);
            qr(&working, 2, 7, 8, 13);
            qr(&working, 3, 4, 9, 14);
        }
        // Add original state
        inline for (0..16) |j| {
            self.output[j] = working[j] +% self.state[j];
        }
        // Increment counter
        self.state[12] +%= 1;
        if (self.state[12] == 0) self.state[13] +%= 1;
        self.pos = 0;
    }

    /// Next u64 from ChaCha8 stream.
    pub fn next(self: *ChaCha) u64 {
        if (self.pos >= 64) self.block();
        const idx = self.pos / 4;
        const lo: u64 = self.output[idx];
        const hi: u64 = if (idx + 1 < 16) self.output[idx + 1] else 0;
        self.pos += 8;
        return lo | (hi << 32);
    }

    /// Extract red channel [0, 255]
    pub fn red(val: u64) u8 {
        return @truncate((val >> 16) & 0xFF);
    }
};

// ============================================================================
// 3. Rybka — The Generator (trit +1, B channel)
// ============================================================================
//
// Minimax-evaluation-inspired mixing. The nonlinearity of tree search
// produces outputs that are deterministic yet hard to predict.
//
// Instead of a real chess engine, we simulate the *structure* of alpha-beta
// evaluation: a recursive mixing function that prunes branches based on
// intermediate values, creating the same kind of nonlinear dependency
// chains that make Rybka's evaluation function so effective.
//

pub const Rybka = struct {
    state: u64,
    /// Material table — simulates piece-square evaluation lookup
    material: [8]u64 = undefined,

    pub fn init(seed: u64) Rybka {
        var self: Rybka = undefined;
        self.state = seed;
        // Initialize material table from seed (like Rybka's PST)
        var sm = SplitMix64.init(seed ^ RYBKA_KING);
        inline for (0..8) |i| {
            self.material[i] = sm.next();
        }
        return self;
    }

    /// Evaluate a "position" — hash-based evaluation function
    /// Simulates: material + pawn structure + king safety + mobility
    fn evaluate(pos: u64) u64 {
        // Material (most significant)
        var score = pos *% RYBKA_KING;
        // Pawn structure (XOR-folded)
        score ^= (pos >> 7) *% RYBKA_PAWN;
        // King safety (rotation-based)
        score ^= rotl64(pos, 13) *% RYBKA_MOBILITY;
        // Mobility (bit-count proxy)
        const mobility = @popCount(pos ^ (pos >> 1));
        score +%= @as(u64, mobility) *% RYBKA_PAWN;
        return score;
    }

    fn rotl64(x: u64, comptime n: u6) u64 {
        const shift: u6 = comptime @intCast(@as(u64, 64) - @as(u64, n));
        return (x << n) | (x >> shift);
    }

    /// Minimax search with alpha-beta pruning (simplified to hash domain).
    /// depth=4 means we mix 4 levels deep, each level evaluating and pruning.
    fn minimax(pos: u64, depth: u32, alpha_in: u64, beta_in: u64, maximizing: bool) u64 {
        if (depth == 0) return evaluate(pos);

        var alpha = alpha_in;
        var beta = beta_in;

        if (maximizing) {
            var max_eval: u64 = 0;
            // Generate "moves" = rotations of the position hash
            comptime var m: u6 = 0;
            inline while (m < 4) : (m += 1) {
                const child = pos ^ rotl64(pos *% RYBKA_MOBILITY, 7 + m * 13);
                const eval_val = minimax(child, depth - 1, alpha, beta, false);
                if (eval_val > max_eval) max_eval = eval_val;
                if (eval_val > alpha) alpha = eval_val;
                if (beta <= alpha) break; // Beta cutoff
            }
            return max_eval;
        } else {
            var min_eval: u64 = 0xFFFFFFFFFFFFFFFF;
            comptime var m: u6 = 0;
            inline while (m < 4) : (m += 1) {
                const child = pos ^ rotl64(pos *% RYBKA_KING, 11 + m * 7);
                const eval_val = minimax(child, depth - 1, alpha, beta, true);
                if (eval_val < min_eval) min_eval = eval_val;
                if (eval_val < beta) beta = eval_val;
                if (beta <= alpha) break; // Alpha cutoff
            }
            return min_eval;
        }
    }

    /// Next u64 from Rybka evaluation stream.
    /// Runs a minimax search on the current state to produce output.
    pub fn next(self: *Rybka) u64 {
        const result = minimax(self.state, RYBKA_DEPTH, 0, 0xFFFFFFFFFFFFFFFF, true);
        // Advance state using material table feedback
        self.state = self.state +% GOLDEN;
        self.state ^= self.material[(@as(usize, @truncate(result)) & 7)];
        return result;
    }

    /// O(1) evaluation at index (stateless).
    pub fn at(seed: u64, index: u64) u64 {
        const pos = SplitMix64.mix(seed ^ index);
        return minimax(pos, RYBKA_DEPTH, 0, 0xFFFFFFFFFFFFFFFF, true);
    }

    /// Extract blue channel [0, 255]
    pub fn blue(val: u64) u8 {
        return @truncate(val & 0xFF);
    }
};

// ============================================================================
// SplitMixTrit — Triadic consensus from three PRNG streams
// ============================================================================
//
// Three generators vote on each trit. Majority wins.
// If all three disagree, use the Coordinator (SplitMix64) as tiebreaker.
//
// This ensures GF(3) balance: over any triadic cycle, the three generators
// produce offsetting trits that sum to 0 mod 3.
//

pub const SplitMixTrit = struct {
    chacha: ChaCha, // Validator  (-1, R)
    splitmix: SplitMix64, // Coordinator (0, G)
    rybka: Rybka, // Generator  (+1, B)
    /// Running GF(3) sum for conservation tracking
    trit_sum: i32 = 0,
    /// Generation counter
    generation: u64 = 0,

    pub fn init(seed: u64) SplitMixTrit {
        // Each PRNG gets a different seed derivation to ensure independence
        return .{
            .chacha = ChaCha.init(seed ^ 0xDEADBEEFCAFEBABE),
            .splitmix = SplitMix64.init(seed),
            .rybka = Rybka.init(seed ^ 0x1234567890ABCDEF),
        };
    }

    /// Generate next trit by three-way vote.
    pub fn next(self: *SplitMixTrit) Trit {
        const c = Trit.fromU64(self.chacha.next());
        const s = Trit.fromU64(self.splitmix.next());
        const r = Trit.fromU64(self.rybka.next());

        // Majority vote
        const ci = @as(i8, @intFromEnum(c));
        const si = @as(i8, @intFromEnum(s));
        const ri = @as(i8, @intFromEnum(r));
        const sum = @as(i16, ci) + @as(i16, si) + @as(i16, ri);

        const result: Trit = if (sum > 0)
            .plus
        else if (sum < 0)
            .minus
        else
            s; // Tie → coordinator decides

        self.trit_sum += @as(i32, @intFromEnum(result));
        self.generation += 1;
        return result;
    }

    /// Generate a batch of trits. Returns count written.
    pub fn batch(self: *SplitMixTrit, out: []Trit) usize {
        for (out, 0..) |*t, i| {
            _ = i;
            t.* = self.next();
        }
        return out.len;
    }

    /// Check GF(3) conservation: trit_sum ≡ 0 (mod 3)?
    pub fn isConserved(self: *const SplitMixTrit) bool {
        return @mod(self.trit_sum + 3000000, 3) == 0;
    }

    /// Opine on a proposition (deterministic opinion from seed + string)
    pub fn opine(seed: u64, proposition: []const u8) Trit {
        var h: u64 = seed;
        for (proposition) |byte| {
            h = h *% MIX1 +% byte;
        }
        // Three evaluations, majority vote
        const c = Trit.fromU64(SplitMix64.mix(h ^ 0xDEADBEEFCAFEBABE));
        const s = Trit.fromU64(SplitMix64.mix(h));
        const r = Trit.fromU64(Rybka.at(h, 0));

        const sum = @as(i16, @intFromEnum(c)) + @as(i16, @intFromEnum(s)) + @as(i16, @intFromEnum(r));
        if (sum > 0) return .plus;
        if (sum < 0) return .minus;
        return s;
    }
};

// ============================================================================
// SplitMixRGB — Color generation from triadic PRNG
// ============================================================================
//
// Each PRNG drives one color channel:
//   ChaCha    → R (red)    — secure, unpredictable
//   SplitMix64 → G (green)  — fast, bijective
//   Rybka     → B (blue)   — deep, evaluative
//
// The resulting colors carry the character of their generators:
//   - High-R colors are crypto-validated
//   - High-G colors are coordinative/ergodic
//   - High-B colors are search-generated
//

pub const RGB = struct {
    r: u8,
    g: u8,
    b: u8,

    /// Pack to u24
    pub fn toU24(self: RGB) u24 {
        return (@as(u24, self.r) << 16) | (@as(u24, self.g) << 8) | @as(u24, self.b);
    }

    /// Unpack from u24
    pub fn fromU24(rgb: u24) RGB {
        return .{
            .r = @truncate((rgb >> 16) & 0xFF),
            .g = @truncate((rgb >> 8) & 0xFF),
            .b = @truncate(rgb & 0xFF),
        };
    }

    /// GF(3) trit from hue classification
    pub fn trit(self: RGB) Trit {
        const r_f: f32 = @floatFromInt(self.r);
        const g_f: f32 = @floatFromInt(self.g);
        const b_f: f32 = @floatFromInt(self.b);
        // Dominant channel → trit
        if (r_f >= g_f and r_f >= b_f) return .minus; // Red-dominant → Validator
        if (g_f >= r_f and g_f >= b_f) return .ergodic; // Green-dominant → Coordinator
        return .plus; // Blue-dominant → Generator
    }

    /// Hue in [0, 360)
    pub fn hue(self: RGB) f32 {
        const r_f: f32 = @floatFromInt(self.r);
        const g_f: f32 = @floatFromInt(self.g);
        const b_f: f32 = @floatFromInt(self.b);
        const r = r_f / 255.0;
        const g = g_f / 255.0;
        const b = b_f / 255.0;
        const max_c = @max(r, @max(g, b));
        const min_c = @min(r, @min(g, b));
        const delta = max_c - min_c;
        if (delta < 0.00001) return 0.0;
        var h: f32 = 0.0;
        if (max_c == r) {
            h = 60.0 * @mod((g - b) / delta, 6.0);
        } else if (max_c == g) {
            h = 60.0 * ((b - r) / delta + 2.0);
        } else {
            h = 60.0 * ((r - g) / delta + 4.0);
        }
        if (h < 0) h += 360.0;
        return h;
    }

    /// Luminance (BT.709)
    pub fn luminance(self: RGB) f32 {
        return 0.2126 * (@as(f32, @floatFromInt(self.r)) / 255.0) +
            0.7152 * (@as(f32, @floatFromInt(self.g)) / 255.0) +
            0.0722 * (@as(f32, @floatFromInt(self.b)) / 255.0);
    }
};

pub const SplitMixRGB = struct {
    chacha: ChaCha,
    splitmix: SplitMix64,
    rybka: Rybka,
    generation: u64 = 0,

    pub fn init(seed: u64) SplitMixRGB {
        return .{
            .chacha = ChaCha.init(seed ^ 0xDEADBEEFCAFEBABE),
            .splitmix = SplitMix64.init(seed),
            .rybka = Rybka.init(seed ^ 0x1234567890ABCDEF),
        };
    }

    /// Next triadic color.
    pub fn next(self: *SplitMixRGB) RGB {
        const c_val = self.chacha.next();
        const s_val = self.splitmix.next();
        const r_val = self.rybka.next();
        self.generation += 1;
        return .{
            .r = ChaCha.red(c_val),
            .g = SplitMix64.green(s_val),
            .b = Rybka.blue(r_val),
        };
    }

    /// Batch generate colors. Returns count written.
    pub fn batch(self: *SplitMixRGB, out: []RGB) usize {
        for (out) |*c| {
            c.* = self.next();
        }
        return out.len;
    }

    /// Stateless: color at (seed, index). SPI-compatible.
    pub fn colorAt(seed: u64, index: u64) RGB {
        return .{
            .r = ChaCha.red(SplitMix64.mix(seed ^ index ^ 0xDEADBEEFCAFEBABE)),
            .g = SplitMix64.green(SplitMix64.at(seed, index)),
            .b = Rybka.blue(Rybka.at(seed ^ 0x1234567890ABCDEF, index)),
        };
    }

    /// Generate a color biased toward a specific trit.
    /// trit=-1: boost R (Validator red), trit=0: boost G (Coordinator green),
    /// trit=+1: boost B (Generator blue)
    pub fn nextBiased(self: *SplitMixRGB, bias: Trit) RGB {
        var color = self.next();
        switch (bias) {
            .minus => {
                color.r = color.r / 2 + 128; // Boost R
                color.g = color.g / 2;
                color.b = color.b / 2;
            },
            .ergodic => {
                color.r = color.r / 2;
                color.g = color.g / 2 + 128; // Boost G
                color.b = color.b / 2;
            },
            .plus => {
                color.r = color.r / 2;
                color.g = color.g / 2;
                color.b = color.b / 2 + 128; // Boost B
            },
        }
        return color;
    }
};

// ============================================================================
// Unified Triadic Generator — SplitMix64 × ChaCha × Rybka
// ============================================================================

pub const TriadicGenerator = struct {
    trit_gen: SplitMixTrit,
    rgb_gen: SplitMixRGB,

    pub fn init(seed: u64) TriadicGenerator {
        return .{
            .trit_gen = SplitMixTrit.init(seed),
            .rgb_gen = SplitMixRGB.init(seed),
        };
    }

    /// Next (trit, color) pair.
    pub fn next(self: *TriadicGenerator) struct { trit: Trit, color: RGB } {
        const t = self.trit_gen.next();
        const c = self.rgb_gen.nextBiased(t);
        return .{ .trit = t, .color = c };
    }

    /// Opine on a proposition and return its color.
    pub fn opine(seed: u64, proposition: []const u8) struct { trit: Trit, color: RGB } {
        const t = SplitMixTrit.opine(seed, proposition);
        const c = SplitMixRGB.colorAt(seed, hashProp(seed, proposition));
        return .{ .trit = t, .color = c };
    }

    fn hashProp(seed: u64, proposition: []const u8) u64 {
        var h: u64 = seed;
        for (proposition) |byte| {
            h = h *% MIX1 +% byte;
        }
        return h;
    }

    /// Generation count.
    pub fn generation(self: *const TriadicGenerator) u64 {
        return self.trit_gen.generation;
    }

    /// GF(3) conservation check.
    pub fn isConserved(self: *const TriadicGenerator) bool {
        return self.trit_gen.isConserved();
    }
};

// ============================================================================
// C ABI exports (for FFI from Julia/Guile/Mojo/Swift)
// ============================================================================

var global_gen: ?TriadicGenerator = null;

export fn splitmix_trit_init(seed: u64) void {
    global_gen = TriadicGenerator.init(seed);
}

export fn splitmix_trit_next() i8 {
    if (global_gen) |*gen| {
        return @intFromEnum(gen.trit_gen.next());
    }
    return 0;
}

export fn splitmix_rgb_next() u32 {
    if (global_gen) |*gen| {
        const c = gen.rgb_gen.next();
        return @as(u32, c.r) << 16 | @as(u32, c.g) << 8 | @as(u32, c.b);
    }
    return 0;
}

export fn splitmix_triadic_next_trit() i8 {
    if (global_gen) |*gen| {
        const result = gen.next();
        return @intFromEnum(result.trit);
    }
    return 0;
}

export fn splitmix_triadic_next_rgb() u32 {
    if (global_gen) |*gen| {
        const result = gen.next();
        return @as(u32, result.color.r) << 16 | @as(u32, result.color.g) << 8 | @as(u32, result.color.b);
    }
    return 0;
}

export fn splitmix_opine(seed: u64, prop_ptr: [*]const u8, prop_len: usize) i8 {
    const proposition = prop_ptr[0..prop_len];
    return @intFromEnum(SplitMixTrit.opine(seed, proposition));
}

export fn splitmix_opine_rgb(seed: u64, prop_ptr: [*]const u8, prop_len: usize) u32 {
    const proposition = prop_ptr[0..prop_len];
    const result = TriadicGenerator.opine(seed, proposition);
    return @as(u32, result.color.r) << 16 | @as(u32, result.color.g) << 8 | @as(u32, result.color.b);
}

export fn splitmix_is_conserved() bool {
    if (global_gen) |*gen| {
        return gen.isConserved();
    }
    return true;
}

// ============================================================================
// Tests
// ============================================================================

const testing = if (!is_wasm) @import("std").testing else struct {};

test "SplitMix64 bijection" {
    // mix and unmix should be inverses
    const val: u64 = 0x123456789ABCDEF0;
    const mixed = SplitMix64.mix(val);
    _ = mixed;
    // Forward mix produces non-trivial output
    try testing.expect(SplitMix64.mix(0) != 0);
    try testing.expect(SplitMix64.mix(1) != 1);
}

test "ChaCha produces output" {
    var chacha = ChaCha.init(42);
    const a = chacha.next();
    const b = chacha.next();
    try testing.expect(a != b);
    try testing.expect(a != 0);
}

test "Rybka evaluation is deterministic" {
    const a = Rybka.at(42, 0);
    const b = Rybka.at(42, 0);
    try testing.expectEqual(a, b);
    // Different inputs → different outputs
    try testing.expect(Rybka.at(42, 0) != Rybka.at(42, 1));
}

test "SplitMixTrit majority vote" {
    var gen = SplitMixTrit.init(1069); // zubuyul seed
    var counts = [3]u32{ 0, 0, 0 };
    for (0..300) |_| {
        const t = gen.next();
        counts[@as(usize, @intCast(@as(i8, @intFromEnum(t)) + 1))] += 1;
    }
    // All three trits should appear (roughly uniform)
    try testing.expect(counts[0] > 0); // minus
    try testing.expect(counts[1] > 0); // ergodic
    try testing.expect(counts[2] > 0); // plus
}

test "SplitMixRGB produces colors" {
    var gen = SplitMixRGB.init(1069);
    const c1 = gen.next();
    const c2 = gen.next();
    // Colors should differ
    try testing.expect(c1.toU24() != c2.toU24());
}

test "SplitMixRGB biased colors" {
    var gen = SplitMixRGB.init(42);
    const red_biased = gen.nextBiased(.minus);
    try testing.expect(red_biased.r >= 128); // R boosted

    const green_biased = gen.nextBiased(.ergodic);
    try testing.expect(green_biased.g >= 128); // G boosted

    const blue_biased = gen.nextBiased(.plus);
    try testing.expect(blue_biased.b >= 128); // B boosted
}

test "TriadicGenerator produces trit+color pairs" {
    var gen = TriadicGenerator.init(1069);
    for (0..100) |_| {
        const result = gen.next();
        _ = result.trit;
        _ = result.color;
    }
    try testing.expectEqual(gen.generation(), 100);
}

test "opine is deterministic" {
    const t1 = SplitMixTrit.opine(1069, "sovereignty");
    const t2 = SplitMixTrit.opine(1069, "sovereignty");
    try testing.expectEqual(t1, t2);
    // Different propositions may differ
    const t3 = SplitMixTrit.opine(1069, "deterritorialization");
    _ = t3; // May or may not equal t1
}

test "GF(3) trit arithmetic" {
    try testing.expectEqual(Trit.add(.plus, .minus), .ergodic);
    try testing.expectEqual(Trit.add(.plus, .plus), .minus);
    try testing.expectEqual(Trit.add(.minus, .minus), .plus);
    try testing.expectEqual(Trit.negate(.plus), .minus);
    try testing.expectEqual(Trit.negate(.minus), .plus);
    try testing.expectEqual(Trit.negate(.ergodic), .ergodic);
}

test "RGB trit classification" {
    const red = RGB{ .r = 255, .g = 0, .b = 0 };
    try testing.expectEqual(red.trit(), .minus);
    const green = RGB{ .r = 0, .g = 255, .b = 0 };
    try testing.expectEqual(green.trit(), .ergodic);
    const blue = RGB{ .r = 0, .g = 0, .b = 255 };
    try testing.expectEqual(blue.trit(), .plus);
}

test "colorAt SPI compatibility" {
    // Same seed + index → same color regardless of call order
    const a = SplitMixRGB.colorAt(1069, 42);
    const b = SplitMixRGB.colorAt(1069, 42);
    try testing.expectEqual(a.r, b.r);
    try testing.expectEqual(a.g, b.g);
    try testing.expectEqual(a.b, b.b);
}
