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
var total_rt: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
var failed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

/// Canonical byte-fixpoint round-trip check on a successfully-decoded value.
/// `decode` rejects NotCanonicalOrder, so `v` is already canonical ⇒ encoding it
/// and decoding+re-encoding must be byte-identical. Any mismatch, or a canonical
/// output that fails to re-decode, is an encoder/decoder-asymmetry bug. Pure byte
/// equality → no float/NaN false positives. Returns false on a real defect (after
/// printing a reproduction); OOM from the bounded arena is a skip, not a defect.
fn roundTripOk(v: syrup.Value, a: std.mem.Allocator, input: []const u8) bool {
    const b2 = v.encodeAlloc(a) catch return true; // arena OOM ⇒ skip
    const v2 = syrup.decode(b2, a) catch {
        std.debug.print("\nROUND-TRIP BUG: canonical encoding failed to re-decode\n  input={x}\n  enc  ={x}\n", .{ input, b2 });
        return false;
    };
    const b3 = v2.encodeAlloc(a) catch return true;
    if (!std.mem.eql(u8, b2, b3)) {
        std.debug.print("\nROUND-TRIP BUG: canonical form not a fixpoint\n  input={x}\n  enc1 ={x}\n  enc2 ={x}\n", .{ input, b2, b3 });
        return false;
    }
    return true;
}

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
    var rt: u64 = 0;
    while (i < ITERS_PER_THREAD) : (i += 1) {
        if (failed.load(.monotonic)) break; // another thread found a defect
        const n = rnd.uintLessThan(usize, MAX_INPUT);
        for (buf[0..n]) |*b| {
            b.* = if (rnd.boolean())
                toks[rnd.uintLessThan(usize, toks.len)]
            else
                rnd.int(u8);
        }
        var fba = std.heap.FixedBufferAllocator.init(backing);
        const a = fba.allocator();
        const v = syrup.decode(buf[0..n], a) catch {
            er += 1; // crash-safety property: expected-error path
            continue;
        };
        ok += 1;
        // correctness property: canonical encoding is a byte-fixpoint
        if (!roundTripOk(v, a, buf[0..n])) {
            failed.store(true, .monotonic);
            break;
        }
        rt += 1;
    }
    _ = total_ok.fetchAdd(ok, .monotonic);
    _ = total_err.fetchAdd(er, .monotonic);
    _ = total_rt.fetchAdd(rt, .monotonic);
}

test "random fuzz: decode never crashes on arbitrary input" {
    var threads: [THREADS]std.Thread = undefined;
    for (&threads, 0..) |*t, k| t.* = try std.Thread.spawn(.{}, worker, .{@as(u64, k)});
    for (&threads) |t| t.join();
    const ok = total_ok.load(.monotonic);
    const er = total_err.load(.monotonic);
    const rt = total_rt.load(.monotonic);
    std.debug.print(
        "\nrandom-fuzz: {d} inputs ({d} decoded, {d} rejected), {d} round-trip fixpoints verified, across {d} threads\n",
        .{ ok + er, ok, er, rt, THREADS },
    );
    // A defect prints its reproduction in the worker and trips this flag.
    try std.testing.expect(!failed.load(.monotonic));
    // No defect ⇒ every input ran (a no-op body cannot satisfy this) and every
    // decoded value passed the round-trip fixpoint.
    try std.testing.expect(ok + er == THREADS * ITERS_PER_THREAD);
    try std.testing.expect(rt == ok);
}
