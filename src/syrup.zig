//! Syrup: OCapN Canonical Binary Serialization for Zig
//!
//! The most complete Zig implementation of the Syrup serialization format.
//!
//! ## Features
//! - All 11 Syrup value types with full spec compliance
//! - Zero-copy decoding with views into input buffer
//! - Canonical encoding (auto-sorted dicts/sets)
//! - Value comparison (Eq/Ord/Hash on wire format)
//! - Explicit allocator control (no hidden allocations)
//! - No-alloc encoding to fixed buffers
//! - Comptime schema validation (Phase 3)
//! - Freestanding/no-std compatible core
//!
//! ## Zig-Unique Advantages
//! - Comptime type generation from schemas
//! - SIMD-ready parsing primitives
//! - Packed value representations for cache efficiency
//! - Compile-time CID computation
//! - Generic serialization traits
//!
//! Reference: https://github.com/ocapn/syrup

const std = @import("std");
const Allocator = std.mem.Allocator;
const Order = std.math.Order;

// ============================================================================
// CORE TYPES
// ============================================================================

/// BigInt for arbitrary precision integers
pub const BigInt = struct {
    const Self = @This();

    magnitude: []const u8, // Big-endian
    negative: bool,

    pub fn compare(self: Self, other: Self) Order {
        if (self.negative != other.negative) {
            return if (self.negative) .lt else .gt;
        }
        const mag_order = compareMagnitudes(self.magnitude, other.magnitude);
        return if (self.negative) mag_order.invert() else mag_order;
    }

    fn compareMagnitudes(a: []const u8, b: []const u8) Order {
        // Strip leading zeros using std.mem.trimLeft
        const a_trimmed = std.mem.trimLeft(u8, a, &.{0});
        const b_trimmed = std.mem.trimLeft(u8, b, &.{0});
        const len_cmp = std.math.order(a_trimmed.len, b_trimmed.len);
        return if (len_cmp != .eq) len_cmp else std.mem.order(u8, a_trimmed, b_trimmed);
    }

    pub fn toI128(self: Self) ?i128 {
        if (self.magnitude.len > 16) return null;
        var value: u128 = 0;
        for (self.magnitude) |byte| value = (value << 8) | byte;
        if (value > @as(u128, std.math.maxInt(i128))) return null;
        const signed: i128 = @intCast(value);
        return if (self.negative) -signed else signed;
    }
};

