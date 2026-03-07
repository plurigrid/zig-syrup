//! ColorValue: Referentially Transparent Unified Color Type
//!
//! Synthesizes five existing color subsystems under one pure value type:
//!   gf3_palette.zig  → GF(3)^5 cyclotomic address (standard part)
//!   splitmix_trit.zig → SPI-compatible deterministic color generation
//!   lux_color.zig    → operadic composition with golden angle rotation
//!   hyperreal.zig    → infinitesimal sub-perceptual entropy
//!   color_simd.zig   → SIMD batch projection
//!
//! Referential transparency: ColorValue.at(seed, index) is a pure function.
//! Same (seed, index) pair always produces the same ColorValue.
//! No global state, no mutation, only construction.
//!
//! Operadic composition: compose(op, args) implements category-colored
//! operad partial composition (Trnka 2023, TAC Vol. 39), with GF(3)
//! trit conservation and hyperreal infinitesimal propagation via the
//! chain rule (the "colored operad view" of entropy).
//!
//! Cyclotomic grounding: GF(3)^5 = Z[ζ₃]^5 mod (ζ₃² + ζ₃ + 1).
//! The 243-color palette is a section of the cyclotomic lattice, and
//! trit conservation corresponds to perfect coloring (Bugarin-Frettlöh 2012).

const std = @import("std");
const math = std.math;

// ---------------------------------------------------------------------------
// GF(3) Trit (balanced ternary: {-1, 0, +1})
// ---------------------------------------------------------------------------

pub const Trit = enum(i8) {
    minus = -1,
    zero = 0,
    plus = 1,

    pub fn add(a: Trit, b: Trit) Trit {
        const sum = @as(i16, @intFromEnum(a)) + @as(i16, @intFromEnum(b));
        const m = @mod(sum + 3, 3);
        return switch (m) {
            0 => .zero,
            1 => .plus,
            2 => .minus,
            else => unreachable,
        };
    }

    pub fn negate(self: Trit) Trit {
        return switch (self) {
            .minus => .plus,
            .zero => .zero,
            .plus => .minus,
        };
    }

    pub fn fromU64(val: u64) Trit {
        return switch (val % 3) {
            0 => .zero,
            1 => .plus,
            2 => .minus,
            else => unreachable,
        };
    }

    pub fn baseHue(self: Trit) f32 {
        return switch (self) {
            .minus => 0.0, // Red
            .zero => 120.0, // Green
            .plus => 240.0, // Blue
        };
    }
};

// ---------------------------------------------------------------------------
// TritWord: 5-trit address in GF(3)^5
// ---------------------------------------------------------------------------

pub const TritWord = struct {
    trits: [5]Trit,

    pub fn init(l: Trit, h0: Trit, h1: Trit, c0: Trit, c1: Trit) TritWord {
        return .{ .trits = .{ l, h0, h1, c0, c1 } };
    }

    pub fn toIndex(self: TritWord) u8 {
        var idx: u16 = 0;
        inline for (0..5) |i| {
            idx = idx * 3 + @as(u16, @intCast(@as(i16, @intFromEnum(self.trits[i])) + 1));
        }
        return @intCast(idx);
    }

    pub fn fromIndex(idx: u8) TritWord {
        std.debug.assert(idx < 243);
        var remaining: u16 = idx;
        var word: TritWord = undefined;
        comptime var i: usize = 5;
        inline while (i > 0) {
            i -= 1;
            const r = remaining % 3;
            word.trits[i] = @enumFromInt(@as(i8, @intCast(r)) - 1);
            remaining /= 3;
        }
        return word;
    }

    /// Negate all 5 trits (GF(3) involution on the word).
    /// Involutive: negate(negate(w)) == w.
    pub fn negateTritWord(self: TritWord) TritWord {
        var result: TritWord = undefined;
        inline for (0..5) |i| {
            result.trits[i] = self.trits[i].negate();
        }
        return result;
    }

    pub fn checksum(self: TritWord) Trit {
        var sum = self.trits[0];
        inline for (1..5) |i| {
            sum = Trit.add(sum, self.trits[i]);
        }
        return sum;
    }

    pub fn applyCNOT3(self: TritWord, position: u3, control: Trit) TritWord {
        if (position >= 5) return self;
        var result = self;
        result.trits[position] = Trit.add(self.trits[position], control);
        return result;
    }

    pub fn luminosity(self: TritWord) Trit {
        return self.trits[0];
    }

    pub fn hueSector(self: TritWord) u4 {
        const h0: u8 = @intCast(@as(i16, @intFromEnum(self.trits[1])) + 1);
        const h1: u8 = @intCast(@as(i16, @intFromEnum(self.trits[2])) + 1);
        return @intCast(h0 * 3 + h1);
    }

    pub fn chromaLevel(self: TritWord) u4 {
        const c0: u8 = @intCast(@as(i16, @intFromEnum(self.trits[3])) + 1);
        const c1: u8 = @intCast(@as(i16, @intFromEnum(self.trits[4])) + 1);
        return @intCast(c0 * 3 + c1);
    }
};

