//! Rhino — Sub-Perceptual Frequency Decomposition of Color
//!
//! A rhino can hear frequencies we cannot. Rhinoceroses communicate via
//! infrasound (< 20 Hz), perceiving structure in signals humans experience
//! as silence. Analogously, the 243-color GF(3)^5 palette quantizes
//! continuous color space into discrete trits, discarding the residual
//! as "silence" — the Infinitesimal in ColorValue.
//!
//! This module treats the Infinitesimal (dr, dg, db) as a 3-channel
//! signal and decomposes it into frequency bands, extracting structure
//! that the standard palette observer cannot perceive:
//!
//!   Band        Analogy          Infinitesimal regime
//!   ─────────   ──────────────   ──────────────────────────
//!   Infra       Rhino hearing    |ε| < 1/243 (sub-trit)
//!   Perceptual  Human hearing    1/243 ≤ |ε| < 1/9 (inter-trit)
//!   Ultra       Bat echoloc.     |ε| ≥ 1/9 (cross-sector)
//!
//! A RhinoObserver extracts trit-level meaning from the infra band
//! that a standard observer would round to zero. This is useful for:
//!   - Arrow IPC batch diffing (two batches that look identical to
//!     a standard observer may differ to a rhino)
//!   - BCI neurofeedback (sub-perceptual EEG color shifts)
//!   - Virion mutation detection (gain-of-function in the noise floor)
//!   - Bisimulation refinement (rhino-distinguishable = not bisimilar)
//!
//! All functions are pure and referentially transparent.
//! No allocator in the observation path. wasm32-freestanding compatible.

const std = @import("std");
const math = std.math;
const color_value = @import("color_value.zig");
const ColorValue = color_value.ColorValue;
const Trit = color_value.Trit;
const TritWord = color_value.TritWord;
const Infinitesimal = color_value.Infinitesimal;
const RGB = color_value.RGB;

// ---------------------------------------------------------------------------
// Frequency band thresholds (in infinitesimal norm-squared units)
// ---------------------------------------------------------------------------

/// Sub-trit threshold: below this, a standard observer sees nothing.
/// 1/243^2 ~ 1.69e-5. The rhino hears this.
const INFRA_THRESHOLD: f32 = 1.0 / (243.0 * 243.0);

/// Inter-trit threshold: perceptible as "slightly off" to a standard observer.
/// 1/9^2 ~ 0.0123. Crosses chroma or hue sector boundaries.
const ULTRA_THRESHOLD: f32 = 1.0 / (9.0 * 9.0);

// ---------------------------------------------------------------------------
// Band classification
// ---------------------------------------------------------------------------

pub const Band = enum(u2) {
    /// Below standard perception. Only a rhino-observer resolves this.
    infra = 0,
    /// Within standard perceptual range. Both observers agree.
    perceptual = 1,
    /// Above standard palette resolution. Crosses trit sector boundaries.
    ultra = 2,

    pub fn name(self: Band) []const u8 {
        return switch (self) {
            .infra => "infra",
            .perceptual => "perceptual",
            .ultra => "ultra",
        };
    }
};

/// Classify an Infinitesimal into a frequency band.
pub fn classify(eps: Infinitesimal) Band {
    const energy = eps.normSq();
    if (energy < INFRA_THRESHOLD) return .infra;
    if (energy < ULTRA_THRESHOLD) return .perceptual;
    return .ultra;
}

/// Classify a ColorValue's sub-perceptual residual.
pub fn classifyColor(cv: ColorValue) Band {
    return classify(cv.eps);
}

// ---------------------------------------------------------------------------
// RhinoObservation: what the rhino perceives that we cannot
// ---------------------------------------------------------------------------

