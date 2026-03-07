//! SPI Parallel Benchmark — Multi-threaded color generation
//!
//! Apples-to-apples comparison with Gay.jl KernelAbstractions:
//!   Gay.jl: _ka_colors_kernel!(seed, out, N) on 8 threads → 1B colors/sec (M3)
//!   zig-syrup: std.Thread spawn N workers, each does SplitMix64.at(seed, i) → ?
//!
//! Gay.jl's SPI verification uses xor_fingerprint (commutative, order-independent).
//! We replicate the same: generate colors in parallel, XOR-fold for verification.
//!
//! Three modes:
//!   1. SplitMix64 only (matches Gay.jl core path)
//!   2. SplitMix64 + hex conversion (matches Gay.jl colorAt)
//!   3. Full triadic (ChaCha + SplitMix + Rybka, zig-syrup extension)

const std = @import("std");
const splitmix_trit = @import("splitmix_trit");

const SEED: u64 = 42;
const GOLDEN: u64 = 0x9e3779b97f4a7c15;
const MIX1: u64 = 0xbf58476d1ce4e5b9;
const MIX2: u64 = 0x94d049bb133111eb;

/// Inline SplitMix64 — matches Gay.jl exactly, no function call overhead
inline fn splitmix64_at(seed: u64, index: u64) u64 {
    var z = seed +% (GOLDEN *% index);
    z = (z ^ (z >> 30)) *% MIX1;
    z = (z ^ (z >> 27)) *% MIX2;
    return z ^ (z >> 31);
}

/// Convert u64 to RGB hex bytes (matches Gay.jl colorAt output)
inline fn to_rgb(val: u64) struct { r: u8, g: u8, b: u8 } {
    const hue_bits = val & 0xFFFFFF;
    return .{
        .r = @truncate((hue_bits >> 16) & 0xFF),
        .g = @truncate((hue_bits >> 8) & 0xFF),
        .b = @truncate(hue_bits & 0xFF),
    };
}

const WorkerResult = struct {
    xor_fingerprint: u64,
    count: u64,
    elapsed_ns: i128,
};

fn workerSplitMix(seed: u64, start: u64, count: u64) WorkerResult {
    var xor: u64 = 0;
    const t0 = std.time.nanoTimestamp();
    var i: u64 = start;
    const end_idx = start + count;
    while (i < end_idx) : (i += 1) {
        xor ^= splitmix64_at(seed, i);
    }
    const t1 = std.time.nanoTimestamp();
    // Prevent dead code elimination
    std.mem.doNotOptimizeAway(xor);
    return .{ .xor_fingerprint = xor, .count = count, .elapsed_ns = t1 - t0 };
}

fn workerColorAt(seed: u64, start: u64, count: u64) WorkerResult {
    var xor: u64 = 0;
    const t0 = std.time.nanoTimestamp();
    var i: u64 = start;
    const end_idx = start + count;
    while (i < end_idx) : (i += 1) {
        const val = splitmix64_at(seed, i);
        const rgb = to_rgb(val);
        xor ^= @as(u64, rgb.r) << 16 | @as(u64, rgb.g) << 8 | @as(u64, rgb.b);
    }
    const t1 = std.time.nanoTimestamp();
    std.mem.doNotOptimizeAway(xor);
    return .{ .xor_fingerprint = xor, .count = count, .elapsed_ns = t1 - t0 };
}

fn workerTriadic(seed: u64, start: u64, count: u64) WorkerResult {
    var xor: u64 = 0;
    const t0 = std.time.nanoTimestamp();
    var i: u64 = start;
    const end_idx = start + count;
    while (i < end_idx) : (i += 1) {
        const rgb = splitmix_trit.SplitMixRGB.colorAt(seed, i);
        xor ^= @as(u64, rgb.r) << 16 | @as(u64, rgb.g) << 8 | @as(u64, rgb.b);
    }
    const t1 = std.time.nanoTimestamp();
    std.mem.doNotOptimizeAway(xor);
    return .{ .xor_fingerprint = xor, .count = count, .elapsed_ns = t1 - t0 };
}

const Mode = enum { splitmix, colorat, triadic };

