//! fNIRS Processor — Modified Beer-Lambert Law & Hemodynamic Analysis
//!
//! Converts raw fNIRS optical intensity measurements to hemoglobin
//! concentration changes (HbO, HbR, HbT) using the modified Beer-Lambert
//! Law (mBLL).
//!
//! Target devices:
//!   - PLUX fNIRS Pioneer Kit (660nm + 860nm, 3 optodes at AF7/Fpz/AF8)
//!   - Wearable Sensing DSI-EEG/fNIRS combo
//!   - DIY OpenNIRScap builds
//!
//! Processing pipeline:
//!   Raw optical intensity (I) → Optical density (OD = -log10(I/I₀))
//!     → Modified Beer-Lambert: [ΔHbO; ΔHbR] = inv(ε·DPF·d) × [ΔOD_λ₁; ΔOD_λ₂]
//!       → Bandpass (0.01-0.2 Hz) → Short-channel regression (if available)
//!         → GF(3) trit classification → Syrup serialization
//!
//! Extinction coefficients from Wray et al. 1988 / Gratzer (tabulated):
//!   λ = 660nm: ε_HbO = 0.350 mM⁻¹cm⁻¹, ε_HbR = 3.843 mM⁻¹cm⁻¹
//!   λ = 760nm: ε_HbO = 1.486 mM⁻¹cm⁻¹, ε_HbR = 1.599 mM⁻¹cm⁻¹
//!   λ = 850nm: ε_HbO = 2.526 mM⁻¹cm⁻¹, ε_HbR = 1.798 mM⁻¹cm⁻¹
//!   λ = 860nm: ε_HbO = 2.609 mM⁻¹cm⁻¹, ε_HbR = 1.683 mM⁻¹cm⁻¹

const std = @import("std");
const math = std.math;

// ============================================================================
// CONSTANTS
// ============================================================================

/// Maximum fNIRS channels (source-detector pairs)
pub const MAX_FNIRS_CHANNELS: usize = 16;

/// Default source-detector separation (cm) — PLUX Pioneer Kit
pub const DEFAULT_SD_SEPARATION: f32 = 3.0;

/// Short-channel separation (cm) — for scalp physiology regression
pub const SHORT_CHANNEL_SEPARATION: f32 = 0.8;

/// Default differential pathlength factor (DPF)
/// Age-dependent; ~6.0 for adult prefrontal cortex at 800nm
pub const DEFAULT_DPF_760: f32 = 6.26;
pub const DEFAULT_DPF_850: f32 = 5.66;
pub const DEFAULT_DPF_660: f32 = 6.51;
pub const DEFAULT_DPF_860: f32 = 5.60;

// ============================================================================
// EXTINCTION COEFFICIENTS (mM⁻¹ cm⁻¹)
// ============================================================================

/// Extinction coefficient pair for a given wavelength
pub const ExtinctionCoeffs = struct {
    hbo: f32, // Oxyhemoglobin
    hbr: f32, // Deoxyhemoglobin
};

/// Get extinction coefficients for common fNIRS wavelengths
pub fn extinctionAt(wavelength_nm: u16) ExtinctionCoeffs {
    return switch (wavelength_nm) {
        660 => .{ .hbo = 0.350, .hbr = 3.843 },
        690 => .{ .hbo = 0.608, .hbr = 2.703 },
        735 => .{ .hbo = 1.249, .hbr = 1.764 },
        760 => .{ .hbo = 1.486, .hbr = 1.599 },
        780 => .{ .hbo = 1.680, .hbr = 1.483 },
        800 => .{ .hbo = 1.840, .hbr = 1.840 }, // Isosbestic point
        830 => .{ .hbo = 2.230, .hbr = 1.791 },
        850 => .{ .hbo = 2.526, .hbr = 1.798 },
        860 => .{ .hbo = 2.609, .hbr = 1.683 },
        else => .{ .hbo = 1.840, .hbr = 1.840 }, // Default to isosbestic
    };
}

// ============================================================================
// WAVELENGTH CONFIGURATION
// ============================================================================

pub const WavelengthPair = struct {
    lambda1_nm: u16, // Short wavelength (more sensitive to HbR)
    lambda2_nm: u16, // Long wavelength (more sensitive to HbO)
    dpf1: f32, // DPF at lambda1
    dpf2: f32, // DPF at lambda2
    sd_separation: f32, // Source-detector separation (cm)

    /// PLUX fNIRS Pioneer Kit configuration
    pub fn plux() WavelengthPair {
        return .{
            .lambda1_nm = 660,
            .lambda2_nm = 860,
            .dpf1 = DEFAULT_DPF_660,
            .dpf2 = DEFAULT_DPF_860,
            .sd_separation = DEFAULT_SD_SEPARATION,
        };
    }

    /// Standard 760/850 nm configuration
    pub fn standard() WavelengthPair {
        return .{
            .lambda1_nm = 760,
            .lambda2_nm = 850,
            .dpf1 = DEFAULT_DPF_760,
            .dpf2 = DEFAULT_DPF_850,
            .sd_separation = DEFAULT_SD_SEPARATION,
        };
    }
};

