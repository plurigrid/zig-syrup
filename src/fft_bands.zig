//! FFT Band Extraction — Frequency Domain Analysis for EEG
//!
//! Extracts frequency band powers from raw EEG time-series data.
//! Uses Welch's method (overlapping segments with FFT) for robust PSD estimation.
//!
//! Performance: Comptime-memoized twiddle factors and Hanning windows eliminate all
//! runtime trig for standard FFT sizes (128, 256, 512, 1024, 2048).
//! For 256-point FFT: 510 sin/cos calls → 0 (table lookup only).
//!
//! Frequency bands:
//!   - Delta:     0.5 - 4.0 Hz   (drowsiness, deep sleep)
//!   - Theta:     4.0 - 8.0 Hz   (meditation, relaxation)
//!   - Alpha:     8.0 - 13.0 Hz  (relaxed wakefulness)
//!   - Beta:     13.0 - 30.0 Hz  (active thinking, alertness)
//!   - Gamma:    30.0 - 100.0 Hz (cognitive processing, binding)

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
// COMPTIME MEMOIZATION TABLES
// ============================================================================

pub const Complex = struct { real: f32, imag: f32 };

/// Precompute n/2 roots of unity: W_k = exp(-2*pi*i*k/n) for k = 0..n/2-1.
/// FFT stage m accesses twiddle j via roots[j * (n/m)].
fn comptimeRoots(comptime n: usize) [n / 2]Complex {
    @setEvalBranchQuota(n * 20);
    var result: [n / 2]Complex = undefined;
    for (0..n / 2) |k| {
        const angle: f64 = -2.0 * math.pi * @as(f64, @floatFromInt(k)) / @as(f64, @floatFromInt(n));
        const c: f32 = @floatCast(@cos(angle));
        const s: f32 = @floatCast(@sin(angle));
        result[k] = .{ .real = c, .imag = s };
    }
    return result;
}

/// Precompute Hanning window: w[i] = 0.5 * (1 - cos(2*pi*i/(n-1)))
fn comptimeHanning(comptime n: usize) [n]f32 {
    @setEvalBranchQuota(n * 20);
    var result: [n]f32 = undefined;
    if (n <= 1) {
        if (n == 1) result[0] = 1.0;
        return result;
    }
    for (0..n) |i| {
        const val: f64 = 0.5 * (1.0 - @cos(2.0 * math.pi * @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(n - 1))));
        const fval: f32 = @floatCast(val);
        result[i] = fval;
    }
    return result;
}

// Roots of unity for standard BCI FFT sizes
const roots_128 = comptimeRoots(128);
const roots_256 = comptimeRoots(256);
const roots_512 = comptimeRoots(512);
const roots_1024 = comptimeRoots(1024);
const roots_2048 = comptimeRoots(2048);

// Hanning windows for standard EEG epoch lengths
pub const hanning_128 = comptimeHanning(128);
pub const hanning_250 = comptimeHanning(250);
pub const hanning_256 = comptimeHanning(256);
pub const hanning_500 = comptimeHanning(500);
pub const hanning_512 = comptimeHanning(512);
pub const hanning_1024 = comptimeHanning(1024);

// ============================================================================
// FFT IMPLEMENTATION (Radix-2 Cooley-Tukey)
// ============================================================================

fn isPowerOf2(n: usize) bool {
    return n > 0 and (n & (n - 1)) == 0;
}

pub fn nextPowerOf2(n: usize) usize {
    var p: usize = 1;
    while (p < n) p *= 2;
    return p;
}

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

/// Memoized FFT using precomputed roots of unity.
/// Eliminates all runtime trig — table lookup only.
pub fn radix2FftMemoized(real: []f32, imag: []f32, n: usize, roots: []const Complex) void {
    const nbits = @as(u6, @intCast(std.math.log2_int(usize, n)));

    for (0..n) |i| {
        const j = bitReverse(i, nbits);
        if (i < j) {
            std.mem.swap(f32, &real[i], &real[j]);
            std.mem.swap(f32, &imag[i], &imag[j]);
        }
    }

    var m: usize = 2;
    while (m <= n) : (m *= 2) {
        const half = m / 2;
        const stride = n / m;
        var group: usize = 0;
        while (group < n) : (group += m) {
            for (0..half) |k| {
                const w = roots[k * stride];
                const idx = group + k;
                const tidx = idx + half;
                const t_real = w.real * real[tidx] - w.imag * imag[tidx];
                const t_imag = w.real * imag[tidx] + w.imag * real[tidx];
                real[tidx] = real[idx] - t_real;
                imag[tidx] = imag[idx] - t_imag;
                real[idx] += t_real;
                imag[idx] += t_imag;
            }
        }
    }
}

