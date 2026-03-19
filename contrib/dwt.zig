//! Discrete Wavelet Transform — CDF 5/3 Lifting Scheme
//!
//! Port of dwt_bitplane.jl to Zig. Lossless integer-to-integer wavelet
//! used in JPEG 2000. The lifting scheme avoids any temporary buffers:
//!
//!   1. Split: even/odd interleave
//!   2. Predict: d[i] -= 0.5 * (s[i] + s[i+1])
//!   3. Update: s[i] += 0.25 * (d[i-1] + d[i])
//!
//! 2D transform is separable: rows then columns.
//!
//! This lives in contrib/ because DWT is signal processing, not
//! core serialization/ocapn infrastructure. However it integrates
//! with the core: wavelet subbands (LL/LH/HL/HH) form a structured
//! decomposition, and trit-plane coding (contrib/tritplane.zig) maps
//! coefficients to GF(3) balanced ternary for progressive coding.

const std = @import("std");
const Allocator = std.mem.Allocator;
const math = std.math;

// ============================================================================
// CDF 5/3 Lifting (1D)
// ============================================================================

/// Forward CDF 5/3 DWT on a 1D signal (in-place).
/// After transform: x[0..n/2] = smooth coefficients (low-pass)
///                  x[n/2..n] = detail coefficients (high-pass)
pub fn dwt53(x: []f64) void {
    const n = x.len;
    if (n < 2) return;
    const neven = (n + 1) >> 1;
    const nodd = n >> 1;

    // Work buffer on the stack for small signals, heap otherwise
    var stack_buf: [512]f64 = undefined;
    const even = stack_buf[0..neven];
    const odd = stack_buf[256 .. 256 + nodd];

    // Split into even/odd
    for (0..neven) |i| even[i] = x[i * 2];
    for (0..nodd) |i| odd[i] = x[i * 2 + 1];

    // Predict: d[i] = odd[i] - 0.5*(even[i] + even[min(i+1, neven-1)])
    for (0..nodd) |i| {
        const ei1 = even[@min(i + 1, neven - 1)];
        odd[i] -= 0.5 * (even[i] + ei1);
    }

    // Update: s[i] = even[i] + 0.25*(d[max(i,1)-1] + d[min(i, nodd-1)])
    for (0..neven) |i| {
        const dm1 = odd[if (i > 0) i - 1 else 0];
        const di = odd[@min(i, nodd - 1)];
        even[i] += 0.25 * (dm1 + di);
    }

    // Pack: smooth then detail
    @memcpy(x[0..neven], even);
    @memcpy(x[neven .. neven + nodd], odd);
}

/// Inverse CDF 5/3 DWT on a 1D signal (in-place).
pub fn idwt53(x: []f64) void {
    const n = x.len;
    if (n < 2) return;
    const neven = (n + 1) >> 1;
    const nodd = n >> 1;

    var stack_buf: [512]f64 = undefined;
    const even = stack_buf[0..neven];
    const odd = stack_buf[256 .. 256 + nodd];

    @memcpy(even, x[0..neven]);
    @memcpy(odd, x[neven .. neven + nodd]);

    // Undo update
    for (0..neven) |i| {
        const dm1 = odd[if (i > 0) i - 1 else 0];
        const di = odd[@min(i, nodd - 1)];
        even[i] -= 0.25 * (dm1 + di);
    }

    // Undo predict
    for (0..nodd) |i| {
        const ei1 = even[@min(i + 1, neven - 1)];
        odd[i] += 0.5 * (even[i] + ei1);
    }

    // Merge
    for (0..neven) |i| x[i * 2] = even[i];
    for (0..nodd) |i| x[i * 2 + 1] = odd[i];
}

// ============================================================================
// 2D Separable DWT
// ============================================================================

/// 2D forward DWT: rows then columns, `levels` levels of dyadic decomposition.
/// data is row-major, rows x cols. Allocates workspace.
pub fn dwt2d(allocator: Allocator, data: []f64, rows: u32, cols: u32, levels: u32) !void {
    var r = rows;
    var c = cols;
    const temp = try allocator.alloc(f64, @max(rows, cols));
    defer allocator.free(temp);

    for (0..levels) |_| {
        // Transform rows
        for (0..r) |row| {
            const start = row * cols;
            @memcpy(temp[0..c], data[start .. start + c]);
            dwt53(temp[0..c]);
            @memcpy(data[start .. start + c], temp[0..c]);
        }
        // Transform columns
        for (0..c) |col| {
            for (0..r) |row| temp[row] = data[row * cols + col];
            dwt53(temp[0..r]);
            for (0..r) |row| data[row * cols + col] = temp[row];
        }
        r = (r + 1) >> 1;
        c = (c + 1) >> 1;
    }
}