/// Syrup value types following OCapN spec (Jan 2026)
/// Reference: https://github.com/ocapn/ocapn/blob/main/draft-specifications/Model.md
pub const Value = union(enum) {
    // === Atoms ===
    /// Undefined: represents absence of value (Guile: *unspecified*, JS: undefined)
    undefined: void,
    /// Null: distinct from undefined for JSON compatibility
    null: void,
    /// Boolean: t or f
    bool: bool,
    /// Integer: <len>+ or <len>- for positive/negative (arbitrary precision)
    integer: i64,
    /// Arbitrary precision integer (for values outside i64 range)
    bigint: BigInt,
    /// IEEE 754 single-precision float: F<4 bytes big-endian>
    float32: f32,
    /// IEEE 754 double-precision float: D<8 bytes big-endian>
    float: f64,
    /// Byte string: <len>:<bytes>
    bytes: []const u8,
    /// UTF-8 string: <len>"<bytes>
    string: []const u8,
    /// Symbol: <len>'<bytes>
    symbol: []const u8,

    // === Containers ===
    /// List: [<values>]
    list: []const Value,
    /// Struct (Dictionary): {<key><value>...} (keys in canonical order)
    dictionary: []const DictEntry,
    /// Set: #<values>$ (values in canonical order)
    set: []const Value,
    /// Record: <<label><fields>...>
    record: Record,
    /// Tagged: <desc:tag label value> - pair of tag string and value
    tagged: Tagged,

    // === Special Types ===
    /// Error: for error propagation across CapTP boundaries
    @"error": Error,

    pub const DictEntry = struct {
        key: Value,
        value: Value,
    };

    pub const Record = struct {
        label: *const Value,
        fields: []const Value,
    };

    /// Tagged value per OCapN Model spec - pair of tag (string) and value
pub const Tagged = struct {
    tag: []const u8,
    payload: *const Value,
};

    /// Error type for CapTP error propagation
    /// Mirrors desc:error: <desc:error message identifier data>
pub const Error = struct {
    message: []const u8,
    identifier: []const u8,
    data: *const Value,
};

    // ========================================================================
    // CONSTRUCTORS - Fluent builder methods
    // ========================================================================

    pub fn fromString(s: []const u8) Value {
        return .{ .string = s };
    }

    pub fn fromSymbol(s: []const u8) Value {
        return .{ .symbol = s };
    }

    pub fn fromInteger(i: i64) Value {
        return .{ .integer = i };
    }

    pub fn fromBool(b: bool) Value {
        return .{ .bool = b };
    }

    /// Encodes a balanced ternary trit (-1, 0, 1) as a symbol
    pub fn fromTrit(val: i8) Value {
        return switch (val) {
            -1 => fromSymbol("-"),
            0 => fromSymbol("0"),
            1 => fromSymbol("+"),
            else => fromSymbol("unknown"),
        };
    }

    pub fn fromBytes(b: []const u8) Value {
        return .{ .bytes = b };
    }

    pub fn fromFloat(f: f64) Value {
        return .{ .float = f };
    }

    pub fn fromFloat32(f: f32) Value {
        return .{ .float32 = f };
    }

    pub fn fromBigint(magnitude: []const u8, negative: bool) Value {
        return .{ .bigint = .{ .magnitude = magnitude, .negative = negative } };
    }

    pub fn fromList(items: []const Value) Value {
        return .{ .list = items };
    }

    pub fn fromDictionary(entries: []const DictEntry) Value {
        return .{ .dictionary = entries };
    }

    pub fn fromSet(items: []const Value) Value {
        return .{ .set = items };
    }

    pub fn fromRecord(label: *const Value, fields: []const Value) Value {
        return .{ .record = .{ .label = label, .fields = fields } };
    }

    pub fn fromTagged(tag: []const u8, payload: *const Value) Value {
        return .{ .tagged = .{ .tag = tag, .payload = payload } };
    }

    pub fn fromError(message: []const u8, identifier: []const u8, data: *const Value) Value {
        return .{ .@"error" = .{ .message = message, .identifier = identifier, .data = data } };
    }

    pub fn fromUndefined() Value {
        return .{ .undefined = {} };
    }

    pub fn fromNull() Value {
        return .{ .null = {} };
    }

    // ========================================================================
    // COMPARISON - Based on canonical wire format (essential for OCapN)
    // ========================================================================

    /// Compare two Values for ordering (based on wire representation)
    pub fn compare(self: Value, other: Value) Order {
        const self_type = typeOrder(self);
        const other_type = typeOrder(other);

        if (self_type != other_type) {
            return std.math.order(self_type, other_type);
        }

        if (isRecordLike(self) and isRecordLike(other)) {
            return compareRecordLike(self, other);
        }

        // Same type - compare values
        // For strings/symbols/bytes: compare by wire format (length then content)
        return switch (self) {
            .undefined, .null => {
                // These types are singleton-like in record-like context, 
                // but handled here if they appear directly
                // undefined < null
                if (self == .undefined and other == .null) return .lt;
                if (self == .null and other == .undefined) return .gt;
                return .eq;
            },
            .bool => |a| {
                const b = other.bool;
                if (a == b) return .eq;
                return if (!a and b) .lt else .gt; // false < true
            },
            .integer => |a| std.math.order(a, other.integer),
            .bigint => |a| a.compare(other.bigint),
            .float32 => |a| std.math.order(a, other.float32),
            .float => |a| std.math.order(a, other.float),
            .bytes => |a| compareLengthPrefixed(a, other.bytes),
            .string => |a| compareLengthPrefixed(a, other.string),
            .symbol => |a| compareLengthPrefixed(a, other.symbol),
            .list => |a| compareSequences(a, other.list),
            .set => |a| compareSequences(a, other.set),
            .dictionary => |a| compareDictionaries(a, other.dictionary),
            .record => |a| {
                const b = other.record;
                const label_cmp = a.label.compare(b.label.*);
                if (label_cmp != .eq) return label_cmp;
                return compareSequences(a.fields, b.fields);
            },
            .tagged, .@"error" => {
                // Should be handled by isRecordLike check above, but as a fallback:
                return compareRecordLike(self, other);
            },
        };
    }

    /// Compare length-prefixed values (bytes/string/symbol) by wire format
    /// Wire format: <len><marker><content>, so we compare the stringified length first
    fn compareLengthPrefixed(a: []const u8, b: []const u8) Order {
        // We must compare the serialized length strings (e.g. "9" vs "10")
        // "9" > "10" lexicographically, so len=9 > len=10 in wire format.
        
        var a_buf: [32]u8 = undefined;
        var b_buf: [32]u8 = undefined;
        const a_str = std.fmt.bufPrint(&a_buf, "{}", .{a.len}) catch unreachable;
        const b_str = std.fmt.bufPrint(&b_buf, "{}", .{b.len}) catch unreachable;
        
        const len_cmp = std.mem.order(u8, a_str, b_str);
        if (len_cmp != .eq) return len_cmp;
        
        // Same length string implies same length value. Compare content.
        return std.mem.order(u8, a, b);
    }

    fn compareSequences(a: []const Value, b: []const Value) Order {
        const min_len = @min(a.len, b.len);
        for (a[0..min_len], b[0..min_len]) |av, bv| {
            const cmp = av.compare(bv);
            if (cmp != .eq) return cmp;
        }
        return std.math.order(a.len, b.len);
    }

    fn compareDictionaries(a: []const DictEntry, b: []const DictEntry) Order {
        const min_len = @min(a.len, b.len);
        for (a[0..min_len], b[0..min_len]) |ae, be| {
            const key_cmp = ae.key.compare(be.key);
            if (key_cmp != .eq) return key_cmp;
            const val_cmp = ae.value.compare(be.value);
            if (val_cmp != .eq) return val_cmp;
        }
        return std.math.order(a.len, b.len);
    }

    fn isRecordLike(v: Value) bool {
        return switch (v) {
            .record, .tagged, .@"error", .undefined, .null => true,
            else => false,
        };
    }

    fn recordLikeLabel(v: Value) Value {
        return switch (v) {
            .record => |r| r.label.*,
            .tagged => Value{ .symbol = "desc:tag" },
            .@"error" => Value{ .symbol = "desc:error" },
            .undefined => Value{ .symbol = "undefined" },
            .null => Value{ .symbol = "null" },
            else => Value{ .symbol = "unknown" }, // Fallback instead of panic
        };
    }

    fn recordLikeFieldCount(v: Value) usize {
        return switch (v) {
            .record => |r| r.fields.len,
            .tagged => 2,
            .@"error" => 3,
            .undefined, .null => 0,
            else => 0, // Fallback
        };
    }

    fn recordLikeField(v: Value, index: usize) Value {
        return switch (v) {
            .record => |r| r.fields[index],
            .tagged => |t| switch (index) {
                0 => Value{ .string = t.tag },
                1 => t.payload.*,
                else => Value{ .undefined = {} }, // Out of bounds
            },
            .@"error" => |e| switch (index) {
                0 => Value{ .string = e.message },
                1 => Value{ .bytes = e.identifier },
                2 => e.data.*,
                else => Value{ .undefined = {} }, // Out of bounds
            },
            .undefined, .null => Value{ .undefined = {} },
            else => Value{ .undefined = {} }, // Fallback
        };
    }

    fn compareRecordLike(a: Value, b: Value) Order {
        const label_cmp = recordLikeLabel(a).compare(recordLikeLabel(b));
        if (label_cmp != .eq) return label_cmp;

        const a_len = recordLikeFieldCount(a);
        const b_len = recordLikeFieldCount(b);
        const min_len = @min(a_len, b_len);
        var i: usize = 0;
        while (i < min_len) : (i += 1) {
            const cmp = recordLikeField(a, i).compare(recordLikeField(b, i));
            if (cmp != .eq) return cmp;
        }
        return std.math.order(a_len, b_len);
    }

    /// Type ordering for canonical comparison
    fn typeOrder(v: Value) u8 {
        return switch (v) {
            .bool => 0,
            .integer, .bigint => 1,
            .float32 => 2,
            .float => 3,
            .bytes => 4,
            .string => 5,
            .symbol => 6,
            .list => 7,
            .dictionary => 8,
            .set => 9,
            .record, .tagged, .@"error", .undefined, .null => 10,
        };
    }

    /// Equality based on wire representation
    pub fn eql(self: Value, other: Value) bool {
        return self.compare(other) == .eq;
    }

    /// Hash based on wire representation (for use in hash maps)
    pub fn hash(self: Value) u64 {
        var hasher = std.hash.Wyhash.init(0);
        self.hashWith(&hasher);
        return hasher.final();
    }

    fn hashWith(self: Value, hasher: anytype) void {
        hasher.update(&[_]u8{typeOrder(self)});
        switch (self) {
            .bool => |b| hasher.update(&[_]u8{if (b) 1 else 0}),
            .integer => |i| {
                const int_bytes: [8]u8 = @bitCast(i);
                hasher.update(&int_bytes);
            },
            .bigint => |b| {
                hasher.update(&[_]u8{if (b.negative) 1 else 0});
                hasher.update(b.magnitude);
            },
            .float32 => |f| {
                const f32_bytes: [4]u8 = @bitCast(f);
                hasher.update(&f32_bytes);
            },
            .float => |f| {
                const f64_bytes: [8]u8 = @bitCast(f);
                hasher.update(&f64_bytes);
            },
            .bytes, .string, .symbol => |s| hasher.update(s),
            .list, .set => |items| {
                for (items) |item| item.hashWith(hasher);
            },
            .dictionary => |entries| {
                for (entries) |entry| {
                    entry.key.hashWith(hasher);
                    entry.value.hashWith(hasher);
                }
            },
            .record, .tagged, .@"error", .undefined, .null => {
                recordLikeLabel(self).hashWith(hasher);
                const len = recordLikeFieldCount(self);
                var i: usize = 0;
                while (i < len) : (i += 1) {
                    recordLikeField(self, i).hashWith(hasher);
                }
            },
        }
    }

    // ========================================================================
    // ENCODING
    // ========================================================================

    /// Encode value to writer (no allocation needed)
    pub fn encode(self: Value, writer: anytype) !void {
        switch (self) {
            .undefined => {
                try writer.writeByte('<');
                try Value.fromSymbol("undefined").encode(writer);
                try writer.writeByte('>');
            },
            .null => {
                try writer.writeByte('<');
                try Value.fromSymbol("null").encode(writer);
                try writer.writeByte('>');
            },
            .bool => |b| try writer.writeByte(if (b) 't' else 'f'),
            .integer => |i| try encodeInteger(i, writer),
            .bigint => |b| {
                if (b.magnitude.len <= 16) {
                    var value: u128 = 0;
                    for (b.magnitude) |byte| {
                        value = (value << 8) | byte;
                    }
                    try std.fmt.format(writer, "{d}{c}", .{ value, if (b.negative) @as(u8, '-') else @as(u8, '+') });
                } else {
                    try writer.writeByte('B');
                    try std.fmt.format(writer, "{d}:", .{b.magnitude.len + 1});
                    try writer.writeByte(if (b.negative) '-' else '+');
                    try writer.writeAll(b.magnitude);
                }
            },
            .float32 => |f| {
                try writer.writeByte('F');
                var buf: [4]u8 = undefined;
                std.mem.writeInt(u32, &buf, @bitCast(f), .big);
                try writer.writeAll(&buf);
            },
            .float => |f| {
                try writer.writeByte('D');
                var buf: [8]u8 = undefined;
                std.mem.writeInt(u64, &buf, @bitCast(f), .big);
                try writer.writeAll(&buf);
            },
            .bytes => |b| try writeLengthPrefixed(writer, b, ':'),
            .string => |s| try writeLengthPrefixed(writer, s, '"'),
            .symbol => |s| try writeLengthPrefixed(writer, s, '\''),
            .list => |items| {
                try writer.writeByte('[');
                for (items) |item| try item.encode(writer);
                try writer.writeByte(']');
            },
            .dictionary => |entries| {
                try writer.writeByte('{');
                for (entries) |e| {
                    try e.key.encode(writer);
                    try e.value.encode(writer);
                }
                try writer.writeByte('}');
            },
            .set => |items| {
                try writer.writeByte('#');
                for (items) |item| try item.encode(writer);
                try writer.writeByte('$');
            },
            .record => |r| {
                try writer.writeByte('<');
                try r.label.encode(writer);
                for (r.fields) |f| try f.encode(writer);
                try writer.writeByte('>');
            },
            .tagged => |t| {
                try writer.writeByte('<');
                try Value.fromSymbol("desc:tag").encode(writer);
                try Value.fromString(t.tag).encode(writer);
                try t.payload.*.encode(writer);
                try writer.writeByte('>');
            },
            .@"error" => |e| {
                try writer.writeByte('<');
                try Value.fromSymbol("desc:error").encode(writer);
                try Value.fromString(e.message).encode(writer);
                try Value.fromBytes(e.identifier).encode(writer);
                try e.data.*.encode(writer);
                try writer.writeByte('>');
            },
        }
    }

    /// Encode to a fixed buffer, returns slice of encoded bytes
    pub fn encodeBuf(self: Value, buf: []u8) ![]u8 {
        var stream = std.io.fixedBufferStream(buf);
        try self.encode(stream.writer());
        return buf[0..stream.pos];
    }

    /// Encode to a fixed buffer, returning the number of bytes written.
    /// Avoids the slice return when callers only need the length.
    pub fn encodeLen(self: Value, buf: []u8) !usize {
        var fbs = std.io.fixedBufferStream(buf);
        try self.encode(fbs.writer());
        return fbs.pos;
    }

    /// Encode to allocated buffer
    pub fn encodeAlloc(self: Value, allocator: Allocator) ![]u8 {
        const ByteList = std.array_list.AlignedManaged(u8, null);
        var list_buf = ByteList.init(allocator);
        errdefer list_buf.deinit();
        try self.encode(list_buf.writer());
        return list_buf.toOwnedSlice();
    }

    /// Get encoded size without actually encoding (for pre-allocation)
    pub fn encodedSize(self: Value) usize {
        return switch (self) {
            .undefined => 2 + Value.fromSymbol("undefined").encodedSize(),
            .null => 2 + Value.fromSymbol("null").encodedSize(),
            .bool => 1,
            .integer => |i| integerEncodedSize(i),
            .bigint => |b| bigintEncodedSize(b),
            .float32 => 5,
            .float => 9,
            .bytes => |s| lengthPrefixSize(s.len) + 1 + s.len,
            .string => |s| lengthPrefixSize(s.len) + 1 + s.len,
            .symbol => |s| lengthPrefixSize(s.len) + 1 + s.len,
            .list => |items| blk: {
                var size: usize = 2; // [ ]
                for (items) |item| size += item.encodedSize();
                break :blk size;
            },
            .dictionary => |entries| blk: {
                var size: usize = 2; // { }
                for (entries) |e| size += e.key.encodedSize() + e.value.encodedSize();
                break :blk size;
            },
            .set => |items| blk: {
                var size: usize = 2; // # $
                for (items) |item| size += item.encodedSize();
                break :blk size;
            },
            .record => |r| blk: {
                var size: usize = 2 + r.label.encodedSize(); // < >
                for (r.fields) |field| size += field.encodedSize();
                break :blk size;
            },
            .tagged => |t| blk: {
                var size: usize = 2;
                size += Value.fromSymbol("desc:tag").encodedSize();
                size += Value.fromString(t.tag).encodedSize();
                size += t.payload.*.encodedSize();
                break :blk size;
            },
            .@"error" => |e| blk: {
                var size: usize = 2;
                size += Value.fromSymbol("desc:error").encodedSize();
                size += Value.fromString(e.message).encodedSize();
                size += Value.fromBytes(e.identifier).encodedSize();
                size += e.data.*.encodedSize();
                break :blk size;
            },
        };
    }

    fn integerEncodedSize(i: i64) usize {
        const abs: u64 = if (i >= 0) @intCast(i) else @intCast(-i);
        return digitCount(abs) + 1; // digits + sign
    }

    fn bigintEncodedSize(b: BigInt) usize {
        if (b.magnitude.len <= 16) {
            var value: u128 = 0;
            for (b.magnitude) |byte| {
                value = (value << 8) | byte;
            }
            return digitCount(value) + 1;
        }
        return 1 + lengthPrefixSize(b.magnitude.len + 1) + 1 + b.magnitude.len;
    }

    fn lengthPrefixSize(len: usize) usize {
        return digitCount(@as(u64, len));
    }

    fn digitCount(n: anytype) usize {
        if (n == 0) return 1;
        var count: usize = 0;
        var v = n;
        while (v > 0) : (v /= 10) count += 1;
        return count;
    }
};

fn encodeInteger(value: i64, writer: anytype) !void {
    const abs: u64 = if (value >= 0) @intCast(value) else @intCast(-value);
    const sign: u8 = if (value >= 0) '+' else '-';
    try std.fmt.format(writer, "{d}{c}", .{ abs, sign });
}

fn writeLengthPrefixed(writer: anytype, data: []const u8, marker: u8) !void {
    try std.fmt.format(writer, "{d}{c}", .{ data.len, marker });
    try writer.writeAll(data);
}

// ============================================================================
// BUILDER API - Ergonomic value construction
// ============================================================================

/// Value constructors - idiomatic Zig uses short, clear names
pub const string = Value.fromString;
pub const symbol = Value.fromSymbol;
pub const integer = Value.fromInteger;
pub const boolean = Value.fromBool;
pub const bytes = Value.fromBytes;
pub const float = Value.fromFloat;
pub const float32 = Value.fromFloat32;
pub const bigint = Value.fromBigint;
pub const list = Value.fromList;
pub const dictionary = Value.fromDictionary;
pub const set = Value.fromSet;
pub const record = Value.fromRecord;
pub const tagged = Value.fromTagged;
pub const err = Value.fromError;
pub const undef = Value.fromUndefined;
pub const nullv = Value.fromNull;

