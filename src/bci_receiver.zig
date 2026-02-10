//! bci_receiver.zig — Universal BCI Receiver (nRF5340)
//!
//! Accepts signals from ANY brain interface (invasive or non-invasive)
//! and outputs standardized GF(3)-classified color signals via OCapN/Syrup.
//!
//! Architecture (nRF5340 dual-core):
//!
//!   APPLICATION CORE (Cortex-M33, 128MHz, 1MB Flash, 512KB RAM):
//!     SPI0 → EEG Frontend (OpenBCI/Intan, 8-64ch, 250-1000Hz)
//!     SPI1 → Ultrasound ADC (focused ultrasound feedback, 1ch, 100Hz)
//!     SPI2 → EMG/ENG (peripheral nerve, 1-8ch, 500Hz)
//!     QSPI → ECoG adapter (future, 32ch, 2000Hz)
//!
//!     Signal pipeline:
//!       Raw samples → Band-power FFT → Shannon entropy
//!         → GF(3) trit classification → Fisher-Rao distance
//!         → PhenomenalState → BCIReading → Ring buffer
//!
//!   NETWORK CORE (Cortex-M33, 64MHz, 256KB Flash, 64KB RAM):
//!     BLE 5.3 GATT → real-time trit stream (20ms intervals)
//!     USB HID → wired host connection (1ms polling)
//!     OCapN/Syrup framing over both transports
//!
//!   SPI Bus Topology:
//!     ┌──────────┐     SPI0 (8MHz)     ┌─────────────────┐
//!     │          │─────────────────────→│ EEG (Intan/OBC) │
//!     │          │     SPI1 (4MHz)      ├─────────────────┤
//!     │ nRF5340  │─────────────────────→│ Ultrasound ADC  │
//!     │ App Core │     SPI2 (4MHz)      ├─────────────────┤
//!     │          │─────────────────────→│ EMG/ENG AFE     │
//!     │          │     QSPI (32MHz)     ├─────────────────┤
//!     │          │═════════════════════→│ ECoG (future)   │
//!     └──────────┘                      └─────────────────┘
//!          │ IPC (shared RAM)
//!          ▼
//!     ┌──────────┐
//!     │ nRF5340  │──→ BLE 5.3 GATT (trit stream)
//!     │ Net Core │──→ USB HID (wired)
//!     └──────────┘
//!
//!   BLE GATT Service Layout:
//!     Service: 0xBCI0 (BCI Factory Primary Service)
//!       UUID: 6e400001-b5a3-f393-e0a9-e50e24dcca9e (Nordic UART base, repurposed)
//!
//!     Characteristics:
//!       0xBCI1 — Trit Stream (Notify, 20-byte packets)
//!         [timestamp_ms:u32][n_channels:u8][trits:u8[n]][color_r:u8][color_g:u8][color_b:u8]
//!       0xBCI2 — Band Powers (Notify, per-channel, 20-byte packets)
//!         [channel:u8][delta:f16][theta:f16][alpha:f16][beta:f16][gamma:f16][entropy:f16]
//!       0xBCI3 — Phenomenal State (Notify, 16-byte packets)
//!         [phi:f16][valence:f16][entropy:f16][trit:i8][confidence:f16][timestamp_ms:u32]
//!       0xBCI4 — Device Info (Read)
//!         [fw_ver:u16][n_sensors:u8][modalities:u8][sample_rate:u16][serial:u32]
//!       0xBCI5 — Configuration (Read/Write)
//!         [active_channels:u64 bitmask][sample_rate:u16][trit_threshold:f16[2]]
//!
//!   GF(3) classification thresholds (configurable via 0xBCI5):
//!     +1 (GENERATOR): band entropy > high_threshold (active cognition)
//!      0 (ERGODIC):   baseline range
//!     -1 (VALIDATOR): band entropy < low_threshold (suppression/rest)
//!
//!   Conservation law: Σ trit across all channels in a reading tends → 0
//!   (enforced softly; hard violation triggers recalibration)
//!
//!   License: MIT OR Apache-2.0
//!   Hardware reference design: CC-BY-SA-4.0

const std = @import("std");
const syrup = @import("syrup");
const Allocator = std.mem.Allocator;

// ============================================================================
// CONSTANTS
// ============================================================================

/// Maximum EEG channels supported
pub const MAX_EEG_CHANNELS: usize = 64;

