//! Spectrum — GF(3) Triadic Color Bridge
//!
//! Closes the read→write loop between zig-syrup's disconnected color systems.
//! Maps triadic classifications (balanced ternary triples from prigogine,
//! spectral_tensor, continuation, czernowitz) to perceptually meaningful
//! colors in HCL/RGB space.
//!
//! The core mapping:
//!   3 trits ∈ {-1, 0, +1}³ → 27 states → points in HCL color space
//!   - Hue: determined by trit₁ via plastic angle (205.14°), the GF(3) spiral
//!   - Chroma: determined by trit₂ (minus=muted, zero=moderate, plus=vivid)
//!   - Lightness: determined by trit₃ (minus=dark, zero=mid, plus=light)
//!
//! The plastic angle is the natural choice because ρ³ = ρ + 1 (the plastic
//! constant satisfies a cubic, matching GF(3)'s ternary structure).
//!
//! Balance constraint: regime + pattern + temporal ≡ 0 (mod 3) means only
//! 9 of 27 states are reachable — these 9 form a coset in (ℤ/3ℤ)³,
//! and the plastic angle ensures maximal perceptual separation among them.
//!
//! References:
//! - rainbow.zig: HCL↔RGB conversion, plastic/golden spirals
//! - prigogine.zig: DissipativeRegime × PatternType × TemporalType
//! - spectral_tensor.zig: integration × differentiation × binding
//! - continuation.zig: Trit enum with GF(3) arithmetic
//! - fem.zig: CIE 1931 spectral → XYZ → Display P3

const std = @import("std");
const math = std.math;

// Relative imports from the same source tree
const rainbow = @import("rainbow.zig");
const RGB = rainbow.RGB;
const HCL = rainbow.HCL;

// ============================================================================
// TRIT → COLOR MAPPING
// ============================================================================

/// Clamp a raw i8 to valid trit range {-1, 0, 1}
fn clampTrit(v: i8) i8 {
    if (v < -1) return -1;
    if (v > 1) return 1;
    return v;
}

