//! EEG Band Decomposition via Freed Factor-of-5 in Trit-Ticks
//!
//! The glimpse time base (141,120,000/s) trades 5⁵→5⁴ relative to
//! flicks (705,600,000/s). The freed factor of 5 encodes exactly 5
//! standard EEG frequency bands:
//!
//!   band_index 0 = Delta   (0.5–4 Hz)
//!   band_index 1 = Theta   (4–8 Hz)
//!   band_index 2 = Alpha   (8–13 Hz)
//!   band_index 3 = Beta    (13–30 Hz)
//!   band_index 4 = Gamma   (30–100 Hz)
//!
//! A BandTick packs a glimpse timestamp with a band index in the
//! sub-quantum freed by the flick→glimpse division.

const std = @import("std");
const glimpse = @import("glimpse.zig");

// ============================================================================
// EEG BAND ENUM — 5 bands = freed factor of 5
// ============================================================================

pub const EegBand = enum(u3) {
    delta = 0, // 0.5–4 Hz
    theta = 1, // 4–8 Hz
    alpha = 2, // 8–13 Hz
    beta = 3, // 13–30 Hz
    gamma = 4, // 30–100 Hz

    pub const COUNT: u3 = 5;

    /// Lower bound of band in Hz (inclusive).
    pub fn lowerHz(self: EegBand) f64 {
        return switch (self) {
            .delta => 0.5,
            .theta => 4.0,
            .alpha => 8.0,
            .beta => 13.0,
            .gamma => 30.0,
        };
    }

    /// Upper bound of band in Hz (exclusive, except gamma which is inclusive at 100).
    pub fn upperHz(self: EegBand) f64 {
        return switch (self) {
            .delta => 4.0,
            .theta => 8.0,
            .alpha => 13.0,
            .beta => 30.0,
            .gamma => 100.0,
        };
    }

    /// Center frequency of the band in Hz.
    pub fn centerHz(self: EegBand) f64 {
        return (self.lowerHz() + self.upperHz()) / 2.0;
    }

    /// Human-readable band name.
    pub fn name(self: EegBand) []const u8 {
        return switch (self) {
            .delta => "delta",
            .theta => "theta",
            .alpha => "alpha",
            .beta => "beta",
            .gamma => "gamma",
        };
    }

    /// Greek letter symbol.
    pub fn symbol(self: EegBand) []const u8 {
        return switch (self) {
            .delta => "δ",
            .theta => "θ",
            .alpha => "α",
            .beta => "β",
            .gamma => "γ",
        };
    }
};

// ============================================================================
// BAND CLASSIFICATION
// ============================================================================

/// Classify a frequency (Hz) into an EEG band.
/// Returns null if frequency is outside all bands (< 0.5 Hz or > 100 Hz).
pub fn classifyFrequency(freq_hz: f64) ?EegBand {
    if (freq_hz < 0.5) return null;
    if (freq_hz < 4.0) return .delta;
    if (freq_hz < 8.0) return .theta;
    if (freq_hz < 13.0) return .alpha;
    if (freq_hz < 30.0) return .beta;
    if (freq_hz <= 100.0) return .gamma;
    return null;
}

// ============================================================================
// TRIT-TICKS-PER-CYCLE
// ============================================================================

/// Compute the number of glimpses in one cycle of a given frequency.
/// Returns TICKS_PER_SECOND / freq_hz as a floating point value since
/// EEG frequencies are not generally integer divisors of the time base.
pub fn tritTicksPerCycle(freq_hz: f64) f64 {
    return @as(f64, @floatFromInt(glimpse.TICKS_PER_SECOND)) / freq_hz;
}

/// For integer frequencies that evenly divide the time base, return
/// exact glimpses-per-cycle. Returns null if not evenly divisible.
pub fn tritTicksPerCycleExact(freq_hz: u64) ?u64 {
    if (freq_hz == 0) return null;
    if (glimpse.TICKS_PER_SECOND % freq_hz != 0) return null;
    return glimpse.TICKS_PER_SECOND / freq_hz;
}

