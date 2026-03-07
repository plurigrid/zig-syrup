//! Fuzz harnesses for Syrup parser and encoder
//!
//! Run: zig build fuzz-syrup --fuzz
//!
//! Targets:
//!   1. Parser: arbitrary bytes → decode (must not crash or OOM)
//!   2. Round-trip: JSON-like → encode → decode → compare
//!   3. Canonical ordering: encode dict → decode → re-encode → bytes equal

const std = @import("std");
const syrup = @import("syrup");

test "fuzz: syrup parser does not crash on arbitrary input" {
    try std.testing.fuzz({}, struct {
        fn testOne(_: void, input: []const u8) anyerror!void {
            if (input.len == 0) return;
            if (input.len > 1024 * 1024) return; // Skip huge inputs

            var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer arena.deinit();

            // Must not crash, panic, or OOM on any input
            _ = syrup.decode(input, arena.allocator()) catch return;
        }
    }.testOne, .{});
}

test "fuzz: integer encode-decode round-trip" {
    try std.testing.fuzz({}, struct {
        fn testOne(_: void, input: []const u8) anyerror!void {
            if (input.len < 8) return;
            const val = std.mem.readInt(i64, input[0..8], .little);

            var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer arena.deinit();
            const allocator = arena.allocator();

            const sval = syrup.Value{ .integer = val };
            const encoded = try sval.encodeAlloc(allocator);
            const decoded = try syrup.decode(encoded, allocator);

            if (decoded != .integer) return error.TypeMismatch;
            if (decoded.integer != val) return error.ValueMismatch;
        }
    }.testOne, .{});
}

test "fuzz: string encode-decode round-trip" {
    try std.testing.fuzz({}, struct {
        fn testOne(_: void, input: []const u8) anyerror!void {
            if (input.len == 0) return;
            if (input.len > 65536) return; // Reasonable limit

            var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer arena.deinit();
            const allocator = arena.allocator();

            const sval = syrup.Value{ .string = input };
            const encoded = try sval.encodeAlloc(allocator);
            const decoded = try syrup.decode(encoded, allocator);

            if (decoded != .string) return error.TypeMismatch;
            if (!std.mem.eql(u8, decoded.string, input)) return error.ValueMismatch;
        }
    }.testOne, .{});
}

test "fuzz: bytes encode-decode round-trip" {
    try std.testing.fuzz({}, struct {
        fn testOne(_: void, input: []const u8) anyerror!void {
            if (input.len == 0) return;
            if (input.len > 65536) return;

            var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer arena.deinit();
            const allocator = arena.allocator();

            const sval = syrup.Value{ .bytes = input };
            const encoded = try sval.encodeAlloc(allocator);
            const decoded = try syrup.decode(encoded, allocator);

            if (decoded != .bytes) return error.TypeMismatch;
            if (!std.mem.eql(u8, decoded.bytes, input)) return error.ValueMismatch;
        }
    }.testOne, .{});
}

test "fuzz: canonical encoding is idempotent" {
    try std.testing.fuzz({}, struct {
        fn testOne(_: void, input: []const u8) anyerror!void {
            if (input.len == 0) return;
            if (input.len > 4096) return;

            var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer arena.deinit();
            const allocator = arena.allocator();

            // Try to decode
            const val1 = syrup.decode(input, allocator) catch return;

            // Encode
            const encoded1 = val1.encodeAlloc(allocator) catch return;

            // Decode again
            const val2 = syrup.decode(encoded1, allocator) catch return;

            // Re-encode — must produce identical bytes (canonical)
            const encoded2 = val2.encodeAlloc(allocator) catch return;

            if (!std.mem.eql(u8, encoded1, encoded2)) return error.NotIdempotent;
        }
    }.testOne, .{});
}

test "fuzz: encoded size matches actual encoding" {
    try std.testing.fuzz({}, struct {
        fn testOne(_: void, input: []const u8) anyerror!void {
            if (input.len < 8) return;
            const val = std.mem.readInt(i64, input[0..8], .little);

            var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer arena.deinit();
            const allocator = arena.allocator();

            const sval = syrup.Value{ .integer = val };
            const predicted = sval.encodedSize();
            const actual = (try sval.encodeAlloc(allocator)).len;

            if (predicted != actual) return error.SizeMismatch;
        }
    }.testOne, .{});
}
