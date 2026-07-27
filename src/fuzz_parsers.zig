//! Fuzz harness for the repo's OTHER untrusted-byte parsers.
//!
//! syrup.zig is well covered by fuzz_syrup_{random,struct}.zig; these modules
//! parse attacker-controlled bytes too and had no fuzzing at all. Properties are
//! per-target and go beyond "does not crash":
//!
//!   message_frame — DIFFERENTIAL: `frameCount` must agree with what
//!                   `decodeFrame` can actually extract sequentially. They apply
//!                   different validation, so disagreement is a real bug.
//!                 — round-trip: encodeRawFrame -> decodeFrame returns the payload.
//!   cyton/dsi24   — ANTI-AMPLIFICATION: a stream parser must not emit more
//!                   samples than the input can contain (len/PACKET_LEN + 1).
//!                   Violating it means overlapping re-parses = memory blowup DoS
//!                   from a small attacker input.
//!   others        — crash-safety on biased-random bytes.
//!
//! Allocation is bounded by a per-thread FixedBufferAllocator, so unbounded
//! growth surfaces as OutOfMemory (an error, fine) instead of thrashing the box.
// Imported as MODULES (not relative paths) so each target's own test blocks are
// not pulled into this compilation — several of them reference stale std APIs or
// sibling modules and would fail to analyze, which has nothing to do with fuzzing
// the parsers themselves.
const std = @import("std");
const frame = @import("message_frame");
const cyton = @import("cyton_parser");
const dsi24 = @import("dsi24_parser");
const edf = @import("edf_reader");
const did_key = @import("did_key");
const geo = @import("geo");
const ibc = @import("ibc_denom_verifier");

const THREADS = 10;
const ITERS_PER_THREAD: u64 = 60_000;
const MAX_INPUT = 1024;
const ARENA_BYTES = 32 * 1024 * 1024;

const CYTON_PACKET_LEN = 33;
const DSI24_PACKET_LEN = 84;

var n_run: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
var n_frame_ok: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
var n_cyton_samples: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
var n_dsi_samples: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
/// Worst observed samples-per-input-byte for cyton (amplification evidence).
var cyton_worst_num: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
var cyton_worst_den: std.atomic.Value(u64) = std.atomic.Value(u64).init(1);
var failed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

fn fill(rnd: std.Random, buf: []u8, alphabet: ?[]const u8) void {
    for (buf) |*b| {
        b.* = if (alphabet) |al| blk: {
            // Mostly alphabet bytes so the parser gets past its first checks.
            break :blk if (rnd.uintLessThan(u8, 10) < 8)
                al[rnd.uintLessThan(usize, al.len)]
            else
                rnd.int(u8);
        } else rnd.int(u8);
    }
}

