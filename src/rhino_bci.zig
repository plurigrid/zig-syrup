//! Rhino BCI — Brain-Computer Interface Device Setup for Rhinoceros
//!
//! Rhinoceros neurophysiology differs from human in ways that demand
//! a fundamentally different BCI architecture:
//!
//!   1. INFRASONIC COMMUNICATION (1-20 Hz)
//!      Rhinos produce and perceive infrasound for long-range contact.
//!      Human EEG treats delta (0.5-4 Hz) as "noise/sleep" — for rhinos,
//!      this is PRIMARY communication bandwidth. We extend downward to 0.1 Hz.
//!
//!   2. SEISMIC DETECTION (5-40 Hz via substrate vibration)
//!      Pacinian corpuscles in rhinoceros feet detect ground vibrations
//!      from other animals at 1+ km range. This requires a dedicated
//!      piezoelectric sensor array on the limbs, not scalp EEG.
//!
//!   3. OLFACTORY DOMINANCE
//!      Rhinoceros olfactory bulb is proportionally massive. Olfactory
//!      EEG (electro-olfactogram, EOG) is a primary modality, not auxiliary.
//!      Sampling at 500 Hz to capture fast olfactory receptor oscillations.
//!
//!   4. DERMAL THICKNESS (1.5-5 cm skin)
//!      Standard Ag/AgCl wet electrodes cannot penetrate rhinoceros hide.
//!      Requires:
//!        - Capacitive coupling (no skin contact needed, works through hide)
//!        - Longer integration times (signal attenuated ~40 dB by dermis)
//!        - Higher gain amplification (100x vs human 24x)
//!
//!   5. HORN PROXIMITY (keratin EM waveguide)
//!      The horn is a dense keratin structure that acts as a waveguide
//!      for EM fields from frontal cortex. A horn-mounted sensor array
//!      provides unique access to prefrontal activity without scalp contact.
//!
//!   6. FREQUENCY BANDS (shifted from human)
//!      Human          Rhino                 Significance
//!      ──────────     ──────────────────    ──────────────────
//!      Delta 0.5-4    Seismic  0.1-2 Hz    Ground vibration processing
//!      Theta 4-8      Infra    2-8 Hz       Long-range social signals
//!      Alpha 8-13     Olfact   8-20 Hz      Olfactory discrimination
//!      Beta  13-30    Alert    20-50 Hz     Threat detection / vigilance
//!      Gamma 30-100   Bind     50-150 Hz    Multi-sensory binding
//!
//! Hardware reference design:
//!   nRF5340 dual-core (reuses bci_receiver.zig IPC architecture)
//!   SPI0: Horn array (8 capacitive electrodes, custom AFE, 500 Hz)
//!   SPI1: Limb piezo array (4 sensors, 200 Hz)
//!   SPI2: EOG (electro-olfactogram, 2 channels, 500 Hz)
//!   QSPI: Dorsal EEG grid (16 capacitive electrodes, 250 Hz)
//!
//! Outputs GF(3) trit classifications via the same BLE GATT profile
//! as bci_receiver.zig, with rhino-specific band boundaries.
//! Arrow IPC batches via arrow_color_ipc.zig for bulk transfer.
//! Sub-perceptual residuals analyzed by rhino.zig.

const std = @import("std");
const math = std.math;

// ============================================================================
// RHINO-SPECIFIC CONSTANTS
// ============================================================================

/// Maximum channels per sensor array
pub const MAX_HORN_CHANNELS: usize = 8;
pub const MAX_LIMB_CHANNELS: usize = 4;
pub const MAX_EOG_CHANNELS: usize = 2;
pub const MAX_DORSAL_CHANNELS: usize = 16;
pub const MAX_TOTAL_CHANNELS: usize = MAX_HORN_CHANNELS + MAX_LIMB_CHANNELS + MAX_EOG_CHANNELS + MAX_DORSAL_CHANNELS; // 30

/// Sample rates per modality (Hz)
pub const HORN_SAMPLE_RATE: u16 = 500;
pub const LIMB_SAMPLE_RATE: u16 = 200;
pub const EOG_SAMPLE_RATE: u16 = 500;
pub const DORSAL_SAMPLE_RATE: u16 = 250;

