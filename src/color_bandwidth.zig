//! Color Bandwidth Test — Perceptual channel capacity measurement
//!
//! Implements the PerceptualColourMaps.jl / Gay.jl protocol:
//! every interaction tests color distinguishability at three checkpoints:
//!   1. FIRST  — opening color (gamut check, contrast against background)
//!   2. LAST   — closing color (drift/collapse detection)
//!   3. RANDOM — spot-check at a random index (uniform sampling)
//!
//! Based on:
//!   - Peter Kovesi, PerceptualColourMaps.jl: arc length in CIELAB ≈ perceptual difference
//!   - Gay.jl: SplitMix64 deterministic color generation
//!   - Nørretranders: 11M bits/sec → 40 bits/sec (the User Illusion)
//!     The color channel bandwidth IS those 40 bits — what survives perceptual filtering
//!
//! The "positionally dependent noise → color" distillation:
//!   atmospheric noise at a geographic position + temporal seed → SplitMix64 →
//!   deterministic hue → CIELAB perceptual distance → bandwidth in bits
//!
//! Usage: call `testBandwidth(seed, n_colors)` to get a BandwidthReport with
//! per-checkpoint Delta-E values and estimated channel capacity.

const std = @import("std");
const math = std.math;

// =============================================================================
// SplitMix64 (matches Gay.jl / wgpu_compute.zig)
// =============================================================================

const GOLDEN_GAMMA: u64 = 0x9e3779b97f4a7c15;
const MIX_C1: u64 = 0xbf58476d1ce4e5b9;
const MIX_C2: u64 = 0x94d049bb133111eb;

pub fn splitmix64(seed: u64, index: u64) u64 {
    const state = seed +% (GOLDEN_GAMMA *% index);
    var z = state;
    z = (z ^ (z >> 30)) *% MIX_C1;
    z = (z ^ (z >> 27)) *% MIX_C2;
    z = z ^ (z >> 31);
    return z;
}

// =============================================================================
// CIELAB Color Space (perceptually uniform)
// =============================================================================

pub const Lab = struct {
    l: f32, // Lightness [0, 100]
    a: f32, // Green(-) to Red(+) [-128, 127]
    b: f32, // Blue(-) to Yellow(+) [-128, 127]
};

pub const RGB = struct {
    r: f32, // [0, 1]
    g: f32,
    b: f32,
};

/// Convert sRGB [0,1] to linear RGB
fn srgbToLinear(c: f32) f32 {
    if (c <= 0.04045) {
        return c / 12.92;
    }
    return math.pow(f32, (c + 0.055) / 1.055, 2.4);
}

/// Convert linear RGB to XYZ (D65 illuminant)
fn rgbToXyz(rgb: RGB) struct { x: f32, y: f32, z: f32 } {
    const r = srgbToLinear(rgb.r);
    const g = srgbToLinear(rgb.g);
    const b = srgbToLinear(rgb.b);
    return .{
        .x = 0.4124564 * r + 0.3575761 * g + 0.1804375 * b,
        .y = 0.2126729 * r + 0.7151522 * g + 0.0721750 * b,
        .z = 0.0193339 * r + 0.1191920 * g + 0.9503041 * b,
    };
}

fn labF(t: f32) f32 {
    const delta: f32 = 6.0 / 29.0;
    if (t > delta * delta * delta) {
        return math.cbrt(t);
    }
    return t / (3.0 * delta * delta) + 4.0 / 29.0;
}

/// Convert XYZ to CIELAB (D65 white point)
fn xyzToLab(x: f32, y: f32, z: f32) Lab {
    // D65 white point
    const xn: f32 = 0.95047;
    const yn: f32 = 1.00000;
    const zn: f32 = 1.08883;

    const fx = labF(x / xn);
    const fy = labF(y / yn);
    const fz = labF(z / zn);

    return .{
        .l = 116.0 * fy - 16.0,
        .a = 500.0 * (fx - fy),
        .b = 200.0 * (fy - fz),
    };
}

pub fn rgbToLab(rgb: RGB) Lab {
    const xyz = rgbToXyz(rgb);
    return xyzToLab(xyz.x, xyz.y, xyz.z);
}

// =============================================================================
// CIEDE2000 Delta-E (perceptual color difference)
// =============================================================================