/// 2D inverse DWT.
pub fn idwt2d(allocator: Allocator, data: []f64, rows: u32, cols: u32, levels: u32) !void {
    const temp = try allocator.alloc(f64, @max(rows, cols));
    defer allocator.free(temp);

    // Compute sizes at each level
    var level_r: [16]u32 = undefined;
    var level_c: [16]u32 = undefined;
    var r = rows;
    var c = cols;
    for (0..levels) |l| {
        level_r[l] = r;
        level_c[l] = c;
        r = (r + 1) >> 1;
        c = (c + 1) >> 1;
    }

    // Inverse from coarsest to finest
    var l: u32 = levels;
    while (l > 0) {
        l -= 1;
        r = level_r[l];
        c = level_c[l];

        // Inverse columns
        for (0..c) |col| {
            for (0..r) |row| temp[row] = data[row * cols + col];
            idwt53(temp[0..r]);
            for (0..r) |row| data[row * cols + col] = temp[row];
        }
        // Inverse rows
        for (0..r) |row| {
            const start = row * cols;
            @memcpy(temp[0..c], data[start .. start + c]);
            idwt53(temp[0..c]);
            @memcpy(data[start .. start + c], temp[0..c]);
        }
    }
}

/// PSNR between original and reconstructed signal.
pub fn psnr(original: []const f64, reconstructed: []const f64) f64 {
    std.debug.assert(original.len == reconstructed.len);
    var max_val: f64 = 0;
    var mse: f64 = 0;
    for (original, reconstructed) |a, b| {
        if (@abs(a) > max_val) max_val = @abs(a);
        const diff = a - b;
        mse += diff * diff;
    }
    mse /= @floatFromInt(original.len);
    if (mse < 1e-30) return 999.0;
    return 10.0 * @log10(max_val * max_val / mse);
}

// ============================================================================
// Tests
// ============================================================================

test "dwt53 roundtrip 1D" {
    var x = [_]f64{ 1, 4, 2, 8, 5, 7, 3, 6 };
    var orig: [8]f64 = undefined;
    @memcpy(&orig, &x);

    dwt53(&x);
    idwt53(&x);

    for (orig, x) |a, b| {
        try std.testing.expectApproxEqAbs(a, b, 1e-12);
    }
}

test "dwt53 roundtrip small" {
    var x = [_]f64{ 3.0, 7.0 };
    const orig = x;
    dwt53(&x);
    idwt53(&x);
    for (orig, x) |a, b| {
        try std.testing.expectApproxEqAbs(a, b, 1e-12);
    }
}

test "dwt53 detail coefficients are differences" {
    var x = [_]f64{ 1, 1, 1, 1, 1, 1, 1, 1 };
    dwt53(&x);
    // Constant signal: all detail coefficients should be ~0
    for (x[4..8]) |d| {
        try std.testing.expectApproxEqAbs(0.0, d, 1e-12);
    }
}

test "dwt2d roundtrip" {
    const allocator = std.testing.allocator;

    // 8x8 test signal
    var data: [64]f64 = undefined;
    var orig: [64]f64 = undefined;
    for (&data, 0..) |*d, i| {
        const r: f64 = @floatFromInt(i / 8);
        const c: f64 = @floatFromInt(i % 8);
        d.* = @sin(r * 0.5) + @cos(c * 0.3);
    }
    @memcpy(&orig, &data);

    try dwt2d(allocator, &data, 8, 8, 2);
    try idwt2d(allocator, &data, 8, 8, 2);

    const q = psnr(&orig, &data);
    try std.testing.expect(q > 200.0); // near-perfect reconstruction
}

test "psnr of identical signals" {
    const a = [_]f64{ 1, 2, 3, 4 };
    try std.testing.expectEqual(@as(f64, 999.0), psnr(&a, &a));
}
