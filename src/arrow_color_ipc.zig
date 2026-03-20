//! Arrow Color IPC — Zero-copy Arrow IPC as SturdyRef bandwidth for color batches
//!
//! Maps ColorValue batches to a flat Arrow-style columnar layout for zero-copy
//! transfer across process/machine boundaries. The "SturdyRef" is the capability
//! reference that grants access to a color batch buffer: holding the ref means
//! you can read the colors without any deserialization overhead.
//!
//! Layout (Arrow IPC RecordBatch, simplified):
//!   [Header: 64 bytes]
//!     magic:          [4]u8 = "ACB\x01"  (Arrow Color Batch v1)
//!     batch_len:      u32   (number of ColorValues in batch)
//!     seed:           u64   (SplitMix64 seed — SturdyRef identity)
//!     schema_cid:     [32]u8 (SHA-256 of schema — capability validation)
//!     trit_checksum:  i8    (GF(3) sum of all trits; 0 = conserved)
//!     flags:          u8    (bit 0: has_infinitesimal, bit 1: has_lineage)
//!     _reserved:      [14]u8
//!   [Column 0: trit_indices]  — u8[batch_len], palette index 0..242
//!   [Column 1: depths]        — u16[batch_len], operadic depth
//!   [Column 2: fingerprints]  — u32[batch_len], seed_fingerprint
//!   [Column 3: eps_dr]        — f16[batch_len], infinitesimal R (optional)
//!   [Column 4: eps_dg]        — f16[batch_len], infinitesimal G (optional)
//!   [Column 5: eps_db]        — f16[batch_len], infinitesimal B (optional)
//!
//! SturdyRef semantics (OCapN CapTP):
//!   - The seed in the header IS the swiss-number: knowing it = having the ref.
//!   - schema_cid validates that sender and receiver agree on the batch schema.
//!   - GF(3) checksum enables integrity verification without full decode.
//!   - Zero-copy: consumer reads column slices directly from the buffer.
//!
//! Wire format:
//!   Wrapped in message_frame.zig 4-byte length prefix for TCP/WebSocket transport.
//!   Can also be mmap'd for shared-memory IPC (the whole point of Arrow).

const std = @import("std");
const color_value = @import("color_value.zig");
const ColorValue = color_value.ColorValue;
const Trit = color_value.Trit;
const Infinitesimal = color_value.Infinitesimal;

pub const MAGIC: [4]u8 = .{ 'A', 'C', 'B', 0x01 };
pub const HEADER_SIZE: usize = 64;
pub const MAX_BATCH: u32 = 65536;
pub const SCHEMA_VERSION: u8 = 1;

pub const Flags = packed struct {
    has_infinitesimal: bool = false,
    has_lineage: bool = false,
    _pad: u6 = 0,
};

pub const Header = extern struct {
    magic: [4]u8 = MAGIC,
    batch_len: u32 = 0,
    seed: u64 = 0,
    schema_cid: [32]u8 = std.mem.zeroes([32]u8),
    trit_checksum: i8 = 0,
    flags: u8 = 0,
    _reserved: [14]u8 = std.mem.zeroes([14]u8),

    comptime {
        std.debug.assert(@sizeOf(Header) == HEADER_SIZE);
    }
};

pub const EncodeError = error{
    BatchTooLarge,
    BufferTooSmall,
};

pub const DecodeError = error{
    InvalidMagic,
    BatchTooLarge,
    BufferTooSmall,
    ChecksumMismatch,
};

// -- Batch layout helpers --

fn batchBufferSize(batch_len: u32, has_eps: bool) usize {
    var size: usize = HEADER_SIZE;
    size += @as(usize, batch_len); // trit_indices: u8
    size += @as(usize, batch_len) * 2; // depths: u16
    size += @as(usize, batch_len) * 4; // fingerprints: u32
    if (has_eps) {
        size += @as(usize, batch_len) * 2 * 3; // eps_dr/dg/db: f16 × 3
    }
    return size;
}

