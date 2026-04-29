//! zigbjj entropy: Shannon entropy over GF(3) trit sequences.
//!
//! Phase 4 of the lazybjj-unison rebuild plan, ported into Zig.
//!
//! The interaction-entropy of a protocol trace is the Shannon entropy of
//! its trit-class distribution. For a sequence drawn from a single class
//! the entropy is 0; for a sequence balanced across all three classes it
//! plateaus at log2(3) ≈ 1.5849625 bits.
//!
//! No allocator: traces are plain slices the caller owns.

const std = @import("std");
const ziggit = @import("ziggit.zig");
const splitmix = @import("splitmix_trit.zig");
const Trit = splitmix.Trit;

/// One protocol step: change_id, the trit it carries, and a timestamp.
/// `entropy_so_far` is filled in by the caller (or computed on-the-fly).
pub const InteractionEvent = struct {
    change_id: [32]u8,
    trit: Trit,
    timestamp: u64,
    entropy_so_far: f64 = 0.0,
};

/// log2(3) — the maximal Shannon entropy of a 3-class distribution.
pub const LOG2_3: f64 = 1.5849625007211562;

/// Shannon entropy in bits of a trit slice. Empty slice → 0.
pub fn shannonEntropyTrits(trits: []const Trit) f64 {
    if (trits.len == 0) return 0;
    const kt = ziggit.KernelTriad.fromTrits(trits);
    const n = @as(f64, @floatFromInt(trits.len));
    var h: f64 = 0;
    inline for (.{ kt.plus, kt.ergodic, kt.minus }) |c| {
        if (c > 0) {
            const p = @as(f64, @floatFromInt(c)) / n;
            h -= p * @log2(p);
        }
    }
    return h;
}

/// Shannon entropy of a slice of InteractionEvents (uses each event's trit).
pub fn shannonEntropyEvents(events: []const InteractionEvent) f64 {
    if (events.len == 0) return 0;
    var counts: ziggit.KernelTriad = .{ .plus = 0, .ergodic = 0, .minus = 0 };
    for (events) |ev| switch (ev.trit) {
        .plus => counts.plus += 1,
        .ergodic => counts.ergodic += 1,
        .minus => counts.minus += 1,
    };
    const n = @as(f64, @floatFromInt(events.len));
    var h: f64 = 0;
    inline for (.{ counts.plus, counts.ergodic, counts.minus }) |c| {
        if (c > 0) {
            const p = @as(f64, @floatFromInt(c)) / n;
            h -= p * @log2(p);
        }
    }
    return h;
}

/// Per-event running entropy, one f64 per element of `trits`.
/// `out` must have the same length as `trits`. Each `out[i]` is the
/// Shannon entropy of `trits[0..=i]`. Useful for criticality detection
/// (Phase 5 takes the gradient of this).
pub fn runningEntropy(trits: []const Trit, out: []f64) void {
    std.debug.assert(out.len == trits.len);
    var counts: ziggit.KernelTriad = .{ .plus = 0, .ergodic = 0, .minus = 0 };
    for (trits, 0..) |t, i| {
        switch (t) {
            .plus => counts.plus += 1,
            .ergodic => counts.ergodic += 1,
            .minus => counts.minus += 1,
        }
        const n = @as(f64, @floatFromInt(i + 1));
        var h: f64 = 0;
        inline for (.{ counts.plus, counts.ergodic, counts.minus }) |c| {
            if (c > 0) {
                const p = @as(f64, @floatFromInt(c)) / n;
                h -= p * @log2(p);
            }
        }
        out[i] = h;
    }
}

/// Entropy gradient: out[i] = entropy[i+1] − entropy[i].
/// `out` length must be `entropies.len - 1` (or 0 if entropies is empty/single).
pub fn entropyGradient(entropies: []const f64, out: []f64) void {
    if (entropies.len < 2) return;
    std.debug.assert(out.len == entropies.len - 1);
    for (0..out.len) |i| out[i] = entropies[i + 1] - entropies[i];
}

// ============================================================================
// Tests
// ============================================================================

const expectApproxEq = std.testing.expectApproxEqAbs;
const expectEqual = std.testing.expectEqual;

test "shannonEntropyTrits: empty is 0" {
    try expectEqual(@as(f64, 0), shannonEntropyTrits(&[_]Trit{}));
}

