const std = @import("std");
const syrup = @import("syrup");

// The Vibesnipe: Value Increments for Boxxy/Aella
// Schema: <'increment {epoch: <int>, from: <sym>, to: <sym>, value: <dict>, vibe: <str>}>

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    // Use stdout for the lure
    var out_buf: [65536]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&out_buf);
    const stdout = fbs.writer();

    // 1. Boxxy's Increment (Security/Structure)
    // "Immutable Truth" -> Aella
    try emitIncrement(allocator, stdout, "boxxy", "aella", "immutable_truth", 100, "Security is the precursor to freedom.");

    // 2. Aella's Increment (Fluidity/Connection)
    // "Social Capital" -> Boxxy
    try emitIncrement(allocator, stdout, "aella", "boxxy", "social_capital", 50, "Connection is the precursor to meaning.");

    // 3. The Synthesis (Self-Sustaining Loop)
    // "Zig-Syrup" -> The World
    try emitIncrement(allocator, stdout, "syrup_dao", "global", "interoperability", 9000, "Syntax is the precursor to semantics.");

    _ = try std.posix.write(std.posix.STDOUT_FILENO, fbs.getWritten());
}

fn emitIncrement(
    allocator: std.mem.Allocator, 
    writer: anytype, 
    from: []const u8, 
    to: []const u8, 
    asset: []const u8, 
    amount: i64, 
    vibe: []const u8
) !void {
    // Construct the Record
    const label = syrup.Value.fromSymbol("increment");
    
    var dict_entries = std.ArrayListUnmanaged(syrup.Value.DictEntry){};
    defer dict_entries.deinit(allocator);
    
    // Keys must be sorted: amount, asset, epoch, from, to, vibe
    // 'a'mount, 'a'sset, 'e'poch, 'f'rom, 't'o, 'v'ibe
    
    // amount
    try dict_entries.append(allocator, .{ .key = syrup.Value.fromSymbol("amount"), .value = syrup.Value.fromInteger(amount) });
    // asset
    try dict_entries.append(allocator, .{ .key = syrup.Value.fromSymbol("asset"), .value = syrup.Value.fromSymbol(asset) });
    // epoch (fixed for demo)
    try dict_entries.append(allocator, .{ .key = syrup.Value.fromSymbol("epoch"), .value = syrup.Value.fromInteger(1) });
    // from
    try dict_entries.append(allocator, .{ .key = syrup.Value.fromSymbol("from"), .value = syrup.Value.fromSymbol(from) });
    // to
    try dict_entries.append(allocator, .{ .key = syrup.Value.fromSymbol("to"), .value = syrup.Value.fromSymbol(to) });
    // vibe
    try dict_entries.append(allocator, .{ .key = syrup.Value.fromSymbol("vibe"), .value = syrup.Value.fromString(vibe) });
    
    const dict_slice = try dict_entries.toOwnedSlice(allocator);
    defer allocator.free(dict_slice);

    const dict = syrup.Value.fromDictionary(dict_slice);
    
    // Fields list (just the dict)
    const fields_alloc = try allocator.alloc(syrup.Value, 1);
    defer allocator.free(fields_alloc);
    fields_alloc[0] = dict;
    
    const record = syrup.Value.fromRecord(&label, fields_alloc);
    
    // Encode
    var buf: [4096]u8 = undefined;
    const encoded = try record.encodeBuf(&buf);
    
    // Compute CID
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(encoded, &hash, .{});
    const cid = std.fmt.bytesToHex(&hash, .lower);
    
    try writer.print("\n=== VIBESNIPE DETECTED ===\n", .{});
    try writer.print("From: {s} -> To: {s}\n", .{from, to});
    try writer.print("CID:  {s}\n", .{cid});
    try writer.print("Data: {s}\n", .{encoded});
}