/// Amplifier gain (capacitive coupling needs higher gain than contact)
pub const HORN_GAIN: f32 = 100.0;
pub const LIMB_GAIN: f32 = 200.0; // piezo signal is very small
pub const EOG_GAIN: f32 = 50.0;
pub const DORSAL_GAIN: f32 = 100.0;

/// ADC resolution
pub const ADC_BITS: u8 = 24;
pub const ADC_VREF: f32 = 4.5;

/// Dermal attenuation factor (dB). Signal through 2 cm rhino hide.
pub const DERMAL_ATTENUATION_DB: f32 = 40.0;

/// Ring buffer depth (10 s at processing rate)
pub const RING_DEPTH: usize = 512;

// ============================================================================
// RHINO FREQUENCY BANDS
// ============================================================================

pub const RhinoBand = enum(u3) {
    seismic = 0, // 0.1-2 Hz: ground vibration processing
    infra = 1, // 2-8 Hz: infrasonic social communication
    olfact = 2, // 8-20 Hz: olfactory discrimination
    alert = 3, // 20-50 Hz: threat detection / vigilance
    bind = 4, // 50-150 Hz: multi-sensory binding

    pub fn name(self: RhinoBand) []const u8 {
        return switch (self) {
            .seismic => "seismic",
            .infra => "infra",
            .olfact => "olfact",
            .alert => "alert",
            .bind => "bind",
        };
    }

    pub fn freqRange(self: RhinoBand) [2]f32 {
        return switch (self) {
            .seismic => .{ 0.1, 2.0 },
            .infra => .{ 2.0, 8.0 },
            .olfact => .{ 8.0, 20.0 },
            .alert => .{ 20.0, 50.0 },
            .bind => .{ 50.0, 150.0 },
        };
    }

    /// Map to GF(3) trit.
    /// seismic/infra = MINUS (deep substrate, analogous to human delta/theta)
    /// olfact = ZERO (discriminative equilibrium, analogous to human alpha)
    /// alert/bind = PLUS (active processing, analogous to human beta/gamma)
    pub fn toTrit(self: RhinoBand) Trit {
        return switch (self) {
            .seismic, .infra => .minus,
            .olfact => .zero,
            .alert, .bind => .plus,
        };
    }
};

pub const NUM_BANDS: usize = 5;

// ============================================================================
// GF(3) TRIT
// ============================================================================

pub const Trit = enum(i8) {
    minus = -1,
    zero = 0,
    plus = 1,

    pub fn add(a: Trit, b: Trit) Trit {
        const sum = @as(i8, @intFromEnum(a)) + @as(i8, @intFromEnum(b));
        return switch (@mod(sum + 3, 3)) {
            0 => .zero,
            1 => .plus,
            2 => .minus,
            else => unreachable,
        };
    }

    pub fn neg(self: Trit) Trit {
        return switch (self) {
            .minus => .plus,
            .zero => .zero,
            .plus => .minus,
        };
    }

    pub fn name(self: Trit) []const u8 {
        return switch (self) {
            .minus => "VALIDATOR",
            .zero => "ERGODIC",
            .plus => "GENERATOR",
        };
    }
};

// ============================================================================
// SENSOR MODALITY
// ============================================================================

