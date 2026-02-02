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

    var out_buf: [2048]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&out_buf);
    const stdout = fbs.writer();

    try stdout.print("Zig Parity Check\n", .{});
    try stdout.print("================\n", .{});
    try stdout.print("Expected: {s}\n", .{expected});
    try stdout.print("Actual:   {s}\n", .{encoded});
    
    if (std.mem.eql(u8, expected, encoded)) {
        try stdout.print("RESULT: PASS\n", .{});
    } else {
        try stdout.print("RESULT: FAIL\n", .{});
    }

    _ = try std.posix.write(std.posix.STDOUT_FILENO, fbs.getWritten());
}