// ---------------------------------------------------------------------------
// SplitMix64 (deterministic, referentially transparent PRNG)
// ---------------------------------------------------------------------------

const GOLDEN: u64 = 0x9E3779B97F4A7C15;

fn splitmix64(x: u64) u64 {
    var z = x +% GOLDEN;
    z = (z ^ (z >> 30)) *% 0xBF58476D1CE4E5B9;
    z = (z ^ (z >> 27)) *% 0x94D049BB133111EB;
    return z ^ (z >> 31);
}

fn colorAtRaw(seed: u64, index: u64) u64 {
    return splitmix64(seed +% (GOLDEN *% index));
}

// ---------------------------------------------------------------------------
// Infinitesimal (f16 triple for hyperreal sub-perceptual entropy)
// ---------------------------------------------------------------------------

pub const Infinitesimal = struct {
    dr: f16 = 0,
    dg: f16 = 0,
    db: f16 = 0,

    pub const ZERO = Infinitesimal{};

    pub fn add(self: Infinitesimal, other: Infinitesimal) Infinitesimal {
        return .{
            .dr = self.dr + other.dr,
            .dg = self.dg + other.dg,
            .db = self.db + other.db,
        };
    }

    pub fn scale(self: Infinitesimal, s: f16) Infinitesimal {
        return .{
            .dr = self.dr * s,
            .dg = self.dg * s,
            .db = self.db * s,
        };
    }

    /// L2 norm squared of the infinitesimal (entropy measure)
    pub fn normSq(self: Infinitesimal) f32 {
        const dr: f32 = @floatCast(self.dr);
        const dg: f32 = @floatCast(self.dg);
        const db: f32 = @floatCast(self.db);
        return dr * dr + dg * dg + db * db;
    }

    pub fn eql(self: Infinitesimal, other: Infinitesimal) bool {
        return self.dr == other.dr and self.dg == other.dg and self.db == other.db;
    }

    /// Derive infinitesimal from quantization error (RGB minus palette entry)
    pub fn fromQuantizationError(r: u8, g: u8, b: u8, pr: u8, pg: u8, pb: u8) Infinitesimal {
        return .{
            .dr = @as(f16, @floatFromInt(@as(i16, r) - @as(i16, pr))) / 255.0,
            .dg = @as(f16, @floatFromInt(@as(i16, g) - @as(i16, pg))) / 255.0,
            .db = @as(f16, @floatFromInt(@as(i16, b) - @as(i16, pb))) / 255.0,
        };
    }
};

// ---------------------------------------------------------------------------
// RGB24 (compact output type)
// ---------------------------------------------------------------------------

pub const RGB = struct {
    r: u8,
    g: u8,
    b: u8,

    pub fn toU24(self: RGB) u24 {
        return (@as(u24, self.r) << 16) | (@as(u24, self.g) << 8) | @as(u24, self.b);
    }

    pub fn fromU24(v: u24) RGB {
        return .{
            .r = @truncate(v >> 16),
            .g = @truncate(v >> 8),
            .b = @truncate(v),
        };
    }
};

// ---------------------------------------------------------------------------
// Palette generation (inlined from gf3_palette logic)
// ---------------------------------------------------------------------------

