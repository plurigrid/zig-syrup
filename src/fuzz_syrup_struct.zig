//! Structure-aware (grammar) fuzzer for the Syrup codec.
//!
//! The random-byte fuzzer (`fuzz_syrup_random.zig`) rejects ~91% of inputs at
//! the first byte, so deep container / record / bigint paths are barely reached.
//! This harness instead GENERATES valid Syrup values, encodes them, and attacks
//! the result — the classic high-yield structure-aware technique:
//!
//!   P1 fixpoint  — a generated value's canonical encoding must decode and
//!                  re-encode byte-identically (exercises encode+decode on deep,
//!                  well-formed trees rather than on rejected garbage).
//!   P2 mutation  — flip random bytes in a VALID encoding, then decode. Near-miss
//!                  inputs get far deeper into the parser than random noise before
//!                  failing, which is exactly where length/index bugs hide.
//!   P3 truncation— decode every kind of prefix of a valid encoding. Highest-yield
//!                  attack on a length-prefixed format: each cut lands mid-field.
//!
//! P2/P3 assert only crash-safety (any error is fine, a panic is not). P1 asserts
//! correctness. Runs as a plain multi-threaded ReleaseSafe test — no coverage
//! runtime, so it works on macOS where zig's ELF-only `--fuzz` cannot.
const std = @import("std");
const syrup = @import("syrup");

const MAX_THREADS = 64;
/// CI default; soak runs raise this.
const ITERS_PER_THREAD: u64 = 200_000;
/// Generation depth. Far below Parser.MAX_DEPTH (256) — this fuzzer is about
/// shape variety, not depth exhaustion (that has its own regression test).
const MAX_GEN_DEPTH: u8 = 5;

var n_generated: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
var n_fixpoint: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
var n_rejected: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
var n_mutated: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
var n_truncated: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
var failed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

fn workerCount() usize {
    return @min(MAX_THREADS, @max(1, std.Thread.getCpuCount() catch 1));
}

fn lessThanValue(_: void, a: syrup.Value, b: syrup.Value) bool {
    return a.compare(b) == .lt;
}

fn lessThanEntry(_: void, a: syrup.Value.DictEntry, b: syrup.Value.DictEntry) bool {
    return a.key.compare(b.key) == .lt;
}

/// Generate a random well-formed Syrup value. Sets and dictionaries are sorted
/// and deduped so they satisfy the decoder's canonical-order requirement —
/// otherwise every container would bounce off NotCanonicalOrder and the deep
/// paths would never run.
fn genValue(rnd: std.Random, a: std.mem.Allocator, depth: u8) error{OutOfMemory}!syrup.Value {
    const kind = if (depth == 0) rnd.uintLessThan(u8, 11) else rnd.uintLessThan(u8, 17);
    switch (kind) {
        0 => return .{ .undefined = {} },
        1 => return .{ .null = {} },
        2 => return .{ .bool = rnd.boolean() },
        3 => return .{ .integer = rnd.int(i64) },
        4 => {
            // Minimal big-endian magnitude (leading byte nonzero). Lengths span
            // both encoder regimes: <=16 bytes emits decimal, >16 emits B-form.
            const len = 1 + rnd.uintLessThan(usize, 24);
            const mag = try a.alloc(u8, len);
            for (mag) |*m| m.* = rnd.int(u8);
            mag[0] = 1 + rnd.uintLessThan(u8, 255);
            return .{ .bigint = .{ .magnitude = mag, .negative = rnd.boolean() } };
        },
        5 => return .{ .float32 = @bitCast(rnd.int(u32)) },
        6 => return .{ .float = @bitCast(rnd.int(u64)) },
        7, 8, 9 => {
            const len = rnd.uintLessThan(usize, 24);
            const s = try a.alloc(u8, len);
            for (s) |*c| c.* = rnd.int(u8);
            return switch (kind) {
                7 => .{ .bytes = s },
                8 => .{ .string = s },
                else => .{ .symbol = s },
            };
        },
        10 => return .{ .list = &.{} },
        11 => {
            const n = rnd.uintLessThan(usize, 5);
            const items = try a.alloc(syrup.Value, n);
            for (items) |*it| it.* = try genValue(rnd, a, depth - 1);
            return .{ .list = items };
        },
        12 => {
            const n = rnd.uintLessThan(usize, 5);
            const items = try a.alloc(syrup.Value, n);
            for (items) |*it| it.* = try genValue(rnd, a, depth - 1);
            std.mem.sort(syrup.Value, items, {}, lessThanValue);
            // Dedupe: canonical sets are strictly increasing.
            var w: usize = 0;
            for (items) |it| {
                if (w == 0 or items[w - 1].compare(it) != .eq) {
                    items[w] = it;
                    w += 1;
                }
            }
            return .{ .set = items[0..w] };
        },
        13 => {
            const n = rnd.uintLessThan(usize, 5);
            const entries = try a.alloc(syrup.Value.DictEntry, n);
            for (entries) |*e| e.* = .{
                .key = try genValue(rnd, a, depth - 1),
                .value = try genValue(rnd, a, depth - 1),
            };
            std.mem.sort(syrup.Value.DictEntry, entries, {}, lessThanEntry);
            var w: usize = 0;
            for (entries) |e| {
                if (w == 0 or entries[w - 1].key.compare(e.key) != .eq) {
                    entries[w] = e;
                    w += 1;
                }
            }
            return .{ .dictionary = entries[0..w] };
        },
        14 => {
            const label = try a.create(syrup.Value);
            const slen = rnd.uintLessThan(usize, 8);
            const sym = try a.alloc(u8, slen);
            for (sym) |*c| c.* = 'a' + rnd.uintLessThan(u8, 26);
            label.* = .{ .symbol = sym };
            const n = rnd.uintLessThan(usize, 4);
            const fields = try a.alloc(syrup.Value, n);
            for (fields) |*f| f.* = try genValue(rnd, a, depth - 1);
            return .{ .record = .{ .label = label, .fields = fields } };
        },
        15 => {
            const tag = try a.alloc(u8, rnd.uintLessThan(usize, 8));
            for (tag) |*c| c.* = 'a' + rnd.uintLessThan(u8, 26);
            const payload = try a.create(syrup.Value);
            payload.* = try genValue(rnd, a, depth - 1);
            return .{ .tagged = .{ .tag = tag, .payload = payload } };
        },
        else => {
            const message = try a.alloc(u8, rnd.uintLessThan(usize, 8));
            for (message) |*c| c.* = 'a' + rnd.uintLessThan(u8, 26);
            const identifier = try a.alloc(u8, rnd.uintLessThan(usize, 8));
            for (identifier) |*c| c.* = rnd.int(u8);
            const data = try a.create(syrup.Value);
            data.* = try genValue(rnd, a, depth - 1);
            return .{ .@"error" = .{
                .message = message,
                .identifier = identifier,
                .data = data,
            } };
        },
    }
}