/// CIEDE2000 perceptual color distance.
/// Delta-E < 1.0 is imperceptible to most observers.
/// Delta-E 1-2 is perceptible on close inspection.
/// Delta-E > 5 is clearly different.
/// Delta-E > 10 is a different color entirely.
pub fn ciede2000(lab1: Lab, lab2: Lab) f32 {
    const pi = math.pi;
    const l1 = lab1.l;
    const a1 = lab1.a;
    const b1 = lab1.b;
    const l2 = lab2.l;
    const a2 = lab2.a;
    const b2 = lab2.b;

    // Step 1: Calculate C'ab, h'ab
    const c1_ab = @sqrt(a1 * a1 + b1 * b1);
    const c2_ab = @sqrt(a2 * a2 + b2 * b2);
    const c_ab_mean = (c1_ab + c2_ab) / 2.0;

    const c_ab_mean_pow7 = math.pow(f32, c_ab_mean, 7.0);
    const g = 0.5 * (1.0 - @sqrt(c_ab_mean_pow7 / (c_ab_mean_pow7 + math.pow(f32, 25.0, 7.0))));

    const a1_prime = a1 * (1.0 + g);
    const a2_prime = a2 * (1.0 + g);

    const c1_prime = @sqrt(a1_prime * a1_prime + b1 * b1);
    const c2_prime = @sqrt(a2_prime * a2_prime + b2 * b2);

    var h1_prime = math.atan2(b1, a1_prime) * 180.0 / pi;
    if (h1_prime < 0) h1_prime += 360.0;
    var h2_prime = math.atan2(b2, a2_prime) * 180.0 / pi;
    if (h2_prime < 0) h2_prime += 360.0;

    // Step 2: Calculate Delta L', Delta C', Delta H'
    const delta_l_prime = l2 - l1;
    const delta_c_prime = c2_prime - c1_prime;

    var delta_h_prime: f32 = undefined;
    if (c1_prime * c2_prime == 0) {
        delta_h_prime = 0;
    } else {
        var dh = h2_prime - h1_prime;
        if (dh > 180.0) dh -= 360.0;
        if (dh < -180.0) dh += 360.0;
        delta_h_prime = 2.0 * @sqrt(c1_prime * c2_prime) * @sin(dh * pi / 360.0);
    }

    // Step 3: Calculate CIEDE2000 weighting functions
    const l_prime_mean = (l1 + l2) / 2.0;
    const c_prime_mean = (c1_prime + c2_prime) / 2.0;

    var h_prime_mean: f32 = undefined;
    if (c1_prime * c2_prime == 0) {
        h_prime_mean = h1_prime + h2_prime;
    } else if (@abs(h1_prime - h2_prime) <= 180.0) {
        h_prime_mean = (h1_prime + h2_prime) / 2.0;
    } else if (h1_prime + h2_prime < 360.0) {
        h_prime_mean = (h1_prime + h2_prime + 360.0) / 2.0;
    } else {
        h_prime_mean = (h1_prime + h2_prime - 360.0) / 2.0;
    }

    const t = 1.0 -
        0.17 * @cos((h_prime_mean - 30.0) * pi / 180.0) +
        0.24 * @cos(2.0 * h_prime_mean * pi / 180.0) +
        0.32 * @cos((3.0 * h_prime_mean + 6.0) * pi / 180.0) -
        0.20 * @cos((4.0 * h_prime_mean - 63.0) * pi / 180.0);

    const l_mean_50_sq = (l_prime_mean - 50.0) * (l_prime_mean - 50.0);
    const sl = 1.0 + 0.015 * l_mean_50_sq / @sqrt(20.0 + l_mean_50_sq);
    const sc = 1.0 + 0.045 * c_prime_mean;
    const sh = 1.0 + 0.015 * c_prime_mean * t;

    const c_prime_mean_pow7 = math.pow(f32, c_prime_mean, 7.0);
    const rt = -2.0 * @sqrt(c_prime_mean_pow7 / (c_prime_mean_pow7 + math.pow(f32, 25.0, 7.0))) *
        @sin(60.0 * @exp(-((h_prime_mean - 275.0) / 25.0) * ((h_prime_mean - 275.0) / 25.0)) * pi / 180.0);

    const de = @sqrt(
        (delta_l_prime / sl) * (delta_l_prime / sl) +
            (delta_c_prime / sc) * (delta_c_prime / sc) +
            (delta_h_prime / sh) * (delta_h_prime / sh) +
            rt * (delta_c_prime / sc) * (delta_h_prime / sh),
    );

    return de;
}

