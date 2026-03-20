//! Trit-Plane Coding — GF(3) Progressive Wavelet Coefficient Coding
//!
//! Port of tritplane.jl to Zig. The core insight: wavelet coefficients
//! are SIGNED quantities clustered near ZERO. Binary bit-planes split
//! this into {significant?, sign?} = 2 conditional bits. GF(3) trit-planes
//! fuse it into {-1, 0, +1} = 1 ternary symbol = 1.585 bits.
//!
//! Five improvements over binary bit-planes:
//!   1. Fewer symbols: sign fused with significance
//!   2. Unbiased truncation: balanced ternary rounding = truncation (no DC drift)
//!   3. Lower entropy: 0-trit dominates in detail subbands (80-95% zeros)
//!   4. GF(3) quad conservation: free error detection across LL/LH/HL/HH
//!   5. Symmetric error: negation = per-trit flip, no DC drift
//!
//! This lives in contrib/ because it's a compression technique built
//! on top of the core GF(3) infrastructure (splitmix_trit, entangle).

const std = @import("std");
const Allocator = std.mem.Allocator;
const math = std.math;

/// A trit value in GF(3): {-1, 0, +1}
pub const Trit = i8;

// ============================================================================
// Balanced Ternary Conversion
// ============================================================================

/// Maximum trits per coefficient (covers i32 range: 3^20 > 2^31)
pub const MAX_TRITS = 20;

/// Balanced ternary representation: trits[0] is LST (least significant trit).
pub const BalancedTernary = struct {
    trits: [MAX_TRITS]Trit,
    len: u8,

    pub fn zero() BalancedTernary {
        return .{ .trits = [_]Trit{0} ** MAX_TRITS, .len = MAX_TRITS };
    }
};

/// Convert integer to balanced ternary.
/// Uses the standard algorithm: divide by 3, carry if remainder = 2.
pub fn toBalancedTernary(n_in: i32) BalancedTernary {
    var bt = BalancedTernary.zero();
    if (n_in == 0) return bt;

    const negative = n_in < 0;
    var n: u32 = if (negative) @intCast(-@as(i64, n_in)) else @intCast(n_in);
    var i: usize = 0;

    while (n > 0 and i < MAX_TRITS) : (i += 1) {
        const r = n % 3;
        n /= 3;
        if (r == 2) {
            bt.trits[i] = -1;
            n += 1; // carry
        } else {
            bt.trits[i] = @intCast(r);
        }
    }

    if (negative) {
        for (&bt.trits) |*t| t.* = -t.*;
    }

    bt.len = MAX_TRITS;
    return bt;
}

/// Convert balanced ternary back to integer.
pub fn fromBalancedTernary(bt: *const BalancedTernary) i32 {
    var val: i64 = 0;
    var pow: i64 = 1;
    for (0..bt.len) |i| {
        val += @as(i64, bt.trits[i]) * pow;
        pow *= 3;
    }
    return @intCast(val);
}

/// Truncate to keep only the `keep` most significant trits (zero the rest).
pub fn truncateTrits(bt: *const BalancedTernary, keep: u32) BalancedTernary {
    var result = bt.*;
    if (keep >= MAX_TRITS) return result;
    const zero_count = MAX_TRITS - keep;
    for (0..zero_count) |i| {
        result.trits[i] = 0;
    }
    return result;
}

// ============================================================================
// Trit-Plane Encoder/Decoder
// ============================================================================

/// Encode wavelet coefficients as trit-planes (MST-first order).
/// Returns trit-planes as a flat array: plane[p][i] = trit of coeff i at plane p.
/// Planes ordered from most significant to least significant.
pub fn tritplaneEncode(allocator: Allocator, coeffs: []const i32, num_planes: u32) ![]Trit {
    const n = coeffs.len;
    const total = n * num_planes;
    const planes = try allocator.alloc(Trit, total);

    for (coeffs, 0..) |c, i| {
        const bt = toBalancedTernary(c);
        for (0..num_planes) |p| {
            // MST first: plane 0 = trit at position (MAX_TRITS - 1)
            const trit_idx = MAX_TRITS - 1 - p;
            planes[p * n + i] = bt.trits[trit_idx];
        }
    }

    return planes;
}

/// Decode trit-planes back to coefficients.
/// Truncation: only uses the first `num_planes` planes.
pub fn tritplaneDecode(allocator: Allocator, planes: []const Trit, n: u32, num_planes: u32) ![]i32 {
    const coeffs = try allocator.alloc(i32, n);

    for (0..n) |i| {
        var bt = BalancedTernary.zero();
        for (0..num_planes) |p| {
            const trit_idx = MAX_TRITS - 1 - p;
            bt.trits[trit_idx] = planes[p * n + i];
        }
        coeffs[i] = fromBalancedTernary(&bt);
    }

    return coeffs;
}

// ============================================================================
// Entropy and Statistics
// ============================================================================

/// Count trit distribution in a plane: returns counts for {-1, 0, +1}
pub fn tritDistribution(plane: []const Trit) [3]u32 {
    var counts = [3]u32{ 0, 0, 0 };
    for (plane) |t| {
        const idx: usize = @intCast(@as(i16, t) + 1);
        counts[idx] += 1;
    }
    return counts;
}

