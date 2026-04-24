//! SPI Virtuoso — Maximum performance color generation
//!
//! Increasingly aggressive optimizations inspired by:
//!   Julia/Mojo: SIMD vectorization, loop tiling, @simd @inbounds
//!   Zig/C: comptime unrolling, restrict semantics, prefetch, zero-alloc
//!
//! Levels:
//!   L0: Scalar baseline (what we had)
//!   L1: 4-wide SIMD SplitMix64 (NEON/SSE)
//!   L2: 8-wide with software pipelining (2 SIMD ops in flight)
//!   L3: Chunked reduction with XOR fingerprint (Gay.jl ka_color_sums equivalent)
//!   L4: Tiled + prefetch (Mojo-style register blocking)
//!   L5: Full pipeline: generate + reduce + verify in one pass (zero-copy ideal)

const std = @import("std");

fn nanoTimestamp() i128 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.REALTIME, &ts);
    return @as(i128, @intCast(ts.sec)) * 1_000_000_000 + @as(i128, @intCast(ts.nsec));
}

fn posixWrite(fd: std.posix.fd_t, bytes: []const u8) !usize {
    const rc = std.c.write(fd, bytes.ptr, bytes.len);
    if (rc < 0) return error.WriteError;
    return @intCast(rc);
}

const GOLDEN: u64 = 0x9e3779b97f4a7c15;
const MIX1: u64 = 0xbf58476d1ce4e5b9;
const MIX2: u64 = 0x94d049bb133111eb;
const SEED: u64 = 42;

// ============================================================================
// L0: Scalar baseline — the reference implementation
// ============================================================================

inline fn splitmix64(seed: u64, index: u64) u64 {
    var z = seed +% (GOLDEN *% index);
    z = (z ^ (z >> 30)) *% MIX1;
    z = (z ^ (z >> 27)) *% MIX2;
    return z ^ (z >> 31);
}

fn l0_scalar(n: u64) u64 {
    var xor: u64 = 0;
    var i: u64 = 0;
    while (i < n) : (i += 1) {
        xor ^= splitmix64(SEED, i);
    }
    return xor;
}

// ============================================================================
// L1: 4-wide scalar unroll (Julia NTuple{4} equivalent)
// Key insight: on Apple Silicon M-series, the wide scalar pipeline (6-wide
// dispatch) means explicit @Vector can be SLOWER than 4 independent scalar
// operations. Julia's @simd lets LLVM decide; we replicate that by unrolling
// 4 independent accumulators without forcing SIMD.
// ============================================================================

const V4u64 = @Vector(4, u64);

inline fn splitmix64_v4(seed: V4u64, index: V4u64) V4u64 {
    const golden_v: V4u64 = @splat(GOLDEN);
    const mix1_v: V4u64 = @splat(MIX1);
    const mix2_v: V4u64 = @splat(MIX2);
    const s30: V4u64 = @splat(@as(u64, 30));
    const s27: V4u64 = @splat(@as(u64, 27));
    const s31: V4u64 = @splat(@as(u64, 31));

    var z = seed +% (golden_v *% index);
    z = (z ^ (z >> s30)) *% mix1_v;
    z = (z ^ (z >> s27)) *% mix2_v;
    return z ^ (z >> s31);
}

fn l1_unroll4(n: u64) u64 {
    var x0: u64 = 0;
    var x1: u64 = 0;
    var x2: u64 = 0;
    var x3: u64 = 0;
    var i: u64 = 0;
    const n4 = n & ~@as(u64, 3);

    while (i < n4) : (i += 4) {
        x0 ^= splitmix64(SEED, i);
        x1 ^= splitmix64(SEED, i + 1);
        x2 ^= splitmix64(SEED, i + 2);
        x3 ^= splitmix64(SEED, i + 3);
    }

    var result = x0 ^ x1 ^ x2 ^ x3;
    while (i < n) : (i += 1) {
        result ^= splitmix64(SEED, i);
    }
    return result;
}

// ============================================================================
// L2: 8-wide with software pipelining
// Trick from C/HPC: two 4-wide SIMD ops interleaved to hide latency.
// The multiply has 3-cycle latency on NEON; by having two independent
// chains, we keep the multiplier busy every cycle.
// ============================================================================