// =============================================================================
// SplitMix64 → RGB color generation (matches Gay.jl)
// =============================================================================

pub fn seedToRgb(seed: u64, index: u64) RGB {
    const val = splitmix64(seed, index);
    // Extract 10 bits each for H, S, L (matches Gay.jl perceptual distribution)
    const h_raw = @as(f32, @floatFromInt((val >> 0) & 0x3FF)) / 1023.0; // [0, 1]
    const s_raw = @as(f32, @floatFromInt((val >> 10) & 0x3FF)) / 1023.0;
    const l_raw = @as(f32, @floatFromInt((val >> 20) & 0x3FF)) / 1023.0;

    // Perceptual mapping: constrain S and L for distinguishability
    const h = h_raw * 360.0;
    const s = 0.4 + s_raw * 0.5; // [0.4, 0.9] — avoid grays
    const l = 0.3 + l_raw * 0.4; // [0.3, 0.7] — avoid too dark/light

    return hslToRgb(h, s, l);
}

fn hslToRgb(h: f32, s: f32, l: f32) RGB {
    if (s == 0) return .{ .r = l, .g = l, .b = l };

    const q = if (l < 0.5) l * (1.0 + s) else l + s - l * s;
    const p = 2.0 * l - q;
    const h_norm = @mod(h, 360.0) / 360.0;

    return .{
        .r = hueToRgb(p, q, h_norm + 1.0 / 3.0),
        .g = hueToRgb(p, q, h_norm),
        .b = hueToRgb(p, q, h_norm - 1.0 / 3.0),
    };
}

fn hueToRgb(p: f32, q: f32, t_in: f32) f32 {
    var t = t_in;
    if (t < 0) t += 1;
    if (t > 1) t -= 1;
    if (t < 1.0 / 6.0) return p + (q - p) * 6.0 * t;
    if (t < 1.0 / 2.0) return q;
    if (t < 2.0 / 3.0) return p + (q - p) * (2.0 / 3.0 - t) * 6.0;
    return p;
}

// =============================================================================
// Bandwidth Report
// =============================================================================

pub const Checkpoint = struct {
    index: u64,
    rgb: RGB,
    lab: Lab,
    delta_e_to_prev: f32, // CIEDE2000 to previous color in sequence
    delta_e_to_next: f32, // CIEDE2000 to next color in sequence
    in_gamut: bool, // sRGB gamut check
    above_jnd: bool, // Above just-noticeable difference (Delta-E > 1.0)
};

pub const BandwidthReport = struct {
    seed: u64,
    n_colors: u64,

    // The three checkpoints
    first: Checkpoint,
    last: Checkpoint,
    random: Checkpoint,

    // Global stats
    min_delta_e: f32, // Minimum perceptual distance in sequence
    mean_delta_e: f32, // Mean perceptual distance between adjacent pairs
    max_delta_e: f32, // Maximum perceptual distance
    estimated_bits: f32, // log2(gamut_volume / min_distinguishable_volume)
    bandwidth_ok: bool, // All three checkpoints pass JND threshold

    pub fn format(self: BandwidthReport, buf: []u8) ![]const u8 {
        return try std.fmt.bufPrint(buf,
            \\ColorBandwidth(seed={x}, n={d})
            \\  first[{d}]:  dE={d:.2} {s}
            \\  last[{d}]:   dE={d:.2} {s}
            \\  random[{d}]: dE={d:.2} {s}
            \\  min_dE={d:.2} mean_dE={d:.2} max_dE={d:.2}
            \\  capacity={d:.1} bits  {s}
        , .{
            self.seed,
            self.n_colors,
            self.first.index,
            self.first.delta_e_to_next,
            if (self.first.above_jnd) "OK" else "FAIL",
            self.last.index,
            self.last.delta_e_to_prev,
            if (self.last.above_jnd) "OK" else "FAIL",
            self.random.index,
            @max(self.random.delta_e_to_prev, self.random.delta_e_to_next),
            if (self.random.above_jnd) "OK" else "FAIL",
            self.min_delta_e,
            self.mean_delta_e,
            self.max_delta_e,
            self.estimated_bits,
            if (self.bandwidth_ok) "PASS" else "FAIL",
        });
    }
};

// =============================================================================
// Core Test Function
// =============================================================================

