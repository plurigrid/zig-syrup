//! ziggit: P2P jj change propagation via Syrup wire format
//!
//! Ports lazybjj's plastic-constant coloring pipeline into zig-syrup:
//!   change_id bytes → plastic_color → hue → GF(3) trit → dispatch
//!
//! P2P: changes serialize as Syrup records and flow over OcapnConnection.
//! Each change carries its deterministic color and trit for routing.

const std = @import("std");
const splitmix = @import("splitmix_trit.zig");
const Trit = splitmix.Trit;
const syrup = @import("syrup.zig");
const Allocator = std.mem.Allocator;

/// Plastic constant rho = 1.324717957... (real root of x^3 = x + 1)
/// Analogous to golden ratio but for ternary/3D structures.
/// hue_step = 360 / rho^2 ≈ 205.14°
const PLASTIC: f64 = 1.32471795724474602596;
const PLASTIC_SQ: f64 = PLASTIC * PLASTIC;
const HUE_STEP: f64 = 360.0 / PLASTIC_SQ;

pub const ChangeColor = struct {
    hue: f64,
    r: u8,
    g: u8,
    b: u8,
    trit: Trit,
};

pub const ChangeRecord = struct {
    change_id: [32]u8,
    color: ChangeColor,
    description: []const u8,
    parent_ids: []const [32]u8,
    timestamp: i64,
};

/// Derive a plastic-constant hue from an index and seed.
/// Mirrors lazybjj's plastic_color(n, seed, lightness).
pub fn plasticHue(n: u64, seed: u64) f64 {
    const offset = @as(f64, @floatFromInt(seed % 360));
    const step = @as(f64, @floatFromInt(n)) * HUE_STEP;
    return @mod(offset + step, 360.0);
}

/// Map a 32-byte change_id to a sequential index via SplitMix64 reduction.
pub fn changeIndex(change_id: [32]u8) u64 {
    var h: u64 = 0;
    for (0..4) |i| {
        const chunk = std.mem.readInt(u64, change_id[i * 8 ..][0..8], .little);
        h ^= chunk;
    }
    h ^= h >> 30;
    h *%= 0xbf58476d1ce4e5b9;
    h ^= h >> 27;
    h *%= 0x94d049bb133111eb;
    h ^= h >> 31;
    return h;
}

/// HSL hue to RGB at fixed saturation=0.7, lightness=0.55
fn hslToRgb(hue: f64) [3]u8 {
    const s: f64 = 0.7;
    const l: f64 = 0.55;
    const c = (1.0 - @abs(2.0 * l - 1.0)) * s;
    const h_prime = hue / 60.0;
    const x = c * (1.0 - @abs(@mod(h_prime, 2.0) - 1.0));
    const m = l - c / 2.0;

    var r1: f64 = 0;
    var g1: f64 = 0;
    var b1: f64 = 0;

    if (h_prime < 1) {
        r1 = c;
        g1 = x;
    } else if (h_prime < 2) {
        r1 = x;
        g1 = c;
    } else if (h_prime < 3) {
        g1 = c;
        b1 = x;
    } else if (h_prime < 4) {
        g1 = x;
        b1 = c;
    } else if (h_prime < 5) {
        r1 = x;
        b1 = c;
    } else {
        r1 = c;
        b1 = x;
    }

    return .{
        @intFromFloat(@round((r1 + m) * 255.0)),
        @intFromFloat(@round((g1 + m) * 255.0)),
        @intFromFloat(@round((b1 + m) * 255.0)),
    };
}

/// Map hue to GF(3) trit: 3 sectors of 120 degrees each.
///   [0, 120)   → plus  (+1, Generator)
///   [120, 240) → ergodic (0, Coordinator)
///   [240, 360) → minus (-1, Validator)
pub fn tritFromHue(hue: f64) Trit {
    const h = @mod(hue, 360.0);
    if (h < 120.0) return .plus;
    if (h < 240.0) return .ergodic;
    return .minus;
}

