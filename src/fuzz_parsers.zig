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
const did_tdw = @import("did_tdw");
const did_web = @import("did_web");
const did_gay = @import("did_gay");
const did_pkh = @import("did_pkh");

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
var n_olc_roundtrip: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
var n_olc_shortrec: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
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

/// Write `v` as ASCII into a fixed-width EDF field, space-padded (EDF fields are
/// left-aligned ASCII).
fn writeField(field: []u8, v: i64) void {
    @memset(field, ' ');
    var tmp: [24]u8 = undefined;
    const s = std.fmt.bufPrint(&tmp, "{d}", .{v}) catch return;
    const n = @min(s.len, field.len);
    @memcpy(field[0..n], s[0..n]);
}

/// Build a SELF-CONSISTENT EDF header (version, matching header_bytes, channel
/// count) with randomized numeric fields. Random bytes essentially never satisfy
/// `header_bytes == 256 + 256*n_channels`, so without this the per-channel
/// parsing loops — where the numeric conversions live — are unreachable.
fn buildEdf(rnd: std.Random, out: []u8) ?[]u8 {
    const n: usize = rnd.uintLessThan(usize, 5);
    const header_bytes: usize = 256 + 256 * n;
    if (out.len < header_bytes) return null;
    const b = out[0..header_bytes];
    @memset(b, ' ');

    b[0] = '0'; // version must start with '0'
    writeField(b[184..192], @intCast(header_bytes));
    writeField(b[236..244], @intCast(rnd.uintLessThan(u32, 1000))); // n_records
    writeField(b[244..252], 1); // record_duration
    writeField(b[252..256], @intCast(n)); // n_channels

    // Numeric per-channel fields. Each is 8 ASCII chars, so it can carry values
    // far outside the i16/u16 the parser stores them in — that is the point.
    const wild = struct {
        fn v(r: std.Random) i64 {
            return switch (r.uintLessThan(u8, 4)) {
                0 => @intCast(r.uintLessThan(u32, 100)), // in range
                1 => 99_999_999, // overflows u16 and i16
                2 => -9_999_999, // underflows i16
                else => r.int(i32), // anything
            };
        }
    }.v;

    var off: usize = 256 + 104 * n; // physical_min block
    for (0..n) |_| {
        writeField(b[off..][0..8], @intCast(rnd.uintLessThan(u32, 100)));
        off += 8;
    }
    for (0..n) |_| { // physical_max
        writeField(b[off..][0..8], @intCast(rnd.uintLessThan(u32, 100)));
        off += 8;
    }
    for (0..n) |_| { // digital_min  -> stored in i16
        writeField(b[off..][0..8], wild(rnd));
        off += 8;
    }
    for (0..n) |_| { // digital_max  -> stored in i16
        writeField(b[off..][0..8], wild(rnd));
        off += 8;
    }
    off += 80 * n; // prefiltering
    for (0..n) |_| { // samples_per_record -> stored in u16
        writeField(b[off..][0..8], wild(rnd));
        off += 8;
    }
    return b;
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
    var olc: u64 = 0;
    var shortrec: u64 = 0;

    var i: u64 = 0;
    while (i < ITERS_PER_THREAD) : (i += 1) {
        if (failed.load(.monotonic)) break;
        var fba = std.heap.FixedBufferAllocator.init(backing);
        const a = fba.allocator();

        const target = rnd.uintLessThan(u8, 9);
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
                // Half structured (reaches the per-channel numeric conversions),
                // half biased-random (exercises the early header validation).
                if (rnd.boolean()) {
                    if (buildEdf(rnd, input)) |edf_buf| {
                        _ = edf.EDFFile.parse(edf_buf) catch {};
                    }
                } else {
                    fill(rnd, input, " 0123456789.-+EDF+CX");
                    _ = edf.EDFFile.parse(input) catch {};
                }
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
            6 => {
                // OLC ROUND-TRIP DIFFERENTIAL. The defining contract of a Plus
                // Code: the encoded point must lie inside the cell you get back,
                // and re-encoding that cell's centre must reproduce the code.
                // Crash-safety alone cannot see a wrong-but-safe geometry bug.
                const lat = rnd.float(f64) * 180.0 - 90.0;
                const lng = rnd.float(f64) * 360.0 - 180.0;
                const lens = [_]u8{ 2, 4, 6, 8, 10, 11, 12, 13, 14, 15 };
                const code_len = lens[rnd.uintLessThan(usize, lens.len)];

                var cbuf: [32]u8 = undefined;
                const written = geo.encodeOlc(lat, lng, code_len, &cbuf) catch continue;
                const code = cbuf[0..written];

                // The encoder's own output must be accepted by the decoder.
                const area = geo.decodeOlc(code) catch {
                    std.debug.print(
                        "\nOLC BUG: encodeOlc produced a code decodeOlc rejects\n  lat={d} lng={d} len={d} code={s}\n",
                        .{ lat, lng, code_len, code },
                    );
                    failed.store(true, .monotonic);
                    break;
                };

                // Containment (tiny epsilon for float boundary rounding only).
                const eps = 1e-9;
                if (lat < area.south_latitude - eps or lat > area.north_latitude + eps or
                    lng < area.west_longitude - eps or lng > area.east_longitude + eps)
                {
                    std.debug.print(
                        "\nOLC CONTAINMENT BUG: point outside its own cell\n  lat={d} lng={d} len={d} code={s}\n  cell lat[{d}, {d}] lng[{d}, {d}]\n",
                        .{ lat, lng, code_len, code, area.south_latitude, area.north_latitude, area.west_longitude, area.east_longitude },
                    );
                    failed.store(true, .monotonic);
                    break;
                }

                // Fixpoint: encoding the cell centre at the same length must give
                // back the identical code.
                var cbuf2: [32]u8 = undefined;
                const w2 = geo.encodeOlc(area.centerLatitude(), area.centerLongitude(), code_len, &cbuf2) catch continue;
                if (!std.mem.eql(u8, code, cbuf2[0..w2])) {
                    std.debug.print(
                        "\nOLC FIXPOINT BUG: centre of the cell re-encodes differently\n  code={s} centre-code={s} len={d}\n",
                        .{ code, cbuf2[0..w2], code_len },
                    );
                    failed.store(true, .monotonic);
                    break;
                }
                olc += 1;
            },
            7 => {
                // SHORTEN/RECOVER DIFFERENTIAL: relative to the SAME reference,
                // shortenOlc and recoverOlc must be inverses — recovering a
                // shortened code has to reproduce the original full code.
                const lat = rnd.float(f64) * 180.0 - 90.0;
                const lng = rnd.float(f64) * 360.0 - 180.0;
                var full_buf: [32]u8 = undefined;
                const fl = geo.encodeOlc(lat, lng, 10, &full_buf) catch continue;
                const full = full_buf[0..fl];

                // Reference at a random distance, spanning every removal tier
                // (8/6/4/2 chars removed, and far enough for no shortening).
                const scales = [_]f64{ 0.0002, 0.008, 0.15, 3.0, 50.0 };
                const scale = scales[rnd.uintLessThan(usize, scales.len)];
                const ref_lat = @min(@max(lat + (rnd.float(f64) - 0.5) * scale, -90.0), 90.0);
                const ref_lng = @min(@max(lng + (rnd.float(f64) - 0.5) * scale, -180.0), 180.0);

                var short_buf: [32]u8 = undefined;
                const sl = geo.shortenOlc(full, ref_lat, ref_lng, &short_buf) catch continue;
                const short = short_buf[0..sl];

                var rec_buf: [32]u8 = undefined;
                const rl = geo.recoverOlc(short, ref_lat, ref_lng, &rec_buf) catch continue;
                const rec = rec_buf[0..rl];

                if (!std.mem.eql(u8, full, rec)) {
                    std.debug.print(
                        "\nOLC SHORTEN/RECOVER BUG: not inverses\n  lat={d} lng={d}\n  ref_lat={d} ref_lng={d}\n  full={s} short={s} recovered={s}\n",
                        .{ lat, lng, ref_lat, ref_lng, full, short, rec },
                    );
                    failed.store(true, .monotonic);
                    break;
                }
                shortrec += 1;
            },
            else => {
                // Open Location Code + IBC denom trace, crash-safety on junk.
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
    _ = n_olc_roundtrip.fetchAdd(olc, .monotonic);
    _ = n_olc_shortrec.fetchAdd(shortrec, .monotonic);
}

test "regression: OLC grid refinement varies (codes longer than 10 chars)" {
    // Two points in the SAME length-10 cell but different refinement sub-cells
    // must encode to DIFFERENT codes, and each must decode to a cell containing
    // it. Before the fix, encodeOlc computed every grid digit from a raw degree
    // remainder and always got 0, so both points produced the IDENTICAL code and
    // both cells sat at the corner of the pair cell.
    const base_lat: f64 = 47.0;
    const base_lng: f64 = 8.0;
    const cell = std.math.pow(f64, 20.0, -3.0); // 1.25e-4 = length-10 cell size

    var a_buf: [32]u8 = undefined;
    var b_buf: [32]u8 = undefined;
    const a_lat = base_lat + cell * 0.1;
    const a_lng = base_lng + cell * 0.1;
    const b_lat = base_lat + cell * 0.9;
    const b_lng = base_lng + cell * 0.9;
    const a = a_buf[0..try geo.encodeOlc(a_lat, a_lng, 15, &a_buf)];
    const b = b_buf[0..try geo.encodeOlc(b_lat, b_lng, 15, &b_buf)];

    try std.testing.expect(!std.mem.eql(u8, a, b));

    const area_a = try geo.decodeOlc(a);
    try std.testing.expect(a_lat >= area_a.south_latitude and a_lat <= area_a.north_latitude);
    try std.testing.expect(a_lng >= area_a.west_longitude and a_lng <= area_a.east_longitude);

    const area_b = try geo.decodeOlc(b);
    try std.testing.expect(b_lat >= area_b.south_latitude and b_lat <= area_b.north_latitude);
    try std.testing.expect(b_lng >= area_b.west_longitude and b_lng <= area_b.east_longitude);
}

test "regression: OLC shorten/recover are inverses (prefix overwrite + antimeridian)" {
    const Case = struct { lat: f64, lng: f64, ref_lat: f64, ref_lng: f64 };
    const cases = [_]Case{
        // Both axes needed adjusting: the latitude fix was overwritten when the
        // longitude branch re-encoded the prefix using the raw reference latitude
        // (full=72C72393+2P came back as 72972393+2P).
        .{ .lat = 18.01759745338643, .lng = -174.9456692586951, .ref_lat = 17.83646729183896, .ref_lng = -175.07240698926444 },
        // Reference sits exactly on the antimeridian, 2.4 degrees from the point
        // the short way round — a raw subtraction called it ~342 degrees away
        // (full=5VJVMJ92+4Q came back as 53JVMJ92+4Q).
        .{ .lat = -17.332166524464142, .lng = 177.6019914449068, .ref_lat = -21.7463226408412, .ref_lng = 180.0 },
    };

    for (cases) |c| {
        var full_buf: [32]u8 = undefined;
        const full = full_buf[0..try geo.encodeOlc(c.lat, c.lng, 10, &full_buf)];

        var short_buf: [32]u8 = undefined;
        const short = short_buf[0..try geo.shortenOlc(full, c.ref_lat, c.ref_lng, &short_buf)];

        var rec_buf: [32]u8 = undefined;
        const rec = rec_buf[0..try geo.recoverOlc(short, c.ref_lat, c.ref_lng, &rec_buf)];

        try std.testing.expectEqualStrings(full, rec);
    }
}

test "leak sweep: DID parsers release everything under injected OOM" {
    // Every one of these types has a deinit(), i.e. the API hands ownership to the
    // caller — so a parse that fails partway MUST release whatever it already
    // allocated. std.testing.allocator fails the test otherwise. This is the same
    // property that caught the did_tdw.verifyLog leak.
    //
    // (bristol.Circuit is deliberately excluded: it has no deinit at all, so that
    // module is arena-only by construction and "leaking" is its contract.)
    const web_inputs = [_][]const u8{
        "did:web:example.com",
        "did:web:example.com:user:alice",
        "did:web:sub.domain.example.com%3A8080:path:deep:deeper",
        "did:web:",
        "did:web:a:b:c:d:e:f:g:h",
    };
    const gay_inputs = [_][]const u8{
        "did:gay:example",
        "did:gay:alice:bob:carol",
        "did:gay:",
        "did:gay:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    };
    const pkh_inputs = [_][]const u8{
        "did:pkh:eip155:1:0xb9c5714089478a327f09197987f16f9e5d936e8a",
        "did:pkh:bip122:000000000019d6689c085ae165831e93:128Lkh3S7CkDTBZ8",
        "did:pkh:",
        "did:pkh:eip155:1",
    };
    const key_inputs = [_][]const u8{
        "did:key:z6MkhaXgBZDvotDkL5257faiztiGiC2QtKLGpbnnEGta2doK",
        "did:key:z",
        "did:key:",
        "did:key:zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz",
    };

    var idx: usize = 0;
    while (idx < 20) : (idx += 1) {
        for (web_inputs) |s| {
            var f = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = idx });
            if (did_web.parse(f.allocator(), s)) |v| v.deinit() else |_| {}
        }
        for (gay_inputs) |s| {
            var f = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = idx });
            if (did_gay.parse(f.allocator(), s)) |v| v.deinit() else |_| {}
        }
        for (pkh_inputs) |s| {
            var f = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = idx });
            if (did_pkh.parse(f.allocator(), s)) |v| v.deinit() else |_| {}
        }
        for (key_inputs) |s| {
            var f = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = idx });
            if (did_key.resolve(f.allocator(), s)) |v| v.deinit() else |_| {}
        }
    }
}

