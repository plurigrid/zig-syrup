//! Trit-Tick — Universal Time Base for BCI + Color Entropy
//!
//! 1 trit-tick = 1/141,120,000 second ≈ 7.086 nanoseconds
//!
//! 141,120,000 = 2⁹ × 3² × 5⁴ × 7²
//!
//! This is the LCM of every sample rate in the BCI, audio, video, and
//! color-entropy ecosystem. It evenly divides all of:
//!   - BCI:   10, 100, 128, 200, 250, 256, 500, 1000, 1500, 2000, 4000, 20000, 30000 Hz
//!   - Audio: 8000, 16000, 22050, 24000, 32000, 44100, 48000, 88200, 96000, 192000 Hz
//!   - Video: 24, 25, 30, 48, 50, 60, 90, 100, 120, 144 fps
//!   - Color: GF(3)=3, bands=5, hue_circle=360
//!
//! Relationships:
//!   1 trit-tick  = 5 flicks                     (Facebook, 2017)
//!   1 flick      = 1/705,600,000 s              705,600,000 = 141,120,000 × 5
//!   1 TimeRef    = 10 trit-ticks = 50 flicks    (Sorbonne/INA, 2004)
//!   1 Unity tick = 1 trit-tick                  (Unity IntegerTime, DefaultTicksPerSecond)
//!
//! The factor of 5 separating trit-ticks from flicks is the number of EEG
//! frequency bands (delta, theta, alpha, beta, gamma) — the it-ti fold
//! between information content and temporal resolution.

const std = @import("std");

/// Trit-ticks per second. The universal time quantum.
/// Equal to Unity's RationalTime.TicksPerSecond.DefaultTicksPerSecond.
pub const TICKS_PER_SECOND: u64 = 141_120_000;

/// Flicks per second (Facebook). Exactly 5× trit-ticks.
pub const FLICKS_PER_SECOND: u64 = 705_600_000;

/// TimeRefs per second (Sorbonne/INA 2004). Exactly 1/10 trit-ticks.
pub const TIMEREFS_PER_SECOND: u64 = 14_112_000;

/// Nanoseconds per second.
const NS_PER_SECOND: u64 = 1_000_000_000;

// ============================================================================
// FACTORIZATION STRUCTURE
// ============================================================================

/// The four primes. Nothing beyond 7 is needed.
pub const PRIME_2_EXP: u4 = 9;
pub const PRIME_3_EXP: u4 = 2;
pub const PRIME_5_EXP: u4 = 4;
pub const PRIME_7_EXP: u4 = 2;

/// GF(3) conservation quantum: TICKS_PER_SECOND / 3
pub const GF3_QUANTUM: u64 = TICKS_PER_SECOND / 3; // 47,040,000

/// Band entropy quantum: TICKS_PER_SECOND / 5
pub const BAND_QUANTUM: u64 = TICKS_PER_SECOND / 5; // 28,224,000

/// Hue degree quantum: TICKS_PER_SECOND / 360
pub const HUE_DEGREE_QUANTUM: u64 = TICKS_PER_SECOND / 360; // 392,000

// ============================================================================
// PER-MODALITY TICK COUNTS
// ============================================================================

/// Trit-ticks per sample for each BCI modality.
/// Every value is an exact integer — no floating point, no drift.
pub const Modality = enum(u8) {
    eeg = 0,
    ultrasound = 1,
    emg = 2,
    eng = 3,
    ecog = 4,
    fnirs = 5,

    pub fn sampleRate(self: Modality) u32 {
        return switch (self) {
            .eeg => 250,
            .ultrasound => 100,
            .emg => 500,
            .eng => 500,
            .ecog => 2000,
            .fnirs => 10,
        };
    }

    /// Exact integer trit-ticks between consecutive samples.
    pub fn ticksPerSample(self: Modality) u64 {
        return TICKS_PER_SECOND / self.sampleRate();
    }
};

// ============================================================================
// TIMESTAMP TYPE
// ============================================================================

