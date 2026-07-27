//! Fuzz harnesses for the Syrup parser and encoder.
//!
//! Run:  zig build fuzz-syrup --fuzz
//!
//! API note (zig 0.17-dev): `std.testing.fuzz` calls back with a
//! `*std.testing.Smith` value generator, NOT a raw `[]const u8`. Draw bytes
//! with `smith.slice(buf)` (returns the length written). See
//! `lib/std/zig/parser_fuzz.zig` for the canonical pattern.
//!
//! Allocator policy: decode builds a Value tree, so we wrap
//! `std.testing.allocator` in an arena — `arena.deinit()` frees the whole tree
//! and the testing allocator's end-of-test check then proves nothing leaked.
//! One target additionally drives a `FailingAllocator` to exercise the OOM /
//! errdefer-cleanup paths (the old `page_allocator`-in-arena hid both).
//!
//! Targets:
//!   1. parser does not crash / leak on arbitrary input
//!   2. parser survives arbitrary input under injected OOM (no leak, no UB)
//!   3. integer  encode -> decode round-trip
//!   4. string   encode -> decode round-trip
//!   5. bytes    encode -> decode round-trip
//!   6. decode -> encode -> decode -> encode is byte-idempotent (canonical)
//!   7. encodedSize() matches the real encoded length
//! Plus a deterministic regression test for the MAX_DEPTH stack-overflow guard.

const std = @import("std");
const syrup = @import("syrup");

/// Shared draw buffer size. Larger than Parser.MAX_DEPTH so the depth guard is
/// reachable, but bounded so a target run stays cheap.
const DRAW_CAP: usize = 8 * 1024;

test "fuzz: syrup parser does not crash on arbitrary input" {
    try std.testing.fuzz({}, struct {
        fn testOne(_: void, smith: *std.testing.Smith) anyerror!void {
            var buf: [DRAW_CAP]u8 = undefined;
            const len = smith.slice(&buf);
            const input = buf[0..len];

            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();

            // Must not crash, panic, UB, or leak on any input. A typed
            // ParseError (incl. error.MaxDepth on deep nesting) is fine.
            _ = syrup.decode(input, arena.allocator()) catch return;
        }
    }.testOne, .{});
}

test "fuzz: syrup parser survives injected OOM without leak or UB" {
    try std.testing.fuzz({}, struct {
        fn testOne(_: void, smith: *std.testing.Smith) anyerror!void {
            var buf: [DRAW_CAP]u8 = undefined;
            const len = smith.slice(&buf);
            const input = buf[0..len];
            if (len == 0) return;

            // Fail the Nth allocation, N derived from the drawn bytes.
            // Exercises every errdefer path in the container parsers.
            const n = @as(usize, buf[0]) | (@as(usize, if (len > 1) buf[1] else 0) << 8);

            var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = n });
            var arena = std.heap.ArenaAllocator.init(failing.allocator());
            defer arena.deinit();

            _ = syrup.decode(input, arena.allocator()) catch return;
        }
    }.testOne, .{});
}

test "fuzz: integer encode-decode round-trip" {
    try std.testing.fuzz({}, struct {
        fn testOne(_: void, smith: *std.testing.Smith) anyerror!void {
            var buf: [8]u8 = undefined;
            const len = smith.slice(&buf);
            if (len < 8) return;
            const val = std.mem.readInt(i64, buf[0..8], .little);

            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            const a = arena.allocator();

            const sval = syrup.Value{ .integer = val };
            const encoded = try sval.encodeAlloc(a);
            const decoded = try syrup.decode(encoded, a);

            if (decoded != .integer) return error.TypeMismatch;
            if (decoded.integer != val) return error.ValueMismatch;
        }
    }.testOne, .{});
}

test "fuzz: string encode-decode round-trip" {
    try std.testing.fuzz({}, struct {
        fn testOne(_: void, smith: *std.testing.Smith) anyerror!void {
            var buf: [4096]u8 = undefined;
            const len = smith.slice(&buf);
            if (len == 0) return;
            const input = buf[0..len];

            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            const a = arena.allocator();

            const sval = syrup.Value{ .string = input };
            const encoded = try sval.encodeAlloc(a);
            const decoded = try syrup.decode(encoded, a);

            if (decoded != .string) return error.TypeMismatch;
            if (!std.mem.eql(u8, decoded.string, input)) return error.ValueMismatch;
        }
    }.testOne, .{});
}

