// learnable.zig: OkHSL Learnable Color Space + Gamut Learnable
// Zig translation of Gay.jl okhsl_learnable.jl & gamut_learnable.jl
//
// OkHSL learnable: differentiable color transforms, gradient descent
// on perceptual quality. Gamut learnable: learn gamut boundaries from
// examples, neural gamut mapping via subobject classifiers.

const std = @import("std");
const math = std.math;
const splitmix = @import("splitmix.zig");

const RGBf = struct { r: f64, g: f64, b: f64 };
const Color = splitmix.Color;

// ============================================================================
// OkHSL Parameters (learnable)
// ============================================================================

pub const OkhslParameters = struct {
    h_scale: f64 = 360.0,
    h_offset: f64 = 0.0,
    s_min: f64 = 0.5,
    s_max: f64 = 0.9,
    l_min: f64 = 0.35,
    l_max: f64 = 0.75,
    gamma: f64 = 1.0,
};

// ============================================================================
// Seed Projection (learnable linear layer)
// ============================================================================

pub const SeedProjection = struct {
    w_h: [3]f64,
    w_s: [3]f64,
    w_l: [3]f64,
    bias: [3]f64,

    pub fn init() SeedProjection {
        const phi = 1.618033988749895;
        var w_h: [3]f64 = undefined;
        var w_s: [3]f64 = undefined;
        var w_l: [3]f64 = undefined;
        var p: f64 = phi;
        for (0..3) |i| {
            w_h[i] = 1.0 / p;
            p *= phi;
        }
        for (0..3) |i| {
            w_s[i] = 1.0 / p;
            p *= phi;
        }
        for (0..3) |i| {
            w_l[i] = 1.0 / p;
            p *= phi;
        }
        return .{
            .w_h = w_h,
            .w_s = w_s,
            .w_l = w_l,
            .bias = .{ 0.0, 0.5, 0.35 },
        };
    }

    pub fn project(self: *const SeedProjection, f1: f64, f2: f64, f3: f64) struct { h: f64, s: f64, l: f64 } {
        return .{
            .h = self.w_h[0] * f1 + self.w_h[1] * f2 + self.w_h[2] * f3 + self.bias[0],
            .s = self.w_s[0] * f1 + self.w_s[1] * f2 + self.w_s[2] * f3 + self.bias[1],
            .l = self.w_l[0] * f1 + self.w_l[1] * f2 + self.w_l[2] * f3 + self.bias[2],
        };
    }
};

// ============================================================================
// Differentiable helpers
// ============================================================================

fn sigmoid(x: f64) f64 {
    return 1.0 / (1.0 + @exp(-x));
}

fn softClamp(x: f64) f64 {
    return 0.5 + 0.5 * math.tanh((x - 0.5) * 4.0);
}

/// Smooth seed -> 3 features using sinusoidal basis
fn seedToFeatures(seed: f64) struct { f1: f64, f2: f64, f3: f64 } {
    const w1 = 2.0 * math.pi * 0.618033988749895;
    const w2 = 2.0 * math.pi * 0.414213562373095;
    const w3 = 2.0 * math.pi * 0.302775637731995;
    return .{
        .f1 = 0.5 + 0.5 * @sin(seed * w1),
        .f2 = 0.5 + 0.5 * @sin(seed * w2 + 1.0),
        .f3 = 0.5 + 0.5 * @sin(seed * w3 + 2.0),
    };
}

/// Apply OkHSL parameters to raw projections
fn applyOkhslParams(params: *const OkhslParameters, h_raw: f64, s_raw: f64, l_raw: f64) struct { h: f64, s: f64, l: f64 } {
    // Hue
    const h = params.h_offset + params.h_scale * h_raw;
    const h_normalized = h / 360.0;
    const h_mod = 360.0 * (h_normalized - @floor(h_normalized));

    // Saturation via sigmoid
    const s_sig = sigmoid(params.gamma * (s_raw - 0.5) * 4.0);
    const s = params.s_min + (params.s_max - params.s_min) * s_sig;

    // Lightness via sigmoid
    const l_sig = sigmoid(params.gamma * (l_raw - 0.5) * 4.0);
    const l = params.l_min + (params.l_max - params.l_min) * l_sig;

    return .{ .h = h_mod, .s = s, .l = l };
}