/// Full pipeline: change_id → ChangeColor
pub fn colorFromChangeId(change_id: [32]u8, seed: u64) ChangeColor {
    const idx = changeIndex(change_id);
    const hue = plasticHue(idx, seed);
    const rgb = hslToRgb(hue);
    return .{
        .hue = hue,
        .r = rgb[0],
        .g = rgb[1],
        .b = rgb[2],
        .trit = tritFromHue(hue),
    };
}

/// Encode a ChangeRecord as Syrup bytes for P2P transmission.
/// Format: <'ziggit-change id:<bytes> trit:<int> ts:<int> desc:<string>>
pub fn encodeChange(alloc: Allocator, rec: ChangeRecord) ![]u8 {
    var buf = std.ArrayList(u8).init(alloc);
    errdefer buf.deinit();
    const w = buf.writer();

    try w.writeAll("<'ziggit-change ");
    // change_id as hex
    try w.print("{d}:", .{rec.change_id.len});
    try w.writeAll(&rec.change_id);
    try w.writeByte(' ');
    // trit as integer
    try w.print("{d}", .{@as(i8, @intFromEnum(rec.color.trit))});
    try w.writeByte(' ');
    // timestamp
    try w.print("{d}", .{rec.timestamp});
    try w.writeByte(' ');
    // description length-prefixed
    try w.print("{d}\"", .{rec.description.len});
    try w.writeAll(rec.description);
    try w.writeByte('>');

    return buf.toOwnedSlice();
}

// ============================================================================
// GF(3) trit reductions  (Phase-1 closeout)
// ============================================================================

/// Render a trit as a single human-readable glyph.
pub fn tritSymbol(t: Trit) []const u8 {
    return switch (t) {
        .minus => "−",
        .ergodic => "○",
        .plus => "+",
    };
}

/// GF(3) sum: fold Trit.add (which is sum mod 3 in {-1,0,+1}) over a slice.
/// Empty slice = .ergodic (the identity).
pub fn tritSum(trits: []const Trit) Trit {
    var acc: Trit = .ergodic;
    for (trits) |t| acc = acc.add(t);
    return acc;
}

/// Conservation predicate: a trit set is conserved iff its GF(3) sum is 0.
pub fn tritsConserved(trits: []const Trit) bool {
    return tritSum(trits) == .ergodic;
}

// ============================================================================
// KernelTriad and stack conservation  (Phase 6)
// ============================================================================

/// Counts of each trit class. Conservation here is sum-of-counts mod 3 == 0
/// (matching kernel_triad.jl in Gay.jl); orthogonal to GF(3) sum-of-values.
pub const KernelTriad = struct {
    plus: u32,
    ergodic: u32,
    minus: u32,

    pub fn fromTrits(trits: []const Trit) KernelTriad {
        var kt: KernelTriad = .{ .plus = 0, .ergodic = 0, .minus = 0 };
        for (trits) |t| switch (t) {
            .plus => kt.plus += 1,
            .ergodic => kt.ergodic += 1,
            .minus => kt.minus += 1,
        };
        return kt;
    }

    /// Total count divisible by 3 — coarse balance, matches Gay.jl.
    pub fn isConserved(kt: KernelTriad) bool {
        return (kt.plus +% kt.ergodic +% kt.minus) % 3 == 0;
    }

    /// Net GF(3) balance: (plus − minus) reduced mod 3 back to a Trit.
    pub fn balance(kt: KernelTriad) Trit {
        const diff = @as(i64, kt.plus) - @as(i64, kt.minus);
        const r = @mod(diff, 3); // in {0,1,2}
        return switch (r) {
            0 => .ergodic,
            1 => .plus,
            2 => .minus,
            else => unreachable,
        };
    }
};

/// Stack conservation: parents + child trits must GF(3)-sum to zero.
/// `seed` parameterises the plastic coloring (zubuyul = 1069).
pub fn checkStackConservation(
    parents: []const [32]u8,
    child: [32]u8,
    seed: u64,
) bool {
    var sum: Trit = colorFromChangeId(child, seed).trit;
    for (parents) |p| sum = sum.add(colorFromChangeId(p, seed).trit);
    return sum == .ergodic;
}

// ============================================================================
// CI dispatch  (Phase 6)
// ============================================================================