/// JND (Just Noticeable Difference) threshold in Delta-E units.
/// 1.0 is the standard perceptual threshold (Mahy et al. 1994).
/// Kovesi uses 2.0 for "clearly different" in PerceptualColourMaps.jl.
pub const JND_THRESHOLD: f32 = 1.0;

/// Test color bandwidth for a seed over n_colors.
/// The random checkpoint uses the seed itself to pick the index (deterministic).
pub fn testBandwidth(seed: u64, n_colors: u64) BandwidthReport {
    if (n_colors < 3) {
        return zeroBandwidth(seed, n_colors);
    }

    // Deterministic random index: use seed to pick a middle index
    const random_idx = 1 + (splitmix64(seed, seed) % (n_colors - 2));

    // Generate colors at the three checkpoints and their neighbors
    const first_rgb = seedToRgb(seed, 0);
    const first_next_rgb = seedToRgb(seed, 1);
    const first_lab = rgbToLab(first_rgb);
    const first_next_lab = rgbToLab(first_next_rgb);
    const first_de = ciede2000(first_lab, first_next_lab);

    const last_rgb = seedToRgb(seed, n_colors - 1);
    const last_prev_rgb = seedToRgb(seed, n_colors - 2);
    const last_lab = rgbToLab(last_rgb);
    const last_prev_lab = rgbToLab(last_prev_rgb);
    const last_de = ciede2000(last_prev_lab, last_lab);

    const rand_rgb = seedToRgb(seed, random_idx);
    const rand_prev_rgb = seedToRgb(seed, random_idx - 1);
    const rand_next_rgb = seedToRgb(seed, random_idx + 1);
    const rand_lab = rgbToLab(rand_rgb);
    const rand_prev_lab = rgbToLab(rand_prev_rgb);
    const rand_next_lab = rgbToLab(rand_next_rgb);
    const rand_de_prev = ciede2000(rand_prev_lab, rand_lab);
    const rand_de_next = ciede2000(rand_lab, rand_next_lab);

    // Scan all adjacent pairs for global stats (cap scan at 1024 for performance)
    const scan_limit = @min(n_colors, 1024);
    var min_de: f32 = math.floatMax(f32);
    var max_de: f32 = 0;
    var sum_de: f32 = 0;
    var prev_lab = rgbToLab(seedToRgb(seed, 0));

    for (1..scan_limit) |i| {
        const cur_lab = rgbToLab(seedToRgb(seed, @intCast(i)));
        const de = ciede2000(prev_lab, cur_lab);
        if (de < min_de) min_de = de;
        if (de > max_de) max_de = de;
        sum_de += de;
        prev_lab = cur_lab;
    }

    const mean_de = if (scan_limit > 1) sum_de / @as(f32, @floatFromInt(scan_limit - 1)) else 0;

    // Estimate channel capacity in bits
    // Gamut volume in CIELAB ≈ 800,000 cubic units (sRGB)
    // Minimum distinguishable sphere volume = (4/3)π(min_dE/2)³
    // Capacity ≈ log2(gamut_volume / sphere_volume)
    const estimated_bits = if (min_de > 0.01) blk: {
        const sphere_vol = (4.0 / 3.0) * math.pi * math.pow(f32, min_de / 2.0, 3.0);
        const gamut_vol: f32 = 800_000.0;
        break :blk @log2(gamut_vol / sphere_vol);
    } else @as(f32, 0);

    const first_ok = first_de >= JND_THRESHOLD;
    const last_ok = last_de >= JND_THRESHOLD;
    const rand_ok = @max(rand_de_prev, rand_de_next) >= JND_THRESHOLD;

    return .{
        .seed = seed,
        .n_colors = n_colors,
        .first = .{
            .index = 0,
            .rgb = first_rgb,
            .lab = first_lab,
            .delta_e_to_prev = 0,
            .delta_e_to_next = first_de,
            .in_gamut = inGamut(first_rgb),
            .above_jnd = first_ok,
        },
        .last = .{
            .index = n_colors - 1,
            .rgb = last_rgb,
            .lab = last_lab,
            .delta_e_to_prev = last_de,
            .delta_e_to_next = 0,
            .in_gamut = inGamut(last_rgb),
            .above_jnd = last_ok,
        },
        .random = .{
            .index = random_idx,
            .rgb = rand_rgb,
            .lab = rand_lab,
            .delta_e_to_prev = rand_de_prev,
            .delta_e_to_next = rand_de_next,
            .in_gamut = inGamut(rand_rgb),
            .above_jnd = rand_ok,
        },
        .min_delta_e = min_de,
        .mean_delta_e = mean_de,
        .max_delta_e = max_de,
        .estimated_bits = estimated_bits,
        .bandwidth_ok = first_ok and last_ok and rand_ok,
    };
}

