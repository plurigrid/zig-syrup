//! fuzz_parallel.zig — N-thread bounded-memory fuzz driver for the Syrup wire layer.
//!
//! Why not `zig build fuzz-syrup --fuzz`: that maintains a growing on-disk corpus and
//! forks per fuzz test. Disk is the scarce resource here, and I want *all* targets
//! saturating all cores simultaneously. This driver is zero-disk and zero-heap-growth:
//! each thread owns a slab + FixedBufferAllocator reset every iteration.
//!
//! Determinism: every input is a pure function of (base_seed, thread_id, iteration)
//! via SplitMix64 (the repo's own SPI idiom). A failure prints its coordinates and is
//! replayable single-threaded — the counterexample is the deliverable, not the count.
//!
//! Oracle discipline: structural equality is implemented HERE, not borrowed from
//! syrup.Value.compare. Code under test must not be its own oracle.
//!
//! Targets:
//!   0 decode(arbitrary bytes)      — totality: no crash, no hang, bounded alloc
//!   1 decode(grammar-biased bytes) — same, but reaching deeper into the parser
//!   2 encode∘decode round-trip     — structural identity over generated Value trees
//!   3 encodedSize == encodeAlloc   — size oracle agrees with the encoder (trees, not just ints)
//!   4 canonical idempotence        — decode→encode→decode→encode is byte-stable
//!   5 attest-frame mutation        — every single-byte flip must be VISIBLE (no silent accept)
//!   6 FrameAccumulator chunking    — framed payloads survive arbitrary chunk splits, in order

const std = @import("std");
const syrup = @import("syrup");
const mf = @import("message_frame");

const Allocator = std.mem.Allocator;

// ---------------------------------------------------------------- SplitMix64

const Rng = struct {
    s: u64,
    fn init(seed: u64) Rng {
        return .{ .s = seed };
    }
    fn next(self: *Rng) u64 {
        self.s +%= 0x9e3779b97f4a7c15;
        var z = self.s;
        z = (z ^ (z >> 30)) *% 0xbf58476d1ce4e5b9;
        z = (z ^ (z >> 27)) *% 0x94d049bb133111eb;
        return z ^ (z >> 31);
    }
    fn below(self: *Rng, n: u64) u64 {
        return if (n == 0) 0 else self.next() % n;
    }
};

// ---------------------------------------------------------------- structural eql

fn eqlSlice(a: []const syrup.Value, b: []const syrup.Value) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (!eql(x, y)) return false;
    return true;
}

/// Numeric view of the two integer REPRESENTATIONS. Syrup has one integer form on the
/// wire (`n+`/`n-`), so a `.bigint` whose magnitude fits i64 canonically encodes as an
/// integer and decodes back as `.integer`. That is value-preserving normalization, so
/// the oracle must compare VALUES here, not representations. (First fuzz run flagged
/// 425/425 bigints; the bug was this function, not the codec.)
fn asInt(v: syrup.Value) ?i128 {
    return switch (v) {
        .integer => |i| @as(i128, i),
        .bigint => |b| blk: {
            if (b.magnitude.len == 0 or b.magnitude.len > 15) break :blk null; // i128 headroom
            var m: i128 = 0;
            for (b.magnitude) |c| m = (m << 8) | c;
            break :blk if (b.negative) -m else m;
        },
        else => null,
    };
}