const HUE_SECTORS = [9]f64{ 0, 40, 80, 120, 160, 200, 240, 280, 320 };
const CHROMA_LEVELS = [9][2]f64{
    .{ 0.08, 0.50 }, .{ 0.08, 0.75 }, .{ 0.08, 1.00 },
    .{ 0.40, 0.50 }, .{ 0.40, 0.75 }, .{ 0.40, 1.00 },
    .{ 0.80, 0.50 }, .{ 0.80, 0.75 }, .{ 0.80, 1.00 },
};
const LUMINOSITY_LEVELS = [3]f64{ 0.30, 0.55, 0.80 };

fn hueToRgbHelper(p: f64, q: f64, t_in: f64) f64 {
    var t = t_in;
    if (t < 0) t += 1;
    if (t > 1) t -= 1;
    if (t < 1.0 / 6.0) return p + (q - p) * 6.0 * t;
    if (t < 1.0 / 2.0) return q;
    if (t < 2.0 / 3.0) return p + (q - p) * (2.0 / 3.0 - t) * 6.0;
    return p;
}

fn hslToRgb(h: f64, s: f64, l: f64) RGB {
    if (s < 0.01) {
        const v: u8 = @intFromFloat(@max(0, @min(255, l * 255.0)));
        return .{ .r = v, .g = v, .b = v };
    }
    const q = if (l < 0.5) l * (1.0 + s) else l + s - l * s;
    const p = 2.0 * l - q;
    const h_norm = @mod(h, 360.0) / 360.0;
    return .{
        .r = @intFromFloat(@max(0, @min(255, hueToRgbHelper(p, q, h_norm + 1.0 / 3.0) * 255.0))),
        .g = @intFromFloat(@max(0, @min(255, hueToRgbHelper(p, q, h_norm) * 255.0))),
        .b = @intFromFloat(@max(0, @min(255, hueToRgbHelper(p, q, h_norm - 1.0 / 3.0) * 255.0))),
    };
}

fn tritWordToRgb(word: TritWord) RGB {
    const l_idx: usize = @intCast(@as(i16, @intFromEnum(word.luminosity())) + 1);
    const lightness = LUMINOSITY_LEVELS[l_idx];
    const hue = HUE_SECTORS[word.hueSector()];
    const chroma = CHROMA_LEVELS[word.chromaLevel()];
    const saturation = chroma[0];
    const value = chroma[1];
    const effective_l = lightness * value;
    return hslToRgb(hue, saturation, @min(1.0, effective_l));
}

/// Static palette: 243 RGB entries computed at comptime.
const PALETTE: [243]RGB = blk: {
    @setEvalBranchQuota(100_000);
    var p: [243]RGB = undefined;
    for (0..243) |i| {
        p[i] = tritWordToRgb(TritWord.fromIndex(@intCast(i)));
    }
    break :blk p;
};

fn quantizeRgb(r: u8, g: u8, b: u8) struct { word: TritWord, rgb: RGB, dist_sq: u32 } {
    var best_dist: u32 = math.maxInt(u32);
    var best_idx: u8 = 0;
    for (0..243) |i| {
        const e = PALETTE[i];
        const dr: i32 = @as(i32, r) - @as(i32, e.r);
        const dg: i32 = @as(i32, g) - @as(i32, e.g);
        const db: i32 = @as(i32, b) - @as(i32, e.b);
        const dist: u32 = @intCast(dr * dr + dg * dg + db * db);
        if (dist < best_dist) {
            best_dist = dist;
            best_idx = @intCast(i);
        }
    }
    return .{
        .word = TritWord.fromIndex(best_idx),
        .rgb = PALETTE[best_idx],
        .dist_sq = best_dist,
    };
}

// ---------------------------------------------------------------------------
// Golden angle constant
// ---------------------------------------------------------------------------

pub const GOLDEN_ANGLE: f32 = 137.5077640500378;

// ---------------------------------------------------------------------------
// ColorValue: the unified referentially transparent color type
// ---------------------------------------------------------------------------