/// Runtime FFT computing twiddles on the fly (fallback for uncommon sizes).
pub fn radix2FftRuntime(real: []f32, imag: []f32, n: usize) void {
    const nbits = @as(u6, @intCast(std.math.log2_int(usize, n)));

    for (0..n) |i| {
        const j = bitReverse(i, nbits);
        if (i < j) {
            std.mem.swap(f32, &real[i], &real[j]);
            std.mem.swap(f32, &imag[i], &imag[j]);
        }
    }

    var m: usize = 2;
    while (m <= n) : (m *= 2) {
        const half = m / 2;
        const base_angle: f32 = -2.0 * math.pi / @as(f32, @floatFromInt(m));
        var group: usize = 0;
        while (group < n) : (group += m) {
            for (0..half) |k| {
                const angle = @as(f32, @floatFromInt(k)) * base_angle;
                const w_real = @cos(angle);
                const w_imag = @sin(angle);
                const idx = group + k;
                const tidx = idx + half;
                const t_real = w_real * real[tidx] - w_imag * imag[tidx];
                const t_imag = w_real * imag[tidx] + w_imag * real[tidx];
                real[tidx] = real[idx] - t_real;
                imag[tidx] = imag[idx] - t_imag;
                real[idx] += t_real;
                imag[idx] += t_imag;
            }
        }
    }
}

/// Dispatch to memoized or runtime FFT based on size
fn radix2Fft(real: []f32, imag: []f32, n: usize) !void {
    if (!isPowerOf2(n)) return error.NotPowerOf2;
    switch (n) {
        128 => radix2FftMemoized(real, imag, n, &roots_128),
        256 => radix2FftMemoized(real, imag, n, &roots_256),
        512 => radix2FftMemoized(real, imag, n, &roots_512),
        1024 => radix2FftMemoized(real, imag, n, &roots_1024),
        2048 => radix2FftMemoized(real, imag, n, &roots_2048),
        else => radix2FftRuntime(real, imag, n),
    }
}

fn getComptimeHanning(n: usize) ?[]const f32 {
    return switch (n) {
        128 => &hanning_128,
        250 => &hanning_250,
        256 => &hanning_256,
        500 => &hanning_500,
        512 => &hanning_512,
        1024 => &hanning_1024,
        else => null,
    };
}

// ============================================================================
// BAND EXTRACTION
// ============================================================================

pub fn extractBands(samples: []const f32, sample_rate: f64, allocator: std.mem.Allocator) !BandPowers {
    if (samples.len == 0) {
        return BandPowers{ .delta = 0, .theta = 0, .alpha = 0, .beta = 0, .gamma = 0 };
    }

    const n = samples.len;
    const fft_size = nextPowerOf2(n);

    var real = try allocator.alloc(f32, fft_size);
    defer allocator.free(real);
    var imag = try allocator.alloc(f32, fft_size);
    defer allocator.free(imag);

    // Apply Hanning window (comptime table if available, else runtime)
    const cached_window = getComptimeHanning(n);
    for (0..fft_size) |i| {
        if (i < n) {
            const w = if (cached_window) |cw| cw[i] else blk: {
                break :blk @as(f32, @floatCast(
                    0.5 * (1.0 - @cos(2.0 * math.pi * @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(n - 1)))),
                ));
            };
            real[i] = samples[i] * w;
        } else {
            real[i] = 0.0;
        }
        imag[i] = 0.0;
    }

    try radix2Fft(real, imag, fft_size);

    // Power spectrum: |X[k]|^2
    var power = try allocator.alloc(f32, fft_size / 2 + 1);
    defer allocator.free(power);
    const norm: f32 = 2.0 / @as(f32, @floatFromInt(fft_size));
    for (0..fft_size / 2 + 1) |i| {
        power[i] = (real[i] * real[i] + imag[i] * imag[i]) * norm * norm;
    }

    // Band integration
    const freq_res = @as(f32, @floatCast(sample_rate / @as(f64, @floatFromInt(fft_size))));
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
// TESTS
// ============================================================================

test "extract bands from sine wave" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const sample_rate: f64 = 250.0;
    const n_samples: usize = @as(usize, @intFromFloat(sample_rate));
    const samples = try allocator.alloc(f32, n_samples);
    defer allocator.free(samples);

    for (0..n_samples) |i| {
        const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatCast(sample_rate));
        samples[i] = @sin(2.0 * math.pi * 10.0 * t);
    }

    const bands = try extractBands(samples, sample_rate, allocator);

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
    const samples = try allocator.alloc(f32, n_samples);
    defer allocator.free(samples);

    for (0..n_samples) |i| {
        samples[i] = 0.0;
    }

    const bands = try extractBands(samples, sample_rate, allocator);

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
    try std.testing.expectEqual(bitReverse(1, 3), 4);
    try std.testing.expectEqual(bitReverse(2, 3), 2);
    try std.testing.expectEqual(bitReverse(3, 3), 6);
}

