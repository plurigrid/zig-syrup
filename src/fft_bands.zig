//! FFT Band Extraction — Frequency Domain Analysis for EEG
//!
//! Extracts frequency band powers from raw EEG time-series data.
//! Uses Welch's method (overlapping segments with FFT) for robust power spectral density estimation.
//!
//! Frequency bands:
//!   - Delta:     0.5 - 4.0 Hz   (drowsiness, deep sleep)
//!   - Theta:     4.0 - 8.0 Hz   (meditation, relaxation)
//!   - Alpha:     8.0 - 13.0 Hz  (relaxed wakefulness)
//!   - Beta:     13.0 - 30.0 Hz  (active thinking, alertness)
//!   - Gamma:    30.0 - 100.0 Hz (cognitive processing, binding)
//!
//! Implemented as an iterative FFT (Cooley-Tukey in spirit, but using Zig's builtin);
//! for full Welch's method, integrate scipy.signal.welch reference implementation.

const std = @import("std");
const math = std.math;

// ============================================================================
// BAND DEFINITIONS
// ============================================================================

pub const Band = enum(u3) {
    delta = 0,
    theta = 1,
    alpha = 2,
    beta = 3,
    gamma = 4,

    pub fn name(self: Band) []const u8 {
        return switch (self) {
            .delta => "delta",
            .theta => "theta",
            .alpha => "alpha",
            .beta => "beta",
            .gamma => "gamma",
        };
    }

    pub fn freqRange(self: Band) [2]f64 {
        return switch (self) {
            .delta => [_]f64{ 0.5, 4.0 },
            .theta => [_]f64{ 4.0, 8.0 },
            .alpha => [_]f64{ 8.0, 13.0 },
            .beta => [_]f64{ 13.0, 30.0 },
            .gamma => [_]f64{ 30.0, 100.0 },
        };
    }
};

pub const NUM_BANDS = 5;

/// Band power structure: power in each frequency band
pub const BandPowers = struct {
    delta: f32,
    theta: f32,
    alpha: f32,
    beta: f32,
    gamma: f32,

    pub fn asArray(self: BandPowers) [NUM_BANDS]f32 {
        return [_]f32{ self.delta, self.theta, self.alpha, self.beta, self.gamma };
    }

    pub fn format(
        self: BandPowers,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        try writer.print("BandPowers{{ delta={d:.6}, theta={d:.6}, alpha={d:.6}, beta={d:.6}, gamma={d:.6} }}", .{
            self.delta,
            self.theta,
            self.alpha,
            self.beta,
            self.gamma,
        });
    }
};

// ============================================================================
// SIMPLE FFT-BASED POWER EXTRACTION
// ============================================================================

/// Compute power spectral density using Welch-like method (simplified)
/// Assumes input is a single window of samples (no overlapping for now)
pub fn extractBands(samples: []const f32, sample_rate: f64, allocator: std.mem.Allocator) !BandPowers {
    if (samples.len == 0) {
        return BandPowers{ .delta = 0, .theta = 0, .alpha = 0, .beta = 0, .gamma = 0 };
    }

    // For Tier 1, use a simple approach: zero-pad to next power of 2, apply Hanning window, compute FFT
    const n = samples.len;
    const fft_size = nextPowerOf2(n);

    // Allocate real FFT workspace
    var real = try allocator.alloc(f32, fft_size);
    defer allocator.free(real);

    var imag = try allocator.alloc(f32, fft_size);
    defer allocator.free(imag);

    // Copy samples with Hanning window to real part, zero-pad
    for (0..fft_size) |i| {
        if (i < n) {
            // Hanning window: 0.5 * (1 - cos(2π * i / (n-1)))
            const w: f32 = 0.5 * (1.0 - @cos(2.0 * math.pi * @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(n - 1))));
            real[i] = samples[i] * w;
        } else {
            real[i] = 0.0;
        }
        imag[i] = 0.0;
    }

    // Perform FFT (using Zig's builtin, or naive DFT for small sizes)
    try radix2Fft(real, imag, fft_size);

    // Compute power: |X[k]|² = real[k]² + imag[k]²
    var power = try allocator.alloc(f32, fft_size / 2 + 1);
    defer allocator.free(power);

    const norm = @as(f32, 2.0) / @as(f32, @floatFromInt(fft_size));
    for (0 .. fft_size / 2 + 1) |i| {
        const mag_sq = real[i] * real[i] + imag[i] * imag[i];
        power[i] = mag_sq * norm * norm; // Normalize by window energy
    }

    // Compute frequency resolution
    const freq_res = @as(f32, @floatCast(sample_rate / @as(f64, @floatFromInt(fft_size))));

    // Integrate power in each band
    var bands = BandPowers{ .delta = 0, .theta = 0, .alpha = 0, .beta = 0, .gamma = 0 };
    const band_list = [_]Band{ .delta, .theta, .alpha, .beta, .gamma };

    for (band_list) |band| {
        const freq_range = band.freqRange();
        const bin_low = @as(usize, @intFromFloat(freq_range[0] / @as(f64, freq_res)));
        const bin_high = @as(usize, @intFromFloat(freq_range[1] / @as(f64, freq_res)));

        var band_power: f32 = 0.0;
        for (bin_low..@min(bin_high + 1, power.len)) |i| {
            band_power += power[i];
        }

        switch (band) {
            .delta => bands.delta = band_power,
            .theta => bands.theta = band_power,
            .alpha => bands.alpha = band_power,
            .beta => bands.beta = band_power,
            .gamma => bands.gamma = band_power,
        }
    }

    return bands;
}

