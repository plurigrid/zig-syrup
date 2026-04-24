//! path_invariance.zig — Zig driver for cross-runtime Syrup path invariance.
//!
//! This is the Zig leg of Squares A (Zig⇄Guile), B (Zig⇄Racket), and the
//! same-runtime Square D control. It does not require a live Goblins peer
//! or a CapTP handshake; it tests the canonical-form layer only.
//!
//! Frame format on disk: a stream of <u32-BE length><syrup bytes> records,
//! one per color in the 70-color CGT corpus.
//!
//!   [0]    Color of Greatest Trickery (mid-grey, trit-0 ergodic)
//!   [1..8] Cube vertices in {0,1}^3
//!   [9..69] 60 splitmix samples (seed=69420)
//!
//! Modes:
//!   emit       <out.bin>             — write corpus to <out.bin>
//!   verify     <orig.bin> <ret.bin>  — assert ret matches orig frame-by-frame
//!   roundtrip  <scratch.bin>         — emit then decode-encode in-process
//!                                      (Square D control, no external peer)
//!
//! Usage with a Racket peer:
//!   path_invariance emit /tmp/corpus.bin
//!   racket examples/interop/racket_echo.rkt /tmp/corpus.bin /tmp/echo.bin
//!   path_invariance verify /tmp/corpus.bin /tmp/echo.bin
//!
//! Exit code is 0 on success, non-zero on first mismatch.

const std = @import("std");
const syrup = @import("syrup");
const gay = @import("gay");
const compat = @import("compat");
const gay_ser = gay.serialization;
const RGB = gay.color.RGB;
const cgt_corpus = gay.cgt_corpus;
const cgtCorpus = cgt_corpus.fill;

fn writeAll(f: compat.File, bytes: []const u8) void {
    compat.fileWriteAll(f, bytes);
}

fn writeFrame(f: compat.File, payload: []const u8) void {
    var len_be: [4]u8 = undefined;
    std.mem.writeInt(u32, &len_be, @intCast(payload.len), .big);
    writeAll(f, &len_be);
    writeAll(f, payload);
}

fn readExact(f: compat.File, buf: []u8) !usize {
    var total: usize = 0;
    while (total < buf.len) {
        const got = compat.fileRead(f, buf[total..]);
        if (got == 0) return total;
        total += got;
    }
    return total;
}

fn readFrame(f: compat.File, allocator: std.mem.Allocator) !?[]u8 {
    var len_be: [4]u8 = undefined;
    const n = try readExact(f, &len_be);
    if (n == 0) return null;
    if (n != 4) return error.TruncatedFrame;
    const len = std.mem.readInt(u32, &len_be, .big);
    const payload = try allocator.alloc(u8, len);
    errdefer allocator.free(payload);
    const got = try readExact(f, payload);
    if (got != len) return error.TruncatedFrame;
    return payload;
}

fn cmdEmit(allocator: std.mem.Allocator, out_path: []const u8) !void {
    var corpus: [70]RGB = undefined;
    cgtCorpus(&corpus);

    const file = try std.fs.cwd().createFile(out_path, .{});
    defer file.close();

    for (corpus) |c| {
        const val = try gay_ser.encodeColor(c, allocator);
        const bytes = try gay_ser.toBytes(val, allocator);
        defer allocator.free(bytes);
        val.deinitAll(allocator);
        writeFrame(file, bytes);
    }

    var msg_buf: [256]u8 = undefined;
    const msg = try std.fmt.bufPrint(&msg_buf, "emit: wrote {d} frames to {s}\n", .{ corpus.len, out_path });
    compat.stdoutWrite(msg);
}

fn cmdVerify(allocator: std.mem.Allocator, orig_path: []const u8, ret_path: []const u8) !u8 {
    const orig = try std.fs.cwd().openFile(orig_path, .{});
    defer orig.close();
    const ret = try std.fs.cwd().openFile(ret_path, .{});
    defer ret.close();

    var msg_buf: [512]u8 = undefined;
    var idx: usize = 0;
    while (true) : (idx += 1) {
        const a = try readFrame(orig, allocator);
        const b = try readFrame(ret, allocator);
        if (a == null and b == null) break;
        if (a == null or b == null) {
            const m = try std.fmt.bufPrint(&msg_buf, "FAIL idx={d}: frame-count mismatch\n", .{idx});
            compat.stdoutWrite(m);
            if (a) |x| allocator.free(x);
            if (b) |x| allocator.free(x);
            return 1;
        }
        defer allocator.free(a.?);
        defer allocator.free(b.?);

        if (!std.mem.eql(u8, a.?, b.?)) {
            const m = try std.fmt.bufPrint(&msg_buf, "FAIL idx={d}: bytes differ ({d} vs {d})\n", .{ idx, a.?.len, b.?.len });
            compat.stdoutWrite(m);
            return 1;
        }
    }
    const m = try std.fmt.bufPrint(&msg_buf, "OK: {d} frames byte-identical\n", .{idx});
    compat.stdoutWrite(m);
    return 0;
}

fn cmdRoundtrip(allocator: std.mem.Allocator, out_path: []const u8) !u8 {
    try cmdEmit(allocator, out_path);

    const file = try std.fs.cwd().openFile(out_path, .{});
    defer file.close();

    var msg_buf: [256]u8 = undefined;
    var idx: usize = 0;
    while (true) : (idx += 1) {
        const frame = try readFrame(file, allocator) orelse break;
        defer allocator.free(frame);

        const v = try gay_ser.fromBytes(frame, allocator);
        defer v.deinitAll(allocator);
        const c = try gay_ser.decodeColor(v);

        const v2 = try gay_ser.encodeColor(c, allocator);
        const re_bytes = try gay_ser.toBytes(v2, allocator);
        defer allocator.free(re_bytes);
        v2.deinitAll(allocator);

        if (!std.mem.eql(u8, frame, re_bytes)) {
            const m = try std.fmt.bufPrint(&msg_buf, "FAIL roundtrip idx={d}: bytes differ\n", .{idx});
            compat.stdoutWrite(m);
            return 1;
        }
    }
    const m = try std.fmt.bufPrint(&msg_buf, "Square D OK: {d} frames roundtrip byte-identical\n", .{idx});
    compat.stdoutWrite(m);
    return 0;
}

pub fn main() !void {
    var gpa = compat.makeDebugAllocator();
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try compat.argsAlloc(allocator);
    defer compat.argsFree(allocator, args);

    if (args.len < 3) {
        var msg_buf: [512]u8 = undefined;
        const msg = try std.fmt.bufPrint(&msg_buf,
            \\usage:
            \\  {s} emit       <out.bin>
            \\  {s} verify     <orig.bin> <returned.bin>
            \\  {s} roundtrip  <scratch.bin>
            \\
        , .{ args[0], args[0], args[0] });
        compat.stderrWrite(msg);
        std.process.exit(2);
    }

    const cmd = args[1];
    if (std.mem.eql(u8, cmd, "emit")) {
        try cmdEmit(allocator, args[2]);
    } else if (std.mem.eql(u8, cmd, "verify")) {
        if (args.len < 4) std.process.exit(2);
        const code = try cmdVerify(allocator, args[2], args[3]);
        std.process.exit(code);
    } else if (std.mem.eql(u8, cmd, "roundtrip")) {
        const code = try cmdRoundtrip(allocator, args[2]);
        std.process.exit(code);
    } else {
        std.process.exit(2);
    }
}