// ============================================================================
// MODIFIED BEER-LAMBERT LAW
// ============================================================================

/// Hemoglobin concentration changes (micromolar, µM)
pub const HemoConcentration = struct {
    hbo: f32, // Δ[HbO] (µM) — oxyhemoglobin
    hbr: f32, // Δ[HbR] (µM) — deoxyhemoglobin
    hbt: f32, // Δ[HbT] = HbO + HbR (µM) — total hemoglobin

    pub fn fromHboHbr(hbo: f32, hbr: f32) HemoConcentration {
        return .{ .hbo = hbo, .hbr = hbr, .hbt = hbo + hbr };
    }
};

/// Compute optical density change from raw intensity
/// ΔOD = -log₁₀(I / I₀)
pub fn opticalDensity(intensity: f32, baseline: f32) f32 {
    if (baseline <= 0 or intensity <= 0) return 0;
    return -@log10(intensity / baseline);
}

/// Apply modified Beer-Lambert law to convert ΔOD at two wavelengths
/// to hemoglobin concentration changes.
///
/// [ΔOD_λ₁]   [ε_HbO_λ₁  ε_HbR_λ₁] [DPF_λ₁ × d     0     ] [Δ[HbO]]
/// [ΔOD_λ₂] = [ε_HbO_λ₂  ε_HbR_λ₂] [   0      DPF_λ₂ × d ] [Δ[HbR]]
///
/// Solving: [Δ[HbO]; Δ[HbR]] = inv(A) × [ΔOD_λ₁ / (DPF₁×d); ΔOD_λ₂ / (DPF₂×d)]
pub fn beerLambert(
    delta_od1: f32, // ΔOD at wavelength 1
    delta_od2: f32, // ΔOD at wavelength 2
    config: WavelengthPair,
) HemoConcentration {
    const e1 = extinctionAt(config.lambda1_nm);
    const e2 = extinctionAt(config.lambda2_nm);

    // Effective path lengths
    const path1 = config.dpf1 * config.sd_separation;
    const path2 = config.dpf2 * config.sd_separation;

    // Normalized OD changes
    const norm_od1 = if (path1 > 0) delta_od1 / path1 else 0;
    const norm_od2 = if (path2 > 0) delta_od2 / path2 else 0;

    // 2×2 matrix inversion: A = [[e1.hbo, e1.hbr], [e2.hbo, e2.hbr]]
    // det(A) = e1.hbo * e2.hbr - e1.hbr * e2.hbo
    const det = e1.hbo * e2.hbr - e1.hbr * e2.hbo;
    if (@abs(det) < 1e-10) {
        return HemoConcentration.fromHboHbr(0, 0);
    }

    // inv(A) = (1/det) * [[e2.hbr, -e1.hbr], [-e2.hbo, e1.hbo]]
    const inv_det = 1.0 / det;
    const delta_hbo = inv_det * (e2.hbr * norm_od1 - e1.hbr * norm_od2);
    const delta_hbr = inv_det * (-e2.hbo * norm_od1 + e1.hbo * norm_od2);

    return HemoConcentration.fromHboHbr(delta_hbo, delta_hbr);
}

// ============================================================================
// fNIRS READING
// ============================================================================

/// Trit classification from hemodynamic state
pub const Trit = enum(i8) {
    minus = -1, // HbO decreasing (deactivation)
    zero = 0, // Baseline / no significant change
    plus = 1, // HbO increasing (activation)

    pub fn name(self: Trit) []const u8 {
        return switch (self) {
            .minus => "DEACTIVATION",
            .zero => "BASELINE",
            .plus => "ACTIVATION",
        };
    }
};

/// Single-channel fNIRS reading
pub const FNIRSReading = struct {
    timestamp_ms: u64,
    hbo: f32, // Δ[HbO] µM
    hbr: f32, // Δ[HbR] µM
    hbt: f32, // Δ[HbT] µM
    trit: Trit,

    pub fn fromConcentration(hemo: HemoConcentration, timestamp_ms: u64, threshold: f32) FNIRSReading {
        const trit: Trit = if (hemo.hbo > threshold)
            .plus
        else if (hemo.hbo < -threshold)
            .minus
        else
            .zero;

        return .{
            .timestamp_ms = timestamp_ms,
            .hbo = hemo.hbo,
            .hbr = hemo.hbr,
            .hbt = hemo.hbt,
            .trit = trit,
        };
    }
};