fn inGamut(rgb: RGB) bool {
    return rgb.r >= 0 and rgb.r <= 1 and
        rgb.g >= 0 and rgb.g <= 1 and
        rgb.b >= 0 and rgb.b <= 1;
}

fn zeroBandwidth(seed: u64, n: u64) BandwidthReport {
    const rgb = seedToRgb(seed, 0);
    const lab = rgbToLab(rgb);
    const cp = Checkpoint{
        .index = 0,
        .rgb = rgb,
        .lab = lab,
        .delta_e_to_prev = 0,
        .delta_e_to_next = 0,
        .in_gamut = inGamut(rgb),
        .above_jnd = false,
    };
    return .{
        .seed = seed,
        .n_colors = n,
        .first = cp,
        .last = cp,
        .random = cp,
        .min_delta_e = 0,
        .mean_delta_e = 0,
        .max_delta_e = 0,
        .estimated_bits = 0,
        .bandwidth_ok = false,
    };
}

// =============================================================================
// Spectral attenuation: graph expansion bounds perceptual capacity
// =============================================================================

/// Effective bandwidth = perceptual capacity * spectral gap.
///
/// The spectral gap of the interaction graph determines what fraction of
/// perceptual channel capacity actually propagates across the network.
///   gap ~ 1.0 (Ramanujan): full capacity propagates (optimal mixing)
///   gap ~ 0.0 (localized): capacity collapses (disconnected subgroups)
///
/// This is the bridge between color_bandwidth (local measurement) and
/// spectral_tensor/zeta (global graph property). It is scale-invariant:
/// the same formula applies whether nodes are neurons, agents, or orgs.
///
/// Returns attenuated bits. The trit of the result encodes trust bandwidth:
///   PLUS  (+1): high trust bandwidth (> 15 effective bits)
///   ERGODIC (0): moderate (5-15 bits)
///   MINUS (-1): trust breakdown (< 5 bits)
pub fn effectiveBandwidth(report: BandwidthReport, spectral_gap: f32) f32 {
    const clamped_gap = @min(@as(f32, 1.0), @max(@as(f32, 0.0), spectral_gap));
    return report.estimated_bits * clamped_gap;
}

/// Compose a BandwidthReport with a spectral gap into an effective report.
/// Preserves all checkpoint data but scales estimated_bits by the gap.
pub fn attenuateBySpectralGap(report: BandwidthReport, spectral_gap: f32) BandwidthReport {
    var result = report;
    result.estimated_bits = effectiveBandwidth(report, spectral_gap);
    result.bandwidth_ok = result.estimated_bits >= 5.0 and
        report.first.above_jnd and report.last.above_jnd and report.random.above_jnd;
    return result;
}

// =============================================================================
// Sweep bandwidth: parallel task coloring with spectral gap validation
// =============================================================================

/// Measures whether N parallel sweeps are perceptually distinguishable.
/// Each sweep gets a deterministic color from the same seed. The spectral
/// gap encodes task orthogonality: independent sweeps have gap ~1, coupled
/// sweeps degrade toward 0.
///
/// This is the concrete instantiation of effectiveBandwidth for parallel
/// task dispatch (e.g., 11 CatColab discovery sweeps color-tagged via
/// splitmix64 with Gay MCP).
///
/// Returns: effective bits after spectral gap attenuation, plus the trit.
pub const SweepBandwidth = struct {
    n_sweeps: u64,
    raw_bits: f32,
    spectral_gap: f32,
    effective_bits: f32,
    trit: i2,
    all_distinguishable: bool,
};

pub fn sweepBandwidth(seed: u64, n_sweeps: u64, spectral_gap: f32) SweepBandwidth {
    const report = testBandwidth(seed, n_sweeps);
    const attenuated = attenuateBySpectralGap(report, spectral_gap);
    return .{
        .n_sweeps = n_sweeps,
        .raw_bits = report.estimated_bits,
        .spectral_gap = @min(@as(f32, 1.0), @max(@as(f32, 0.0), spectral_gap)),
        .effective_bits = attenuated.estimated_bits,
        .trit = bandwidthTrit(attenuated),
        .all_distinguishable = report.first.above_jnd and
            report.last.above_jnd and report.random.above_jnd,
    };
}