fn eql(a: syrup.Value, b: syrup.Value) bool {
    if (asInt(a)) |x| {
        if (asInt(b)) |y| return x == y;
    }
    if (@as(std.meta.Tag(syrup.Value), a) != @as(std.meta.Tag(syrup.Value), b)) return false;
    return switch (a) {
        .undefined, .null => true,
        .bool => a.bool == b.bool,
        .integer => a.integer == b.integer,
        .bigint => a.bigint.negative == b.bigint.negative and
            std.mem.eql(u8, a.bigint.magnitude, b.bigint.magnitude),
        // bit-compare so NaN payloads are exact rather than always-unequal
        .float32 => @as(u32, @bitCast(a.float32)) == @as(u32, @bitCast(b.float32)),
        .float => @as(u64, @bitCast(a.float)) == @as(u64, @bitCast(b.float)),
        .bytes => std.mem.eql(u8, a.bytes, b.bytes),
        .string => std.mem.eql(u8, a.string, b.string),
        .symbol => std.mem.eql(u8, a.symbol, b.symbol),
        .list => eqlSlice(a.list, b.list),
        .set => eqlSlice(a.set, b.set),
        .dictionary => blk: {
            if (a.dictionary.len != b.dictionary.len) break :blk false;
            for (a.dictionary, b.dictionary) |x, y| {
                if (!eql(x.key, y.key) or !eql(x.value, y.value)) break :blk false;
            }
            break :blk true;
        },
        .record => eql(a.record.label.*, b.record.label.*) and
            eqlSlice(a.record.fields, b.record.fields),
        .tagged => std.mem.eql(u8, a.tagged.tag, b.tagged.tag) and
            eql(a.tagged.payload.*, b.tagged.payload.*),
        .@"error" => std.mem.eql(u8, a.@"error".message, b.@"error".message) and
            std.mem.eql(u8, a.@"error".identifier, b.@"error".identifier) and
            eql(a.@"error".data.*, b.@"error".data.*),
    };
}

// ---------------------------------------------------------------- generators

fn genBlob(rng: *Rng, a: Allocator, max: usize, printable: bool) ![]u8 {
    const n = rng.below(max + 1);
    const buf = try a.alloc(u8, n);
    for (buf) |*c| {
        c.* = if (printable)
            @intCast(0x61 + rng.below(26)) // ascii a-z: keeps strings valid UTF-8
        else
            @intCast(rng.below(256));
    }
    return buf;
}

/// Atoms only at depth 0; containers above. Sets/dicts are canonical BY CONSTRUCTION
/// (ascending small integer keys) so any NotCanonicalOrder from the decoder is a real
/// finding, not generator noise. Bigints are normalized (no leading zero, non-empty)
/// because the encoder normalizes and a denormal input would be a fake mismatch.
fn genValue(rng: *Rng, a: Allocator, depth: u8) anyerror!syrup.Value {
    const atom_kinds: u64 = 10;
    const kind = if (depth == 0) rng.below(atom_kinds) else rng.below(atom_kinds + 6);
    return switch (kind) {
        0 => .{ .bool = rng.below(2) == 1 },
        1 => .{ .integer = @bitCast(rng.next()) },
        2 => .{ .integer = @as(i64, @intCast(rng.below(1000))) },
        3 => .{ .float = @bitCast(rng.next()) },
        4 => .{ .float32 = @bitCast(@as(u32, @truncate(rng.next()))) },
        5 => .{ .bytes = try genBlob(rng, a, 24, false) },
        6 => .{ .string = try genBlob(rng, a, 24, true) },
        7 => .{ .symbol = try genBlob(rng, a, 12, true) },
        8 => .{ .null = {} },
        9 => blk: {
            // 1..16 bytes: deliberately straddles the i64 boundary so the genuinely-big
            // path (which cannot normalize to `.integer`) is actually exercised.
            const n = 1 + rng.below(16);
            const mag = try a.alloc(u8, n);
            for (mag) |*c| c.* = @intCast(rng.below(256));
            mag[0] = @intCast(1 + rng.below(255)); // no leading zero
            break :blk .{ .bigint = .{ .magnitude = mag, .negative = rng.below(2) == 1 } };
        },
        10 => blk: { // list
            const n = rng.below(5);
            const items = try a.alloc(syrup.Value, n);
            for (items) |*it| it.* = try genValue(rng, a, depth - 1);
            break :blk .{ .list = items };
        },
        11 => blk: { // set — ascending distinct small ints == canonical
            const n = rng.below(6);
            const items = try a.alloc(syrup.Value, n);
            for (items, 0..) |*it, i| it.* = .{ .integer = @intCast(i) };
            break :blk .{ .set = items };
        },
        12 => blk: { // dictionary — ascending distinct small int keys == canonical
            const n = rng.below(6);
            const entries = try a.alloc(syrup.Value.DictEntry, n);
            for (entries, 0..) |*e, i| {
                e.* = .{ .key = .{ .integer = @intCast(i) }, .value = try genValue(rng, a, depth - 1) };
            }
            break :blk .{ .dictionary = entries };
        },
        13 => blk: { // record
            const label = try a.create(syrup.Value);
            label.* = .{ .symbol = try genBlob(rng, a, 10, true) };
            const n = rng.below(4);
            const fields = try a.alloc(syrup.Value, n);
            for (fields) |*f| f.* = try genValue(rng, a, depth - 1);
            break :blk .{ .record = .{ .label = label, .fields = fields } };
        },
        14 => blk: { // tagged
            const payload = try a.create(syrup.Value);
            payload.* = try genValue(rng, a, depth - 1);
            break :blk .{ .tagged = .{ .tag = try genBlob(rng, a, 8, true), .payload = payload } };
        },
        else => blk: { // error
            const data = try a.create(syrup.Value);
            data.* = try genValue(rng, a, depth - 1);
            break :blk .{ .@"error" = .{
                .message = try genBlob(rng, a, 12, true),
                .identifier = try genBlob(rng, a, 8, true),
                .data = data,
            } };
        },
    };
}