/// Multi-channel fNIRS epoch
pub const FNIRSEpoch = struct {
    timestamp_ms: u64,
    n_channels: u8,
    channels: [MAX_FNIRS_CHANNELS]FNIRSReading,

    /// Aggregate trit across channels (majority vote)
    pub fn aggregateTrit(self: *const FNIRSEpoch) Trit {
        var sum: i32 = 0;
        for (self.channels[0..self.n_channels]) |ch| {
            sum += @backingInt(ch.trit);
        }
        if (sum > 0) return .plus;
        if (sum < 0) return .minus;
        return .zero;
    }

    /// Mean HbO across channels
    pub fn meanHbO(self: *const FNIRSEpoch) f32 {
        if (self.n_channels == 0) return 0;
        var total: f32 = 0;
        for (self.channels[0..self.n_channels]) |ch| {
            total += ch.hbo;
        }
        return total / @as(f32, @floatFromInt(self.n_channels));
    }
};

// ============================================================================
// BASELINE TRACKER
// ============================================================================

/// Tracks baseline intensity for optical density calculation.
/// Uses exponential moving average for adaptive baseline.
pub const BaselineTracker = struct {
    baseline_lambda1: [MAX_FNIRS_CHANNELS]f32,
    baseline_lambda2: [MAX_FNIRS_CHANNELS]f32,
    initialized: [MAX_FNIRS_CHANNELS]bool,
    alpha: f32, // EMA decay (0.01 = slow adaptation)

    pub fn init(alpha: f32) BaselineTracker {
        return .{
            .baseline_lambda1 = @splat(0),
            .baseline_lambda2 = @splat(0),
            .initialized = @splat(false),
            .alpha = alpha,
        };
    }

    /// Update baseline and return ΔOD for both wavelengths
    pub fn update(
        self: *BaselineTracker,
        channel: usize,
        intensity_lambda1: f32,
        intensity_lambda2: f32,
    ) struct { delta_od1: f32, delta_od2: f32 } {
        if (channel >= MAX_FNIRS_CHANNELS) {
            return .{ .delta_od1 = 0, .delta_od2 = 0 };
        }

        if (!self.initialized[channel]) {
            self.baseline_lambda1[channel] = intensity_lambda1;
            self.baseline_lambda2[channel] = intensity_lambda2;
            self.initialized[channel] = true;
            return .{ .delta_od1 = 0, .delta_od2 = 0 };
        }

        const od1 = opticalDensity(intensity_lambda1, self.baseline_lambda1[channel]);
        const od2 = opticalDensity(intensity_lambda2, self.baseline_lambda2[channel]);

        // Update baseline with EMA
        self.baseline_lambda1[channel] = self.alpha * intensity_lambda1 +
            (1.0 - self.alpha) * self.baseline_lambda1[channel];
        self.baseline_lambda2[channel] = self.alpha * intensity_lambda2 +
            (1.0 - self.alpha) * self.baseline_lambda2[channel];

        return .{ .delta_od1 = od1, .delta_od2 = od2 };
    }
};

// ============================================================================
// COMPLETE PIPELINE
// ============================================================================

/// Process raw dual-wavelength intensities into hemoglobin concentrations.
/// This is the full mBLL pipeline for one sample, one channel.
pub fn processRawSample(
    tracker: *BaselineTracker,
    channel: usize,
    intensity_lambda1: f32,
    intensity_lambda2: f32,
    config: WavelengthPair,
    timestamp_ms: u64,
    activation_threshold: f32,
) FNIRSReading {
    const od = tracker.update(channel, intensity_lambda1, intensity_lambda2);
    const hemo = beerLambert(od.delta_od1, od.delta_od2, config);
    return FNIRSReading.fromConcentration(hemo, timestamp_ms, activation_threshold);
}

// ============================================================================
// TESTS
// ============================================================================

test "optical density: same intensity = zero OD" {
    const od = opticalDensity(100.0, 100.0);
    try std.testing.expectApproxEqAbs(@as(f32, 0), od, 1e-6);
}

test "optical density: half intensity = positive OD" {
    const od = opticalDensity(50.0, 100.0);
    // -log10(0.5) = 0.3010
    try std.testing.expectApproxEqAbs(@as(f32, 0.3010), od, 0.001);
}

test "optical density: double intensity = negative OD" {
    const od = opticalDensity(200.0, 100.0);
    // -log10(2) = -0.3010
    try std.testing.expectApproxEqAbs(@as(f32, -0.3010), od, 0.001);
}

test "beer-lambert with zero OD = zero concentration" {
    const config = WavelengthPair.plux();
    const hemo = beerLambert(0, 0, config);
    try std.testing.expectApproxEqAbs(@as(f32, 0), hemo.hbo, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0), hemo.hbr, 1e-6);
}

