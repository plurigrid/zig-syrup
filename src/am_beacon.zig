//! am_beacon.zig — AM Broadcast Commitment Beacon
//!
//! Extracts temporal commitments from AM radio broadcasts.
//! The broadcast signal provides:
//!   1. Timestamp proof (gospel content = unique per-second fingerprint)
//!   2. Atmospheric fingerprint (multipath propagation = location proof)
//!   3. Coverage geometry (145km ground wave radius = OLC cell tiling)
//!
//! Architecture:
//!   RTL-SDR dongle (RTL2832U+R820T2, $10-14)
//!     → AM demodulation (530-1700 kHz)
//!     → Audio fingerprint (chromagram, 8 bands)
//!     → Atmospheric channel estimation (multipath delay spread)
//!     → GF(3) trit from signal quality
//!     → Syrup commitment record
//!     → passport.gay session binding
//!
//! The "Earth AM Radio everyman device":
//!   Chinese supply: RTL-SDR + antenna + USB OTG = $14 (AliExpress/Jumia)
//!   Taiwan scale:   Custom PCB + MCU + AM frontend = $8 @ 10K (Tier 2 EMS)
//!   US retail:      Assembled + OSHWA cert = $25 (Amazon/GroupGets)
//!
//! GF(3) trit: -1 (VALIDATOR) — validates temporal/spatial claims against broadcast
//!
//! Kenya deployment:
//!   Community broadcast license: KSh 15,000/year (~$115)
//!   Spectrum fee (analog sound): KSh 18,000/year (~$140)
//!   Payment rail: M-PESA (91%) | Airtel Money (9%) | CBK FPS (2026, ISO 20022)
//!   Gig coordination: PataKazi (WhatsApp-native, zero commission)
//!   Distribution: Jumia Kenya (Chinese seller pipeline) | Balozy (local install)

const std = @import("std");
const geo = @import("geo");
const syrup = @import("syrup");

// =============================================================================
// Constants
// =============================================================================

/// AM broadcast band (kHz)
pub const AM_BAND_LOW_KHZ: u32 = 530;
pub const AM_BAND_HIGH_KHZ: u32 = 1700;

/// Ground wave propagation radius (meters)
/// 145km = typical 1kW AM station ground wave coverage
pub const GROUND_WAVE_RADIUS_M: f64 = 145_000.0;

/// Speed of light (m/s) for delay calculations
const C: f64 = 299_792_458.0;

/// Audio fingerprint bands (Hz boundaries)
/// Matches chromagram octave bands within AM audio bandwidth (50-5000 Hz)
const FINGERPRINT_BANDS = [9]f64{ 50, 100, 200, 400, 800, 1600, 3200, 4500, 5000 };

/// Number of fingerprint bands (8 intervals from 9 boundaries)
pub const N_FINGERPRINT_BANDS: usize = 8;

/// Minimum SNR for valid atmospheric measurement (dB)
const MIN_SNR_DB: f64 = 6.0;

/// Maximum multipath delay spread for ground wave (microseconds)
/// Beyond this = skywave, not ground wave (different physics)
const MAX_GROUND_WAVE_DELAY_US: f64 = 500.0;

/// Atmospheric fingerprint sample window (seconds)
pub const FINGERPRINT_WINDOW_SEC: f64 = 1.0;

// =============================================================================
// Types
// =============================================================================

/// GF(3) trit (matches entangle.zig, passport.zig)
pub const Trit = enum(i8) {
    minus = -1,
    zero = 0,
    plus = 1,

    pub fn add(a: Trit, b: Trit) Trit {
        const table = [3]Trit{ .zero, .plus, .minus };
        const av: u8 = @intCast(@mod(@as(i16, @intFromEnum(a)) + 3, 3));
        const bv: u8 = @intCast(@mod(@as(i16, @intFromEnum(b)) + 3, 3));
        return table[(av + bv) % 3];
    }
};