fn worker(tid: u64) void {
    var prng = std.Random.DefaultPrng.init(0xFACADE ^ (tid *% 0x9E3779B97F4A7C15));
    const rnd = prng.random();

    const backing = std.heap.page_allocator.alloc(u8, ARENA_BYTES) catch return;
    defer std.heap.page_allocator.free(backing);
    var buf: [MAX_INPUT]u8 = undefined;

    var runs: u64 = 0;
    var frames_ok: u64 = 0;
    var cyt: u64 = 0;
    var dsi: u64 = 0;

    var i: u64 = 0;
    while (i < ITERS_PER_THREAD) : (i += 1) {
        if (failed.load(.monotonic)) break;
        var fba = std.heap.FixedBufferAllocator.init(backing);
        const a = fba.allocator();

        const target = rnd.uintLessThan(u8, 7);
        const n = rnd.uintLessThan(usize, MAX_INPUT);
        const input = buf[0..n];
        runs += 1;

        switch (target) {
            0 => {
                // message_frame: small length prefixes so frames actually complete.
                fill(rnd, input, null);
                if (n >= 4 and rnd.boolean()) {
                    const plen = rnd.uintLessThan(u32, @intCast(n + 8));
                    input[0] = @truncate(plen >> 24);
                    input[1] = @truncate(plen >> 16);
                    input[2] = @truncate(plen >> 8);
                    input[3] = @truncate(plen);
                }
                _ = frame.peekFrameLength(input);
                _ = frame.decodeFrame(input) catch {};

                // DIFFERENTIAL: sequential decodeFrame count == frameCount.
                var pos: usize = 0;
                var seq: usize = 0;
                while (pos < input.len) {
                    const f = frame.decodeFrame(input[pos..]) catch break;
                    if (f.consumed == 0) break;
                    seq += 1;
                    pos += f.consumed;
                }
                const counted = frame.frameCount(input);
                if (seq != counted) {
                    std.debug.print(
                        "\nFRAME DIFFERENTIAL BUG: frameCount={d} but decodeFrame yields {d}\n  input={x}\n",
                        .{ counted, seq, input },
                    );
                    failed.store(true, .monotonic);
                    break;
                }
                frames_ok += 1;
            },
            1 => {
                // Round-trip framing.
                const payload_len = rnd.uintLessThan(usize, 128);
                const payload = buf[0..payload_len];
                fill(rnd, payload, null);
                const out = a.alloc(u8, payload_len + 8) catch continue;
                const written = frame.encodeRawFrame(payload, out) catch continue;
                const f = frame.decodeFrame(out[0..written]) catch {
                    std.debug.print("\nFRAME ROUNDTRIP BUG: encoded frame will not decode\n", .{});
                    failed.store(true, .monotonic);
                    break;
                };
                if (!std.mem.eql(u8, f.payload, payload)) {
                    std.debug.print("\nFRAME ROUNDTRIP BUG: payload mismatch\n", .{});
                    failed.store(true, .monotonic);
                    break;
                }
                frames_ok += 1;
            },
            2 => {
                // cyton: bias toward the start/stop bytes so packets parse.
                fill(rnd, input, &[_]u8{ 0xA0, 0xC0 });
                const samples = cyton.parseStream(input, a) catch continue;
                cyt += samples.len;
                // ANTI-AMPLIFICATION: at most one sample per packet-length of input.
                const bound = input.len / CYTON_PACKET_LEN + 1;
                if (samples.len > bound) {
                    // record the worst ratio seen, then report once
                    _ = cyton_worst_num.store(samples.len, .monotonic);
                    _ = cyton_worst_den.store(@max(input.len, 1), .monotonic);
                    std.debug.print(
                        "\nCYTON AMPLIFICATION: {d} samples from {d} bytes (bound {d})\n",
                        .{ samples.len, input.len, bound },
                    );
                    failed.store(true, .monotonic);
                    break;
                }
            },
            3 => {
                fill(rnd, input, &[_]u8{ 0x01, 0x02, 0xFF });
                const samples = dsi24.parseStream(input, a) catch continue;
                dsi += samples.len;
                const bound = input.len / DSI24_PACKET_LEN + 1;
                if (samples.len > bound) {
                    std.debug.print(
                        "\nDSI24 AMPLIFICATION: {d} samples from {d} bytes (bound {d})\n",
                        .{ samples.len, input.len, bound },
                    );
                    failed.store(true, .monotonic);
                    break;
                }
                if (input.len >= DSI24_PACKET_LEN) {
                    _ = dsi24.parseDSI24Packet(input[0..DSI24_PACKET_LEN]) catch {};
                }
            },
            4 => {
                // EDF headers are ASCII numerics in fixed-width fields.
                fill(rnd, input, " 0123456789.-+EDF+CX");
                _ = edf.EDFFile.parse(input) catch {};
            },
            5 => {
                // did:key:z<base58btc>
                const prefix = "did:key:z";
                const b58 = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";
                if (n > prefix.len) {
                    @memcpy(input[0..prefix.len], prefix);
                    fill(rnd, input[prefix.len..], b58);
                }
                _ = did_key.resolve(a, input) catch {};
            },
            else => {
                // Open Location Code + IBC denom trace.
                fill(rnd, input, "23456789CFGHJMPQRVWX+0");
                _ = geo.isValid(input);
                _ = geo.decodeOlc(input) catch {};
                _ = ibc.DenomTrace.parse(input);
            },
        }
    }

    _ = n_run.fetchAdd(runs, .monotonic);
    _ = n_frame_ok.fetchAdd(frames_ok, .monotonic);
    _ = n_cyton_samples.fetchAdd(cyt, .monotonic);
    _ = n_dsi_samples.fetchAdd(dsi, .monotonic);
}

test "regression: frameCount agrees with decodeFrame on an oversized frame" {
    // decodeFrame rejects payloads > MAX_MESSAGE_SIZE; frameCount must not count
    // a frame that decodeFrame refuses to produce, or a caller sizing its decode
    // loop from frameCount walks off the end of what it can actually parse.
    const alloc = std.testing.allocator;
    const payload_len: u32 = frame.MAX_MESSAGE_SIZE + 1;
    const total = frame.HEADER_SIZE + @as(usize, payload_len);
    const buf = try alloc.alloc(u8, total);
    defer alloc.free(buf);
    @memset(buf, 0);
    buf[0] = @truncate(payload_len >> 24);
    buf[1] = @truncate(payload_len >> 16);
    buf[2] = @truncate(payload_len >> 8);
    buf[3] = @truncate(payload_len);

    try std.testing.expectError(error.MessageTooLarge, frame.decodeFrame(buf));
    try std.testing.expectEqual(@as(usize, 0), frame.frameCount(buf));
}

test "regression: cyton parseStream does not amplify (one sample per packet)" {
    // Before the fix, a successful parse advanced by 1 byte instead of the packet
    // length, re-parsing overlapping windows: ~1 sample per byte from a small
    // input (memory-amplification DoS). dsi24 already advanced correctly.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var buf: [CYTON_PACKET_LEN * 8]u8 = undefined;
    @memset(&buf, 0xA0); // every offset looks like a packet start
    const samples = try cyton.parseStream(&buf, a);
    try std.testing.expect(samples.len <= buf.len / CYTON_PACKET_LEN + 1);
}

test "fuzz: repo parsers (frame differential, stream anti-amplification, crash-safety)" {
    var threads: [THREADS]std.Thread = undefined;
    for (&threads, 0..) |*t, k| t.* = try std.Thread.spawn(.{}, worker, .{@as(u64, k)});
    for (&threads) |t| t.join();

    std.debug.print(
        "\nparser-fuzz: {d} runs | {d} frame properties | cyton {d} samples, dsi24 {d} samples | {d} threads\n",
        .{
            n_run.load(.monotonic),      n_frame_ok.load(.monotonic),
            n_cyton_samples.load(.monotonic), n_dsi_samples.load(.monotonic),
            THREADS,
        },
    );
    try std.testing.expect(!failed.load(.monotonic));
    try std.testing.expect(n_run.load(.monotonic) == THREADS * ITERS_PER_THREAD);
}