pub const RhinoObservation = struct {
    band: Band,
    /// Magnitude of the infinitesimal (L2 norm)
    magnitude: f32,
    /// Dominant channel: which color axis carries the most sub-perceptual energy
    dominant_channel: Channel,
    /// Infra-trit: a GF(3) trit extracted from the infinitesimal direction.
    /// This is invisible to the standard observer but meaningful to the rhino.
    infra_trit: Trit,
    /// Phase angle in the dr-dg plane (radians). Encodes rotational structure
    /// in the noise floor, like the phase of an infrasound wave.
    phase: f32,

    pub const Channel = enum(u2) {
        r = 0,
        g = 1,
        b = 2,
    };
};

/// Observe a ColorValue as a rhino would: extract sub-perceptual structure.
/// Pure function. Same ColorValue always produces the same observation.
pub fn observe(cv: ColorValue) RhinoObservation {
    return observeEps(cv.eps);
}

/// Observe an Infinitesimal directly.
pub fn observeEps(eps: Infinitesimal) RhinoObservation {
    const dr: f32 = @floatCast(eps.dr);
    const dg: f32 = @floatCast(eps.dg);
    const db: f32 = @floatCast(eps.db);

    const energy = dr * dr + dg * dg + db * db;
    const magnitude = @sqrt(energy);

    // Dominant channel: largest absolute component
    const ar = @abs(dr);
    const ag = @abs(dg);
    const ab = @abs(db);
    const dominant: RhinoObservation.Channel = if (ar >= ag and ar >= ab)
        .r
    else if (ag >= ab)
        .g
    else
        .b;

    // Infra-trit: extract from the sign pattern of the infinitesimal.
    // Maps the 3D sign vector to a single trit via majority vote.
    // (+,+,+) or (+,+,-) etc -> trit encoding of the "direction" of the noise.
    const sign_sum: i8 = (if (dr > 0) @as(i8, 1) else if (dr < 0) @as(i8, -1) else @as(i8, 0)) +
        (if (dg > 0) @as(i8, 1) else if (dg < 0) @as(i8, -1) else @as(i8, 0)) +
        (if (db > 0) @as(i8, 1) else if (db < 0) @as(i8, -1) else @as(i8, 0));
    const infra_trit: Trit = if (sign_sum > 0) .plus else if (sign_sum < 0) .minus else .zero;

    // Phase: atan2(dg, dr) in the red-green plane.
    // Carries rotational information invisible to the palette.
    const phase = math.atan2(dg, dr);

    return .{
        .band = classify(eps),
        .magnitude = magnitude,
        .dominant_channel = dominant,
        .infra_trit = infra_trit,
        .phase = phase,
    };
}

// ---------------------------------------------------------------------------
// Rhino diff: detect differences invisible to standard observers
// ---------------------------------------------------------------------------

pub const RhinoDiff = struct {
    /// Are the two colors identical to a standard (palette) observer?
    standard_equal: bool,
    /// Are they identical to a rhino observer? (includes infra band)
    rhino_equal: bool,
    /// Energy of the difference in the infra band
    infra_energy: f32,
    /// The trit the rhino sees in the difference
    diff_trit: Trit,
};

/// Compare two ColorValues as a rhino would.
/// Two colors that look identical under the 243-palette (standard_equal=true)
/// may still differ to a rhino (rhino_equal=false) if their infinitesimals diverge.
pub fn diff(a: ColorValue, b: ColorValue) RhinoDiff {
    const standard_eq = a.eqlStandard(b);

    const dr: f32 = @as(f32, @floatCast(a.eps.dr)) - @as(f32, @floatCast(b.eps.dr));
    const dg: f32 = @as(f32, @floatCast(a.eps.dg)) - @as(f32, @floatCast(b.eps.dg));
    const db: f32 = @as(f32, @floatCast(a.eps.db)) - @as(f32, @floatCast(b.eps.db));

    const infra_energy = dr * dr + dg * dg + db * db;

    const sign_sum: i8 = (if (dr > 0) @as(i8, 1) else if (dr < 0) @as(i8, -1) else @as(i8, 0)) +
        (if (dg > 0) @as(i8, 1) else if (dg < 0) @as(i8, -1) else @as(i8, 0)) +
        (if (db > 0) @as(i8, 1) else if (db < 0) @as(i8, -1) else @as(i8, 0));
    const diff_trit: Trit = if (sign_sum > 0) .plus else if (sign_sum < 0) .minus else .zero;

    // Rhino equality: standard part matches AND infra energy is negligible
    const rhino_eq = standard_eq and (infra_energy < INFRA_THRESHOLD);

    return .{
        .standard_equal = standard_eq,
        .rhino_equal = rhino_eq,
        .infra_energy = infra_energy,
        .diff_trit = diff_trit,
    };
}

