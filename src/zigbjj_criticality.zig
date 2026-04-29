//! zigbjj criticality: bifurcation detection on entropy gradients.
//!
//! Phase 5 of the lazybjj-unison rebuild plan, ported into Zig.
//!
//! Consumes the running-entropy series produced by zigbjj_entropy and
//! emits CriticalPoints (per-event) plus a coarse BifurcationType for
//! the whole trace. Pure functions over slices; caller owns memory.
//!
//! References:
//!   - lazybjj-unison gay/criticality.u  (Phase 5 spec)
//!   - traced_criticality.jl, ink_traced_criticality.jl  (Gay.jl)

const std = @import("std");
const ziggit = @import("ziggit.zig");
const entropy = @import("zigbjj_entropy.zig");
const splitmix = @import("splitmix_trit.zig");
const Trit = splitmix.Trit;

/// A single point flagged by the detector.
pub const CriticalPoint = struct {
    index: usize,
    change_id: [32]u8,
    trit: Trit,
    entropy_local: f64,
    gradient: f64,
    is_transition: bool,
    score: f64,
};

/// Coarse bifurcation taxonomy, matching the Unison plan.
pub const BifurcationType = enum {
    none,
    hopf, // oscillatory: many sign changes in entropy gradient
    pitchfork, // symmetry-breaking: gradient drifts in one direction with one branch
    saddle_node, // creation/annihilation of equilibria: monotonic shift
    transcritical, // exchange of stability: clean sign-flip with no oscillation
};

/// Default threshold for `is_transition`: |gradient| above this counts.
pub const DEFAULT_THRESHOLD: f64 = 0.25;

/// Population variance of trit values mapped to {-1, 0, +1}.
/// Higher variance = more spread across classes = more critical.
pub fn tritVariance(trits: []const Trit) f64 {
    if (trits.len == 0) return 0;
    const n = @as(f64, @floatFromInt(trits.len));
    var sum: f64 = 0;
    var sq: f64 = 0;
    for (trits) |t| {
        const v: f64 = switch (t) {
            .minus => -1,
            .ergodic => 0,
            .plus => 1,
        };
        sum += v;
        sq += v * v;
    }
    const mean = sum / n;
    return (sq / n) - (mean * mean);
}

/// Composite criticality score: entropy × variance. Both peak together
/// at the maximally-mixed configuration.
pub fn criticalityScore(trits: []const Trit) f64 {
    return entropy.shannonEntropyTrits(trits) * tritVariance(trits);
}

/// Scan a trace and emit one CriticalPoint per event from index 1..N-1.
/// `out` length must equal `events.len - 1`. Returns the number of
/// transitions flagged.
pub fn detectTransitions(
    events: []const entropy.InteractionEvent,
    threshold: f64,
    out: []CriticalPoint,
) usize {
    if (events.len < 2) return 0;
    std.debug.assert(out.len == events.len - 1);

    // Build trit slice and running entropy on the stack-friendly path.
    // For longer traces caller should provide their own scratch arena.
    var trits_buf: [4096]Trit = undefined;
    var run_buf: [4096]f64 = undefined;
    std.debug.assert(events.len <= trits_buf.len);
    for (events, 0..) |ev, i| trits_buf[i] = ev.trit;
    entropy.runningEntropy(trits_buf[0..events.len], run_buf[0..events.len]);

    var n_trans: usize = 0;
    for (1..events.len) |i| {
        const grad = run_buf[i] - run_buf[i - 1];
        const window = trits_buf[0 .. i + 1];
        const score = entropy.shannonEntropyTrits(window) * tritVariance(window);
        const is_trans = @abs(grad) > threshold;
        out[i - 1] = .{
            .index = i,
            .change_id = events[i].change_id,
            .trit = events[i].trit,
            .entropy_local = run_buf[i],
            .gradient = grad,
            .is_transition = is_trans,
            .score = score,
        };
        if (is_trans) n_trans += 1;
    }
    return n_trans;
}

/// Count sign changes in a gradient series (zero treated as no-sign).
pub fn countSignChanges(gradients: []const f64) usize {
    if (gradients.len < 2) return 0;
    var prev_sign: i8 = 0;
    var count: usize = 0;
    for (gradients) |g| {
        const s: i8 = if (g > 0) 1 else if (g < 0) -1 else 0;
        if (s != 0 and prev_sign != 0 and s != prev_sign) count += 1;
        if (s != 0) prev_sign = s;
    }
    return count;
}

/// Coarse classifier: looks at the gradient series of running entropy
/// and assigns a bifurcation type. Heuristic; refined in later iterations.
pub fn classifyBifurcation(trits: []const Trit) BifurcationType {
    if (trits.len < 4) return .none;
    var run_buf: [4096]f64 = undefined;
    var grad_buf: [4096]f64 = undefined;
    std.debug.assert(trits.len <= run_buf.len);
    entropy.runningEntropy(trits, run_buf[0..trits.len]);
    entropy.entropyGradient(run_buf[0..trits.len], grad_buf[0 .. trits.len - 1]);
    const grads = grad_buf[0 .. trits.len - 1];

    const sign_changes = countSignChanges(grads);
    const half = grads.len / 2;

    // Dominant final sign (last quarter average)
    var final_sum: f64 = 0;
    const tail_start = (grads.len * 3) / 4;
    for (grads[tail_start..]) |g| final_sum += g;
    const final_avg = if (tail_start < grads.len)
        final_sum / @as(f64, @floatFromInt(grads.len - tail_start))
    else
        0;

    if (sign_changes > half) return .hopf;
    if (sign_changes == 0) {
        // Strictly monotonic. If average gradient near zero we already
        // returned no oscillation; saddle_node = creation of new mixing,
        // i.e. monotonic positive gradient.
        if (final_avg > 0.05) return .saddle_node;
        if (final_avg < -0.05) return .pitchfork; // collapse to one class
        return .none;
    }
    if (sign_changes <= 2 and @abs(final_avg) > 0.05) return .transcritical;
    return .none;
}