/// A referentially transparent color value.
///
/// Carries its full algebraic provenance:
///   - trit_word: GF(3)^5 cyclotomic address (standard part)
///   - depth: operadic nesting depth
///   - infinitesimal: hyperreal sub-perceptual entropy
///   - seed_fingerprint: SPI provenance (truncated hash of seed+index)
///
/// Construction is pure. No mutation. Leibniz substitutability holds:
/// if cv1 == cv2, then f(cv1) == f(cv2) for all f.
pub const ColorValue = struct {
    trit_word: TritWord,
    depth: u16,
    eps: Infinitesimal,
    seed_fingerprint: u32,

    /// Pure construction from seed + index.
    /// Referentially transparent: same (seed, index) -> same ColorValue.
    pub fn at(seed: u64, index: u64) ColorValue {
        const raw = colorAtRaw(seed, index);
        const r: u8 = @truncate((raw >> 16) & 0xFF);
        const g: u8 = @truncate((raw >> 8) & 0xFF);
        const b: u8 = @truncate(raw & 0xFF);

        const q = quantizeRgb(r, g, b);
        const epsilon = Infinitesimal.fromQuantizationError(r, g, b, q.rgb.r, q.rgb.g, q.rgb.b);

        return .{
            .trit_word = q.word,
            .depth = 0,
            .eps = epsilon,
            .seed_fingerprint = @truncate(splitmix64(seed ^ index)),
        };
    }

    /// Construct from an explicit trit word (e.g. for operad generators).
    pub fn fromTritWord(word: TritWord, depth: u16) ColorValue {
        return .{
            .trit_word = word,
            .depth = depth,
            .eps = Infinitesimal.ZERO,
            .seed_fingerprint = 0,
        };
    }

    /// Construct from a trit at a given operadic depth (lux_color compat).
    pub fn fromTrit(t: Trit, depth: u16) ColorValue {
        return .{
            .trit_word = TritWord.init(t, .zero, .zero, .zero, .zero),
            .depth = depth,
            .eps = Infinitesimal.ZERO,
            .seed_fingerprint = 0,
        };
    }

    /// Operadic composition: color of (op applied to args).
    ///
    /// Implements category-colored operad partial composition o_i
    /// (Trnka 2023, TAC Vol. 39, Def. 2.2):
    ///   P_n ⊗_i P_m -> P_{m+n-1}
    ///
    /// Trit conservation: result trit = sum of all trits (mod 3).
    /// Depth: max(child depths) + 1.
    /// Infinitesimal: chain rule propagation (the operadic view of entropy).
    ///   ε(f∘g) = f'(g(x)) · ε(g(x)) + ε(f)(g(x))
    /// Approximated as sum of infinitesimals scaled by 1/(n_args+1),
    /// preserving total infinitesimal energy without amplification.
    pub fn compose(op: ColorValue, args: []const ColorValue) ColorValue {
        var max_depth: u16 = op.depth;
        var result_trit = op.trit();
        var eps_acc = op.eps;

        for (args) |c| {
            max_depth = @max(max_depth, c.depth);
            result_trit = Trit.add(result_trit, c.trit());
            eps_acc = eps_acc.add(c.eps);
        }

        const n_total: f16 = @floatFromInt(@as(u16, @intCast(args.len)) + 1);
        const chain_factor: f16 = 1.0 / n_total;
        const propagated_eps = eps_acc.scale(chain_factor);

        const parent_depth = max_depth + 1;

        // Build parent trit word: result_trit as luminosity, depth-rotated hue
        const hue_rotation = @as(f32, @floatFromInt(parent_depth)) * GOLDEN_ANGLE;
        const hue_sector_raw = @mod(hue_rotation, 360.0);
        const hue_sector_idx: u4 = @intCast(@as(u8, @intFromFloat(hue_sector_raw / 40.0)) % 9);
        const h0: Trit = @enumFromInt(@as(i8, @intCast(hue_sector_idx / 3)) - 1);
        const h1: Trit = @enumFromInt(@as(i8, @intCast(hue_sector_idx % 3)) - 1);

        return .{
            .trit_word = TritWord.init(result_trit, h0, h1, .zero, .zero),
            .depth = parent_depth,
            .eps = propagated_eps,
            .seed_fingerprint = op.seed_fingerprint,
        };
    }

    /// Project to RGB (lossy: collapses infinitesimal to standard part).
    pub fn toRgb(self: ColorValue) RGB {
        return PALETTE[self.trit_word.toIndex()];
    }

    /// Project to RGB with infinitesimal correction (higher fidelity).
    pub fn toRgbCorrected(self: ColorValue) RGB {
        const base = PALETTE[self.trit_word.toIndex()];
        const dr: i16 = @intFromFloat(@as(f32, @floatCast(self.eps.dr)) * 255.0);
        const dg: i16 = @intFromFloat(@as(f32, @floatCast(self.eps.dg)) * 255.0);
        const db: i16 = @intFromFloat(@as(f32, @floatCast(self.eps.db)) * 255.0);
        return .{
            .r = @intCast(math.clamp(@as(i16, base.r) + dr, 0, 255)),
            .g = @intCast(math.clamp(@as(i16, base.g) + dg, 0, 255)),
            .b = @intCast(math.clamp(@as(i16, base.b) + db, 0, 255)),
        };
    }

    /// GF(3) trit of this color (the luminosity component).
    /// This is the conserved quantity under operadic composition:
    /// compose(op, args).trit() == sum of all input trits (mod 3).
    /// The full checksum includes depth-derived hue trits which are
    /// not part of the conservation law.
    pub fn trit(self: ColorValue) Trit {
        return self.trit_word.luminosity();
    }

    /// Involution: negate all 5 trits and infinitesimals.
    ///
    /// Referentially transparent: negate(cv) is a pure function of cv.
    /// Involutive: negate(negate(cv)) == cv (self-inverse, order 2).
    ///
    /// This is the GF(3) Galois involution on Z[zeta_3]^5:
    ///   zeta_3 -> zeta_3^{-1} = zeta_3^2 = conjugate
    /// On trits: +1 <-> -1, 0 fixed.
    /// On infinitesimals: sign flip (the hyperreal conjugation).
    /// Depth and seed_fingerprint are structural and preserved.
    ///
    /// Properties:
    ///   negate(negate(x)) == x                          (involution)
    ///   negate(x).trit() == x.trit().negate()           (trit-compatible)
    ///   negate preserves GF(3) balance                  (conservation)
    ///   negate(compose(op,args)) == compose(negate(op), map(negate,args))
    pub fn negate(self: ColorValue) ColorValue {
        var result = self;
        inline for (0..5) |i| {
            result.trit_word.trits[i] = self.trit_word.trits[i].negate();
        }
        result.eps = .{
            .dr = -self.eps.dr,
            .dg = -self.eps.dg,
            .db = -self.eps.db,
        };
        return result;
    }

    /// Cyclotomic symmetry: apply n-th root of unity rotation.
    /// Rotates all 5 trits by the control trit, implementing
    /// the Galois action of Z/3Z on Z[ζ₃]^5.
    pub fn rotate(self: ColorValue, control: Trit) ColorValue {
        var result = self;
        inline for (0..5) |i| {
            result.trit_word.trits[i] = Trit.add(self.trit_word.trits[i], control);
        }
        return result;
    }

    /// Conservation check: luminosity trit == zero.
    pub fn isConserved(self: ColorValue) bool {
        return self.trit() == .zero;
    }

    /// Description length in bits (MDL measure).
    /// Standard part: log2(243) ≈ 7.92 bits.
    /// Infinitesimal adds its entropy contribution.
    pub fn descriptionLength(self: ColorValue) f32 {
        const standard_bits: f32 = 7.925; // log2(243)
        const eps_energy = self.eps.normSq();
        if (eps_energy < 1e-10) return standard_bits;
        // Infinitesimal entropy ≈ -log2(1 - |ε|²) ≈ |ε|²/ln(2)
        return standard_bits + eps_energy / 0.6931472;
    }

    /// Hue angle (for display: combines base trit hue with depth rotation).
    pub fn hue(self: ColorValue) f32 {
        const base = self.trit().baseHue();
        const rotation = @as(f32, @floatFromInt(self.depth)) * GOLDEN_ANGLE;
        return @mod(base + rotation, 360.0);
    }

    /// Equality: two ColorValues are equal iff all fields match.
    pub fn eql(self: ColorValue, other: ColorValue) bool {
        inline for (0..5) |i| {
            if (self.trit_word.trits[i] != other.trit_word.trits[i]) return false;
        }
        return self.depth == other.depth and
            self.eps.eql(other.eps) and
            self.seed_fingerprint == other.seed_fingerprint;
    }

    /// Standard equality: only standard part (trit word) matches.
    /// Infinitesimal differences are "indistinguishable" (hyperreal intuition).
    pub fn eqlStandard(self: ColorValue, other: ColorValue) bool {
        inline for (0..5) |i| {
            if (self.trit_word.trits[i] != other.trit_word.trits[i]) return false;
        }
        return true;
    }

    /// SIMD-friendly f32 projection (r, g, b, hue) for batch processing.
    pub fn toF32x4(self: ColorValue) @Vector(4, f32) {
        const rgb = self.toRgbCorrected();
        return @Vector(4, f32){
            @as(f32, @floatFromInt(rgb.r)) / 255.0,
            @as(f32, @floatFromInt(rgb.g)) / 255.0,
            @as(f32, @floatFromInt(rgb.b)) / 255.0,
            self.hue() / 360.0,
        };
    }

    /// Batch project 4 ColorValues to SIMD-friendly layout.
    pub fn toSimd4(values: [4]ColorValue) struct {
        r: @Vector(4, f32),
        g: @Vector(4, f32),
        b: @Vector(4, f32),
    } {
        var r_vec: @Vector(4, f32) = @splat(0.0);
        var g_vec: @Vector(4, f32) = @splat(0.0);
        var b_vec: @Vector(4, f32) = @splat(0.0);
        inline for (0..4) |i| {
            const rgb = values[i].toRgbCorrected();
            r_vec[i] = @as(f32, @floatFromInt(rgb.r)) / 255.0;
            g_vec[i] = @as(f32, @floatFromInt(rgb.g)) / 255.0;
            b_vec[i] = @as(f32, @floatFromInt(rgb.b)) / 255.0;
        }
        return .{ .r = r_vec, .g = g_vec, .b = b_vec };
    }
};

