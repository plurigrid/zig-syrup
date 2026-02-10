//! Lux Expression Color Computation
//!
//! Referentially transparent coloring for S-expressions based on:
//! - GF(3) trit of operation (-1/0/+1)
//! - Nesting depth with golden angle progression
//! - Integration with Gay.jl color system
//!
//! Used by Lux→Zig compiler to emit parenthesis color metadata.
//! Self-contained with minimal color space code.

const std = @import("std");

/// Golden angle in degrees: 360° / φ² ≈ 137.508°
pub const GOLDEN_ANGLE: f32 = 137.5077640500378;

/// Plastic ratio ψ = (∛(108 + 12√69) + ∛(108 - 12√69)) / 6 ≈ 1.3247
/// Plastic angle: 360° / ψ² ≈ 205.14°
pub const PLASTIC_ANGLE: f32 = 205.14;

/// Silver ratio δ_S = 1 + √2 ≈ 2.414
/// Silver angle: 360° / δ_S² ≈ 149.07°
pub const SILVER_ANGLE: f32 = 149.07;

/// RGB color (24-bit)
pub const RGB = struct {
    r: u8,
    g: u8,
    b: u8,

    /// ANSI 24-bit truecolor escape sequence for foreground
    pub fn toAnsiFg(self: RGB, buf: *[19]u8) []const u8 {
        const len = std.fmt.bufPrint(buf, "\x1b[38;2;{d};{d};{d}m", .{ self.r, self.g, self.b }) catch unreachable;
        return buf[0..len.len];
    }
};

/// HCL color (Hue-Chroma-Lightness, perceptually uniform)
pub const HCL = struct {
    h: f32, // Hue in degrees [0, 360)
    c: f32, // Chroma [0, ~1.3]
    l: f32, // Lightness [0, 1]

    /// Convert to RGB via Lab intermediate
    pub fn toRGB(self: HCL) RGB {
        // HCL -> Lab
        const h_rad = self.h * std.math.pi / 180.0;
        const a = self.c * @cos(h_rad);
        const b = self.c * @sin(h_rad);
        const l = self.l * 100.0;

        // Lab -> XYZ (D65 illuminant)
        const fy = (l + 16.0) / 116.0;
        const fx = a / 500.0 + fy;
        const fz = fy - b / 200.0;

        const xn = 0.95047;
        const yn = 1.00000;
        const zn = 1.08883;

        const x = xn * labF_inv(fx);
        const y = yn * labF_inv(fy);
        const z = zn * labF_inv(fz);

        // XYZ -> sRGB
        var r_lin = 3.2404542 * x - 1.5371385 * y - 0.4985314 * z;
        var g_lin = -0.9692660 * x + 1.8760108 * y + 0.0415560 * z;
        var b_lin = 0.0556434 * x - 0.2040259 * y + 1.0572252 * z;

        // Gamma correction
        r_lin = gammaCorrect(r_lin);
        g_lin = gammaCorrect(g_lin);
        b_lin = gammaCorrect(b_lin);

        return .{
            .r = @intFromFloat(@max(0, @min(255, r_lin * 255.0))),
            .g = @intFromFloat(@max(0, @min(255, g_lin * 255.0))),
            .b = @intFromFloat(@max(0, @min(255, b_lin * 255.0))),
        };
    }

    fn labF_inv(t: f32) f32 {
        const delta = 6.0 / 29.0;
        if (t > delta) {
            return t * t * t;
        } else {
            return 3.0 * delta * delta * (t - 4.0 / 29.0);
        }
    }

    fn gammaCorrect(u: f32) f32 {
        if (u <= 0.0031308) {
            return 12.92 * u;
        } else {
            return 1.055 * std.math.pow(f32, u, 1.0 / 2.4) - 0.055;
        }
    }
};

/// GF(3) trit for colored operads
pub const Trit = enum(i8) {
    minus = -1,
    ergodic = 0,
    plus = 1,

    /// Sum of trits modulo 3, in balanced form
    pub fn add(self: Trit, other: Trit) Trit {
        const sum = @intFromEnum(self) + @intFromEnum(other);
        // Reduce to range [-1, 0, 1]
        const mod = @mod(sum + 3, 3); // Ensure positive before mod
        return switch (mod) {
            0 => .ergodic,
            1 => .plus,
            2 => .minus, // 2 ≡ -1 (mod 3) in balanced
            else => unreachable,
        };
    }

    /// Check if trits sum to zero (GF(3) conservation)
    pub fn conserved(trits: []const Trit) bool {
        var sum: Trit = .ergodic;
        for (trits) |t| {
            sum = sum.add(t);
        }
        return sum == .ergodic;
    }

    /// Base hue for this trit (before depth rotation)
    pub fn baseHue(self: Trit) f32 {
        return switch (self) {
            .minus => 0.0, // Red
            .ergodic => 120.0, // Green
            .plus => 240.0, // Blue
        };
    }
};

