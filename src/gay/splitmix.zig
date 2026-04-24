// splitmix.zig: SplitMix64 deterministic color generation
// Zig translation of Gay.jl — bijective PRNG for reproducible color palettes
// Seed 1069 = canonical genesis chain, GF(3) trit-tagged

const std = @import("std");
const math = std.math;

// ============================================================================
// Constants
// ============================================================================

pub const GOLDEN: u64 = 0x9e3779b97f4a7c15;
pub const MIX1: u64 = 0xbf58476d1ce4e5b9;
pub const MIX2: u64 = 0x94d049bb133111eb;
pub const GAY_SEED: u64 = 1069;

// ============================================================================
// SplitMix64 bijection
// ============================================================================

pub fn splitmix64(input: u64) u64 {
    var x = input +% GOLDEN;
    x = (x ^ (x >> 30)) *% MIX1;
    x = (x ^ (x >> 27)) *% MIX2;
    return x ^ (x >> 31);
}

// ============================================================================
// Color type
// ============================================================================

pub const Color = struct {
    r: f64,
    g: f64,
    b: f64,

    /// Format as "#RRGGBB"
    pub fn toHex(self: Color) [7]u8 {
        const hex_chars = "0123456789ABCDEF";
        const ri: u8 = @intFromFloat(@round(std.math.clamp(self.r, 0.0, 1.0) * 255.0));
        const gi: u8 = @intFromFloat(@round(std.math.clamp(self.g, 0.0, 1.0) * 255.0));
        const bi: u8 = @intFromFloat(@round(std.math.clamp(self.b, 0.0, 1.0) * 255.0));
        return .{
            '#',
            hex_chars[ri >> 4],
            hex_chars[ri & 0xF],
            hex_chars[gi >> 4],
            hex_chars[gi & 0xF],
            hex_chars[bi >> 4],
            hex_chars[bi & 0xF],
        };
    }

    /// Linear interpolation between two colors
    pub fn mix(a: Color, b: Color, t: f64) Color {
        const tc = std.math.clamp(t, 0.0, 1.0);
        return .{
            .r = a.r + (b.r - a.r) * tc,
            .g = a.g + (b.g - a.g) * tc,
            .b = a.b + (b.b - a.b) * tc,
        };
    }

    /// RGB complement (1 - channel)
    pub fn complement(self: Color) Color {
        return .{
            .r = 1.0 - self.r,
            .g = 1.0 - self.g,
            .b = 1.0 - self.b,
        };
    }

    pub fn eql(a: Color, b: Color) bool {
        return @as(u8, @intFromFloat(@round(a.r * 255.0))) == @as(u8, @intFromFloat(@round(b.r * 255.0))) and
            @as(u8, @intFromFloat(@round(a.g * 255.0))) == @as(u8, @intFromFloat(@round(b.g * 255.0))) and
            @as(u8, @intFromFloat(@round(a.b * 255.0))) == @as(u8, @intFromFloat(@round(b.b * 255.0)));
    }
};

// ============================================================================
// GayRng — splittable RNG for deterministic color generation
// ============================================================================

pub const GayRng = struct {
    root_seed: u64,
    state: u64,
    invocation: u64,

    pub fn init(seed: u64) GayRng {
        return .{
            .root_seed = seed,
            .state = splitmix64(seed),
            .invocation = 0,
        };
    }

    /// Split: advance state and return the new value
    pub fn split(self: *GayRng) u64 {
        self.state = splitmix64(self.state);
        self.invocation += 1;
        return self.state;
    }

    /// Generate next color from current state
    pub fn nextColor(self: *GayRng) Color {
        const val = self.split();
        return colorFromU64(val);
    }

    /// Fill buffer with n deterministic colors
    pub fn nextColors(self: *GayRng, n: usize, buf: []Color) void {
        const count = @min(n, buf.len);
        for (0..count) |i| {
            buf[i] = self.nextColor();
        }
    }
};

// ============================================================================
// Core color extraction from 64-bit value
// ============================================================================

pub fn colorFromU64(val: u64) Color {
    // Split 64 bits into 3 segments: bits [0..21], [21..42], [42..63]
    const mask21: u64 = (1 << 21) - 1;
    const r_raw = val & mask21;
    const g_raw = (val >> 21) & mask21;
    const b_raw = (val >> 42) & mask21;
    const scale = 1.0 / @as(f64, @floatFromInt(mask21));
    return .{
        .r = @as(f64, @floatFromInt(r_raw)) * scale,
        .g = @as(f64, @floatFromInt(g_raw)) * scale,
        .b = @as(f64, @floatFromInt(b_raw)) * scale,
    };
}

// ============================================================================
// Deterministic indexed access
// ============================================================================

/// Apply splitmix64 (index + seed) times to seed, extract color from final value
pub fn colorAt(index: u64, seed: u64) Color {
    var state = seed;
    const iterations = index +% seed;
    var i: u64 = 0;
    while (i < iterations) : (i += 1) {
        state = splitmix64(state);
    }
    return colorFromU64(state);
}