// =============================================================================
// Interaction wrapper: test bandwidth and return pass/fail trit
// =============================================================================

/// GF(3) trit for bandwidth quality.
///   PLUS  (+1): all checkpoints pass, high capacity (> 15 bits)
///   ERGODIC (0): partial pass or moderate capacity (5-15 bits)
///   MINUS (-1): bandwidth failure (< 5 bits or any checkpoint fails JND)
pub fn bandwidthTrit(report: BandwidthReport) i2 {
    if (report.bandwidth_ok and report.estimated_bits > 15.0) return 1;
    if (!report.bandwidth_ok or report.estimated_bits < 5.0) return -1;
    return 0;
}

// =============================================================================
// Tests
// =============================================================================

test "CIEDE2000 identical colors" {
    const lab = Lab{ .l = 50, .a = 25, .b = -10 };
    const de = ciede2000(lab, lab);
    try std.testing.expectApproxEqAbs(@as(f32, 0), de, 0.001);
}

test "CIEDE2000 clearly different colors" {
    const red_lab = rgbToLab(.{ .r = 1, .g = 0, .b = 0 });
    const green_lab = rgbToLab(.{ .r = 0, .g = 1, .b = 0 });
    const de = ciede2000(red_lab, green_lab);
    // Red vs green should be very different (Delta-E > 50)
    try std.testing.expect(de > 40);
}

test "CIEDE2000 subtle difference" {
    const c1 = rgbToLab(.{ .r = 0.5, .g = 0.5, .b = 0.5 });
    const c2 = rgbToLab(.{ .r = 0.51, .g = 0.5, .b = 0.5 });
    const de = ciede2000(c1, c2);
    // Very subtle: should be small but nonzero
    try std.testing.expect(de > 0);
    try std.testing.expect(de < 5);
}

test "seedToRgb in gamut" {
    // Test 100 seed/index combos all produce in-gamut RGB
    for (0..100) |i| {
        const rgb = seedToRgb(42, @intCast(i));
        try std.testing.expect(rgb.r >= 0 and rgb.r <= 1);
        try std.testing.expect(rgb.g >= 0 and rgb.g <= 1);
        try std.testing.expect(rgb.b >= 0 and rgb.b <= 1);
    }
}

test "testBandwidth basic" {
    const report = testBandwidth(12345, 100);
    // SplitMix64 with constrained HSL should produce distinguishable colors
    try std.testing.expect(report.min_delta_e > 0);
    try std.testing.expect(report.mean_delta_e > 0);
    try std.testing.expect(report.estimated_bits > 0);
    try std.testing.expect(report.first.in_gamut);
    try std.testing.expect(report.last.in_gamut);
    try std.testing.expect(report.random.in_gamut);
}

test "testBandwidth deterministic" {
    const r1 = testBandwidth(99999, 50);
    const r2 = testBandwidth(99999, 50);
    // Same seed, same n_colors => identical reports
    try std.testing.expectEqual(r1.first.index, r2.first.index);
    try std.testing.expectEqual(r1.last.index, r2.last.index);
    try std.testing.expectEqual(r1.random.index, r2.random.index);
    try std.testing.expectApproxEqAbs(r1.min_delta_e, r2.min_delta_e, 0.0001);
    try std.testing.expectApproxEqAbs(r1.estimated_bits, r2.estimated_bits, 0.0001);
}

test "testBandwidth different seeds differ" {
    const r1 = testBandwidth(1, 100);
    const r2 = testBandwidth(2, 100);
    // Different seeds should (almost certainly) produce different random checkpoints
    try std.testing.expect(r1.random.index != r2.random.index or
        r1.first.rgb.r != r2.first.rgb.r);
}

test "bandwidthTrit mapping" {
    // High bandwidth
    var good = testBandwidth(42, 100);
    good.bandwidth_ok = true;
    good.estimated_bits = 20;
    try std.testing.expectEqual(@as(i2, 1), bandwidthTrit(good));

    // Low bandwidth
    var bad = testBandwidth(42, 100);
    bad.bandwidth_ok = false;
    bad.estimated_bits = 2;
    try std.testing.expectEqual(@as(i2, -1), bandwidthTrit(bad));

    // Moderate bandwidth
    var mid = testBandwidth(42, 100);
    mid.bandwidth_ok = true;
    mid.estimated_bits = 10;
    try std.testing.expectEqual(@as(i2, 0), bandwidthTrit(mid));
}