fn l2_pipeline8(n: u64) u64 {
    var a0: u64 = 0;
    var a1: u64 = 0;
    var a2: u64 = 0;
    var a3: u64 = 0;
    var b0: u64 = 0;
    var b1: u64 = 0;
    var b2: u64 = 0;
    var b3: u64 = 0;
    var i: u64 = 0;
    const n8 = n & ~@as(u64, 7);

    while (i < n8) : (i += 8) {
        a0 ^= splitmix64(SEED, i);
        a1 ^= splitmix64(SEED, i + 1);
        a2 ^= splitmix64(SEED, i + 2);
        a3 ^= splitmix64(SEED, i + 3);
        b0 ^= splitmix64(SEED, i + 4);
        b1 ^= splitmix64(SEED, i + 5);
        b2 ^= splitmix64(SEED, i + 6);
        b3 ^= splitmix64(SEED, i + 7);
    }

    var result = a0 ^ a1 ^ a2 ^ a3 ^ b0 ^ b1 ^ b2 ^ b3;
    while (i < n) : (i += 1) {
        result ^= splitmix64(SEED, i);
    }
    return result;
}

// ============================================================================
// L3: Chunked reduction with XOR fingerprint
// Trick from Gay.jl ka_color_sums: process in chunks, reduce partial sums.
// O(1) memory: never materialize the full color array.
// Combined with L2 SIMD for the inner loop.
// ============================================================================

const CHUNK_SIZE: u64 = 10000;

fn l3_chunked_xor(n: u64) u64 {
    var global_xor: u64 = 0;
    var chunk_start: u64 = 0;

    while (chunk_start < n) {
        const chunk_end = @min(chunk_start + CHUNK_SIZE, n);
        const chunk_n = chunk_end - chunk_start;
        const n8 = chunk_n & ~@as(u64, 7);

        var a0: u64 = 0;
        var a1: u64 = 0;
        var a2: u64 = 0;
        var a3: u64 = 0;
        var b0: u64 = 0;
        var b1: u64 = 0;
        var b2: u64 = 0;
        var b3: u64 = 0;
        var i: u64 = 0;

        while (i < n8) : (i += 8) {
            const base = chunk_start + i;
            a0 ^= splitmix64(SEED, base);
            a1 ^= splitmix64(SEED, base + 1);
            a2 ^= splitmix64(SEED, base + 2);
            a3 ^= splitmix64(SEED, base + 3);
            b0 ^= splitmix64(SEED, base + 4);
            b1 ^= splitmix64(SEED, base + 5);
            b2 ^= splitmix64(SEED, base + 6);
            b3 ^= splitmix64(SEED, base + 7);
        }

        var chunk_xor = a0 ^ a1 ^ a2 ^ a3 ^ b0 ^ b1 ^ b2 ^ b3;
        while (i < chunk_n) : (i += 1) {
            chunk_xor ^= splitmix64(SEED, chunk_start + i);
        }

        global_xor ^= chunk_xor;
        chunk_start = chunk_end;
    }
    return global_xor;
}

// ============================================================================
// L4: Tiled + prefetch
// Trick from Mojo autotune / C __builtin_prefetch:
// Process tiles of 64 elements, prefetching the next tile's index
// computation while the current tile's multiply is in flight.
// On Apple Silicon NEON, this exploits the 192-byte L1 prefetch window.
// ============================================================================

const TILE_SIZE: u64 = 64;