/// Compute the schema CID (BLAKE3 of the column layout descriptor).
fn computeSchemaCid(batch_len: u32, flags: Flags) [32]u8 {
    var hasher = std.crypto.hash.Blake3.init(.{});
    hasher.update(&MAGIC);
    hasher.update(&[_]u8{SCHEMA_VERSION});
    hasher.update(&std.mem.toBytes(batch_len));
    hasher.update(&[_]u8{@bitCast(flags)});
    var cid: [32]u8 = undefined;
    hasher.final(&cid);
    return cid;
}

/// Encode a batch of ColorValues into a zero-copy Arrow IPC buffer.
/// The buffer must be pre-allocated (use `encodedSize` to compute).
/// Returns bytes written.
pub fn encode(colors: []const ColorValue, seed: u64, buf: []u8) EncodeError!usize {
    const n: u32 = @intCast(colors.len);
    if (n > MAX_BATCH) return EncodeError.BatchTooLarge;

    // Detect whether any color carries non-zero infinitesimal
    var has_eps = false;
    var trit_sum: i16 = 0;
    for (colors) |cv| {
        if (cv.eps.normSq() > 0) has_eps = true;
        trit_sum += @intFromEnum(cv.trit());
    }

    const total = batchBufferSize(n, has_eps);
    if (buf.len < total) return EncodeError.BufferTooSmall;

    const flags = Flags{ .has_infinitesimal = has_eps };
    const schema_cid = computeSchemaCid(n, flags);

    // GF(3) checksum: sum of all luminosity trits mod 3, mapped to {-1,0,+1}
    const checksum_mod = @mod(trit_sum + 3000, 3);
    const trit_checksum: i8 = @as(i8, @intCast(checksum_mod)) - 1;
    // Extra safety: if all values check to 0, mark as zero explicitly
    const final_checksum: i8 = if (trit_sum == 0) 0 else trit_checksum;

    // Write header
    var header: Header = .{
        .batch_len = n,
        .seed = seed,
        .schema_cid = schema_cid,
        .trit_checksum = final_checksum,
        .flags = @bitCast(flags),
    };
    const header_bytes: *const [HEADER_SIZE]u8 = @ptrCast(&header);
    @memcpy(buf[0..HEADER_SIZE], header_bytes);

    // Column 0: trit_indices (u8)
    var off: usize = HEADER_SIZE;
    for (colors, 0..) |cv, i| {
        buf[off + i] = cv.trit_word.toIndex();
    }
    off += n;

    // Column 1: depths (u16 little-endian)
    for (colors, 0..) |cv, i| {
        const depth_bytes: [2]u8 = @bitCast(cv.depth);
        buf[off + i * 2] = depth_bytes[0];
        buf[off + i * 2 + 1] = depth_bytes[1];
    }
    off += @as(usize, n) * 2;

    // Column 2: fingerprints (u32 little-endian)
    for (colors, 0..) |cv, i| {
        const fp_bytes: [4]u8 = @bitCast(cv.seed_fingerprint);
        @memcpy(buf[off + i * 4 ..][0..4], &fp_bytes);
    }
    off += @as(usize, n) * 4;

    // Columns 3-5: infinitesimals (f16 × 3, optional)
    if (has_eps) {
        // eps_dr
        for (colors, 0..) |cv, i| {
            const bytes: [2]u8 = @bitCast(cv.eps.dr);
            buf[off + i * 2] = bytes[0];
            buf[off + i * 2 + 1] = bytes[1];
        }
        off += @as(usize, n) * 2;
        // eps_dg
        for (colors, 0..) |cv, i| {
            const bytes: [2]u8 = @bitCast(cv.eps.dg);
            buf[off + i * 2] = bytes[0];
            buf[off + i * 2 + 1] = bytes[1];
        }
        off += @as(usize, n) * 2;
        // eps_db
        for (colors, 0..) |cv, i| {
            const bytes: [2]u8 = @bitCast(cv.eps.db);
            buf[off + i * 2] = bytes[0];
            buf[off + i * 2 + 1] = bytes[1];
        }
        off += @as(usize, n) * 2;
    }

    _ = &header;
    return off;
}