/// A balanced ternary triple (3 trits), the universal classification unit
pub const TriadicColor = struct {
    /// First trit: mapped to hue (plastic angle rotation)
    t1: i8,
    /// Second trit: mapped to chroma (color saturation)
    t2: i8,
    /// Third trit: mapped to lightness
    t3: i8,

    /// Construct with clamping — any i8 values are clamped to {-1, 0, 1}
    pub fn init(t1: i8, t2: i8, t3: i8) TriadicColor {
        return .{
            .t1 = clampTrit(t1),
            .t2 = clampTrit(t2),
            .t3 = clampTrit(t3),
        };
    }

    /// Construct with balance enforcement — sets t3 to satisfy GF(3) conservation
    pub fn initBalanced(t1: i8, t2: i8) TriadicColor {
        const ct1 = clampTrit(t1);
        const ct2 = clampTrit(t2);
        const partial = @mod(ct1 + ct2 + 9, 3);
        const ct3: i8 = switch (partial) {
            0 => 0,
            1 => -1,
            2 => 1,
            else => unreachable,
        };
        return .{ .t1 = ct1, .t2 = ct2, .t3 = ct3 };
    }

    /// GF(3) balance check: sum ≡ 0 (mod 3)
    pub fn isBalanced(self: TriadicColor) bool {
        const sum = @mod(self.t1 + self.t2 + self.t3 + 9, 3);
        return sum == 0;
    }

    /// GF(3) negation: negate each trit
    pub fn negate(self: TriadicColor) TriadicColor {
        return .{ .t1 = -self.t1, .t2 = -self.t2, .t3 = -self.t3 };
    }

    /// GF(3) addition: add corresponding trits mod 3
    pub fn add(self: TriadicColor, other: TriadicColor) TriadicColor {
        return .{
            .t1 = gf3Add(self.t1, other.t1),
            .t2 = gf3Add(self.t2, other.t2),
            .t3 = gf3Add(self.t3, other.t3),
        };
    }

    /// GF(3) component-wise multiplication
    pub fn mul(self: TriadicColor, other: TriadicColor) TriadicColor {
        return .{
            .t1 = gf3Mul(self.t1, other.t1),
            .t2 = gf3Mul(self.t2, other.t2),
            .t3 = gf3Mul(self.t3, other.t3),
        };
    }

    /// Dot product in GF(3): sum of component-wise products
    pub fn dot(self: TriadicColor, other: TriadicColor) i8 {
        const prod = self.mul(other);
        return gf3Add(gf3Add(prod.t1, prod.t2), prod.t3);
    }

    /// Hamming distance: count of differing trits
    pub fn hammingDistance(self: TriadicColor, other: TriadicColor) u8 {
        var d: u8 = 0;
        if (self.t1 != other.t1) d += 1;
        if (self.t2 != other.t2) d += 1;
        if (self.t3 != other.t3) d += 1;
        return d;
    }

    /// Lee distance: sum of |a_i - b_i| mod 3, natural metric on Z/3Z
    pub fn leeDistance(self: TriadicColor, other: TriadicColor) u8 {
        return leeDist1(self.t1, other.t1) + leeDist1(self.t2, other.t2) + leeDist1(self.t3, other.t3);
    }

    /// Encode as a single integer in [0, 26] (ternary → decimal)
    pub fn encode(self: TriadicColor) u8 {
        const a: u8 = @intCast(self.t1 + 1);
        const b: u8 = @intCast(self.t2 + 1);
        const c: u8 = @intCast(self.t3 + 1);
        return a * 9 + b * 3 + c;
    }

    /// Decode from integer in [0, 26]
    pub fn decode(code: u8) ?TriadicColor {
        if (code > 26) return null;
        return .{
            .t1 = @as(i8, @intCast(code / 9)) - 1,
            .t2 = @as(i8, @intCast((code % 9) / 3)) - 1,
            .t3 = @as(i8, @intCast(code % 3)) - 1,
        };
    }

    /// Map to HCL color space
    /// The plastic angle (205.14°) rotates hue for GF(3) structure
    pub fn toHCL(self: TriadicColor) HCL {
        // Clamp to valid trit range for safety
        const ct1 = clampTrit(self.t1);
        const ct2 = clampTrit(self.t2);
        const ct3 = clampTrit(self.t3);

        // Hue: base + trit₁ × plastic_angle
        // minus(-1) → 0°, zero(0) → 205.14°, plus(1) → 410.28° ≡ 50.28°
        // This places the 3 hue anchors at roughly red, blue, yellow-green
        const base_hue: f64 = 30.0; // warm red anchor for minus
        const hue = @mod(base_hue + @as(f64, @floatFromInt(ct1 + 1)) * rainbow.PLASTIC_ANGLE, 360.0);

        // Chroma: [0, ~1.3] in HCL. Use well-spaced values within gamut
        // minus=0.25 (muted), zero=0.55 (moderate), plus=0.90 (vivid)
        const chroma: f64 = switch (ct2) {
            -1 => 0.25,
            0 => 0.55,
            1 => 0.90,
            else => 0.55,
        };

        // Lightness: [0, 1] in HCL
        // minus=0.30 (dark), zero=0.55 (mid), plus=0.80 (light)
        const lightness: f64 = switch (ct3) {
            -1 => 0.30,
            0 => 0.55,
            1 => 0.80,
            else => 0.55,
        };

        return .{ .h = hue, .c = chroma, .l = lightness };
    }

    /// Map to RGB via HCL
    pub fn toRGB(self: TriadicColor) RGB {
        return self.toHCL().toRGB();
    }

    /// ANSI 24-bit foreground escape sequence for terminal rendering
    pub fn ansiFg(self: TriadicColor, buf: *[24]u8) []const u8 {
        const rgb = self.toRGB();
        const result = std.fmt.bufPrint(buf, "\x1b[38;2;{};{};{}m", .{ rgb.r, rgb.g, rgb.b }) catch return "";
        return result;
    }

    /// ANSI 24-bit background escape sequence
    pub fn ansiBg(self: TriadicColor, buf: *[24]u8) []const u8 {
        const rgb = self.toRGB();
        const result = std.fmt.bufPrint(buf, "\x1b[48;2;{};{};{}m", .{ rgb.r, rgb.g, rgb.b }) catch return "";
        return result;
    }

    /// Interpolate between two triadic colors at parameter t ∈ [0,1]
    /// Uses RGB lerp for smooth gradients between trit-quantized endpoints
    pub fn lerp(a: TriadicColor, b: TriadicColor, t: f64) RGB {
        const ct = @max(0.0, @min(1.0, t));
        return RGB.lerp(a.toRGB(), b.toRGB(), ct);
    }

    /// Construct from Prigogine classification (clamped)
    pub fn fromPrigogine(regime: i8, pattern: i8, temporal: i8) TriadicColor {
        return init(regime, pattern, temporal);
    }

    /// Construct from spectral tensor classification (clamped)
    pub fn fromSpectralTensor(integration: i8, differentiation: i8, binding: i8) TriadicColor {
        return init(integration, differentiation, binding);
    }

    /// Construct from a homotopy path parameter t ∈ [0,1]
    /// Maps the continuous path to a discrete trit triple:
    ///   t ∈ [0, 1/3) → minus, [1/3, 2/3) → zero, [2/3, 1] → plus
    /// Each digit of the ternary expansion gives one trit
    /// NaN and Inf are clamped to [0,1] boundaries
    pub fn fromPathParameter(t: f64) TriadicColor {
        // Handle NaN → 0, Inf → 1, -Inf → 0
        const safe = if (math.isNan(t)) 0.0 else t;
        const clamped = @max(0.0, @min(1.0, safe));
        // Ternary expansion: 3 digits of precision
        const v = clamped * 27.0; // [0, 27]
        const i: u8 = @intFromFloat(@min(26.0, v));
        const d0: i8 = @as(i8, @intCast(i / 9)) - 1; // first ternary digit → [-1,0,1]
        const d1: i8 = @as(i8, @intCast((i % 9) / 3)) - 1;
        const d2: i8 = @as(i8, @intCast(i % 3)) - 1;
        return .{ .t1 = d0, .t2 = d1, .t3 = d2 };
    }

    /// Construct from FEM spectral wavelength (380-780nm visible range)
    /// Maps physical wavelength to perceptual trit triple:
    ///   t1 (hue region): violet/blue(-1), green(0), orange/red(+1)
    ///   t2 (saturation): monochromatic lines are vivid(+1)
    ///   t3 (brightness): follows luminous efficiency V(λ)
    /// Out-of-range wavelengths and NaN are handled gracefully
    pub fn fromWavelength(lambda_nm: f64) TriadicColor {
        // Handle NaN/Inf
        if (math.isNan(lambda_nm) or math.isInf(lambda_nm)) {
            return .{ .t1 = 0, .t2 = 0, .t3 = 0 }; // achromatic fallback
        }

        // Hue region by wavelength
        const t1: i8 = if (lambda_nm < 500.0)
            -1 // violet-blue
        else if (lambda_nm < 580.0)
            0 // green-yellow
        else
            1; // orange-red

        // Monochromatic light is maximally saturated
        const t2: i8 = 1;

        // Luminous efficiency peaks at 555nm (photopic)
        const peak = 555.0;
        const spread = 100.0;
        const diff = (lambda_nm - peak) / spread;
        const efficiency = @exp(-0.5 * diff * diff);
        const t3: i8 = if (efficiency > 0.66)
            1 // bright (near peak)
        else if (efficiency > 0.33)
            0 // moderate
        else
            -1; // dim (violet/deep red ends)

        return .{ .t1 = t1, .t2 = t2, .t3 = t3 };
    }

    /// Equality check
    pub fn eql(self: TriadicColor, other: TriadicColor) bool {
        return self.t1 == other.t1 and self.t2 == other.t2 and self.t3 == other.t3;
    }
};

