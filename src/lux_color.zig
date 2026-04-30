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

/// Comptime-memoized sine table for 0..359 degrees
const sin_table = blk: {
    @setEvalBranchQuota(2000);
    var table: [360]f32 = undefined;
    for (0..360) |i| {
        table[i] = @sin(@as(f32, @floatFromInt(i)) * std.math.pi / 180.0);
    }
    break :blk table;
};

/// Comptime-memoized cosine table for 0..359 degrees
const cos_table = blk: {
    @setEvalBranchQuota(2000);
    var table: [360]f32 = undefined;
    for (0..360) |i| {
        table[i] = @cos(@as(f32, @floatFromInt(i)) * std.math.pi / 180.0);
    }
    break :blk table;
};

/// Fast sine lookup with degree input
fn fastSin(degrees: f32) f32 {
    const d = @mod(degrees, 360.0);
    const idx = @as(usize, @intFromFloat(d));
    const frac = d - @as(f32, @floatFromInt(idx));
    const next_idx = (idx + 1) % 360;
    return sin_table[idx] * (1.0 - frac) + sin_table[next_idx] * frac;
}

/// Fast cosine lookup with degree input
fn fastCos(degrees: f32) f32 {
    const d = @mod(degrees, 360.0);
    const idx = @as(usize, @intFromFloat(d));
    const frac = d - @as(f32, @floatFromInt(idx));
    const next_idx = (idx + 1) % 360;
    return cos_table[idx] * (1.0 - frac) + cos_table[next_idx] * frac;
}