pub const Modality = enum(u3) {
    horn = 0, // Capacitive array on/near horn base
    limb = 1, // Piezoelectric ground vibration sensors
    eog = 2, // Electro-olfactogram (nasal)
    dorsal = 3, // Dorsal EEG grid (capacitive, through hide)

    pub fn name(self: Modality) []const u8 {
        return switch (self) {
            .horn => "Horn Array",
            .limb => "Limb Piezo",
            .eog => "EOG (Olfactory)",
            .dorsal => "Dorsal EEG Grid",
        };
    }

    pub fn maxChannels(self: Modality) usize {
        return switch (self) {
            .horn => MAX_HORN_CHANNELS,
            .limb => MAX_LIMB_CHANNELS,
            .eog => MAX_EOG_CHANNELS,
            .dorsal => MAX_DORSAL_CHANNELS,
        };
    }

    pub fn sampleRate(self: Modality) u16 {
        return switch (self) {
            .horn => HORN_SAMPLE_RATE,
            .limb => LIMB_SAMPLE_RATE,
            .eog => EOG_SAMPLE_RATE,
            .dorsal => DORSAL_SAMPLE_RATE,
        };
    }

    pub fn gain(self: Modality) f32 {
        return switch (self) {
            .horn => HORN_GAIN,
            .limb => LIMB_GAIN,
            .eog => EOG_GAIN,
            .dorsal => DORSAL_GAIN,
        };
    }

    /// nRF5340 SPI bus assignment
    pub fn spiBus(self: Modality) u8 {
        return switch (self) {
            .horn => 0,
            .limb => 1,
            .eog => 2,
            .dorsal => 3, // QSPI
        };
    }

    /// Scale factor: ADC counts to microvolts, accounting for dermal attenuation
    pub fn scaleFactor(self: Modality) f64 {
        const g: f64 = @floatCast(self.gain());
        const base_scale = (@as(f64, ADC_VREF) / (g * @as(f64, @floatFromInt(@as(u64, 1) << ADC_BITS)))) * 1e6;
        // Compensate for dermal attenuation (add back the lost dB)
        const attenuation_linear = math.pow(f64, 10.0, @as(f64, DERMAL_ATTENUATION_DB) / 20.0);
        return base_scale * attenuation_linear;
    }
};

// ============================================================================
// RHINO BAND POWERS
// ============================================================================

pub const RhinoBandPowers = struct {
    seismic: f32 = 0,
    infra: f32 = 0,
    olfact: f32 = 0,
    alert: f32 = 0,
    bind: f32 = 0,

    pub fn asArray(self: RhinoBandPowers) [NUM_BANDS]f32 {
        return .{ self.seismic, self.infra, self.olfact, self.alert, self.bind };
    }

    pub fn shannonEntropy(self: RhinoBandPowers) f32 {
        const total = self.seismic + self.infra + self.olfact + self.alert + self.bind;
        if (total <= 0) return 0;
        var entropy: f32 = 0;
        for (self.asArray()) |p| {
            if (p > 0) {
                const prob = p / total;
                entropy -= prob * @log2(prob);
            }
        }
        return entropy;
    }

    pub fn dominantBand(self: RhinoBandPowers) RhinoBand {
        const powers = self.asArray();
        var max_idx: usize = 0;
        var max_val: f32 = powers[0];
        for (powers[1..], 1..) |p, i| {
            if (p > max_val) {
                max_val = p;
                max_idx = i;
            }
        }
        return @enumFromInt(@as(u3, @intCast(max_idx)));
    }

    pub fn dominantTrit(self: RhinoBandPowers) Trit {
        return self.dominantBand().toTrit();
    }

    /// Olfactory valence: olfact / total, normalized to [-1, +1].
    /// Analogous to human alpha-based valence.
    pub fn olfactoryValence(self: RhinoBandPowers) f32 {
        const total = self.seismic + self.infra + self.olfact + self.alert + self.bind;
        if (total <= 0) return 0;
        return 2.0 * (self.olfact / total) - 1.0;
    }

    /// Seismic-to-alert ratio: environmental awareness index.
    /// High seismic + low alert = relaxed grazing.
    /// Low seismic + high alert = threat response.
    pub fn vigilanceIndex(self: RhinoBandPowers) f32 {
        const denom = self.seismic + self.alert;
        if (denom <= 0) return 0;
        return self.alert / denom;
    }

    /// Pack into 10 bytes for BLE (5 x f16)
    pub fn packBLE(self: RhinoBandPowers) [10]u8 {
        var buf: [10]u8 = undefined;
        for (self.asArray(), 0..) |f, i| {
            const h: u16 = @bitCast(@as(f16, @floatCast(f)));
            buf[i * 2] = @truncate(h);
            buf[i * 2 + 1] = @truncate(h >> 8);
        }
        return buf;
    }
};

// ============================================================================
// ELECTRODE PLACEMENT — Rhinoceros 10-20 Analog
// ============================================================================