// ============================================================================
// HSL helpers for parallel fork bridge
// ============================================================================

/// Golden angle (137.508 deg) hue distribution
pub fn computeHue(seed: u64, index: u64) f64 {
    const golden_angle = 137.50776405003785; // degrees
    const base = @as(f64, @floatFromInt(splitmix64(seed) & 0xFFFF)) / 65535.0 * 360.0;
    const offset = @as(f64, @floatFromInt(index)) * golden_angle;
    return @mod(base + offset, 360.0);
}

/// Saturation from seed+iteration, range [0.5, 1.0]
pub fn computeSaturation(seed: u64, iteration: u64) f64 {
    const mixed = splitmix64(seed +% iteration);
    const raw = @as(f64, @floatFromInt(mixed & 0xFFFF)) / 65535.0;
    return 0.5 + raw * 0.5;
}

/// Lightness from seed+depth, range [0.35, 0.65]
pub fn computeLightness(seed: u64, depth: u64) f64 {
    const mixed = splitmix64(seed ^ depth);
    const raw = @as(f64, @floatFromInt(mixed & 0xFFFF)) / 65535.0;
    return 0.35 + raw * 0.3;
}

/// HSL to RGB conversion (h in [0,360], s,l in [0,1])
pub fn hslToRgb(h: f64, s: f64, l: f64) Color {
    if (s == 0.0) {
        return .{ .r = l, .g = l, .b = l };
    }
    const q = if (l < 0.5) l * (1.0 + s) else l + s - l * s;
    const p = 2.0 * l - q;
    const h_norm = h / 360.0;
    return .{
        .r = hueToRgb(p, q, h_norm + 1.0 / 3.0),
        .g = hueToRgb(p, q, h_norm),
        .b = hueToRgb(p, q, h_norm - 1.0 / 3.0),
    };
}

fn hueToRgb(p: f64, q: f64, t_in: f64) f64 {
    var t = t_in;
    if (t < 0.0) t += 1.0;
    if (t > 1.0) t -= 1.0;
    if (t < 1.0 / 6.0) return p + (q - p) * 6.0 * t;
    if (t < 1.0 / 2.0) return q;
    if (t < 2.0 / 3.0) return p + (q - p) * (2.0 / 3.0 - t) * 6.0;
    return p;
}

// ============================================================================
// Genesis verification — seed=1069 canonical colors
// ============================================================================

pub const GenesisColor = struct {
    index: u8,
    hex: [7]u8,
    trit: i2, // GF(3): -1, 0, +1
};

pub const GENESIS_COLORS = [12]GenesisColor{
    .{ .index = 1, .hex = "#3EEA93".*, .trit = 0 },
    .{ .index = 2, .hex = "#5435E4".*, .trit = -1 },
    .{ .index = 3, .hex = "#69F034".*, .trit = 0 },
    .{ .index = 4, .hex = "#1443D8".*, .trit = -1 },
    .{ .index = 5, .hex = "#74F641".*, .trit = 0 },
    .{ .index = 6, .hex = "#5E7E0A".*, .trit = 0 },
    .{ .index = 7, .hex = "#3A25AB".*, .trit = -1 },
    .{ .index = 8, .hex = "#D7CAA1".*, .trit = 1 },
    .{ .index = 9, .hex = "#23D79A".*, .trit = 0 },
    .{ .index = 10, .hex = "#1CF5E4".*, .trit = 1 },
    .{ .index = 11, .hex = "#FE8F8D".*, .trit = 1 },
    .{ .index = 12, .hex = "#04F171".*, .trit = 0 },
};

/// Verify that seed=1069 produces the canonical genesis chain
pub fn verifyGenesisChain() bool {
    var rng = GayRng.init(GAY_SEED);
    for (&GENESIS_COLORS) |gc| {
        const color = rng.nextColor();
        const hex = color.toHex();
        if (!std.mem.eql(u8, &hex, &gc.hex)) return false;
    }
    // Verify GF(3) conservation: trit sum = 0 (mod 3)
    var trit_sum: i32 = 0;
    for (&GENESIS_COLORS) |gc| {
        trit_sum += @as(i32, gc.trit);
    }
    if (@mod(trit_sum, 3) != 0) return false;
    return true;
}

// ============================================================================
// Parallel fork
// ============================================================================

/// Derive a fork seed from an index (for parallel color generation)
pub fn parallelForkSeed(index: u64) u64 {
    return splitmix64(GAY_SEED ^ index) ^ splitmix64(index);
}

/// Generate a color from a parallel fork at the given index
pub fn colorFromParallelFork(index: u64) Color {
    const fork_seed = parallelForkSeed(index);
    const h = computeHue(fork_seed, index);
    const s = computeSaturation(fork_seed, index);
    const l = computeLightness(fork_seed, index);
    return hslToRgb(h, s, l);
}

// ============================================================================
// Tests
// ============================================================================

test "splitmix64 basic" {
    // Bijection: different inputs -> different outputs
    const a = splitmix64(0);
    const b = splitmix64(1);
    const c = splitmix64(GAY_SEED);
    try std.testing.expect(a != b);
    try std.testing.expect(b != c);
    try std.testing.expect(a != c);
    // Not identity
    try std.testing.expect(a != 0);
}