fn worker(tid: u64) void {
    // Deterministic per-thread seed → any failure is reproducible from (tid, iter).
    var prng = std.Random.DefaultPrng.init(0x5EED_1234 ^ @as(u64, std.testing.random_seed) ^ (tid *% 0x9E3779B97F4A7C15));
    const rnd = prng.random();

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    var gen: u64 = 0;
    var fix: u64 = 0;
    var rej: u64 = 0;
    var mut: u64 = 0;
    var trunc: u64 = 0;

    var i: u64 = 0;
    while (i < ITERS_PER_THREAD) : (i += 1) {
        if (failed.load(.monotonic)) break;
        _ = arena.reset(.retain_capacity);
        const a = arena.allocator();

        const v = genValue(rnd, a, MAX_GEN_DEPTH) catch continue;
        const b = v.encodeAlloc(a) catch continue;
        gen += 1;

        // P1: canonical byte-fixpoint on a well-formed value.
        if (syrup.decode(b, a)) |v2| {
            const b2 = v2.encodeAlloc(a) catch b;
            if (!std.mem.eql(u8, b, b2)) {
                std.debug.print(
                    "\nSTRUCT FIXPOINT BUG:\n  encoded={x}\n  redecoded={x}\n",
                    .{ b, b2 },
                );
                failed.store(true, .monotonic);
                break;
            }
            fix += 1;
        } else |_| {
            // Generation can still produce something the decoder declines
            // (e.g. an ordering the canonical check rejects). Not a defect.
            rej += 1;
        }

        // P2: mutate a valid encoding — near-miss inputs probe deep parser state.
        if (b.len > 0) {
            const m = a.dupe(u8, b) catch continue;
            const flips = 1 + rnd.uintLessThan(usize, 4);
            var f: usize = 0;
            while (f < flips) : (f += 1) {
                const idx = rnd.uintLessThan(usize, m.len);
                if (rnd.boolean()) {
                    m[idx] = rnd.int(u8); // random byte
                } else {
                    m[idx] ^= @as(u8, 1) << rnd.int(u3); // bit flip (u3 spans 0..7)
                }
            }
            _ = syrup.decode(m, a) catch {};
            mut += 1;
        }

        // P3: truncation — every cut lands mid-field in a length-prefixed format.
        const cut = rnd.uintLessThan(usize, b.len + 1);
        _ = syrup.decode(b[0..cut], a) catch {};
        trunc += 1;
    }

    _ = n_generated.fetchAdd(gen, .monotonic);
    _ = n_fixpoint.fetchAdd(fix, .monotonic);
    _ = n_rejected.fetchAdd(rej, .monotonic);
    _ = n_mutated.fetchAdd(mut, .monotonic);
    _ = n_truncated.fetchAdd(trunc, .monotonic);
}

test "structure-aware fuzz: generate, round-trip, mutate, truncate" {
    const thread_count = workerCount();
    const threads = try std.testing.allocator.alloc(std.Thread, thread_count);
    defer std.testing.allocator.free(threads);
    for (threads, 0..) |*t, k| t.* = try std.Thread.spawn(.{}, worker, .{@as(u64, k)});
    for (threads) |t| t.join();

    const gen = n_generated.load(.monotonic);
    const fix = n_fixpoint.load(.monotonic);
    const rej = n_rejected.load(.monotonic);
    const mut = n_mutated.load(.monotonic);
    const trunc = n_truncated.load(.monotonic);
    std.debug.print(
        "\nstruct-fuzz: seed=0x{x} {d} values generated | {d} fixpoints, {d} declined | {d} mutations, {d} truncations survived | {d} threads\n",
        .{ std.testing.random_seed, gen, fix, rej, mut, trunc, thread_count },
    );

    try std.testing.expect(!failed.load(.monotonic));
    // Proves the run was real: every generated value was fixpoint-checked, and
    // the mutation/truncation attacks actually executed.
    try std.testing.expect(gen == fix + rej);
    try std.testing.expect(gen > 0 and trunc > 0 and mut > 0);
    // The generator must actually produce canonical values, not just rejects —
    // if this trips, the grammar drifted and coverage silently collapsed.
    try std.testing.expect(fix * 10 > gen * 9);
}