/// Rhinoceros electrode sites.
/// Named by anatomical landmark rather than human 10-20 convention.
pub const ElectrodeSite = enum(u8) {
    // Horn array (capacitive, 8 channels)
    horn_base_left = 0,
    horn_base_right = 1,
    horn_mid_left = 2,
    horn_mid_right = 3,
    horn_tip_left = 4,
    horn_tip_right = 5,
    nasal_bridge_left = 6,
    nasal_bridge_right = 7,

    // Limb piezo (4 channels)
    front_left_foot = 8,
    front_right_foot = 9,
    rear_left_foot = 10,
    rear_right_foot = 11,

    // EOG (2 channels)
    olfactory_left = 12,
    olfactory_right = 13,

    // Dorsal EEG grid (16 channels, capacitive)
    dorsal_frontal_left = 14,
    dorsal_frontal_right = 15,
    dorsal_frontal_mid = 16,
    dorsal_temporal_left = 17,
    dorsal_temporal_right = 18,
    dorsal_parietal_left = 19,
    dorsal_parietal_right = 20,
    dorsal_parietal_mid = 21,
    dorsal_occipital_left = 22,
    dorsal_occipital_right = 23,
    dorsal_occipital_mid = 24,
    dorsal_central_left = 25,
    dorsal_central_right = 26,
    dorsal_central_mid = 27,
    dorsal_vertex = 28,
    dorsal_inion = 29,

    pub fn modality(self: ElectrodeSite) Modality {
        const idx = @intFromEnum(self);
        if (idx < 8) return .horn;
        if (idx < 12) return .limb;
        if (idx < 14) return .eog;
        return .dorsal;
    }

    pub fn name(self: ElectrodeSite) []const u8 {
        return @tagName(self);
    }
};

// ============================================================================
// DEVICE CONFIGURATION
// ============================================================================

pub const DeviceConfig = struct {
    /// Bitmask of active electrode sites
    active_channels: u32 = 0x3FFFFFFF, // all 30 channels
    /// GF(3) entropy thresholds (rhino-calibrated)
    high_threshold: f32 = 1.8,
    low_threshold: f32 = 0.8,
    /// Dermal compensation enabled (capacitive coupling correction)
    dermal_compensation: bool = true,
    /// Horn waveguide correction (de-emphasize EM resonances)
    horn_waveguide_correction: bool = true,
    /// Seismic baseline subtraction (remove ambient ground vibration)
    seismic_baseline_subtraction: bool = true,

    pub fn isChannelActive(self: DeviceConfig, site: ElectrodeSite) bool {
        return (self.active_channels & (@as(u32, 1) << @intFromEnum(site))) != 0;
    }

    pub fn activeCount(self: DeviceConfig) u8 {
        return @popCount(self.active_channels);
    }
};

// ============================================================================
// RHINO BCI READING
// ============================================================================

pub const RhinoReading = struct {
    timestamp_ms: u64,
    channels: [MAX_TOTAL_CHANNELS]f32, // all 30 channels in microvolts
    n_active: u8,
    band_powers: RhinoBandPowers,
    trit: Trit,
    vigilance: f32,
    olfactory_valence: f32,
    entropy: f32,

    pub fn fromBandPowers(powers: RhinoBandPowers, timestamp_ms: u64) RhinoReading {
        return .{
            .timestamp_ms = timestamp_ms,
            .channels = std.mem.zeroes([MAX_TOTAL_CHANNELS]f32),
            .n_active = 0,
            .band_powers = powers,
            .trit = powers.dominantTrit(),
            .vigilance = powers.vigilanceIndex(),
            .olfactory_valence = powers.olfactoryValence(),
            .entropy = powers.shannonEntropy(),
        };
    }
};

// ============================================================================
// CROSS-SPECIES TRANSLATION
// ============================================================================

/// Map rhino bands to human bands for interspecies BCI bridge.
/// Preserves GF(3) trit assignment across the translation.
pub fn rhinoToHumanBand(band: RhinoBand) HumanBandEquiv {
    return switch (band) {
        .seismic => .{ .human_name = "delta", .freq_lo = 0.5, .freq_hi = 4.0, .trit = .minus },
        .infra => .{ .human_name = "theta", .freq_lo = 4.0, .freq_hi = 8.0, .trit = .minus },
        .olfact => .{ .human_name = "alpha", .freq_lo = 8.0, .freq_hi = 13.0, .trit = .zero },
        .alert => .{ .human_name = "beta", .freq_lo = 13.0, .freq_hi = 30.0, .trit = .plus },
        .bind => .{ .human_name = "gamma", .freq_lo = 30.0, .freq_hi = 100.0, .trit = .plus },
    };
}