/// Expression color metadata (emitted by Lux→Zig compiler)
pub const ExprColor = struct {
    trit: Trit,
    depth: u16,
    hue: f32,
    rgb: RGB,

    /// Compute color for an expression at given depth
    pub fn init(trit: Trit, depth: u16) ExprColor {
        const base = trit.baseHue();
        const rotation = @as(f32, @floatFromInt(depth)) * GOLDEN_ANGLE;
        const hue = @mod(base + rotation, 360.0);

        // Use HCL color space (perceptually uniform)
        const hcl = HCL{
            .h = hue,
            .c = 0.6, // Medium chroma for good saturation
            .l = 0.6, // Medium lightness for readability
        };
        const rgb = hcl.toRGB();

        return .{
            .trit = trit,
            .depth = depth,
            .hue = hue,
            .rgb = rgb,
        };
    }

    /// Compose child expression colors into parent
    pub fn compose(op_color: ExprColor, arg_colors: []const ExprColor) ExprColor {
        // Parent depth = max child depth + 1
        var max_depth: u16 = 0;
        for (arg_colors) |c| {
            max_depth = @max(max_depth, c.depth);
        }
        const parent_depth = max_depth + 1;

        // Parent trit = sum of all trits (mod 3)
        var result_trit = op_color.trit;
        for (arg_colors) |c| {
            result_trit = result_trit.add(c.trit);
        }

        return ExprColor.init(result_trit, parent_depth);
    }
};

// =============================================================================
// Tests
// =============================================================================

test "trit arithmetic" {
    try std.testing.expectEqual(Trit.ergodic, Trit.plus.add(.minus));
    try std.testing.expectEqual(Trit.plus, Trit.ergodic.add(.plus));
    try std.testing.expectEqual(Trit.minus, Trit.minus.add(.ergodic));

    // GF(3) conservation: -1 + 0 + 1 = 0
    const triad = [_]Trit{ .minus, .ergodic, .plus };
    try std.testing.expect(Trit.conserved(&triad));
}

test "base hues" {
    try std.testing.expectEqual(@as(f32, 0.0), Trit.minus.baseHue());
    try std.testing.expectEqual(@as(f32, 120.0), Trit.ergodic.baseHue());
    try std.testing.expectEqual(@as(f32, 240.0), Trit.plus.baseHue());
}

test "golden angle progression" {
    const depth0 = ExprColor.init(.ergodic, 0);
    const depth1 = ExprColor.init(.ergodic, 1);
    const depth2 = ExprColor.init(.ergodic, 2);

    try std.testing.expectEqual(@as(f32, 120.0), depth0.hue);
    try std.testing.expectApproxEqAbs(@as(f32, 257.507764), depth1.hue, 0.001);
    // depth2 wraps around: 120 + 2*137.5 = 395 → 35
    try std.testing.expectApproxEqAbs(@as(f32, 35.015528), depth2.hue, 0.001);
}

test "composition" {
    // (op1 (op2 x))
    // op1: PLUS, op2: MINUS, x: ERGODIC
    const x_color = ExprColor.init(.ergodic, 0);
    const op2_color = ExprColor.init(.minus, 0);
    const inner = ExprColor.compose(op2_color, &[_]ExprColor{x_color});

    try std.testing.expectEqual(Trit.minus, inner.trit); // -1 + 0 = -1
    try std.testing.expectEqual(@as(u16, 1), inner.depth);

    const op1_color = ExprColor.init(.plus, 0);
    const outer = ExprColor.compose(op1_color, &[_]ExprColor{inner});

    try std.testing.expectEqual(Trit.ergodic, outer.trit); // +1 + -1 = 0
    try std.testing.expectEqual(@as(u16, 2), outer.depth);
}

test "BCI pipeline colors" {
    // (aptos_commit (+1)
    //   (golden_spiral (0)
    //     (sigmoid (-1)
    //       (fisher_rao (-1)
    //         eeg_data))))

    const eeg = ExprColor.init(.ergodic, 0); // Data source = neutral
    const fisher = ExprColor.init(.minus, 0);
    const sigmoid = ExprColor.init(.minus, 0);
    const golden = ExprColor.init(.ergodic, 0);
    const aptos = ExprColor.init(.plus, 0);

    // Build tree bottom-up
    const level1 = ExprColor.compose(fisher, &[_]ExprColor{eeg});
    try std.testing.expectEqual(Trit.minus, level1.trit);
    try std.testing.expectEqual(@as(u16, 1), level1.depth);

    const level2 = ExprColor.compose(sigmoid, &[_]ExprColor{level1});
    // -1 + -1 = -2. In balanced ternary: (-2 + 3) mod 3 = 1 → .plus
    try std.testing.expectEqual(Trit.plus, level2.trit);
    try std.testing.expectEqual(@as(u16, 2), level2.depth);

    const level3 = ExprColor.compose(golden, &[_]ExprColor{level2});
    // 0 + 1 = 1 → .plus
    try std.testing.expectEqual(Trit.plus, level3.trit);
    try std.testing.expectEqual(@as(u16, 3), level3.depth);

    const level4 = ExprColor.compose(aptos, &[_]ExprColor{level3});
    // +1 + +1 = +2. In balanced: (2 + 3) mod 3 = 2 → .minus
    try std.testing.expectEqual(Trit.minus, level4.trit);
    try std.testing.expectEqual(@as(u16, 4), level4.depth);
}