/// Maximum EMG/ENG channels
pub const MAX_EMG_CHANNELS: usize = 8;

/// Maximum total channels across all modalities
pub const MAX_CHANNELS: usize = MAX_EEG_CHANNELS + MAX_EMG_CHANNELS + 1 + 32;
// 64 EEG + 8 EMG + 1 ultrasound + 32 ECoG = 105

/// Ring buffer depth (10s at 50Hz processing rate = 500 readings)
pub const RING_DEPTH: usize = 512;

/// FFT window size (256 samples = ~1s at 250Hz)
pub const FFT_WINDOW: usize = 256;

/// Band frequency boundaries (Hz)
pub const BAND_DELTA_LO: f32 = 0.5;
pub const BAND_DELTA_HI: f32 = 4.0;
pub const BAND_THETA_HI: f32 = 8.0;
pub const BAND_ALPHA_HI: f32 = 13.0;
pub const BAND_BETA_HI: f32 = 30.0;
pub const BAND_GAMMA_HI: f32 = 100.0;

/// Default GF(3) entropy thresholds
pub const DEFAULT_HIGH_THRESHOLD: f32 = 2.0; // bits — above = +1
pub const DEFAULT_LOW_THRESHOLD: f32 = 1.0; // bits — below = -1

/// BLE GATT UUIDs (128-bit, Nordic UART Service base)
pub const UUID_BCI_SERVICE = [16]u8{
    0x6e, 0x40, 0x00, 0x01, 0xb5, 0xa3, 0xf3, 0x93,
    0xe0, 0xa9, 0xe5, 0x0e, 0x24, 0xdc, 0xca, 0x9e,
};
pub const UUID_TRIT_STREAM = [16]u8{
    0x6e, 0x40, 0x00, 0x02, 0xb5, 0xa3, 0xf3, 0x93,
    0xe0, 0xa9, 0xe5, 0x0e, 0x24, 0xdc, 0xca, 0x9e,
};
pub const UUID_BAND_POWERS = [16]u8{
    0x6e, 0x40, 0x00, 0x03, 0xb5, 0xa3, 0xf3, 0x93,
    0xe0, 0xa9, 0xe5, 0x0e, 0x24, 0xdc, 0xca, 0x9e,
};
pub const UUID_PHENOMENAL = [16]u8{
    0x6e, 0x40, 0x00, 0x04, 0xb5, 0xa3, 0xf3, 0x93,
    0xe0, 0xa9, 0xe5, 0x0e, 0x24, 0xdc, 0xca, 0x9e,
};
pub const UUID_DEVICE_INFO = [16]u8{
    0x6e, 0x40, 0x00, 0x05, 0xb5, 0xa3, 0xf3, 0x93,
    0xe0, 0xa9, 0xe5, 0x0e, 0x24, 0xdc, 0xca, 0x9e,
};
pub const UUID_CONFIG = [16]u8{
    0x6e, 0x40, 0x00, 0x06, 0xb5, 0xa3, 0xf3, 0x93,
    0xe0, 0xa9, 0xe5, 0x0e, 0x24, 0xdc, 0xca, 0x9e,
};

/// Gay.jl color chain references
pub const COLOR_GENERATOR = RGB{ .r = 0x00, .g = 0xE1, .b = 0xA9 }; // +1
pub const COLOR_ERGODIC = RGB{ .r = 0xFF, .g = 0xE6, .b = 0x4E }; // 0
pub const COLOR_VALIDATOR = RGB{ .r = 0xF5, .g = 0x00, .b = 0x26 }; // -1

/// Firmware version
pub const FW_VERSION: u16 = 0x0100; // 1.0

// ============================================================================
// GF(3) TRIT — matches passport.zig / tapo_energy.zig / continuation.zig
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

    pub fn color(self: Trit) RGB {
        return switch (self) {
            .plus => COLOR_GENERATOR,
            .zero => COLOR_ERGODIC,
            .minus => COLOR_VALIDATOR,
        };
    }

    pub fn toSyrup(self: Trit) syrup.Value {
        return .{ .int = @as(i64, @intFromEnum(self)) };
    }
};

// ============================================================================
// COLOR
// ============================================================================

pub const RGB = struct {
    r: u8,
    g: u8,
    b: u8,

    pub fn toSyrup(self: RGB) syrup.Value {
        return .{ .list = &[_]syrup.Value{
            .{ .int = self.r },
            .{ .int = self.g },
            .{ .int = self.b },
        } };
    }
};