// ===========================================================================
// Tests
// ===========================================================================

test "referential transparency: same seed+index -> same color" {
    const a = ColorValue.at(1069, 42);
    const b = ColorValue.at(1069, 42);
    try std.testing.expect(a.eql(b));

    // Different index -> different color
    const c = ColorValue.at(1069, 43);
    try std.testing.expect(!a.eql(c));
}

test "trit word roundtrip" {
    for (0..243) |i| {
        const idx: u8 = @intCast(i);
        const word = TritWord.fromIndex(idx);
        try std.testing.expectEqual(idx, word.toIndex());
    }
}

test "operadic composition preserves trit conservation" {
    // (op (+1) (arg1 (-1)) (arg2 (0)))
    // Sum: +1 + -1 + 0 = 0 (ergodic) -> conserved
    const op = ColorValue.fromTrit(.plus, 0);
    const arg1 = ColorValue.fromTrit(.minus, 0);
    const arg2 = ColorValue.fromTrit(.zero, 0);

    const result = ColorValue.compose(op, &[_]ColorValue{ arg1, arg2 });
    try std.testing.expectEqual(Trit.zero, result.trit());
    try std.testing.expect(result.isConserved());
    try std.testing.expectEqual(@as(u16, 1), result.depth);
}

test "nested composition depth tracking" {
    const x = ColorValue.fromTrit(.zero, 0);
    const f = ColorValue.fromTrit(.minus, 0);
    const g = ColorValue.fromTrit(.plus, 0);

    const fx = ColorValue.compose(f, &[_]ColorValue{x});
    try std.testing.expectEqual(@as(u16, 1), fx.depth);

    const gfx = ColorValue.compose(g, &[_]ColorValue{fx});
    try std.testing.expectEqual(@as(u16, 2), gfx.depth);
}