// ============================================================================
// GF(3) ARITHMETIC HELPERS
// ============================================================================

/// GF(3) addition: (a + b) mod 3, result in {-1, 0, 1}
fn gf3Add(a: i8, b: i8) i8 {
    return switch (@mod(a + b + 9, 3)) {
        0 => 0,
        1 => 1,
        2 => -1,
        else => unreachable,
    };
}

/// GF(3) multiplication: (a * b) mod 3, result in {-1, 0, 1}
fn gf3Mul(a: i8, b: i8) i8 {
    // In {-1, 0, 1} representation: just multiply and reduce
    const prod = @as(i8, a) * @as(i8, b);
    return switch (@mod(prod + 9, 3)) {
        0 => 0,
        1 => 1,
        2 => -1,
        else => unreachable,
    };
}

/// Lee distance for a single trit pair: min(|a-b|, 3-|a-b|) in Z/3Z
fn leeDist1(a: i8, b: i8) u8 {
    const d: u8 = @intCast(if (a - b < 0) b - a else a - b);
    return @min(d, 3 - d);
}

// ============================================================================
// THE 9 BALANCED STATES
// ============================================================================

/// The 9 balanced triadic states (sum ≡ 0 mod 3)
/// These are the only physically meaningful states under GF(3) conservation
pub const balanced_states: [9]TriadicColor = blk: {
    var states: [9]TriadicColor = undefined;
    var idx: usize = 0;
    for ([_]i8{ -1, 0, 1 }) |t1| {
        for ([_]i8{ -1, 0, 1 }) |t2| {
            // t3 is determined by balance: t1 + t2 + t3 ≡ 0 (mod 3)
            const partial = @mod(t1 + t2 + 9, 3);
            const t3: i8 = switch (partial) {
                0 => 0,
                1 => -1,
                2 => 1,
                else => unreachable,
            };
            states[idx] = .{ .t1 = t1, .t2 = t2, .t3 = t3 };
            idx += 1;
        }
    }
    break :blk states;
};

/// Get the balanced palette as RGB colors (runtime, because HCL→RGB uses math.pow)
pub fn balancedPalette() [9]RGB {
    var colors: [9]RGB = undefined;
    for (balanced_states, 0..) |state, i| {
        colors[i] = state.toRGB();
    }
    return colors;
}

// ============================================================================
// RENDERING HELPERS
// ============================================================================

/// Render a colored block character for terminal display
pub fn renderBlock(writer: anytype, tc: TriadicColor) !void {
    const rgb = tc.toRGB();
    try writer.print("\x1b[48;2;{};{};{}m  \x1b[0m", .{ rgb.r, rgb.g, rgb.b });
}

/// Render the full 3×3 balanced palette grid
pub fn renderPalette(writer: anytype) !void {
    try writer.writeAll("GF(3) Balanced Triadic Palette\n");
    try writer.writeAll("      t2=-1    t2=0    t2=+1\n");
    const labels = [_][]const u8{ "t1=-1", "t1= 0", "t1=+1" };
    for (0..3) |row| {
        try writer.print("{s}  ", .{labels[row]});
        for (0..3) |col| {
            const state = balanced_states[row * 3 + col];
            try renderBlock(writer, state);
            try writer.writeAll(" ");
        }
        try writer.writeAll("\n");
    }
}

/// Render a single classification as a colored trit string: [±0±]
pub fn renderTrit(writer: anytype, tc: TriadicColor) !void {
    const rgb = tc.toRGB();
    const chars = [3]u8{
        if (tc.t1 < 0) '-' else if (tc.t1 > 0) '+' else '0',
        if (tc.t2 < 0) '-' else if (tc.t2 > 0) '+' else '0',
        if (tc.t3 < 0) '-' else if (tc.t3 > 0) '+' else '0',
    };
    try writer.print("\x1b[38;2;{};{};{}m[{c}{c}{c}]\x1b[0m", .{
        rgb.r, rgb.g, rgb.b,
        chars[0], chars[1], chars[2],
    });
}

// ============================================================================
// PERSISTENCE DIAGRAM COLORING
// ============================================================================