// ============================================================================
// BANDTICK — glimpse timestamp + band index
// ============================================================================

/// A BandTick encodes both a glimpse timestamp and an EEG band index.
///
/// The band index occupies the sub-quantum freed by the 5× reduction
/// from flicks. Conceptually:
///   flick_position = glimpse * 5 + band_index
///
/// This means each glimpse contains 5 "slots" — one per EEG band —
/// and a BandTick addresses a specific (time, band) pair.
pub const BandTick = struct {
    /// The glimpse timestamp (epoch 1).
    tick: glimpse.Instant,
    /// Which EEG band this measurement belongs to.
    band: EegBand,

    pub const ZERO = BandTick{
        .tick = glimpse.Instant.ZERO,
        .band = .delta,
    };

    /// Create a BandTick from a sample index, sample rate, and band.
    /// sample_index is 0-based within the recording.
    pub fn fromSample(sample_index: u64, sample_rate: u32, band: EegBand) BandTick {
        const ticks_per_sample = glimpse.TICKS_PER_SECOND / @as(u64, sample_rate);
        return .{
            .tick = .{ .ticks = @as(i64, @intCast(sample_index * ticks_per_sample)) },
            .band = band,
        };
    }

    /// Encode into a single u64 "flick-space" address:
    ///   flick_addr = glimpse * 5 + band_index
    /// This is lossless since band_index ∈ {0,1,2,3,4}.
    pub fn toFlickAddr(self: BandTick) i64 {
        return self.tick.ticks * 5 + @as(i64, @intFromEnum(self.band));
    }

    /// Decode from a flick-space address back to BandTick.
    pub fn fromFlickAddr(addr: i64) BandTick {
        const band_idx = @mod(addr, 5);
        const tick_val = @divFloor(addr, 5);
        return .{
            .tick = .{ .ticks = tick_val },
            .band = @enumFromInt(@as(u3, @intCast(band_idx))),
        };
    }

    /// Advance by one sample at the given rate, keeping the same band.
    pub fn advanceSample(self: BandTick, sample_rate: u32) BandTick {
        const ticks_per_sample = glimpse.TICKS_PER_SECOND / @as(u64, sample_rate);
        return .{
            .tick = .{ .ticks = self.tick.ticks + @as(i64, @intCast(ticks_per_sample)) },
            .band = self.band,
        };
    }

    /// Time in seconds (f64).
    pub fn toSeconds(self: BandTick) f64 {
        return @as(f64, @floatFromInt(self.tick.ticks)) / @as(f64, @floatFromInt(glimpse.TICKS_PER_SECOND));
    }

    /// The BAND_QUANTUM (TICKS_PER_SECOND / 5) relationship.
    /// Each band owns exactly one BAND_QUANTUM of the tick space.
    pub fn bandQuantumOffset(self: BandTick) u64 {
        return @as(u64, @intFromEnum(self.band)) * glimpse.BAND_QUANTUM;
    }
};

// ============================================================================
// COMPTIME VERIFICATION — sample rate divisibility
// ============================================================================

/// Verify at compile time that 141,120,000 divides evenly by a sample rate.
fn assertExactSampleRate(comptime rate: u64) void {
    if (glimpse.TICKS_PER_SECOND % rate != 0) {
        @compileError("Sample rate does not divide 141,120,000 (glimpse base)");
    }
}