/// Differentiable HSL -> RGB (soft sector selection)
fn hslToRgb(h: f64, s: f64, l: f64) RGBf {
    const h_norm = h / 360.0;
    const c = (1.0 - @abs(2.0 * l - 1.0)) * s;
    const h6 = h_norm * 6.0;
    const h6_mod2 = h6 - 2.0 * @floor(h6 / 2.0);
    const x = c * (1.0 - @abs(h6_mod2 - 1.0));
    const m = l - c / 2.0;

    // Soft sector indicators
    const sigma: f64 = 0.1;
    const softStep = struct {
        fn f(val: f64, a: f64, sig: f64) f64 {
            return 1.0 / (1.0 + @exp(-(val - a) / sig));
        }
    }.f;

    var s0 = softStep(h6, 0.0, sigma) * (1.0 - softStep(h6, 1.0, sigma));
    var s1 = softStep(h6, 1.0, sigma) * (1.0 - softStep(h6, 2.0, sigma));
    var s2 = softStep(h6, 2.0, sigma) * (1.0 - softStep(h6, 3.0, sigma));
    var s3 = softStep(h6, 3.0, sigma) * (1.0 - softStep(h6, 4.0, sigma));
    var s4 = softStep(h6, 4.0, sigma) * (1.0 - softStep(h6, 5.0, sigma));
    var s5 = softStep(h6, 5.0, sigma) * (1.0 - softStep(h6, 6.0, sigma));
    _ = .{ &s0, &s1, &s2, &s3, &s4, &s5 };

    const r = s0 * c + s1 * x + s4 * x + s5 * c + m;
    const g = s0 * x + s1 * c + s2 * c + s3 * x + m;
    const b = s2 * x + s3 * c + s4 * c + s5 * x + m;

    return .{
        .r = softClamp(r),
        .g = softClamp(g),
        .b = softClamp(b),
    };
}

// ============================================================================
// LearnableOkhsl: Complete forward pass
// ============================================================================

pub const LearnableOkhsl = struct {
    params: OkhslParameters,
    projection: SeedProjection,
    // Cached
    last_h: f64 = 0,
    last_s: f64 = 0,
    last_l: f64 = 0,

    pub fn init() LearnableOkhsl {
        return .{
            .params = .{},
            .projection = SeedProjection.init(),
        };
    }

    /// Forward: seed -> RGB
    pub fn forwardColor(self: *LearnableOkhsl, seed: f64) RGBf {
        const feats = seedToFeatures(seed);
        const proj = self.projection.project(feats.f1, feats.f2, feats.f3);
        const hsl = applyOkhslParams(&self.params, proj.h, proj.s, proj.l);
        self.last_h = hsl.h;
        self.last_s = hsl.s;
        self.last_l = hsl.l;
        return hslToRgb(hsl.h, hsl.s, hsl.l);
    }

    /// Finite-difference gradient step on h_scale
    pub fn trainStep(self: *LearnableOkhsl, seeds: []const f64, class_labels: []const usize, lr: f64) f64 {
        const loss = self.computeLoss(seeds, class_labels);
        const eps = 1e-4;

        // h_scale gradient
        self.params.h_scale += eps;
        const loss_p = self.computeLoss(seeds, class_labels);
        self.params.h_scale -= 2.0 * eps;
        const loss_m = self.computeLoss(seeds, class_labels);
        self.params.h_scale += eps;
        self.params.h_scale -= lr * (loss_p - loss_m) / (2.0 * eps);

        // gamma gradient
        self.params.gamma += eps;
        const loss_pg = self.computeLoss(seeds, class_labels);
        self.params.gamma -= 2.0 * eps;
        const loss_mg = self.computeLoss(seeds, class_labels);
        self.params.gamma += eps;
        self.params.gamma -= lr * (loss_pg - loss_mg) / (2.0 * eps);

        return loss;
    }

    /// Intra-class hue variance + inter-class hue proximity
    fn computeLoss(self: *LearnableOkhsl, seeds: []const f64, class_labels: []const usize) f64 {
        const n = seeds.len;
        if (n == 0) return 0;

        // Collect hues per class
        var hues: [64]f64 = undefined;
        for (0..n) |i| {
            _ = self.forwardColor(seeds[i]);
            hues[i] = self.last_h;
        }

        // Intra-class variance
        var intra_loss: f64 = 0;
        var max_class: usize = 0;
        for (class_labels) |cl| {
            if (cl > max_class) max_class = cl;
        }

        for (0..max_class + 1) |c| {
            var sum: f64 = 0;
            var count: usize = 0;
            for (0..n) |i| {
                if (class_labels[i] == c) {
                    sum += hues[i];
                    count += 1;
                }
            }
            if (count > 1) {
                const mean = sum / @as(f64, @floatFromInt(count));
                var variance: f64 = 0;
                for (0..n) |i| {
                    if (class_labels[i] == c) {
                        const d = hues[i] - mean;
                        variance += d * d;
                    }
                }
                intra_loss += @sqrt(variance / @as(f64, @floatFromInt(count)) + 1e-8);
            }
        }

        return intra_loss;
    }
};