/// Color a persistence pair (birth, death) by its topological significance
/// Maps the persistence = death - birth to a triadic color:
///   Short-lived features (noise) → minus (dark, muted)
///   Medium persistence → zero (moderate)
///   Long-lived features (signal) → plus (bright, vivid)
pub fn persistenceColor(birth: f64, death: f64, max_persistence: f64) TriadicColor {
    // Guard: NaN, Inf, or degenerate inputs → neutral color
    if (math.isNan(birth) or math.isNan(death) or math.isNan(max_persistence) or
        math.isInf(birth) or math.isInf(death) or math.isInf(max_persistence))
    {
        return TriadicColor.initBalanced(0, 0);
    }

    const persistence = @max(0.0, death - birth); // clamp negative persistence
    const safe_max = @max(persistence, max_persistence); // avoid div-by-zero, ensure max >= persistence
    const normalized = if (safe_max > 0) persistence / safe_max else 0;

    // t1: persistence magnitude → hue
    const t1: i8 = if (normalized < 0.33) -1 else if (normalized < 0.66) 0 else 1;

    // t2: birth time → saturation (early births = more saturated)
    const birth_norm = if (safe_max > 0) @max(0.0, birth) / safe_max else 0;
    const t2: i8 = if (birth_norm < 0.33) 1 else if (birth_norm < 0.66) 0 else -1;

    // t3: balance — enforced via initBalanced-style calculation
    return TriadicColor.initBalanced(t1, t2);
}

// ============================================================================
// SYRUP SERIALIZATION
// ============================================================================

const syrup = @import("syrup.zig");
const Allocator = std.mem.Allocator;

/// Serialize a TriadicColor to Syrup record
pub fn toSyrup(tc: TriadicColor, allocator: Allocator) !syrup.Value {
    const rgb = tc.toRGB();
    const label = try allocator.create(syrup.Value);
    label.* = .{ .symbol = "triadic-color" };
    const fields = try allocator.alloc(syrup.Value, 6);
    fields[0] = .{ .integer = tc.t1 };
    fields[1] = .{ .integer = tc.t2 };
    fields[2] = .{ .integer = tc.t3 };
    fields[3] = .{ .integer = rgb.r };
    fields[4] = .{ .integer = rgb.g };
    fields[5] = .{ .integer = rgb.b };
    return .{ .record = .{ .label = label, .fields = fields } };
}

/// Deserialize a TriadicColor from a Syrup record
/// Returns null if the value is not a well-formed triadic-color record
pub fn fromSyrup(val: syrup.Value) ?TriadicColor {
    const rec = switch (val) {
        .record => |r| r,
        else => return null,
    };
    // Check label
    const label_sym = switch (rec.label.*) {
        .symbol => |s| s,
        else => return null,
    };
    if (!std.mem.eql(u8, label_sym, "triadic-color")) return null;
    if (rec.fields.len < 3) return null;

    // Extract trits from first 3 fields
    const t1_i64 = switch (rec.fields[0]) {
        .integer => |i| i,
        else => return null,
    };
    const t2_i64 = switch (rec.fields[1]) {
        .integer => |i| i,
        else => return null,
    };
    const t3_i64 = switch (rec.fields[2]) {
        .integer => |i| i,
        else => return null,
    };

    // Validate range [-1, 1]
    if (t1_i64 < -1 or t1_i64 > 1) return null;
    if (t2_i64 < -1 or t2_i64 > 1) return null;
    if (t3_i64 < -1 or t3_i64 > 1) return null;

    return .{
        .t1 = @intCast(t1_i64),
        .t2 = @intCast(t2_i64),
        .t3 = @intCast(t3_i64),
    };
}

/// Serialize a full triadic classification with semantic labels
pub fn classificationToSyrup(tc: TriadicColor, name: []const u8, allocator: Allocator) !syrup.Value {
    const label = try allocator.create(syrup.Value);
    label.* = .{ .symbol = "triadic-classification" };
    const fields = try allocator.alloc(syrup.Value, 4);
    fields[0] = .{ .symbol = name };
    // Nested triadic-color record
    fields[1] = try toSyrup(tc, allocator);
    // Balance flag
    fields[2] = .{ .bool = tc.isBalanced() };
    // Encoded index
    fields[3] = .{ .integer = tc.encode() };
    return .{ .record = .{ .label = label, .fields = fields } };
}

// ============================================================================
// TESTS
// ============================================================================

// --- Balanced state tests ---

test "balanced states are all balanced" {
    for (balanced_states) |state| {
        try std.testing.expect(state.isBalanced());
    }
}

test "balanced states count is 9" {
    try std.testing.expectEqual(@as(usize, 9), balanced_states.len);
}

test "all 27 states enumerable, exactly 9 balanced" {
    var balanced_count: usize = 0;
    for (0..27) |code| {
        const tc = TriadicColor.decode(@intCast(code)).?;
        if (tc.isBalanced()) balanced_count += 1;
        // roundtrip encode/decode
        try std.testing.expectEqual(@as(u8, @intCast(code)), tc.encode());
    }
    try std.testing.expectEqual(@as(usize, 9), balanced_count);
}

test "decode out of range returns null" {
    try std.testing.expect(TriadicColor.decode(27) == null);
    try std.testing.expect(TriadicColor.decode(255) == null);
}

test "encode/decode roundtrip for all 27 states" {
    for (0..27) |code| {
        const tc = TriadicColor.decode(@intCast(code)).?;
        try std.testing.expectEqual(@as(u8, @intCast(code)), tc.encode());
    }
}

test "balanced palette has nonzero distance between all pairs" {
    const pal = balancedPalette();
    for (0..9) |i| {
        for (i + 1..9) |j| {
            const a = pal[i];
            const b = pal[j];
            const dr: i16 = @as(i16, a.r) - @as(i16, b.r);
            const dg: i16 = @as(i16, a.g) - @as(i16, b.g);
            const db: i16 = @as(i16, a.b) - @as(i16, b.b);
            const dist = (if (dr < 0) -dr else dr) + (if (dg < 0) -dg else dg) + (if (db < 0) -db else db);
            try std.testing.expect(dist > 0);
        }
    }
}

