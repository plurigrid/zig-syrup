//! QRTP Frame: QR Transfer Protocol Framing as Syrup Records
//!
//! Encodes fountain-coded blocks as Syrup records for transport over
//! QR codes, TCP, or any byte-oriented channel.
//!
//! Inspired by Orion Reed's QR Transfer Protocols:
//!   https://www.orionreed.com/posts/qrtp/
//!
//! Frame format (Syrup record):
//!   {
//!     "qrtp"          : symbol tag
//!     "seed"          : u64 session seed
//!     "idx"           : u32 block index
//!     "k"             : u16 total source blocks
//!     "deg"           : u8 degree (XOR count)
//!     "src"           : list of u16 source indices
//!     "payload"       : bytestring encoded block
//!   }
//!
//! The same frame format works over TCP (message_frame.zig framing)
//! or over QR (each frame = one QR code payload).
//!
//! GF(3) trit: 0 (ERGODIC) — bridges encoder↔decoder, transport-agnostic

const std = @import("std");
const fountain = @import("fountain.zig");

// =============================================================================
// Constants
// =============================================================================

/// QRTP protocol version
pub const PROTOCOL_VERSION: u8 = 1;

/// Maximum serialized frame size (fits in QR code at ECC-M, version 40)
pub const MAX_FRAME_SIZE: usize = 2953;

/// Magic tag for QRTP frames
pub const FRAME_TAG: *const [4]u8 = "qrtp";

/// Minimum header overhead (tag + version + seed + idx + k + deg + src_len_prefix)
const MIN_HEADER: usize = 4 + 1 + 8 + 4 + 2 + 1 + 2;

// =============================================================================
// QRTP Frame
// =============================================================================

/// A serialized QRTP frame ready for transport.
pub const QrtpFrame = struct {
    /// Raw serialized bytes
    data: [MAX_FRAME_SIZE]u8 = undefined,
    /// Actual length of serialized data
    len: usize = 0,

    /// Get the serialized frame as a slice.
    pub fn bytes(self: *const QrtpFrame) []const u8 {
        return self.data[0..self.len];
    }
};

/// Parsed QRTP frame fields (zero-copy view into buffer).
pub const ParsedFrame = struct {
    version: u8,
    seed: u64,
    block_index: u32,
    num_source_blocks: u16,
    degree: u8,
    source_indices: []const u16,
    payload: []const u8,
};

// =============================================================================
// Serialization (Compact Binary)
// =============================================================================

/// Serialize a fountain EncodedBlock into a QRTP frame.
/// Uses a compact binary encoding (not full Syrup, but Syrup-compatible layout).
pub fn encodeFrame(block: *const fountain.EncodedBlock) QrtpFrame {
    var frame = QrtpFrame{};
    var pos: usize = 0;

    // Tag: "qrtp" (4 bytes)
    @memcpy(frame.data[pos..][0..4], FRAME_TAG);
    pos += 4;

    // Version (1 byte)
    frame.data[pos] = PROTOCOL_VERSION;
    pos += 1;

    // Session seed (8 bytes, big-endian)
    writeU64BE(frame.data[pos..], block.seed);
    pos += 8;

    // Block index (4 bytes, big-endian)
    writeU32BE(frame.data[pos..], block.block_index);
    pos += 4;

    // Number of source blocks (2 bytes, big-endian)
    writeU16BE(frame.data[pos..], block.num_source_blocks);
    pos += 2;

    // Degree (1 byte)
    frame.data[pos] = block.degree;
    pos += 1;

    // Source indices: count (1 byte) + indices (2 bytes each)
    frame.data[pos] = block.degree;
    pos += 1;
    for (0..block.degree) |i| {
        writeU16BE(frame.data[pos..], block.source_indices[i]);
        pos += 2;
    }

    // Payload length (2 bytes, big-endian) + payload bytes
    const payload_len: u16 = @intCast(block.payload_len);
    writeU16BE(frame.data[pos..], payload_len);
    pos += 2;
    @memcpy(frame.data[pos .. pos + block.payload_len], block.payload[0..block.payload_len]);
    pos += block.payload_len;

    frame.len = pos;
    return frame;
}

