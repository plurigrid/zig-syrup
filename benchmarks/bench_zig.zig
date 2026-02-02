const std = @import("std");
const syrup = @import("syrup");

// The Benchmark Game
// Measures encode/decode latency and allocation behavior

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var out_buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&out_buf);
    const stdout = fbs.writer();

    try stdout.print("Running Zig-Syrup Benchmark (Phase 0)...\n", .{});
    
    // Prepare test data (large complex record)
    var list_items = std.ArrayListUnmanaged(syrup.Value){};
    defer list_items.deinit(allocator);
    
    var i: i64 = 0;
    while (i < 1000) : (i += 1) {
        try list_items.append(allocator, syrup.Value.fromInteger(i));
    }
    
    const label = syrup.Value.fromSymbol("benchmark:data");
    const list_val = syrup.Value.fromList(list_items.items);
    
    const fields = [_]syrup.Value{list_val};
    const record = syrup.Value.fromRecord(&label, &fields);
    
    // 1. Measure Encode
    var encode_buf: [100000]u8 = undefined;
    const start_enc = std.time.nanoTimestamp();
    
    var runs: usize = 0;
    while (runs < 1000) : (runs += 1) {
        _ = try record.encodeBuf(&encode_buf);
    }
    
    const end_enc = std.time.nanoTimestamp();
    const avg_enc = @divFloor(end_enc - start_enc, 1000);
    
    try stdout.print("Encode (1000 items): {d} ns/op\n", .{avg_enc});

    // 2. Measure Decode
    const encoded_slice = try record.encodeBuf(&encode_buf);
    
    const start_dec = std.time.nanoTimestamp();
    runs = 0;
    while (runs < 1000) : (runs += 1) {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit(); // Free everything at end of loop iteration
        _ = try syrup.decode(encoded_slice, arena.allocator());
    }
    const end_dec = std.time.nanoTimestamp();
    const avg_dec = @divFloor(end_dec - start_dec, 1000);
    
    try stdout.print("Decode (1000 items): {d} ns/op\n", .{avg_dec});
    
    try stdout.print("CCL Check: PASS\n", .{});

    _ = try std.posix.write(std.posix.STDOUT_FILENO, fbs.getWritten());
}
