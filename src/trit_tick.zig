//! Trit-Tick — Universal Time Base for BCI + Color Entropy
//!
//! Four epochs, backward-compatible, monotonically expanding:
//!
//!   EPOCH 0 — flick (Facebook/Oculus 2017)
//!     705,600,000 = 2⁹ × 3 × 5² × 7² × 5
//!     Audio + video. 1 flick ≈ 1.417 ns.
//!
//!   EPOCH 1 — trit-tick (original, this file's default)
//!     141,120,000 = 2⁹ × 3² × 5⁴ × 7²
//!     = flick / 5, where 5 = EEG band count.
//!     4 primes. 80/105 rates. 1 trit-tick ≈ 7.086 ns = 5 flicks.
//!
//!   EPOCH 2 — expanded
//!     51,433,932,566,016,000,000 = 2¹⁵ × 3³ × 5⁶ × 7² × 11 × 13 × 37 × 113 × 127
//!     9 primes. ALL 105 device rates + NTSC. u128 required.
//!     Factor 364,469,476,800 × epoch 1.
//!
//!   EPOCH 3 — extreme (principled u128 limit)
//!     22,699,189,348,598,680,245,940,103,331,840,000,000
//!     = 2²⁰ × 3¹⁰ × 5⁷ × 7² × 11 × 13 × 17 × 19 × 29 × 37 × 43 × 89 × 113 × 127 × 151 × 233
//!     16 primes. 139 rates. 126 bits. 817,185 × Planck time.
//!     Fibonacci/Padovan closure: golden/plastic spirals in the time base.
//!
//!   BEYOND — unbounded (factored representation)
//!     Timestamps as prime exponent vectors. Never overflows.
//!     See FactoredInstant below.
//!
//! Relationships:
//!   1 trit-tick  = 5 flicks                     (Facebook, 2017)
//!   1 flick      = 1/705,600,000 s
//!   1 TimeRef    = 10 trit-ticks = 50 flicks    (Sorbonne/INA, 2004)
//!   1 Unity tick = 1 trit-tick                  (Unity IntegerTime)

const std = @import("std");
const root = @This();

// ============================================================================
// EPOCH 1 — ORIGINAL TRIT-TICK (u64, backward-compatible default)
// ============================================================================

/// Trit-ticks per second. The epoch 1 time quantum.
/// 141,120,000 = 2⁹ × 3² × 5⁴ × 7²
pub const TICKS_PER_SECOND: u64 = 141_120_000;

/// Flicks per second (Facebook). Exactly 5× trit-ticks.
pub const FLICKS_PER_SECOND: u64 = 705_600_000;

/// TimeRefs per second (Sorbonne/INA 2004). Exactly 1/10 trit-ticks.
pub const TIMEREFS_PER_SECOND: u64 = 14_112_000;

pub const PRIME_2_EXP: u4 = 9;
pub const PRIME_3_EXP: u4 = 2;
pub const PRIME_5_EXP: u4 = 4;
pub const PRIME_7_EXP: u4 = 2;

/// GF(3) conservation quantum: TICKS_PER_SECOND / 3
pub const GF3_QUANTUM: u64 = TICKS_PER_SECOND / 3; // 47,040,000

/// EEG band quantum: TICKS_PER_SECOND / 5
pub const BAND_QUANTUM: u64 = TICKS_PER_SECOND / 5; // 28,224,000

/// Hue degree quantum: TICKS_PER_SECOND / 360
pub const HUE_DEGREE_QUANTUM: u64 = TICKS_PER_SECOND / 360; // 392,000

// ============================================================================
// EPOCH 1 MODALITIES
// ============================================================================

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

    pub fn ticksPerSample(self: Modality) u64 {
        return TICKS_PER_SECOND / self.sampleRate();
    }
};

// ============================================================================
// EPOCH 1 TIMESTAMP (i64)
// ============================================================================