/// Shannon entropy of a trit plane (bits per symbol).
pub fn tritEntropy(plane: []const Trit) f64 {
    const counts = tritDistribution(plane);
    const n: f64 = @floatFromInt(plane.len);
    if (n == 0) return 0;

    var h: f64 = 0;
    for (counts) |c| {
        if (c > 0) {
            const p: f64 = @as(f64, @floatFromInt(c)) / n;
            h -= p * @log2(p);
        }
    }
    return h;
}

/// GF(3) checksum of a trit plane: sum of all trits mod 3.
/// Returns 0 if balanced (conservation holds).
pub fn gf3Checksum(plane: []const Trit) Trit {
    var sum: i32 = 0;
    for (plane) |t| sum += t;
    const r = @mod(sum, 3);
    return switch (r) {
        0 => 0,
        1 => 1,
        2 => -1,
        else => unreachable,
    };
}

/// Truncation bias: mean error when truncating to `keep` planes.
/// Balanced ternary has zero truncation bias (key advantage over binary).
pub fn truncationBias(coeffs: []const i32, num_planes: u32) f64 {
    var total_error: f64 = 0;
    for (coeffs) |c| {
        const bt = toBalancedTernary(c);
        const trunc = truncateTrits(&bt, num_planes);
        const reconstructed = fromBalancedTernary(&trunc);
        total_error += @as(f64, @floatFromInt(reconstructed)) - @as(f64, @floatFromInt(c));
    }
    return total_error / @as(f64, @floatFromInt(coeffs.len));
}

// ============================================================================
// Tests
// ============================================================================

test "balanced ternary roundtrip" {
    const cases = [_]i32{ 0, 1, -1, 2, -2, 3, -3, 4, -4, 13, -13, 42, -42, 100, -100, 1000, -1000, 99999, -99999 };
    for (cases) |n| {
        const bt = toBalancedTernary(n);
        const back = fromBalancedTernary(&bt);
        try std.testing.expectEqual(n, back);
    }
}

test "balanced ternary trits are in {-1, 0, +1}" {
    const bt = toBalancedTernary(12345);
    for (bt.trits[0..bt.len]) |t| {
        try std.testing.expect(t >= -1 and t <= 1);
    }
}

test "balanced ternary negation flips trits" {
    const pos = toBalancedTernary(42);
    const neg = toBalancedTernary(-42);
    for (pos.trits[0..pos.len], neg.trits[0..neg.len]) |p, n| {
        try std.testing.expectEqual(-p, n);
    }
}

test "truncation preserves magnitude order" {
    const bt = toBalancedTernary(100);
    var prev_err: f64 = @as(f64, @floatFromInt(@abs(100 - fromBalancedTernary(&truncateTrits(&bt, 1)))));
    for (2..MAX_TRITS) |keep| {
        const trunc = truncateTrits(&bt, @intCast(keep));
        const err: f64 = @as(f64, @floatFromInt(@abs(100 - fromBalancedTernary(&trunc))));
        try std.testing.expect(err <= prev_err + 1e-10);
        prev_err = err;
    }
}

test "tritplane encode/decode roundtrip" {
    const allocator = std.testing.allocator;
    const coeffs = [_]i32{ 42, -17, 0, 100, -1, 3 };

    const planes = try tritplaneEncode(allocator, &coeffs, MAX_TRITS);
    defer allocator.free(planes);

    const decoded = try tritplaneDecode(allocator, planes, @intCast(coeffs.len), MAX_TRITS);
    defer allocator.free(decoded);

    for (coeffs, decoded) |orig, dec| {
        try std.testing.expectEqual(orig, dec);
    }
}

test "tritplane progressive quality" {
    const allocator = std.testing.allocator;
    const coeffs = [_]i32{ 42, -17, 0, 100, -1, 3, 256, -50 };

    const planes = try tritplaneEncode(allocator, &coeffs, MAX_TRITS);
    defer allocator.free(planes);

    // Quality should improve with more planes
    var prev_mse: f64 = math.floatMax(f64);
    for (1..MAX_TRITS) |np| {
        const decoded = try tritplaneDecode(allocator, planes, @intCast(coeffs.len), @intCast(np));
        defer allocator.free(decoded);

        var mse: f64 = 0;
        for (coeffs, decoded) |orig, dec| {
            const diff: f64 = @as(f64, @floatFromInt(orig)) - @as(f64, @floatFromInt(dec));
            mse += diff * diff;
        }
        mse /= @floatFromInt(coeffs.len);
        try std.testing.expect(mse <= prev_mse + 1e-10);
        prev_mse = mse;
    }
}

test "trit entropy of sparse plane is low" {
    // Mostly zeros (like wavelet detail coefficients)
    var plane: [100]Trit = undefined;
    for (&plane) |*t| t.* = 0;
    plane[10] = 1;
    plane[50] = -1;

    const h = tritEntropy(&plane);
    try std.testing.expect(h < 0.2); // Very low entropy
}

test "gf3 checksum" {
    const plane = [_]Trit{ 1, -1, 0, 1, -1 };
    try std.testing.expectEqual(@as(Trit, 0), gf3Checksum(&plane));

    const unbalanced = [_]Trit{ 1, 1, 0 }; // sum=2 ≡ -1 mod 3
    try std.testing.expect(gf3Checksum(&unbalanced) != 0);
}

test "truncation bias near zero" {
    // Balanced ternary truncation should have near-zero mean bias
    const coeffs = [_]i32{ 10, -10, 20, -20, 5, -5, 1, -1 };
    const bias = truncationBias(&coeffs, 5);
    try std.testing.expectApproxEqAbs(0.0, bias, 5.0);
}