/// Create a positive bigint from u128
pub fn bigintFromU128(allocator: Allocator, value: u128) !Value {
    if (value == 0) return integer(0);
    var v = value;
    var byte_count: usize = 0;
    while (v != 0) : (v >>= 8) byte_count += 1;

    const magnitude = try allocator.alloc(u8, byte_count);
    v = value;
    var i: usize = byte_count;
    while (i > 0) {
        i -= 1;
        magnitude[i] = @truncate(v);
        v >>= 8;
    }
    return .{ .bigint = .{ .magnitude = magnitude, .negative = false } };
}

// ============================================================================
// CANONICAL CONSTRUCTORS - Auto-sort for canonical encoding
// ============================================================================

/// Comparator for canonical Value ordering (for std.mem.sort)
pub fn valueLessThan(_: void, a: Value, b: Value) bool {
    return a.compare(b) == .lt;
}

/// Comparator for canonical DictEntry ordering (by key)
pub fn dictEntryLessThan(_: void, a: Value.DictEntry, b: Value.DictEntry) bool {
    return a.key.compare(b.key) == .lt;
}

/// Create a canonically sorted dictionary (allocates)
pub fn dictionaryCanonical(allocator: Allocator, entries: []const Value.DictEntry) !Value {
    if (entries.len == 0) return .{ .dictionary = &[_]Value.DictEntry{} };
    const sorted = try allocator.alloc(Value.DictEntry, entries.len);
    @memcpy(sorted, entries);
    if (sorted.len <= 8) {
        // Insertion sort for small dicts — lower overhead than pdqsort
        for (1..sorted.len) |i| {
            const key = sorted[i];
            var j: usize = i;
            while (j > 0 and sorted[j - 1].key.compare(key.key) == .gt) {
                sorted[j] = sorted[j - 1];
                j -= 1;
            }
            sorted[j] = key;
        }
    } else {
        std.mem.sort(Value.DictEntry, sorted, {}, dictEntryLessThan);
    }
    return .{ .dictionary = sorted };
}

/// Create a canonically sorted set (allocates)
pub fn setCanonical(allocator: Allocator, items: []const Value) !Value {
    if (items.len == 0) return .{ .set = &[_]Value{} };
    const sorted = try allocator.alloc(Value, items.len);
    @memcpy(sorted, items);
    if (sorted.len <= 8) {
        // Insertion sort for small sets — lower overhead than pdqsort
        for (1..sorted.len) |i| {
            const key = sorted[i];
            var j: usize = i;
            while (j > 0 and sorted[j - 1].compare(key) == .gt) {
                sorted[j] = sorted[j - 1];
                j -= 1;
            }
            sorted[j] = key;
        }
    } else {
        std.mem.sort(Value, sorted, {}, valueLessThan);
    }
    return .{ .set = sorted };
}

// ============================================================================
// CID (Content Identifier) Computation
// ============================================================================

/// Compute SHA-256 CID of encoded value
pub fn computeCid(value: Value, out: *[32]u8) !void {
    var buf: [4096]u8 = undefined;
    const encoded = try value.encodeBuf(&buf);
    std.crypto.hash.sha2.Sha256.hash(encoded, out, .{});
}

/// Compute SHA-256 CID using a caller-provided encode buffer
/// Avoids the fixed 4096-byte stack allocation when the caller already has a buffer
pub fn computeCidWithBuf(value: Value, out: *[32]u8, encode_buf: []u8) !void {
    const encoded = try value.encodeBuf(encode_buf);
    std.crypto.hash.sha2.Sha256.hash(encoded, out, .{});
}

/// Compute SHA-256 CID and return as hex string
pub fn computeCidHex(value: Value, allocator: Allocator) ![]u8 {
    var hash: [32]u8 = undefined;
    try computeCid(value, &hash);
    const hex = try allocator.alloc(u8, 64);
    _ = std.fmt.bufPrint(hex, "{s}", .{std.fmt.fmtSliceHexLower(&hash)}) catch return error.FormattingError;
    return hex;
}

/// Comptime CID computation for static values
pub fn comptimeCid(comptime value: Value) [64]u8 {
    comptime {
        var buf: [4096]u8 = undefined;
        var stream = std.io.fixedBufferStream(&buf);
        value.encode(stream.writer()) catch @compileError("Encoding failed");
        const encoded = buf[0..stream.pos];

        var hash: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(encoded, &hash, .{});

        var hex: [64]u8 = undefined;
        _ = std.fmt.bufPrint(&hex, "{s}", .{std.fmt.fmtSliceHexLower(&hash)}) catch @compileError("Formatting failed");
        return hex;
    }
}

// ============================================================================
// ERRORS
// ============================================================================

/// Errors that can occur during parsing
pub const ParseError = error{
    UnexpectedEOF,
    InvalidFormat,
    NotCanonicalOrder,
    ListTooLarge,
    DictionaryTooLarge,
    SetTooLarge,
    RecordTooLarge,
    OutOfMemory,
    Overflow,
};

// ============================================================================
// PARSER / DECODER
// ============================================================================

/// Parser state for streaming Syrup deserialization
pub const Parser = struct {
    input: []const u8,
    pos: usize = 0,
    allocator: Allocator,

    /// Create a new parser
    pub fn init(input: []const u8, allocator: Allocator) Parser {
        return .{
            .input = input,
            .pos = 0,
            .allocator = allocator,
        };
    }

    /// Parse the next value from input
    pub fn parse(self: *Parser) ParseError!Value {
        if (self.pos >= self.input.len) {
            return error.UnexpectedEOF;
        }

        const ch = self.input[self.pos];
        return switch (ch) {
            't' => {
                self.pos += 1;
                return Value{ .bool = true };
            },
            'f' => {
                self.pos += 1;
                return Value{ .bool = false };
            },
            'F' => try self.parseFloat32(),
            'D' => try self.parseFloat64(),
            'B' => try self.parseBigIntExtended(),
            '[' => try self.parseList(),
            '{' => try self.parseDictionary(),
            '#' => try self.parseSet(),
            '<' => try self.parseRecord(),
            else => try self.parseNumberOrString(),
        };
    }

    /// Check if more input is available
    pub fn hasMore(self: *Parser) bool {
        return self.pos < self.input.len;
    }

    /// Get remaining unparsed input
    pub fn remaining(self: *Parser) []const u8 {
        return self.input[self.pos..];
    }

    /// Parse integer, bytes, string, or symbol
    fn parseNumberOrString(self: *Parser) ParseError!Value {
        var num: u64 = 0;
        var digit_count: usize = 0;
        while (self.pos < self.input.len and std.ascii.isDigit(self.input[self.pos])) {
            const digit: u64 = self.input[self.pos] - '0';
            // Check for overflow
            if (num > (std.math.maxInt(u64) - digit) / 10) {
                return error.Overflow;
            }
            num = num * 10 + digit;
            self.pos += 1;
            digit_count += 1;
        }

        if (self.pos >= self.input.len) {
            return error.UnexpectedEOF;
        }

        const marker = self.input[self.pos];
        self.pos += 1;

        switch (marker) {
            '+' => {
                if (num > @as(u64, @intCast(std.math.maxInt(i64)))) {
                    // Convert to bigint
                    const mag = try self.allocator.alloc(u8, 8);
                    var v = num;
                    var i: usize = 8;
                    while (i > 0) {
                        i -= 1;
                        mag[i] = @truncate(v);
                        v >>= 8;
                    }
                    // Strip leading zeros
                    var start: usize = 0;
                    while (start < mag.len - 1 and mag[start] == 0) start += 1;
                    return Value{ .bigint = .{ .magnitude = mag[start..], .negative = false } };
                }
                return Value{ .integer = @intCast(num) };
            },
            '-' => {
                if (num > @as(u64, @intCast(std.math.maxInt(i64))) + 1) {
                    const mag = try self.allocator.alloc(u8, 8);
                    var v = num;
                    var i: usize = 8;
                    while (i > 0) {
                        i -= 1;
                        mag[i] = @truncate(v);
                        v >>= 8;
                    }
                    var start: usize = 0;
                    while (start < mag.len - 1 and mag[start] == 0) start += 1;
                    return Value{ .bigint = .{ .magnitude = mag[start..], .negative = true } };
                }
                return Value{ .integer = -@as(i64, @intCast(num)) };
            },
            ':' => {
                const len = num;
                if (self.pos + len > self.input.len) {
                    return error.UnexpectedEOF;
                }
                const data = self.input[self.pos .. self.pos + len];
                self.pos += len;
                return Value{ .bytes = data };
            },
            '"' => {
                const len = num;
                if (self.pos + len > self.input.len) {
                    return error.UnexpectedEOF;
                }
                const data = self.input[self.pos .. self.pos + len];
                self.pos += len;
                return Value{ .string = data };
            },
            '\'' => {
                const len = num;
                if (self.pos + len > self.input.len) {
                    return error.UnexpectedEOF;
                }
                const data = self.input[self.pos .. self.pos + len];
                self.pos += len;
                return Value{ .symbol = data };
            },
            else => {
                return error.InvalidFormat;
            },
        }
    }

    /// Parse extended bigint: B<len>:<sign><magnitude>
    fn parseBigIntExtended(self: *Parser) ParseError!Value {
        self.pos += 1; // Skip 'B'

        // Parse length
        var len: u64 = 0;
        while (self.pos < self.input.len and std.ascii.isDigit(self.input[self.pos])) {
            len = len * 10 + (self.input[self.pos] - '0');
            self.pos += 1;
        }

        if (self.pos >= self.input.len or self.input[self.pos] != ':') {
            return error.InvalidFormat;
        }
        self.pos += 1; // Skip ':'

        if (len < 1 or self.pos + len > self.input.len) {
            return error.UnexpectedEOF;
        }

        const sign_byte = self.input[self.pos];
        self.pos += 1;
        const negative = sign_byte == '-';

        const magnitude = self.input[self.pos .. self.pos + len - 1];
        self.pos += len - 1;

        // Copy magnitude to owned memory
        const mag_copy = try self.allocator.alloc(u8, magnitude.len);
        @memcpy(mag_copy, magnitude);

        return Value{ .bigint = .{ .magnitude = mag_copy, .negative = negative } };
    }

    /// Parse float32: F<4 big-endian bytes>
    fn parseFloat32(self: *Parser) ParseError!Value {
        self.pos += 1;
        if (self.pos + 4 > self.input.len) return error.UnexpectedEOF;
        const bits = std.mem.readInt(u32, self.input[self.pos..][0..4], .big);
        self.pos += 4;
        return .{ .float32 = @bitCast(bits) };
    }

    /// Parse float64: D<8 big-endian bytes>
    fn parseFloat64(self: *Parser) ParseError!Value {
        self.pos += 1;
        if (self.pos + 8 > self.input.len) return error.UnexpectedEOF;
        const bits = std.mem.readInt(u64, self.input[self.pos..][0..8], .big);
        self.pos += 8;
        return .{ .float = @bitCast(bits) };
    }

    /// Collect values until terminator, checking canonical order if requested
    fn collectUntil(
        self: *Parser,
        terminator: u8,
        comptime check_order: bool,
    ) ParseError![]Value {
        var items = std.ArrayListUnmanaged(Value){};
        errdefer items.deinit(self.allocator);
        
        var last_start: usize = 0;
        var last_end: usize = 0;

        while (self.pos < self.input.len and self.input[self.pos] != terminator) {
            const item_start = self.pos;
            const item = try self.parse();
            const item_end = self.pos;

            if (check_order and items.items.len > 0) {
                // Compare using original input bytes - O(1) lookup, O(min(m,n)) compare
                const prev_bytes = self.input[last_start..last_end];
                const curr_bytes = self.input[item_start..item_end];
                if (std.mem.order(u8, curr_bytes, prev_bytes) == .lt) {
                    return error.NotCanonicalOrder;
                }
            }
            last_start = item_start;
            last_end = item_end;

            try items.append(self.allocator, item);
        }

        if (self.pos >= self.input.len) return error.UnexpectedEOF;
        self.pos += 1;

        return items.toOwnedSlice(self.allocator);
    }

    /// Parse list: [<values>]
    fn parseList(self: *Parser) ParseError!Value {
        self.pos += 1;
        return .{ .list = try self.collectUntil(']', false) };
    }

    /// Parse dictionary: {<key><value>...}
    fn parseDictionary(self: *Parser) ParseError!Value {
        self.pos += 1;
        var entries = std.ArrayListUnmanaged(Value.DictEntry){};
        errdefer entries.deinit(self.allocator);
        
        var last_key_start: usize = 0;
        var last_key_end: usize = 0;

        while (self.pos < self.input.len and self.input[self.pos] != '}') {
            const key_start = self.pos;
            const key = try self.parse();
            const key_end = self.pos;
            const val = try self.parse();

            // Verify canonical ordering using original input bytes
            if (entries.items.len > 0) {
                const prev_bytes = self.input[last_key_start..last_key_end];
                const curr_bytes = self.input[key_start..key_end];
                if (std.mem.order(u8, curr_bytes, prev_bytes) == .lt) {
                    return error.NotCanonicalOrder;
                }
            }
            last_key_start = key_start;
            last_key_end = key_end;

            try entries.append(self.allocator, .{ .key = key, .value = val });
        }

        if (self.pos >= self.input.len) return error.UnexpectedEOF;
        self.pos += 1;

        return .{ .dictionary = try entries.toOwnedSlice(self.allocator) };
    }

    /// Parse set: #<values>$
    fn parseSet(self: *Parser) ParseError!Value {
        self.pos += 1;
        return .{ .set = try self.collectUntil('$', true) };
    }

    /// Parse record: <<label><fields>...>
    fn parseRecord(self: *Parser) ParseError!Value {
        self.pos += 1;
        const label = try self.parse();

        if (labelName(label)) |name| {
            if (std.mem.eql(u8, name, "desc:tag")) {
                const tag_val = try self.parse();
                if (tag_val != .string) return error.InvalidFormat;
                const payload_val = try self.parse();
                if (self.pos >= self.input.len or self.input[self.pos] != '>') return error.InvalidFormat;
                self.pos += 1;

                const payload_alloc = try self.allocator.alloc(Value, 1);
                payload_alloc[0] = payload_val;
                return Value.fromTagged(tag_val.string, &payload_alloc[0]);
            }

            if (std.mem.eql(u8, name, "desc:error")) {
                const message_val = try self.parse();
                if (message_val != .string) return error.InvalidFormat;
                const identifier_val = try self.parse();
                if (identifier_val != .bytes) return error.InvalidFormat;
                const data_val = try self.parse();
                if (data_val != .dictionary) return error.InvalidFormat;
                if (self.pos >= self.input.len or self.input[self.pos] != '>') return error.InvalidFormat;
                self.pos += 1;

                const data_alloc = try self.allocator.alloc(Value, 1);
                data_alloc[0] = data_val;
                return Value.fromError(message_val.string, identifier_val.bytes, &data_alloc[0]);
            }

            if (std.mem.eql(u8, name, "undefined")) {
                if (self.pos >= self.input.len or self.input[self.pos] != '>') return error.InvalidFormat;
                self.pos += 1;
                return .{ .undefined = {} };
            }

            if (std.mem.eql(u8, name, "null")) {
                if (self.pos >= self.input.len or self.input[self.pos] != '>') return error.InvalidFormat;
                self.pos += 1;
                return .{ .null = {} };
            }
        }

        const label_alloc = try self.allocator.alloc(Value, 1);
        label_alloc[0] = label;
        const fields = try self.collectUntil('>', false);
        return .{ .record = .{ .label = &label_alloc[0], .fields = fields } };
    }

    fn labelName(label: Value) ?[]const u8 {
        return switch (label) {
            .symbol => |s| s,
            .string => |s| s,
            else => null,
        };
    }

    /// Helper: encode a value to bytes for canonical ordering comparison
    fn valueToBytes(self: *Parser, value: *const Value) ParseError![]const u8 {
        // Stack buffer for encoding - most keys are small
        var stack_buf: [256]u8 = undefined;
        var stream = std.io.fixedBufferStream(&stack_buf);
        value.encode(stream.writer()) catch {
            // Fall back to allocating for large values
            var list_buf = std.ArrayListUnmanaged(u8){};
            value.encode(list_buf.writer(self.allocator)) catch return error.OutOfMemory;
            return list_buf.toOwnedSlice(self.allocator) catch return error.OutOfMemory;
        };
        // Copy to allocated memory since stack buffer won't live
        const result = self.allocator.alloc(u8, stream.pos) catch return error.OutOfMemory;
        @memcpy(result, stack_buf[0..stream.pos]);
        return result;
    }
};