// ============================================================================
// SENSOR MODALITY
// ============================================================================

pub const Modality = enum(u8) {
    eeg = 0,
    ultrasound = 1,
    emg = 2,
    eng = 3,
    ecog = 4,
    fnirs = 5,

    pub fn name(self: Modality) []const u8 {
        return switch (self) {
            .eeg => "EEG",
            .ultrasound => "Ultrasound",
            .emg => "EMG",
            .eng => "ENG",
            .ecog => "ECoG",
            .fnirs => "fNIRS",
        };
    }

    pub fn maxChannels(self: Modality) usize {
        return switch (self) {
            .eeg => MAX_EEG_CHANNELS,
            .ultrasound => 1,
            .emg => MAX_EMG_CHANNELS,
            .eng => MAX_EMG_CHANNELS,
            .ecog => 32,
            .fnirs => 8,
        };
    }

    pub fn defaultSampleRate(self: Modality) u16 {
        return switch (self) {
            .eeg => 250,
            .ultrasound => 100,
            .emg => 500,
            .eng => 500,
            .ecog => 2000,
            .fnirs => 10,
        };
    }

    /// SPI bus assignment on nRF5340
    pub fn spiBus(self: Modality) u8 {
        return switch (self) {
            .eeg => 0, // SPI0, 8MHz
            .ultrasound => 1, // SPI1, 4MHz
            .emg, .eng => 2, // SPI2, 4MHz
            .ecog => 3, // QSPI, 32MHz
            .fnirs => 1, // shared with ultrasound (time-multiplexed)
        };
    }
};

// ============================================================================
// BAND POWERS — matches passport.zig exactly
// ============================================================================

