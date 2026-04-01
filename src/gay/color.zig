// color.zig: Zig translation of Gay.jl's universal_color.jl and colorspaces.jl
// Universal color types with runtime/space/eval tagging for GPU dispatch.
// SPI fingerprinting via XOR hash for spectral parallel identity verification.

const std = @import("std");
const math = std.math;

// ---------------------------------------------------------------------------
// Runtime targets (for future GPU dispatch)
// ---------------------------------------------------------------------------
pub const Runtime = enum { cpu, cuda, metal, amdgpu, oneapi, tpu };

// ---------------------------------------------------------------------------
// Color spaces
// ---------------------------------------------------------------------------
pub const ColorSpace = enum { srgb, display_p3, rec2020, spectral, custom };

// ---------------------------------------------------------------------------
// Evaluation strategy
// ---------------------------------------------------------------------------
pub const EvalStrategy = enum { eager, lazy, symbolic };

// ---------------------------------------------------------------------------
// CIE xy primaries + white point
// ---------------------------------------------------------------------------
pub const Primaries = struct {
    rx: f64,
    ry: f64,
    gx: f64,
    gy: f64,
    bx: f64,
    by: f64,
    wx: f64,
    wy: f64,
};

pub const SRGB_PRIMARIES = Primaries{ .rx = 0.640, .ry = 0.330, .gx = 0.300, .gy = 0.600, .bx = 0.150, .by = 0.060, .wx = 0.3127, .wy = 0.3290 };
pub const P3_PRIMARIES = Primaries{ .rx = 0.680, .ry = 0.320, .gx = 0.265, .gy = 0.690, .bx = 0.150, .by = 0.060, .wx = 0.3127, .wy = 0.3290 };
pub const REC2020_PRIMARIES = Primaries{ .rx = 0.708, .ry = 0.292, .gx = 0.170, .gy = 0.797, .bx = 0.131, .by = 0.046, .wx = 0.3127, .wy = 0.3290 };

// ---------------------------------------------------------------------------
// Core color types
// ---------------------------------------------------------------------------

pub const RGB = struct {
    r: f64,
    g: f64,
    b: f64,

    /// Convert to "#RRGGBB" hex string.
    pub fn toHex(self: RGB) [7]u8 {
        const ri = clampByte(self.r);
        const gi = clampByte(self.g);
        const bi = clampByte(self.b);
        var buf: [7]u8 = undefined;
        buf[0] = '#';
        const hex_chars = "0123456789abcdef";
        buf[1] = hex_chars[ri >> 4];
        buf[2] = hex_chars[ri & 0x0f];
        buf[3] = hex_chars[gi >> 4];
        buf[4] = hex_chars[gi & 0x0f];
        buf[5] = hex_chars[bi >> 4];
        buf[6] = hex_chars[bi & 0x0f];
        return buf;
    }

    /// Parse "#RRGGBB" hex string to RGB. Returns null on invalid input.
    pub fn fromHex(hex: []const u8) ?RGB {
        if (hex.len != 7 or hex[0] != '#') return null;
        const r = parseHexByte(hex[1], hex[2]) orelse return null;
        const g = parseHexByte(hex[3], hex[4]) orelse return null;
        const b = parseHexByte(hex[5], hex[6]) orelse return null;
        return RGB{
            .r = @as(f64, @floatFromInt(r)) / 255.0,
            .g = @as(f64, @floatFromInt(g)) / 255.0,
            .b = @as(f64, @floatFromInt(b)) / 255.0,
        };
    }

    /// Linear interpolation between two colors.
    pub fn mix(a: RGB, b: RGB, t: f64) RGB {
        return .{
            .r = a.r + (b.r - a.r) * t,
            .g = a.g + (b.g - a.g) * t,
            .b = a.b + (b.b - a.b) * t,
        };
    }

    /// Complement (1 - c). Involution: complement(complement(c)) == c.
    pub fn complement(self: RGB) RGB {
        return .{ .r = 1.0 - self.r, .g = 1.0 - self.g, .b = 1.0 - self.b };
    }

    /// XOR-based hash of the bit pattern for SPI fingerprinting.
    pub fn hash(self: RGB) u64 {
        const rb: u64 = @bitCast(self.r);
        const gb: u64 = @bitCast(self.g);
        const bb: u64 = @bitCast(self.b);
        // Murmur-style mix
        var h = rb ^ (gb *% 0x9e3779b97f4a7c15);
        h ^= bb *% 0x517cc1b727220a95;
        h ^= h >> 33;
        h *%= 0xff51afd7ed558ccd;
        h ^= h >> 33;
        return h;
    }
};