/// AM station identity
pub const Station = struct {
    frequency_khz: u32,
    call_sign: [8]u8,
    call_sign_len: u8,
    location: geo.Coordinate,
    power_watts: u32,

    /// OLC Plus Code for the transmitter site
    pub fn plusCode(self: Station, buf: []u8) geo.OlcError!usize {
        return self.location.encode(10, buf);
    }

    /// Coverage area as a CodeArea (bounding box of 145km radius)
    pub fn coverageArea(self: Station) geo.CodeArea {
        const lat_deg = GROUND_WAVE_RADIUS_M / 111_320.0;
        const lng_deg = GROUND_WAVE_RADIUS_M / (111_320.0 * @cos(self.location.latitude * std.math.pi / 180.0));
        return .{
            .south_latitude = self.location.latitude - lat_deg,
            .west_longitude = self.location.longitude - lng_deg,
            .north_latitude = self.location.latitude + lat_deg,
            .east_longitude = self.location.longitude + lng_deg,
            .code_length = 4, // ~110km x 110km cells for coverage grid
        };
    }

    /// Distance from station to a coordinate (Haversine, meters)
    pub fn distanceTo(self: Station, coord: geo.Coordinate) f64 {
        return haversineM(self.location.latitude, self.location.longitude, coord.latitude, coord.longitude);
    }

    /// Is a coordinate within ground wave coverage?
    pub fn inCoverage(self: Station, coord: geo.Coordinate) bool {
        return self.distanceTo(coord) <= GROUND_WAVE_RADIUS_M;
    }
};

/// Audio fingerprint: 8-band energy distribution over 1-second window
pub const AudioFingerprint = struct {
    band_energy: [N_FINGERPRINT_BANDS]f64,
    timestamp_ms: u64,

    /// Shannon entropy of the band energy distribution
    pub fn entropy(self: AudioFingerprint) f64 {
        var total: f64 = 0;
        for (self.band_energy) |e| total += e;
        if (total <= 0) return 0;

        var h: f64 = 0;
        for (self.band_energy) |e| {
            if (e > 0) {
                const p = e / total;
                h -= p * @log(p) / @log(2.0);
            }
        }
        return h;
    }

    /// GF(3) trit from audio entropy
    /// High entropy (diverse content) = PLUS
    /// Low entropy (silence/tone) = MINUS
    /// Mid-range = ERGODIC
    pub fn trit(self: AudioFingerprint) Trit {
        const h = self.entropy();
        if (h > 2.5) return .plus;
        if (h < 1.0) return .minus;
        return .zero;
    }
};

/// Atmospheric channel estimate from multipath analysis
pub const AtmosphericFingerprint = struct {
    delay_spread_us: f64,
    snr_db: f64,
    doppler_hz: f64,
    phase_offset_rad: f64,
    timestamp_ms: u64,

    /// Is this a valid ground wave measurement?
    pub fn isGroundWave(self: AtmosphericFingerprint) bool {
        return self.delay_spread_us <= MAX_GROUND_WAVE_DELAY_US and
            self.snr_db >= MIN_SNR_DB;
    }

    /// GF(3) trit from channel quality
    /// Strong ground wave (low delay, high SNR) = PLUS (reliable location proof)
    /// Skywave or weak signal = MINUS (unreliable)
    /// Marginal = ERGODIC
    pub fn trit(self: AtmosphericFingerprint) Trit {
        if (!self.isGroundWave()) return .minus;
        if (self.snr_db > 20.0 and self.delay_spread_us < 100.0) return .plus;
        return .zero;
    }

    /// Estimated distance from transmitter (meters) from delay spread
    pub fn estimatedDistanceM(self: AtmosphericFingerprint) f64 {
        return self.delay_spread_us * 1e-6 * C;
    }
};

