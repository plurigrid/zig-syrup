//! macOS-native random / property fuzzer for the Syrup decoder.
//!
//! Why this exists: zig's coverage-guided `--fuzz` runtime is ELF-only and does
//! not work on macOS (0.17-dev crashes in `fuzzer.zig ensureCorpusLoaded`; 0.15.2
//! crashes parsing the Mach-O test binary as ELF: `InvalidElfMagic` in
//! `Build/Fuzz.zig`). This harness is the working alternative on Darwin: N worker
//! threads pound `decode()` with random + structural-biased bytes in a ReleaseSafe
//! binary, so any overflow / bounds / UB / unreachable panics with a stack trace.
//!
//! It is a CRASH-SAFETY property test: for arbitrary input, `decode` must return a
//! value or an error — never crash. Memory is hard-bounded (a per-thread
//! FixedBufferAllocator) so adversarial length prefixes return `OutOfMemory`
//! instead of thrashing, and recursion is bounded by `Parser.MAX_DEPTH`.
//!
//! Run: `zig build fuzz-syrup-random`  (defaults below, ~a few seconds)
//! Longer soak: bump ITERS_PER_THREAD, or loop the step.
const std = @import("std");
const syrup = @import("syrup");

const THREADS = 10;
/// CI default. A soak run raises this; 30M/thread ran clean in ~20s locally.
const ITERS_PER_THREAD: u64 = 250_000;
const MAX_INPUT = 512;
const ARENA_BYTES = 16 * 1024 * 1024;

var total_ok: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
var total_err: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);

fn worker(tid: u64) void {
    // Deterministic per-thread seed → any crash is reproducible from (tid, iter).
    var prng = std.Random.DefaultPrng.init(0xDEADBEEF ^ (tid *% 0x9E3779B97F4A7C15));
    const rnd = prng.random();

    const backing = std.heap.page_allocator.alloc(u8, ARENA_BYTES) catch return;
    defer std.heap.page_allocator.free(backing);
    var buf: [MAX_INPUT]u8 = undefined;

    // Structural tokens the grammar keys on ([ ] { } # < > : digits sign quote
    // bool-ish). Biasing toward these reaches container / record / length-prefix
    // paths far faster than uniform random bytes.
    const toks = "[]{}#<>:0123456789+-\"'ftFTID ";

    var i: u64 = 0;
    var ok: u64 = 0;
    var er: u64 = 0;
    while (i < ITERS_PER_THREAD) : (i += 1) {
        const n = rnd.uintLessThan(usize, MAX_INPUT);
        for (buf[0..n]) |*b| {
            b.* = if (rnd.boolean())
                toks[rnd.uintLessThan(usize, toks.len)]
            else
                rnd.int(u8);
        }
        var fba = std.heap.FixedBufferAllocator.init(backing);
        const v = syrup.decode(buf[0..n], fba.allocator()) catch {
            er += 1;
            continue;
        };
        _ = v; // decoded without crashing — the property under test
        ok += 1;
    }
    _ = total_ok.fetchAdd(ok, .monotonic);
    _ = total_err.fetchAdd(er, .monotonic);
}

test "random fuzz: decode never crashes on arbitrary input" {
    var threads: [THREADS]std.Thread = undefined;
    for (&threads, 0..) |*t, k| t.* = try std.Thread.spawn(.{}, worker, .{@as(u64, k)});
    for (&threads) |t| t.join();
    const ok = total_ok.load(.monotonic);
    const er = total_err.load(.monotonic);
    std.debug.print(
        "\nrandom-fuzz survived {d} inputs ({d} decoded, {d} rejected) across {d} threads\n",
        .{ ok + er, ok, er, THREADS },
    );
    // Passing this proves every input actually ran (a no-op body cannot satisfy it).
    try std.testing.expect(ok + er == THREADS * ITERS_PER_THREAD);
}
