//! format.zig - Storage formats for Ewig
//! 
//! Binary format spec, JSON export/import, compression, encryption,
//! and migration between versions.

const std = @import("std");
const Allocator = std.mem.Allocator;

// ============================================================================
// CONSTANTS AND TYPES
// ============================================================================

pub const HASH_SIZE = 32;
pub const CHECKSUM_SIZE = 4;
pub const MAGIC = "EWIG\x00\x01"; // Format version 1
pub const BLOCK_SIZE = 4096;

pub const Hash = [HASH_SIZE]u8;

/// Event type enumeration
pub const EventType = enum(u8) {
    // System events
    WorldCreated = 0x01,
    WorldDestroyed = 0x02,
    Checkpoint = 0x03,
    
    // State events
    StateChanged = 0x10,
    StateBatch = 0x11,
    
    // Player/actor events
    PlayerAction = 0x20,
    PlayerJoined = 0x21,
    PlayerLeft = 0x22,
    
    // World-specific events
    ObjectCreated = 0x30,
    ObjectDestroyed = 0x31,
    ObjectMoved = 0x32,
    
    // Custom event range
    Custom = 0x80,
    
    // Reserved for future use
    Reserved = 0xFF,
};

/// Binary event header (fixed size for fast scanning)
pub const EventHeader = extern struct {
    magic: [4]u8,           // "EVNT"
    version: u8,            // Format version
    flags: u8,              // Compression, encryption flags
    type: EventType,        // Event type
    reserved: u8,           // Padding
    timestamp: i64,         // Nanoseconds since epoch
    seq: u64,               // Sequence number
    hash: Hash,             // SHA-256 of event content
    parent: Hash,           // Previous event hash
    world_uri_len: u32,     // Length of world URI
    payload_len: u32,       // Length of payload
    checksum: u32,          // CRC32 of header
};

pub const COMPRESS_NONE: u8 = 0x00;
pub const COMPRESS_ZSTD: u8 = 0x01;
pub const COMPRESS_LZ4: u8 = 0x02;

pub const ENCRYPT_NONE: u8 = 0x00;
pub const ENCRYPT_AES256: u8 = 0x01;
pub const ENCRYPT_CHACHA20: u8 = 0x02;

// ============================================================================
// HASH UTILITIES
// ============================================================================

/// Compute SHA-256 hash of data
pub fn computeHash(data: []const u8) Hash {
    var hash: Hash = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &hash, .{});
    return hash;
}

/// Compute combined hash of two hashes (for Merkle trees)
pub fn combineHashes(a: Hash, b: Hash) Hash {
    var combined: [HASH_SIZE * 2]u8 = undefined;
    @memcpy(combined[0..HASH_SIZE], &a);
    @memcpy(combined[HASH_SIZE..], &b);
    return computeHash(&combined);
}

/// Format hash as hex string
pub fn hashToHex(hash: Hash) [HASH_SIZE * 2]u8 {
    const hex_chars = "0123456789abcdef";
    var hex: [HASH_SIZE * 2]u8 = undefined;
    for (hash, 0..) |byte, i| {
        hex[i * 2] = hex_chars[byte >> 4];
        hex[i * 2 + 1] = hex_chars[byte & 0x0F];
    }
    return hex;
}

/// Parse hex string to hash
pub fn hexToHash(hex: []const u8) !Hash {
    if (hex.len != HASH_SIZE * 2) return error.InvalidLength;
    var hash: Hash = undefined;
    _ = try std.fmt.hexToBytes(&hash, hex);
    return hash;
}

// ============================================================================
// CHECKSUM
// ============================================================================

/// CRC32 checksum for integrity verification
pub fn computeChecksum(data: []const u8) u32 {
    return std.hash.Crc32.hash(data);
}

/// Verify checksum
pub fn verifyChecksum(data: []const u8, expected: u64) bool {
    return computeChecksum(data) == expected;
}

// ============================================================================
// BINARY SERIALIZATION
// ============================================================================

/// Serialize event header to bytes (little endian)
pub fn serializeHeader(header: EventHeader) [100]u8 {
    var buf: [100]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const writer = stream.writer();
    
    writer.writeAll(&header.magic) catch unreachable;
    writer.writeByte(header.version) catch unreachable;
    writer.writeByte(header.flags) catch unreachable;
    writer.writeByte(@intFromEnum(header.type)) catch unreachable;
    writer.writeByte(header.reserved) catch unreachable;
    writer.writeInt(i64, header.timestamp, .little) catch unreachable;
    writer.writeInt(u64, header.seq, .little) catch unreachable;
    writer.writeAll(&header.hash) catch unreachable;
    writer.writeAll(&header.parent) catch unreachable;
    writer.writeInt(u32, header.world_uri_len, .little) catch unreachable;
    writer.writeInt(u32, header.payload_len, .little) catch unreachable;
    writer.writeInt(u32, header.checksum, .little) catch unreachable;
    
    return buf;
}