test "shannonEntropyTrits: single trit is 0 (no diversity)" {
    try expectEqual(@as(f64, 0), shannonEntropyTrits(&[_]Trit{.plus}));
    try expectEqual(@as(f64, 0), shannonEntropyTrits(&[_]Trit{ .plus, .plus, .plus }));
}

test "shannonEntropyTrits: balanced binary {+,-} is 1 bit" {
    try expectApproxEq(@as(f64, 1.0), shannonEntropyTrits(&[_]Trit{ .plus, .minus }), 1e-12);
}

test "shannonEntropyTrits: balanced ternary plateaus at log2(3)" {
    try expectApproxEq(LOG2_3, shannonEntropyTrits(&[_]Trit{ .plus, .ergodic, .minus }), 1e-12);
    // 30 events balanced 10/10/10
    var trits: [30]Trit = undefined;
    inline for (0..10) |i| {
        trits[i * 3 + 0] = .plus;
        trits[i * 3 + 1] = .ergodic;
        trits[i * 3 + 2] = .minus;
    }
    try expectApproxEq(LOG2_3, shannonEntropyTrits(&trits), 1e-12);
}

test "shannonEntropyTrits: 2/3-skew {+,+,-} is below log2(3)" {
    const h = shannonEntropyTrits(&[_]Trit{ .plus, .plus, .minus });
    try std.testing.expect(h > 0 and h < LOG2_3);
    // Expected: -(2/3 log2 2/3 + 1/3 log2 1/3) ≈ 0.918295834
    try expectApproxEq(@as(f64, 0.9182958340544896), h, 1e-12);
}

test "shannonEntropyEvents: matches trit-slice version" {
    const trits = [_]Trit{ .plus, .minus, .ergodic, .plus };
    var events: [4]InteractionEvent = undefined;
    for (trits, 0..) |t, i| {
        events[i] = .{
            .change_id = [_]u8{0} ** 32,
            .trit = t,
            .timestamp = i,
        };
    }
    try expectApproxEq(
        shannonEntropyTrits(&trits),
        shannonEntropyEvents(&events),
        1e-12,
    );
}

test "runningEntropy: monotonically non-decreasing for first-class additions" {
    // After 1 plus, then 1 ergodic, then 1 minus, entropy should rise to log2(3).
    const trits = [_]Trit{ .plus, .ergodic, .minus };
    var running: [3]f64 = undefined;
    runningEntropy(&trits, &running);
    try expectEqual(@as(f64, 0.0), running[0]); // single class
    try expectApproxEq(@as(f64, 1.0), running[1], 1e-12); // 2-class balanced
    try expectApproxEq(LOG2_3, running[2], 1e-12); // 3-class balanced
}

test "runningEntropy: dropping into existing class lowers entropy" {
    // {+, -, +, +, +} — entropy peaks then decays
    const trits = [_]Trit{ .plus, .minus, .plus, .plus, .plus };
    var running: [5]f64 = undefined;
    runningEntropy(&trits, &running);
    // After +,- (50/50): 1 bit. After +,-,+: 2 vs 1, less than 1 bit.
    try expectEqual(@as(f64, 0.0), running[0]);
    try expectApproxEq(@as(f64, 1.0), running[1], 1e-12);
    try std.testing.expect(running[2] < running[1]);
    try std.testing.expect(running[3] < running[2]);
    try std.testing.expect(running[4] < running[3]);
}

test "entropyGradient: shape len-1; first run-up gives positive gradients" {
    const trits = [_]Trit{ .plus, .ergodic, .minus };
    var running: [3]f64 = undefined;
    runningEntropy(&trits, &running);
    var grad: [2]f64 = undefined;
    entropyGradient(&running, &grad);
    try std.testing.expect(grad[0] > 0);
    try std.testing.expect(grad[1] > 0);
}

test "entropyGradient: stable plateau gives near-zero gradient" {
    // 30 trits balanced — entropy should be flat at log2(3) most of the time.
    var trits: [30]Trit = undefined;
    inline for (0..10) |i| {
        trits[i * 3 + 0] = .plus;
        trits[i * 3 + 1] = .ergodic;
        trits[i * 3 + 2] = .minus;
    }
    var running: [30]f64 = undefined;
    runningEntropy(&trits, &running);
    var grad: [29]f64 = undefined;
    entropyGradient(&running, &grad);
    // The last few gradients should be tiny (already at the plateau).
    try std.testing.expect(@abs(grad[28]) < 1e-2);
}