// ============================================================================
// FFT IMPLEMENTATION (Radix-2 Cooley-Tukey)
// ============================================================================

/// Check if n is a power of 2
fn isPowerOf2(n: usize) bool {
    return n > 0 and (n & (n - 1)) == 0;
}

/// Next power of 2 >= n
fn nextPowerOf2(n: usize) usize {
    var p: usize = 1;
    while (p < n) {
        p *= 2;
    }
    return p;
}

/// Bit-reversal permutation for FFT
fn bitReverse(i: usize, nbits: u6) usize {
    var result: usize = 0;
    var bit: u6 = 0;
    var val = i;
    while (bit < nbits) : (bit += 1) {
        result = (result << 1) | (val & 1);
        val >>= 1;
    }
    return result;
}

/// In-place radix-2 FFT (Cooley-Tukey algorithm)
fn radix2Fft(real: []f32, imag: []f32, n: usize) !void {
    if (!isPowerOf2(n)) {
        return error.NotPowerOf2;
    }

    const nbits = @as(u6, @intCast(std.math.log2_int(usize, n)));

    // Bit-reversal stage
    for (0..n) |i| {
        const j = bitReverse(i, nbits);
        if (i < j) {
            std.mem.swap(f32, &real[i], &real[j]);
            std.mem.swap(f32, &imag[i], &imag[j]);
        }
    }

    // FFT butterflies
    var m: usize = 2;
    while (m <= n) : (m *= 2) {
        const angle = -2.0 * math.pi / @as(f32, @floatFromInt(m));

        for (0..n / m) |k| {
            const w_real = @cos(@as(f32, @floatFromInt(k)) * angle);
            const w_imag = @sin(@as(f32, @floatFromInt(k)) * angle);

            var j: usize = 0;
            while (j < n) : (j += m) {
                const t = j + m / 2;

                // t_real = w * x[t]
                const t_real = w_real * real[t] - w_imag * imag[t];
                const t_imag = w_real * imag[t] + w_imag * real[t];

                // x[t] = x[j] - t
                real[t] = real[j] - t_real;
                imag[t] = imag[j] - t_imag;

                // x[j] = x[j] + t
                real[j] += t_real;
                imag[j] += t_imag;
            }
        }
    }
}

// ============================================================================
// TESTS
// ============================================================================

test "extract bands from sine wave" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Generate 1-second 10 Hz sine wave (alpha band)
    const sample_rate: f64 = 250.0;
    const n_samples: usize = @as(usize, @intFromFloat(sample_rate));
    var samples = try allocator.alloc(f32, n_samples);
    defer allocator.free(samples);

    for (0..n_samples) |i| {
        const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatCast(sample_rate));
        samples[i] = @sin(2.0 * math.pi * 10.0 * t);
    }

    const bands = try extractBands(samples, sample_rate, allocator);

    // Alpha band (8-13 Hz) should have highest power
    try std.testing.expect(bands.alpha > bands.delta);
    try std.testing.expect(bands.alpha > bands.theta);
    try std.testing.expect(bands.alpha > bands.beta);
    try std.testing.expect(bands.alpha > bands.gamma);
}

test "extract bands from zero signal" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const sample_rate: f64 = 250.0;
    const n_samples: usize = 250;
    var samples = try allocator.alloc(f32, n_samples);
    defer allocator.free(samples);

    for (0..n_samples) |i| {
        samples[i] = 0.0;
    }

    const bands = try extractBands(samples, sample_rate, allocator);

    // All bands should be close to zero
    try std.testing.expectApproxEqAbs(bands.delta, 0.0, 0.001);
    try std.testing.expectApproxEqAbs(bands.theta, 0.0, 0.001);
    try std.testing.expectApproxEqAbs(bands.alpha, 0.0, 0.001);
    try std.testing.expectApproxEqAbs(bands.beta, 0.0, 0.001);
    try std.testing.expectApproxEqAbs(bands.gamma, 0.0, 0.001);
}

test "next power of 2" {
    try std.testing.expectEqual(nextPowerOf2(1), 1);
    try std.testing.expectEqual(nextPowerOf2(2), 2);
    try std.testing.expectEqual(nextPowerOf2(3), 4);
    try std.testing.expectEqual(nextPowerOf2(7), 8);
    try std.testing.expectEqual(nextPowerOf2(250), 256);
}

test "bit reverse" {
    // bitReverse(1, 3) = bitReverse(001, 3) = 100 = 4
    try std.testing.expectEqual(bitReverse(1, 3), 4);
    // bitReverse(2, 3) = bitReverse(010, 3) = 010 = 2
    try std.testing.expectEqual(bitReverse(2, 3), 2);
    // bitReverse(3, 3) = bitReverse(011, 3) = 110 = 6
    try std.testing.expectEqual(bitReverse(3, 3), 6);
}