/// Decode Syrup bytes into a Value
pub fn decode(input: []const u8, allocator: Allocator) !Value {
    var parser = Parser.init(input, allocator);
    return parser.parse();
}

/// Decode with zero-copy string views (strings reference input buffer)
pub fn decodeZeroCopy(input: []const u8, allocator: Allocator) !Value {
    return decode(input, allocator);
}

/// Decode multiple values from a stream
pub fn decodeStream(input: []const u8, allocator: Allocator) ![]Value {
    var parser = Parser.init(input, allocator);
    var values = std.ArrayListUnmanaged(Value){};
    errdefer values.deinit(allocator);

    while (parser.hasMore()) {
        const value = try parser.parse();
        try values.append(allocator, value);
    }

    return try values.toOwnedSlice(allocator);
}

// ============================================================================
// COMPTIME SCHEMA VALIDATION (Phase 3)
// ============================================================================

/// Schema for compile-time type checking
pub const Schema = union(enum) {
    any: void,
    undefined: void,
    null: void,
    boolean: void,
    integer: void,
    float: void,
    string: void,
    symbol: void,
    bytes: void,
    list: *const Schema,
    dictionary: struct { key: *const Schema, value: *const Schema },
    record: struct { label: []const u8, fields: []const Schema },
    tagged: struct { tag: []const u8, payload: *const Schema },
    @"error": void,
    oneOf: []const Schema,
};

/// Validate a value against a schema at runtime
pub fn validateSchema(value: Value, schema: Schema) bool {
    return switch (schema) {
        .any => true,
        .undefined => value == .undefined,
        .null => value == .null,
        .boolean => value == .bool,
        .integer => value == .integer or value == .bigint,
        .float => value == .float or value == .float32,
        .string => value == .string,
        .symbol => value == .symbol,
        .bytes => value == .bytes,
        .list => |item_schema| {
            if (value != .list) return false;
            for (value.list) |item| {
                if (!validateSchema(item, item_schema.*)) return false;
            }
            return true;
        },
        .dictionary => |dict_schema| {
            if (value != .dictionary) return false;
            for (value.dictionary) |entry| {
                if (!validateSchema(entry.key, dict_schema.key.*)) return false;
                if (!validateSchema(entry.value, dict_schema.value.*)) return false;
            }
            return true;
        },
        .record => |rec_schema| {
            if (value != .record) return false;
            const label = value.record.label.*;
            if (label != .string and label != .symbol) return false;
            const label_str = if (label == .string) label.string else label.symbol;
            if (!std.mem.eql(u8, label_str, rec_schema.label)) return false;
            if (value.record.fields.len != rec_schema.fields.len) return false;
            for (value.record.fields, rec_schema.fields) |field, field_schema| {
                if (!validateSchema(field, field_schema)) return false;
            }
            return true;
        },
        .tagged => |tag_schema| {
            if (value != .tagged) return false;
            if (!std.mem.eql(u8, value.tagged.tag, tag_schema.tag)) return false;
            return validateSchema(value.tagged.payload.*, tag_schema.payload.*);
        },
        .@"error" => value == .@"error",
        .oneOf => |schemas| {
            for (schemas) |s| {
                if (validateSchema(value, s)) return true;
            }
            return false;
        },
    };
}

// ============================================================================
// GENERIC SERIALIZATION TRAITS (Serde-like)
// ============================================================================

/// Serialize any Zig type to Syrup Value (requires allocator for containers)
pub fn serialize(comptime T: type, value: T, allocator: Allocator) !Value {
    return serializeImpl(T, value, allocator);
}

/// Deserialize Syrup Value to any Zig type (requires allocator for strings/slices)
pub fn deserialize(comptime T: type, value: Value, allocator: Allocator) !T {
    return deserializeImpl(T, value, allocator);
}

/// Serialize directly to writer (convenience function)
pub fn serializeToWriter(comptime T: type, value: T, allocator: Allocator, writer: anytype) !void {
    const syrup_value = try serialize(T, value, allocator);
    try syrup_value.encode(writer);
}

/// Deserialize directly from bytes
pub fn deserializeFromBytes(comptime T: type, input: []const u8, allocator: Allocator) !T {
    const value = try decode(input, allocator);
    return deserialize(T, value, allocator);
}

