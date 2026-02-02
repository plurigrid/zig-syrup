const std = @import("std");
const syrup = @import("syrup");

// The Benchmark Game — Comprehensive Zig-Syrup Benchmarks
// Measures encode/decode latency, hashing, CID, canonical sort, parsing, and roundtrip

const BenchConfig = struct {
    name: []const u8,
    count: i64,
    enabled: bool,
    ratio: f64,
    tag: []const u8,
};

fn runBench(comptime label: []const u8, comptime iters: usize, stdout: anytype, func: anytype) !void {
    const start = std.time.nanoTimestamp();
    var run: usize = 0;
    while (run < iters) : (run += 1) {
        func.call();
    }
    const end = std.time.nanoTimestamp();
    const total_ns = end - start;
    const avg_ns = @divFloor(total_ns, iters);
    const ops_sec = if (avg_ns > 0) @divFloor(@as(i128, 1_000_000_000), avg_ns) else 0;
    try stdout.print("{s}: {d} ns/op  ({d} ops/sec)\n", .{ label, avg_ns, ops_sec });
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var out_buf: [8192]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&out_buf);
    const stdout = fbs.writer();

    try stdout.print("=== Zig-Syrup Comprehensive Benchmark ===\n\n", .{});

    // ----- Shared buffers -----
    var encode_buf: [100000]u8 = undefined;

    // ========== 1. Encode tiny (single integer) ==========
    {
        const val = syrup.Value.fromInteger(42);
        const start = std.time.nanoTimestamp();
        var run: usize = 0;
        while (run < 100_000) : (run += 1) {
            _ = try val.encodeBuf(&encode_buf);
        }
        const end = std.time.nanoTimestamp();
        const avg = @divFloor(end - start, 100_000);
        const ops = if (avg > 0) @divFloor(@as(i128, 1_000_000_000), avg) else 0;
        try stdout.print("Encode tiny (int):          {d} ns/op  ({d} ops/sec)\n", .{ avg, ops });
    }

    // ========== 2. Encode small record (skill:invoke, 3 fields) ==========
    {
        const label = syrup.Value.fromSymbol("skill:invoke");
        const fields = [_]syrup.Value{
            syrup.Value.fromSymbol("method"),
            syrup.Value.fromSymbol("target"),
            syrup.Value.fromSymbol("context"),
        };
        const rec = syrup.Value.fromRecord(&label, &fields);
        const start = std.time.nanoTimestamp();
        var run: usize = 0;
        while (run < 100_000) : (run += 1) {
            _ = try rec.encodeBuf(&encode_buf);
        }
        const end = std.time.nanoTimestamp();
        const avg = @divFloor(end - start, 100_000);
        const ops = if (avg > 0) @divFloor(@as(i128, 1_000_000_000), avg) else 0;
        try stdout.print("Encode small record:        {d} ns/op  ({d} ops/sec)\n", .{ avg, ops });
    }

    // ========== 3. Encode medium list (100 integers) ==========
    {
        var items_100 = std.ArrayListUnmanaged(syrup.Value){};
        defer items_100.deinit(allocator);
        var i: i64 = 0;
        while (i < 100) : (i += 1) {
            try items_100.append(allocator, syrup.Value.fromInteger(i));
        }
        const list_val = syrup.Value.fromList(items_100.items);
        const start = std.time.nanoTimestamp();
        var run: usize = 0;
        while (run < 100_000) : (run += 1) {
            _ = try list_val.encodeBuf(&encode_buf);
        }
        const end = std.time.nanoTimestamp();
        const avg = @divFloor(end - start, 100_000);
        const ops = if (avg > 0) @divFloor(@as(i128, 1_000_000_000), avg) else 0;
        try stdout.print("Encode medium list (100):   {d} ns/op  ({d} ops/sec)\n", .{ avg, ops });
    }

    // ========== 4. Encode large list (1000 integers, 1000 iters) ==========
    {
        var items_1000 = std.ArrayListUnmanaged(syrup.Value){};
        defer items_1000.deinit(allocator);
        var i: i64 = 0;
        while (i < 1000) : (i += 1) {
            try items_1000.append(allocator, syrup.Value.fromInteger(i));
        }
        const label = syrup.Value.fromSymbol("benchmark:data");
        const list_val = syrup.Value.fromList(items_1000.items);
        const fields_large = [_]syrup.Value{list_val};
        const rec = syrup.Value.fromRecord(&label, &fields_large);
        const start = std.time.nanoTimestamp();
        var run: usize = 0;
        while (run < 1000) : (run += 1) {
            _ = try rec.encodeBuf(&encode_buf);
        }
        const end = std.time.nanoTimestamp();
        const avg = @divFloor(end - start, 1000);
        const ops = if (avg > 0) @divFloor(@as(i128, 1_000_000_000), avg) else 0;
        try stdout.print("Encode large list (1000):   {d} ns/op  ({d} ops/sec)\n", .{ avg, ops });
    }

    // ========== 5. Decode tiny (single integer) ==========
    {
        const val = syrup.Value.fromInteger(42);
        const encoded = try val.encodeBuf(&encode_buf);
        const start = std.time.nanoTimestamp();
        var run: usize = 0;
        while (run < 100_000) : (run += 1) {
            var arena = std.heap.ArenaAllocator.init(allocator);
            defer arena.deinit();
            _ = try syrup.decode(encoded, arena.allocator());
        }
        const end = std.time.nanoTimestamp();
        const avg = @divFloor(end - start, 100_000);
        const ops = if (avg > 0) @divFloor(@as(i128, 1_000_000_000), avg) else 0;
        try stdout.print("Decode tiny (int):          {d} ns/op  ({d} ops/sec)\n", .{ avg, ops });
    }

    // ========== 6. Decode small record (skill:invoke) ==========
    {
        const label = syrup.Value.fromSymbol("skill:invoke");
        const fields = [_]syrup.Value{
            syrup.Value.fromSymbol("method"),
            syrup.Value.fromSymbol("target"),
            syrup.Value.fromSymbol("context"),
        };
        const rec = syrup.Value.fromRecord(&label, &fields);
        const encoded = try rec.encodeBuf(&encode_buf);
        const start = std.time.nanoTimestamp();
        var run: usize = 0;
        while (run < 100_000) : (run += 1) {
            var arena = std.heap.ArenaAllocator.init(allocator);
            defer arena.deinit();
            _ = try syrup.decode(encoded, arena.allocator());
        }
        const end = std.time.nanoTimestamp();
        const avg = @divFloor(end - start, 100_000);
        const ops = if (avg > 0) @divFloor(@as(i128, 1_000_000_000), avg) else 0;
        try stdout.print("Decode small record:        {d} ns/op  ({d} ops/sec)\n", .{ avg, ops });
    }

    // ========== 7. Decode medium list (100 integers) ==========
    {
        var items_100 = std.ArrayListUnmanaged(syrup.Value){};
        defer items_100.deinit(allocator);
        var i: i64 = 0;
        while (i < 100) : (i += 1) {
            try items_100.append(allocator, syrup.Value.fromInteger(i));
        }
        const list_val = syrup.Value.fromList(items_100.items);
        const encoded = try list_val.encodeBuf(&encode_buf);
        const start = std.time.nanoTimestamp();
        var run: usize = 0;
        while (run < 100_000) : (run += 1) {
            var arena = std.heap.ArenaAllocator.init(allocator);
            defer arena.deinit();
            _ = try syrup.decode(encoded, arena.allocator());
        }
        const end = std.time.nanoTimestamp();
        const avg = @divFloor(end - start, 100_000);
        const ops = if (avg > 0) @divFloor(@as(i128, 1_000_000_000), avg) else 0;
        try stdout.print("Decode medium list (100):   {d} ns/op  ({d} ops/sec)\n", .{ avg, ops });
    }

    // ========== 8. Decode large list (1000 integers, 1000 iters) ==========
    {
        var items_1000 = std.ArrayListUnmanaged(syrup.Value){};
        defer items_1000.deinit(allocator);
        var i: i64 = 0;
        while (i < 1000) : (i += 1) {
            try items_1000.append(allocator, syrup.Value.fromInteger(i));
        }
        const label = syrup.Value.fromSymbol("benchmark:data");
        const list_val = syrup.Value.fromList(items_1000.items);
        const fields_large = [_]syrup.Value{list_val};
        const rec = syrup.Value.fromRecord(&label, &fields_large);
        const encoded = try rec.encodeBuf(&encode_buf);
        const start = std.time.nanoTimestamp();
        var run: usize = 0;
        while (run < 1000) : (run += 1) {
            var arena = std.heap.ArenaAllocator.init(allocator);
            defer arena.deinit();
            _ = try syrup.decode(encoded, arena.allocator());
        }
        const end = std.time.nanoTimestamp();
        const avg = @divFloor(end - start, 1000);
        const ops = if (avg > 0) @divFloor(@as(i128, 1_000_000_000), avg) else 0;
        try stdout.print("Decode large list (1000):   {d} ns/op  ({d} ops/sec)\n", .{ avg, ops });
    }

    // ========== 9. Value.compare (two medium dictionaries) ==========
    {
        var entries_a: [10]syrup.Value.DictEntry = undefined;
        var entries_b: [10]syrup.Value.DictEntry = undefined;
        for (0..10) |idx| {
            const i_val: i64 = @intCast(idx);
            entries_a[idx] = .{ .key = syrup.Value.fromInteger(i_val), .value = syrup.Value.fromString("alpha") };
            entries_b[idx] = .{ .key = syrup.Value.fromInteger(i_val), .value = syrup.Value.fromString("beta") };
        }
        const dict_a = syrup.Value.fromDictionary(&entries_a);
        const dict_b = syrup.Value.fromDictionary(&entries_b);
        const start = std.time.nanoTimestamp();
        var run: usize = 0;
        while (run < 100_000) : (run += 1) {
            _ = dict_a.compare(dict_b);
        }
        const end = std.time.nanoTimestamp();
        const avg = @divFloor(end - start, 100_000);
        const ops = if (avg > 0) @divFloor(@as(i128, 1_000_000_000), avg) else 0;
        try stdout.print("Value.compare (dicts):      {d} ns/op  ({d} ops/sec)\n", .{ avg, ops });
    }

    // ========== 10. Value.hash (medium record) ==========
    {
        const label = syrup.Value.fromSymbol("skill:invoke");
        const fields = [_]syrup.Value{
            syrup.Value.fromSymbol("method"),
            syrup.Value.fromString("doSomething"),
            syrup.Value.fromInteger(42),
            syrup.Value.fromSymbol("context"),
            syrup.Value.fromString("bench"),
        };
        const rec = syrup.Value.fromRecord(&label, &fields);
        const start = std.time.nanoTimestamp();
        var run: usize = 0;
        while (run < 100_000) : (run += 1) {
            _ = rec.hash();
        }
        const end = std.time.nanoTimestamp();
        const avg = @divFloor(end - start, 100_000);
        const ops = if (avg > 0) @divFloor(@as(i128, 1_000_000_000), avg) else 0;
        try stdout.print("Value.hash (record):        {d} ns/op  ({d} ops/sec)\n", .{ avg, ops });
    }

    // ========== 11. computeCid (small record) ==========
    {
        const label = syrup.Value.fromSymbol("skill:invoke");
        const fields = [_]syrup.Value{
            syrup.Value.fromSymbol("method"),
            syrup.Value.fromString("target"),
            syrup.Value.fromInteger(1),
        };
        const rec = syrup.Value.fromRecord(&label, &fields);
        var hash_out: [32]u8 = undefined;
        const start = std.time.nanoTimestamp();
        var run: usize = 0;
        while (run < 100_000) : (run += 1) {
            try syrup.computeCid(rec, &hash_out);
        }
        const end = std.time.nanoTimestamp();
        const avg = @divFloor(end - start, 100_000);
        const ops = if (avg > 0) @divFloor(@as(i128, 1_000_000_000), avg) else 0;
        try stdout.print("computeCid (record):        {d} ns/op  ({d} ops/sec)\n", .{ avg, ops });
    }

    // ========== 12. dictionaryCanonical (sort 20 entries) ==========
    {
        var entries: [20]syrup.Value.DictEntry = undefined;
        // Fill in reverse order to force sorting work
        for (0..20) |idx| {
            const i_val: i64 = @intCast(19 - idx);
            entries[idx] = .{ .key = syrup.Value.fromInteger(i_val), .value = syrup.Value.fromString("val") };
        }
        const start = std.time.nanoTimestamp();
        var run: usize = 0;
        while (run < 100_000) : (run += 1) {
            var arena = std.heap.ArenaAllocator.init(allocator);
            defer arena.deinit();
            _ = try syrup.dictionaryCanonical(arena.allocator(), &entries);
        }
        const end = std.time.nanoTimestamp();
        const avg = @divFloor(end - start, 100_000);
        const ops = if (avg > 0) @divFloor(@as(i128, 1_000_000_000), avg) else 0;
        try stdout.print("dictionaryCanonical (20):   {d} ns/op  ({d} ops/sec)\n", .{ avg, ops });
    }

    // ========== 13. parseDecimalFast ("12345") ==========
    {
        const start = std.time.nanoTimestamp();
        var run: usize = 0;
        while (run < 100_000) : (run += 1) {
            const r = syrup.parseDecimalFast("12345:");
            std.mem.doNotOptimizeAway(r);
        }
        const end = std.time.nanoTimestamp();
        const avg = @divFloor(end - start, 100_000);
        const ops = if (avg > 0) @divFloor(@as(i128, 1_000_000_000), avg) else 0;
        try stdout.print("parseDecimalFast:           {d} ns/op  ({d} ops/sec)\n", .{ avg, ops });
    }

    // ========== 14. estimateCapTPArenaSize (op:deliver) ==========
    {
        const input = "<10'op:deliver42+5\"hello>";
        const start = std.time.nanoTimestamp();
        var run: usize = 0;
        while (run < 100_000) : (run += 1) {
            const r = syrup.estimateCapTPArenaSize(input);
            std.mem.doNotOptimizeAway(r);
        }
        const end = std.time.nanoTimestamp();
        const avg = @divFloor(end - start, 100_000);
        const ops = if (avg > 0) @divFloor(@as(i128, 1_000_000_000), avg) else 0;
        try stdout.print("estimateCapTPArenaSize:     {d} ns/op  ({d} ops/sec)\n", .{ avg, ops });
    }

    // ========== 15. serialize/deserialize roundtrip (5-field struct) ==========
    {
        const config = BenchConfig{
            .name = "benchmark",
            .count = 100,
            .enabled = true,
            .ratio = 3.14,
            .tag = "test",
        };
        const start = std.time.nanoTimestamp();
        var run: usize = 0;
        while (run < 100_000) : (run += 1) {
            var arena = std.heap.ArenaAllocator.init(allocator);
            defer arena.deinit();
            const a = arena.allocator();
            const val = try syrup.serialize(BenchConfig, config, a);
            var buf2: [512]u8 = undefined;
            const encoded = try val.encodeBuf(&buf2);
            const decoded = try syrup.decode(encoded, a);
            const restored = try syrup.deserialize(BenchConfig, decoded, a);
            std.mem.doNotOptimizeAway(restored);
        }
        const end = std.time.nanoTimestamp();
        const avg = @divFloor(end - start, 100_000);
        const ops = if (avg > 0) @divFloor(@as(i128, 1_000_000_000), avg) else 0;
        try stdout.print("Roundtrip (5-field struct):  {d} ns/op  ({d} ops/sec)\n", .{ avg, ops });
    }

    try stdout.print("\n=== Benchmark complete ===\n", .{});

    _ = try std.posix.write(std.posix.STDOUT_FILENO, fbs.getWritten());
}
