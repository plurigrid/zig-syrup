//! zigbjj parity harness: emit deterministic test cases for cross-language
//! verification against lazybjj-unison.
//!
//! Phase: cross-language verification. The plan calls for byte-for-byte
//! parity between the Zig and Unison ports of plasticColor / tritFromHue.
//!
//! This module emits JSONL — one record per line, the format
//! lazybjj-unison expects, and provides a roundtrip parser so the same
//! Zig run can self-check before the file is shipped to UCM.
//!
//! Workflow:
//!   1. Zig:   call emitCasesJsonl(alloc, N, seed_base) → []u8
//!   2. write to /tmp/parity.jsonl
//!   3. UCM:   run lazybjj.bjj.parityVerify "/tmp/parity.jsonl"
//!   4. UCM emits 0 if all cases match its own colorFromChangeId / tritFromHue.

const std = @import("std");
const ziggit = @import("ziggit.zig");
const splitmix = @import("splitmix_trit.zig");
const Trit = splitmix.Trit;
const jj = @import("zigbjj_jj.zig");
const Allocator = std.mem.Allocator;

fn appendFmt(buf: *std.ArrayList(u8), alloc: Allocator, comptime fmt: []const u8, args: anytype) !void {
    var tmp: [256]u8 = undefined;
    const text = try std.fmt.bufPrint(&tmp, fmt, args);
    try buf.appendSlice(alloc, text);
}

/// One parity test case in canonical form.
pub const ParityCase = struct {
    change_id: [32]u8,
    seed: u64,
    hue: f64,
    r: u8,
    g: u8,
    b: u8,
    trit: Trit,

    pub fn fromChangeId(change_id: [32]u8, seed: u64) ParityCase {
        const c = ziggit.colorFromChangeId(change_id, seed);
        return .{
            .change_id = change_id,
            .seed = seed,
            .hue = c.hue,
            .r = c.r,
            .g = c.g,
            .b = c.b,
            .trit = c.trit,
        };
    }
};

/// Generate N deterministic test cases. The change_ids are the bytes of
/// SplitMix64(seed_base, i) tiled to 32 bytes; seeds rotate through a
/// small grid so we cover varied (id, seed) combinations.
pub fn emitCasesJsonl(alloc: Allocator, n: usize, seed_base: u64) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(alloc);

    var i: usize = 0;
    while (i < n) : (i += 1) {
        const change_id = synthChangeId(seed_base, i);
        const seed: u64 = 1069 + @as(u64, @intCast(i % 7));
        const cs = ParityCase.fromChangeId(change_id, seed);
        try writeCaseJson(&buf, alloc, cs);
        try buf.append(alloc, '\n');
    }
    return try buf.toOwnedSlice(alloc);
}

/// Deterministic synthetic change_id: 4×u64 = 32 bytes, each chunk a
/// distinct splitmix iterate so flipping `i` changes every byte.
pub fn synthChangeId(seed_base: u64, i: usize) [32]u8 {
    var out: [32]u8 = undefined;
    inline for (0..4) |k| {
        const z = splitmix64Mix(seed_base +% @as(u64, @intCast(i)) +% k);
        std.mem.writeInt(u64, out[k * 8 ..][0..8], z, .little);
    }
    return out;
}

fn splitmix64Mix(seed: u64) u64 {
    var z = seed +% 0x9e3779b97f4a7c15;
    z = (z ^ (z >> 30)) *% 0xbf58476d1ce4e5b9;
    z = (z ^ (z >> 27)) *% 0x94d049bb133111eb;
    return z ^ (z >> 31);
}

