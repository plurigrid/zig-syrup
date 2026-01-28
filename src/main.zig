//! CID Verification - Verify Zig Syrup produces identical CID to BB/JS/PY/Rust
//!
//! Canonical CID: 06fe1dc709bea744f8a0e1cd767210cd90f2b78200f574497e876c2778fa7ffb
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

    // Compute SHA256
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(encoded, &hash, .{});

    // Convert to hex
    const cid = std.fmt.bytesToHex(&hash, .lower);

    const expected = "06fe1dc709bea744f8a0e1cd767210cd90f2b78200f574497e876c2778fa7ffb";

    // Build output in buffer and write at once
    var out_buf: [2048]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&out_buf);
    const writer = fbs.writer();

    try writer.print("Zig Syrup CID Verification\n", .{});
    try writer.print("==========================\n\n", .{});
    try writer.print("Encoded bytes ({d}): ", .{encoded.len});
    for (encoded) |b| {
        if (b >= 0x20 and b < 0x7f) {
            try writer.print("{c}", .{b});
        } else {
            try writer.print("\\x{x:0>2}", .{b});
        }
    }
    try writer.print("\n\n", .{});
    try writer.print("CID (SHA256):  {s}\n", .{cid});
    try writer.print("Expected:      {s}\n", .{expected});
    try writer.print("\n", .{});

    if (std.mem.eql(u8, &cid, expected)) {
        try writer.print("✓ CID MATCH - Zig implementation verified!\n", .{});
    } else {
        try writer.print("✗ CID MISMATCH\n", .{});
        try writer.print("\nDebug: Raw encoded hex: ", .{});
        for (encoded) |b| {
            try writer.print("{x:0>2}", .{b});
        }
        try writer.print("\n", .{});
    }

    // Write everything to stdout
    _ = try std.posix.write(std.posix.STDOUT_FILENO, fbs.getWritten());

    if (!std.mem.eql(u8, &cid, expected)) {
        return error.CidMismatch;
    }
}