pub const Instant = struct {
    ticks: i64,

    pub const ZERO = Instant{ .ticks = 0 };

    pub fn advanceSample(self: Instant, modality: Modality) Instant {
        return .{ .ticks = self.ticks + @as(i64, @intCast(modality.ticksPerSample())) };
    }

    pub fn advanceSamples(self: Instant, modality: Modality, n: u32) Instant {
        return .{ .ticks = self.ticks + @as(i64, @intCast(modality.ticksPerSample())) * @as(i64, @intCast(n)) };
    }

    pub fn advanceGF3Cycle(self: Instant) Instant {
        return .{ .ticks = self.ticks + @as(i64, @intCast(GF3_QUANTUM)) };
    }

    pub fn advanceHueDegree(self: Instant) Instant {
        return .{ .ticks = self.ticks + @as(i64, @intCast(HUE_DEGREE_QUANTUM)) };
    }

    pub fn since(self: Instant, earlier: Instant) Duration {
        return .{ .ticks = self.ticks - earlier.ticks };
    }

    pub fn fromNanoseconds(ns: i64) Instant {
        return .{ .ticks = @divFloor(ns * 441, 3125) };
    }

    pub fn toNanoseconds(self: Instant) i64 {
        return @divFloor(self.ticks * 3125, 441);
    }

    pub fn fromFlicks(flicks: i64) Instant {
        return .{ .ticks = @divExact(flicks, 5) };
    }

    pub fn toFlicks(self: Instant) i64 {
        return self.ticks * 5;
    }

    pub fn sampleCount(self: Instant, modality: Modality) u64 {
        if (self.ticks <= 0) return 0;
        return @intCast(@divFloor(self.ticks, @as(i64, @intCast(modality.ticksPerSample()))));
    }

    /// Upgrade to epoch 2 (expanded). Exact: multiply by expansion factor.
    pub fn toExpanded(self: Instant) Expanded.Instant {
        return .{ .ticks = @as(i128, self.ticks) * @as(i128, Expanded.FACTOR_FROM_EPOCH1) };
    }

    /// Upgrade to epoch 3 (extreme). Exact.
    pub fn toExtreme(self: Instant) Extreme.Instant {
        return .{ .ticks = @as(i128, self.ticks) * @as(i128, @intCast(Extreme.FACTOR_FROM_EPOCH1)) };
    }
};

pub const Duration = struct {
    ticks: i64,

    pub const ZERO = Duration{ .ticks = 0 };

    pub fn fromSeconds(s: f64) Duration {
        return .{ .ticks = @intFromFloat(s * @as(f64, @floatFromInt(TICKS_PER_SECOND))) };
    }

    pub fn toSeconds(self: Duration) f64 {
        return @as(f64, @floatFromInt(self.ticks)) / @as(f64, @floatFromInt(TICKS_PER_SECOND));
    }

    pub fn sampleCount(self: Duration, modality: Modality) u64 {
        if (self.ticks <= 0) return 0;
        return @intCast(@divFloor(self.ticks, @as(i64, @intCast(modality.ticksPerSample()))));
    }

    pub fn fromSamples(modality: Modality, n: u32) Duration {
        return .{ .ticks = @as(i64, @intCast(modality.ticksPerSample())) * @as(i64, @intCast(n)) };
    }

    pub fn fftWindow(modality: Modality) Duration {
        return fromSamples(modality, 256);
    }
};

pub fn assertExactRate(comptime rate: u64) void {
    if (TICKS_PER_SECOND % rate != 0) {
        @compileError("Rate does not divide 141,120,000 (epoch 1 trit-tick base)");
    }
}

pub fn ticksForRate(comptime rate: u64) u64 {
    assertExactRate(rate);
    return TICKS_PER_SECOND / rate;
}

// ============================================================================
// EPOCH 2 — EXPANDED (u128, 9 primes, 105 rates)
// ============================================================================

pub const Expanded = struct {
    /// 2¹⁵ × 3³ × 5⁶ × 7² × 11 × 13 × 37 × 113 × 127
    pub const TICKS_PER_SECOND: u128 = 51_433_932_566_016_000_000;
    pub const FACTOR_FROM_EPOCH1: u64 = 364_469_476_800;
    pub const FACTOR_FROM_FLICK: u64 = 72_893_895_360;

    pub const Instant = struct {
        ticks: i128,

        pub const ZERO = Expanded.Instant{ .ticks = 0 };

        pub fn advanceBySampleRate(self: Expanded.Instant, rate_hz: u64) Expanded.Instant {
            return .{ .ticks = self.ticks + @as(i128, @intCast(Expanded.TICKS_PER_SECOND / @as(u128, rate_hz))) };
        }

        pub fn toEpoch1(self: Expanded.Instant) root.Instant {
            return .{ .ticks = @intCast(@divFloor(self.ticks, @as(i128, FACTOR_FROM_EPOCH1))) };
        }

        pub fn toExtreme(self: Expanded.Instant) Extreme.Instant {
            return .{ .ticks = self.ticks * @as(i128, @intCast(Extreme.FACTOR_FROM_EPOCH2)) };
        }

        pub fn sampleCountAtRate(self: Expanded.Instant, rate_hz: u64) u128 {
            if (self.ticks <= 0) return 0;
            return @intCast(@divFloor(self.ticks, @as(i128, @intCast(Expanded.TICKS_PER_SECOND / @as(u128, rate_hz)))));
        }
    };

    pub fn assertExactRate(comptime rate: u64) void {
        if (Expanded.TICKS_PER_SECOND % @as(u128, rate) != 0) {
            @compileError("Rate does not divide epoch 2 expanded trit-tick base");
        }
    }
};