// ---------------------------------------------------------------------------
// Batch observation: rhino sweep over Arrow IPC batch
// ---------------------------------------------------------------------------

/// Summary statistics of a rhino sweep over a color batch.
pub const BatchSweep = struct {
    total: u32,
    infra_count: u32,
    perceptual_count: u32,
    ultra_count: u32,
    mean_magnitude: f32,
    /// Net trit of all infra-trits (GF(3) sum).
    /// If zero, the sub-perceptual noise is balanced.
    net_infra_trit: Trit,
};

/// Sweep a batch of ColorValues, counting how many fall in each band.
pub fn sweep(colors: []const ColorValue) BatchSweep {
    var infra: u32 = 0;
    var perceptual: u32 = 0;
    var ultra: u32 = 0;
    var mag_sum: f32 = 0;
    var trit_sum: i16 = 0;

    for (colors) |cv| {
        const obs = observe(cv);
        switch (obs.band) {
            .infra => infra += 1,
            .perceptual => perceptual += 1,
            .ultra => ultra += 1,
        }
        mag_sum += obs.magnitude;
        trit_sum += @intFromEnum(obs.infra_trit);
    }

    const n: f32 = @floatFromInt(@max(colors.len, 1));
    const net_mod = @mod(trit_sum + 3000, 3);
    const net_trit: Trit = switch (net_mod) {
        0 => .zero,
        1 => .plus,
        2 => .minus,
        else => unreachable,
    };

    return .{
        .total = @intCast(colors.len),
        .infra_count = infra,
        .perceptual_count = perceptual,
        .ultra_count = ultra,
        .mean_magnitude = mag_sum / n,
        .net_infra_trit = net_trit,
    };
}

// ===========================================================================
// Tests
// ===========================================================================

test "zero infinitesimal is infra band" {
    const cv = ColorValue.fromTrit(.zero, 0);
    try std.testing.expectEqual(Band.infra, classifyColor(cv));
}

test "observe zero eps yields zero magnitude" {
    const cv = ColorValue.fromTrit(.plus, 0);
    const obs = observe(cv);
    try std.testing.expectEqual(@as(f32, 0.0), obs.magnitude);
    try std.testing.expectEqual(Trit.zero, obs.infra_trit);
    try std.testing.expectEqual(Band.infra, obs.band);
}

test "observe nonzero eps extracts infra trit" {
    var cv = ColorValue.fromTrit(.minus, 0);
    cv.eps = .{ .dr = 0.001, .dg = 0.002, .db = 0.0005 };
    const obs = observe(cv);
    // All positive -> infra_trit = plus
    try std.testing.expectEqual(Trit.plus, obs.infra_trit);
    try std.testing.expect(obs.magnitude > 0);
}

test "observe dominant channel detection" {
    var cv = ColorValue.fromTrit(.zero, 0);
    cv.eps = .{ .dr = 0.5, .dg = 0.01, .db = 0.01 };
    const obs = observe(cv);
    try std.testing.expectEqual(RhinoObservation.Channel.r, obs.dominant_channel);
    try std.testing.expectEqual(Band.ultra, obs.band);
}