fn serializeImpl(comptime T: type, value: T, allocator: Allocator) Allocator.Error!Value {
    const info = @typeInfo(T);

    return switch (info) {
        .bool => boolean(value),

        .int => |int_info| blk: {
            if (int_info.bits <= 64) {
                if (int_info.signedness == .signed) {
                    break :blk integer(@intCast(value));
                } else {
                    if (value <= std.math.maxInt(i64)) {
                        break :blk integer(@intCast(value));
                    }
                    // Large unsigned - encode as positive with magnitude
                    break :blk integer(@intCast(@as(i64, @bitCast(@as(u64, value)))));
                }
            }
            // Larger integers would need bigint support
            return error.IntegerTooLarge;
        },

        .float => |float_info| blk: {
            if (float_info.bits == 32) {
                break :blk float32(value);
            }
            break :blk float(value);
        },

        .pointer => |ptr_info| blk: {
            // []const u8 -> string
            if (ptr_info.size == .slice and ptr_info.child == u8) {
                break :blk string(value);
            }
            // []const T -> list
            if (ptr_info.size == .slice) {
                const items = try allocator.alloc(Value, value.len);
                for (value, 0..) |item, i| {
                    items[i] = try serializeImpl(ptr_info.child, item, allocator);
                }
                break :blk list(items);
            }
            // *const T -> serialize pointee
            if (ptr_info.size == .one) {
                break :blk try serializeImpl(ptr_info.child, value.*, allocator);
            }
            return error.UnsupportedPointerType;
        },

        .array => |arr_info| blk: {
            // [N]u8 -> bytes
            if (arr_info.child == u8) {
                break :blk bytes(&value);
            }
            // [N]T -> list
            const items = try allocator.alloc(Value, arr_info.len);
            for (value, 0..) |item, i| {
                items[i] = try serializeImpl(arr_info.child, item, allocator);
            }
            break :blk list(items);
        },

        .optional => |opt_info| blk: {
            if (value) |v| {
                break :blk try serializeImpl(opt_info.child, v, allocator);
            }
            // None -> false (Syrup convention)
            break :blk boolean(false);
        },

        .@"enum" => blk: {
            // Enum -> symbol
            break :blk symbol(@tagName(value));
        },

        .@"struct" => |struct_info| blk: {
            // Check for syrup_label declaration (serialize as record)
            if (@hasDecl(T, "syrup_label")) {
                const label_str = T.syrup_label;
                const label_alloc = try allocator.alloc(Value, 1);
                label_alloc[0] = string(label_str);

                const fields_list = try allocator.alloc(Value, struct_info.fields.len);
                inline for (struct_info.fields, 0..) |field, i| {
                    fields_list[i] = try serializeImpl(field.type, @field(value, field.name), allocator);
                }

                break :blk Value{ .record = .{
                    .label = &label_alloc[0],
                    .fields = fields_list,
                } };
            }

            // Default: struct -> dictionary
            const entries = try allocator.alloc(Value.DictEntry, struct_info.fields.len);
            inline for (struct_info.fields, 0..) |field, i| {
                entries[i] = .{
                    .key = string(field.name),
                    .value = try serializeImpl(field.type, @field(value, field.name), allocator),
                };
            }
            // Sort for canonical ordering (by wire format bytes)
            std.mem.sort(Value.DictEntry, entries, {}, dictEntryLessThan);
            break :blk dictionary(entries);
        },

        .@"union" => |union_info| blk: {
            // Tagged union -> record with tag as label
            if (union_info.tag_type) |_| {
                const tag_name = @tagName(value);
                const label_alloc = try allocator.alloc(Value, 1);
                label_alloc[0] = symbol(tag_name);

                // Get the active field value
                inline for (union_info.fields) |field| {
                    if (std.mem.eql(u8, field.name, tag_name)) {
                        const field_val = @field(value, field.name);
                        const fields_list = try allocator.alloc(Value, 1);
                        fields_list[0] = try serializeImpl(field.type, field_val, allocator);

                        break :blk Value{ .record = .{
                            .label = &label_alloc[0],
                            .fields = fields_list,
                        } };
                    }
                }
            }
            return error.UnionTagNotFound;
        },

        else => return error.UnsupportedType,
    };
}

fn deserializeImpl(comptime T: type, value: Value, allocator: Allocator) !T {
    const info = @typeInfo(T);

    return switch (info) {
        .bool => switch (value) {
            .bool => |b| b,
            else => error.TypeMismatch,
        },

        .int => |int_info| switch (value) {
            .integer => |i| blk: {
                if (int_info.signedness == .signed) {
                    break :blk @intCast(i);
                } else {
                    if (i >= 0) {
                        break :blk @intCast(i);
                    }
                    return error.TypeMismatch;
                }
            },
            else => error.TypeMismatch,
        },

        .float => switch (value) {
            .float => |f| @floatCast(f),
            .float32 => |f| @floatCast(f),
            .integer => |i| @floatFromInt(i),
            else => error.TypeMismatch,
        },

        .pointer => |ptr_info| blk: {
            // []const u8 from string
            if (ptr_info.size == .slice and ptr_info.child == u8) {
                switch (value) {
                    .string => |s| break :blk s,
                    .bytes => |b| break :blk b,
                    .symbol => |s| break :blk s,
                    else => return error.TypeMismatch,
                }
            }
            // []const T from list
            if (ptr_info.size == .slice) {
                switch (value) {
                    .list => |items| {
                        const result = try allocator.alloc(ptr_info.child, items.len);
                        for (items, 0..) |item, i| {
                            result[i] = try deserializeImpl(ptr_info.child, item, allocator);
                        }
                        break :blk result;
                    },
                    else => return error.TypeMismatch,
                }
            }
            return error.TypeMismatch;
        },

        .array => |arr_info| blk: {
            switch (value) {
                .list => |items| {
                    if (items.len != arr_info.len) return error.TypeMismatch;
                    var result: T = undefined;
                    for (items, 0..) |item, i| {
                        result[i] = try deserializeImpl(arr_info.child, item, allocator);
                    }
                    break :blk result;
                },
                .bytes => |b| {
                    if (arr_info.child == u8 and b.len == arr_info.len) {
                        var result: T = undefined;
                        @memcpy(&result, b);
                        break :blk result;
                    }
                    return error.TypeMismatch;
                },
                else => return error.TypeMismatch,
            }
        },

        .optional => |opt_info| blk: {
            switch (value) {
                .bool => |b| {
                    if (!b) break :blk null; // false -> None
                    return error.TypeMismatch;
                },
                else => break :blk try deserializeImpl(opt_info.child, value, allocator),
            }
        },

        .@"enum" => |enum_info| blk: {
            switch (value) {
                .symbol => |s| {
                    inline for (enum_info.fields) |field| {
                        if (std.mem.eql(u8, field.name, s)) {
                            break :blk @enumFromInt(field.value);
                        }
                    }
                    return error.TypeMismatch;
                },
                .string => |s| {
                    inline for (enum_info.fields) |field| {
                        if (std.mem.eql(u8, field.name, s)) {
                            break :blk @enumFromInt(field.value);
                        }
                    }
                    return error.TypeMismatch;
                },
                else => return error.TypeMismatch,
            }
        },

        .@"struct" => |struct_info| blk: {
            // From record (if has syrup_label)
            if (@hasDecl(T, "syrup_label")) {
                switch (value) {
                    .record => |rec| {
                        var result: T = undefined;
                        if (rec.fields.len != struct_info.fields.len) return error.TypeMismatch;
                        inline for (struct_info.fields, 0..) |field, i| {
                            @field(result, field.name) = try deserializeImpl(field.type, rec.fields[i], allocator);
                        }
                        break :blk result;
                    },
                    else => {},
                }
            }

            // From dictionary
            switch (value) {
                .dictionary => |entries| {
                    var result: T = undefined;
                    inline for (struct_info.fields) |field| {
                        var found = false;
                        for (entries) |entry| {
                            const key_str = switch (entry.key) {
                                .string => |s| s,
                                .symbol => |s| s,
                                else => continue,
                            };
                            if (std.mem.eql(u8, key_str, field.name)) {
                                @field(result, field.name) = try deserializeImpl(field.type, entry.value, allocator);
                                found = true;
                                break;
                            }
                        }
                        if (!found) {
                            // Check for default value
                            if (field.default_value_ptr) |default_ptr| {
                                @field(result, field.name) = @as(*const field.type, @ptrCast(@alignCast(default_ptr))).*;
                            } else {
                                return error.MissingField;
                            }
                        }
                    }
                    break :blk result;
                },
                else => return error.TypeMismatch,
            }
        },

        else => error.TypeMismatch,
    };
}

/// Legacy trait interface (for compatibility)
pub fn Serializable(comptime T: type) type {
    return struct {
        pub fn toValue(self: T, allocator: Allocator) !Value {
            return serialize(T, self, allocator);
        }

        pub fn fromValue(value: Value, allocator: Allocator) !T {
            return deserialize(T, value, allocator);
        }

        pub fn encode(self: T, allocator: Allocator, writer: anytype) !void {
            const val = try toValue(self, allocator);
            try val.encode(writer);
        }
    };
}

// Error types for deserialization
pub const DeserializeError = error{
    TypeMismatch,
    MissingField,
    OutOfMemory,
};

// ============================================================================
// TESTS
// ============================================================================

test "encode boolean" {
    var buf: [10]u8 = undefined;

    const t = Value{ .bool = true };
    const t_enc = try t.encodeBuf(&buf);
    try std.testing.expectEqualSlices(u8, "t", t_enc);

    const f = Value{ .bool = false };
    const f_enc = try f.encodeBuf(&buf);
    try std.testing.expectEqualSlices(u8, "f", f_enc);
}

test "encode integer" {
    var buf: [32]u8 = undefined;

    const zero = integer(0);
    const zero_enc = try zero.encodeBuf(&buf);
    try std.testing.expectEqualSlices(u8, "0+", zero_enc);

    const pos = integer(42);
    const pos_enc = try pos.encodeBuf(&buf);
    try std.testing.expectEqualSlices(u8, "42+", pos_enc);

    const neg = integer(-123);
    const neg_enc = try neg.encodeBuf(&buf);
    try std.testing.expectEqualSlices(u8, "123-", neg_enc);
}

test "encode string" {
    var buf: [32]u8 = undefined;

    const s = string("hello");
    const enc = try s.encodeBuf(&buf);
    try std.testing.expectEqualSlices(u8, "5\"hello", enc);
}

test "encode symbol" {
    var buf: [32]u8 = undefined;

    const s = symbol("foo");
    const enc = try s.encodeBuf(&buf);
    try std.testing.expectEqualSlices(u8, "3'foo", enc);
}

test "encode list" {
    var buf: [64]u8 = undefined;

    const items = [_]Value{ integer(1), integer(2), integer(3) };
    const l = list(&items);
    const enc = try l.encodeBuf(&buf);
    try std.testing.expectEqualSlices(u8, "[1+2+3+]", enc);
}

test "encode dictionary" {
    var buf: [128]u8 = undefined;

    const entries = [_]Value.DictEntry{
        .{ .key = string("a"), .value = integer(1) },
        .{ .key = string("b"), .value = integer(2) },
    };
    const d = dictionary(&entries);
    const enc = try d.encodeBuf(&buf);
    try std.testing.expectEqualSlices(u8, "{1\"a1+1\"b2+}", enc);
}

test "encode record" {
    var buf: [128]u8 = undefined;

    const label = string("point");
    const fields = [_]Value{ integer(10), integer(20) };
    const r = record(&label, &fields);
    const enc = try r.encodeBuf(&buf);
    try std.testing.expectEqualSlices(u8, "<5\"point10+20+>", enc);
}

test "encode tagged value" {
    var buf: [128]u8 = undefined;

    const payload = string("red");
    const tagged_val = Value.fromTagged("color", &payload);
    const enc = try tagged_val.encodeBuf(&buf);
    try std.testing.expectEqualSlices(u8, "<8'desc:tag5\"color3\"red>", enc);
}

test "encode error value" {
    var buf: [128]u8 = undefined;

    const data_entries = [_]Value.DictEntry{};
    const data_struct = dictionary(&data_entries);
    const err_val = Value.fromError("oops", "aa", &data_struct);
    const enc = try err_val.encodeBuf(&buf);
    try std.testing.expectEqualSlices(u8, "<10'desc:error4\"oops2:aa{}>", enc);
}

test "encode undefined and null" {
    var buf: [64]u8 = undefined;

    const enc_undef = try Value.fromUndefined().encodeBuf(&buf);
    try std.testing.expectEqualSlices(u8, "<9'undefined>", enc_undef);

    const enc_null = try Value.fromNull().encodeBuf(&buf);
    try std.testing.expectEqualSlices(u8, "<4'null>", enc_null);
}