/// A point in time measured in trit-ticks from an arbitrary epoch.
pub const Instant = struct {
    ticks: i64,

    pub const ZERO = Instant{ .ticks = 0 };

    /// Advance by one sample at the given modality's rate.
    pub fn advanceSample(self: Instant, modality: Modality) Instant {
        return .{ .ticks = self.ticks + @as(i64, @intCast(modality.ticksPerSample())) };
    }

    /// Advance by N samples.
    pub fn advanceSamples(self: Instant, modality: Modality, n: u32) Instant {
        return .{ .ticks = self.ticks + @as(i64, @intCast(modality.ticksPerSample())) * @as(i64, @intCast(n)) };
    }

    /// Advance by one GF(3) conservation cycle.
    pub fn advanceGF3Cycle(self: Instant) Instant {
        return .{ .ticks = self.ticks + @as(i64, @intCast(GF3_QUANTUM)) };
    }

    /// Advance by one hue degree of color rotation.
    pub fn advanceHueDegree(self: Instant) Instant {
        return .{ .ticks = self.ticks + @as(i64, @intCast(HUE_DEGREE_QUANTUM)) };
    }

    /// Duration between two instants.
    pub fn since(self: Instant, earlier: Instant) Duration {
        return .{ .ticks = self.ticks - earlier.ticks };
    }

    /// Convert from nanosecond timestamp.
    /// Uses the exact rational conversion: ticks = ns × 441 / 3125
    /// (441 = 3² × 7², 3125 = 5⁵)
    pub fn fromNanoseconds(ns: i64) Instant {
        return .{ .ticks = @divFloor(ns * 441, 3125) };
    }

    /// Convert to nanosecond timestamp.
    /// Inverse: ns = ticks × 3125 / 441
    pub fn toNanoseconds(self: Instant) i64 {
        return @divFloor(self.ticks * 3125, 441);
    }

    /// Convert from flicks. Exact: 1 trit-tick = 5 flicks.
    pub fn fromFlicks(flicks: i64) Instant {
        return .{ .ticks = @divExact(flicks, 5) };
    }

    /// Convert to flicks. Exact.
    pub fn toFlicks(self: Instant) i64 {
        return self.ticks * 5;
    }

    /// How many complete samples of a given modality fit in [0, self)?
    pub fn sampleCount(self: Instant, modality: Modality) u64 {
        if (self.ticks <= 0) return 0;
        return @intCast(@divFloor(self.ticks, @as(i64, @intCast(modality.ticksPerSample()))));
    }
};

// ============================================================================
// DURATION TYPE
// ============================================================================

pub const Duration = struct {
    ticks: i64,

    pub const ZERO = Duration{ .ticks = 0 };

    pub fn fromSeconds(s: f64) Duration {
        return .{ .ticks = @intFromFloat(s * @as(f64, @floatFromInt(TICKS_PER_SECOND))) };
    }

    pub fn toSeconds(self: Duration) f64 {
        return @as(f64, @floatFromInt(self.ticks)) / @as(f64, @floatFromInt(TICKS_PER_SECOND));
    }

    /// Number of complete samples at a given rate.
    pub fn sampleCount(self: Duration, modality: Modality) u64 {
        if (self.ticks <= 0) return 0;
        return @intCast(@divFloor(self.ticks, @as(i64, @intCast(modality.ticksPerSample()))));
    }

    /// Duration of exactly N samples at a given rate.
    pub fn fromSamples(modality: Modality, n: u32) Duration {
        return .{ .ticks = @as(i64, @intCast(modality.ticksPerSample())) * @as(i64, @intCast(n)) };
    }

    /// Duration of one FFT window (256 samples at the given modality).
    pub fn fftWindow(modality: Modality) Duration {
        return fromSamples(modality, 256);
    }
};

// ============================================================================
// RATE DIVISIBILITY CHECK (comptime)
// ============================================================================

/// Verify at comptime that a sample rate divides TICKS_PER_SECOND exactly.
pub fn assertExactRate(comptime rate: u64) void {
    if (TICKS_PER_SECOND % rate != 0) {
        @compileError("Rate does not divide 141,120,000 (trit-tick base)");
    }
}

/// Trit-ticks per sample for an arbitrary exact rate.
pub fn ticksForRate(comptime rate: u64) u64 {
    assertExactRate(rate);
    return TICKS_PER_SECOND / rate;
}

// ============================================================================
// TESTS
// ============================================================================

test "factorization" {
    // 2^9 * 3^2 * 5^4 * 7^2 = 141,120,000
    var n: u64 = 1;
    var i: u4 = 0;
    while (i < PRIME_2_EXP) : (i += 1) n *= 2;
    i = 0;
    while (i < PRIME_3_EXP) : (i += 1) n *= 3;
    i = 0;
    while (i < PRIME_5_EXP) : (i += 1) n *= 5;
    i = 0;
    while (i < PRIME_7_EXP) : (i += 1) n *= 7;
    try std.testing.expectEqual(TICKS_PER_SECOND, n);
}