/// Grammar-biased bytes: real Syrup is length-prefixed, so uniform random bytes almost
/// never get past the first marker. Emit plausible prefixes to reach deeper parser states.
fn genGrammarish(rng: *Rng, a: Allocator) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    const tokens = rng.below(14) + 1;
    var i: u64 = 0;
    while (i < tokens) : (i += 1) {
        switch (rng.below(12)) {
            0 => try buf.append(a, 't'),
            1 => try buf.append(a, 'f'),
            2 => try buf.appendSlice(a, "["),
            3 => try buf.appendSlice(a, "]"),
            4 => try buf.appendSlice(a, "{"),
            5 => try buf.appendSlice(a, "}"),
            6 => try buf.appendSlice(a, "#"),
            7 => try buf.appendSlice(a, "$"),
            8 => try buf.appendSlice(a, "<"),
            9 => try buf.appendSlice(a, ">"),
            10 => { // number + marker, length often LYING about the payload
                var tmp: [24]u8 = undefined;
                const n = rng.below(40);
                const s = std.fmt.bufPrint(&tmp, "{d}", .{n}) catch continue;
                try buf.appendSlice(a, s);
                const markers = "+-:\"'";
                try buf.append(a, markers[@intCast(rng.below(markers.len))]);
                const emit = rng.below(n + 1); // deliberately under/over-run
                var k: u64 = 0;
                while (k < emit) : (k += 1) try buf.append(a, @intCast(0x61 + rng.below(26)));
            },
            else => try buf.append(a, @intCast(rng.below(256))),
        }
    }
    return buf.items;
}

// ---------------------------------------------------------------- attest corpus (target 5)

const attest_frames = [_][]const u8{
    "<6'attest7\"n-again4'play1+>",
    "<6'attest7\"n-again7'witness0+>",
    "<6'attest7\"n-again6'coplay1->",
};

// ---------------------------------------------------------------- results

const NT = 7;

const FailKind = enum(u8) {
    none = 0,
    roundtrip_mismatch = 1,
    size_mismatch = 2,
    not_idempotent = 3,
    frame_payload_mismatch = 4,
    silent_mutation = 5,
    unexpected_error = 6,
    frame_count_mismatch = 7,
    accumulator_stuck = 8,
    canonical_rejected = 9,
};

const Res = struct {
    per_target: [NT]u64 = @splat(0),
    fails: u64 = 0,
    skips: u64 = 0,
    first_iter: u64 = 0,
    first_target: u8 = 255,
    first_kind: FailKind = .none,
    thread_seed: u64 = 0,

    fn record(self: *Res, iter: u64, target: u8, kind: FailKind) void {
        self.fails += 1;
        if (self.first_kind == .none) {
            self.first_iter = iter;
            self.first_target = target;
            self.first_kind = kind;
        }
    }
};

// ---------------------------------------------------------------- targets