test "encode float32" {
    var buf: [32]u8 = undefined;

    const f = float32(1.0);
    const enc = try f.encodeBuf(&buf);

    try std.testing.expectEqual(@as(usize, 5), enc.len);
    try std.testing.expectEqual(@as(u8, 'F'), enc[0]);
    try std.testing.expectEqual(@as(u8, 0x3F), enc[1]);
    try std.testing.expectEqual(@as(u8, 0x80), enc[2]);
    try std.testing.expectEqual(@as(u8, 0x00), enc[3]);
    try std.testing.expectEqual(@as(u8, 0x00), enc[4]);
}

test "encode float64" {
    var buf: [32]u8 = undefined;

    const f = float(1.0);
    const enc = try f.encodeBuf(&buf);

    try std.testing.expectEqual(@as(usize, 9), enc.len);
    try std.testing.expectEqual(@as(u8, 'D'), enc[0]);
    try std.testing.expectEqual(@as(u8, 0x3F), enc[1]);
    try std.testing.expectEqual(@as(u8, 0xF0), enc[2]);
    for (enc[3..9]) |b| {
        try std.testing.expectEqual(@as(u8, 0x00), b);
    }
}

test "encode bigint small" {
    var buf: [64]u8 = undefined;

    const magnitude = [_]u8{ 0x01, 0x00 };
    const b = bigint(&magnitude, false);
    const enc = try b.encodeBuf(&buf);
    try std.testing.expectEqualSlices(u8, "256+", enc);

    const neg = bigint(&magnitude, true);
    const neg_enc = try neg.encodeBuf(&buf);
    try std.testing.expectEqualSlices(u8, "256-", neg_enc);
}

test "encode bigint u128 max" {
    var buf: [64]u8 = undefined;

    const magnitude = [_]u8{
        0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
    };
    const b = bigint(&magnitude, false);
    const enc = try b.encodeBuf(&buf);
    try std.testing.expectEqualSlices(u8, "340282366920938463463374607431768211455+", enc);
}

test "encode set" {
    var buf: [64]u8 = undefined;

    const items = [_]Value{ integer(1), integer(2), integer(3) };
    const s = set(&items);
    const enc = try s.encodeBuf(&buf);
    try std.testing.expectEqualSlices(u8, "#1+2+3+$", enc);
}

test "decode boolean" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    {
        const val = try decode("t", allocator);
        try std.testing.expect(val == .bool);
        try std.testing.expect(val.bool == true);
    }

    {
        const val = try decode("f", allocator);
        try std.testing.expect(val == .bool);
        try std.testing.expect(val.bool == false);
    }
}

test "decode integer" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    {
        const val = try decode("0+", allocator);
        try std.testing.expect(val == .integer);
        try std.testing.expectEqual(@as(i64, 0), val.integer);
    }

    {
        const val = try decode("42+", allocator);
        try std.testing.expect(val == .integer);
        try std.testing.expectEqual(@as(i64, 42), val.integer);
    }

    {
        const val = try decode("123-", allocator);
        try std.testing.expect(val == .integer);
        try std.testing.expectEqual(@as(i64, -123), val.integer);
    }
}

test "decode string" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const val = try decode("5\"hello", allocator);
    try std.testing.expect(val == .string);
    try std.testing.expectEqualSlices(u8, "hello", val.string);
}

test "decode symbol" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const val = try decode("3'foo", allocator);
    try std.testing.expect(val == .symbol);
    try std.testing.expectEqualSlices(u8, "foo", val.symbol);
}

test "decode list" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    const allocator = arena.allocator();

    const val = try decode("[1+2+3+]", allocator);
    try std.testing.expect(val == .list);
    try std.testing.expectEqual(@as(usize, 3), val.list.len);
    try std.testing.expectEqual(@as(i64, 1), val.list[0].integer);
    try std.testing.expectEqual(@as(i64, 2), val.list[1].integer);
    try std.testing.expectEqual(@as(i64, 3), val.list[2].integer);
}

test "decode dictionary" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    const allocator = arena.allocator();

    const val = try decode("{1\"a1+1\"b2+}", allocator);
    try std.testing.expect(val == .dictionary);
    try std.testing.expectEqual(@as(usize, 2), val.dictionary.len);
}

test "decode record" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    const allocator = arena.allocator();

    const val = try decode("<5\"point10+20+>", allocator);
    try std.testing.expect(val == .record);
    try std.testing.expect(val.record.label.* == .string);
    try std.testing.expectEqualSlices(u8, "point", val.record.label.*.string);
    try std.testing.expectEqual(@as(usize, 2), val.record.fields.len);
}

test "decode tagged value" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    const allocator = arena.allocator();

    const val = try decode("<8'desc:tag5\"color3\"red>", allocator);
    try std.testing.expect(val == .tagged);
    try std.testing.expectEqualSlices(u8, "color", val.tagged.tag);
    try std.testing.expect(val.tagged.payload.* == .string);
    try std.testing.expectEqualSlices(u8, "red", val.tagged.payload.*.string);
}

test "decode error value" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    const allocator = arena.allocator();

    const val = try decode("<10'desc:error4\"oops2:aa{}>", allocator);
    try std.testing.expect(val == .@"error");
    try std.testing.expectEqualSlices(u8, "oops", val.@"error".message);
    try std.testing.expectEqualSlices(u8, "aa", val.@"error".identifier);
    try std.testing.expect(val.@"error".data.* == .dictionary);
    try std.testing.expectEqual(@as(usize, 0), val.@"error".data.*.dictionary.len);
}

test "decode undefined and null" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const undef_val = try decode("<9'undefined>", allocator);
    try std.testing.expect(undef_val == .undefined);

    const nul = try decode("<4'null>", allocator);
    try std.testing.expect(nul == .null);
}

test "decode float32" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const encoded = [_]u8{ 'F', 0x3F, 0x80, 0x00, 0x00 };
    const val = try decode(&encoded, allocator);
    try std.testing.expect(val == .float32);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), val.float32, 0.0001);
}

test "decode float64" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const encoded = [_]u8{ 'D', 0x3F, 0xF0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 };
    const val = try decode(&encoded, allocator);
    try std.testing.expect(val == .float);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), val.float, 0.0001);
}

test "decode set" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    const allocator = arena.allocator();

    const val = try decode("#1+2+3+$", allocator);
    try std.testing.expect(val == .set);
    try std.testing.expectEqual(@as(usize, 3), val.set.len);
}

test "roundtrip: encode then decode" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    const allocator = arena.allocator();

    const dict_entries = [_]Value.DictEntry{
        .{ .key = string("x"), .value = integer(10) },
        .{ .key = string("y"), .value = integer(20) },
    };
    const original = dictionary(&dict_entries);

    var buf: [256]u8 = undefined;
    const encoded = try original.encodeBuf(&buf);

    const decoded = try decode(encoded, allocator);

    try std.testing.expect(decoded == .dictionary);
    try std.testing.expectEqual(@as(usize, 2), decoded.dictionary.len);
}

test "value comparison" {
    // Test type ordering
    try std.testing.expect(boolean(true).compare(integer(1)) == .lt);
    try std.testing.expect(integer(1).compare(string("a")) == .lt);
    try std.testing.expect(string("a").compare(symbol("a")) == .lt);

    // Test same-type comparison
    try std.testing.expect(integer(1).compare(integer(2)) == .lt);
    try std.testing.expect(integer(2).compare(integer(1)) == .gt);
    try std.testing.expect(integer(1).compare(integer(1)) == .eq);

    try std.testing.expect(string("abc").compare(string("abd")) == .lt);
    try std.testing.expect(string("abc").compare(string("abc")) == .eq);
}

test "value equality" {
    try std.testing.expect(integer(42).eql(integer(42)));
    try std.testing.expect(!integer(42).eql(integer(43)));
    try std.testing.expect(string("hello").eql(string("hello")));
    try std.testing.expect(!string("hello").eql(symbol("hello")));
}

test "value hash" {
    const h1 = integer(42).hash();
    const h2 = integer(42).hash();
    const h3 = integer(43).hash();

    try std.testing.expectEqual(h1, h2);
    try std.testing.expect(h1 != h3);
}

test "canonical dictionary construction" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    const allocator = arena.allocator();

    // Create unsorted entries
    const entries = [_]Value.DictEntry{
        .{ .key = string("z"), .value = integer(3) },
        .{ .key = string("a"), .value = integer(1) },
        .{ .key = string("m"), .value = integer(2) },
    };

    const d = try dictionaryCanonical(allocator, &entries);

    // Verify sorted order
    try std.testing.expectEqualSlices(u8, "a", d.dictionary[0].key.string);
    try std.testing.expectEqualSlices(u8, "m", d.dictionary[1].key.string);
    try std.testing.expectEqualSlices(u8, "z", d.dictionary[2].key.string);
}

test "canonical set construction" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    const allocator = arena.allocator();

    const items = [_]Value{ integer(3), integer(1), integer(2) };
    const s = try setCanonical(allocator, &items);

    try std.testing.expectEqual(@as(i64, 1), s.set[0].integer);
    try std.testing.expectEqual(@as(i64, 2), s.set[1].integer);
    try std.testing.expectEqual(@as(i64, 3), s.set[2].integer);
}

test "encoded size calculation" {
    const i = integer(42);
    try std.testing.expectEqual(@as(usize, 3), i.encodedSize()); // "42+"

    const s = string("hello");
    try std.testing.expectEqual(@as(usize, 7), s.encodedSize()); // "5\"hello"

    const items = [_]Value{ integer(1), integer(2) };
    const l = list(&items);
    try std.testing.expectEqual(@as(usize, 6), l.encodedSize()); // "[1+2+]"
}

test "schema validation" {
    const int_schema = Schema{ .integer = {} };
    try std.testing.expect(validateSchema(integer(42), int_schema));
    try std.testing.expect(!validateSchema(string("hello"), int_schema));

    const list_int_schema = Schema{ .list = &int_schema };
    const items = [_]Value{ integer(1), integer(2) };
    try std.testing.expect(validateSchema(list(&items), list_int_schema));
}

test "stream decode" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    const allocator = arena.allocator();

    const input = "1+2+3+";
    const values = try decodeStream(input, allocator);

    try std.testing.expectEqual(@as(usize, 3), values.len);
    try std.testing.expectEqual(@as(i64, 1), values[0].integer);
    try std.testing.expectEqual(@as(i64, 2), values[1].integer);
    try std.testing.expectEqual(@as(i64, 3), values[2].integer);
}

// ============================================================================
// SERDE-LIKE SERIALIZATION TESTS
// ============================================================================

test "serialize primitive types" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    const allocator = arena.allocator();

    // bool
    const b = try serialize(bool, true, allocator);
    try std.testing.expect(b.bool == true);

    // integers
    const i = try serialize(i32, 42, allocator);
    try std.testing.expectEqual(@as(i64, 42), i.integer);

    const u = try serialize(u16, 1000, allocator);
    try std.testing.expectEqual(@as(i64, 1000), u.integer);

    // floats
    const f = try serialize(f64, 3.14, allocator);
    try std.testing.expect(@abs(f.float - 3.14) < 0.001);

    // strings
    const s = try serialize([]const u8, "hello", allocator);
    try std.testing.expectEqualSlices(u8, "hello", s.string);
}