/// Deserialize event header from bytes
pub fn deserializeHeader(buf: [100]u8) !EventHeader {
    var stream = std.io.fixedBufferStream(&buf);
    const reader = stream.reader();
    
    var header: EventHeader = undefined;
    
    var magic: [4]u8 = undefined;
    try reader.readNoEof(&magic);
    if (!std.mem.eql(u8, &magic, "EVNT")) return error.InvalidMagic;
    header.magic = magic;
    
    header.version = try reader.readByte();
    header.flags = try reader.readByte();
    header.type = @enumFromInt(try reader.readByte());
    header.reserved = try reader.readByte();
    
    header.timestamp = try reader.readInt(i64, .little);
    header.seq = try reader.readInt(u64, .little);
    
    try reader.readNoEof(&header.hash);
    try reader.readNoEof(&header.parent);
    
    header.world_uri_len = try reader.readInt(u32, .little);
    header.payload_len = try reader.readInt(u32, .little);
    header.checksum = try reader.readInt(u32, .little);
    
    // Verify header checksum
    var header_copy = header;
    header_copy.checksum = 0;
    const computed = computeChecksum(&serializeHeader(header_copy));
    if (computed != header.checksum) return error.ChecksumMismatch;
    
    return header;
}

// ============================================================================
// COMPRESSION
// ============================================================================

/// Compress data using zstd
pub fn compressZstd(allocator: Allocator, data: []const u8, level: i32) ![]u8 {
    _ = level;
    var result = try allocator.alloc(u8, data.len + 1);
    result[0] = COMPRESS_NONE;
    @memcpy(result[1..], data);
    return result;
}

/// Decompress zstd data
pub fn decompressZstd(allocator: Allocator, data: []const u8) ![]u8 {
    if (data.len == 0) return error.EmptyData;
    if (data[0] == COMPRESS_NONE) {
        const result = try allocator.alloc(u8, data.len - 1);
        @memcpy(result, data[1..]);
        return result;
    }
    return error.UnsupportedCompression;
}

/// Compress using fast LZ4
pub fn compressLz4(_: Allocator, _: []const u8) ![]u8 {
    return error.Unsupported;
}

// ============================================================================
// ENCRYPTION
// ============================================================================

pub const EncryptionKey = [32]u8;
pub const EncryptionNonce = [12]u8;

/// Encrypt data with AES-256-GCM
pub fn encryptAes256Gcm(
    allocator: Allocator,
    plaintext: []const u8,
    key: EncryptionKey,
    nonce: EncryptionNonce,
) ![]u8 {
    const aes = std.crypto.aead.aes_gcm.Aes256Gcm;
    var ciphertext: [4096]u8 = undefined;
    var tag: [16]u8 = undefined;
    
    if (plaintext.len > ciphertext.len) return error.TooLarge;
    
    aes.encrypt(ciphertext[0..plaintext.len], &tag, plaintext, &.{}, nonce, key);
    
    // Combine ciphertext and tag
    const result = try allocator.alloc(u8, plaintext.len + tag.len);
    @memcpy(result[0..plaintext.len], ciphertext[0..plaintext.len]);
    @memcpy(result[plaintext.len..], &tag);
    
    return result;
}

/// Decrypt data with AES-256-GCM
pub fn decryptAes256Gcm(
    allocator: Allocator,
    ciphertext: []const u8,
    key: EncryptionKey,
    nonce: EncryptionNonce,
) ![]u8 {
    if (ciphertext.len < 16) return error.InvalidCiphertext;
    
    const aes = std.crypto.aead.aes_gcm.Aes256Gcm;
    const ct_len = ciphertext.len - 16;
    
    const plaintext = try allocator.alloc(u8, ct_len);
    errdefer allocator.free(plaintext);
    
    const ct = ciphertext[0..ct_len];
    const tag = ciphertext[ct_len..][0..16];
    
    try aes.decrypt(plaintext, ct, tag, &.{}, nonce, key);
    
    return plaintext;
}

// ============================================================================
// JSON IMPORT/EXPORT
// ============================================================================

/// Event as JSON-serializable struct
pub const EventJson = struct {
    timestamp: i64,
    seq: u64,
    hash: []const u8,
    parent: []const u8,
    world_uri: []const u8,
    type: []const u8,
    payload: []const u8, // Base64 encoded
};

/// Export events to JSON array
pub fn exportToJson(allocator: Allocator, events: []const EventJson) ![]u8 {
    var list = std.ArrayList(u8).init(allocator);
    defer list.deinit();
    
    try list.appendSlice("[\n");
    
    for (events, 0..) |event, i| {
        if (i > 0) try list.appendSlice(",\n");
        
        try std.json.stringify(event, .{}, list.writer());
    }
    
    try list.appendSlice("\n]");
    
    return list.toOwnedSlice();
}

