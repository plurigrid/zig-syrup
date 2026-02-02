const std = @import("std");
const syrup = @import("syrup");

// ============================================================================
// Snapshot / Golden-value tests for Syrup encoding
// ============================================================================

// Helpers
fn expectEncodeExact(val: syrup.Value, expected: []const u8) !void {
    var buf: [256]u8 = undefined;
    const encoded = try val.encodeBuf(&buf);
    try std.testing.expectEqualSlices(u8, expected, encoded);
}

fn expectDecodeEquals(bytes: []const u8, expected: syrup.Value) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    const decoded = try syrup.decode(bytes, arena.allocator());
    try std.testing.expect(decoded.compare(expected) == .eq);
}

fn expectRoundtrip(bytes: []const u8) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    const decoded = try syrup.decode(bytes, arena.allocator());
    var buf: [256]u8 = undefined;
    const re_encoded = try decoded.encodeBuf(&buf);
    try std.testing.expectEqualSlices(u8, bytes, re_encoded);
}

// ============================================================================
// Encode golden tests
// ============================================================================

test "snapshot encode: boolean true" {
    try expectEncodeExact(syrup.Value.fromBool(true), "t");
}

test "snapshot encode: boolean false" {
    try expectEncodeExact(syrup.Value.fromBool(false), "f");
}

test "snapshot encode: integer 0" {
    try expectEncodeExact(syrup.Value.fromInteger(0), "0+");
}

test "snapshot encode: integer 42" {
    try expectEncodeExact(syrup.Value.fromInteger(42), "42+");
}

test "snapshot encode: integer -1" {
    try expectEncodeExact(syrup.Value.fromInteger(-1), "1-");
}

test "snapshot encode: empty string" {
    try expectEncodeExact(syrup.Value.fromString(""), "0\"");
}

test "snapshot encode: string hello" {
    try expectEncodeExact(syrup.Value.fromString("hello"), "5\"hello");
}

test "snapshot encode: symbol foo" {
    try expectEncodeExact(syrup.Value.fromSymbol("foo"), "3'foo");
}

test "snapshot encode: empty list" {
    try expectEncodeExact(syrup.Value.fromList(&[_]syrup.Value{}), "[]");
}

test "snapshot encode: list [1,2,3]" {
    const items = [_]syrup.Value{
        syrup.Value.fromInteger(1),
        syrup.Value.fromInteger(2),
        syrup.Value.fromInteger(3),
    };
    try expectEncodeExact(syrup.Value.fromList(&items), "[1+2+3+]");
}

test "snapshot encode: empty dict" {
    try expectEncodeExact(syrup.Value.fromDictionary(&[_]syrup.Value.DictEntry{}), "{}");
}

// ============================================================================
// Decode golden tests
// ============================================================================

test "snapshot decode: boolean true" {
    try expectDecodeEquals("t", syrup.Value.fromBool(true));
}

test "snapshot decode: boolean false" {
    try expectDecodeEquals("f", syrup.Value.fromBool(false));
}

test "snapshot decode: integer 0" {
    try expectDecodeEquals("0+", syrup.Value.fromInteger(0));
}

test "snapshot decode: integer 42" {
    try expectDecodeEquals("42+", syrup.Value.fromInteger(42));
}

test "snapshot decode: integer -1" {
    try expectDecodeEquals("1-", syrup.Value.fromInteger(-1));
}

test "snapshot decode: empty string" {
    try expectDecodeEquals("0\"", syrup.Value.fromString(""));
}

test "snapshot decode: string hello" {
    try expectDecodeEquals("5\"hello", syrup.Value.fromString("hello"));
}

test "snapshot decode: symbol foo" {
    try expectDecodeEquals("3'foo", syrup.Value.fromSymbol("foo"));
}

test "snapshot decode: empty list" {
    try expectDecodeEquals("[]", syrup.Value.fromList(&[_]syrup.Value{}));
}

test "snapshot decode: list [1,2,3]" {
    const items = [_]syrup.Value{
        syrup.Value.fromInteger(1),
        syrup.Value.fromInteger(2),
        syrup.Value.fromInteger(3),
    };
    try expectDecodeEquals("[1+2+3+]", syrup.Value.fromList(&items));
}

test "snapshot decode: empty dict" {
    try expectDecodeEquals("{}", syrup.Value.fromDictionary(&[_]syrup.Value.DictEntry{}));
}

// ============================================================================
// Roundtrip tests (encode -> decode -> re-encode byte identity)
// ============================================================================

test "snapshot roundtrip: boolean true" {
    try expectRoundtrip("t");
}

test "snapshot roundtrip: boolean false" {
    try expectRoundtrip("f");
}

test "snapshot roundtrip: integer 0" {
    try expectRoundtrip("0+");
}

test "snapshot roundtrip: integer 42" {
    try expectRoundtrip("42+");
}

test "snapshot roundtrip: integer -1" {
    try expectRoundtrip("1-");
}

test "snapshot roundtrip: empty string" {
    try expectRoundtrip("0\"");
}

test "snapshot roundtrip: string hello" {
    try expectRoundtrip("5\"hello");
}

test "snapshot roundtrip: symbol foo" {
    try expectRoundtrip("3'foo");
}

test "snapshot roundtrip: empty list" {
    try expectRoundtrip("[]");
}

test "snapshot roundtrip: list [1,2,3]" {
    try expectRoundtrip("[1+2+3+]");
}

test "snapshot roundtrip: empty dict" {
    try expectRoundtrip("{}");
}
