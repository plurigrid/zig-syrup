const std = @import("std");
const syrup = @import("syrup");
const bristol = @import("bristol");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // const stdout = std.io.getStdOut().writer();
    // Use std.debug.print which writes to stderr but is reliable
    const print = std.debug.print;

    // 1. Read Bristol File
    const file_path = "circuits/simple_logic.txt";
    const file = try std.fs.cwd().openFile(file_path, .{});
    defer file.close();
    
    const size = try file.getEndPos();
    const buffer = try allocator.alloc(u8, size);
    defer allocator.free(buffer);
    _ = try file.readAll(buffer);

    print("Parsing Bristol Circuit: {s}\n", .{file_path});
    
    // 2. Parse Circuit
    const circuit = try bristol.Circuit.parse(allocator, buffer);
    print("Parsed: {d} gates, {d} wires\n", .{circuit.num_gates, circuit.num_wires});

    // 3. Convert to Syrup
    const syrup_val = try circuit.toSyrup(allocator);
    
    // 4. Serialize
    var out_buf: [4096]u8 = undefined;
    const encoded = try syrup_val.encodeBuf(&out_buf);
    
    print("Syrup Encoded Size: {d} bytes\n", .{encoded.len});
    print("Syrup Preview: {s}\n", .{encoded});
    
    // 5. Verify CID
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(encoded, &hash, .{});
    const cid = std.fmt.bytesToHex(&hash, .lower);
    print("Circuit CID: {s}\n", .{cid});
}