/// Compute the buffer size needed for encoding a batch.
pub fn encodedSize(count: u32, has_infinitesimal: bool) usize {
    return batchBufferSize(count, has_infinitesimal);
}

/// Zero-copy view into an encoded Arrow Color Batch buffer.
/// All slices reference the original buffer — no allocations.
pub const BatchView = struct {
    header: *const Header,
    trit_indices: []const u8,
    depths: []const u8, // raw bytes, read as u16 LE pairs
    fingerprints: []const u8, // raw bytes, read as u32 LE quads
    eps_dr: ?[]const u8, // raw f16 bytes
    eps_dg: ?[]const u8,
    eps_db: ?[]const u8,

    pub fn len(self: BatchView) u32 {
        return self.header.batch_len;
    }

    pub fn seed(self: BatchView) u64 {
        return self.header.seed;
    }

    pub fn tritChecksum(self: BatchView) i8 {
        return self.header.trit_checksum;
    }

    pub fn isConserved(self: BatchView) bool {
        return self.header.trit_checksum == 0;
    }

    pub fn flags(self: BatchView) Flags {
        return @bitCast(self.header.flags);
    }

    /// Read the i-th color as a full ColorValue (reconstruction from columns).
    pub fn colorAt(self: BatchView, i: u32) ColorValue {
        const idx = self.trit_indices[i];
        const word = color_value.TritWord.fromIndex(idx);

        const depth_off = i * 2;
        const depth: u16 = @bitCast([2]u8{ self.depths[depth_off], self.depths[depth_off + 1] });

        const fp_off = i * 4;
        const fp: u32 = @bitCast([4]u8{
            self.fingerprints[fp_off],
            self.fingerprints[fp_off + 1],
            self.fingerprints[fp_off + 2],
            self.fingerprints[fp_off + 3],
        });

        var eps = Infinitesimal.ZERO;
        if (self.eps_dr) |dr_buf| {
            const dr_off = i * 2;
            eps.dr = @bitCast([2]u8{ dr_buf[dr_off], dr_buf[dr_off + 1] });
        }
        if (self.eps_dg) |dg_buf| {
            const dg_off = i * 2;
            eps.dg = @bitCast([2]u8{ dg_buf[dg_off], dg_buf[dg_off + 1] });
        }
        if (self.eps_db) |db_buf| {
            const db_off = i * 2;
            eps.db = @bitCast([2]u8{ db_buf[db_off], db_buf[db_off + 1] });
        }

        return .{
            .trit_word = word,
            .depth = depth,
            .eps = eps,
            .seed_fingerprint = fp,
        };
    }

    /// Verify the GF(3) checksum by scanning all trit indices.
    pub fn verifyChecksum(self: BatchView) bool {
        var sum: i16 = 0;
        for (0..self.header.batch_len) |i| {
            const word = color_value.TritWord.fromIndex(self.trit_indices[i]);
            sum += @intFromEnum(word.luminosity());
        }
        const expected: i8 = if (sum == 0) 0 else blk: {
            const m = @mod(sum + 3000, 3);
            break :blk @as(i8, @intCast(m)) - 1;
        };
        return expected == self.header.trit_checksum;
    }
};