// Common EEG sample rates. Compile-time check that each divides evenly.
// 141,120,000 = 2⁹ × 3² × 5⁴ × 7²
//   250  = 2 × 5³         → 141,120,000 / 250  = 564,480 ✓
//   256  = 2⁸             → 141,120,000 / 256  = 551,250 ✓
//   500  = 2² × 5³        → 141,120,000 / 500  = 282,240 ✓
//   512  = 2⁹             → 141,120,000 / 512  = 275,625 ✓
//   1000 = 2³ × 5³        → 141,120,000 / 1000 = 141,120 ✓
//   1024 = 2¹⁰            → FAILS: 2¹⁰ does not divide 2⁹
//
// Note: 1024 Hz does NOT divide 141,120,000 (needs 2¹⁰, base has 2⁹).
// It requires epoch 2 (Expanded). We verify the 5 that do divide, and
// separately verify 1024 requires epoch 2.
comptime {
    assertExactSampleRate(250);
    assertExactSampleRate(256);
    assertExactSampleRate(500);
    assertExactSampleRate(512);
    assertExactSampleRate(1000);
    // 1024 does NOT divide epoch 1 — verified in tests below.
    // It divides epoch 2 (2¹⁵ in the factorization).
}

// ============================================================================
// TESTS
// ============================================================================

test "freed factor of 5: BAND_QUANTUM = TICKS_PER_SECOND / 5" {
    try std.testing.expectEqual(@as(u64, 28_224_000), glimpse.BAND_QUANTUM);
    try std.testing.expectEqual(glimpse.TICKS_PER_SECOND, glimpse.BAND_QUANTUM * 5);
}

test "freed factor of 5: exactly 5 bands = EegBand.COUNT" {
    try std.testing.expectEqual(@as(u3, 5), EegBand.COUNT);
}

test "band classification: delta 0.5–4 Hz" {
    try std.testing.expectEqual(EegBand.delta, classifyFrequency(0.5).?);
    try std.testing.expectEqual(EegBand.delta, classifyFrequency(2.0).?);
    try std.testing.expectEqual(EegBand.delta, classifyFrequency(3.99).?);
}

test "band classification: theta 4–8 Hz" {
    try std.testing.expectEqual(EegBand.theta, classifyFrequency(4.0).?);
    try std.testing.expectEqual(EegBand.theta, classifyFrequency(6.0).?);
    try std.testing.expectEqual(EegBand.theta, classifyFrequency(7.99).?);
}

test "band classification: alpha 8–13 Hz" {
    try std.testing.expectEqual(EegBand.alpha, classifyFrequency(8.0).?);
    try std.testing.expectEqual(EegBand.alpha, classifyFrequency(10.0).?);
    try std.testing.expectEqual(EegBand.alpha, classifyFrequency(12.99).?);
}

test "band classification: beta 13–30 Hz" {
    try std.testing.expectEqual(EegBand.beta, classifyFrequency(13.0).?);
    try std.testing.expectEqual(EegBand.beta, classifyFrequency(20.0).?);
    try std.testing.expectEqual(EegBand.beta, classifyFrequency(29.99).?);
}

test "band classification: gamma 30–100 Hz" {
    try std.testing.expectEqual(EegBand.gamma, classifyFrequency(30.0).?);
    try std.testing.expectEqual(EegBand.gamma, classifyFrequency(40.0).?);
    try std.testing.expectEqual(EegBand.gamma, classifyFrequency(100.0).?);
}

test "band classification: out of range returns null" {
    try std.testing.expect(classifyFrequency(0.0) == null);
    try std.testing.expect(classifyFrequency(0.49) == null);
    try std.testing.expect(classifyFrequency(100.1) == null);
    try std.testing.expect(classifyFrequency(1000.0) == null);
}

test "glimpses-per-cycle: exact for integer divisors" {
    // 1 Hz → 141,120,000 ticks/cycle
    try std.testing.expectEqual(@as(u64, 141_120_000), tritTicksPerCycleExact(1).?);
    // 10 Hz → 14,112,000 ticks/cycle
    try std.testing.expectEqual(@as(u64, 14_112_000), tritTicksPerCycleExact(10).?);
    // 50 Hz → 2,822,400 ticks/cycle (mains hum)
    try std.testing.expectEqual(@as(u64, 2_822_400), tritTicksPerCycleExact(50).?);
    // 100 Hz → 1,411,200 ticks/cycle
    try std.testing.expectEqual(@as(u64, 1_411_200), tritTicksPerCycleExact(100).?);
}