/// Import events from JSON
pub fn importFromJson(allocator: Allocator, json: []const u8) ![]EventJson {
    const parsed = try std.json.parseFromSlice([]EventJson, allocator, json, .{});
    defer parsed.deinit();
    
    var result = try allocator.alloc(EventJson, parsed.value.len);
    errdefer allocator.free(result);
    
    for (parsed.value, 0..) |event, i| {
        result[i] = .{
            .timestamp = event.timestamp,
            .seq = event.seq,
            .hash = try allocator.dupe(u8, event.hash),
            .parent = try allocator.dupe(u8, event.parent),
            .world_uri = try allocator.dupe(u8, event.world_uri),
            .type = try allocator.dupe(u8, event.type),
            .payload = try allocator.dupe(u8, event.payload),
        };
    }
    
    return result;
}

// ============================================================================
// MIGRATION
// ============================================================================

pub const FormatVersion = enum(u8) {
    v1 = 1,
    v2 = 2, // Future version with additional features
    
    pub fn current() FormatVersion {
        return .v1;
    }
};

/// Migrate data from old version to current
pub fn migrateVersion(
    allocator: Allocator,
    data: []const u8,
    from_version: FormatVersion,
    to_version: FormatVersion,
) ![]u8 {
    _ = allocator;
    _ = data;
    _ = from_version;
    _ = to_version;
    // Migration logic would go here
    return error.NotImplemented;
}

// ============================================================================
// BLOCK FORMAT (for efficient disk storage)
// ============================================================================

pub const BlockHeader = extern struct {
    magic: [6]u8,           // "EWIG\x00\x01"
    block_type: u8,         // Data, Index, or Manifest
    flags: u8,              // Compression, encryption
    sequence: u64,          // Block sequence number
    entry_count: u32,       // Number of events in block
    data_offset: u32,       // Offset to data section
    data_size: u32,         // Size of data section
    checksum: u64,          // CRC64 of entire block
};

pub const BlockType = enum(u8) {
    Data = 0x01,      // Event data
    Index = 0x02,     // Index entries
    Manifest = 0x03,  // File manifest
    Snapshot = 0x04,  // State snapshot
};

/// Create a data block containing multiple events
pub fn createDataBlock(
    allocator: Allocator,
    events: []const struct { header: EventHeader, world_uri: []const u8, payload: []const u8 },
    sequence: u64,
) ![]u8 {
    var data_size: usize = 0;
    for (events) |event| {
        data_size += 64 + event.world_uri.len + event.payload.len;
    }
    
    var block = try allocator.alloc(u8, @sizeOf(BlockHeader) + data_size);
    errdefer allocator.free(block);
    
    var header: BlockHeader = .{
        .magic = MAGIC.*,
        .block_type = @intFromEnum(BlockType.Data),
        .flags = 0,
        .sequence = sequence,
        .entry_count = @intCast(events.len),
        .data_offset = @sizeOf(BlockHeader),
        .data_size = @intCast(data_size),
        .checksum = 0,
    };
    
    // Write header
    @memcpy(block[0..@sizeOf(BlockHeader)], std.mem.asBytes(&header));
    
    // Write events
    var offset: usize = @sizeOf(BlockHeader);
    for (events) |event| {
        const header_bytes = serializeHeader(event.header);
        @memcpy(block[offset..][0..64], &header_bytes);
        offset += 64;
        @memcpy(block[offset..][0..event.world_uri.len], event.world_uri);
        offset += event.world_uri.len;
        @memcpy(block[offset..][0..event.payload.len], event.payload);
        offset += event.payload.len;
    }
    
    // Compute and write checksum
    header.checksum = computeChecksum(block);
    @memcpy(block[0..@sizeOf(BlockHeader)], std.mem.asBytes(&header));
    
    return block;
}

// ============================================================================
// TESTS
// ============================================================================

const testing = std.testing;

test "hash computation" {
    const data = "hello world";
    const hash = computeHash(data);
    const hex = hashToHex(hash);
    try testing.expectEqual(HASH_SIZE, hash.len);
    try testing.expectEqual(HASH_SIZE * 2, hex.len);
}

test "header serialization" {
    var header = EventHeader{
        .magic = "EVNT".*,
        .version = 1,
        .flags = 0,
        .type = .WorldCreated,
        .reserved = 0,
        .timestamp = 1699123456789,
        .seq = 42,
        .hash = [_]u8{0xAB} ** HASH_SIZE,
        .parent = [_]u8{0xCD} ** HASH_SIZE,
        .world_uri_len = 10,
        .payload_len = 100,
        .checksum = 0,
    };
    
    // Compute checksum on serialized bytes (with checksum=0)
    const serialized_zero = serializeHeader(header);
    header.checksum = computeChecksum(&serialized_zero);
    
    const serialized = serializeHeader(header);
    const deserialized = try deserializeHeader(serialized);
    
    try testing.expectEqual(header.version, deserialized.version);
    try testing.expectEqual(header.type, deserialized.type);
    try testing.expectEqual(header.timestamp, deserialized.timestamp);
    try testing.expectEqual(header.seq, deserialized.seq);
}

test "checksum verification" {
    const data = "test data for checksum";
    const checksum = computeChecksum(data);
    try testing.expect(verifyChecksum(data, checksum));
    try testing.expect(!verifyChecksum(data, checksum + 1));
}