test "CIEDE2000 magenta has no wavelength" {
    // Magenta (L-cone + S-cone, no M-cone) vs pure red vs pure blue
    const magenta_lab = rgbToLab(.{ .r = 1.0, .g = 0.0, .b = 1.0 });
    const red_lab = rgbToLab(.{ .r = 1.0, .g = 0.0, .b = 0.0 });
    const blue_lab = rgbToLab(.{ .r = 0.0, .g = 0.0, .b = 1.0 });

    const de_red = ciede2000(magenta_lab, red_lab);
    const de_blue = ciede2000(magenta_lab, blue_lab);

    // Magenta is perceptually between red and blue but distinct from both
    try std.testing.expect(de_red > 10);
    try std.testing.expect(de_blue > 10);
}

test "first-last-random all tested" {
    // The core protocol: every interaction MUST test all three checkpoints
    const report = testBandwidth(7777, 200);

    // First is always index 0
    try std.testing.expectEqual(@as(u64, 0), report.first.index);
    // Last is always n-1
    try std.testing.expectEqual(@as(u64, 199), report.last.index);
    // Random is somewhere in between
    try std.testing.expect(report.random.index > 0);
    try std.testing.expect(report.random.index < 199);

    // All three have valid Delta-E measurements
    try std.testing.expect(report.first.delta_e_to_next >= 0);
    try std.testing.expect(report.last.delta_e_to_prev >= 0);
    try std.testing.expect(report.random.delta_e_to_prev >= 0);
    try std.testing.expect(report.random.delta_e_to_next >= 0);
}

test "spectral attenuation: Ramanujan preserves capacity" {
    const report = testBandwidth(42, 100);
    const full = effectiveBandwidth(report, 1.0);
    try std.testing.expectApproxEqAbs(report.estimated_bits, full, 0.001);
}

test "spectral attenuation: zero gap kills capacity" {
    const report = testBandwidth(42, 100);
    const dead = effectiveBandwidth(report, 0.0);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), dead, 0.001);
}

test "spectral attenuation: half gap halves capacity" {
    const report = testBandwidth(42, 100);
    const half = effectiveBandwidth(report, 0.5);
    try std.testing.expectApproxEqAbs(report.estimated_bits * 0.5, half, 0.001);
}

test "spectral attenuation: trit degrades with closing gap" {
    const report = testBandwidth(42, 100);
    // Full gap: should be high bandwidth
    const full_trit = bandwidthTrit(attenuateBySpectralGap(report, 1.0));
    // Tiny gap: should be low bandwidth
    const low_trit = bandwidthTrit(attenuateBySpectralGap(report, 0.05));
    try std.testing.expect(full_trit >= low_trit);
}

test "sweep bandwidth: 11 orthogonal CatColab sweeps" {
    // Concrete scenario: 11 parallel discovery sweeps, nearly independent tasks.
    // Spectral gap ~0.92 (high orthogonality, minor coupling through shared backend).
    // Seed from drand beacon (truncated for test): 142242816565714880 mod 2^32.
    const seed: u64 = 142242816565714880 & 0xFFFFFFFF;
    const sw = sweepBandwidth(seed, 11, 0.92);

    // 11 sweeps should be distinguishable with splitmix64
    try std.testing.expect(sw.all_distinguishable);
    // Effective bits should be close to raw (gap ~1)
    try std.testing.expect(sw.effective_bits > sw.raw_bits * 0.85);
    // Trit should indicate at least moderate bandwidth
    try std.testing.expect(sw.trit >= 0);
}

test "sweep bandwidth: coupled sweeps degrade capacity" {
    // Same 11 sweeps but with tight coupling (gap ~0.15): tasks share state,
    // e.g., writing to the same database concurrently.
    const seed: u64 = 142242816565714880 & 0xFFFFFFFF;
    const coupled = sweepBandwidth(seed, 11, 0.15);
    const orthogonal = sweepBandwidth(seed, 11, 0.92);

    // Coupled effective bits must be strictly less
    try std.testing.expect(coupled.effective_bits < orthogonal.effective_bits);
    // Coupled trit should degrade
    try std.testing.expect(coupled.trit <= orthogonal.trit);
}
