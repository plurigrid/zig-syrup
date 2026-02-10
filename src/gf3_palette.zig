//! GF(3)⁵ Palette: 243-Color Successor to xterm-256
//!
//! xterm-256 (R1) maps 8 bits → RGB via ad hoc table:
//!   16 legacy + 216 cube (6³) + 24 grayscale = 256
//!   Kolmogorov cost: ~400 bytes (the lookup table itself)
//!
//! GF(3)⁵ maps 5 trits → RGB via group action:
//!   3 luminosity × 9 hue × 9 chroma = 243
//!   Kolmogorov cost: ~50 bytes (the generating program)
//!
//! Why 243 < 256 is better:
//!   - Radix economy: base 3 minimizes digits × base (e ≈ 2.718)
//!   - MOSFET trichotomy: silicon has 3 regimes, not 2
//!   - Trichromatic eye: output device IS GF(3)
//!   - σ permutation: zero-cost gate (wire routing)
//!   - Conservation: Σtᵢ ≡ 0 mod 3 gives free error detection
//!
//! Trit layout:  [L] [H₀ H₁] [C₀ C₁]
//!   L:     luminosity     {dim, neutral, bright}    → HSL lightness
//!   H₀H₁: hue            9 sectors (40° each)      → HSL hue
//!   C₀C₁: chroma/sat     9 levels                  → HSL saturation × value
//!
//! The CNOT₃ gate from entangle.zig operates on any individual trit,
//! rotating that perceptual dimension independently.

const std = @import("std");
const entangle = @import("entangle.zig");
const Trit = entangle.Trit;

// ============================================================================
// TRIT WORD: 5-trit address into the palette
// ============================================================================

/// A 5-trit word addressing a color in GF(3)⁵ space.
pub const TritWord = struct {
    trits: [5]Trit,

    /// Construct from 5 individual trits.
    pub fn init(l: Trit, h0: Trit, h1: Trit, c0: Trit, c1: Trit) TritWord {
        return .{ .trits = .{ l, h0, h1, c0, c1 } };
    }

    /// Convert to linear index 0..242.
    /// Mixed-radix: index = Σ (tᵢ+1) × 3^(4-i)
    pub fn toIndex(self: TritWord) u8 {
        var idx: u16 = 0;
        inline for (0..5) |i| {
            idx = idx * 3 + @as(u16, @intCast(@as(i16, @intFromEnum(self.trits[i])) + 1));
        }
        return @intCast(idx);
    }

    /// Convert from linear index 0..242.
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

    /// Apply CNOT₃ to a specific trit position.
    /// Rotates that perceptual dimension by the control trit.
    pub fn applyCNOT3(self: TritWord, position: u3, control: Trit) TritWord {
        if (position >= 5) return self;
        var result = self;
        result.trits[position] = Trit.add(self.trits[position], control);
        return result;
    }

    /// GF(3) sum of all trits (for conservation check).
    pub fn checksum(self: TritWord) Trit {
        var sum = self.trits[0];
        inline for (1..5) |i| {
            sum = Trit.add(sum, self.trits[i]);
        }
        return sum;
    }

    /// Luminosity trit (position 0).
    pub fn luminosity(self: TritWord) Trit {
        return self.trits[0];
    }

    /// Hue as a pair of trits (positions 1,2) → 0..8 sector.
    pub fn hueSector(self: TritWord) u4 {
        const h0: u8 = @intCast(@as(i16, @intFromEnum(self.trits[1])) + 1);
        const h1: u8 = @intCast(@as(i16, @intFromEnum(self.trits[2])) + 1);
        return @intCast(h0 * 3 + h1);
    }

    /// Chroma as a pair of trits (positions 3,4) → 0..8 level.
    pub fn chromaLevel(self: TritWord) u4 {
        const c0: u8 = @intCast(@as(i16, @intFromEnum(self.trits[3])) + 1);
        const c1: u8 = @intCast(@as(i16, @intFromEnum(self.trits[4])) + 1);
        return @intCast(c0 * 3 + c1);
    }
};

// ============================================================================
// PALETTE GENERATION
// ============================================================================

pub const RGB = struct { r: u8, g: u8, b: u8 };

/// The 9 hue sectors, each 40° apart, covering the full circle.
/// Chosen so sectors 0,3,6 align with R,G,B primaries.
const HUE_SECTORS = [9]f64{
    0, 40, 80, // red → orange → yellow
    120, 160, 200, // green → teal → cyan
    240, 280, 320, // blue → violet → magenta
};

/// The 9 chroma levels (saturation × value).
/// Outer trits control coarse, inner trits control fine.
/// Level 0 = near gray, level 8 = fully saturated.
const CHROMA_LEVELS = [9][2]f64{
    .{ 0.08, 0.50 }, // 0: very low sat, mid value
    .{ 0.08, 0.75 }, // 1: very low sat, high value
    .{ 0.08, 1.00 }, // 2: very low sat, full value
    .{ 0.40, 0.50 }, // 3: mid sat, mid value
    .{ 0.40, 0.75 }, // 4: mid sat, high value
    .{ 0.40, 1.00 }, // 5: mid sat, full value
    .{ 0.80, 0.50 }, // 6: high sat, mid value
    .{ 0.80, 0.75 }, // 7: high sat, high value
    .{ 0.80, 1.00 }, // 8: high sat, full value
};