/// Decode a buffer into a zero-copy BatchView. No allocations.
pub fn decode(buf: []const u8) DecodeError!BatchView {
    if (buf.len < HEADER_SIZE) return DecodeError.BufferTooSmall;

    const header: *const Header = @ptrCast(@alignCast(buf[0..HEADER_SIZE].ptr));

    if (!std.mem.eql(u8, &header.magic, &MAGIC)) return DecodeError.InvalidMagic;

    const n = header.batch_len;
    if (n > MAX_BATCH) return DecodeError.BatchTooLarge;

    const fl: Flags = @bitCast(header.flags);
    const required = batchBufferSize(n, fl.has_infinitesimal);
    if (buf.len < required) return DecodeError.BufferTooSmall;

    var off: usize = HEADER_SIZE;

    const trit_indices = buf[off..][0..n];
    off += n;

    const depths = buf[off..][0 .. @as(usize, n) * 2];
    off += @as(usize, n) * 2;

    const fingerprints = buf[off..][0 .. @as(usize, n) * 4];
    off += @as(usize, n) * 4;

    var eps_dr: ?[]const u8 = null;
    var eps_dg: ?[]const u8 = null;
    var eps_db: ?[]const u8 = null;

    if (fl.has_infinitesimal) {
        eps_dr = buf[off..][0 .. @as(usize, n) * 2];
        off += @as(usize, n) * 2;
        eps_dg = buf[off..][0 .. @as(usize, n) * 2];
        off += @as(usize, n) * 2;
        eps_db = buf[off..][0 .. @as(usize, n) * 2];
        off += @as(usize, n) * 2;
    }

    return .{
        .header = header,
        .trit_indices = trit_indices,
        .depths = depths,
        .fingerprints = fingerprints,
        .eps_dr = eps_dr,
        .eps_dg = eps_dg,
        .eps_db = eps_db,
    };
}

/// SturdyRef handle for a color batch.
/// Holding this struct = having the capability to read the batch.
/// The swiss_number (seed) is the unforgeable capability token.
pub const SturdyRef = struct {
    swiss_number: u64,
    schema_cid: [32]u8,
    batch_len: u32,

    /// Construct from an encoded buffer's header.
    pub fn fromBuffer(buf: []const u8) DecodeError!SturdyRef {
        if (buf.len < HEADER_SIZE) return DecodeError.BufferTooSmall;
        const header: *const Header = @ptrCast(@alignCast(buf[0..HEADER_SIZE].ptr));
        if (!std.mem.eql(u8, &header.magic, &MAGIC)) return DecodeError.InvalidMagic;
        return .{
            .swiss_number = header.seed,
            .schema_cid = header.schema_cid,
            .batch_len = header.batch_len,
        };
    }

    /// Validate that a buffer matches this SturdyRef.
    pub fn validates(self: SturdyRef, buf: []const u8) bool {
        const header: *const Header = @ptrCast(@alignCast(buf[0..HEADER_SIZE].ptr));
        return header.seed == self.swiss_number and
            std.mem.eql(u8, &header.schema_cid, &self.schema_cid);
    }

    /// Attempt to decode the buffer only if the SturdyRef validates.
    pub fn access(self: SturdyRef, buf: []const u8) DecodeError!BatchView {
        if (buf.len < HEADER_SIZE) return DecodeError.BufferTooSmall;
        if (!self.validates(buf)) return DecodeError.ChecksumMismatch;
        return decode(buf);
    }
};

// ===========================================================================
// Tests
// ===========================================================================

test "roundtrip encode-decode zero-copy" {
    const colors = [_]ColorValue{
        ColorValue.at(1069, 0),
        ColorValue.at(1069, 1),
        ColorValue.at(1069, 2),
        ColorValue.at(1069, 3),
    };

    const size = encodedSize(4, true);
    var buf: [4096]u8 align(@alignOf(Header)) = undefined;
    const written = try encode(&colors, 1069, &buf);
    try std.testing.expect(written <= size);

    const view = try decode(&buf);
    try std.testing.expectEqual(@as(u32, 4), view.len());
    try std.testing.expectEqual(@as(u64, 1069), view.seed());

    // Verify each color roundtrips
    for (0..4) |i| {
        const original = colors[i];
        const decoded = view.colorAt(@intCast(i));
        try std.testing.expectEqual(original.trit_word.toIndex(), decoded.trit_word.toIndex());
        try std.testing.expectEqual(original.depth, decoded.depth);
        try std.testing.expectEqual(original.seed_fingerprint, decoded.seed_fingerprint);
        try std.testing.expect(original.eps.eql(decoded.eps));
    }
}