test "encode and decode tagged/error/undefined/null" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    const allocator = arena.allocator();

    const payload = integer(1);
    const tagged_val = Value.fromTagged("foo", &payload);
    var buf: [128]u8 = undefined;
    const tagged_enc = try tagged_val.encodeBuf(&buf);
    try std.testing.expectEqualSlices(u8, "<8'desc:tag3\"foo1+>", tagged_enc);

    const tagged_dec = try decode(tagged_enc, allocator);
    try std.testing.expect(tagged_dec == .tagged);
    try std.testing.expectEqualSlices(u8, "foo", tagged_dec.tagged.tag);
    try std.testing.expect(tagged_dec.tagged.payload.* == .integer);
    try std.testing.expectEqual(@as(i64, 1), tagged_dec.tagged.payload.*.integer);

    const empty_struct = Value.fromDictionary(&[_]Value.DictEntry{});
    const err_val = Value.fromError("boom", "abc", &empty_struct);
    const err_enc = try err_val.encodeBuf(&buf);
    try std.testing.expectEqualSlices(u8, "<10'desc:error4\"boom3:abc{}>", err_enc);

    const err_dec = try decode(err_enc, allocator);
    try std.testing.expect(err_dec == .@"error");
    try std.testing.expectEqualSlices(u8, "boom", err_dec.@"error".message);
    try std.testing.expectEqualSlices(u8, "abc", err_dec.@"error".identifier);
    try std.testing.expect(err_dec.@"error".data.* == .dictionary);

    const undef_enc = try Value.fromUndefined().encodeBuf(&buf);
    try std.testing.expectEqualSlices(u8, "<9'undefined>", undef_enc);
    const undef_dec = try decode(undef_enc, allocator);
    try std.testing.expect(undef_dec == .undefined);

    const null_enc = try Value.fromNull().encodeBuf(&buf);
    try std.testing.expectEqualSlices(u8, "<4'null>", null_enc);
    const null_dec = try decode(null_enc, allocator);
    try std.testing.expect(null_dec == .null);
}

test "serialize struct to dictionary" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    const allocator = arena.allocator();

    const Person = struct {
        name: []const u8,
        age: i32,
    };

    const person = Person{ .name = "Alice", .age = 30 };
    const val = try serialize(Person, person, allocator);

    try std.testing.expect(val == .dictionary);
    try std.testing.expectEqual(@as(usize, 2), val.dictionary.len);

    // Verify encoding produces valid Syrup
    var buf: [256]u8 = undefined;
    const encoded = try val.encodeBuf(&buf);
    try std.testing.expect(encoded.len > 0);
}

test "serialize enum to symbol" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    const allocator = arena.allocator();

    const Color = enum { red, green, blue };

    const val = try serialize(Color, .green, allocator);
    try std.testing.expect(val == .symbol);
    try std.testing.expectEqualSlices(u8, "green", val.symbol);
}

test "serialize slice to list" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    const allocator = arena.allocator();

    const nums: []const i32 = &[_]i32{ 1, 2, 3 };
    const val = try serialize([]const i32, nums, allocator);

    try std.testing.expect(val == .list);
    try std.testing.expectEqual(@as(usize, 3), val.list.len);
    try std.testing.expectEqual(@as(i64, 1), val.list[0].integer);
    try std.testing.expectEqual(@as(i64, 2), val.list[1].integer);
    try std.testing.expectEqual(@as(i64, 3), val.list[2].integer);
}

test "serialize optional" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    const allocator = arena.allocator();

    const some: ?i32 = 42;
    const val_some = try serialize(?i32, some, allocator);
    try std.testing.expectEqual(@as(i64, 42), val_some.integer);

    const none: ?i32 = null;
    const val_none = try serialize(?i32, none, allocator);
    try std.testing.expect(val_none == .bool);
    try std.testing.expect(val_none.bool == false);
}

test "serialize record with syrup_label" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    const allocator = arena.allocator();

    const Point = struct {
        pub const syrup_label = "point";
        x: i32,
        y: i32,
    };

    const pt = Point{ .x = 10, .y = 20 };
    const val = try serialize(Point, pt, allocator);

    try std.testing.expect(val == .record);
    try std.testing.expectEqualSlices(u8, "point", val.record.label.string);
    try std.testing.expectEqual(@as(usize, 2), val.record.fields.len);

    // Verify encoding: <5"point10+20+>
    var buf: [64]u8 = undefined;
    const encoded = try val.encodeBuf(&buf);
    try std.testing.expectEqualSlices(u8, "<5\"point10+20+>", encoded);
}

test "deserialize primitive types" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    const allocator = arena.allocator();

    // bool
    const b = try deserialize(bool, boolean(true), allocator);
    try std.testing.expect(b == true);

    // integer
    const i = try deserialize(i32, integer(42), allocator);
    try std.testing.expectEqual(@as(i32, 42), i);

    // float
    const f = try deserialize(f64, float(3.14), allocator);
    try std.testing.expect(@abs(f - 3.14) < 0.001);

    // string
    const s = try deserialize([]const u8, string("hello"), allocator);
    try std.testing.expectEqualSlices(u8, "hello", s);
}

test "deserialize struct from dictionary" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    const allocator = arena.allocator();

    const Person = struct {
        name: []const u8,
        age: i32,
    };

    const entries = [_]Value.DictEntry{
        .{ .key = string("age"), .value = integer(30) },
        .{ .key = string("name"), .value = string("Alice") },
    };
    const dict = dictionary(&entries);

    const person = try deserialize(Person, dict, allocator);
    try std.testing.expectEqualSlices(u8, "Alice", person.name);
    try std.testing.expectEqual(@as(i32, 30), person.age);
}

test "deserialize enum from symbol" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    const allocator = arena.allocator();

    const Color = enum { red, green, blue };

    const val = try deserialize(Color, symbol("green"), allocator);
    try std.testing.expect(val == .green);
}

// ============================================================================
// CAPTP OPTIMIZATIONS (Phase 1)
// ============================================================================

/// Comptime-generated descriptor encoding tables for common CapTP labels
/// Zero-cost lookup at runtime - encodings pre-computed at compile time
pub const CapTPDescriptors = struct {
    /// Pre-encoded descriptor labels for single-byte lookup
    pub const labels = struct {
        pub const op_deliver = "10'op:deliver";
        pub const op_deliver_only = "14'op:deliver-only";
        pub const op_pick = "7'op:pick";
        pub const op_abort = "8'op:abort";
        pub const op_listen = "9'op:listen";
        pub const op_gc_export = "12'op:gc-export";
        pub const op_gc_answer = "12'op:gc-answer";
        pub const desc_export = "11'desc:export";
        pub const desc_import = "15'desc:import-object";
        pub const desc_promise = "16'desc:import-promise";
        pub const desc_answer = "11'desc:answer";
        pub const desc_tag = "8'desc:tag";
        pub const desc_error = "10'desc:error";
        pub const desc_handoff_give = "16'desc:handoff-give";
        pub const desc_handoff_receive = "19'desc:handoff-receive";
    };

    /// Pre-computed record starters for common descriptors
    /// Format: <{label}...> where label is pre-encoded
    pub fn encodeDescExportStart(buf: []u8) []u8 {
        const prefix = "<" ++ labels.desc_export;
        @memcpy(buf[0..prefix.len], prefix);
        return buf[0..prefix.len];
    }

    pub fn encodeDescAnswerStart(buf: []u8) []u8 {
        const prefix = "<" ++ labels.desc_answer;
        @memcpy(buf[0..prefix.len], prefix);
        return buf[0..prefix.len];
    }

    /// Runtime fast encoding of desc:export - writes to buffer, returns slice
    pub fn encodeDescExport(pos: u16, buf: []u8) ![]u8 {
        const prefix = "<" ++ labels.desc_export;
        @memcpy(buf[0..prefix.len], prefix);
        const num_slice = try std.fmt.bufPrint(buf[prefix.len..], "{d}", .{pos});
        const len = num_slice.len;
        buf[prefix.len + len] = '+';
        buf[prefix.len + len + 1] = '>';
        return buf[0 .. prefix.len + len + 2];
    }

    /// Runtime fast encoding of desc:answer - writes to buffer, returns slice
    pub fn encodeDescAnswer(pos: u16, buf: []u8) ![]u8 {
        const prefix = "<" ++ labels.desc_answer;
        @memcpy(buf[0..prefix.len], prefix);
        const num_slice = try std.fmt.bufPrint(buf[prefix.len..], "{d}", .{pos});
        const len = num_slice.len;
        buf[prefix.len + len] = '+';
        buf[prefix.len + len + 1] = '>';
        return buf[0 .. prefix.len + len + 2];
    }

    /// Comptime encoding for when position is known at compile time
    pub fn comptimeDescExport(comptime pos: u16) *const [comptimeDescExportLen(pos)]u8 {
        const prefix = "<" ++ labels.desc_export;
        const num_str = std.fmt.comptimePrint("{d}", .{pos});
        return prefix ++ num_str ++ "+>";
    }

    fn comptimeDescExportLen(comptime pos: u16) usize {
        const prefix = "<" ++ labels.desc_export;
        const num_str = std.fmt.comptimePrint("{d}", .{pos});
        return prefix.len + num_str.len + 2;
    }

    pub fn comptimeDescAnswer(comptime pos: u16) *const [comptimeDescAnswerLen(pos)]u8 {
        const prefix = "<" ++ labels.desc_answer;
        const num_str = std.fmt.comptimePrint("{d}", .{pos});
        return prefix ++ num_str ++ "+>";
    }

    fn comptimeDescAnswerLen(comptime pos: u16) usize {
        const prefix = "<" ++ labels.desc_answer;
        const num_str = std.fmt.comptimePrint("{d}", .{pos});
        return prefix.len + num_str.len + 2;
    }
};