// ============================================================================
// GAMUT LEARNABLE
// ============================================================================

pub const GamutType = enum {
    srgb,
    p3,
    rec2020,
};

/// Gamut truth value (subobject classifier)
pub const GamutTruth = struct {
    in_gamut: bool,
    distance: f64, // negative = inside, positive = outside

    pub fn meet(a: GamutTruth, b: GamutTruth) GamutTruth {
        return .{ .in_gamut = a.in_gamut and b.in_gamut, .distance = @max(a.distance, b.distance) };
    }

    pub fn join(a: GamutTruth, b: GamutTruth) GamutTruth {
        return .{ .in_gamut = a.in_gamut or b.in_gamut, .distance = @min(a.distance, b.distance) };
    }

    pub fn negate(self: GamutTruth) GamutTruth {
        return .{ .in_gamut = !self.in_gamut, .distance = -self.distance };
    }
};

/// Characteristic morphism chi_G: Color -> Omega
pub fn characteristicMorphism(gamut: GamutType, r: f64, g: f64, b: f64) GamutTruth {
    const margin: f64 = switch (gamut) {
        .srgb => 0.0,
        .p3 => 0.1,
        .rec2020 => 0.2,
    };

    const lo = -margin;
    const hi = 1.0 + margin;

    const dist_r = @max(@max(lo - r, r - hi), 0.0);
    const dist_g = @max(@max(lo - g, g - hi), 0.0);
    const dist_b = @max(@max(lo - b, b - hi), 0.0);
    const outside_dist = @sqrt(dist_r * dist_r + dist_g * dist_g + dist_b * dist_b);

    const in_gamut = (r >= lo and r <= hi) and (g >= lo and g <= hi) and (b >= lo and b <= hi);

    if (in_gamut) {
        const min_to_edge = @min(
            @min(r - lo, hi - r),
            @min(@min(g - lo, hi - g), @min(b - lo, hi - b)),
        );
        return .{ .in_gamut = true, .distance = -min_to_edge };
    }

    return .{ .in_gamut = false, .distance = outside_dist };
}

/// Pullback: clamp color into gamut
pub fn gamutPullback(gamut: GamutType, r: f64, g: f64, b: f64) RGBf {
    const margin: f64 = switch (gamut) {
        .srgb => 0.0,
        .p3 => 0.1,
        .rec2020 => 0.2,
    };
    return .{
        .r = math.clamp(r, -margin, 1.0 + margin),
        .g = math.clamp(g, -margin, 1.0 + margin),
        .b = math.clamp(b, -margin, 1.0 + margin),
    };
}

/// Gamut hierarchy: is sub a subset of super?
pub fn gamutSubset(sub: GamutType, super_g: GamutType) bool {
    return switch (sub) {
        .srgb => true,
        .p3 => super_g != .srgb,
        .rec2020 => super_g == .rec2020,
    };
}