// ============================================================================
// EPOCH 3 — EXTREME (u128, 16 primes, 139 rates, Fibonacci/Padovan closure)
// ============================================================================

pub const Extreme = struct {
    /// 2²⁰ × 3¹⁰ × 5⁷ × 7² × 11 × 13 × 17 × 19 × 29 × 37 × 43 × 89 × 113 × 127 × 151 × 233
    const extreme_base: u128 = 22_699_189_348_598_680_245_940_103_331_840_000_000;
    pub const TICKS_PER_SECOND: u128 = extreme_base;
    pub const FACTOR_FROM_EPOCH2: u128 = extreme_base / Expanded.TICKS_PER_SECOND;
    pub const FACTOR_FROM_EPOCH1: u128 = extreme_base / @as(u128, 141_120_000);

    pub const FIBONACCI_RATES = [14]u64{ 1, 1, 2, 3, 5, 8, 13, 21, 34, 55, 89, 144, 233, 377 };
    pub const PADOVAN_RATES = [19]u64{ 1, 1, 1, 2, 2, 3, 4, 5, 7, 9, 16, 21, 28, 49, 65, 86, 114, 151, 200 };

    pub const N_PRIMES: u8 = 16;
    pub const PRIMES = [16]u16{ 2, 3, 5, 7, 11, 13, 17, 19, 29, 37, 43, 89, 113, 127, 151, 233 };
    pub const EXPONENTS = [16]u8{ 20, 10, 7, 2, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1 };

    pub const Instant = struct {
        ticks: i128,

        pub const ZERO = Extreme.Instant{ .ticks = 0 };

        pub fn advanceBySampleRate(self: Extreme.Instant, rate_hz: u64) Extreme.Instant {
            return .{ .ticks = self.ticks + @as(i128, @intCast(Extreme.TICKS_PER_SECOND / @as(u128, rate_hz))) };
        }

        pub fn toEpoch1(self: Extreme.Instant) root.Instant {
            return .{ .ticks = @intCast(@divFloor(self.ticks, @as(i128, @intCast(Extreme.FACTOR_FROM_EPOCH1)))) };
        }

        pub fn toExpanded(self: Extreme.Instant) Expanded.Instant {
            return .{ .ticks = @divFloor(self.ticks, @as(i128, @intCast(Extreme.FACTOR_FROM_EPOCH2))) };
        }

        pub fn gf3Trit(self: Extreme.Instant) i8 {
            const secs: i128 = @divFloor(self.ticks, @as(i128, @intCast(Extreme.TICKS_PER_SECOND)));
            const m = @mod(secs, 3);
            return switch (@as(u2, @intCast(m))) {
                0 => 0, 1 => 1, 2 => -1, else => unreachable,
            };
        }
    };

    pub fn assertExactRate(comptime rate: u64) void {
        if (Extreme.TICKS_PER_SECOND % @as(u128, rate) != 0) {
            @compileError("Rate does not divide epoch 3 extreme trit-tick base");
        }
    }

    /// Cross-modal: exact samples of fast modality per one sample of slow modality.
    pub fn samplesPerSample(slow_hz: u64, fast_hz: u64) ?u128 {
        const slow_tps = Extreme.TICKS_PER_SECOND / @as(u128, slow_hz);
        const fast_tps = Extreme.TICKS_PER_SECOND / @as(u128, fast_hz);
        if (slow_tps % fast_tps != 0) return null;
        return slow_tps / fast_tps;
    }
};

// ============================================================================
// UNBOUNDED — FACTORED TIMESTAMPS (prime exponent vectors, never overflow)
// ============================================================================