test "beer-lambert: HbO increase at 660/860nm" {
    const config = WavelengthPair.plux();
    // Simulate ΔOD pattern typical of cortical activation:
    // At 660nm: small positive ΔOD (HbR contribution via high ε_HbR)
    // At 860nm: larger positive ΔOD (HbO contribution via high ε_HbO)
    const hemo = beerLambert(0.01, 0.02, config);
    // HbO should increase (activation)
    try std.testing.expect(hemo.hbo > 0);
    // HbT should be sum
    try std.testing.expectApproxEqAbs(hemo.hbt, hemo.hbo + hemo.hbr, 1e-6);
}

test "beer-lambert: determinant not zero for 660/860" {
    const e1 = extinctionAt(660);
    const e2 = extinctionAt(860);
    const det = e1.hbo * e2.hbr - e1.hbr * e2.hbo;
    // Must be non-zero for invertible system
    try std.testing.expect(@abs(det) > 0.1);
}

test "beer-lambert: determinant not zero for 760/850" {
    const e1 = extinctionAt(760);
    const e2 = extinctionAt(850);
    const det = e1.hbo * e2.hbr - e1.hbr * e2.hbo;
    try std.testing.expect(@abs(det) > 0.1);
}

test "trit classification from HbO" {
    const threshold: f32 = 0.5;
    const activation = FNIRSReading.fromConcentration(
        HemoConcentration.fromHboHbr(1.0, -0.3),
        1000,
        threshold,
    );
    try std.testing.expectEqual(Trit.plus, activation.trit);

    const deactivation = FNIRSReading.fromConcentration(
        HemoConcentration.fromHboHbr(-1.0, 0.3),
        1000,
        threshold,
    );
    try std.testing.expectEqual(Trit.minus, deactivation.trit);

    const baseline = FNIRSReading.fromConcentration(
        HemoConcentration.fromHboHbr(0.1, -0.05),
        1000,
        threshold,
    );
    try std.testing.expectEqual(Trit.zero, baseline.trit);
}

test "baseline tracker initialization" {
    var tracker = BaselineTracker.init(0.01);
    // First sample initializes baseline, returns zero OD
    const first = tracker.update(0, 100.0, 200.0);
    try std.testing.expectApproxEqAbs(@as(f32, 0), first.delta_od1, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0), first.delta_od2, 1e-6);

    // Second sample with same intensity → OD ≈ 0 (baseline nearly unchanged)
    const second = tracker.update(0, 100.0, 200.0);
    try std.testing.expect(@abs(second.delta_od1) < 0.01);
}

test "full pipeline: raw → concentration → trit" {
    var tracker = BaselineTracker.init(0.01);
    const config = WavelengthPair.plux();

    // Initialize baseline
    _ = processRawSample(&tracker, 0, 1000.0, 1000.0, config, 0, 0.5);

    // Process a sample with decreased intensity (tissue absorption increased)
    const reading = processRawSample(&tracker, 0, 900.0, 850.0, config, 100, 0.001);
    // Should produce non-zero hemoglobin changes
    try std.testing.expect(reading.hbo != 0 or reading.hbr != 0);
}

test "epoch aggregate trit" {
    var epoch: FNIRSEpoch = .{
        .timestamp_ms = 1000,
        .n_channels = 3,
        .channels = undefined,
    };
    epoch.channels[0] = .{ .timestamp_ms = 1000, .hbo = 1.0, .hbr = -0.3, .hbt = 0.7, .trit = .plus };
    epoch.channels[1] = .{ .timestamp_ms = 1000, .hbo = 0.0, .hbr = 0.0, .hbt = 0.0, .trit = .zero };
    epoch.channels[2] = .{ .timestamp_ms = 1000, .hbo = 0.8, .hbr = -0.2, .hbt = 0.6, .trit = .plus };
    // 2 plus + 1 zero → aggregate = plus
    try std.testing.expectEqual(Trit.plus, epoch.aggregateTrit());
}

test "extinction coefficients: isosbestic point at 800nm" {
    const e = extinctionAt(800);
    // At 800nm, HbO and HbR have equal extinction
    try std.testing.expectApproxEqAbs(e.hbo, e.hbr, 0.001);
}

test "PLUX config has valid wavelengths" {
    const config = WavelengthPair.plux();
    try std.testing.expectEqual(@as(u16, 660), config.lambda1_nm);
    try std.testing.expectEqual(@as(u16, 860), config.lambda2_nm);
    try std.testing.expect(config.sd_separation > 0);
    try std.testing.expect(config.dpf1 > 0);
    try std.testing.expect(config.dpf2 > 0);
}