/// Action for a change based on its trit + stack conservation.
pub const CIAction = enum {
    build, // +1: generative
    run_tests, // 0: coordinating
    validate, // -1: validating
    review_required, // conservation violated
};

/// Pure dispatch from a (child, parents, seed). If parents are non-empty and
/// the GF(3) stack does not conserve, fall back to `review_required`.
pub fn dispatchCI(
    child: [32]u8,
    parents: []const [32]u8,
    seed: u64,
) CIAction {
    if (parents.len > 0 and !checkStackConservation(parents, child, seed)) {
        return .review_required;
    }
    return switch (colorFromChangeId(child, seed).trit) {
        .plus => .build,
        .ergodic => .run_tests,
        .minus => .validate,
    };
}

// ============================================================================
// Tests
// ============================================================================

test "plastic hue is deterministic" {
    const h1 = plasticHue(42, 0);
    const h2 = plasticHue(42, 0);
    try std.testing.expectEqual(h1, h2);
}

test "different indices produce different hues" {
    const h1 = plasticHue(0, 0);
    const h2 = plasticHue(1, 0);
    try std.testing.expect(h1 != h2);
}

test "trit sectors cover 360 degrees" {
    try std.testing.expectEqual(Trit.plus, tritFromHue(0.0));
    try std.testing.expectEqual(Trit.plus, tritFromHue(119.9));
    try std.testing.expectEqual(Trit.ergodic, tritFromHue(120.0));
    try std.testing.expectEqual(Trit.ergodic, tritFromHue(239.9));
    try std.testing.expectEqual(Trit.minus, tritFromHue(240.0));
    try std.testing.expectEqual(Trit.minus, tritFromHue(359.9));
}

test "colorFromChangeId round-trip determinism" {
    var id: [32]u8 = undefined;
    @memset(&id, 0xAB);
    const c1 = colorFromChangeId(id, 69);
    const c2 = colorFromChangeId(id, 69);
    try std.testing.expectEqual(c1.trit, c2.trit);
    try std.testing.expectEqual(c1.r, c2.r);
    try std.testing.expectEqual(c1.hue, c2.hue);
}

test "zero change_id gets a valid color" {
    var id: [32]u8 = undefined;
    @memset(&id, 0);
    const c = colorFromChangeId(id, 0);
    try std.testing.expect(c.hue >= 0.0 and c.hue < 360.0);
}

// ---------------------------------------------------------------------------
// Phase 1 closeout: tritSum / tritsConserved / tritSymbol
// ---------------------------------------------------------------------------

test "tritSum: empty is ergodic (identity)" {
    try std.testing.expectEqual(Trit.ergodic, tritSum(&[_]Trit{}));
}

test "tritSum: +1 + -1 = 0" {
    try std.testing.expectEqual(Trit.ergodic, tritSum(&[_]Trit{ .plus, .minus }));
}

test "tritSum: three +1 wraps to 0 in GF(3)" {
    try std.testing.expectEqual(
        Trit.ergodic,
        tritSum(&[_]Trit{ .plus, .plus, .plus }),
    );
}

test "tritsConserved: balanced triad" {
    try std.testing.expect(tritsConserved(&[_]Trit{ .plus, .ergodic, .minus }));
}

test "tritsConserved: single plus is not conserved" {
    try std.testing.expect(!tritsConserved(&[_]Trit{.plus}));
}

test "tritSymbol: glyphs" {
    try std.testing.expectEqualStrings("+", tritSymbol(.plus));
    try std.testing.expectEqualStrings("○", tritSymbol(.ergodic));
    try std.testing.expectEqualStrings("−", tritSymbol(.minus));
}

// ---------------------------------------------------------------------------
// Phase 6: KernelTriad
// ---------------------------------------------------------------------------

test "KernelTriad.fromTrits counts each class" {
    const kt = KernelTriad.fromTrits(&[_]Trit{ .plus, .plus, .ergodic, .minus });
    try std.testing.expectEqual(@as(u32, 2), kt.plus);
    try std.testing.expectEqual(@as(u32, 1), kt.ergodic);
    try std.testing.expectEqual(@as(u32, 1), kt.minus);
}