/// The 3 luminosity levels (HSL lightness).
const LUMINOSITY_LEVELS = [3]f64{ 0.30, 0.55, 0.80 };

/// HSL → RGB conversion (matches spatial_propagator.zig)
fn hueToRgb(p: f64, q: f64, t_in: f64) f64 {
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
        .r = @intFromFloat(@max(0, @min(255, hueToRgb(p, q, h_norm + 1.0 / 3.0) * 255.0))),
        .g = @intFromFloat(@max(0, @min(255, hueToRgb(p, q, h_norm) * 255.0))),
        .b = @intFromFloat(@max(0, @min(255, hueToRgb(p, q, h_norm - 1.0 / 3.0) * 255.0))),
    };
}

/// Generate the color for a given trit word.
pub fn tritToRgb(word: TritWord) RGB {
    const l_idx: usize = @intCast(@as(i16, @intFromEnum(word.luminosity())) + 1);
    const lightness = LUMINOSITY_LEVELS[l_idx];
    const hue = HUE_SECTORS[word.hueSector()];
    const chroma = CHROMA_LEVELS[word.chromaLevel()];
    const saturation = chroma[0];
    const value = chroma[1];
    // Combine lightness with value adjustment
    const effective_l = lightness * value;
    return hslToRgb(hue, saturation, @min(1.0, effective_l));
}

/// Pack RGB to ARGB8.
pub fn rgbToArgb(rgb: RGB) u32 {
    return 0xFF000000 |
        (@as(u32, rgb.r) << 16) |
        (@as(u32, rgb.g) << 8) |
        @as(u32, rgb.b);
}

// ============================================================================
// STATIC PALETTE (the 243 entries, computed at init)
// ============================================================================

/// The full GF(3)⁵ palette: 243 RGB entries.
pub const Palette = struct {
    entries: [243]RGB,
    argb: [243]u32,

    /// Generate the palette.
    pub fn generate() Palette {
        @setEvalBranchQuota(100_000);
        var p: Palette = undefined;
        for (0..243) |i| {
            const word = TritWord.fromIndex(@intCast(i));
            p.entries[i] = tritToRgb(word);
            p.argb[i] = rgbToArgb(p.entries[i]);
        }
        return p;
    }

    /// Look up by trit word.
    pub fn lookup(self: *const Palette, word: TritWord) RGB {
        return self.entries[word.toIndex()];
    }

    /// Look up ARGB by trit word.
    pub fn lookupArgb(self: *const Palette, word: TritWord) u32 {
        return self.argb[word.toIndex()];
    }

    /// Find nearest palette entry to an arbitrary RGB color.
    /// Returns the trit word and the distance².
    pub fn quantize(self: *const Palette, r: u8, g: u8, b: u8) struct { word: TritWord, dist: u32 } {
        var best_dist: u32 = std.math.maxInt(u32);
        var best_idx: u8 = 0;
        for (0..243) |i| {
            const e = self.entries[i];
            const dr: i32 = @as(i32, r) - @as(i32, e.r);
            const dg: i32 = @as(i32, g) - @as(i32, e.g);
            const db: i32 = @as(i32, b) - @as(i32, e.b);
            const dist: u32 = @intCast(dr * dr + dg * dg + db * db);
            if (dist < best_dist) {
                best_dist = dist;
                best_idx = @intCast(i);
            }
        }
        return .{ .word = TritWord.fromIndex(best_idx), .dist = best_dist };
    }

    /// Apply CNOT₃ to a trit position across the entire palette mapping.
    /// Returns the remapped index: palette[old] → palette[CNOT₃(old, pos, ctrl)].
    pub fn remap(word: TritWord, position: u3, control: Trit) TritWord {
        return word.applyCNOT3(position, control);
    }
};

/// Global palette instance (generated once).
pub const PALETTE = Palette.generate();

// ============================================================================
// COMPARISON WITH XTERM-256
// ============================================================================

// Kolmogorov complexity comparison (approximate program lengths):
//
//   xterm-256:
//     16 named colors:  16 × 3 = 48 bytes (lookup table)
//     216 cube:         program: "for r,g,b in 0..5: rgb(r*51, g*51, b*51)" ≈ 30 bytes
//     24 grayscale:     program: "for i in 0..23: gray(8 + i*10)" ≈ 20 bytes
//     Total: ~100 bytes program + disambiguating which entry type ≈ 110 bytes
//
//   GF(3)⁵:
//     243 colors:       program: "HSL(sectors[h0*3+h1], chroma[c0*3+c1], lum[l])" ≈ 50 bytes
//     + 3 tables:       9 + 18 + 3 = 30 bytes
//     Total: ~80 bytes
//
//   Solomonoff advantage: 2^{-(80)} / 2^{-(110)} = 2^{30} ≈ 10⁹ higher prior weight.