pub const BandPowers = struct {
    delta: f32 = 0, // 0.5–4.0 Hz
    theta: f32 = 0, // 4.0–8.0 Hz
    alpha: f32 = 0, // 8.0–13.0 Hz
    beta: f32 = 0, // 13.0–30.0 Hz
    gamma: f32 = 0, // 30.0–100.0 Hz

    /// Shannon entropy of band distribution (bits)
    pub fn shannonEntropy(self: BandPowers) f32 {
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

    /// Dominant band as trit (delta/theta → -1, alpha → 0, beta/gamma → +1)
    pub fn dominantTrit(self: BandPowers) Trit {
        const powers = [_]f32{ self.delta, self.theta, self.alpha, self.beta, self.gamma };
        const trits = [_]Trit{ .minus, .minus, .zero, .plus, .plus };
        var max_idx: usize = 0;
        var max_val: f32 = powers[0];
        for (powers[1..], 1..) |p, i| {
            if (p > max_val) {
                max_val = p;
                max_idx = i;
            }
        }
        return trits[max_idx];
    }

    /// Classify to trit via entropy thresholds
    pub fn classifyEntropy(self: BandPowers, high: f32, low: f32) Trit {
        const e = self.shannonEntropy();
        if (e > high) return .plus;
        if (e < low) return .minus;
        return .zero;
    }

    /// Valence from alpha power: 2*alpha_norm - 1
    pub fn valence(self: BandPowers) f32 {
        const total = self.delta + self.theta + self.alpha + self.beta + self.gamma;
        if (total <= 0) return 0;
        return 2.0 * (self.alpha / total) - 1.0;
    }

    /// Pack into 10 bytes for BLE (5 × f16)
    pub fn packBLE(self: BandPowers) [10]u8 {
        var buf: [10]u8 = undefined;
        const fields = [_]f32{ self.delta, self.theta, self.alpha, self.beta, self.gamma };
        for (fields, 0..) |f, i| {
            const h: u16 = @bitCast(@as(f16, @floatCast(f)));
            buf[i * 2] = @truncate(h);
            buf[i * 2 + 1] = @truncate(h >> 8);
        }
        return buf;
    }
};

// ============================================================================
// BCI READING — the standardized output
// ============================================================================

pub const BCIReading = struct {
    timestamp_ms: u64,
    n_channels: u8,
    channels: [MAX_CHANNELS]Trit,
    band_powers: BandPowers, // aggregate (mean across channels)
    phenomenal_state: f32, // Fisher-Rao distance from baseline
    color: RGB, // Gay.jl color chain mapping
    modality_mask: u8, // bitmask of active modalities

    pub fn classify(band: BandPowers, high_thresh: f32, low_thresh: f32) struct { trit: Trit, color: RGB } {
        const trit = band.classifyEntropy(high_thresh, low_thresh);
        return .{ .trit = trit, .color = trit.color() };
    }

    /// Compute aggregate trit from all channels
    pub fn aggregateTrit(self: *const BCIReading) Trit {
        var sum: i32 = 0;
        for (self.channels[0..self.n_channels]) |t| {
            sum += @intFromEnum(t);
        }
        // Map sum to trit via majority vote
        if (sum > 0) return .plus;
        if (sum < 0) return .minus;
        return .zero;
    }

    /// GF(3) balance check: how far from conservation?
    pub fn gf3Imbalance(self: *const BCIReading) i32 {
        var sum: i32 = 0;
        for (self.channels[0..self.n_channels]) |t| {
            sum += @intFromEnum(t);
        }
        return sum;
    }

    /// Pack trit stream for BLE characteristic 0xBCI1 (max 20 bytes)
    /// Format: [ts:u32][n:u8][trits:u8[n]][r:u8][g:u8][b:u8]
    pub fn packTritStream(self: *const BCIReading) [20]u8 {
        var buf = [_]u8{0} ** 20;
        // Timestamp (lower 32 bits)
        const ts: u32 = @truncate(self.timestamp_ms);
        buf[0] = @truncate(ts);
        buf[1] = @truncate(ts >> 8);
        buf[2] = @truncate(ts >> 16);
        buf[3] = @truncate(ts >> 24);
        // Channel count
        const n = @min(self.n_channels, 14); // max 14 trits fit in 20-byte packet
        buf[4] = n;
        // Trits (packed 1 byte each as signed)
        for (0..n) |i| {
            buf[5 + i] = @bitCast(@intFromEnum(self.channels[i]));
        }
        // Color at end
        buf[17] = self.color.r;
        buf[18] = self.color.g;
        buf[19] = self.color.b;
        return buf;
    }

    /// Serialize to OCapN/Syrup record
    pub fn toSyrup(self: *const BCIReading, allocator: Allocator) !syrup.Value {
        var entries = std.ArrayList(syrup.Value).init(allocator);

        try entries.append(.{ .symbol = "bci-reading" });
        try entries.append(.{ .int = @intCast(self.timestamp_ms) });
        try entries.append(.{ .int = self.n_channels });

        // Channel trits as list
        var trit_list = std.ArrayList(syrup.Value).init(allocator);
        for (self.channels[0..self.n_channels]) |t| {
            try trit_list.append(t.toSyrup());
        }
        try entries.append(.{ .list = try trit_list.toOwnedSlice() });

        // Band powers
        try entries.append(.{ .symbol = "bands" });
        try entries.append(.{ .float = self.band_powers.delta });
        try entries.append(.{ .float = self.band_powers.theta });
        try entries.append(.{ .float = self.band_powers.alpha });
        try entries.append(.{ .float = self.band_powers.beta });
        try entries.append(.{ .float = self.band_powers.gamma });

        // Phenomenal state
        try entries.append(.{ .symbol = "phenomenal" });
        try entries.append(.{ .float = self.phenomenal_state });

        // Color
        try entries.append(.{ .symbol = "color" });
        try entries.append(self.color.toSyrup());

        return .{ .record = try entries.toOwnedSlice() };
    }
};

// ============================================================================
// RING BUFFER — bounded memory, zero allocation after init
// ============================================================================

pub const ReadingRing = struct {
    buf: [RING_DEPTH]BCIReading = undefined,
    head: usize = 0,
    count: usize = 0,
    trit_sum: i32 = 0,

    pub fn push(self: *ReadingRing, reading: BCIReading) void {
        if (self.count == RING_DEPTH) {
            // Subtract outgoing reading's aggregate trit
            const old = &self.buf[self.head];
            self.trit_sum -= old.gf3Imbalance();
        }
        self.buf[self.head] = reading;
        self.trit_sum += reading.gf3Imbalance();
        self.head = (self.head + 1) % RING_DEPTH;
        if (self.count < RING_DEPTH) self.count += 1;
    }

    pub fn latest(self: *const ReadingRing) ?*const BCIReading {
        if (self.count == 0) return null;
        const idx = if (self.head == 0) RING_DEPTH - 1 else self.head - 1;
        return &self.buf[idx];
    }

    /// Running GF(3) balance across all readings in buffer
    pub fn gf3Balance(self: *const ReadingRing) i32 {
        return self.trit_sum;
    }

    /// Should we recalibrate? (GF(3) imbalance exceeds threshold)
    pub fn needsRecalibration(self: *const ReadingRing, threshold: i32) bool {
        return @abs(self.trit_sum) > threshold;
    }
};

// ============================================================================
// SENSOR CONFIGURATION
// ============================================================================

pub const SensorConfig = struct {
    modality: Modality,
    active_channels: u64, // bitmask
    sample_rate: u16,
    high_threshold: f32, // GF(3) +1 boundary
    low_threshold: f32, // GF(3) -1 boundary
    enabled: bool,

    pub fn channelCount(self: SensorConfig) u8 {
        return @popCount(self.active_channels);
    }

    pub fn default(modality: Modality) SensorConfig {
        const n = modality.maxChannels();
        const mask: u64 = if (n >= 64) ~@as(u64, 0) else (@as(u64, 1) << @intCast(n)) - 1;
        return .{
            .modality = modality,
            .active_channels = mask,
            .sample_rate = modality.defaultSampleRate(),
            .high_threshold = DEFAULT_HIGH_THRESHOLD,
            .low_threshold = DEFAULT_LOW_THRESHOLD,
            .enabled = true,
        };
    }
};

// ============================================================================
// FISHER-RAO METRIC — phenomenal state distance
// ============================================================================

/// Compute Fisher-Rao distance between two band power distributions.
/// D²(p,q) = Σ(√pᵢ - √qᵢ)²
/// Returns engagement angle φ = (π/2) × D/√2 ∈ [0, π/2]
pub fn fisherRaoDistance(current: BandPowers, baseline: BandPowers) f32 {
    const p = [_]f32{ current.delta, current.theta, current.alpha, current.beta, current.gamma };
    const q = [_]f32{ baseline.delta, baseline.theta, baseline.alpha, baseline.beta, baseline.gamma };

    var p_total: f32 = 0;
    var q_total: f32 = 0;
    for (p) |v| p_total += v;
    for (q) |v| q_total += v;
    if (p_total <= 0) p_total = 1;
    if (q_total <= 0) q_total = 1;

    var d_sq: f32 = 0;
    for (0..5) |i| {
        const diff = @sqrt(p[i] / p_total) - @sqrt(q[i] / q_total);
        d_sq += diff * diff;
    }
    const d = @sqrt(d_sq);
    return (std.math.pi / 2.0) * (d / @sqrt(@as(f32, 2.0)));
}

// ============================================================================
// DEVICE STATE — full receiver state machine
// ============================================================================

pub const DeviceState = enum {
    idle, // powered on, not acquiring
    calibrating, // collecting baseline (first 30 epochs)
    acquiring, // normal operation
    streaming, // BLE/USB active
    sensor_error, // sensor fault
    recalibrating, // GF(3) imbalance detected

    pub fn name(self: DeviceState) []const u8 {
        return switch (self) {
            .idle => "IDLE",
            .calibrating => "CALIBRATING",
            .acquiring => "ACQUIRING",
            .streaming => "STREAMING",
            .sensor_error => "ERROR",
            .recalibrating => "RECALIBRATING",
        };
    }
};

pub const UniversalReceiver = struct {
    sensors: [6]SensorConfig, // one per Modality
    baseline: BandPowers, // calibration baseline
    ring: ReadingRing,
    state: DeviceState,
    epoch_count: u64,
    calibration_epochs: u32,
    serial: u32,

    const CALIBRATION_TARGET: u32 = 30; // ~6 seconds at 5Hz
    const RECALIBRATION_THRESHOLD: i32 = 50; // trit imbalance trigger

    pub fn init(serial: u32) UniversalReceiver {
        var sensors: [6]SensorConfig = undefined;
        sensors[@intFromEnum(Modality.eeg)] = SensorConfig.default(.eeg);
        sensors[@intFromEnum(Modality.ultrasound)] = SensorConfig.default(.ultrasound);
        sensors[@intFromEnum(Modality.emg)] = SensorConfig.default(.emg);
        sensors[@intFromEnum(Modality.eng)] = SensorConfig.default(.eng);
        sensors[@intFromEnum(Modality.ecog)] = SensorConfig.default(.ecog);
        sensors[@intFromEnum(Modality.fnirs)] = SensorConfig.default(.fnirs);

        // Disable ECoG and fNIRS by default (future modalities)
        sensors[@intFromEnum(Modality.ecog)].enabled = false;
        sensors[@intFromEnum(Modality.fnirs)].enabled = false;

        return .{
            .sensors = sensors,
            .baseline = .{},
            .ring = .{},
            .state = .idle,
            .epoch_count = 0,
            .calibration_epochs = 0,
            .serial = serial,
        };
    }

    /// Process one epoch of raw band powers from all active sensors
    pub fn processEpoch(self: *UniversalReceiver, bands_per_channel: []const BandPowers, timestamp_ms: u64) BCIReading {
        var reading: BCIReading = .{
            .timestamp_ms = timestamp_ms,
            .n_channels = @intCast(@min(bands_per_channel.len, MAX_CHANNELS)),
            .channels = [_]Trit{.zero} ** MAX_CHANNELS,
            .band_powers = .{},
            .phenomenal_state = 0,
            .color = COLOR_ERGODIC,
            .modality_mask = 0,
        };

        // Aggregate band powers
        var total_delta: f32 = 0;
        var total_theta: f32 = 0;
        var total_alpha: f32 = 0;
        var total_beta: f32 = 0;
        var total_gamma: f32 = 0;

        for (bands_per_channel, 0..) |band, i| {
            if (i >= MAX_CHANNELS) break;

            // Per-channel trit classification
            reading.channels[i] = band.classifyEntropy(
                DEFAULT_HIGH_THRESHOLD,
                DEFAULT_LOW_THRESHOLD,
            );

            total_delta += band.delta;
            total_theta += band.theta;
            total_alpha += band.alpha;
            total_beta += band.beta;
            total_gamma += band.gamma;
        }

        const n_f: f32 = @floatFromInt(@max(reading.n_channels, 1));
        reading.band_powers = .{
            .delta = total_delta / n_f,
            .theta = total_theta / n_f,
            .alpha = total_alpha / n_f,
            .beta = total_beta / n_f,
            .gamma = total_gamma / n_f,
        };

        // Calibration phase: accumulate baseline
        if (self.state == .calibrating) {
            self.baseline.delta += reading.band_powers.delta;
            self.baseline.theta += reading.band_powers.theta;
            self.baseline.alpha += reading.band_powers.alpha;
            self.baseline.beta += reading.band_powers.beta;
            self.baseline.gamma += reading.band_powers.gamma;
            self.calibration_epochs += 1;

            if (self.calibration_epochs >= CALIBRATION_TARGET) {
                const cal_f: f32 = @floatFromInt(self.calibration_epochs);
                self.baseline.delta /= cal_f;
                self.baseline.theta /= cal_f;
                self.baseline.alpha /= cal_f;
                self.baseline.beta /= cal_f;
                self.baseline.gamma /= cal_f;
                self.state = .acquiring;
            }
        }

        // Fisher-Rao distance from baseline
        reading.phenomenal_state = fisherRaoDistance(reading.band_powers, self.baseline);

        // Overall color from aggregate trit
        const result = BCIReading.classify(reading.band_powers, DEFAULT_HIGH_THRESHOLD, DEFAULT_LOW_THRESHOLD);
        reading.color = result.color;

        // Push to ring buffer
        self.ring.push(reading);
        self.epoch_count += 1;

        // Check GF(3) conservation
        if (self.ring.needsRecalibration(RECALIBRATION_THRESHOLD) and self.state == .acquiring) {
            self.state = .recalibrating;
        }

        return reading;
    }

    /// Start calibration
    pub fn startCalibration(self: *UniversalReceiver) void {
        self.state = .calibrating;
        self.calibration_epochs = 0;
        self.baseline = .{};
    }

    /// Serialize device info for BLE characteristic 0xBCI4
    pub fn packDeviceInfo(self: *const UniversalReceiver) [12]u8 {
        var buf = [_]u8{0} ** 12;
        // FW version
        buf[0] = @truncate(FW_VERSION);
        buf[1] = @truncate(FW_VERSION >> 8);
        // Active sensor count
        var n_sensors: u8 = 0;
        var modality_mask: u8 = 0;
        for (self.sensors, 0..) |s, i| {
            if (s.enabled) {
                n_sensors += 1;
                modality_mask |= @as(u8, 1) << @intCast(i);
            }
        }
        buf[2] = n_sensors;
        buf[3] = modality_mask;
        // EEG sample rate
        buf[4] = @truncate(self.sensors[0].sample_rate);
        buf[5] = @truncate(self.sensors[0].sample_rate >> 8);
        // Serial number
        buf[6] = @truncate(self.serial);
        buf[7] = @truncate(self.serial >> 8);
        buf[8] = @truncate(self.serial >> 16);
        buf[9] = @truncate(self.serial >> 24);
        // State
        buf[10] = @intFromEnum(self.state);
        // Epoch count (lower 8 bits)
        buf[11] = @truncate(self.epoch_count);
        return buf;
    }

    /// Syrup serialization for OCapN transport
    pub fn toSyrup(self: *const UniversalReceiver, allocator: Allocator) !syrup.Value {
        var entries = std.ArrayList(syrup.Value).init(allocator);

        try entries.append(.{ .symbol = "bci-receiver" });
        try entries.append(.{ .int = self.serial });
        try entries.append(.{ .symbol = DeviceState.name(self.state) });
        try entries.append(.{ .int = @intCast(self.epoch_count) });
        try entries.append(.{ .int = self.ring.gf3Balance() });

        // Latest reading
        if (self.ring.latest()) |latest| {
            try entries.append(try latest.toSyrup(allocator));
        }

        return .{ .record = try entries.toOwnedSlice() };
    }
};

// ============================================================================
// TESTS
// ============================================================================

test "GF(3) trit arithmetic" {
    const t = Trit;
    try std.testing.expectEqual(t.zero, t.add(.plus, .minus));
    try std.testing.expectEqual(t.plus, t.neg(.minus));
    try std.testing.expectEqual(t.minus, t.neg(.plus));
    try std.testing.expectEqual(t.zero, t.neg(.zero));
}

test "BandPowers entropy and classification" {
    const bp = BandPowers{
        .delta = 10,
        .theta = 5,
        .alpha = 30,
        .beta = 40,
        .gamma = 15,
    };
    const entropy = bp.shannonEntropy();
    // 5-band spectrum should have entropy ~2.0-2.3 bits
    try std.testing.expect(entropy > 1.5);
    try std.testing.expect(entropy < 2.5);

    // Beta dominant → +1
    try std.testing.expectEqual(Trit.plus, bp.dominantTrit());
}

test "BandPowers entropy classification" {
    // High entropy (uniform distribution)
    const uniform = BandPowers{ .delta = 20, .theta = 20, .alpha = 20, .beta = 20, .gamma = 20 };
    try std.testing.expectEqual(Trit.plus, uniform.classifyEntropy(2.0, 1.0));

    // Low entropy (peaked)
    const peaked = BandPowers{ .delta = 100, .theta = 0, .alpha = 0, .beta = 0, .gamma = 0 };
    try std.testing.expectEqual(Trit.minus, peaked.classifyEntropy(2.0, 1.0));
}

test "Fisher-Rao distance" {
    const baseline = BandPowers{ .delta = 10, .theta = 10, .alpha = 10, .beta = 10, .gamma = 10 };
    const active = BandPowers{ .delta = 5, .theta = 5, .alpha = 5, .beta = 50, .gamma = 35 };

    const d = fisherRaoDistance(active, baseline);
    // Should be non-zero (states differ)
    try std.testing.expect(d > 0);
    // Should be bounded by π/2
    try std.testing.expect(d <= std.math.pi / 2.0 + 0.01);

    // Same distribution → distance 0
    const d0 = fisherRaoDistance(baseline, baseline);
    try std.testing.expectApproxEqAbs(@as(f32, 0), d0, 0.001);
}

test "BCIReading ring buffer" {
    var ring = ReadingRing{};
    try std.testing.expectEqual(@as(usize, 0), ring.count);

    // Push a reading with all +1 channels
    var reading: BCIReading = .{
        .timestamp_ms = 1000,
        .n_channels = 3,
        .channels = [_]Trit{.zero} ** MAX_CHANNELS,
        .band_powers = .{},
        .phenomenal_state = 0,
        .color = COLOR_GENERATOR,
        .modality_mask = 0x01,
    };
    reading.channels[0] = .plus;
    reading.channels[1] = .zero;
    reading.channels[2] = .minus;

    ring.push(reading);
    try std.testing.expectEqual(@as(usize, 1), ring.count);
    try std.testing.expectEqual(@as(i32, 0), ring.gf3Balance()); // +1+0-1 = 0 ✓
}

test "UniversalReceiver calibration" {
    var receiver = UniversalReceiver.init(0xDEAD);
    try std.testing.expectEqual(DeviceState.idle, receiver.state);

    receiver.startCalibration();
    try std.testing.expectEqual(DeviceState.calibrating, receiver.state);

    // Feed 30 calibration epochs with balanced GF(3) trits:
    // Mix high-entropy (→ +1), medium (→ 0), and low-entropy (→ -1) channels
    const high_ent = BandPowers{ .delta = 20, .theta = 20, .alpha = 20, .beta = 20, .gamma = 20 }; // entropy ~2.32 → +1
    const med_ent = BandPowers{ .delta = 10, .theta = 8, .alpha = 15, .beta = 12, .gamma = 5 }; // entropy ~2.1 → 0
    const low_ent = BandPowers{ .delta = 100, .theta = 1, .alpha = 1, .beta = 1, .gamma = 1 }; // entropy ~0.2 → -1
    // 3 channels: +1, 0, -1 → sum = 0 (GF(3) balanced)
    var bands = [_]BandPowers{ high_ent, med_ent, low_ent };
    for (0..30) |i| {
        _ = receiver.processEpoch(&bands, @intCast(i * 200));
    }

    // Should transition to acquiring after 30 epochs
    try std.testing.expectEqual(DeviceState.acquiring, receiver.state);
    try std.testing.expect(receiver.baseline.alpha > 0);
}

test "Modality SPI bus assignment" {
    try std.testing.expectEqual(@as(u8, 0), Modality.eeg.spiBus());
    try std.testing.expectEqual(@as(u8, 1), Modality.ultrasound.spiBus());
    try std.testing.expectEqual(@as(u8, 2), Modality.emg.spiBus());
    try std.testing.expectEqual(@as(u8, 3), Modality.ecog.spiBus());
}

test "SensorConfig defaults" {
    const eeg = SensorConfig.default(.eeg);
    try std.testing.expectEqual(@as(u16, 250), eeg.sample_rate);
    try std.testing.expectEqual(@as(u8, 64), eeg.channelCount());
    try std.testing.expect(eeg.enabled);

    const us = SensorConfig.default(.ultrasound);
    try std.testing.expectEqual(@as(u16, 100), us.sample_rate);
    try std.testing.expectEqual(@as(u8, 1), us.channelCount());
}

test "BLE trit stream packing" {
    var reading: BCIReading = .{
        .timestamp_ms = 0x12345678,
        .n_channels = 3,
        .channels = [_]Trit{.zero} ** MAX_CHANNELS,
        .band_powers = .{},
        .phenomenal_state = 0,
        .color = COLOR_GENERATOR,
        .modality_mask = 0x01,
    };
    reading.channels[0] = .plus;
    reading.channels[1] = .zero;
    reading.channels[2] = .minus;

    const pkt = reading.packTritStream();
    // Timestamp bytes
    try std.testing.expectEqual(@as(u8, 0x78), pkt[0]);
    try std.testing.expectEqual(@as(u8, 0x56), pkt[1]);
    // Channel count
    try std.testing.expectEqual(@as(u8, 3), pkt[4]);
    // Trits
    try std.testing.expectEqual(@as(u8, 1), pkt[5]); // +1
    try std.testing.expectEqual(@as(u8, 0), pkt[6]); // 0
    try std.testing.expectEqual(@as(u8, 0xFF), pkt[7]); // -1 as u8
    // Color
    try std.testing.expectEqual(@as(u8, 0x00), pkt[17]); // R
    try std.testing.expectEqual(@as(u8, 0xE1), pkt[18]); // G
    try std.testing.expectEqual(@as(u8, 0xA9), pkt[19]); // B
}

test "BandPowers BLE packing" {
    const bp = BandPowers{ .delta = 10, .theta = 5, .alpha = 30, .beta = 40, .gamma = 15 };
    const ble_data = bp.packBLE();
    // Should produce 10 bytes (5 × f16)
    try std.testing.expectEqual(@as(usize, 10), ble_data.len);
}