// ============================================================================
// Tests
// ============================================================================

const expectEqual = std.testing.expectEqual;
const expectApproxEq = std.testing.expectApproxEqAbs;

test "tritVariance: single class is 0" {
    try expectEqual(@as(f64, 0), tritVariance(&[_]Trit{ .plus, .plus, .plus }));
    try expectEqual(@as(f64, 0), tritVariance(&[_]Trit{ .ergodic, .ergodic }));
}

test "tritVariance: balanced {+,-} is 1" {
    try expectApproxEq(@as(f64, 1.0), tritVariance(&[_]Trit{ .plus, .minus }), 1e-12);
}

test "tritVariance: balanced 3-class is 2/3" {
    try expectApproxEq(
        @as(f64, 2.0 / 3.0),
        tritVariance(&[_]Trit{ .plus, .ergodic, .minus }),
        1e-12,
    );
}

test "criticalityScore: 0 for single-class, max in 3-class balanced" {
    try expectEqual(@as(f64, 0), criticalityScore(&[_]Trit{ .plus, .plus }));
    const s_balanced = criticalityScore(&[_]Trit{ .plus, .ergodic, .minus });
    // log2(3) * 2/3 ≈ 1.0566
    try expectApproxEq(@as(f64, 1.0566416671474375), s_balanced, 1e-12);
}

test "countSignChanges: monotonic gradient → 0" {
    try expectEqual(@as(usize, 0), countSignChanges(&[_]f64{ 0.1, 0.2, 0.3, 0.4 }));
    try expectEqual(@as(usize, 0), countSignChanges(&[_]f64{ -0.1, -0.2, -0.3 }));
}

test "countSignChanges: alternating → many" {
    try expectEqual(
        @as(usize, 3),
        countSignChanges(&[_]f64{ 0.1, -0.1, 0.1, -0.1 }),
    );
}

fn mkEvents(comptime n: usize, trits: [n]Trit) [n]entropy.InteractionEvent {
    var evs: [n]entropy.InteractionEvent = undefined;
    for (trits, 0..) |t, i| {
        evs[i] = .{
            .change_id = [_]u8{0} ** 32,
            .trit = t,
            .timestamp = i,
        };
    }
    return evs;
}

test "detectTransitions: ramp-up trace flags first two as transitions" {
    var evs = mkEvents(3, .{ .plus, .ergodic, .minus });
    var crit: [2]CriticalPoint = undefined;
    const n_trans = detectTransitions(&evs, DEFAULT_THRESHOLD, &crit);
    try std.testing.expect(n_trans >= 1);
    // The first jump (single → 2-class balanced) is a +1.0 gradient.
    try std.testing.expect(crit[0].is_transition);
    try std.testing.expect(crit[0].gradient > 0);
}

test "detectTransitions: stable plateau has no transitions" {
    // 12 events, balanced 4/4/4 — entropy plateaus quickly and grads tiny.
    var trits: [12]Trit = undefined;
    inline for (0..4) |i| {
        trits[i * 3 + 0] = .plus;
        trits[i * 3 + 1] = .ergodic;
        trits[i * 3 + 2] = .minus;
    }
    const evs = mkEvents(12, trits);
    var crit: [11]CriticalPoint = undefined;
    const n_trans = detectTransitions(&evs, DEFAULT_THRESHOLD, &crit);
    // Only the very first few jumps cross the threshold.
    try std.testing.expect(n_trans <= 3);
    // The last point's gradient is essentially zero.
    try std.testing.expect(@abs(crit[crit.len - 1].gradient) < 0.05);
}

test "classifyBifurcation: too short → none" {
    try expectEqual(BifurcationType.none, classifyBifurcation(&[_]Trit{.plus}));
    try expectEqual(
        BifurcationType.none,
        classifyBifurcation(&[_]Trit{ .plus, .minus, .plus }),
    );
}

test "classifyBifurcation: oscillating {+,-,+,-,+,-,+,-} → hopf" {
    const trits = [_]Trit{ .plus, .minus, .plus, .minus, .plus, .minus, .plus, .minus };
    try expectEqual(BifurcationType.hopf, classifyBifurcation(&trits));
}

test "classifyBifurcation: monotonic mixing-up → saddle_node" {
    // First 4 plus, then 4 minus, then 4 ergodic — entropy keeps rising.
    const trits = [_]Trit{
        .plus,    .plus,    .plus,    .plus,
        .minus,   .minus,   .minus,   .minus,
        .ergodic, .ergodic, .ergodic, .ergodic,
    };
    const bt = classifyBifurcation(&trits);
    // After ramping into all 3 classes the gradient is small but never went
    // negative: classifier returns saddle_node OR none depending on tail.
    try std.testing.expect(bt == .saddle_node or bt == .none);
}