pub const HSV = struct { h: f64, s: f64, v: f64 };
pub const HSL = struct { h: f64, s: f64, l: f64 };
pub const Lab = struct { l: f64, a: f64, b: f64 };
pub const Gray = struct { val: f64 };
pub const RGBA = struct { r: f64, g: f64, b: f64, a: f64 };

// ---------------------------------------------------------------------------
// Spectral color (compile-time N)
// ---------------------------------------------------------------------------
pub fn Spectral(comptime N: usize) type {
    return struct {
        wavelengths: [N]f64,
        values: [N]f64,
    };
}

// ---------------------------------------------------------------------------
// Universal color wrapper
// ---------------------------------------------------------------------------
pub const UniversalColor = struct {
    rgb: RGB,
    space: ColorSpace = .srgb,
    runtime: Runtime = .cpu,
    eval_strategy: EvalStrategy = .eager,

    pub fn withRuntime(self: UniversalColor, rt: Runtime) UniversalColor {
        var c = self;
        c.runtime = rt;
        return c;
    }

    pub fn withSpace(self: UniversalColor, cs: ColorSpace) UniversalColor {
        var c = self;
        c.space = cs;
        return c;
    }

    pub fn withEval(self: UniversalColor, ev: EvalStrategy) UniversalColor {
        var c = self;
        c.eval_strategy = ev;
        return c;
    }
};

// ---------------------------------------------------------------------------
// Conversions
// ---------------------------------------------------------------------------

/// HSL to RGB. h in [0,360), s,l in [0,1].
pub fn hslToRgb(h: f64, s: f64, l: f64) RGB {
    if (s == 0.0) return .{ .r = l, .g = l, .b = l };

    const q = if (l < 0.5) l * (1.0 + s) else l + s - l * s;
    const p = 2.0 * l - q;
    const h_norm = h / 360.0;

    return .{
        .r = hueToRgb(p, q, h_norm + 1.0 / 3.0),
        .g = hueToRgb(p, q, h_norm),
        .b = hueToRgb(p, q, h_norm - 1.0 / 3.0),
    };
}

/// RGB to HSL. Returns h in [0,360), s,l in [0,1].
pub fn rgbToHsl(c: RGB) HSL {
    const max_c = @max(c.r, @max(c.g, c.b));
    const min_c = @min(c.r, @min(c.g, c.b));
    const l = (max_c + min_c) / 2.0;
    const delta = max_c - min_c;

    if (delta == 0.0) return .{ .h = 0.0, .s = 0.0, .l = l };

    const s = if (l < 0.5) delta / (max_c + min_c) else delta / (2.0 - max_c - min_c);

    var h: f64 = undefined;
    if (max_c == c.r) {
        h = (c.g - c.b) / delta;
        if (c.g < c.b) h += 6.0;
    } else if (max_c == c.g) {
        h = (c.b - c.r) / delta + 2.0;
    } else {
        h = (c.r - c.g) / delta + 4.0;
    }
    h *= 60.0;

    return .{ .h = h, .s = s, .l = l };
}

/// HSV to RGB. h in [0,360), s,v in [0,1].
pub fn hsvToRgb(h: f64, s: f64, v: f64) RGB {
    if (s == 0.0) return .{ .r = v, .g = v, .b = v };

    const sector = h / 60.0;
    const i = @floor(sector);
    const f = sector - i;
    const p = v * (1.0 - s);
    const q_val = v * (1.0 - s * f);
    const t = v * (1.0 - s * (1.0 - f));

    const idx: usize = @intFromFloat(@mod(i, 6.0));
    return switch (idx) {
        0 => .{ .r = v, .g = t, .b = p },
        1 => .{ .r = q_val, .g = v, .b = p },
        2 => .{ .r = p, .g = v, .b = t },
        3 => .{ .r = p, .g = q_val, .b = v },
        4 => .{ .r = t, .g = p, .b = v },
        5 => .{ .r = v, .g = p, .b = q_val },
        else => .{ .r = 0, .g = 0, .b = 0 },
    };
}

// ---------------------------------------------------------------------------
// Gamut operations
// ---------------------------------------------------------------------------

pub fn inGamut(c: RGB) bool {
    return c.r >= 0.0 and c.r <= 1.0 and
        c.g >= 0.0 and c.g <= 1.0 and
        c.b >= 0.0 and c.b <= 1.0;
}