/// Combined beacon measurement: audio + atmosphere + location
pub const BeaconMeasurement = struct {
    station: Station,
    audio: AudioFingerprint,
    atmosphere: AtmosphericFingerprint,
    receiver_location: geo.Coordinate,
    timestamp_ms: u64,

    /// Combined GF(3) trit: all three sub-trits must sum to 0 (mod 3)
    /// for a valid commitment. If not, the measurement is suspect.
    pub fn commitmentTrit(self: BeaconMeasurement) Trit {
        const audio_t = self.audio.trit();
        const atmo_t = self.atmosphere.trit();
        return audio_t.add(atmo_t);
    }

    /// Is this measurement consistent?
    /// Receiver must be within coverage AND atmosphere must be ground wave
    pub fn isConsistent(self: BeaconMeasurement) bool {
        if (!self.station.inCoverage(self.receiver_location)) return false;
        if (!self.atmosphere.isGroundWave()) return false;
        // Atmospheric distance estimate should roughly match geometric distance
        const geo_dist = self.station.distanceTo(self.receiver_location);
        const atmo_dist = self.atmosphere.estimatedDistanceM();
        const ratio = if (geo_dist > 0) atmo_dist / geo_dist else 0;
        return ratio > 0.5 and ratio < 2.0;
    }

    /// Commitment hash: SHA-256 of (station_freq || audio_fingerprint || atmo_fingerprint || timestamp)
    pub fn commitmentHash(self: BeaconMeasurement) [32]u8 {
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});

        // Station identity
        const freq_bytes = std.mem.asBytes(&self.station.frequency_khz);
        hasher.update(freq_bytes);

        // Audio fingerprint (band energies)
        for (self.audio.band_energy) |e| {
            hasher.update(std.mem.asBytes(&e));
        }

        // Atmospheric fingerprint
        hasher.update(std.mem.asBytes(&self.atmosphere.delay_spread_us));
        hasher.update(std.mem.asBytes(&self.atmosphere.snr_db));
        hasher.update(std.mem.asBytes(&self.atmosphere.phase_offset_rad));

        // Timestamp
        hasher.update(std.mem.asBytes(&self.timestamp_ms));

        return hasher.finalResult();
    }

    /// Serialize to Syrup record
    pub fn toSyrup(self: BeaconMeasurement, allocator: std.mem.Allocator) !syrup.Value {
        const label_alloc = try allocator.alloc(syrup.Value, 1);
        label_alloc[0] = syrup.Value.fromSymbol("beacon:measurement");

        const fields = try allocator.alloc(syrup.Value, 5);
        fields[0] = syrup.Value.fromInteger(@intCast(self.station.frequency_khz));
        fields[1] = syrup.Value.fromFloat(self.audio.entropy());
        fields[2] = syrup.Value.fromFloat(self.atmosphere.snr_db);
        fields[3] = syrup.Value.fromFloat(self.atmosphere.delay_spread_us);
        fields[4] = syrup.Value.fromInteger(@intCast(self.timestamp_ms));

        return syrup.Value.fromRecord(&label_alloc[0], fields);
    }
};

// =============================================================================
// Known Stations (Kenya deployment)
// =============================================================================

/// KBC National Service (Kenya Broadcasting Corporation)
/// Main AM transmitter at Langata, Nairobi
pub const KBC_NAIROBI = Station{
    .frequency_khz = 747,
    .call_sign = [_]u8{ 'K', 'B', 'C', ' ', 'N', 'B', 'I', 0 },
    .call_sign_len = 7,
    .location = geo.Coordinate.init(-1.3521, 36.7660), // Langata
    .power_watts = 100_000, // 100kW
};

/// KBC Mombasa relay
pub const KBC_MOMBASA = Station{
    .frequency_khz = 594,
    .call_sign = [_]u8{ 'K', 'B', 'C', ' ', 'M', 'S', 'A', 0 },
    .call_sign_len = 7,
    .location = geo.Coordinate.init(-4.0435, 39.6682),
    .power_watts = 10_000,
};

// =============================================================================
// Haversine distance
// =============================================================================

fn haversineM(lat1: f64, lon1: f64, lat2: f64, lon2: f64) f64 {
    const R = 6_371_000.0; // Earth radius in meters
    const to_rad = std.math.pi / 180.0;
    const dlat = (lat2 - lat1) * to_rad;
    const dlon = (lon2 - lon1) * to_rad;
    const a = @sin(dlat / 2) * @sin(dlat / 2) +
        @cos(lat1 * to_rad) * @cos(lat2 * to_rad) *
        @sin(dlon / 2) * @sin(dlon / 2);
    const c = 2 * std.math.atan2(@sqrt(a), @sqrt(1 - a));
    return R * c;
}