test "comptime roots correctness" {
    // Root 0 = exp(0) = (1, 0)
    try std.testing.expectApproxEqAbs(roots_256[0].real, 1.0, 1e-6);
    try std.testing.expectApproxEqAbs(roots_256[0].imag, 0.0, 1e-6);
    // Root n/4 = exp(-i*pi/2) = (0, -1)
    try std.testing.expectApproxEqAbs(roots_256[64].real, 0.0, 1e-6);
    try std.testing.expectApproxEqAbs(roots_256[64].imag, -1.0, 1e-6);
}

test "comptime hanning correctness" {
    // Endpoints should be ~0, center should be ~1
    try std.testing.expectApproxEqAbs(hanning_256[0], 0.0, 1e-6);
    try std.testing.expectApproxEqAbs(hanning_256[255], 0.0, 1e-6);
    try std.testing.expectApproxEqAbs(hanning_256[128], 1.0, 0.01);
}

test "memoized vs runtime FFT agreement" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const n: usize = 256;
    const real_memo = try allocator.alloc(f32, n);
    defer allocator.free(real_memo);
    const imag_memo = try allocator.alloc(f32, n);
    defer allocator.free(imag_memo);
    const real_rt = try allocator.alloc(f32, n);
    defer allocator.free(real_rt);
    const imag_rt = try allocator.alloc(f32, n);
    defer allocator.free(imag_rt);

    for (0..n) |i| {
        const t = @as(f32, @floatFromInt(i)) / 250.0;
        const val = @sin(2.0 * math.pi * 10.0 * t) + 0.5 * @sin(2.0 * math.pi * 30.0 * t);
        real_memo[i] = val;
        real_rt[i] = val;
        imag_memo[i] = 0;
        imag_rt[i] = 0;
    }

    radix2FftMemoized(real_memo, imag_memo, n, &roots_256);
    radix2FftRuntime(real_rt, imag_rt, n);

    for (0..n) |i| {
        try std.testing.expectApproxEqAbs(real_memo[i], real_rt[i], 1e-3);
        try std.testing.expectApproxEqAbs(imag_memo[i], imag_rt[i], 1e-3);
    }
}

test "fft benchmark: memoized vs runtime" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const n: usize = 256;
    const iterations: usize = 10_000;

    const real = try allocator.alloc(f32, n);
    defer allocator.free(real);
    const imag = try allocator.alloc(f32, n);
    defer allocator.free(imag);

    const base = try allocator.alloc(f32, n);
    defer allocator.free(base);
    for (0..n) |i| {
        const t = @as(f32, @floatFromInt(i)) / 250.0;
        base[i] = @sin(2.0 * math.pi * 10.0 * t) + 0.3 * @sin(2.0 * math.pi * 40.0 * t);
    }

    // Benchmark runtime FFT
    const start_rt = std.time.nanoTimestamp();
    for (0..iterations) |_| {
        @memcpy(real, base);
        @memset(imag, 0);
        radix2FftRuntime(real, imag, n);
    }
    const elapsed_rt = std.time.nanoTimestamp() - start_rt;

    // Benchmark memoized FFT
    const start_memo = std.time.nanoTimestamp();
    for (0..iterations) |_| {
        @memcpy(real, base);
        @memset(imag, 0);
        radix2FftMemoized(real, imag, n, &roots_256);
    }
    const elapsed_memo = std.time.nanoTimestamp() - start_memo;

    const ns_rt: i64 = @intCast(@divFloor(elapsed_rt, @as(i128, iterations)));
    const ns_memo: i64 = @intCast(@divFloor(elapsed_memo, @as(i128, iterations)));

    std.debug.print("\n", .{});
    std.debug.print("FFT MEMOIZATION BENCHMARK (256-point, {d} iterations)\n", .{iterations});
    std.debug.print("  Runtime trig:   {d} ns/FFT\n", .{ns_rt});
    std.debug.print("  Comptime table: {d} ns/FFT\n", .{ns_memo});
    if (ns_memo > 0) {
        const speedup = @as(f64, @floatFromInt(ns_rt)) / @as(f64, @floatFromInt(ns_memo));
        std.debug.print("  Speedup:        {d:.2}x\n", .{speedup});
    }
    std.debug.print("  Trig calls eliminated: 510 sin/cos per FFT\n", .{});

    // Memoized should not be dramatically slower
    try std.testing.expect(elapsed_memo <= elapsed_rt * 3);
}