pub fn clampToGamut(c: RGB) RGB {
    return .{
        .r = math.clamp(c.r, 0.0, 1.0),
        .g = math.clamp(c.g, 0.0, 1.0),
        .b = math.clamp(c.b, 0.0, 1.0),
    };
}

// ---------------------------------------------------------------------------
// SPI fingerprint
// ---------------------------------------------------------------------------

/// Compute a rolling XOR fingerprint over a color palette.
pub fn fingerprint(colors: []const RGB) u64 {
    var h: u64 = 0xcbf29ce484222325; // FNV offset basis
    for (colors) |c| {
        h ^= c.hash();
        h *%= 0x100000001b3; // FNV prime
    }
    return h;
}

/// Verify two palettes have identical SPI fingerprints.
pub fn verifySpi(a: []const RGB, b: []const RGB) bool {
    return fingerprint(a) == fingerprint(b);
}

// ---------------------------------------------------------------------------
// Pride flag palettes
// ---------------------------------------------------------------------------

pub const pride_rainbow = [6]RGB{
    .{ .r = 0.894, .g = 0.012, .b = 0.012 }, // red
    .{ .r = 1.000, .g = 0.549, .b = 0.000 }, // orange
    .{ .r = 1.000, .g = 0.929, .b = 0.000 }, // yellow
    .{ .r = 0.000, .g = 0.502, .b = 0.149 }, // green
    .{ .r = 0.000, .g = 0.302, .b = 0.686 }, // blue
    .{ .r = 0.459, .g = 0.027, .b = 0.529 }, // violet
};

pub const pride_bisexual = [3]RGB{
    .{ .r = 0.843, .g = 0.008, .b = 0.439 }, // magenta
    .{ .r = 0.608, .g = 0.314, .b = 0.588 }, // lavender
    .{ .r = 0.000, .g = 0.220, .b = 0.659 }, // blue
};

pub const pride_trans = [5]RGB{
    .{ .r = 0.357, .g = 0.808, .b = 0.980 }, // light blue
    .{ .r = 0.961, .g = 0.659, .b = 0.722 }, // pink
    .{ .r = 1.000, .g = 1.000, .b = 1.000 }, // white
    .{ .r = 0.961, .g = 0.659, .b = 0.722 }, // pink
    .{ .r = 0.357, .g = 0.808, .b = 0.980 }, // light blue
};

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

fn clampByte(v: f64) u8 {
    const clamped = math.clamp(v, 0.0, 1.0);
    return @intFromFloat(@round(clamped * 255.0));
}

fn hexDigit(c: u8) ?u4 {
    return switch (c) {
        '0'...'9' => @intCast(c - '0'),
        'a'...'f' => @intCast(c - 'a' + 10),
        'A'...'F' => @intCast(c - 'A' + 10),
        else => null,
    };
}

fn parseHexByte(hi: u8, lo: u8) ?u8 {
    const h = hexDigit(hi) orelse return null;
    const l = hexDigit(lo) orelse return null;
    return (@as(u8, h) << 4) | @as(u8, l);
}

fn hueToRgb(p: f64, q: f64, t_raw: f64) f64 {
    var t = t_raw;
    if (t < 0.0) t += 1.0;
    if (t > 1.0) t -= 1.0;
    if (t < 1.0 / 6.0) return p + (q - p) * 6.0 * t;
    if (t < 1.0 / 2.0) return q;
    if (t < 2.0 / 3.0) return p + (q - p) * (2.0 / 3.0 - t) * 6.0;
    return p;
}

// ===========================================================================
// Tests
// ===========================================================================

test "hex round-trip" {
    const c = RGB{ .r = 0.2, .g = 0.6, .b = 1.0 };
    const hex = c.toHex();
    const back = RGB.fromHex(&hex) orelse unreachable;
    // 8-bit quantization tolerance
    try std.testing.expectApproxEqAbs(c.r, back.r, 1.0 / 255.0 + 0.01);
    try std.testing.expectApproxEqAbs(c.g, back.g, 1.0 / 255.0 + 0.01);
    try std.testing.expectApproxEqAbs(c.b, back.b, 1.0 / 255.0 + 0.01);
}

test "hex known values" {
    const black = RGB{ .r = 0, .g = 0, .b = 0 };
    try std.testing.expectEqualSlices(u8, "#000000", &black.toHex());
    const white = RGB{ .r = 1, .g = 1, .b = 1 };
    try std.testing.expectEqualSlices(u8, "#ffffff", &white.toHex());
}