pub const HumanBandEquiv = struct {
    human_name: []const u8,
    freq_lo: f32,
    freq_hi: f32,
    trit: Trit,
};

/// Translate RhinoBandPowers to human-equivalent BandPowers structure.
/// Frequency ranges differ but GF(3) trit conservation is preserved.
pub fn translateToHumanBands(rhino: RhinoBandPowers) HumanEquivPowers {
    return .{
        .delta = rhino.seismic,
        .theta = rhino.infra,
        .alpha = rhino.olfact,
        .beta = rhino.alert,
        .gamma = rhino.bind,
        .trit = rhino.dominantTrit(),
    };
}

pub const HumanEquivPowers = struct {
    delta: f32,
    theta: f32,
    alpha: f32,
    beta: f32,
    gamma: f32,
    trit: Trit,

    pub fn shannonEntropy(self: HumanEquivPowers) f32 {
        const total = self.delta + self.theta + self.alpha + self.beta + self.gamma;
        if (total <= 0) return 0;
        var entropy: f32 = 0;
        const powers = [_]f32{ self.delta, self.theta, self.alpha, self.beta, self.gamma };
        for (powers) |p| {
            if (p > 0) {
                const prob = p / total;
                entropy -= prob * @log2(prob);
            }
        }
        return entropy;
    }
};

// ===========================================================================
// Tests
// ===========================================================================

test "rhino band frequency ranges are contiguous and non-overlapping" {
    const bands = [_]RhinoBand{ .seismic, .infra, .olfact, .alert, .bind };
    for (bands[0 .. bands.len - 1], bands[1..]) |lo, hi| {
        const lo_range = lo.freqRange();
        const hi_range = hi.freqRange();
        try std.testing.expectEqual(lo_range[1], hi_range[0]);
    }
}

test "rhino bands cover 0.1 Hz to 150 Hz" {
    try std.testing.expect(RhinoBand.seismic.freqRange()[0] == 0.1);
    try std.testing.expect(RhinoBand.bind.freqRange()[1] == 150.0);
}

test "GF(3) trit assignment: seismic/infra=minus, olfact=zero, alert/bind=plus" {
    try std.testing.expectEqual(Trit.minus, RhinoBand.seismic.toTrit());
    try std.testing.expectEqual(Trit.minus, RhinoBand.infra.toTrit());
    try std.testing.expectEqual(Trit.zero, RhinoBand.olfact.toTrit());
    try std.testing.expectEqual(Trit.plus, RhinoBand.alert.toTrit());
    try std.testing.expectEqual(Trit.plus, RhinoBand.bind.toTrit());
}

test "electrode site modality assignment" {
    try std.testing.expectEqual(Modality.horn, ElectrodeSite.horn_base_left.modality());
    try std.testing.expectEqual(Modality.limb, ElectrodeSite.front_left_foot.modality());
    try std.testing.expectEqual(Modality.eog, ElectrodeSite.olfactory_left.modality());
    try std.testing.expectEqual(Modality.dorsal, ElectrodeSite.dorsal_vertex.modality());
}

test "30 total electrode sites" {
    try std.testing.expectEqual(@as(usize, 30), MAX_TOTAL_CHANNELS);
}

test "band powers dominant band" {
    const powers = RhinoBandPowers{
        .seismic = 0.1,
        .infra = 0.2,
        .olfact = 0.8,
        .alert = 0.3,
        .bind = 0.1,
    };
    try std.testing.expectEqual(RhinoBand.olfact, powers.dominantBand());
    try std.testing.expectEqual(Trit.zero, powers.dominantTrit());
}