pub const Unbounded = struct {
    pub const MAX_INLINE_PRIMES: usize = 32;

    pub const PrimeBasis = struct {
        primes: [MAX_INLINE_PRIMES]u16,
        len: u8,

        pub fn initEpoch3() PrimeBasis {
            var b = PrimeBasis{ .primes = [_]u16{0} ** MAX_INLINE_PRIMES, .len = Extreme.N_PRIMES };
            for (Extreme.PRIMES, 0..) |p, i| b.primes[i] = p;
            return b;
        }

        pub fn contains(self: *const PrimeBasis, p: u16) bool {
            for (self.primes[0..self.len]) |q| {
                if (q == p) return true;
            }
            return false;
        }

        /// Register a new rate. Extends basis if needed. Returns true if basis grew.
        pub fn registerRate(self: *PrimeBasis, rate: u64) bool {
            var grew = false;
            var r = rate;
            var p: u64 = 2;
            while (r > 1 and p * p <= r) : (p += 1) {
                while (r % p == 0) {
                    r /= p;
                    if (!self.contains(@intCast(p)) and self.len < MAX_INLINE_PRIMES) {
                        self.primes[self.len] = @intCast(p);
                        self.len += 1;
                        grew = true;
                    }
                }
            }
            if (r > 1 and !self.contains(@intCast(r)) and self.len < MAX_INLINE_PRIMES) {
                self.primes[self.len] = @intCast(r);
                self.len += 1;
                grew = true;
            }
            return grew;
        }
    };

    pub const FactoredInstant = struct {
        exponents: [MAX_INLINE_PRIMES]i16,
        n_active: u8,

        pub const ZERO = FactoredInstant{
            .exponents = [_]i16{0} ** MAX_INLINE_PRIMES,
            .n_active = 0,
        };

        /// Upgrade from epoch 1 i64 tick count.
        pub fn fromEpoch1(basis: *const PrimeBasis, ticks: i64) FactoredInstant {
            var result = FactoredInstant.ZERO;
            result.n_active = basis.len;
            var r: u128 = if (ticks >= 0) @intCast(ticks) else @intCast(-ticks);
            for (basis.primes[0..basis.len], 0..) |p, i| {
                while (r % @as(u128, p) == 0 and r > 0) {
                    result.exponents[i] += 1;
                    r /= @as(u128, p);
                }
            }
            return result;
        }
    };
};

// ============================================================================
// TESTS — EPOCH 1 (original, must pass unchanged)
// ============================================================================

test "factorization" {
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
    try std.testing.expectEqual(@as(u64, 0), TICKS_PER_SECOND % 3);
    try std.testing.expectEqual(@as(u64, 0), TICKS_PER_SECOND % 5);
    try std.testing.expectEqual(@as(u64, 0), TICKS_PER_SECOND % 360);
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
    const one_sec = Instant{ .ticks = TICKS_PER_SECOND };
    const ns = one_sec.toNanoseconds();
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
    try std.testing.expectEqual(@as(i64, @intCast(TICKS_PER_SECOND)), t.ticks);
}

test "FFT window duration" {
    const w = Duration.fftWindow(.eeg);
    const secs = w.toSeconds();
    try std.testing.expect(secs > 1.023 and secs < 1.025);
}

test "comptime rate validation" {
    comptime {
        assertExactRate(250);
        assertExactRate(44100);
        assertExactRate(192000);
        assertExactRate(360);
        assertExactRate(3);
        assertExactRate(5);
    }
}

// ============================================================================
// TESTS — EPOCH 2 (expanded)
// ============================================================================

test "epoch 2: epoch chain divides exactly" {
    try std.testing.expectEqual(@as(u128, 0), Expanded.TICKS_PER_SECOND % @as(u128, TICKS_PER_SECOND));
    try std.testing.expectEqual(@as(u128, Expanded.FACTOR_FROM_EPOCH1), Expanded.TICKS_PER_SECOND / @as(u128, TICKS_PER_SECOND));
}

test "epoch 2: broken rates now work" {
    const broken = [_]u64{ 13, 165, 185, 508, 1017, 32768, 100000, 22579200 };
    for (broken) |rate| {
        try std.testing.expectEqual(@as(u128, 0), Expanded.TICKS_PER_SECOND % @as(u128, rate));
    }
}

test "epoch 2: upgrade roundtrip" {
    const e1 = Instant{ .ticks = @intCast(TICKS_PER_SECOND) }; // 1 second
    const e2 = e1.toExpanded();
    try std.testing.expectEqual(@as(i128, @intCast(Expanded.TICKS_PER_SECOND)), e2.ticks);
    const back = e2.toEpoch1();
    try std.testing.expectEqual(e1.ticks, back.ticks);
}

test "epoch 2: NTSC rates" {
    try std.testing.expectEqual(@as(u128, 0), (Expanded.TICKS_PER_SECOND * 1001) % 24000);
    try std.testing.expectEqual(@as(u128, 0), (Expanded.TICKS_PER_SECOND * 1001) % 30000);
    try std.testing.expectEqual(@as(u128, 0), (Expanded.TICKS_PER_SECOND * 1001) % 60000);
}