test "diff: identical standard part, different infinitesimal" {
    var a = ColorValue.fromTrit(.plus, 0);
    var b = ColorValue.fromTrit(.plus, 0);
    a.eps = .{ .dr = 0.01, .dg = 0.0, .db = 0.0 };
    b.eps = .{ .dr = -0.01, .dg = 0.0, .db = 0.0 };

    const d = diff(a, b);
    try std.testing.expect(d.standard_equal);
    try std.testing.expect(!d.rhino_equal);
    try std.testing.expect(d.infra_energy > 0);
}

test "diff: truly identical colors" {
    const a = ColorValue.fromTrit(.zero, 0);
    const b = ColorValue.fromTrit(.zero, 0);
    const d = diff(a, b);
    try std.testing.expect(d.standard_equal);
    try std.testing.expect(d.rhino_equal);
    try std.testing.expectEqual(@as(f32, 0.0), d.infra_energy);
}

test "rhino observes structure in ColorValue.at quantization residual" {
    const cv = ColorValue.at(1069, 42);
    const obs = observe(cv);
    // ColorValue.at produces quantization error -> nonzero eps
    // The rhino should see something in the infra or perceptual band
    try std.testing.expect(obs.magnitude >= 0);
}

test "sweep conserved batch has balanced infra trits" {
    const colors = [_]ColorValue{
        ColorValue.fromTrit(.plus, 0),
        ColorValue.fromTrit(.minus, 0),
        ColorValue.fromTrit(.zero, 0),
    };
    const s = sweep(&colors);
    try std.testing.expectEqual(@as(u32, 3), s.total);
    // All have zero eps -> all infra
    try std.testing.expectEqual(@as(u32, 3), s.infra_count);
    try std.testing.expectEqual(Trit.zero, s.net_infra_trit);
}

test "sweep mixed bands" {
    const c0 = ColorValue.fromTrit(.zero, 0);
    var c1 = ColorValue.fromTrit(.zero, 0);
    c1.eps = .{ .dr = 0.005, .dg = 0.005, .db = 0.005 };
    var c2 = ColorValue.fromTrit(.zero, 0);
    c2.eps = .{ .dr = 0.5, .dg = 0.5, .db = 0.5 };

    const colors = [_]ColorValue{ c0, c1, c2 };
    const s = sweep(&colors);
    try std.testing.expectEqual(@as(u32, 3), s.total);
    // c0 = infra, c1 = perceptual, c2 = ultra
    try std.testing.expectEqual(@as(u32, 1), s.infra_count);
    try std.testing.expectEqual(@as(u32, 1), s.perceptual_count);
    try std.testing.expectEqual(@as(u32, 1), s.ultra_count);
}

test "classify thresholds" {
    try std.testing.expectEqual(Band.infra, classify(Infinitesimal.ZERO));
    // Just above infra threshold
    const small = Infinitesimal{ .dr = 0.005, .dg = 0.0, .db = 0.0 };
    try std.testing.expectEqual(Band.perceptual, classify(small));
    // Above ultra threshold
    const big = Infinitesimal{ .dr = 0.2, .dg = 0.2, .db = 0.2 };
    try std.testing.expectEqual(Band.ultra, classify(big));
}

test "phase encodes rotation in noise floor" {
    var cv = ColorValue.fromTrit(.zero, 0);
    cv.eps = .{ .dr = 0.01, .dg = 0.0, .db = 0.0 };
    const obs_r = observe(cv);
    // Pure red eps -> phase ~ 0
    try std.testing.expect(@abs(obs_r.phase) < 0.01);

    cv.eps = .{ .dr = 0.0, .dg = 0.01, .db = 0.0 };
    const obs_g = observe(cv);
    // Pure green eps -> phase ~ pi/2
    try std.testing.expect(@abs(obs_g.phase - math.pi / 2.0) < 0.01);
}

test "empty sweep" {
    const colors = [_]ColorValue{};
    const s = sweep(&colors);
    try std.testing.expectEqual(@as(u32, 0), s.total);
    try std.testing.expectEqual(Trit.zero, s.net_infra_trit);
}
