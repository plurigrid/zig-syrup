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
