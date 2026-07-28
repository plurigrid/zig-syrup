const std = @import("std");
const syrup = @import("syrup");

// Canonical Test Vector from Rust Implementation
// Test { int: 1, seq: vec!["a", "b"] }
// Expected: <4'Test{3'int1+3'seq[1"a1"b]}>

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    _ = arena.allocator();

    const expected = "<4'Test{3'int1+3'seq[1\"a1\"b]}>";

    // Construct equivalent Zig Value
    const label = syrup.Value.fromSymbol("Test");

    const int_key = syrup.Value.fromSymbol("int");
    const int_val = syrup.Value.fromInteger(1);

    const seq_key = syrup.Value.fromSymbol("seq");
    const seq_val = syrup.Value.fromList(&[_]syrup.Value{
        syrup.Value.fromString("a"),
        syrup.Value.fromString("b"),
    });

    // Note: Dictionary keys must be sorted by bytes of the key
    // "int" vs "seq" -> 'i' vs 's' -> int comes first
    var dict_entries = [_]syrup.Value.DictEntry{
        .{ .key = int_key, .value = int_val },
        .{ .key = seq_key, .value = seq_val },
    };

    // In Rust impl, structs are encoded as Records with a dictionary inside
    // <Label { key val ... }>
    // This is weird. Let's look at the Rust output again:
    // <4'Test{3'int1+3'seq[1"a1"b]}>
    // This looks like a Record where the fields list contains a SINGLE dictionary

    const dict = syrup.Value.fromDictionary(&dict_entries);
    const fields = [_]syrup.Value{dict};
    const record = syrup.Value.fromRecord(&label, &fields);

    var buf: [1024]u8 = undefined;
    const encoded = try record.encodeBuf(&buf);

    // Formatted into a fixed buffer and emitted in one go. `std.Io.File`'s
    // writer() takes an `Io` instance as of 0.17-dev, and a parity check has
    // no business standing up an I/O implementation just to print four lines.
    var out_buf: [2048]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buf);

    try out.print("Zig Parity Check\n", .{});
    try out.print("================\n", .{});
    try out.print("Expected: {s}\n", .{expected});
    try out.print("Actual:   {s}\n", .{encoded});

    const matched = std.mem.eql(u8, expected, encoded);
    try out.print("RESULT: {s}\n", .{if (matched) "PASS" else "FAIL"});
    std.debug.print("{s}", .{out.buffered()});

    // Report the mismatch through the exit code too. Printing "FAIL" and
    // returning normally let `zig build parity` succeed on a broken encoder.
    if (!matched) return error.ParityMismatch;
}