test "trit-ticks-per-cycle: non-divisor returns null" {
    // 11 Hz does not divide 141,120,000
    try std.testing.expect(tritTicksPerCycleExact(11) == null);
    // 13 Hz does not divide 141,120,000
    try std.testing.expect(tritTicksPerCycleExact(13) == null);
}

test "trit-ticks-per-cycle: f64 for arbitrary frequencies" {
    const delta_low = tritTicksPerCycle(0.5); // 282,240,000
    try std.testing.expectApproxEqRel(282_240_000.0, delta_low, 1e-10);
    const alpha_10 = tritTicksPerCycle(10.0); // 14,112,000
    try std.testing.expectApproxEqRel(14_112_000.0, alpha_10, 1e-10);
}

test "BandTick: fromSample at 250 Hz" {
    const bt = BandTick.fromSample(0, 250, .alpha);
    try std.testing.expectEqual(@as(i64, 0), bt.tick.ticks);
    try std.testing.expectEqual(EegBand.alpha, bt.band);

    const bt1 = BandTick.fromSample(1, 250, .beta);
    try std.testing.expectEqual(@as(i64, 564_480), bt1.tick.ticks);
    try std.testing.expectEqual(EegBand.beta, bt1.band);
}

test "BandTick: fromSample at 500 Hz" {
    const bt = BandTick.fromSample(1, 500, .gamma);
    try std.testing.expectEqual(@as(i64, 282_240), bt.tick.ticks);
}

test "BandTick: flick-addr roundtrip" {
    const bands = [_]EegBand{ .delta, .theta, .alpha, .beta, .gamma };
    for (bands) |band| {
        const bt = BandTick.fromSample(42, 250, band);
        const addr = bt.toFlickAddr();
        const recovered = BandTick.fromFlickAddr(addr);
        try std.testing.expectEqual(bt.tick.ticks, recovered.tick.ticks);
        try std.testing.expectEqual(bt.band, recovered.band);
    }
}

test "BandTick: flick-addr encodes band in sub-quantum" {
    // Same tick, different bands → consecutive flick addresses
    const tick = glimpse.Instant{ .ticks = 1000 };
    const addrs = [5]i64{
        (BandTick{ .tick = tick, .band = .delta }).toFlickAddr(),
        (BandTick{ .tick = tick, .band = .theta }).toFlickAddr(),
        (BandTick{ .tick = tick, .band = .alpha }).toFlickAddr(),
        (BandTick{ .tick = tick, .band = .beta }).toFlickAddr(),
        (BandTick{ .tick = tick, .band = .gamma }).toFlickAddr(),
    };
    try std.testing.expectEqual(@as(i64, 5000), addrs[0]);
    try std.testing.expectEqual(@as(i64, 5001), addrs[1]);
    try std.testing.expectEqual(@as(i64, 5002), addrs[2]);
    try std.testing.expectEqual(@as(i64, 5003), addrs[3]);
    try std.testing.expectEqual(@as(i64, 5004), addrs[4]);
}

test "BandTick: advanceSample preserves band" {
    const bt0 = BandTick.fromSample(0, 250, .theta);
    const bt1 = bt0.advanceSample(250);
    try std.testing.expectEqual(EegBand.theta, bt1.band);
    try std.testing.expectEqual(@as(i64, 564_480), bt1.tick.ticks);
}

test "BandTick: toSeconds" {
    const bt = BandTick.fromSample(250, 250, .delta); // exactly 1 second
    try std.testing.expectApproxEqRel(1.0, bt.toSeconds(), 1e-10);
}