fn tRoundTrip(rng: *Rng, a: Allocator, res: *Res, iter: u64) void {
    const v = genValue(rng, a, 3) catch {
        res.skips += 1;
        return;
    };
    const enc = v.encodeAlloc(a) catch {
        res.skips += 1;
        return;
    };
    const dec = syrup.decode(enc, a) catch |e| {
        // Failing to decode our OWN encoder's output breaks the retraction property.
        // Only OutOfMemory is a harness limit; everything else is a finding. (Previously
        // this was a silent `skip`, which would have masked exactly this bug class.)
        switch (e) {
            error.OutOfMemory => res.skips += 1,
            error.NotCanonicalOrder => res.record(iter, 2, .canonical_rejected),
            else => res.record(iter, 2, .unexpected_error),
        }
        return;
    };
    if (!eql(v, dec)) res.record(iter, 2, .roundtrip_mismatch);
}

fn tSize(rng: *Rng, a: Allocator, res: *Res, iter: u64) void {
    const v = genValue(rng, a, 3) catch {
        res.skips += 1;
        return;
    };
    const predicted = v.encodedSize();
    const enc = v.encodeAlloc(a) catch {
        res.skips += 1;
        return;
    };
    if (predicted != enc.len) res.record(iter, 3, .size_mismatch);
}

fn tIdempotent(rng: *Rng, a: Allocator, res: *Res, iter: u64) void {
    const src = genGrammarish(rng, a) catch {
        res.skips += 1;
        return;
    };
    const v1 = syrup.decode(src, a) catch {
        res.skips += 1;
        return;
    };
    const e1 = v1.encodeAlloc(a) catch {
        res.skips += 1;
        return;
    };
    const v2 = syrup.decode(e1, a) catch {
        // re-decoding our own encoder output must not fail: that IS the finding
        res.record(iter, 4, .unexpected_error);
        return;
    };
    const e2 = v2.encodeAlloc(a) catch {
        res.skips += 1;
        return;
    };
    if (!std.mem.eql(u8, e1, e2)) res.record(iter, 4, .not_idempotent);
}

/// Every single-byte flip of a canonical attest frame must be VISIBLE: either the parse
/// fails, or the decoded value differs. A mutation that parses to an identical value is
/// silent acceptance — the codec-layer analogue of the Σ≡0 forgery result.
fn tAttestMutation(rng: *Rng, a: Allocator, res: *Res, iter: u64) void {
    const base = attest_frames[@intCast(rng.below(attest_frames.len))];
    const pristine = syrup.decode(base, a) catch {
        res.record(iter, 5, .unexpected_error); // canonical corpus must always parse
        return;
    };
    const buf = a.alloc(u8, base.len) catch {
        res.skips += 1;
        return;
    };
    @memcpy(buf, base);
    const pos: usize = @intCast(rng.below(buf.len));
    const delta: u8 = @intCast(1 + rng.below(255));
    buf[pos] = buf[pos] +% delta; // guaranteed different byte
    const mutated = syrup.decode(buf, a) catch return; // rejected — correct
    if (eql(pristine, mutated)) res.record(iter, 5, .silent_mutation);
}

fn tFrames(rng: *Rng, a: Allocator, res: *Res, iter: u64) void {
    const cap = 1024;
    var acc = mf.FrameAccumulator(cap){};
    const k: usize = @intCast(1 + rng.below(6));

    const originals = a.alloc([]u8, k) catch {
        res.skips += 1;
        return;
    };
    var stream: std.ArrayListUnmanaged(u8) = .empty;
    for (originals) |*p| {
        p.* = genBlob(rng, a, 200, false) catch {
            res.skips += 1;
            return;
        };
        var fbuf: [256]u8 = undefined;
        const n = mf.encodeRawFrame(p.*, &fbuf) catch {
            res.skips += 1;
            return;
        };
        stream.appendSlice(a, fbuf[0..n]) catch {
            res.skips += 1;
            return;
        };
    }

    var got: std.ArrayListUnmanaged([]u8) = .empty;
    var off: usize = 0;
    var spins: usize = 0;
    while (off < stream.items.len) {
        spins += 1;
        if (spins > 10_000) {
            res.record(iter, 6, .accumulator_stuck);
            return;
        }
        const room = acc.writeSlice();
        if (room.len > 0) {
            const want: usize = @intCast(1 + rng.below(97));
            const n = @min(@min(want, room.len), stream.items.len - off);
            @memcpy(room[0..n], stream.items[off..][0..n]);
            acc.advance(n);
            off += n;
        }
        // Frame.payload borrows the accumulator's buffer, which compaction may move.
        // Copy immediately — a borrowed slice held across the next write is a live hazard.
        while (acc.nextFrame()) |fr| {
            const owned = a.alloc(u8, fr.payload.len) catch {
                res.skips += 1;
                return;
            };
            @memcpy(owned, fr.payload);
            got.append(a, owned) catch {
                res.skips += 1;
                return;
            };
        }
        if (room.len == 0 and got.items.len == 0) {
            res.record(iter, 6, .accumulator_stuck);
            return;
        }
    }
    while (acc.nextFrame()) |fr| {
        const owned = a.alloc(u8, fr.payload.len) catch {
            res.skips += 1;
            return;
        };
        @memcpy(owned, fr.payload);
        got.append(a, owned) catch {
            res.skips += 1;
            return;
        };
    }

    if (got.items.len != k) {
        res.record(iter, 6, .frame_count_mismatch);
        return;
    }
    for (originals, got.items) |o, g| {
        if (!std.mem.eql(u8, o, g)) {
            res.record(iter, 6, .frame_payload_mismatch);
            return;
        }
    }
}