/// HCL (Hue-Chroma-Lightness, uniform)
pub const HCL = struct {
    h: f32, // Hue in degrees [0, 360)
    c: f32, // Chroma [0, ~1.3]
    l: f32, // Lightness [0, 1]

    /// Convert to RGB via Lab intermediate
    pub fn toRGB(self: HCL) RGB {
        // HCL -> Lab
        // Optimization: Use memoized trig tables
        const a = self.c * fastCos(self.h);
        const b = self.c * fastSin(self.h);
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

    /// Color through which an expression coheres at given depth.
    /// For linear nesting (lists), golden angle suffices.
    /// For branching (let bindings, cond arms), use plastic angle on the branch index.
    pub fn init(trit: Trit, depth: u16) ExprColor {
        return initWithBranch(trit, depth, 0);
    }

    /// Compute color with both depth (golden angle) and branch slot (plastic angle).
    /// depth × golden + branch × plastic = 2D dispersion matching interaction net geometry.
    pub fn initWithBranch(trit: Trit, depth: u16, branch: u8) ExprColor {
        const base = trit.baseHue();
        const rotation = @as(f32, @floatFromInt(depth)) * GOLDEN_ANGLE +
            @as(f32, @floatFromInt(branch)) * PLASTIC_ANGLE;
        const hue = @mod(base + rotation, 360.0);

        // Use HCL color space (uniform)
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
// Comptime Memoization (#3558B0 — fold into existing tables)
//
// skeeto's insight: the hash table IS the identity.
// Zig comptime: the table IS the proof.
// 3 trits × 32 depths × 4 branches = 384 entries, all at compile time.
// =============================================================================

const MEMO_MAX_DEPTH = 32;
const MEMO_MAX_BRANCH = 4;

const MemoKey = struct {
    trit: i8,
    depth: u16,
    branch: u8,

    fn pack(self: MemoKey) u32 {
        const t: u32 = @intCast(@as(u8, @bitCast(self.trit)));
        return (t << 24) | (@as(u32, self.depth) << 8) | self.branch;
    }
};

const MemoEntry = struct {
    hue: f32,
    r: u8,
    g: u8,
    b: u8,
};

const color_memo_table = blk: {
    @setEvalBranchQuota(200_000);
    var table: [3][MEMO_MAX_DEPTH][MEMO_MAX_BRANCH]MemoEntry = undefined;
    const trits = [_]i8{ -1, 0, 1 };
    const bases = [_]f32{ 0.0, 120.0, 240.0 };
    for (trits, bases, 0..) |_, base, ti| {
        for (0..MEMO_MAX_DEPTH) |di| {
            for (0..MEMO_MAX_BRANCH) |bi| {
                const rotation = @as(f32, @floatFromInt(di)) * GOLDEN_ANGLE +
                    @as(f32, @floatFromInt(bi)) * PLASTIC_ANGLE;
                const hue = @mod(base + rotation, 360.0);
                const a_val = 0.6 * @cos(hue * std.math.pi / 180.0);
                const b_val = 0.6 * @sin(hue * std.math.pi / 180.0);
                const l = 0.6 * 100.0;
                const fy = (l + 16.0) / 116.0;
                const fx = a_val / 500.0 + fy;
                const fz = fy - b_val / 200.0;
                const delta = 6.0 / 29.0;
                const x_val = 0.95047 * (if (fx > delta) fx * fx * fx else 3.0 * delta * delta * (fx - 4.0 / 29.0));
                const y_val = 1.00000 * (if (fy > delta) fy * fy * fy else 3.0 * delta * delta * (fy - 4.0 / 29.0));
                const z_val = 1.08883 * (if (fz > delta) fz * fz * fz else 3.0 * delta * delta * (fz - 4.0 / 29.0));
                var r_lin = 3.2404542 * x_val - 1.5371385 * y_val - 0.4985314 * z_val;
                var g_lin = -0.9692660 * x_val + 1.8760108 * y_val + 0.0415560 * z_val;
                var b_lin = 0.0556434 * x_val - 0.2040259 * y_val + 1.0572252 * z_val;
                r_lin = if (r_lin <= 0.0031308) 12.92 * r_lin else 1.055 * std.math.pow(f32, @max(r_lin, 0.0), 1.0 / 2.4) - 0.055;
                g_lin = if (g_lin <= 0.0031308) 12.92 * g_lin else 1.055 * std.math.pow(f32, @max(g_lin, 0.0), 1.0 / 2.4) - 0.055;
                b_lin = if (b_lin <= 0.0031308) 12.92 * b_lin else 1.055 * std.math.pow(f32, @max(b_lin, 0.0), 1.0 / 2.4) - 0.055;
                table[ti][di][bi] = .{
                    .hue = hue,
                    .r = @intFromFloat(@max(0, @min(255, r_lin * 255.0))),
                    .g = @intFromFloat(@max(0, @min(255, g_lin * 255.0))),
                    .b = @intFromFloat(@max(0, @min(255, b_lin * 255.0))),
                };
            }
        }
    }
    break :blk table;
};

fn tritIndex(t: Trit) usize {
    return switch (t) {
        .minus => 0,
        .ergodic => 1,
        .plus => 2,
    };
}

/// O(1) memoized color lookup. Falls back to runtime for out-of-range.
pub fn memoColor(trit: Trit, depth: u16, branch: u8) ExprColor {
    if (depth < MEMO_MAX_DEPTH and branch < MEMO_MAX_BRANCH) {
        const e = color_memo_table[tritIndex(trit)][depth][branch];
        return .{ .trit = trit, .depth = depth, .hue = e.hue, .rgb = .{ .r = e.r, .g = e.g, .b = e.b } };
    }
    return ExprColor.initWithBranch(trit, depth, branch);
}

/// Expression fingerprint: hash an expression tree structure → u64.
/// Same structure always produces the same fingerprint (referential transparency).
pub fn exprFingerprint(op_bytes: []const u8, child_fps: []const u64) u64 {
    var h: u64 = 0xcbf29ce484222325; // FNV offset
    for (op_bytes) |byte| {
        h ^= byte;
        h *%= 0x100000001b3; // FNV prime
    }
    for (child_fps) |cfp| {
        h ^= cfp;
        h *%= 0x100000001b3;
    }
    return h;
}

/// Map fingerprint → color for cross-world expression matching.
/// Same expression in world A and world B → same color.
pub fn fingerprintColor(fp: u64, seed: u64) RGB {
    const mixed = fp ^ seed;
    var z = mixed +% 0x9E3779B97F4A7C15;
    z = (z ^ (z >> 30)) *% 0xBF58476D1CE4E5B9;
    z = (z ^ (z >> 27)) *% 0x94D049BB133111EB;
    z ^= (z >> 31);
    return .{
        .r = @truncate(z >> 16),
        .g = @truncate(z >> 8),
        .b = @truncate(z),
    };
}

// =============================================================================
// Tests
// =============================================================================

test "memo table matches runtime" {
    const trits = [_]Trit{ .minus, .ergodic, .plus };
    for (trits) |t| {
        for (0..8) |d| {
            for (0..4) |b| {
                const memo = memoColor(t, @intCast(d), @intCast(b));
                const live = ExprColor.initWithBranch(t, @intCast(d), @intCast(b));
                try std.testing.expectEqual(memo.rgb.r, live.rgb.r);
                try std.testing.expectEqual(memo.rgb.g, live.rgb.g);
                try std.testing.expectEqual(memo.rgb.b, live.rgb.b);
            }
        }
    }
}

test "fingerprint determinism" {
    const fp1 = exprFingerprint("compose", &[_]u64{ 111, 222 });
    const fp2 = exprFingerprint("compose", &[_]u64{ 111, 222 });
    try std.testing.expectEqual(fp1, fp2);

    const fp3 = exprFingerprint("compose", &[_]u64{ 222, 111 });
    try std.testing.expect(fp1 != fp3);
}

test "fingerprint color cross-world" {
    const fp = exprFingerprint("sigmoid", &[_]u64{42});
    const c1 = fingerprintColor(fp, 2026);
    const c2 = fingerprintColor(fp, 2026);
    try std.testing.expectEqual(c1.r, c2.r);
    try std.testing.expectEqual(c1.g, c2.g);
    try std.testing.expectEqual(c1.b, c2.b);
}

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