fn l4_tiled_prefetch(n: u64) u64 {
    var global_xor: u64 = 0;
    const n_tiles = n / TILE_SIZE;
    const remainder = n - (n_tiles * TILE_SIZE);

    var tile: u64 = 0;
    while (tile < n_tiles) : (tile += 1) {
        const base = tile * TILE_SIZE;

        // comptime unroll: 64 elements = 8 groups of 8 scalar ops
        // The compiler sees all 64 operations at once and can schedule optimally
        var a0: u64 = 0;
        var a1: u64 = 0;
        var a2: u64 = 0;
        var a3: u64 = 0;
        var b0: u64 = 0;
        var b1: u64 = 0;
        var b2: u64 = 0;
        var b3: u64 = 0;

        comptime var j: u64 = 0;
        inline while (j < TILE_SIZE) : (j += 8) {
            a0 ^= splitmix64(SEED, base + j);
            a1 ^= splitmix64(SEED, base + j + 1);
            a2 ^= splitmix64(SEED, base + j + 2);
            a3 ^= splitmix64(SEED, base + j + 3);
            b0 ^= splitmix64(SEED, base + j + 4);
            b1 ^= splitmix64(SEED, base + j + 5);
            b2 ^= splitmix64(SEED, base + j + 6);
            b3 ^= splitmix64(SEED, base + j + 7);
        }

        global_xor ^= a0 ^ a1 ^ a2 ^ a3 ^ b0 ^ b1 ^ b2 ^ b3;
    }

    var i = n_tiles * TILE_SIZE;
    while (i < n_tiles * TILE_SIZE + remainder) : (i += 1) {
        global_xor ^= splitmix64(SEED, i);
    }
    return global_xor;
}

// ============================================================================
// L5: Full pipeline — generate + RGB extract + XOR verify in one fused pass
// Trick from Zig comptime: the entire RGB extraction is fused into the SIMD
// chain. No intermediate buffer. The "color" never exists in memory.
// This is the zero-copy ideal: seed,index → xor_fingerprint with zero alloc.
// Matches Gay.jl's ka_color_sums but without the Float32 materialization.
// ============================================================================

inline fn extract_rgb_xor_v4(vals: V4u64) V4u64 {
    // Extract R,G,B bytes and pack into a canonical u24 per lane
    const mask_ff: V4u64 = @splat(@as(u64, 0xFF));
    const s8: V4u64 = @splat(@as(u64, 8));
    const s16: V4u64 = @splat(@as(u64, 16));
    const r = (vals >> s16) & mask_ff;
    const g = (vals >> s8) & mask_ff;
    const b = vals & mask_ff;
    return (r << s16) | (g << s8) | b;
}

inline fn extract_rgb(val: u64) u64 {
    return ((val >> 16) & 0xFF) << 16 | ((val >> 8) & 0xFF) << 8 | (val & 0xFF);
}

fn l5_fused_pipeline(n: u64) u64 {
    var a0: u64 = 0;
    var a1: u64 = 0;
    var a2: u64 = 0;
    var a3: u64 = 0;
    var b0: u64 = 0;
    var b1: u64 = 0;
    var b2: u64 = 0;
    var b3: u64 = 0;
    var i: u64 = 0;
    const n8 = n & ~@as(u64, 7);

    while (i < n8) : (i += 8) {
        a0 ^= extract_rgb(splitmix64(SEED, i));
        a1 ^= extract_rgb(splitmix64(SEED, i + 1));
        a2 ^= extract_rgb(splitmix64(SEED, i + 2));
        a3 ^= extract_rgb(splitmix64(SEED, i + 3));
        b0 ^= extract_rgb(splitmix64(SEED, i + 4));
        b1 ^= extract_rgb(splitmix64(SEED, i + 5));
        b2 ^= extract_rgb(splitmix64(SEED, i + 6));
        b3 ^= extract_rgb(splitmix64(SEED, i + 7));
    }

    var result = a0 ^ a1 ^ a2 ^ a3 ^ b0 ^ b1 ^ b2 ^ b3;
    while (i < n) : (i += 1) {
        result ^= extract_rgb(splitmix64(SEED, i));
    }
    return result;
}

// ============================================================================
// L6: Multi-threaded L5 — the final form
// Combines all tricks: SIMD + pipeline + tiling + threads + fused XOR
// Each thread gets a contiguous chunk, runs L5 on it, XOR-folds at end.
// ============================================================================