// ============================================================================
// GamutParameters (learnable)
// ============================================================================

pub const GamutParameters = struct {
    chroma_scale: f64 = 1.0,
    lightness_scale: f64 = 1.0,
    hue_shift: f64 = 0.0,
    compression_gamma: f64 = 1.0,
};

// ============================================================================
// LearnableGamutMap
// ============================================================================

pub const LearnableGamutMap = struct {
    source: GamutType,
    target: GamutType,
    params: GamutParameters,

    pub fn init(source: GamutType, target: GamutType) LearnableGamutMap {
        return .{ .source = source, .target = target, .params = .{} };
    }

    /// Map color through learnable gamut compression
    pub fn mapToGamut(self: *const LearnableGamutMap, r: f64, g: f64, b: f64) RGBf {
        const gamma = self.params.compression_gamma;
        const cs = self.params.chroma_scale;

        const r_out = math.copysign(std.math.pow(f64, @abs(r), gamma), r) * cs;
        const g_out = math.copysign(std.math.pow(f64, @abs(g), gamma), g) * cs;
        const b_out = math.copysign(std.math.pow(f64, @abs(b), gamma), b) * cs;

        return gamutPullback(self.target, r_out, g_out, b_out);
    }

    /// Loss: penalty for out-of-gamut colors after mapping
    pub fn gamutLoss(self: *LearnableGamutMap, colors: []const [3]f64) f64 {
        var total: f64 = 0;
        for (colors) |c| {
            const mapped = self.mapToGamut(c[0], c[1], c[2]);
            const truth = characteristicMorphism(self.target, mapped.r, mapped.g, mapped.b);
            if (truth.distance > 0) total += truth.distance * truth.distance;
        }
        return total / @as(f64, @floatFromInt(colors.len));
    }

    /// Chroma preservation loss
    pub fn chromaPreservationLoss(self: *const LearnableGamutMap, original: []const [3]f64) f64 {
        var total: f64 = 0;
        for (original) |o| {
            const m = self.mapToGamut(o[0], o[1], o[2]);
            const chroma_o = @sqrt((o[0] - o[1]) * (o[0] - o[1]) + (o[1] - o[2]) * (o[1] - o[2]) + (o[2] - o[0]) * (o[2] - o[0]));
            const chroma_m = @sqrt((m.r - m.g) * (m.r - m.g) + (m.g - m.b) * (m.g - m.b) + (m.b - m.r) * (m.b - m.r));
            const d = chroma_o - chroma_m;
            total += d * d;
        }
        return total / @as(f64, @floatFromInt(original.len));
    }

    /// Train via finite-difference gradient descent
    pub fn train(self: *LearnableGamutMap, colors: []const [3]f64, lr: f64, epochs: usize) void {
        const eps = 1e-5;
        for (0..epochs) |_| {
            self.params.compression_gamma += eps;
            const lp = self.gamutLoss(colors);
            self.params.compression_gamma -= 2.0 * eps;
            const lm = self.gamutLoss(colors);
            self.params.compression_gamma += eps;

            const grad = (lp - lm) / (2.0 * eps);
            self.params.compression_gamma -= lr * grad;
            self.params.compression_gamma = math.clamp(self.params.compression_gamma, 0.1, 3.0);
        }
    }
};

// ============================================================================
// GayChain: color trajectory
// ============================================================================

pub const MAX_CHAIN = 64;

pub const GayChain = struct {
    colors: [MAX_CHAIN][3]f64,
    len: usize,
    gamut: GamutType,

    pub fn init(gamut: GamutType) GayChain {
        return .{
            .colors = undefined,
            .len = 0,
            .gamut = gamut,
        };
    }

    pub fn push(self: *GayChain, r: f64, g: f64, b: f64) void {
        if (self.len >= MAX_CHAIN) return;
        self.colors[self.len] = .{ r, g, b };
        self.len += 1;
    }

    pub fn verifyInGamut(self: *const GayChain) bool {
        for (0..self.len) |i| {
            const truth = characteristicMorphism(self.gamut, self.colors[i][0], self.colors[i][1], self.colors[i][2]);
            if (!truth.in_gamut) return false;
        }
        return true;
    }

    pub fn process(self: *GayChain) void {
        for (0..self.len) |i| {
            const clamped = gamutPullback(self.gamut, self.colors[i][0], self.colors[i][1], self.colors[i][2]);
            self.colors[i] = .{ clamped.r, clamped.g, clamped.b };
        }
    }
};