fn runParallel(
    comptime mode: Mode,
    n_total: u64,
    n_threads: usize,
) !struct { total_ns: i128, xor: u64, verified: bool } {
    const alloc = std.heap.page_allocator;

    const ThreadFn = switch (mode) {
        .splitmix => workerSplitMix,
        .colorat => workerColorAt,
        .triadic => workerTriadic,
    };

    const chunk = n_total / n_threads;
    const remainder = n_total % n_threads;

    var handles = try alloc.alloc(std.Thread, n_threads);
    defer alloc.free(handles);
    var results = try alloc.alloc(WorkerResult, n_threads);
    defer alloc.free(results);

    const t0 = std.time.nanoTimestamp();

    for (0..n_threads) |tid| {
        const start = chunk * tid + @min(tid, remainder);
        const count = chunk + @as(u64, if (tid < remainder) 1 else 0);
        const seed = SEED;
        const result_ptr = &results[tid];
        handles[tid] = try std.Thread.spawn(.{}, struct {
            fn run(s: u64, st: u64, c: u64, out: *WorkerResult) void {
                out.* = ThreadFn(s, st, c);
            }
        }.run, .{ seed, start, count, result_ptr });
    }

    for (handles) |h| h.join();
    const t1 = std.time.nanoTimestamp();

    // XOR-fold all thread fingerprints (commutative — order doesn't matter)
    var combined_xor: u64 = 0;
    for (results) |r| combined_xor ^= r.xor_fingerprint;

    // Verify against single-threaded reference
    const ref_result = ThreadFn(SEED, 0, n_total);
    const verified = combined_xor == ref_result.xor_fingerprint;

    return .{ .total_ns = t1 - t0, .xor = combined_xor, .verified = verified };
}

fn writeAll(buf: []const u8) void {
    _ = std.posix.write(std.posix.STDOUT_FILENO, buf) catch {};
}

fn printBuf(comptime fmt: []const u8, args: anytype) void {
    var buf: [1024]u8 = undefined;
    const slice = std.fmt.bufPrint(&buf, fmt, args) catch &buf;
    writeAll(slice);
}

fn runModeTable(
    label: []const u8,
    comptime mode: Mode,
    test_sizes: []const u64,
    size_labels: []const []const u8,
    thread_counts: []const usize,
    cpu_count: usize,
) !void {
    printBuf("  -- {s} --\n", .{label});
    writeAll("  +----------+--------+--------------+--------------+------------+\n");
    writeAll("  |   Count  |Threads |   Wall ms    |  Colors/sec  | SPI verify |\n");
    writeAll("  +----------+--------+--------------+--------------+------------+\n");

    for (test_sizes, 0..) |n, si| {
        for (thread_counts) |nt| {
            if (nt > cpu_count) continue;
            if (mode == .triadic and n >= 100_000_000 and nt < 4) continue;

            const result = runParallel(mode, n, nt) catch {
                printBuf("  | {s:>8} | {d:>6} | ERROR        |              |            |\n", .{ size_labels[si], nt });
                continue;
            };

            const wall_ms = @divFloor(result.total_ns, 1_000_000);
            const colors_per_sec: i128 = if (result.total_ns > 0)
                @divFloor(@as(i128, n) * 1_000_000_000, result.total_ns)
            else
                0;
            const verified_str: []const u8 = if (result.verified) "OK" else "MISMATCH";

            printBuf("  | {s:>8} | {d:>6} | {d:>10} ms | {d:>10} M/s | {s:>10} |\n", .{
                size_labels[si],
                nt,
                wall_ms,
                @divFloor(colors_per_sec, 1_000_000),
                verified_str,
            });
        }
    }
    writeAll("  +----------+--------+--------------+--------------+------------+\n\n");
}

pub fn main() !void {
    const cpu_count = std.Thread.getCpuCount() catch 4;
    const thread_counts = [_]usize{ 1, 2, 4, @min(cpu_count, 8), cpu_count };

    writeAll(
        \\
        \\╔══════════════════════════════════════════════════════════════════════╗
        \\║              SPI PARALLEL THROUGHPUT BENCHMARK                      ║
        \\║    Apples-to-apples comparison with Gay.jl KernelAbstractions       ║
        \\╚══════════════════════════════════════════════════════════════════════╝
        \\
    );

    printBuf("  CPU cores detected: {}\n", .{cpu_count});
    printBuf("  Seed: {}\n\n", .{SEED});

    const test_sizes = [_]u64{ 1_000_000, 10_000_000, 100_000_000 };
    const size_labels = [_][]const u8{ "1M", "10M", "100M" };

    // Mode 1: SplitMix64 raw
    try runModeTable("SplitMix64 raw (Gay.jl core path)", .splitmix, &test_sizes, &size_labels, &thread_counts, cpu_count);
    // Mode 2: SplitMix64 → RGB
    try runModeTable("SplitMix64 -> RGB (Gay.jl colorAt)", .colorat, &test_sizes, &size_labels, &thread_counts, cpu_count);
    // Mode 3: Triadic RGB
    try runModeTable("Triadic RGB (zig-syrup ChaCha+SM+Rybka)", .triadic, &test_sizes, &size_labels, &thread_counts, cpu_count);

    writeAll(
        \\  Gay.jl reference (M3 Pro, 8 threads):
        \\    SplitMix64 core:     ~1B colors/sec
        \\    ka_color_sums:       ~7B colors/sec (O(1) memory, chunked reduce)
        \\    SPI xor_fingerprint: ~378M colors/sec (M5 Metal GPU)
        \\
        \\  Zero-copy advantage: zig-syrup operates on stack/registers only.
        \\  No GC pressure, no array allocations, no Julia type dispatch overhead.
        \\
    );
}