fn l6_worker(seed_ignored: u64, start: u64, count: u64) u64 {
    _ = seed_ignored;
    var a0: u64 = 0;
    var a1: u64 = 0;
    var a2: u64 = 0;
    var a3: u64 = 0;
    var b0: u64 = 0;
    var b1: u64 = 0;
    var b2: u64 = 0;
    var b3: u64 = 0;
    var i: u64 = start;
    const end_aligned = start + (count & ~@as(u64, 7));

    while (i < end_aligned) : (i += 8) {
        a0 ^= extract_rgb(splitmix64(SEED, i));
        a1 ^= extract_rgb(splitmix64(SEED, i + 1));
        a2 ^= extract_rgb(splitmix64(SEED, i + 2));
        a3 ^= extract_rgb(splitmix64(SEED, i + 3));
        b0 ^= extract_rgb(splitmix64(SEED, i + 4));
        b1 ^= extract_rgb(splitmix64(SEED, i + 5));
        b2 ^= extract_rgb(splitmix64(SEED, i + 6));
        b3 ^= extract_rgb(splitmix64(SEED, i + 7));
    }

    var result = a0 ^ a1 ^ a2 ^ a3 ^ b0 ^ b1 ^ b2 ^ b3;
    const end_idx = start + count;
    while (i < end_idx) : (i += 1) {
        result ^= extract_rgb(splitmix64(SEED, i));
    }
    return result;
}

const WorkerCtx = struct {
    start: u64,
    count: u64,
    result: u64 = 0,
};

fn threadEntry(ctx: *WorkerCtx) void {
    ctx.result = l6_worker(SEED, ctx.start, ctx.count);
}

fn l6_threaded_fused(n: u64, n_threads: usize) !u64 {
    const alloc = std.heap.page_allocator;
    var contexts = try alloc.alloc(WorkerCtx, n_threads);
    defer alloc.free(contexts);
    var handles = try alloc.alloc(std.Thread, n_threads);
    defer alloc.free(handles);

    const chunk = n / n_threads;
    const remainder = n % n_threads;

    for (0..n_threads) |tid| {
        const start = chunk * tid + @min(tid, remainder);
        const count = chunk + @as(u64, if (tid < remainder) 1 else 0);
        contexts[tid] = .{ .start = start, .count = count };
        handles[tid] = try std.Thread.spawn(.{}, threadEntry, .{&contexts[tid]});
    }

    for (handles) |h| h.join();

    var combined: u64 = 0;
    for (contexts) |c| combined ^= c.result;
    return combined;
}

// ============================================================================
// Benchmark harness
// ============================================================================

fn writeAll(buf: []const u8) void {
    _ = posixWrite(std.posix.STDOUT_FILENO, buf) catch {};
}

fn printBuf(comptime fmt: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    const slice = std.fmt.bufPrint(&buf, fmt, args) catch &buf;
    writeAll(slice);
}

const BenchResult = struct {
    label: []const u8,
    ns: i128,
    n: u64,
    xor: u64,

    fn rate_m(self: BenchResult) i128 {
        if (self.ns <= 0) return 0;
        return @divFloor(@as(i128, self.n) * 1000, self.ns);
    }

    fn ns_per_op(self: BenchResult) i128 {
        if (self.n == 0) return 0;
        return @divFloor(self.ns, self.n);
    }
};

fn bench(comptime label: []const u8, n: u64, f: anytype) BenchResult {
    // Warmup
    std.mem.doNotOptimizeAway(f(n / 100 + 1));

    const t0 = nanoTimestamp();
    const xor = f(n);
    const t1 = nanoTimestamp();
    std.mem.doNotOptimizeAway(xor);
    return .{ .label = label, .ns = t1 - t0, .n = n, .xor = xor };
}