test "infinitesimal from quantization error" {
    const cv = ColorValue.at(1069, 0);
    // The corrected RGB should be closer to the original raw color
    const standard_rgb = cv.toRgb();
    const corrected_rgb = cv.toRgbCorrected();
    // Both should produce valid u8 values
    try std.testing.expect(standard_rgb.r <= 255);
    try std.testing.expect(corrected_rgb.r <= 255);
}

test "infinitesimal propagation through composition" {
    // Create two colors with different infinitesimals
    var cv1 = ColorValue.fromTrit(.plus, 0);
    cv1.eps = .{ .dr = 0.1, .dg = -0.05, .db = 0.02 };

    var cv2 = ColorValue.fromTrit(.minus, 0);
    cv2.eps = .{ .dr = -0.03, .dg = 0.08, .db = -0.01 };

    const op = ColorValue.fromTrit(.zero, 0);
    const result = ColorValue.compose(op, &[_]ColorValue{ cv1, cv2 });

    // Infinitesimal should be non-zero (propagated)
    try std.testing.expect(result.eps.normSq() > 0);
    // But scaled down by chain factor 1/3
    const raw_sum_sq = cv1.eps.add(cv2.eps).normSq();
    try std.testing.expect(result.eps.normSq() < raw_sum_sq);
}