// --- GF(3) arithmetic tests ---

test "GF(3) addition table" {
    // 0 is identity
    try std.testing.expectEqual(@as(i8, 1), gf3Add(1, 0));
    try std.testing.expectEqual(@as(i8, -1), gf3Add(-1, 0));
    try std.testing.expectEqual(@as(i8, 0), gf3Add(0, 0));
    // Inverses
    try std.testing.expectEqual(@as(i8, 0), gf3Add(1, -1));
    try std.testing.expectEqual(@as(i8, 0), gf3Add(-1, 1));
    // Wrap-around: 1+1 = 2 ≡ -1 (mod 3)
    try std.testing.expectEqual(@as(i8, -1), gf3Add(1, 1));
    // -1 + -1 = -2 ≡ 1 (mod 3)
    try std.testing.expectEqual(@as(i8, 1), gf3Add(-1, -1));
}

test "GF(3) multiplication table" {
    // 0 annihilates
    try std.testing.expectEqual(@as(i8, 0), gf3Mul(1, 0));
    try std.testing.expectEqual(@as(i8, 0), gf3Mul(-1, 0));
    try std.testing.expectEqual(@as(i8, 0), gf3Mul(0, -1));
    // 1 is identity
    try std.testing.expectEqual(@as(i8, 1), gf3Mul(1, 1));
    try std.testing.expectEqual(@as(i8, -1), gf3Mul(1, -1));
    try std.testing.expectEqual(@as(i8, -1), gf3Mul(-1, 1));
    // -1 * -1 = 1
    try std.testing.expectEqual(@as(i8, 1), gf3Mul(-1, -1));
}

test "triadic color negate is involution" {
    for (0..27) |code| {
        const tc = TriadicColor.decode(@intCast(code)).?;
        const neg = tc.negate();
        const neg_neg = neg.negate();
        try std.testing.expect(tc.eql(neg_neg));
    }
}

test "triadic color add then negate is identity" {
    for (0..27) |code| {
        const tc = TriadicColor.decode(@intCast(code)).?;
        const sum = tc.add(tc.negate());
        try std.testing.expectEqual(@as(i8, 0), sum.t1);
        try std.testing.expectEqual(@as(i8, 0), sum.t2);
        try std.testing.expectEqual(@as(i8, 0), sum.t3);
    }
}

test "negation preserves balance" {
    for (balanced_states) |state| {
        try std.testing.expect(state.negate().isBalanced());
    }
}

test "addition of balanced states is balanced" {
    for (balanced_states) |a| {
        for (balanced_states) |b| {
            // Sum of balanced triples: (a1+b1) + (a2+b2) + (a3+b3) mod 3
            // = (a1+a2+a3) + (b1+b2+b3) mod 3 = 0+0 = 0 ✓
            try std.testing.expect(a.add(b).isBalanced());
        }
    }
}

test "hamming and lee distance properties" {
    const zero = TriadicColor{ .t1 = 0, .t2 = 0, .t3 = 0 };
    const one = TriadicColor{ .t1 = 1, .t2 = 1, .t3 = 1 };
    const minus = TriadicColor{ .t1 = -1, .t2 = -1, .t3 = -1 };

    // Self-distance is 0
    try std.testing.expectEqual(@as(u8, 0), zero.hammingDistance(zero));
    try std.testing.expectEqual(@as(u8, 0), zero.leeDistance(zero));

    // Max hamming distance is 3
    try std.testing.expectEqual(@as(u8, 3), zero.hammingDistance(one));

    // Lee distance: |1 - (-1)| = 2, but min(2, 3-2) = 1 in Z/3Z
    try std.testing.expectEqual(@as(u8, 3), one.leeDistance(minus));
}

test "dot product symmetry" {
    for (0..27) |i| {
        for (0..27) |j| {
            const a = TriadicColor.decode(@intCast(i)).?;
            const b = TriadicColor.decode(@intCast(j)).?;
            try std.testing.expectEqual(a.dot(b), b.dot(a));
        }
    }
}

// --- Clamping and init tests ---

test "init clamps out-of-range trits" {
    const tc = TriadicColor.init(5, -10, 127);
    try std.testing.expectEqual(@as(i8, 1), tc.t1);
    try std.testing.expectEqual(@as(i8, -1), tc.t2);
    try std.testing.expectEqual(@as(i8, 1), tc.t3);
}

test "initBalanced forces GF(3) conservation" {
    for ([_]i8{ -1, 0, 1 }) |t1| {
        for ([_]i8{ -1, 0, 1 }) |t2| {
            const tc = TriadicColor.initBalanced(t1, t2);
            try std.testing.expect(tc.isBalanced());
        }
    }
}

test "initBalanced clamps then balances" {
    const tc = TriadicColor.initBalanced(100, -100);
    try std.testing.expectEqual(@as(i8, 1), tc.t1);
    try std.testing.expectEqual(@as(i8, -1), tc.t2);
    try std.testing.expect(tc.isBalanced());
}

// --- HCL/RGB edge cases ---

