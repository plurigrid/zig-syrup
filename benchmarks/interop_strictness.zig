//! Does upstream's new decoder strictness reject bytes another conforming
//! implementation still emits?
//!
//! `2bc815b` taught the decoder to refuse non-canonical integers, lengths and
//! bigints, and `37e5e6a` added `TrailingData`. Tightening a wire format is
//! correct in the abstract and a compatibility hazard in practice: the repo's
//! own tests only prove Zig agrees with Zig. This reads a corpus produced
//! entirely by ocapn-test-suite's contrib/syrup.py — an independent
//! implementation that has never seen this code — and asks two questions per
//! case:
//!
//!   1. does `decode()` accept it at all, and
//!   2. is what we re-encode a canonical fixpoint?
//!
//! (2) is deliberately NOT "reproduces the peer's bytes exactly". The decoder
//! normalizes out-of-order dictionary and set members, so for non-canonical
//! input the emitted bytes SHOULD differ from what arrived; those cases are
//! counted as `normalized`. What must hold is that the output survives another
//! decode/encode round unchanged, which is what keeps `computeCid` one digest
//! per value instead of one per wire permutation. A non-fixpoint is the quiet
//! failure: both sides decode fine but disagree on canonical form.
//!
//! Input: `<name>\t<hex>` lines on stdin. Exit code is the failure count.
const std = @import("std");
const syrup = @import("syrup");

fn hexNibble(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

pub fn main() !void {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    // The corpus is small and fully known; slurping it keeps this free of the
    // 0.17 reader API, which is still moving.
    const stdin_data = try readAllStdin(gpa);
    defer gpa.free(stdin_data);

    var accepted: usize = 0;
    var rejected: usize = 0;
    var mismatched: usize = 0;
    var normalized: usize = 0;

    var lines = std.mem.tokenizeScalar(u8, stdin_data, '\n');
    while (lines.next()) |line| {
        const tab = std.mem.indexOfScalar(u8, line, '\t') orelse continue;
        const name = line[0..tab];
        const hex = std.mem.trim(u8, line[tab + 1 ..], " \r\t");

        const bytes = try gpa.alloc(u8, hex.len / 2);
        defer gpa.free(bytes);
        for (bytes, 0..) |*b, i| {
            const hi = hexNibble(hex[i * 2]) orelse return error.BadHex;
            const lo = hexNibble(hex[i * 2 + 1]) orelse return error.BadHex;
            b.* = hi * 16 + lo;
        }

        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const a = arena.allocator();

        const value = syrup.decode(bytes, a) catch |err| {
            rejected += 1;
            std.debug.print("REJECTED  {s:<18} {s}  bytes={s}\n", .{ name, @errorName(err), hex });
            continue;
        };
        accepted += 1;

        // Re-encode. Matching the peer's bytes exactly is the expected result
        // for canonical input, but a decoder that normalizes out-of-order
        // members deliberately produces DIFFERENT bytes than it received —
        // that is the point of normalizing, not a defect. So the property
        // checked here is a canonical fixpoint: whatever we emit must survive
        // another decode/encode round unchanged. That is what makes `computeCid`
        // one digest per value rather than one per wire permutation.
        var buf: [8192]u8 = undefined;
        const re = value.encodeBuf(&buf) catch |err| {
            mismatched += 1;
            std.debug.print("REENCODE  {s:<18} {s}\n", .{ name, @errorName(err) });
            continue;
        };

        var buf2: [8192]u8 = undefined;
        const re2 = blk: {
            const v2 = syrup.decode(re, a) catch |err| {
                std.debug.print("REDECODE  {s:<18} {s}\n", .{ name, @errorName(err) });
                break :blk null;
            };
            break :blk v2.encodeBuf(&buf2) catch null;
        };

        if (re2 == null or !std.mem.eql(u8, re, re2.?)) {
            mismatched += 1;
            std.debug.print("NOTFIXPT  {s:<18} re-encoding is not a fixpoint\n", .{name});
        } else if (!std.mem.eql(u8, re, bytes)) {
            normalized += 1;
            std.debug.print("NORMALIZ  {s:<18} peer bytes were not canonical; sorted on decode\n", .{name});
        }
    }

    std.debug.print(
        "\ninterop-strictness: {d} accepted ({d} normalized), {d} rejected, {d} non-fixpoint\n",
        .{ accepted, normalized, rejected, mismatched },
    );
    if (rejected + mismatched != 0) return error.InteropFailure;
}

fn readAllStdin(gpa: std.mem.Allocator) ![]u8 {
    var list: std.ArrayListUnmanaged(u8) = .empty;
    errdefer list.deinit(gpa);
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = std.posix.read(0, &buf) catch |err| switch (err) {
            error.WouldBlock => continue,
            else => return err,
        };
        if (n == 0) break;
        try list.appendSlice(gpa, buf[0..n]);
    }
    return list.toOwnedSlice(gpa);
}