// ---------------------------------------------------------------- worker

fn worker(tid: usize, base_seed: u64, budget: u64, slab: []u8, res: *Res) void {
    var fba = std.heap.FixedBufferAllocator.init(slab);
    const a = fba.allocator();
    var rng = Rng.init(base_seed ^ (@as(u64, tid) *% 0x9e3779b97f4a7c15));
    res.thread_seed = rng.s;

    // Iteration budget, not a wall-clock deadline: a fixed (seed, threads, iters)
    // reproduces byte-identical coverage. Wall time is measured by the caller.
    var iter: u64 = 0;
    while (iter < budget) : (iter += 1) {
        fba.reset();

        const target: u8 = @intCast(rng.below(NT));
        res.per_target[target] += 1;
        switch (target) {
            0 => {
                const b = genBlob(&rng, a, 512, false) catch continue;
                _ = syrup.decode(b, a) catch {};
            },
            1 => {
                const b = genGrammarish(&rng, a) catch continue;
                _ = syrup.decode(b, a) catch {};
            },
            2 => tRoundTrip(&rng, a, res, iter),
            3 => tSize(&rng, a, res, iter),
            4 => tIdempotent(&rng, a, res, iter),
            5 => tAttestMutation(&rng, a, res, iter),
            else => tFrames(&rng, a, res, iter),
        }
    }
    _ = totals_iters.fetchAdd(iter, .monotonic);
}

var totals_iters = std.atomic.Value(u64).init(0);

// ---------------------------------------------------------------- diagnosis

fn dumpBytes(b: []const u8) void {
    for (b) |c| {
        if (c >= 0x20 and c < 0x7f) std.debug.print("{c}", .{c}) else std.debug.print("\\x{x:0>2}", .{c});
    }
}