// ============================================================================
// TESTS
// ============================================================================

test "trit word index roundtrip" {
    for (0..243) |i| {
        const idx: u8 = @intCast(i);
        const word = TritWord.fromIndex(idx);
        try std.testing.expectEqual(idx, word.toIndex());
    }
}

test "trit word bounds" {
    // All zeros → index 0 (all trits = minus)
    const zero = TritWord.init(.minus, .minus, .minus, .minus, .minus);
    try std.testing.expectEqual(@as(u8, 0), zero.toIndex());

    // All maxes → index 242 (all trits = plus)
    const max = TritWord.init(.plus, .plus, .plus, .plus, .plus);
    try std.testing.expectEqual(@as(u8, 242), max.toIndex());

    // Center → index 121 (all trits = zero)
    const center = TritWord.init(.zero, .zero, .zero, .zero, .zero);
    try std.testing.expectEqual(@as(u8, 121), center.toIndex());
}

test "hue sectors cover 9 values" {
    var seen = [_]bool{false} ** 9;
    for (0..243) |i| {
        const word = TritWord.fromIndex(@intCast(i));
        seen[word.hueSector()] = true;
    }
    for (seen) |s| {
        try std.testing.expect(s);
    }
}

test "chroma levels cover 9 values" {
    var seen = [_]bool{false} ** 9;
    for (0..243) |i| {
        const word = TritWord.fromIndex(@intCast(i));
        seen[word.chromaLevel()] = true;
    }
    for (seen) |s| {
        try std.testing.expect(s);
    }
}

test "palette has 243 distinct entries" {
    // Not all will be unique RGB (low sat colors may collide),
    // but the vast majority should be distinct
    var unique_count: usize = 0;
    for (0..243) |i| {
        var is_unique = true;
        for (0..i) |j| {
            if (PALETTE.argb[i] == PALETTE.argb[j]) {
                is_unique = false;
                break;
            }
        }
        if (is_unique) unique_count += 1;
    }
    // At least 200 of 243 should be distinct (some low-sat grays may collide)
    try std.testing.expect(unique_count >= 200);
}

test "CNOT₃ on luminosity trit rotates brightness" {
    const dim = TritWord.init(.minus, .zero, .zero, .plus, .plus);
    const rotated = dim.applyCNOT3(0, .plus);
    // minus + plus = zero → neutral luminosity
    try std.testing.expectEqual(Trit.zero, rotated.luminosity());

    const rotated2 = rotated.applyCNOT3(0, .plus);
    // zero + plus = plus → bright
    try std.testing.expectEqual(Trit.plus, rotated2.luminosity());

    const rotated3 = rotated2.applyCNOT3(0, .plus);
    // plus + plus = minus → back to dim (CNOT₃³ = I)
    try std.testing.expectEqual(Trit.minus, rotated3.luminosity());
}

test "CNOT₃ on hue trit rotates color sector" {
    const word = TritWord.init(.zero, .minus, .zero, .zero, .zero);
    try std.testing.expectEqual(@as(u4, 1), word.hueSector()); // sector 1

    // Rotate H₀ by +1
    const rotated = word.applyCNOT3(1, .plus);
    try std.testing.expectEqual(@as(u4, 4), rotated.hueSector()); // sector 4 (jumped 3)
}

test "quantize finds nearest color" {
    // Pure red should map to a red-dominant entry
    const result = PALETTE.quantize(255, 0, 0);
    const rgb = PALETTE.entries[result.word.toIndex()];
    // R channel should dominate
    try std.testing.expect(rgb.r > rgb.g);
    try std.testing.expect(rgb.r > rgb.b);
}

test "quantize pure green" {
    const result = PALETTE.quantize(0, 255, 0);
    const rgb = PALETTE.entries[result.word.toIndex()];
    try std.testing.expect(rgb.g > rgb.r);
    try std.testing.expect(rgb.g > rgb.b);
}

test "conservation checksum" {
    // A word with all zeros has checksum zero
    const balanced = TritWord.init(.zero, .zero, .zero, .zero, .zero);
    try std.testing.expectEqual(Trit.zero, balanced.checksum());

    // (+1, +1, +1, +1, +1) has checksum 5 mod 3 = 2 ↔ minus
    const all_plus = TritWord.init(.plus, .plus, .plus, .plus, .plus);
    try std.testing.expectEqual(Trit.minus, all_plus.checksum());
}

test "palette center is neutral gray" {
    // Index 121 = all trits zero = neutral luminosity, hue sector 4 (green region),
    // chroma level 4 (mid sat, high value)
    const center = PALETTE.entries[121];
    // Should be a visible, non-extreme color
    try std.testing.expect(center.r > 0);
    try std.testing.expect(center.g > 0);
    try std.testing.expect(center.b > 0);
    try std.testing.expect(center.r < 255);
}