test "vigilance index: alert-dominant = high vigilance" {
    const relaxed = RhinoBandPowers{ .seismic = 0.8, .infra = 0.1, .olfact = 0.0, .alert = 0.1, .bind = 0.0 };
    const alert = RhinoBandPowers{ .seismic = 0.1, .infra = 0.0, .olfact = 0.0, .alert = 0.8, .bind = 0.1 };
    try std.testing.expect(relaxed.vigilanceIndex() < 0.3);
    try std.testing.expect(alert.vigilanceIndex() > 0.7);
}

test "olfactory valence range" {
    const olfact_dom = RhinoBandPowers{ .seismic = 0.0, .infra = 0.0, .olfact = 1.0, .alert = 0.0, .bind = 0.0 };
    const val = olfact_dom.olfactoryValence();
    // Olfact = 1.0 of total 1.0, valence = 2*(1) - 1 = 1.0
    try std.testing.expectEqual(@as(f32, 1.0), val);
}

test "shannon entropy of uniform distribution" {
    const uniform = RhinoBandPowers{ .seismic = 1, .infra = 1, .olfact = 1, .alert = 1, .bind = 1 };
    const e = uniform.shannonEntropy();
    // log2(5) ~ 2.322
    try std.testing.expect(e > 2.3 and e < 2.4);
}

test "BLE pack roundtrip" {
    const powers = RhinoBandPowers{
        .seismic = 0.5,
        .infra = 1.0,
        .olfact = 0.25,
        .alert = 2.0,
        .bind = 0.125,
    };
    const ble_bytes = powers.packBLE();
    // Verify we can unpack (f16 roundtrip)
    for (powers.asArray(), 0..) |orig, i| {
        const h: f16 = @bitCast([2]u8{ ble_bytes[i * 2], ble_bytes[i * 2 + 1] });
        const recovered: f32 = @floatCast(h);
        try std.testing.expect(@abs(orig - recovered) < 0.01);
    }
}

test "cross-species translation preserves GF(3) trit" {
    const rhino = RhinoBandPowers{
        .seismic = 0.1,
        .infra = 0.1,
        .olfact = 0.5,
        .alert = 0.2,
        .bind = 0.1,
    };
    const human = translateToHumanBands(rhino);
    try std.testing.expectEqual(rhino.dominantTrit(), human.trit);
    // Alpha (human) = olfact (rhino)
    try std.testing.expectEqual(rhino.olfact, human.alpha);
}

test "device config active channel count" {
    const cfg = DeviceConfig{};
    try std.testing.expectEqual(@as(u8, 30), cfg.activeCount());

    const partial = DeviceConfig{ .active_channels = 0xFF }; // only horn array
    try std.testing.expectEqual(@as(u8, 8), partial.activeCount());
}

test "modality scale factors account for dermal attenuation" {
    const horn_scale = Modality.horn.scaleFactor();
    const limb_scale = Modality.limb.scaleFactor();
    // Both should be positive and finite
    try std.testing.expect(horn_scale > 0 and !math.isNan(horn_scale));
    try std.testing.expect(limb_scale > 0 and !math.isNan(limb_scale));
    // Limb has higher gain -> different scale
    try std.testing.expect(horn_scale != limb_scale);
}

test "reading from band powers" {
    const powers = RhinoBandPowers{ .seismic = 0.1, .infra = 0.5, .olfact = 0.2, .alert = 0.1, .bind = 0.1 };
    const reading = RhinoReading.fromBandPowers(powers, 1000);
    try std.testing.expectEqual(@as(u64, 1000), reading.timestamp_ms);
    try std.testing.expectEqual(Trit.minus, reading.trit); // infra dominant
    try std.testing.expect(reading.entropy > 0);
}

test "rhino to human band mapping is complete" {
    const bands = [_]RhinoBand{ .seismic, .infra, .olfact, .alert, .bind };
    for (bands) |b| {
        const equiv = rhinoToHumanBand(b);
        try std.testing.expect(equiv.freq_hi > equiv.freq_lo);
        try std.testing.expect(equiv.human_name.len > 0);
    }
}

test "all modalities have valid SPI bus assignment" {
    const mods = [_]Modality{ .horn, .limb, .eog, .dorsal };
    for (mods) |m| {
        try std.testing.expect(m.spiBus() <= 3);
        try std.testing.expect(m.sampleRate() >= 100);
        try std.testing.expect(m.gain() > 0);
    }
}