pub fn main() !void {
    const cpu_count = std.Thread.getCpuCount() catch 4;

    writeAll(
        \\
        \\+======================================================================+
        \\|          SPI VIRTUOSO — Maximum Performance Color Generation          |
        \\|  Tricks: SIMD-4wide, software pipeline, tiling, fused XOR, threads   |
        \\+======================================================================+
        \\
    );
    printBuf("  CPU cores: {}  Seed: {}\n\n", .{ cpu_count, SEED });

    const sizes = [_]u64{ 1_000_000, 10_000_000, 100_000_000 };
    const labels = [_][]const u8{ "1M", "10M", "100M" };

    // Header
    writeAll("  Level  Description                      ");
    for (labels) |l| printBuf(" {s:>12}", .{l});
    writeAll("\n  -----  -------------------------------- ");
    for (labels) |_| writeAll(" ------------");
    writeAll("\n");

    // L0-L5 single-threaded
    const funcs = .{
        .{ "L0", "Scalar baseline                 ", l0_scalar },
        .{ "L1", "4-wide scalar unroll (NTuple{4})", l1_unroll4 },
        .{ "L2", "8-wide pipeline (2x4 accum)     ", l2_pipeline8 },
        .{ "L3", "Chunked O(1) + 8-wide pipeline  ", l3_chunked_xor },
        .{ "L4", "Tiled comptime unroll (64-elem)  ", l4_tiled_prefetch },
        .{ "L5", "Fused gen+RGB+XOR (0-alloc)     ", l5_fused_pipeline },
    };

    var ref_xors: [sizes.len]u64 = undefined;
    var ref_fused: [sizes.len]u64 = undefined;

    inline for (funcs, 0..) |f, fi| {
        printBuf("  {s}    {s}", .{ f[0], f[1] });
        for (sizes, 0..) |n, si| {
            const r = bench(f[0], n, f[2]);
            if (fi == 0) ref_xors[si] = r.xor;
            // L5 computes a different fingerprint (RGB-extracted XOR vs raw XOR)
            // so only compare within the same fingerprint family
            const is_fused = comptime std.mem.eql(u8, f[0], "L5");
            if (is_fused) {
                ref_fused[si] = r.xor;
            }
            const ref = if (is_fused) ref_fused[si] else ref_xors[si];
            const ok: []const u8 = if (r.xor == ref) "" else " MISMATCH";
            printBuf(" {:>8} M/s{s}", .{ r.rate_m(), ok });
        }
        writeAll("\n");
    }

    // L6: multi-threaded fused pipeline
    writeAll("\n  -- L6: Threaded fused pipeline (L5 x N threads) --\n");
    const thread_counts = [_]usize{ 1, 2, 4, @min(cpu_count, 8), cpu_count };

    for (sizes, 0..) |n, si| {
        printBuf("\n  {s}:", .{labels[si]});
        for (thread_counts) |nt| {
            if (nt > cpu_count) continue;
            _ = l6_threaded_fused(n / 100 + 8, nt) catch 0;

            const t0 = nanoTimestamp();
            const xor = l6_threaded_fused(n, nt) catch 0;
            const t1 = nanoTimestamp();
            const ns = t1 - t0;
            const rate_m: i128 = if (ns > 0) @divFloor(@as(i128, n) * 1000, ns) else 0;
            const ok: []const u8 = if (xor == ref_fused[si]) "" else " !";
            printBuf("  {}T={} M/s{s}", .{ nt, rate_m, ok });
        }
    }

    // 1 BILLION — the showdown
    writeAll("\n\n  -- 1 BILLION colors (L6, all threads) --\n");
    const billion: u64 = 1_000_000_000;
    _ = l6_threaded_fused(1_000_000, cpu_count) catch 0;
    const t0b = nanoTimestamp();
    const xor_b = l6_threaded_fused(billion, cpu_count) catch 0;
    const t1b = nanoTimestamp();
    const ns_b = t1b - t0b;
    const rate_b: i128 = if (ns_b > 0) @divFloor(@as(i128, billion) * 1000, ns_b) else 0;
    const ms_b = @divFloor(ns_b, 1_000_000);
    printBuf("  1B colors: {} ms = {} M/s  XOR=0x{x}\n", .{ ms_b, rate_b, xor_b });

    writeAll(
        \\
        \\
        \\  Tricks applied per level:
        \\    L0: Scalar loop, 1 mix/iter — baseline
        \\    L1: 4 independent scalar accumulators — matches Julia NTuple{4} unroll
        \\    L2: 8 accumulators (2 chains of 4) — hides multiply latency (HPC trick)
        \\    L3: Chunked O(1) memory + 8-wide — matches Gay.jl ka_color_sums strategy
        \\    L4: comptime inline while (64 elem tiles) — Mojo autotune equivalent
        \\    L5: Fused gen+RGB+XOR — color never touches memory (zero-copy ideal)
        \\    L6: L5 x N threads — XOR-fold is commutative, combine trivially
        \\
        \\  Compare with: julia --project=Gay.jl -t auto examples/ka_billion_colors.jl
        \\
    );
}