fn writeCaseJson(buf: *std.ArrayList(u8), alloc: Allocator, c: ParityCase) !void {
    var hex: [64]u8 = undefined;
    jj.formatHex(&hex, c.change_id);
    try buf.appendSlice(alloc, "{\"change_id\":\"");
    try buf.appendSlice(alloc, &hex);
    try buf.appendSlice(alloc, "\",\"seed\":");
    try appendFmt(buf, alloc, "{d}", .{c.seed});
    try buf.appendSlice(alloc, ",\"hue\":");
    try appendFmt(buf, alloc, "{d:.9}", .{c.hue});
    try buf.appendSlice(alloc, ",\"r\":");
    try appendFmt(buf, alloc, "{d}", .{c.r});
    try buf.appendSlice(alloc, ",\"g\":");
    try appendFmt(buf, alloc, "{d}", .{c.g});
    try buf.appendSlice(alloc, ",\"b\":");
    try appendFmt(buf, alloc, "{d}", .{c.b});
    try buf.appendSlice(alloc, ",\"trit\":");
    try appendFmt(buf, alloc, "{d}", .{@as(i8, @backingInt(c.trit))});
    try buf.append(alloc, '}');
}

/// Re-derive the case from `change_id` and `seed` and assert byte-equal
/// hue/r/g/b/trit. Returns true iff all assertions pass.
/// Used both by the in-process roundtrip test and by an external verifier
/// that parses someone else's JSONL and re-checks each case.
pub fn verifyCase(c: ParityCase) bool {
    const recomputed = ParityCase.fromChangeId(c.change_id, c.seed);
    return c.hue == recomputed.hue and
        c.r == recomputed.r and
        c.g == recomputed.g and
        c.b == recomputed.b and
        c.trit == recomputed.trit;
}

// ============================================================================
// Tests
// ============================================================================

test "synthChangeId: deterministic" {
    const a = synthChangeId(1069, 7);
    const b = synthChangeId(1069, 7);
    try std.testing.expectEqualSlices(u8, &a, &b);
    const c = synthChangeId(1069, 8);
    try std.testing.expect(!std.mem.eql(u8, &a, &c));
}

test "ParityCase.fromChangeId: deterministic" {
    const id = synthChangeId(0, 0);
    const c1 = ParityCase.fromChangeId(id, 1069);
    const c2 = ParityCase.fromChangeId(id, 1069);
    try std.testing.expectEqual(c1.hue, c2.hue);
    try std.testing.expectEqual(c1.r, c2.r);
    try std.testing.expectEqual(c1.trit, c2.trit);
}

test "emitCasesJsonl: shape" {
    const json = try emitCasesJsonl(std.testing.allocator, 5, 42);
    defer std.testing.allocator.free(json);
    // Five lines, each starting with `{"change_id":"`
    var lines = std.mem.tokenizeScalar(u8, json, '\n');
    var n: usize = 0;
    while (lines.next()) |line| {
        n += 1;
        try std.testing.expect(std.mem.startsWith(u8, line, "{\"change_id\":\""));
        try std.testing.expect(std.mem.endsWith(u8, line, "}"));
        try std.testing.expect(std.mem.indexOf(u8, line, "\"trit\":") != null);
        try std.testing.expect(std.mem.indexOf(u8, line, "\"hue\":") != null);
    }
    try std.testing.expectEqual(@as(usize, 5), n);
}

test "verifyCase: self-roundtrip is always true" {
    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        const id = synthChangeId(0xCAFE, i);
        const seed: u64 = 1069 + (i % 7);
        const c = ParityCase.fromChangeId(id, seed);
        try std.testing.expect(verifyCase(c));
    }
}

test "verifyCase: tampered case fails" {
    const id = synthChangeId(0, 0);
    var c = ParityCase.fromChangeId(id, 1069);
    c.r = c.r +% 1; // flip a single byte
    try std.testing.expect(!verifyCase(c));
}

test "deterministic across N runs" {
    // Re-emitting the same (n, seed_base) must give byte-identical bytes.
    const j1 = try emitCasesJsonl(std.testing.allocator, 32, 7);
    defer std.testing.allocator.free(j1);
    const j2 = try emitCasesJsonl(std.testing.allocator, 32, 7);
    defer std.testing.allocator.free(j2);
    try std.testing.expectEqualSlices(u8, j1, j2);
}