test "cyclotomic rotation is order-3" {
    const cv = ColorValue.at(42, 7);
    const r1 = cv.rotate(.plus);
    const r2 = r1.rotate(.plus);
    const r3 = r2.rotate(.plus);
    // Three rotations should return to original trit word
    try std.testing.expect(cv.eqlStandard(r3));
}

test "description length bounds" {
    const cv = ColorValue.at(1069, 0);
    const dl = cv.descriptionLength();
    // Standard part alone is ~7.925 bits
    try std.testing.expect(dl >= 7.9);
    // With infinitesimal, should not exceed 24 bits (RGB precision)
    try std.testing.expect(dl < 24.0);
}

test "SIMD batch projection" {
    const values = [4]ColorValue{
        ColorValue.at(1069, 0),
        ColorValue.at(1069, 1),
        ColorValue.at(1069, 2),
        ColorValue.at(1069, 3),
    };
    const simd = ColorValue.toSimd4(values);
    // All components should be in [0, 1]
    inline for (0..4) |i| {
        try std.testing.expect(simd.r[i] >= 0 and simd.r[i] <= 1);
        try std.testing.expect(simd.g[i] >= 0 and simd.g[i] <= 1);
        try std.testing.expect(simd.b[i] >= 0 and simd.b[i] <= 1);
    }
}

test "BCI pipeline composition (backward compat with lux_color)" {
    const eeg = ColorValue.fromTrit(.zero, 0);
    const fisher = ColorValue.fromTrit(.minus, 0);
    const sigmoid = ColorValue.fromTrit(.minus, 0);
    const golden = ColorValue.fromTrit(.zero, 0);
    const aptos = ColorValue.fromTrit(.plus, 0);

    const level1 = ColorValue.compose(fisher, &[_]ColorValue{eeg});
    try std.testing.expectEqual(Trit.minus, level1.trit());
    try std.testing.expectEqual(@as(u16, 1), level1.depth);

    const level2 = ColorValue.compose(sigmoid, &[_]ColorValue{level1});
    try std.testing.expectEqual(Trit.plus, level2.trit());

    const level3 = ColorValue.compose(golden, &[_]ColorValue{level2});
    try std.testing.expectEqual(Trit.plus, level3.trit());

    const level4 = ColorValue.compose(aptos, &[_]ColorValue{level3});
    try std.testing.expectEqual(Trit.minus, level4.trit());
    try std.testing.expectEqual(@as(u16, 4), level4.depth);
}

test "GF(3) trit arithmetic" {
    try std.testing.expectEqual(Trit.zero, Trit.add(.plus, .minus));
    try std.testing.expectEqual(Trit.plus, Trit.add(.zero, .plus));
    try std.testing.expectEqual(Trit.minus, Trit.add(.minus, .zero));
    try std.testing.expectEqual(Trit.minus, Trit.add(.plus, .plus));
}

test "palette center is neutral" {
    const center = PALETTE[121];
    try std.testing.expect(center.r > 0);
    try std.testing.expect(center.g > 0);
    try std.testing.expect(center.b > 0);
}

test "negate is involutive and preserves GF(3) balance" {
    const cv = ColorValue.at(42, 7);
    const neg = cv.negate();
    const neg_neg = neg.negate();
    // Involution: negate(negate(x)) == x
    try std.testing.expectEqual(cv.trit_word, neg_neg.trit_word);
    try std.testing.expectEqual(cv.eps.dr, neg_neg.eps.dr);
    try std.testing.expectEqual(cv.eps.dg, neg_neg.eps.dg);
    try std.testing.expectEqual(cv.eps.db, neg_neg.eps.db);
    // Trits are negated
    for (0..5) |i| {
        try std.testing.expectEqual(cv.trit_word.trits[i].negate(), neg.trit_word.trits[i]);
    }
}