// =============================================================================
// Tests
// =============================================================================

test "KBC Nairobi covers Nairobi CBD" {
    const cbd = geo.Coordinate.init(-1.2921, 36.8219);
    try std.testing.expect(KBC_NAIROBI.inCoverage(cbd));
}

test "KBC Nairobi does not cover Mombasa" {
    const mombasa = geo.Coordinate.init(-4.0435, 39.6682);
    try std.testing.expect(!KBC_NAIROBI.inCoverage(mombasa));
}

test "KBC Mombasa covers Mombasa CBD" {
    const cbd = geo.Coordinate.init(-4.0505, 39.6667);
    try std.testing.expect(KBC_MOMBASA.inCoverage(cbd));
}

test "audio fingerprint entropy: uniform = max entropy" {
    const fp = AudioFingerprint{
        .band_energy = .{ 1, 1, 1, 1, 1, 1, 1, 1 },
        .timestamp_ms = 0,
    };
    try std.testing.expectApproxEqAbs(3.0, fp.entropy(), 0.01);
    try std.testing.expectEqual(Trit.plus, fp.trit());
}

test "audio fingerprint entropy: single band = zero entropy" {
    const fp = AudioFingerprint{
        .band_energy = .{ 1, 0, 0, 0, 0, 0, 0, 0 },
        .timestamp_ms = 0,
    };
    try std.testing.expectApproxEqAbs(0.0, fp.entropy(), 0.01);
    try std.testing.expectEqual(Trit.minus, fp.trit());
}

test "atmospheric ground wave detection" {
    const good = AtmosphericFingerprint{
        .delay_spread_us = 50,
        .snr_db = 30,
        .doppler_hz = 0.1,
        .phase_offset_rad = 0,
        .timestamp_ms = 0,
    };
    try std.testing.expect(good.isGroundWave());
    try std.testing.expectEqual(Trit.plus, good.trit());

    const skywave = AtmosphericFingerprint{
        .delay_spread_us = 1000,
        .snr_db = 15,
        .doppler_hz = 2.0,
        .phase_offset_rad = 0,
        .timestamp_ms = 0,
    };
    try std.testing.expect(!skywave.isGroundWave());
    try std.testing.expectEqual(Trit.minus, skywave.trit());
}

test "beacon measurement consistency check" {
    const measurement = BeaconMeasurement{
        .station = KBC_NAIROBI,
        .audio = .{
            .band_energy = .{ 1, 1, 1, 1, 1, 1, 1, 1 },
            .timestamp_ms = 1000,
        },
        .atmosphere = .{
            .delay_spread_us = 30, // ~9km atmospheric distance
            .snr_db = 25,
            .doppler_hz = 0.05,
            .phase_offset_rad = 0.1,
            .timestamp_ms = 1000,
        },
        .receiver_location = geo.Coordinate.init(-1.2921, 36.8219), // Nairobi CBD
        .timestamp_ms = 1000,
    };

    try std.testing.expect(measurement.isConsistent());

    const hash = measurement.commitmentHash();
    try std.testing.expect(hash[0] != 0 or hash[1] != 0); // non-trivial
}

test "coverage area OLC tiling" {
    const area = KBC_NAIROBI.coverageArea();
    // 145km north/south from Langata
    try std.testing.expect(area.north_latitude > KBC_NAIROBI.location.latitude);
    try std.testing.expect(area.south_latitude < KBC_NAIROBI.location.latitude);
    // Rough check: ~1.3 degrees lat for 145km
    const lat_span = area.north_latitude - area.south_latitude;
    try std.testing.expect(lat_span > 2.0 and lat_span < 3.0);
}

test "station plus code" {
    var buf: [20]u8 = undefined;
    const len = try KBC_NAIROBI.plusCode(&buf);
    try std.testing.expect(len > 0);
    try std.testing.expect(geo.isFullCode(buf[0..len]));
}