test "all 27 states produce valid RGB" {
    for (0..27) |code| {
        const tc = TriadicColor.decode(@intCast(code)).?;
        const rgb = tc.toRGB();
        _ = rgb; // if it didn't panic, it's valid (u8 can't overflow)
        const hcl = tc.toHCL();
        try std.testing.expect(hcl.h >= 0.0 and hcl.h < 360.0);
        try std.testing.expect(hcl.c >= 0.0);
        try std.testing.expect(hcl.l >= 0.0 and hcl.l <= 1.0);
    }
}

test "toHCL hue values are exactly 3 distinct anchors" {
    // All trits share the same hue mapping: t1 → one of 3 hues
    var hues: [3]f64 = undefined;
    for ([_]i8{ -1, 0, 1 }, 0..) |t1, idx| {
        const tc = TriadicColor{ .t1 = t1, .t2 = 0, .t3 = 0 };
        hues[idx] = tc.toHCL().h;
    }
    // All 3 must be different
    try std.testing.expect(hues[0] != hues[1]);
    try std.testing.expect(hues[1] != hues[2]);
    try std.testing.expect(hues[0] != hues[2]);
}

test "out-of-range trit values in struct are clamped in toHCL" {
    // Directly construct with invalid trit values (bypass init)
    const tc = TriadicColor{ .t1 = 5, .t2 = -7, .t3 = 42 };
    const hcl = tc.toHCL();
    // Should clamp to valid ranges and produce valid output
    try std.testing.expect(hcl.h >= 0.0 and hcl.h < 360.0);
    try std.testing.expect(hcl.c >= 0.0);
    try std.testing.expect(hcl.l >= 0.0 and hcl.l <= 1.0);
}

// --- Path parameter edge cases ---

test "fromPathParameter NaN" {
    const tc = TriadicColor.fromPathParameter(math.nan(f64));
    try std.testing.expectEqual(@as(i8, -1), tc.t1);
    try std.testing.expectEqual(@as(i8, -1), tc.t2);
    try std.testing.expectEqual(@as(i8, -1), tc.t3);
}

test "fromPathParameter Inf" {
    const tc_pos = TriadicColor.fromPathParameter(math.inf(f64));
    try std.testing.expectEqual(@as(i8, 1), tc_pos.t1);
    try std.testing.expectEqual(@as(i8, 1), tc_pos.t2);
    try std.testing.expectEqual(@as(i8, 1), tc_pos.t3);

    const tc_neg = TriadicColor.fromPathParameter(-math.inf(f64));
    try std.testing.expectEqual(@as(i8, -1), tc_neg.t1);
    try std.testing.expectEqual(@as(i8, -1), tc_neg.t2);
    try std.testing.expectEqual(@as(i8, -1), tc_neg.t3);
}

test "fromPathParameter negative" {
    const tc = TriadicColor.fromPathParameter(-0.5);
    try std.testing.expectEqual(@as(i8, -1), tc.t1);
}

test "fromPathParameter exceeds 1.0" {
    const tc = TriadicColor.fromPathParameter(999.0);
    try std.testing.expectEqual(@as(i8, 1), tc.t1);
    try std.testing.expectEqual(@as(i8, 1), tc.t2);
    try std.testing.expectEqual(@as(i8, 1), tc.t3);
}

test "fromPathParameter monotonicity" {
    // Encoding should be monotonically non-decreasing
    var prev: u8 = 0;
    var i: u32 = 0;
    while (i <= 100) : (i += 1) {
        const t = @as(f64, @floatFromInt(i)) / 100.0;
        const code = TriadicColor.fromPathParameter(t).encode();
        try std.testing.expect(code >= prev);
        prev = code;
    }
}

// --- Wavelength edge cases ---

test "fromWavelength NaN returns achromatic" {
    const tc = TriadicColor.fromWavelength(math.nan(f64));
    try std.testing.expectEqual(@as(i8, 0), tc.t1);
    try std.testing.expectEqual(@as(i8, 0), tc.t2);
    try std.testing.expectEqual(@as(i8, 0), tc.t3);
}

test "fromWavelength Inf returns achromatic" {
    const tc = TriadicColor.fromWavelength(math.inf(f64));
    try std.testing.expectEqual(@as(i8, 0), tc.t1);
}

test "fromWavelength extreme UV and IR" {
    const uv = TriadicColor.fromWavelength(100.0); // deep UV
    try std.testing.expectEqual(@as(i8, -1), uv.t1); // blue side
    try std.testing.expectEqual(@as(i8, -1), uv.t3); // very dim

    const ir = TriadicColor.fromWavelength(2000.0); // deep IR
    try std.testing.expectEqual(@as(i8, 1), ir.t1); // red side
    try std.testing.expectEqual(@as(i8, -1), ir.t3); // very dim
}

test "fromWavelength negative wavelength" {
    const tc = TriadicColor.fromWavelength(-500.0);
    try std.testing.expectEqual(@as(i8, -1), tc.t1); // < 500 → blue
}

test "fromWavelength zero" {
    const tc = TriadicColor.fromWavelength(0.0);
    // 0 < 500 → blue, dim
    try std.testing.expectEqual(@as(i8, -1), tc.t1);
}

// --- Persistence edge cases ---

test "persistence color with NaN inputs" {
    const tc = persistenceColor(math.nan(f64), 1.0, 1.0);
    try std.testing.expect(tc.isBalanced());
    try std.testing.expectEqual(@as(i8, 0), tc.t1);
}

test "persistence color with Inf inputs" {
    const tc = persistenceColor(0.0, math.inf(f64), 1.0);
    try std.testing.expect(tc.isBalanced());
}