/// Deserialize a QRTP frame back into a fountain EncodedBlock.
pub fn decodeFrame(data: []const u8) DecodeError!fountain.EncodedBlock {
    if (data.len < MIN_HEADER) return DecodeError.FrameTooShort;

    var pos: usize = 0;

    // Verify tag
    if (!std.mem.eql(u8, data[pos..][0..4], FRAME_TAG))
        return DecodeError.InvalidTag;
    pos += 4;

    // Version
    const version = data[pos];
    if (version != PROTOCOL_VERSION) return DecodeError.UnsupportedVersion;
    pos += 1;

    // Session seed
    const seed = readU64BE(data[pos..]);
    pos += 8;

    // Block index
    const block_index = readU32BE(data[pos..]);
    pos += 4;

    // Number of source blocks
    const num_source_blocks = readU16BE(data[pos..]);
    pos += 2;

    // Degree
    const degree = data[pos];
    pos += 1;

    // Source indices
    const src_count = data[pos];
    pos += 1;
    if (src_count != degree) return DecodeError.DegreeIndexMismatch;
    if (pos + @as(usize, src_count) * 2 > data.len) return DecodeError.FrameTooShort;

    var block = fountain.EncodedBlock{
        .seed = seed,
        .block_index = block_index,
        .num_source_blocks = num_source_blocks,
        .degree = degree,
    };

    for (0..src_count) |i| {
        block.source_indices[i] = readU16BE(data[pos..]);
        pos += 2;
    }

    // Payload
    if (pos + 2 > data.len) return DecodeError.FrameTooShort;
    const payload_len = readU16BE(data[pos..]);
    pos += 2;
    if (pos + payload_len > data.len) return DecodeError.FrameTooShort;
    if (payload_len > fountain.DEFAULT_BLOCK_SIZE) return DecodeError.PayloadTooLarge;

    @memset(&block.payload, 0);
    @memcpy(block.payload[0..payload_len], data[pos .. pos + payload_len]);
    block.payload_len = payload_len;

    return block;
}

pub const DecodeError = error{
    FrameTooShort,
    InvalidTag,
    UnsupportedVersion,
    DegreeIndexMismatch,
    PayloadTooLarge,
};

// =============================================================================
// Session Metadata Frame
// =============================================================================

/// Session start frame: announces K (source block count) and total payload size.
pub const SessionFrame = struct {
    seed: u64,
    num_source_blocks: u16,
    total_payload_size: u32,
    block_size: u16,
};

/// Magic tag for session announcement frames
pub const SESSION_TAG: *const [4]u8 = "qrts";

pub fn encodeSessionFrame(session: *const SessionFrame) QrtpFrame {
    var frame = QrtpFrame{};
    var pos: usize = 0;

    @memcpy(frame.data[pos..][0..4], SESSION_TAG);
    pos += 4;
    frame.data[pos] = PROTOCOL_VERSION;
    pos += 1;
    writeU64BE(frame.data[pos..], session.seed);
    pos += 8;
    writeU16BE(frame.data[pos..], session.num_source_blocks);
    pos += 2;
    writeU32BE(frame.data[pos..], session.total_payload_size);
    pos += 4;
    writeU16BE(frame.data[pos..], session.block_size);
    pos += 2;

    frame.len = pos;
    return frame;
}

pub fn decodeSessionFrame(data: []const u8) DecodeError!SessionFrame {
    if (data.len < 21) return DecodeError.FrameTooShort;

    var pos: usize = 0;
    if (!std.mem.eql(u8, data[pos..][0..4], SESSION_TAG))
        return DecodeError.InvalidTag;
    pos += 4;

    if (data[pos] != PROTOCOL_VERSION) return DecodeError.UnsupportedVersion;
    pos += 1;

    const seed = readU64BE(data[pos..]);
    pos += 8;
    const k = readU16BE(data[pos..]);
    pos += 2;
    const total = readU32BE(data[pos..]);
    pos += 4;
    const bs = readU16BE(data[pos..]);

    return .{
        .seed = seed,
        .num_source_blocks = k,
        .total_payload_size = total,
        .block_size = bs,
    };
}

// =============================================================================
// Wire Helpers (Big-Endian)
// =============================================================================

fn writeU64BE(buf: []u8, v: u64) void {
    buf[0] = @intCast((v >> 56) & 0xFF);
    buf[1] = @intCast((v >> 48) & 0xFF);
    buf[2] = @intCast((v >> 40) & 0xFF);
    buf[3] = @intCast((v >> 32) & 0xFF);
    buf[4] = @intCast((v >> 24) & 0xFF);
    buf[5] = @intCast((v >> 16) & 0xFF);
    buf[6] = @intCast((v >> 8) & 0xFF);
    buf[7] = @intCast(v & 0xFF);
}

fn readU64BE(buf: []const u8) u64 {
    return @as(u64, buf[0]) << 56 |
        @as(u64, buf[1]) << 48 |
        @as(u64, buf[2]) << 40 |
        @as(u64, buf[3]) << 32 |
        @as(u64, buf[4]) << 24 |
        @as(u64, buf[5]) << 16 |
        @as(u64, buf[6]) << 8 |
        @as(u64, buf[7]);
}

fn writeU32BE(buf: []u8, v: u32) void {
    buf[0] = @intCast((v >> 24) & 0xFF);
    buf[1] = @intCast((v >> 16) & 0xFF);
    buf[2] = @intCast((v >> 8) & 0xFF);
    buf[3] = @intCast(v & 0xFF);
}