test "fromHex rejects invalid" {
    try std.testing.expect(RGB.fromHex("nothex") == null);
    try std.testing.expect(RGB.fromHex("#gggggg") == null);
    try std.testing.expect(RGB.fromHex("") == null);
}

test "mix interpolation" {
    const a = RGB{ .r = 0, .g = 0, .b = 0 };
    const b = RGB{ .r = 1, .g = 1, .b = 1 };
    const mid = RGB.mix(a, b, 0.5);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), mid.r, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), mid.g, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), mid.b, 1e-12);
    // mix endpoints
    const at0 = RGB.mix(a, b, 0.0);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), at0.r, 1e-12);
    const at1 = RGB.mix(a, b, 1.0);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), at1.r, 1e-12);
}

test "complement involution" {
    const c = RGB{ .r = 0.3, .g = 0.7, .b = 0.1 };
    const cc = c.complement().complement();
    try std.testing.expectApproxEqAbs(c.r, cc.r, 1e-12);
    try std.testing.expectApproxEqAbs(c.g, cc.g, 1e-12);
    try std.testing.expectApproxEqAbs(c.b, cc.b, 1e-12);
}

test "HSL<->RGB conversion" {
    // Pure red: h=0, s=1, l=0.5
    const red = hslToRgb(0, 1, 0.5);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), red.r, 1e-10);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), red.g, 1e-10);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), red.b, 1e-10);

    // Round-trip
    const orig = RGB{ .r = 0.4, .g = 0.6, .b = 0.8 };
    const hsl = rgbToHsl(orig);
    const back = hslToRgb(hsl.h, hsl.s, hsl.l);
    try std.testing.expectApproxEqAbs(orig.r, back.r, 1e-10);
    try std.testing.expectApproxEqAbs(orig.g, back.g, 1e-10);
    try std.testing.expectApproxEqAbs(orig.b, back.b, 1e-10);

    // Achromatic
    const gray = hslToRgb(0, 0, 0.5);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), gray.r, 1e-10);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), gray.g, 1e-10);
}

test "HSV to RGB" {
    // Pure green: h=120, s=1, v=1
    const green = hsvToRgb(120, 1, 1);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), green.r, 1e-10);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), green.g, 1e-10);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), green.b, 1e-10);
}

test "gamut clamping" {
    const oob = RGB{ .r = -0.5, .g = 1.5, .b = 0.5 };
    try std.testing.expect(!inGamut(oob));
    const clamped = clampToGamut(oob);
    try std.testing.expect(inGamut(clamped));
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), clamped.r, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), clamped.g, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), clamped.b, 1e-12);

    // In-gamut color passes
    const ok = RGB{ .r = 0.5, .g = 0.5, .b = 0.5 };
    try std.testing.expect(inGamut(ok));
}

test "SPI fingerprint" {
    const palette = [_]RGB{
        .{ .r = 1, .g = 0, .b = 0 },
        .{ .r = 0, .g = 1, .b = 0 },
        .{ .r = 0, .g = 0, .b = 1 },
    };
    const fp1 = fingerprint(&palette);
    const fp2 = fingerprint(&palette);
    try std.testing.expectEqual(fp1, fp2);
    try std.testing.expect(verifySpi(&palette, &palette));

    // Different palette => different fingerprint
    const other = [_]RGB{
        .{ .r = 0, .g = 0, .b = 0 },
    };
    try std.testing.expect(!verifySpi(&palette, &other));
}

test "pride palettes have correct lengths" {
    try std.testing.expectEqual(@as(usize, 6), pride_rainbow.len);
    try std.testing.expectEqual(@as(usize, 3), pride_bisexual.len);
    try std.testing.expectEqual(@as(usize, 5), pride_trans.len);
}

test "UniversalColor builder" {
    const uc = UniversalColor{ .rgb = .{ .r = 0.5, .g = 0.5, .b = 0.5 } };
    const gpu = uc.withRuntime(.metal).withSpace(.display_p3).withEval(.lazy);
    try std.testing.expectEqual(Runtime.metal, gpu.runtime);
    try std.testing.expectEqual(ColorSpace.display_p3, gpu.space);
    try std.testing.expectEqual(EvalStrategy.lazy, gpu.eval_strategy);
    // Original unchanged
    try std.testing.expectEqual(Runtime.cpu, uc.runtime);
}