test "splitmix64 deterministic" {
    try std.testing.expectEqual(splitmix64(42), splitmix64(42));
    try std.testing.expectEqual(splitmix64(GAY_SEED), splitmix64(GAY_SEED));
}

test "GayRng determinism" {
    var rng1 = GayRng.init(GAY_SEED);
    var rng2 = GayRng.init(GAY_SEED);
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        const c1 = rng1.nextColor();
        const c2 = rng2.nextColor();
        try std.testing.expect(Color.eql(c1, c2));
    }
}

test "GayRng split advances state" {
    var rng = GayRng.init(GAY_SEED);
    const s0 = rng.state;
    _ = rng.split();
    try std.testing.expect(rng.state != s0);
    try std.testing.expectEqual(rng.invocation, 1);
}

test "Color toHex roundtrip" {
    const c = Color{ .r = 1.0, .g = 0.0, .b = 0.5019607843137255 };
    const hex = c.toHex();
    try std.testing.expectEqualSlices(u8, "#FF0080", &hex);
}

test "Color mix" {
    const black = Color{ .r = 0, .g = 0, .b = 0 };
    const white = Color{ .r = 1, .g = 1, .b = 1 };
    const mid = Color.mix(black, white, 0.5);
    try std.testing.expectApproxEqAbs(mid.r, 0.5, 0.01);
    try std.testing.expectApproxEqAbs(mid.g, 0.5, 0.01);
    try std.testing.expectApproxEqAbs(mid.b, 0.5, 0.01);
}

test "Color complement" {
    const c = Color{ .r = 0.2, .g = 0.4, .b = 0.8 };
    const comp = c.complement();
    try std.testing.expectApproxEqAbs(comp.r, 0.8, 0.001);
    try std.testing.expectApproxEqAbs(comp.g, 0.6, 0.001);
    try std.testing.expectApproxEqAbs(comp.b, 0.2, 0.001);
}

test "genesis chain verification" {
    try std.testing.expect(verifyGenesisChain());
}

test "genesis GF(3) conservation" {
    var trit_sum: i32 = 0;
    for (&GENESIS_COLORS) |gc| {
        trit_sum += @as(i32, gc.trit);
    }
    // Sum: 0-1+0-1+0+0-1+1+0+1+1+0 = 0  => GF(3) balanced
    try std.testing.expectEqual(@as(i32, 0), @mod(trit_sum, 3));
}

test "genesis first color hex" {
    var rng = GayRng.init(GAY_SEED);
    const c = rng.nextColor();
    const hex = c.toHex();
    try std.testing.expectEqualSlices(u8, "#3EEA93", &hex);
}

test "colorAt deterministic" {
    const c1 = colorAt(5, GAY_SEED);
    const c2 = colorAt(5, GAY_SEED);
    try std.testing.expect(Color.eql(c1, c2));
}

test "hslToRgb pure red" {
    const c = hslToRgb(0, 1.0, 0.5);
    try std.testing.expectApproxEqAbs(c.r, 1.0, 0.01);
    try std.testing.expectApproxEqAbs(c.g, 0.0, 0.01);
    try std.testing.expectApproxEqAbs(c.b, 0.0, 0.01);
}

test "hslToRgb achromatic" {
    const c = hslToRgb(180, 0.0, 0.5);
    try std.testing.expectApproxEqAbs(c.r, 0.5, 0.001);
    try std.testing.expectApproxEqAbs(c.g, 0.5, 0.001);
    try std.testing.expectApproxEqAbs(c.b, 0.5, 0.001);
}

test "computeHue golden angle spacing" {
    const h0 = computeHue(GAY_SEED, 0);
    const h1 = computeHue(GAY_SEED, 1);
    const diff = @mod(h1 - h0 + 360.0, 360.0);
    // Should be approximately the golden angle
    try std.testing.expectApproxEqAbs(diff, 137.508, 0.01);
}

test "parallelForkSeed distinct" {
    const s0 = parallelForkSeed(0);
    const s1 = parallelForkSeed(1);
    const s2 = parallelForkSeed(2);
    try std.testing.expect(s0 != s1);
    try std.testing.expect(s1 != s2);
}

test "colorFromParallelFork valid range" {
    var i: u64 = 0;
    while (i < 50) : (i += 1) {
        const c = colorFromParallelFork(i);
        try std.testing.expect(c.r >= 0.0 and c.r <= 1.0);
        try std.testing.expect(c.g >= 0.0 and c.g <= 1.0);
        try std.testing.expect(c.b >= 0.0 and c.b <= 1.0);
    }
}

test "nextColors fills buffer" {
    var rng = GayRng.init(GAY_SEED);
    var buf: [5]Color = undefined;
    rng.nextColors(5, &buf);
    // First should match genesis color 1
    const hex = buf[0].toHex();
    try std.testing.expectEqualSlices(u8, "#3EEA93", &hex);
}