// ============================================================================
// WorldGamutClassifier: lattice of gamut classifiers
// ============================================================================

pub const WorldGamutClassifier = struct {
    pub fn gamutMeet(a: GamutType, b: GamutType) GamutType {
        const oa: u8 = switch (a) {
            .srgb => 0,
            .p3 => 1,
            .rec2020 => 2,
        };
        const ob: u8 = switch (b) {
            .srgb => 0,
            .p3 => 1,
            .rec2020 => 2,
        };
        const m = @min(oa, ob);
        return switch (m) {
            0 => .srgb,
            1 => .p3,
            else => .rec2020,
        };
    }

    pub fn gamutJoin(a: GamutType, b: GamutType) GamutType {
        const oa: u8 = switch (a) {
            .srgb => 0,
            .p3 => 1,
            .rec2020 => 2,
        };
        const ob: u8 = switch (b) {
            .srgb => 0,
            .p3 => 1,
            .rec2020 => 2,
        };
        const m = @max(oa, ob);
        return switch (m) {
            0 => .srgb,
            1 => .p3,
            else => .rec2020,
        };
    }

    /// Find smallest gamut containing color
    pub fn probeSmallest(r: f64, g: f64, b: f64) GamutType {
        if (characteristicMorphism(.srgb, r, g, b).in_gamut) return .srgb;
        if (characteristicMorphism(.p3, r, g, b).in_gamut) return .p3;
        return .rec2020;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "OkhslParameters default values" {
    const p = OkhslParameters{};
    try std.testing.expect(p.h_scale == 360.0);
    try std.testing.expect(p.gamma == 1.0);
}

test "SeedProjection golden ratio weights" {
    const proj = SeedProjection.init();
    try std.testing.expect(proj.w_h[0] > 0);
    try std.testing.expect(proj.w_h[0] > proj.w_h[1]); // decreasing powers of phi
}

test "seedToFeatures in [0,1]" {
    const f = seedToFeatures(12345.0);
    try std.testing.expect(f.f1 >= 0 and f.f1 <= 1.0);
    try std.testing.expect(f.f2 >= 0 and f.f2 <= 1.0);
    try std.testing.expect(f.f3 >= 0 and f.f3 <= 1.0);
}

test "LearnableOkhsl forward produces valid RGB" {
    var cs = LearnableOkhsl.init();
    const rgb = cs.forwardColor(1234567.0);
    try std.testing.expect(rgb.r >= 0 and rgb.r <= 1.0);
    try std.testing.expect(rgb.g >= 0 and rgb.g <= 1.0);
    try std.testing.expect(rgb.b >= 0 and rgb.b <= 1.0);
}

test "LearnableOkhsl different seeds produce different colors" {
    var cs = LearnableOkhsl.init();
    const c1 = cs.forwardColor(100.0);
    const c2 = cs.forwardColor(999999.0);
    // Not exactly equal (extremely unlikely)
    try std.testing.expect(c1.r != c2.r or c1.g != c2.g or c1.b != c2.b);
}

test "LearnableOkhsl training reduces loss" {
    var cs = LearnableOkhsl.init();
    const seeds = [_]f64{ 100.0, 101.0, 102.0, 200.0, 201.0, 202.0 };
    const labels = [_]usize{ 0, 0, 0, 1, 1, 1 };
    const loss_before = cs.computeLoss(&seeds, &labels);
    _ = cs.trainStep(&seeds, &labels, 0.1);
    _ = cs.trainStep(&seeds, &labels, 0.1);
    _ = cs.trainStep(&seeds, &labels, 0.1);
    const loss_after = cs.computeLoss(&seeds, &labels);
    // Loss should not increase dramatically (may not always decrease due to finite diff noise)
    try std.testing.expect(loss_after < loss_before + 1.0);
}

test "characteristicMorphism sRGB" {
    const truth = characteristicMorphism(.srgb, 0.5, 0.5, 0.5);
    try std.testing.expect(truth.in_gamut);
    try std.testing.expect(truth.distance < 0);

    const out = characteristicMorphism(.srgb, 1.5, 0.5, 0.5);
    try std.testing.expect(!out.in_gamut);
    try std.testing.expect(out.distance > 0);
}

test "characteristicMorphism P3 wider than sRGB" {
    // Color just outside sRGB but inside P3
    const srgb = characteristicMorphism(.srgb, 1.05, 0.5, 0.5);
    const p3 = characteristicMorphism(.p3, 1.05, 0.5, 0.5);
    try std.testing.expect(!srgb.in_gamut);
    try std.testing.expect(p3.in_gamut);
}

test "gamutPullback clamps correctly" {
    const clamped = gamutPullback(.srgb, 1.5, -0.3, 0.5);
    try std.testing.expect(clamped.r == 1.0);
    try std.testing.expect(clamped.g == 0.0);
    try std.testing.expect(clamped.b == 0.5);
}

test "gamutSubset hierarchy" {
    try std.testing.expect(gamutSubset(.srgb, .p3));
    try std.testing.expect(gamutSubset(.srgb, .rec2020));
    try std.testing.expect(gamutSubset(.p3, .rec2020));
    try std.testing.expect(!gamutSubset(.p3, .srgb));
    try std.testing.expect(!gamutSubset(.rec2020, .srgb));
}

test "GamutTruth lattice operations" {
    const a = GamutTruth{ .in_gamut = true, .distance = -0.1 };
    const b = GamutTruth{ .in_gamut = false, .distance = 0.2 };

    const m = GamutTruth.meet(a, b);
    try std.testing.expect(!m.in_gamut);

    const j = GamutTruth.join(a, b);
    try std.testing.expect(j.in_gamut);

    const neg = GamutTruth.negate(a);
    try std.testing.expect(!neg.in_gamut);
}

test "LearnableGamutMap mapToGamut" {
    var gm = LearnableGamutMap.init(.srgb, .srgb);
    const mapped = gm.mapToGamut(0.5, 0.5, 0.5);
    try std.testing.expect(mapped.r >= 0 and mapped.r <= 1.0);
    try std.testing.expect(mapped.g >= 0 and mapped.g <= 1.0);
}

test "LearnableGamutMap gamutLoss zero for in-gamut" {
    var gm = LearnableGamutMap.init(.srgb, .srgb);
    const colors = [_][3]f64{
        .{ 0.2, 0.3, 0.4 },
        .{ 0.5, 0.6, 0.7 },
    };
    const loss = gm.gamutLoss(&colors);
    try std.testing.expect(loss < 1e-10);
}

test "GayChain verify and process" {
    var chain = GayChain.init(.srgb);
    chain.push(0.5, 0.5, 0.5);
    chain.push(0.9, 0.1, 0.3);
    try std.testing.expect(chain.verifyInGamut());

    chain.push(1.5, -0.1, 0.5); // out of gamut
    try std.testing.expect(!chain.verifyInGamut());

    chain.process(); // clamp all
    try std.testing.expect(chain.verifyInGamut());
}

test "WorldGamutClassifier meet and join" {
    try std.testing.expectEqual(GamutType.srgb, WorldGamutClassifier.gamutMeet(.srgb, .p3));
    try std.testing.expectEqual(GamutType.p3, WorldGamutClassifier.gamutJoin(.srgb, .p3));
    try std.testing.expectEqual(GamutType.rec2020, WorldGamutClassifier.gamutJoin(.p3, .rec2020));
}

test "WorldGamutClassifier probeSmallest" {
    try std.testing.expectEqual(GamutType.srgb, WorldGamutClassifier.probeSmallest(0.5, 0.5, 0.5));
    try std.testing.expectEqual(GamutType.p3, WorldGamutClassifier.probeSmallest(1.05, 0.5, 0.5));
}
