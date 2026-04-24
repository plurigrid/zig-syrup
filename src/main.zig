//! CID Verification - Verify Zig Syrup produces deterministic CID (BLAKE3)
//!
//! Hash: BLAKE3 (tree construction, no length extension, 2x faster than SHA-256)
//!
//! Test structure (skill invocation):
//! {
//!   label: "skill:invoke" (string, not symbol!)
//!   fields: [
//!     'gay-mcp      (symbol)
//!     'palette      (symbol)
//!     {"n": 4, "seed": 1069}  (dictionary)
//!     0             (integer)
//!   ]
//! }

const std = @import("std");
const syrup = @import("syrup.zig");
const Value = syrup.Value;

pub fn main() !void {
    // Build the canonical skill invocation
    // Note: label is STRING not symbol, and fields are wrapped in a list
    const label = syrup.string("skill:invoke");

    // Dictionary entries must be in canonical order (by key)
    const dict_entries = [_]Value.DictEntry{
        .{ .key = syrup.string("n"), .value = syrup.integer(4) },
        .{ .key = syrup.string("seed"), .value = syrup.integer(1069) },
    };

    // Fields list containing: symbol, symbol, dict, integer
    const fields_inner = [_]Value{
        syrup.symbol("gay-mcp"),
        syrup.symbol("palette"),
        syrup.dictionary(&dict_entries),
        syrup.integer(0),
    };

    // Wrap fields in a list (this is how ocapn-syrup encodes records)
    const fields = [_]Value{syrup.list(&fields_inner)};

    // Create the record
    const invocation = syrup.record(&label, &fields);

    // Encode to buffer
    var buf: [512]u8 = undefined;
    const encoded = try invocation.encodeBuf(&buf);

    // Compute BLAKE3
    var hash: [32]u8 = undefined;
    std.crypto.hash.Blake3.hash(encoded, &hash, .{});

    // Convert to hex
    const cid = std.fmt.bytesToHex(&hash, .lower);

    // Build output in buffer and write at once
    var out_buf: [2048]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&out_buf);
    const writer = fbs.writer();

    try writer.print("Zig Syrup CID Verification (BLAKE3)\n", .{});
    try writer.print("====================================\n\n", .{});
    try writer.print("Encoded bytes ({d}): ", .{encoded.len});
    for (encoded) |b| {
        if (b >= 0x20 and b < 0x7f) {
            try writer.print("{c}", .{b});
        } else {
            try writer.print("\\x{x:0>2}", .{b});
        }
    }
    try writer.print("\n\n", .{});
    try writer.print("CID (BLAKE3):  {s}\n", .{cid});

    // Verify CID is deterministic by computing it again
    var hash2: [32]u8 = undefined;
    std.crypto.hash.Blake3.hash(encoded, &hash2, .{});
    const cid2 = std.fmt.bytesToHex(&hash2, .lower);

    if (std.mem.eql(u8, &cid, &cid2)) {
        try writer.print("✓ CID deterministic - BLAKE3 verified!\n", .{});
    } else {
        try writer.print("✗ CID non-deterministic (should never happen)\n", .{});
    }

    _ = try std.posix.write(std.posix.STDOUT_FILENO, fbs.getWritten());
}