test "GF(3) checksum verification" {
    // Conserved triad: +1 + -1 + 0 = 0
    const colors = [_]ColorValue{
        ColorValue.fromTrit(.plus, 0),
        ColorValue.fromTrit(.minus, 0),
        ColorValue.fromTrit(.zero, 0),
    };

    var buf: [4096]u8 align(@alignOf(Header)) = undefined;
    _ = try encode(&colors, 42, &buf);

    const view = try decode(&buf);
    try std.testing.expect(view.isConserved());
    try std.testing.expect(view.verifyChecksum());
}

test "SturdyRef capability gating" {
    const colors = [_]ColorValue{
        ColorValue.at(7777, 0),
        ColorValue.at(7777, 1),
    };

    var buf: [4096]u8 align(@alignOf(Header)) = undefined;
    _ = try encode(&colors, 7777, &buf);

    const ref = try SturdyRef.fromBuffer(&buf);
    try std.testing.expectEqual(@as(u64, 7777), ref.swiss_number);
    try std.testing.expectEqual(@as(u32, 2), ref.batch_len);

    // Valid access
    const view = try ref.access(&buf);
    try std.testing.expectEqual(@as(u32, 2), view.len());

    // Tamper with seed -> SturdyRef rejects
    const header: *Header = @ptrCast(@alignCast(buf[0..HEADER_SIZE].ptr));
    header.seed = 9999;
    const result = ref.access(&buf);
    try std.testing.expectError(DecodeError.ChecksumMismatch, result);
}

test "batch without infinitesimals (compact layout)" {
    const colors = [_]ColorValue{
        ColorValue.fromTrit(.zero, 0),
        ColorValue.fromTrit(.zero, 0),
    };

    const compact_size = encodedSize(2, false);
    const full_size = encodedSize(2, true);
    try std.testing.expect(compact_size < full_size);

    var buf: [4096]u8 align(@alignOf(Header)) = undefined;
    const written = try encode(&colors, 0, &buf);
    try std.testing.expectEqual(compact_size, written);

    const view = try decode(&buf);
    try std.testing.expect(!view.flags().has_infinitesimal);
    try std.testing.expectEqual(Infinitesimal.ZERO, view.colorAt(0).eps);
}

test "header size is exactly 64 bytes" {
    try std.testing.expectEqual(@as(usize, 64), @sizeOf(Header));
    try std.testing.expectEqual(@as(usize, 64), HEADER_SIZE);
}

test "empty batch" {
    const colors = [_]ColorValue{};
    var buf: [128]u8 align(@alignOf(Header)) = undefined;
    const written = try encode(&colors, 0, &buf);
    try std.testing.expectEqual(HEADER_SIZE, written);

    const view = try decode(&buf);
    try std.testing.expectEqual(@as(u32, 0), view.len());
    try std.testing.expect(view.isConserved());
}

test "invalid magic rejected" {
    var buf: [128]u8 align(@alignOf(Header)) = undefined;
    @memset(&buf, 0);
    buf[0] = 'X'; // corrupt magic
    try std.testing.expectError(DecodeError.InvalidMagic, decode(&buf));
}

test "batch too large rejected" {
    var buf: [128]u8 align(@alignOf(Header)) = undefined;
    @memset(&buf, 0);
    @memcpy(buf[0..4], &MAGIC);
    // Write batch_len > MAX_BATCH
    const too_large: u32 = MAX_BATCH + 1;
    const len_bytes: [4]u8 = @bitCast(too_large);
    @memcpy(buf[4..8], &len_bytes);
    try std.testing.expectError(DecodeError.BatchTooLarge, decode(&buf));
}
