const std = @import("std");
const syrup = @import("syrup");

const ITERATIONS = 100_000;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Test data: skill:invoke record (canonical test case)
    const dict_entries = [_]syrup.Value.DictEntry{
        .{ .key = syrup.string("n"), .value = syrup.integer(4) },
        .{ .key = syrup.string("seed"), .value = syrup.integer(1069) },
    };
    const fields = [_]syrup.Value{
        syrup.symbol("gay-mcp"),
        syrup.symbol("palette"),
        syrup.dictionary(&dict_entries),
        syrup.integer(0),
    };
    const label = syrup.string("skill:invoke");
    const test_value = syrup.record(&label, &fields);

    // Large nested structure
    var nested_items: [100]syrup.Value = undefined;
    for (&nested_items, 0..) |*item, i| {
        item.* = syrup.integer(@intCast(i * 42));
    }
    const nested = syrup.list(&nested_items);

    var encode_buf: [4096]u8 = undefined;

    // Benchmark 1: Encode skill:invoke
    {
        const start = std.time.nanoTimestamp();
        for (0..ITERATIONS) |_| {
            _ = try test_value.encodeBuf(&encode_buf);
        }
        const elapsed_ns: u64 = @intCast(std.time.nanoTimestamp() - start);
        const per_op_ns = elapsed_ns / ITERATIONS;
        std.debug.print("Encode skill:invoke: {d} ns/op ({d} ops/sec)\n", .{
            per_op_ns,
            @as(u64, 1_000_000_000) * ITERATIONS / elapsed_ns,
        });
    }

    // Benchmark 2: Decode skill:invoke
    const encoded = try test_value.encodeBuf(&encode_buf);
    {
        var arena = std.heap.ArenaAllocator.init(allocator);
        const start = std.time.nanoTimestamp();
        for (0..ITERATIONS) |_| {
            _ = try syrup.decode(encoded, arena.allocator());
            // Reset arena instead of deinit/init - much faster
            _ = arena.reset(.retain_capacity);
        }
        const elapsed_ns: u64 = @intCast(std.time.nanoTimestamp() - start);
        arena.deinit();
        const per_op_ns = elapsed_ns / ITERATIONS;
        std.debug.print("Decode skill:invoke: {d} ns/op ({d} ops/sec)\n", .{
            per_op_ns,
            @as(u64, 1_000_000_000) * ITERATIONS / elapsed_ns,
        });
    }

    // Benchmark 3: Encode large list
    {
        const start = std.time.nanoTimestamp();
        for (0..ITERATIONS / 10) |_| {
            _ = try nested.encodeBuf(&encode_buf);
        }
        const elapsed_ns: u64 = @intCast(std.time.nanoTimestamp() - start);
        const per_op_ns = elapsed_ns / (ITERATIONS / 10);
        std.debug.print("Encode list[100]: {d} ns/op ({d} ops/sec)\n", .{
            per_op_ns,
            @as(u64, 1_000_000_000) * (ITERATIONS / 10) / elapsed_ns,
        });
    }

    // Benchmark 4: CID computation
    {
        var hash: [32]u8 = undefined;
        const start = std.time.nanoTimestamp();
        for (0..ITERATIONS) |_| {
            try syrup.computeCid(test_value, &hash);
        }
        const elapsed_ns: u64 = @intCast(std.time.nanoTimestamp() - start);
        const per_op_ns = elapsed_ns / ITERATIONS;
        std.debug.print("CID compute: {d} ns/op ({d} ops/sec)\n", .{
            per_op_ns,
            @as(u64, 1_000_000_000) * ITERATIONS / elapsed_ns,
        });
    }

    // Benchmark 5: Serde roundtrip
    const Config = struct {
        host: []const u8,
        port: i32,
        enabled: bool,
    };
    const config = Config{ .host = "localhost", .port = 8080, .enabled = true };
    {
        var arena = std.heap.ArenaAllocator.init(allocator);
        const start = std.time.nanoTimestamp();
        for (0..ITERATIONS) |_| {
            const val = try syrup.serialize(Config, config, arena.allocator());
            var buf: [256]u8 = undefined;
            const bytes = try val.encodeBuf(&buf);
            const decoded = try syrup.decode(bytes, arena.allocator());
            _ = try syrup.deserialize(Config, decoded, arena.allocator());
            _ = arena.reset(.retain_capacity);
        }
        const elapsed_ns: u64 = @intCast(std.time.nanoTimestamp() - start);
        arena.deinit();
        const per_op_ns = elapsed_ns / ITERATIONS;
        std.debug.print("Serde roundtrip: {d} ns/op ({d} ops/sec)\n", .{
            per_op_ns,
            @as(u64, 1_000_000_000) * ITERATIONS / elapsed_ns,
        });
    }

    // Benchmark 6: CapTP descriptor encoding (fast path)
    {
        var desc_buf: [64]u8 = undefined;
        const start = std.time.nanoTimestamp();
        for (0..ITERATIONS) |i| {
            const pos: u16 = @intCast(i % 256);
            _ = syrup.CapTPDescriptors.encodeDescExport(pos, &desc_buf);
        }
        const elapsed_ns: u64 = @intCast(std.time.nanoTimestamp() - start);
        const per_op_ns = elapsed_ns / ITERATIONS;
        std.debug.print("CapTP desc:export: {d} ns/op ({d} ops/sec)\n", .{
            per_op_ns,
            @as(u64, 1_000_000_000) * ITERATIONS / elapsed_ns,
        });
    }

    // Benchmark 7: Fast decimal parsing
    {
        const test_inputs = [_][]const u8{ "42+", "1234:", "99999\"", "7'" };
        var sum: u64 = 0;
        const start = std.time.nanoTimestamp();
        for (0..ITERATIONS) |i| {
            const input = test_inputs[i % test_inputs.len];
            const result = syrup.parseDecimalFast(input);
            sum +%= result.value;
        }
        const elapsed_ns: u64 = @intCast(std.time.nanoTimestamp() - start);
        const per_op_ns = elapsed_ns / ITERATIONS;
        std.debug.print("Fast decimal parse: {d} ns/op ({d} ops/sec) [sum={d}]\n", .{
            per_op_ns,
            @as(u64, 1_000_000_000) * ITERATIONS / elapsed_ns,
            sum,
        });
    }

    // Benchmark 8: Arena pre-sizing (simulated CapTP decode)
    {
        const captp_msg = "<10'op:deliver<11'desc:export42+>5'hello[1+2+3+]>";
        var arena = std.heap.ArenaAllocator.init(allocator);
        const start = std.time.nanoTimestamp();
        for (0..ITERATIONS) |_| {
            // Estimate arena size before parsing
            const estimated = syrup.estimateCapTPArenaSize(captp_msg);
            _ = estimated;
            _ = try syrup.decode(captp_msg, arena.allocator());
            _ = arena.reset(.retain_capacity);
        }
        const elapsed_ns: u64 = @intCast(std.time.nanoTimestamp() - start);
        arena.deinit();
        const per_op_ns = elapsed_ns / ITERATIONS;
        std.debug.print("CapTP decode: {d} ns/op ({d} ops/sec)\n", .{
            per_op_ns,
            @as(u64, 1_000_000_000) * ITERATIONS / elapsed_ns,
        });
    }
}