test "persistence color with death < birth" {
    const tc = persistenceColor(0.9, 0.1, 1.0);
    // Negative persistence clamped to 0 → lowest tier
    try std.testing.expectEqual(@as(i8, -1), tc.t1);
    try std.testing.expect(tc.isBalanced());
}

test "persistence color with max_persistence = 0" {
    const tc = persistenceColor(0.0, 0.0, 0.0);
    try std.testing.expect(tc.isBalanced());
}

test "persistence color with negative max_persistence" {
    const tc = persistenceColor(0.0, 0.5, -1.0);
    try std.testing.expect(tc.isBalanced());
}

test "persistence always balanced across sweep" {
    var i: u32 = 0;
    while (i <= 100) : (i += 1) {
        var j: u32 = 0;
        while (j <= 100) : (j += 1) {
            const birth = @as(f64, @floatFromInt(i)) / 100.0;
            const death = @as(f64, @floatFromInt(j)) / 100.0;
            const tc = persistenceColor(birth, death, 1.0);
            try std.testing.expect(tc.isBalanced());
        }
    }
}

// --- ANSI rendering edge cases ---

test "ansiFg buffer sufficient for max RGB values" {
    const tc = TriadicColor{ .t1 = 1, .t2 = 1, .t3 = 1 };
    var buf: [24]u8 = undefined;
    const result = tc.ansiFg(&buf);
    try std.testing.expect(result.len > 0);
    // Must start with ESC[
    try std.testing.expect(result[0] == 0x1b);
    try std.testing.expect(result[1] == '[');
    // Must end with 'm'
    try std.testing.expect(result[result.len - 1] == 'm');
}

test "ansiBg buffer sufficient" {
    const tc = TriadicColor{ .t1 = -1, .t2 = -1, .t3 = -1 };
    var buf: [24]u8 = undefined;
    const result = tc.ansiBg(&buf);
    try std.testing.expect(result.len > 0);
    try std.testing.expect(std.mem.startsWith(u8, result, "\x1b[48;2;"));
}

test "ansiFg and ansiBg for all 27 states" {
    for (0..27) |code| {
        const tc = TriadicColor.decode(@intCast(code)).?;
        var fg_buf: [24]u8 = undefined;
        var bg_buf: [24]u8 = undefined;
        const fg = tc.ansiFg(&fg_buf);
        const bg = tc.ansiBg(&bg_buf);
        try std.testing.expect(fg.len > 0);
        try std.testing.expect(bg.len > 0);
    }
}

// --- Interpolation tests ---

test "lerp at boundaries" {
    const a = TriadicColor{ .t1 = -1, .t2 = -1, .t3 = -1 };
    const b = TriadicColor{ .t1 = 1, .t2 = 1, .t3 = 1 };

    const start = TriadicColor.lerp(a, b, 0.0);
    const end = TriadicColor.lerp(a, b, 1.0);
    const a_rgb = a.toRGB();
    const b_rgb = b.toRGB();

    try std.testing.expectEqual(a_rgb.r, start.r);
    try std.testing.expectEqual(a_rgb.g, start.g);
    try std.testing.expectEqual(a_rgb.b, start.b);
    try std.testing.expectEqual(b_rgb.r, end.r);
    try std.testing.expectEqual(b_rgb.g, end.g);
    try std.testing.expectEqual(b_rgb.b, end.b);
}

test "lerp clamps out-of-range parameter" {
    const a = TriadicColor{ .t1 = 0, .t2 = 0, .t3 = 0 };
    const b = TriadicColor{ .t1 = 1, .t2 = 1, .t3 = -1 };

    const neg = TriadicColor.lerp(a, b, -5.0);
    const over = TriadicColor.lerp(a, b, 100.0);
    try std.testing.expectEqual(a.toRGB().r, neg.r);
    try std.testing.expectEqual(b.toRGB().r, over.r);
}

// --- Rendering to buffer tests ---

test "renderBlock writes valid ANSI" {
    var buf: [128]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const writer = fbs.writer();
    try renderBlock(writer, balanced_states[0]);
    const written = fbs.getWritten();
    try std.testing.expect(written.len > 0);
    try std.testing.expect(std.mem.startsWith(u8, written, "\x1b[48;2;"));
    try std.testing.expect(std.mem.endsWith(u8, written, "\x1b[0m"));
}

test "renderTrit writes bracketed trit string" {
    var buf: [128]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const writer = fbs.writer();
    try renderTrit(writer, TriadicColor{ .t1 = 1, .t2 = 0, .t3 = -1 });
    const written = fbs.getWritten();
    // Should contain [+0-]
    try std.testing.expect(std.mem.indexOf(u8, written, "+0-") != null);
}

test "renderPalette writes 3 rows" {
    var buf: [2048]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const writer = fbs.writer();
    try renderPalette(writer);
    const written = fbs.getWritten();
    // Should contain "t1=-1", "t1= 0", "t1=+1"
    try std.testing.expect(std.mem.indexOf(u8, written, "t1=-1") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "t1= 0") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "t1=+1") != null);
}

// --- Syrup roundtrip tests ---

test "syrup encode/decode roundtrip for all 27 states" {
    const allocator = std.testing.allocator;
    for (0..27) |code| {
        const tc = TriadicColor.decode(@intCast(code)).?;
        const val = try toSyrup(tc, allocator);
        defer val.deinitContainers(allocator);

        const decoded = fromSyrup(val).?;
        try std.testing.expect(tc.eql(decoded));
    }
}