test "flicks relationship" {
    try std.testing.expectEqual(FLICKS_PER_SECOND, TICKS_PER_SECOND * 5);
}

test "TimeRef relationship" {
    try std.testing.expectEqual(TIMEREFS_PER_SECOND, TICKS_PER_SECOND / 10);
}

test "all BCI modalities divide exactly" {
    const modalities = [_]Modality{ .eeg, .ultrasound, .emg, .eng, .ecog, .fnirs };
    for (modalities) |m| {
        try std.testing.expectEqual(@as(u64, 0), TICKS_PER_SECOND % m.sampleRate());
    }
}

test "modality tick counts" {
    try std.testing.expectEqual(@as(u64, 564_480), Modality.eeg.ticksPerSample());
    try std.testing.expectEqual(@as(u64, 1_411_200), Modality.ultrasound.ticksPerSample());
    try std.testing.expectEqual(@as(u64, 282_240), Modality.emg.ticksPerSample());
    try std.testing.expectEqual(@as(u64, 70_560), Modality.ecog.ticksPerSample());
    try std.testing.expectEqual(@as(u64, 14_112_000), Modality.fnirs.ticksPerSample());
}

test "color-entropy divisors" {
    try std.testing.expectEqual(@as(u64, 0), TICKS_PER_SECOND % 3); // GF(3)
    try std.testing.expectEqual(@as(u64, 0), TICKS_PER_SECOND % 5); // bands
    try std.testing.expectEqual(@as(u64, 0), TICKS_PER_SECOND % 360); // hue circle
}

test "audio rates divide exactly" {
    const audio_rates = [_]u64{ 8000, 16000, 22050, 24000, 32000, 44100, 48000, 88200, 96000, 192000 };
    for (audio_rates) |rate| {
        try std.testing.expectEqual(@as(u64, 0), TICKS_PER_SECOND % rate);
    }
}

test "video rates divide exactly" {
    const video_rates = [_]u64{ 24, 25, 30, 48, 50, 60, 90, 100, 120, 144 };
    for (video_rates) |rate| {
        try std.testing.expectEqual(@as(u64, 0), TICKS_PER_SECOND % rate);
    }
}

test "nanosecond roundtrip" {
    // 1 second = 1e9 ns = 141,120,000 trit-ticks
    const one_sec = Instant{ .ticks = TICKS_PER_SECOND };
    const ns = one_sec.toNanoseconds();
    // Allow ±1 ns rounding from integer division
    try std.testing.expect(ns >= 999_999_999 and ns <= 1_000_000_001);

    const back = Instant.fromNanoseconds(1_000_000_000);
    try std.testing.expectEqual(@as(i64, @intCast(TICKS_PER_SECOND)), back.ticks);
}

test "flick roundtrip" {
    const t = Instant{ .ticks = 1000 };
    const f = t.toFlicks();
    try std.testing.expectEqual(@as(i64, 5000), f);
    const back = Instant.fromFlicks(f);
    try std.testing.expectEqual(t.ticks, back.ticks);
}

test "cross-modal sync" {
    // In 1 fNIRS epoch (100ms), there are exactly 25 EEG samples
    const fnirs_ticks = Modality.fnirs.ticksPerSample();
    const eeg_ticks = Modality.eeg.ticksPerSample();
    try std.testing.expectEqual(@as(u64, 0), fnirs_ticks % eeg_ticks);
    try std.testing.expectEqual(@as(u64, 25), fnirs_ticks / eeg_ticks);
}

test "sample advancement" {
    var t = Instant.ZERO;
    t = t.advanceSample(.eeg);
    try std.testing.expectEqual(@as(i64, 564_480), t.ticks);
    t = t.advanceSamples(.eeg, 249);
    // 250 EEG samples = 1 second
    try std.testing.expectEqual(@as(i64, @intCast(TICKS_PER_SECOND)), t.ticks);
}

test "FFT window duration" {
    // 256 samples at 250 Hz = 1.024 seconds
    const w = Duration.fftWindow(.eeg);
    const secs = w.toSeconds();
    try std.testing.expect(secs > 1.023 and secs < 1.025);
}

test "comptime rate validation" {
    // These compile:
    comptime {
        assertExactRate(250);
        assertExactRate(44100);
        assertExactRate(192000);
        assertExactRate(360);
        assertExactRate(3);
        assertExactRate(5);
    }
}