test "BandTick: bandQuantumOffset" {
    try std.testing.expectEqual(@as(u64, 0), (BandTick{ .tick = glimpse.Instant.ZERO, .band = .delta }).bandQuantumOffset());
    try std.testing.expectEqual(@as(u64, 28_224_000), (BandTick{ .tick = glimpse.Instant.ZERO, .band = .theta }).bandQuantumOffset());
    try std.testing.expectEqual(@as(u64, 56_448_000), (BandTick{ .tick = glimpse.Instant.ZERO, .band = .alpha }).bandQuantumOffset());
    try std.testing.expectEqual(@as(u64, 84_672_000), (BandTick{ .tick = glimpse.Instant.ZERO, .band = .beta }).bandQuantumOffset());
    try std.testing.expectEqual(@as(u64, 112_896_000), (BandTick{ .tick = glimpse.Instant.ZERO, .band = .gamma }).bandQuantumOffset());
    // Sum of all offsets: 0+1+2+3+4 = 10 BAND_QUANTUMs = 282,240,000
    // which equals 2 × TICKS_PER_SECOND, consistent with the algebra.
}

test "comptime: 5 common rates divide 141,120,000" {
    comptime {
        const rates = [_]u64{ 250, 256, 500, 512, 1000 };
        for (rates) |r| {
            if (glimpse.TICKS_PER_SECOND % r != 0)
                @compileError("expected divisible");
        }
    }
}

test "comptime: 1024 Hz requires epoch 2 (2^10 > 2^9)" {
    // 1024 does NOT divide epoch 1
    try std.testing.expect(glimpse.TICKS_PER_SECOND % 1024 != 0);
    // 1024 DOES divide epoch 2 (2^15 in factorization)
    try std.testing.expectEqual(@as(u128, 0), glimpse.Expanded.TICKS_PER_SECOND % 1024);
}

test "comptime: ticks-per-sample values for common rates" {
    try std.testing.expectEqual(@as(u64, 564_480), glimpse.TICKS_PER_SECOND / 250);
    try std.testing.expectEqual(@as(u64, 551_250), glimpse.TICKS_PER_SECOND / 256);
    try std.testing.expectEqual(@as(u64, 282_240), glimpse.TICKS_PER_SECOND / 500);
    try std.testing.expectEqual(@as(u64, 275_625), glimpse.TICKS_PER_SECOND / 512);
    try std.testing.expectEqual(@as(u64, 141_120), glimpse.TICKS_PER_SECOND / 1000);
}

test "band enum: all 5 bands are contiguous 0..4" {
    try std.testing.expectEqual(@as(u3, 0), @intFromEnum(EegBand.delta));
    try std.testing.expectEqual(@as(u3, 1), @intFromEnum(EegBand.theta));
    try std.testing.expectEqual(@as(u3, 2), @intFromEnum(EegBand.alpha));
    try std.testing.expectEqual(@as(u3, 3), @intFromEnum(EegBand.beta));
    try std.testing.expectEqual(@as(u3, 4), @intFromEnum(EegBand.gamma));
}

test "band enum: frequency ranges are contiguous and non-overlapping" {
    const bands = [_]EegBand{ .delta, .theta, .alpha, .beta };
    for (bands, 0..) |band, i| {
        _ = i;
        // Upper bound of this band = lower bound of next
        const next: EegBand = @enumFromInt(@intFromEnum(band) + 1);
        try std.testing.expectApproxEqRel(band.upperHz(), next.lowerHz(), 1e-10);
    }
}

test "GF(3) × band: TICKS_PER_SECOND = 3 × GF3_QUANTUM = 5 × BAND_QUANTUM" {
    try std.testing.expectEqual(glimpse.TICKS_PER_SECOND, 3 * glimpse.GF3_QUANTUM);
    try std.testing.expectEqual(glimpse.TICKS_PER_SECOND, 5 * glimpse.BAND_QUANTUM);
    // GF3 and band quanta are coprime factors: lcm(3,5) = 15
    // TICKS_PER_SECOND / 15 = 9,408,000 — the joint sub-quantum
    try std.testing.expectEqual(@as(u64, 9_408_000), glimpse.TICKS_PER_SECOND / 15);
}