test "fuzz: bytes encode-decode round-trip" {
    try std.testing.fuzz({}, struct {
        fn testOne(_: void, smith: *std.testing.Smith) anyerror!void {
            var buf: [4096]u8 = undefined;
            const len = smith.slice(&buf);
            if (len == 0) return;
            const input = buf[0..len];

            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            const a = arena.allocator();

            const sval = syrup.Value{ .bytes = input };
            const encoded = try sval.encodeAlloc(a);
            const decoded = try syrup.decode(encoded, a);

            if (decoded != .bytes) return error.TypeMismatch;
            if (!std.mem.eql(u8, decoded.bytes, input)) return error.ValueMismatch;
        }
    }.testOne, .{});
}

test "fuzz: canonical encoding is idempotent" {
    try std.testing.fuzz({}, struct {
        fn testOne(_: void, smith: *std.testing.Smith) anyerror!void {
            var buf: [4096]u8 = undefined;
            const len = smith.slice(&buf);
            if (len == 0) return;
            const input = buf[0..len];

            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            const a = arena.allocator();

            const val1 = syrup.decode(input, a) catch return;
            const encoded1 = val1.encodeAlloc(a) catch return;
            const val2 = syrup.decode(encoded1, a) catch return;
            const encoded2 = val2.encodeAlloc(a) catch return;

            if (!std.mem.eql(u8, encoded1, encoded2)) return error.NotIdempotent;
        }
    }.testOne, .{});
}

test "fuzz: encoded size matches actual encoding" {
    try std.testing.fuzz({}, struct {
        fn testOne(_: void, smith: *std.testing.Smith) anyerror!void {
            var buf: [8]u8 = undefined;
            const len = smith.slice(&buf);
            if (len < 8) return;
            const val = std.mem.readInt(i64, buf[0..8], .little);

            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            const a = arena.allocator();

            const sval = syrup.Value{ .integer = val };
            const predicted = sval.encodedSize();
            const actual = (try sval.encodeAlloc(a)).len;

            if (predicted != actual) return error.SizeMismatch;
        }
    }.testOne, .{});
}

// Deterministic regression: deep nesting must be a typed error, not a stack
// overflow. Found by /tmp/band/depth_probe.bb (SIGSEGV between depth 5000 and
// 10000 before the MAX_DEPTH guard was added to syrup.Parser). This test runs
// under plain `zig build test` too, so the guard can't silently regress.
test "regression: deep nesting returns error.MaxDepth, never crashes" {
    const alloc = std.testing.allocator;
    inline for (.{ .{ '[', ']' }, .{ '{', '}' }, .{ '#', '$' }, .{ '<', '>' } }) |pair| {
        const open: u8 = pair[0];
        const close: u8 = pair[1];
        const depth: usize = 10_000;
        const bytes = try alloc.alloc(u8, depth * 2);
        defer alloc.free(bytes);
        @memset(bytes[0..depth], open);
        @memset(bytes[depth..], close);

        var arena = std.heap.ArenaAllocator.init(alloc);
        defer arena.deinit();

        try std.testing.expectError(error.MaxDepth, syrup.decode(bytes, arena.allocator()));
    }
}

test "regression: non-canonical integers/lengths/bigints are rejected (wire malleability)" {
    const alloc = std.testing.allocator;

    // Each of these decoded successfully before the fix and re-encoded to a
    // DIFFERENT canonical byte string — distinct wire bytes for the same value,
    // a bytes-identity hazard for CIDs / capability nullifiers. The round-trip
    // fuzzer surfaced them; these lock the fix in deterministically.
    const non_canonical = [_][]const u8{
        "0-", // negative zero          -> canonical is "0+"
        "00+", // leading zero
        "007+", // leading zeros
        "+", // integer, no digits
        "-", // integer, no digits
        "00:", // length, leading zero
        "B1:-", // bigint negative zero (empty magnitude, '-')
        "B2:-\x00", // bigint negative zero (zero magnitude byte)
        "B2:+\x00", // bigint non-minimal magnitude (leading zero byte)
        "B01:+\x05", // bigint leading-zero length
        "B1:x\x05", // bigint invalid sign byte
    };
    for (non_canonical) |bytes| {
        var arena = std.heap.ArenaAllocator.init(alloc);
        defer arena.deinit();
        try std.testing.expectError(error.NonCanonical, syrup.decode(bytes, arena.allocator()));
    }

    // Canonical forms must still decode cleanly (no over-rejection).
    const canonical = [_][]const u8{ "0+", "7+", "123-", "10+", "0:", "3:abc" };
    for (canonical) |bytes| {
        var arena = std.heap.ArenaAllocator.init(alloc);
        defer arena.deinit();
        _ = try syrup.decode(bytes, arena.allocator());
    }
}