test "syrup roundtrip preserves balance" {
    const allocator = std.testing.allocator;
    for (balanced_states) |state| {
        const val = try toSyrup(state, allocator);
        defer val.deinitContainers(allocator);
        const decoded = fromSyrup(val).?;
        try std.testing.expect(decoded.isBalanced());
    }
}

test "fromSyrup rejects non-record" {
    try std.testing.expect(fromSyrup(syrup.Value{ .integer = 42 }) == null);
    try std.testing.expect(fromSyrup(syrup.Value{ .bool = true }) == null);
    try std.testing.expect(fromSyrup(syrup.Value{ .string = "hello" }) == null);
}

test "fromSyrup rejects wrong label" {
    const allocator = std.testing.allocator;
    const label = try allocator.create(syrup.Value);
    defer allocator.destroy(label);
    label.* = .{ .symbol = "not-triadic" };
    const fields = try allocator.alloc(syrup.Value, 3);
    defer allocator.free(fields);
    fields[0] = .{ .integer = 0 };
    fields[1] = .{ .integer = 0 };
    fields[2] = .{ .integer = 0 };
    const val = syrup.Value{ .record = .{ .label = label, .fields = fields } };
    try std.testing.expect(fromSyrup(val) == null);
}

test "fromSyrup rejects too few fields" {
    const allocator = std.testing.allocator;
    const label = try allocator.create(syrup.Value);
    defer allocator.destroy(label);
    label.* = .{ .symbol = "triadic-color" };
    const fields = try allocator.alloc(syrup.Value, 2);
    defer allocator.free(fields);
    fields[0] = .{ .integer = 0 };
    fields[1] = .{ .integer = 0 };
    const val = syrup.Value{ .record = .{ .label = label, .fields = fields } };
    try std.testing.expect(fromSyrup(val) == null);
}

test "fromSyrup rejects out-of-range trit values" {
    const allocator = std.testing.allocator;
    const label = try allocator.create(syrup.Value);
    defer allocator.destroy(label);
    label.* = .{ .symbol = "triadic-color" };
    const fields = try allocator.alloc(syrup.Value, 3);
    defer allocator.free(fields);
    fields[0] = .{ .integer = 5 }; // out of range
    fields[1] = .{ .integer = 0 };
    fields[2] = .{ .integer = 0 };
    const val = syrup.Value{ .record = .{ .label = label, .fields = fields } };
    try std.testing.expect(fromSyrup(val) == null);
}

test "fromSyrup rejects non-integer fields" {
    const allocator = std.testing.allocator;
    const label = try allocator.create(syrup.Value);
    defer allocator.destroy(label);
    label.* = .{ .symbol = "triadic-color" };
    const fields = try allocator.alloc(syrup.Value, 3);
    defer allocator.free(fields);
    fields[0] = .{ .string = "nope" };
    fields[1] = .{ .integer = 0 };
    fields[2] = .{ .integer = 0 };
    const val = syrup.Value{ .record = .{ .label = label, .fields = fields } };
    try std.testing.expect(fromSyrup(val) == null);
}

test "classificationToSyrup has nested record" {
    const allocator = std.testing.allocator;
    const tc = TriadicColor.initBalanced(1, -1);
    const val = try classificationToSyrup(tc, "prigogine", allocator);
    // deinitContainers recurses into nested records, so one call suffices
    defer val.deinitContainers(allocator);

    try std.testing.expectEqual(syrup.Value.record, std.meta.activeTag(val));
    // Label should be "triadic-classification"
    try std.testing.expect(std.mem.eql(u8, val.record.label.symbol, "triadic-classification"));
    // 4 fields: name, nested color, balanced bool, encoded index
    try std.testing.expectEqual(@as(usize, 4), val.record.fields.len);
    // Field 0: name symbol
    try std.testing.expect(std.mem.eql(u8, val.record.fields[0].symbol, "prigogine"));
    // Field 1: nested triadic-color record
    try std.testing.expectEqual(syrup.Value.record, std.meta.activeTag(val.record.fields[1]));
    // Field 2: balanced bool
    try std.testing.expectEqual(true, val.record.fields[2].bool);
    // Field 3: encoded index
    const decoded_tc = fromSyrup(val.record.fields[1]).?;
    try std.testing.expect(tc.eql(decoded_tc));
}

// --- Prigogine/SpectralTensor constructor tests ---

test "fromPrigogine clamps garbage" {
    const tc = TriadicColor.fromPrigogine(100, -100, 50);
    try std.testing.expectEqual(@as(i8, 1), tc.t1);
    try std.testing.expectEqual(@as(i8, -1), tc.t2);
    try std.testing.expectEqual(@as(i8, 1), tc.t3);
}

test "fromSpectralTensor clamps garbage" {
    const tc = TriadicColor.fromSpectralTensor(-128, 127, 0);
    try std.testing.expectEqual(@as(i8, -1), tc.t1);
    try std.testing.expectEqual(@as(i8, 1), tc.t2);
    try std.testing.expectEqual(@as(i8, 0), tc.t3);
}

// --- Equality ---

test "eql reflexive for all 27" {
    for (0..27) |code| {
        const tc = TriadicColor.decode(@intCast(code)).?;
        try std.testing.expect(tc.eql(tc));
    }
}

test "eql distinguishes all 27 states" {
    for (0..27) |i| {
        for (0..27) |j| {
            const a = TriadicColor.decode(@intCast(i)).?;
            const b = TriadicColor.decode(@intCast(j)).?;
            if (i == j) {
                try std.testing.expect(a.eql(b));
            } else {
                try std.testing.expect(!a.eql(b));
            }
        }
    }
}