/// Fast decimal parsing with minimal bounds checks
/// Parses up to 19 digits (max u64) using unrolled loop
pub inline fn parseDecimalFast(input: []const u8) struct { value: u64, len: usize } {
    if (input.len == 0) return .{ .value = 0, .len = 0 };

    var value: u64 = 0;
    var i: usize = 0;

    // SWAR fast path: check if first 8 bytes are all digits
    if (input.len >= 8) {
        // Load 8 bytes as u64
        const chunk = std.mem.readInt(u64, input[0..8], .little);
        // Each byte minus '0', check if all < 10
        const zeros: u64 = 0x3030303030303030; // '0' repeated
        const sub = chunk -% zeros;
        // Check each byte is a valid digit (0-9):
        // After subtracting '0', each byte should be < 10.
        // If byte was < '0', the subtraction wraps and sets high bit.
        // If byte was > '9', (byte - '0') >= 10, so adding 0x76 (= 0x80 - 10) sets high bit.
        const hi_bits = (sub | (sub +% 0x7676767676767676)) & 0x8080808080808080;
        if (hi_bits == 0) {
            // All 8 bytes are ASCII digits, parse directly
            const b0: u64 = (chunk >> 0) & 0xFF;
            const b1: u64 = (chunk >> 8) & 0xFF;
            const b2: u64 = (chunk >> 16) & 0xFF;
            const b3: u64 = (chunk >> 24) & 0xFF;
            const b4: u64 = (chunk >> 32) & 0xFF;
            const b5: u64 = (chunk >> 40) & 0xFF;
            const b6: u64 = (chunk >> 48) & 0xFF;
            const b7: u64 = (chunk >> 56) & 0xFF;
            value = (b0 -% 0x30) * 10000000 + (b1 -% 0x30) * 1000000 +
                (b2 -% 0x30) * 100000 + (b3 -% 0x30) * 10000 +
                (b4 -% 0x30) * 1000 + (b5 -% 0x30) * 100 +
                (b6 -% 0x30) * 10 + (b7 -% 0x30);
            i = 8;
            // Continue with remaining digits
            while (i < input.len and i < 19) : (i += 1) {
                const c = input[i];
                if (c < '0' or c > '9') break;
                value = value * 10 + (c - '0');
            }
            return .{ .value = value, .len = i };
        }
    }

    // Unrolled fast path for common small numbers (1-4 digits)
    if (input.len >= 1 and input[0] >= '0' and input[0] <= '9') {
        value = input[0] - '0';
        i = 1;
        if (input.len >= 2 and input[1] >= '0' and input[1] <= '9') {
            value = value * 10 + (input[1] - '0');
            i = 2;
            if (input.len >= 3 and input[2] >= '0' and input[2] <= '9') {
                value = value * 10 + (input[2] - '0');
                i = 3;
                if (input.len >= 4 and input[3] >= '0' and input[3] <= '9') {
                    value = value * 10 + (input[3] - '0');
                    i = 4;
                }
            }
        }
    }

    // Continue for larger numbers
    while (i < input.len and i < 19) : (i += 1) {
        const c = input[i];
        if (c < '0' or c > '9') break;
        value = value * 10 + (c - '0');
    }

    return .{ .value = value, .len = i };
}

/// Estimate arena size needed for CapTP message based on first bytes
/// Returns recommended arena capacity for reduced allocation overhead
pub fn estimateCapTPArenaSize(input: []const u8) usize {
    if (input.len < 2) return 128;

    // Check record marker and label prefix
    if (input[0] == '<') {
        // Quick check for common message types by examining label length prefix
        if (input.len > 3) {
            const result = parseDecimalFast(input[1..]);
            return switch (result.value) {
                10 => 256, // op:deliver / desc:error (10 chars) - medium
                14 => 128, // op:deliver-only (14 chars) - smaller
                5 => 64, // op:start (5 chars) - tiny
                6 => 32, // op:ping (6 chars) - minimal
                7 => 64, // op:pick (7 chars) - tiny
                8 => 128, // op:abort / desc:tag (8 chars) - small
                9 => 64, // op:listen (9 chars) - tiny
                12 => 512, // op:gc-export/answer (12 chars) - can be large
                11 => 128, // desc:export/answer (11 chars) - small
                15, 16 => 256, // desc:import-* (15-16 chars) - medium
                19 => 512, // desc:handoff-receive - large
                else => @max(128, input.len * 2), // scale with message size
            };
        }
    }
    return 256;
}

/// Parse CapTP message with pre-sized arena for optimal performance
pub fn decodeCapTP(input: []const u8, base_allocator: Allocator) !struct { value: Value, arena: std.heap.ArenaAllocator } {
    const estimated_size = estimateCapTPArenaSize(input);
    var arena = std.heap.ArenaAllocator.init(base_allocator);
    errdefer arena.deinit();

    // Pre-allocate estimated capacity
    _ = try arena.allocator().alloc(u8, estimated_size);
    _ = arena.reset(.retain_capacity);

    const value = try decode(input, arena.allocator());
    return .{ .value = value, .arena = arena };
}

test "comptime descriptor tables" {
    // Test runtime desc:export encoding
    var buf: [64]u8 = undefined;

    const export_0 = try CapTPDescriptors.encodeDescExport(0, &buf);
    try std.testing.expectEqualSlices(u8, "<11'desc:export0+>", export_0);

    const export_42 = try CapTPDescriptors.encodeDescExport(42, &buf);
    try std.testing.expectEqualSlices(u8, "<11'desc:export42+>", export_42);

    const export_255 = try CapTPDescriptors.encodeDescExport(255, &buf);
    try std.testing.expectEqualSlices(u8, "<11'desc:export255+>", export_255);

    // Test runtime desc:answer encoding
    const answer_0 = try CapTPDescriptors.encodeDescAnswer(0, &buf);
    try std.testing.expectEqualSlices(u8, "<11'desc:answer0+>", answer_0);

    // Test comptime encoding
    const ct_export_42 = CapTPDescriptors.comptimeDescExport(42);
    try std.testing.expectEqualSlices(u8, "<11'desc:export42+>", ct_export_42);

    const ct_answer_0 = CapTPDescriptors.comptimeDescAnswer(0);
    try std.testing.expectEqualSlices(u8, "<11'desc:answer0+>", ct_answer_0);
}

test "trit encoding" {
    const t_neg = Value.fromTrit(-1);
    try std.testing.expectEqualStrings("-", t_neg.symbol);

    const t_zero = Value.fromTrit(0);
    try std.testing.expectEqualStrings("0", t_zero.symbol);

    const t_pos = Value.fromTrit(1);
    try std.testing.expectEqualStrings("+", t_pos.symbol);
}

test "fast decimal parsing" {
    const r1 = parseDecimalFast("42+");
    try std.testing.expectEqual(@as(u64, 42), r1.value);
    try std.testing.expectEqual(@as(usize, 2), r1.len);

    const r2 = parseDecimalFast("12345:");
    try std.testing.expectEqual(@as(u64, 12345), r2.value);
    try std.testing.expectEqual(@as(usize, 5), r2.len);

    const r3 = parseDecimalFast("0+");
    try std.testing.expectEqual(@as(u64, 0), r3.value);
    try std.testing.expectEqual(@as(usize, 1), r3.len);
}

test "arena size estimation" {
    // op:deliver message
    try std.testing.expectEqual(@as(usize, 256), estimateCapTPArenaSize("<10'op:deliver"));

    // op:pick message
    try std.testing.expectEqual(@as(usize, 64), estimateCapTPArenaSize("<7'op:pick"));

    // desc:export descriptor
    try std.testing.expectEqual(@as(usize, 128), estimateCapTPArenaSize("<11'desc:export"));
}

test "roundtrip struct serialize/deserialize" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    const allocator = arena.allocator();

    const Config = struct {
        host: []const u8,
        port: i32,
        enabled: bool,
    };

    const original = Config{
        .host = "localhost",
        .port = 8080,
        .enabled = true,
    };

    // Serialize
    const val = try serialize(Config, original, allocator);

    // Encode to bytes
    var buf: [256]u8 = undefined;
    const encoded = try val.encodeBuf(&buf);

    // Decode from bytes
    const decoded_val = try decode(encoded, allocator);

    // Deserialize
    const restored = try deserialize(Config, decoded_val, allocator);

    try std.testing.expectEqualSlices(u8, original.host, restored.host);
    try std.testing.expectEqual(original.port, restored.port);
    try std.testing.expectEqual(original.enabled, restored.enabled);
}

test "computeCidWithBuf matches computeCid" {
    const val = integer(42);

    var cid1: [32]u8 = undefined;
    try computeCid(val, &cid1);

    var caller_buf: [256]u8 = undefined;
    var cid2: [32]u8 = undefined;
    try computeCidWithBuf(val, &cid2, &caller_buf);

    try std.testing.expectEqualSlices(u8, &cid1, &cid2);

    // Also test with a more complex value
    const entries = [_]Value.DictEntry{
        .{ .key = string("x"), .value = integer(10) },
        .{ .key = string("y"), .value = integer(20) },
    };
    const dict_val = dictionary(&entries);

    var cid3: [32]u8 = undefined;
    try computeCid(dict_val, &cid3);

    var cid4: [32]u8 = undefined;
    try computeCidWithBuf(dict_val, &cid4, &caller_buf);

    try std.testing.expectEqualSlices(u8, &cid3, &cid4);
}

test "insertion sort for small canonical dictionary" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    const allocator = arena.allocator();

    // 5 entries — uses insertion sort path (<=8)
    const entries = [_]Value.DictEntry{
        .{ .key = string("e"), .value = integer(5) },
        .{ .key = string("c"), .value = integer(3) },
        .{ .key = string("a"), .value = integer(1) },
        .{ .key = string("d"), .value = integer(4) },
        .{ .key = string("b"), .value = integer(2) },
    };

    const d = try dictionaryCanonical(allocator, &entries);
    try std.testing.expectEqualSlices(u8, "a", d.dictionary[0].key.string);
    try std.testing.expectEqualSlices(u8, "b", d.dictionary[1].key.string);
    try std.testing.expectEqualSlices(u8, "c", d.dictionary[2].key.string);
    try std.testing.expectEqualSlices(u8, "d", d.dictionary[3].key.string);
    try std.testing.expectEqualSlices(u8, "e", d.dictionary[4].key.string);
}

test "insertion sort for small canonical set" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    const allocator = arena.allocator();

    // 6 entries — uses insertion sort path (<=8)
    const items = [_]Value{ integer(6), integer(3), integer(1), integer(5), integer(2), integer(4) };
    const s = try setCanonical(allocator, &items);

    try std.testing.expectEqual(@as(i64, 1), s.set[0].integer);
    try std.testing.expectEqual(@as(i64, 2), s.set[1].integer);
    try std.testing.expectEqual(@as(i64, 3), s.set[2].integer);
    try std.testing.expectEqual(@as(i64, 4), s.set[3].integer);
    try std.testing.expectEqual(@as(i64, 5), s.set[4].integer);
    try std.testing.expectEqual(@as(i64, 6), s.set[5].integer);
}

test "SWAR fast decimal parsing for 8+ digit numbers" {
    // 8-digit number: triggers SWAR path
    const r1 = parseDecimalFast("12345678+");
    try std.testing.expectEqual(@as(u64, 12345678), r1.value);
    try std.testing.expectEqual(@as(usize, 8), r1.len);

    // 10-digit number: SWAR parses first 8, loop handles rest
    const r2 = parseDecimalFast("1234567890:");
    try std.testing.expectEqual(@as(u64, 1234567890), r2.value);
    try std.testing.expectEqual(@as(usize, 10), r2.len);

    // Timestamp-like number (13 digits)
    const r3 = parseDecimalFast("1706745600000+");
    try std.testing.expectEqual(@as(u64, 1706745600000), r3.value);
    try std.testing.expectEqual(@as(usize, 13), r3.len);

    // 8 digits exactly at boundary
    const r4 = parseDecimalFast("99999999\"");
    try std.testing.expectEqual(@as(u64, 99999999), r4.value);
    try std.testing.expectEqual(@as(usize, 8), r4.len);

    // Verify small numbers still work (existing unrolled path)
    const r5 = parseDecimalFast("42+");
    try std.testing.expectEqual(@as(u64, 42), r5.value);
    try std.testing.expectEqual(@as(usize, 2), r5.len);

    // 8 bytes but not all digits — should fall through to unrolled path
    const r6 = parseDecimalFast("1234abc+");
    try std.testing.expectEqual(@as(u64, 1234), r6.value);
    try std.testing.expectEqual(@as(usize, 4), r6.len);
}