test "regression: did_tdw.verifyLog does not leak under injected OOM" {
    // verifyLog allocates an entries array and then dupes a string per entry.
    // If a later allocation fails, everything already allocated must be released
    // before returning the error. std.testing.allocator fails this test if not.
    const lines = [_][]const u8{
        "2026-07-27T00:00:00Z genesis entry payload",
        "2026-07-27T00:01:00Z rotation entry payload",
        "2026-07-27T00:02:00Z another rotation payload",
        "2026-07-27T00:03:00Z yet another payload",
    };
    // Walk the fail index across every allocation the call makes.
    var idx: usize = 0;
    while (idx < 16) : (idx += 1) {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = idx });
        if (did_tdw.verifyLog(failing.allocator(), &lines)) |vlog| {
            vlog.deinit(); // succeeded: release normally
        } else |_| {
            // failed: verifyLog must have cleaned up after itself
        }
    }
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
        "\nparser-fuzz: {d} runs | {d} frame properties | cyton {d} samples, dsi24 {d} samples | {d} OLC round-trips, {d} shorten/recover | {d} threads\n",
        .{
            n_run.load(.monotonic),           n_frame_ok.load(.monotonic),
            n_cyton_samples.load(.monotonic), n_dsi_samples.load(.monotonic),
            n_olc_roundtrip.load(.monotonic), n_olc_shortrec.load(.monotonic),
            THREADS,
        },
    );
    try std.testing.expect(!failed.load(.monotonic));
    try std.testing.expect(n_run.load(.monotonic) == THREADS * ITERS_PER_THREAD);
}