fn readU32BE(buf: []const u8) u32 {
    return @as(u32, buf[0]) << 24 |
        @as(u32, buf[1]) << 16 |
        @as(u32, buf[2]) << 8 |
        @as(u32, buf[3]);
}

fn writeU16BE(buf: []u8, v: u16) void {
    buf[0] = @intCast((v >> 8) & 0xFF);
    buf[1] = @intCast(v & 0xFF);
}

fn readU16BE(buf: []const u8) u16 {
    return @as(u16, buf[0]) << 8 | @as(u16, buf[1]);
}

// =============================================================================
// Tests
// =============================================================================

test "encode-decode frame round trip" {
    // Create a fountain block
    const data = "hello QRTP!";
    var enc = fountain.Encoder.init(0xABCD, data);
    const fblock = enc.nextBlock();

    // Serialize to QRTP frame
    const qframe = encodeFrame(&fblock);
    try std.testing.expect(qframe.len > 0);
    try std.testing.expect(qframe.len <= MAX_FRAME_SIZE);

    // Verify tag
    try std.testing.expectEqualSlices(u8, "qrtp", qframe.data[0..4]);

    // Deserialize back
    const decoded = try decodeFrame(qframe.bytes());
    try std.testing.expectEqual(fblock.seed, decoded.seed);
    try std.testing.expectEqual(fblock.block_index, decoded.block_index);
    try std.testing.expectEqual(fblock.num_source_blocks, decoded.num_source_blocks);
    try std.testing.expectEqual(fblock.degree, decoded.degree);
    try std.testing.expectEqual(fblock.payload_len, decoded.payload_len);
    try std.testing.expectEqualSlices(
        u8,
        fblock.payload[0..fblock.payload_len],
        decoded.payload[0..decoded.payload_len],
    );
}

test "frame with multiple source indices" {
    // Create multi-block payload
    var data: [fountain.DEFAULT_BLOCK_SIZE * 3]u8 = undefined;
    for (&data, 0..) |*b, i| b.* = @intCast(i % 251);

    var enc = fountain.Encoder.init(0x1234, &data);

    // Generate several blocks, some will have degree > 1
    for (0..20) |_| {
        const fblock = enc.nextBlock();
        const qframe = encodeFrame(&fblock);

        // Round-trip must preserve all fields
        const decoded = try decodeFrame(qframe.bytes());
        try std.testing.expectEqual(fblock.seed, decoded.seed);
        try std.testing.expectEqual(fblock.degree, decoded.degree);
        try std.testing.expectEqual(fblock.payload_len, decoded.payload_len);
    }
}

test "session frame round trip" {
    const session = SessionFrame{
        .seed = 0xDEADBEEFCAFEBABE,
        .num_source_blocks = 8,
        .total_payload_size = 2048,
        .block_size = fountain.DEFAULT_BLOCK_SIZE,
    };

    const frame = encodeSessionFrame(&session);
    const decoded = try decodeSessionFrame(frame.bytes());

    try std.testing.expectEqual(session.seed, decoded.seed);
    try std.testing.expectEqual(session.num_source_blocks, decoded.num_source_blocks);
    try std.testing.expectEqual(session.total_payload_size, decoded.total_payload_size);
    try std.testing.expectEqual(session.block_size, decoded.block_size);
}

test "decode rejects invalid tag" {
    var bad_data: [64]u8 = undefined;
    @memcpy(bad_data[0..4], "nope");
    try std.testing.expectError(DecodeError.InvalidTag, decodeFrame(&bad_data));
}

test "decode rejects truncated frame" {
    const short = [_]u8{ 'q', 'r', 't', 'p' };
    try std.testing.expectError(DecodeError.FrameTooShort, decodeFrame(&short));
}

test "full encode-transport-decode pipeline" {
    // Simulate: payload → fountain encode → QRTP frame → QRTP decode → fountain decode → payload
    const original = "Air-gapped identity proof via QRTP fountain codes. No internet needed!";
    const seed: u64 = 0x42;

    // Encoder side
    var enc = fountain.Encoder.init(seed, original);
    const k = enc.sourceCount();

    // Decoder side
    var dec = fountain.Decoder.init(seed, k);

    // Transport loop: encode → frame → unframe → decode
    var blocks_sent: u32 = 0;
    while (!dec.isComplete()) : (blocks_sent += 1) {
        // Generate fountain block
        const fblock = enc.nextBlock();

        // Serialize to QRTP wire format
        const qframe = encodeFrame(&fblock);

        // <<< QR code / TCP / any transport would happen here >>>

        // Deserialize from wire format
        var decoded = try decodeFrame(qframe.bytes());

        // Feed to decoder
        _ = dec.processBlock(&decoded);

        if (blocks_sent > k * 20) break;
    }

    try std.testing.expect(dec.isComplete());

    var out: [1024]u8 = undefined;
    const len = dec.reassemble(&out).?;
    try std.testing.expectEqualSlices(u8, original, out[0..len]);
}
