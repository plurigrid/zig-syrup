/// bandwidth_simple.zig - Simplified bandwidth benchmark

const std = @import("std");
const syrup = @import("syrup");
const Value = syrup.Value;

fn skillInvocation() Value {
    const label = syrup.string("skill:invoke");
    const dict_entries = [_]Value.DictEntry{
        .{ .key = syrup.string("n"), .value = syrup.integer(4) },
        .{ .key = syrup.string("seed"), .value = syrup.integer(1069) },
    };
    const fields_inner = [_]Value{
        syrup.symbol("gay-mcp"),
        syrup.symbol("palette"),
        syrup.dictionary(&dict_entries),
        syrup.integer(0),
    };
    const fields = [_]Value{syrup.list(&fields_inner)};
    return syrup.record(&label, &fields);
}

pub fn main() !void {
    const stdout = std.posix.STDOUT_FILENO;
    var out_buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&out_buf);
    const writer = fbs.writer();
    
    try writer.writeAll("Zig Syrup Bandwidth Benchmark\n");
    try writer.writeAll("=============================\n\n");
    
    const invocation = skillInvocation();
    var buf: [256]u8 = undefined;
    
    // Warmup
    for (0..1000) |_| {
        _ = invocation.encodeBuf(&buf) catch unreachable;
    }
    
    // Benchmark encoding
    const iterations: usize = 1_000_000;
    const start = std.time.nanoTimestamp();
    for (0..iterations) |_| {
        _ = invocation.encodeBuf(&buf) catch unreachable;
    }
    const elapsed_ns = std.time.nanoTimestamp() - start;
    const elapsed_sec = @as(f64, @floatFromInt(elapsed_ns)) / 1e9;
    
    const encoded = invocation.encodeBuf(&buf) catch unreachable;
    const bytes_per_op = encoded.len;
    const total_bytes = bytes_per_op * iterations;
    const mb_per_sec = @as(f64, @floatFromInt(total_bytes)) / elapsed_sec / 1e6;
    const ops_per_sec = @as(f64, @floatFromInt(iterations)) / elapsed_sec;
    
    try writer.print("Test: skill-invocation encode\n", .{});
    try writer.print("  Iterations: {d}\n", .{iterations});
    try writer.print("  Size/op: {d} bytes\n", .{bytes_per_op});
    try writer.print("  Elapsed: {d:.3}s\n", .{elapsed_sec});
    try writer.print("  ops/sec: {d:.0}\n", .{ops_per_sec});
    try writer.print("  MB/sec: {d:.2}\n", .{mb_per_sec});
    try writer.writeAll("\nNote: Zero-allocation encoding to fixed buffer\n");
    
    _ = try std.posix.write(stdout, fbs.getWritten());
}