/// Bisect a round-trip failure population: atoms-only first, then trees, bucketed by
/// top-level variant. A failure rate that is uniform across a variant is a systematic
/// encode/decode asymmetry; one confined to my generated shapes is generator noise.
/// Either way the output is a concrete counterexample, not a count.
fn diagnose(alloc: Allocator, base_seed: u64, budget: u64) !void {
    const slab = try alloc.alloc(u8, 8 << 20);
    defer alloc.free(slab);
    // 0.17.0-dev.667 reflection: Enum exposes `field_names`, not `fields`.
    const ntags = @typeInfo(std.meta.Tag(syrup.Value)).@"enum".field_names.len;

    for ([_]u8{ 0, 3 }) |depth| {
        var fba = std.heap.FixedBufferAllocator.init(slab);
        const a = fba.allocator();
        var rng = Rng.init(base_seed);
        var total: [ntags]u64 = @splat(0);
        var bad: [ntags]u64 = @splat(0);
        var shown: usize = 0;

        var i: u64 = 0;
        while (i < budget) : (i += 1) {
            fba.reset();
            const v = genValue(&rng, a, depth) catch continue;
            const ti = @backingInt(std.meta.activeTag(v));
            const enc = v.encodeAlloc(a) catch continue;
            total[ti] += 1;
            const dec = syrup.decode(enc, a) catch |e| {
                bad[ti] += 1;
                if (shown < 6) {
                    shown += 1;
                    std.debug.print("  DECODE-ERR depth={d} tag={s} err={s} enc=", .{ depth, @tagName(std.meta.activeTag(v)), @errorName(e) });
                    dumpBytes(enc);
                    std.debug.print("\n", .{});
                }
                continue;
            };
            if (!eql(v, dec)) {
                bad[ti] += 1;
                if (shown < 6) {
                    shown += 1;
                    std.debug.print("  MISMATCH depth={d} in={s} out={s} enc=", .{ depth, @tagName(std.meta.activeTag(v)), @tagName(std.meta.activeTag(dec)) });
                    dumpBytes(enc);
                    std.debug.print("\n", .{});
                }
            }
        }

        std.debug.print("depth={d}: ", .{depth});
        inline for (@typeInfo(std.meta.Tag(syrup.Value)).@"enum".field_names, 0..) |fname, idx| {
            if (total[idx] > 0 and bad[idx] > 0)
                std.debug.print("{s}={d}/{d} ", .{ fname, bad[idx], total[idx] });
        }
        std.debug.print("\n", .{});
    }
}

/// Minimal, hand-written reproducers distilled from the fuzz population. These use only
/// the PUBLIC constructors, so each is a value a caller can legitimately build.
fn repro(alloc: Allocator) !void {
    const slab = try alloc.alloc(u8, 1 << 20);
    defer alloc.free(slab);
    var fba = std.heap.FixedBufferAllocator.init(slab);
    const a = fba.allocator();

    const Case = struct { name: []const u8, data: syrup.Value };
    const cases = [_]Case{
        .{ .name = "data=symbol", .data = .{ .symbol = "x" } },
        .{ .name = "data=string", .data = .{ .string = "x" } },
        .{ .name = "data=integer", .data = .{ .integer = 7 } },
        .{ .name = "data=list", .data = .{ .list = &.{} } },
        .{ .name = "data=dictionary", .data = .{ .dictionary = &.{} } },
    };
    inline for (cases) |c| {
        fba.reset();
        const v = syrup.Value.fromError("m", "i", &c.data);
        const enc = try v.encodeAlloc(a);
        const dec = try syrup.decode(enc, a);
        std.debug.print("desc:error {s:<16} enc=", .{c.name});
        dumpBytes(enc);
        std.debug.print("  ->  {s}{s}\n", .{
            @tagName(std.meta.activeTag(dec)),
            if (std.meta.activeTag(dec) == .@"error") "" else "   <-- degraded to record",
        });
    }

    // Integer-representation boundary: where does bigint stop normalizing to .integer?
    const widths = [_]usize{ 7, 8, 9, 10 };
    for (widths) |w| {
        fba.reset();
        const mag = try a.alloc(u8, w);
        @memset(mag, 0xFF);
        const v = syrup.Value.fromBigint(mag, false);
        const enc = v.encodeAlloc(a) catch |e| {
            std.debug.print("bigint {d}B  ENCODE-ERR {s}\n", .{ w, @errorName(e) });
            continue;
        };
        const dec = syrup.decode(enc, a) catch |e| {
            std.debug.print("bigint {d}B  enc_len={d}  DECODE-ERR {s}\n", .{ w, enc.len, @errorName(e) });
            continue;
        };
        std.debug.print("bigint {d}B  enc_len={d}  -> {s}  roundtrip_eq={}\n", .{
            w, enc.len, @tagName(std.meta.activeTag(dec)), eql(v, dec),
        });
    }
}