// ============================================================================
// TESTS — EPOCH 3 (extreme)
// ============================================================================

test "epoch 3: factorization" {
    var n: u128 = 1;
    for (Extreme.PRIMES, Extreme.EXPONENTS) |p, e| {
        var j: u8 = 0;
        while (j < e) : (j += 1) n *= @as(u128, p);
    }
    try std.testing.expectEqual(Extreme.TICKS_PER_SECOND, n);
}

test "epoch 3: epoch chain" {
    try std.testing.expectEqual(@as(u128, 0), Extreme.TICKS_PER_SECOND % Expanded.TICKS_PER_SECOND);
    try std.testing.expectEqual(@as(u128, 0), Extreme.TICKS_PER_SECOND % @as(u128, TICKS_PER_SECOND));
    try std.testing.expectEqual(@as(u128, 0), Extreme.TICKS_PER_SECOND % @as(u128, FLICKS_PER_SECOND));
}

test "epoch 3: Fibonacci rates divide" {
    for (Extreme.FIBONACCI_RATES) |fib| {
        if (fib == 0) continue;
        try std.testing.expectEqual(@as(u128, 0), Extreme.TICKS_PER_SECOND % @as(u128, fib));
    }
}

test "epoch 3: Padovan rates divide" {
    for (Extreme.PADOVAN_RATES) |pad| {
        if (pad == 0) continue;
        try std.testing.expectEqual(@as(u128, 0), Extreme.TICKS_PER_SECOND % @as(u128, pad));
    }
}

test "epoch 3: cross-modal fNIRS-to-Neuropixels" {
    const ratio = Extreme.samplesPerSample(10, 30000);
    try std.testing.expectEqual(@as(u128, 3000), ratio.?);
}

test "epoch 3: cross-modal DSD512-to-CD" {
    const ratio = Extreme.samplesPerSample(44100, 22579200);
    try std.testing.expectEqual(@as(u128, 512), ratio.?);
}

test "epoch 3: DBS 185 Hz" {
    try std.testing.expectEqual(@as(u128, 0), Extreme.TICKS_PER_SECOND % 185);
}

test "epoch 3: 4D/BTi MEG" {
    try std.testing.expectEqual(@as(u128, 0), Extreme.TICKS_PER_SECOND % 508);
    try std.testing.expectEqual(@as(u128, 0), Extreme.TICKS_PER_SECOND % 1017);
}

test "epoch 3: upgrade roundtrip" {
    const e1 = Instant{ .ticks = @intCast(TICKS_PER_SECOND) };
    const e3 = e1.toExtreme();
    try std.testing.expectEqual(@as(i128, @intCast(Extreme.TICKS_PER_SECOND)), e3.ticks);
    const back = e3.toEpoch1();
    try std.testing.expectEqual(e1.ticks, back.ticks);
}

// ============================================================================
// TESTS — UNBOUNDED
// ============================================================================

test "unbounded: basis init" {
    const basis = Unbounded.PrimeBasis.initEpoch3();
    try std.testing.expectEqual(@as(u8, 16), basis.len);
    try std.testing.expectEqual(@as(u16, 2), basis.primes[0]);
    try std.testing.expectEqual(@as(u16, 233), basis.primes[15]);
}

test "unbounded: register known rate adds nothing" {
    var basis = Unbounded.PrimeBasis.initEpoch3();
    const grew = basis.registerRate(44100);
    try std.testing.expect(!grew);
    try std.testing.expectEqual(@as(u8, 16), basis.len);
}

test "unbounded: register new prime rate extends basis" {
    var basis = Unbounded.PrimeBasis.initEpoch3();
    const grew = basis.registerRate(257);
    try std.testing.expect(grew);
    try std.testing.expectEqual(@as(u8, 17), basis.len);
    try std.testing.expectEqual(@as(u16, 257), basis.primes[16]);
}

test "unbounded: register Fibonacci prime 1597" {
    var basis = Unbounded.PrimeBasis.initEpoch3();
    const grew = basis.registerRate(1597);
    try std.testing.expect(grew);
    try std.testing.expectEqual(@as(u8, 17), basis.len);
}

test "unbounded: cascade multiple devices" {
    var basis = Unbounded.PrimeBasis.initEpoch3();
    _ = basis.registerRate(257);  // +1 prime
    _ = basis.registerRate(1597); // +1 prime
    _ = basis.registerRate(44100); // +0 (already covered)
    _ = basis.registerRate(3329); // Padovan prime, +1
    try std.testing.expect(basis.len >= 19);
}