test "KernelTriad.isConserved: total count mod 3" {
    // 4 elements: 4 mod 3 == 1, not conserved
    const kt = KernelTriad.fromTrits(&[_]Trit{ .plus, .plus, .ergodic, .minus });
    try std.testing.expect(!kt.isConserved());
    // 3 elements: conserved
    const kt2 = KernelTriad.fromTrits(&[_]Trit{ .plus, .ergodic, .minus });
    try std.testing.expect(kt2.isConserved());
}

test "KernelTriad.balance: net GF(3) over (plus − minus)" {
    const kt = KernelTriad.fromTrits(&[_]Trit{ .plus, .plus, .minus });
    // (2 − 1) mod 3 = 1 → plus
    try std.testing.expectEqual(Trit.plus, kt.balance());
    const kt2 = KernelTriad.fromTrits(&[_]Trit{ .plus, .minus });
    try std.testing.expectEqual(Trit.ergodic, kt2.balance());
}

// ---------------------------------------------------------------------------
// Phase 6: stack conservation + CI dispatch
// ---------------------------------------------------------------------------

test "checkStackConservation: child alone is ergodic-only-when-color-is-ergodic" {
    var c: [32]u8 = undefined;
    @memset(&c, 0xAB);
    // Find a seed that yields child trit == ergodic, then with no parents
    // the stack sum equals the child trit, so conservation iff trit == ergodic.
    var saw_ergodic = false;
    var saw_other = false;
    for (0..256) |s| {
        const seed: u64 = s;
        const ok = checkStackConservation(&[_][32]u8{}, c, seed);
        const t = colorFromChangeId(c, seed).trit;
        try std.testing.expectEqual(t == .ergodic, ok);
        if (t == .ergodic) saw_ergodic = true else saw_other = true;
    }
    try std.testing.expect(saw_ergodic and saw_other);
}

test "checkStackConservation: synthetic balanced stack" {
    // Construct three change_ids whose trits we discover, then assemble
    // (parents, child) so that GF(3) sum is zero.
    var ids: [3][32]u8 = undefined;
    var trits: [3]Trit = undefined;
    for (0..3) |i| {
        @memset(&ids[i], @intCast(i + 1));
        trits[i] = colorFromChangeId(ids[i], 1069).trit;
    }
    const sum_all = tritSum(&trits);
    const expected = sum_all == .ergodic;
    const got = checkStackConservation(ids[0..2], ids[2], 1069);
    try std.testing.expectEqual(expected, got);
}

test "dispatchCI: parentless plus → build, ergodic → run_tests, minus → validate" {
    var id: [32]u8 = undefined;
    for (0..256) |s| {
        @memset(&id, @intCast(s));
        const seed: u64 = s;
        const t = colorFromChangeId(id, seed).trit;
        const action = dispatchCI(id, &[_][32]u8{}, seed);
        const expected: CIAction = switch (t) {
            .plus => .build,
            .ergodic => .run_tests,
            .minus => .validate,
        };
        try std.testing.expectEqual(expected, action);
    }
}

// Pull in zigbjj_{entropy, criticality, jj, narrative, parity} tests so
// `zig build test-ziggit` covers Phases 3, 4, 5, 7 + the parity harness.
test {
    _ = @import("zigbjj_entropy.zig");
    _ = @import("zigbjj_criticality.zig");
    _ = @import("zigbjj_jj.zig");
    _ = @import("zigbjj_narrative.zig");
    _ = @import("zigbjj_parity.zig");
}

test "dispatchCI: violated conservation → review_required" {
    var p: [32]u8 = undefined;
    var c: [32]u8 = undefined;
    @memset(&p, 0x11);
    @memset(&c, 0x22);
    // Try seeds until we find one where sum is non-ergodic.
    for (0..256) |s| {
        const seed: u64 = s;
        const sum = colorFromChangeId(p, seed).trit.add(colorFromChangeId(c, seed).trit);
        if (sum != .ergodic) {
            try std.testing.expectEqual(
                CIAction.review_required,
                dispatchCI(c, &[_][32]u8{p}, seed),
            );
            return;
        }
    }
    return error.NoNonConservedSeedFound;
}