/// EXHAUSTIVE single-byte mutation of the canonical attest frames. The random target
/// hits a silent acceptance ~1/30k, which is too rare to characterise by sampling — but
/// the space is only |frames| x |positions| x 255, so enumerate it and report every case.
fn attestScan(alloc: Allocator) !void {
    const slab = try alloc.alloc(u8, 1 << 20);
    defer alloc.free(slab);
    var fba = std.heap.FixedBufferAllocator.init(slab);
    const a = fba.allocator();

    var silent: usize = 0;
    var parsed: usize = 0;
    var rejected: usize = 0;

    for (attest_frames) |base| {
        fba.reset();
        const pristine = try syrup.decode(base, a);
        _ = pristine;

        for (0..base.len) |pos| {
            var d: u16 = 1;
            while (d < 256) : (d += 1) {
                fba.reset();
                const pr = syrup.decode(base, a) catch continue;
                const buf = try a.alloc(u8, base.len);
                @memcpy(buf, base);
                buf[pos] = buf[pos] +% @as(u8, @intCast(d));
                const mut = syrup.decode(buf, a) catch {
                    rejected += 1;
                    continue;
                };
                parsed += 1;
                if (eql(pr, mut)) {
                    silent += 1;
                    std.debug.print("  SILENT pos={d} '{c}'(0x{x:0>2}) -> 0x{x:0>2}  frame=", .{
                        pos, base[pos], base[pos], buf[pos],
                    });
                    dumpBytes(buf);
                    std.debug.print("\n", .{});
                }
            }
        }
    }
    std.debug.print("attest single-byte scan: silent={d} parsed_but_different={d} rejected={d}\n", .{ silent, parsed - silent, rejected });

    // Whole-value decoding must reject trailing bytes. If this succeeds, a frame
    // can carry undetected extra payload after a valid value.
    fba.reset();
    if (syrup.decode("1+GARBAGE", a)) |v| {
        std.debug.print("trailing-bytes: unexpectedly decoded {s}\n", .{@tagName(std.meta.activeTag(v))});
        return error.TrailingDataAccepted;
    } else |err| {
        if (err != error.TrailingData) return err;
        std.debug.print("trailing-bytes: rejected TrailingData\n", .{});
    }
}

/// MALLEABILITY probe. The single-byte scan is exhaustive but can only SUBSTITUTE, never
/// INSERT — so it cannot see length-changing non-canonical forms. The decisive question it
/// leaves open: is wire malleability one bit (signed zero) or unbounded (zero padding)?
fn malleability(alloc: Allocator) !void {
    const slab = try alloc.alloc(u8, 1 << 20);
    defer alloc.free(slab);
    var fba = std.heap.FixedBufferAllocator.init(slab);
    const a = fba.allocator();

    std.debug.print("-- integer wire forms (does a distinct byte string give the same value?) --\n", .{});
    const forms = [_][]const u8{ "0+", "0-", "7+", "07+", "007+", "0000000007+", "7-", "07-" };
    for (forms) |f| {
        fba.reset();
        const v = syrup.decode(f, a) catch |e| {
            std.debug.print("  {s:<14} REJECTED {s}\n", .{ f, @errorName(e) });
            continue;
        };
        if (std.meta.activeTag(v) == .integer)
            std.debug.print("  {s:<14} -> integer {d}\n", .{ f, v.integer })
        else
            std.debug.print("  {s:<14} -> {s}\n", .{ f, @tagName(std.meta.activeTag(v)) });
    }

    std.debug.print("-- attest witness leg: byte-distinct frames, identical decoded audit --\n", .{});
    const pairs = [_][]const u8{
        "<6'attest7\"n-again7'witness0+>",
        "<6'attest7\"n-again7'witness0->",
        "<6'attest7\"n-again7'witness00+>",
        "<6'attest7\"n-again7'witness000000+>",
    };
    for (pairs) |p| {
        fba.reset();
        const v = syrup.decode(p, a) catch |e| {
            std.debug.print("  len={d:<3} REJECTED {s}  {s}\n", .{ p.len, @errorName(e), p });
            continue;
        };
        var trit: i128 = 999;
        // label + [nonce, leg, trit] => the trit is the LAST field. (A previous run printed
        // the 999 sentinel because this assumed fields.len==2; that was the probe's bug.)
        if (std.meta.activeTag(v) == .record and v.record.fields.len > 0)
            if (asInt(v.record.fields[v.record.fields.len - 1])) |t| {
                trit = t;
            };
        std.debug.print("  len={d:<3} decodes, witness trit={d}  {s}\n", .{ p.len, trit, p });
    }

    std.debug.print("-- trailing bytes inside an explicit frame boundary --\n", .{});
    const framed = "<6'attest7\"n-again7'witness0+>STOWAWAY";
    fba.reset();
    const fv = syrup.decode(framed, a) catch |e| {
        std.debug.print("  rejected {s}\n", .{@errorName(e)});
        return;
    };
    std.debug.print("  frame_len={d} decodes as {s}; {d} bytes after the value are never examined\n", .{
        framed.len, @tagName(std.meta.activeTag(fv)), framed.len - 29,
    });
}

// ---------------------------------------------------------------- main

// 0.17.0-dev.667 dropped std.process.argsAlloc AND std.os.argv; the current shape is
// `main(std.process.Init.Minimal)` + `args.iterate()`. Measured from the stdlib, not guessed.
pub fn main(init: std.process.Init.Minimal) !void {
    const alloc = std.heap.page_allocator;

    var argv: [4][]const u8 = .{ "", "", "", "" };
    var argn: usize = 0;
    var it = init.args.iterate();
    _ = it.skip(); // program name
    while (it.next()) |arg| {
        if (argn >= argv.len) break;
        argv[argn] = arg;
        argn += 1;
    }

    const iters: u64 = if (argn > 0) try std.fmt.parseInt(u64, argv[0], 10) else 100_000;
    const nthreads: usize = if (argn > 1) try std.fmt.parseInt(usize, argv[1], 10) else 10;
    const base_seed: u64 = if (argn > 2) try std.fmt.parseInt(u64, argv[2], 10) else 0x42D;
    const mode: u8 = if (argn > 3) try std.fmt.parseInt(u8, argv[3], 10) else 0;
    if (mode == 1) return diagnose(alloc, base_seed, iters);
    if (mode == 2) return repro(alloc);
    if (mode == 5) return attestScan(alloc);
    if (mode == 6) return malleability(alloc);
    // Modes 3/4 are retained as compatibility aliases from the original probe;
    // both now exercise the full corpus because the historical defects are fixed.
    if (mode == 4) return diagnose(alloc, base_seed, iters);
    const slab_bytes: usize = 4 << 20;

    const results = try alloc.alloc(Res, nthreads);
    defer alloc.free(results);
    for (results) |*r| r.* = .{};

    const slabs = try alloc.alloc([]u8, nthreads);
    defer alloc.free(slabs);
    for (slabs) |*s| s.* = try alloc.alloc(u8, slab_bytes);
    defer for (slabs) |s| alloc.free(s);

    const threads = try alloc.alloc(std.Thread, nthreads);
    defer alloc.free(threads);

    for (threads, 0..) |*t, i| {
        t.* = try std.Thread.spawn(.{}, worker, .{ i, base_seed, iters, slabs[i], &results[i] });
    }
    for (threads) |t| t.join();

    var total_fails: u64 = 0;
    var total_skips: u64 = 0;
    var per_target: [NT]u64 = @splat(0);
    for (results) |r| {
        total_fails += r.fails;
        total_skips += r.skips;
        for (0..NT) |i| per_target[i] += r.per_target[i];
    }
    const total_iters = totals_iters.load(.monotonic);

    std.debug.print("{{\"threads\":{d},\"iters_per_thread\":{d},\"base_seed\":{d}," ++
        "\"iterations\":{d},\"fails\":{d},\"skips\":{d},\"per_target\":[", .{
        nthreads, iters, base_seed, total_iters, total_fails, total_skips,
    });
    for (per_target, 0..) |c, i| {
        if (i > 0) std.debug.print(",", .{});
        std.debug.print("{d}", .{c});
    }
    std.debug.print("],\"first_failures\":[", .{});
    var printed: usize = 0;
    for (results, 0..) |r, i| {
        if (r.first_kind == .none) continue;
        if (printed > 0) std.debug.print(",", .{});
        printed += 1;
        std.debug.print("{{\"thread\":{d},\"thread_seed\":{d},\"iter\":{d},\"target\":{d},\"kind\":\"{s}\"}}", .{
            i, r.thread_seed, r.first_iter, r.first_target, @tagName(r.first_kind),
        });
    }
    std.debug.print("]}}\n", .{});

    if (total_fails > 0) std.process.exit(2);
}
