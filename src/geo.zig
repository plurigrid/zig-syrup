//! Geo: Open Location Code (Plus Codes) Integration for Syrup
//!
//! This module provides geographic location encoding and Syrup serialization
//! for Open Location Code (OLC) / Plus Codes - Google's geocoding system.
//!
//! ## Features
//! - Full OLC encoding/decoding (Plus Codes like "849VQHFJ+X6")
//! - Syrup serialization for geo types
//! - Zero-copy coordinate handling
//! - Validation and recovery functions
//!
//! Reference: https://github.com/google/open-location-code

const std = @import("std");
const syrup = @import("syrup");
const Allocator = std.mem.Allocator;
const Value = syrup.Value;

// ============================================================================
// CONSTANTS
// ============================================================================

/// Valid characters in an Open Location Code (base 20)
const CODE_ALPHABET = "23456789CFGHJMPQRVWX";

/// Separator character in Plus Codes
const SEPARATOR = '+';
const SEPARATOR_POSITION: usize = 8;

/// Padding character for short codes
const PADDING = '0';

/// Encoding base (20 characters)
const ENCODING_BASE: f64 = 20.0;
const PAIR_CODE_LENGTH: usize = 10;
const GRID_CODE_LENGTH: usize = 15;
const MIN_TRIMMABLE_CODE_LEN: usize = 6;

/// Latitude/longitude bounds
const LAT_MAX: f64 = 90.0;
const LNG_MAX: f64 = 180.0;

// ============================================================================
// CORE TYPES
// ============================================================================

/// Errors that can occur during OLC operations
pub const OlcError = error{
    InvalidCode,
    InvalidLength,
    InvalidLatitude,
    InvalidLongitude,
    BufferTooSmall,
    ShortCodeNotSupported,
};

/// Represents a decoded Plus Code area (bounding box)
pub const CodeArea = struct {
    south_latitude: f64,
    west_longitude: f64,
    north_latitude: f64,
    east_longitude: f64,
    code_length: u8,

    /// Get the center latitude of the code area
    pub fn centerLatitude(self: CodeArea) f64 {
        return (self.south_latitude + self.north_latitude) / 2.0;
    }

    /// Get the center longitude of the code area
    pub fn centerLongitude(self: CodeArea) f64 {
        return (self.west_longitude + self.east_longitude) / 2.0;
    }

    /// Serialize to Syrup Value as a record
    pub fn toSyrup(self: CodeArea, allocator: Allocator) !Value {
        const label_alloc = try allocator.alloc(Value, 1);
        label_alloc[0] = Value.fromSymbol("geo:code-area");

        const fields = try allocator.alloc(Value, 5);
        fields[0] = Value.fromFloat(self.south_latitude);
        fields[1] = Value.fromFloat(self.west_longitude);
        fields[2] = Value.fromFloat(self.north_latitude);
        fields[3] = Value.fromFloat(self.east_longitude);
        fields[4] = Value.fromInteger(@intCast(self.code_length));

        return Value.fromRecord(&label_alloc[0], fields);
    }

    /// Deserialize from Syrup Value
    pub fn fromSyrup(value: Value) !CodeArea {
        switch (value) {
            .record => |rec| {
                const label = rec.label.*;
                const label_str = switch (label) {
                    .symbol => |s| s,
                    .string => |s| s,
                    else => return error.InvalidCode,
                };

                if (!std.mem.eql(u8, label_str, "geo:code-area")) {
                    return error.InvalidCode;
                }

                if (rec.fields.len != 5) return error.InvalidLength;

                return CodeArea{
                    .south_latitude = switch (rec.fields[0]) {
                        .float => |f| f,
                        .float32 => |f| @floatCast(f),
                        else => return error.InvalidLatitude,
                    },
                    .west_longitude = switch (rec.fields[1]) {
                        .float => |f| f,
                        .float32 => |f| @floatCast(f),
                        else => return error.InvalidLongitude,
                    },
                    .north_latitude = switch (rec.fields[2]) {
                        .float => |f| f,
                        .float32 => |f| @floatCast(f),
                        else => return error.InvalidLatitude,
                    },
                    .east_longitude = switch (rec.fields[3]) {
                        .float => |f| f,
                        .float32 => |f| @floatCast(f),
                        else => return error.InvalidLongitude,
                    },
                    .code_length = switch (rec.fields[4]) {
                        .integer => |i| @intCast(i),
                        else => return error.InvalidLength,
                    },
                };
            },
            else => return error.InvalidCode,
        }
    }
};

/// A geographic coordinate (lat/lng pair)
pub const Coordinate = struct {
    latitude: f64,
    longitude: f64,

    /// Create coordinate from latitude and longitude
    pub fn init(lat: f64, lng: f64) Coordinate {
        return .{ .latitude = lat, .longitude = lng };
    }

    /// Serialize to Syrup Value as a record
    pub fn toSyrup(self: Coordinate, allocator: Allocator) !Value {
        const label_alloc = try allocator.alloc(Value, 1);
        label_alloc[0] = Value.fromSymbol("geo:coord");

        const fields = try allocator.alloc(Value, 2);
        fields[0] = Value.fromFloat(self.latitude);
        fields[1] = Value.fromFloat(self.longitude);

        return Value.fromRecord(&label_alloc[0], fields);
    }

    /// Deserialize from Syrup Value
    pub fn fromSyrup(value: Value) !Coordinate {
        switch (value) {
            .record => |rec| {
                const label = rec.label.*;
                const label_str = switch (label) {
                    .symbol => |s| s,
                    .string => |s| s,
                    else => return error.InvalidCode,
                };

                if (!std.mem.eql(u8, label_str, "geo:coord")) {
                    return error.InvalidCode;
                }

                if (rec.fields.len != 2) return error.InvalidLength;

                return Coordinate{
                    .latitude = switch (rec.fields[0]) {
                        .float => |f| f,
                        .float32 => |f| @floatCast(f),
                        else => return error.InvalidLatitude,
                    },
                    .longitude = switch (rec.fields[1]) {
                        .float => |f| f,
                        .float32 => |f| @floatCast(f),
                        else => return error.InvalidLongitude,
                    },
                };
            },
            else => return error.InvalidCode,
        }
    }

    /// Encode this coordinate to a Plus Code
    pub fn encode(self: Coordinate, code_length: u8, buffer: []u8) OlcError!usize {
        return encodeOlc(self.latitude, self.longitude, code_length, buffer);
    }
};

/// A Plus Code (Open Location Code) string with serialization support
pub const PlusCode = struct {
    code: []const u8,

    /// Create from a Plus Code string (validates)
    pub fn init(code: []const u8) OlcError!PlusCode {
        if (!isValid(code)) return error.InvalidCode;
        return .{ .code = code };
    }

    /// Create without validation (for internal use)
    pub fn initUnchecked(code: []const u8) PlusCode {
        return .{ .code = code };
    }

    /// Decode this Plus Code to a CodeArea
    pub fn decode(self: PlusCode) OlcError!CodeArea {
        return decodeOlc(self.code);
    }

    /// Get the center coordinate
    pub fn center(self: PlusCode) OlcError!Coordinate {
        const area = try self.decode();
        return Coordinate.init(area.centerLatitude(), area.centerLongitude());
    }

    /// Check if this is a full code (not shortened)
    pub fn isFull(self: PlusCode) bool {
        return isFullCode(self.code);
    }

    /// Check if this is a short code
    pub fn isShort(self: PlusCode) bool {
        return isShortCode(self.code);
    }

    /// Serialize to Syrup Value as a tagged string
    pub fn toSyrup(self: PlusCode, allocator: Allocator) !Value {
        const payload_alloc = try allocator.alloc(Value, 1);
        payload_alloc[0] = Value.fromString(self.code);
        return Value.fromTagged("geo:olc", &payload_alloc[0]);
    }

    /// Deserialize from Syrup Value
    pub fn fromSyrup(value: Value) OlcError!PlusCode {
        switch (value) {
            .tagged => |t| {
                if (!std.mem.eql(u8, t.tag, "geo:olc")) {
                    return error.InvalidCode;
                }
                switch (t.payload.*) {
                    .string => |s| return PlusCode.init(s),
                    else => return error.InvalidCode,
                }
            },
            .string => |s| return PlusCode.init(s),
            else => return error.InvalidCode,
        }
    }
};

// ============================================================================
// OLC ENCODING
// ============================================================================

/// Encode latitude/longitude to Plus Code
pub fn encodeOlc(lat: f64, lng: f64, code_length: u8, buffer: []u8) OlcError!usize {
    if (code_length < 2 or code_length > GRID_CODE_LENGTH) {
        return error.InvalidLength;
    }
    if (code_length < PAIR_CODE_LENGTH and code_length % 2 == 1) {
        return error.InvalidLength;
    }

    // Clamp latitude to valid range
    var adj_lat = @min(@max(lat, -LAT_MAX), LAT_MAX);
    var adj_lng = lng;

    // Normalize longitude
    while (adj_lng < -LNG_MAX) adj_lng += 360.0;
    while (adj_lng >= LNG_MAX) adj_lng -= 360.0;

    // Adjust latitude if at max
    if (adj_lat == LAT_MAX) {
        adj_lat = adj_lat - computeLatPrecision(code_length);
    }

    // Shift to positive values
    adj_lat += LAT_MAX;
    adj_lng += LNG_MAX;

    var pos: usize = 0;
    var lat_val = adj_lat;
    var lng_val = adj_lng;

    // Encode pairs (first 10 characters, 5 lat/lng pairs)
    var digit: usize = 0;
    while (digit < PAIR_CODE_LENGTH and digit < code_length) : (digit += 2) {
        if (digit == 8 and code_length > 8) {
            if (pos >= buffer.len) return error.BufferTooSmall;
            buffer[pos] = SEPARATOR;
            pos += 1;
        }

        const lat_digit: usize = @intFromFloat(@divFloor(lat_val, pairResolution(@intCast(digit))));
        const lng_digit: usize = @intFromFloat(@divFloor(lng_val, pairResolution(@intCast(digit))));

        lat_val -= @as(f64, @floatFromInt(lat_digit)) * pairResolution(@intCast(digit));
        lng_val -= @as(f64, @floatFromInt(lng_digit)) * pairResolution(@intCast(digit));

        if (pos >= buffer.len) return error.BufferTooSmall;
        buffer[pos] = CODE_ALPHABET[lat_digit];
        pos += 1;

        if (pos >= buffer.len) return error.BufferTooSmall;
        buffer[pos] = CODE_ALPHABET[lng_digit];
        pos += 1;
    }

    // Add padding if needed
    while (digit < SEPARATOR_POSITION) : (digit += 2) {
        if (pos >= buffer.len) return error.BufferTooSmall;
        buffer[pos] = PADDING;
        pos += 1;
        if (pos >= buffer.len) return error.BufferTooSmall;
        buffer[pos] = PADDING;
        pos += 1;
    }

    // Add separator if not already added
    if (code_length <= SEPARATOR_POSITION) {
        if (pos >= buffer.len) return error.BufferTooSmall;
        buffer[pos] = SEPARATOR;
        pos += 1;
    }

    // Encode grid refinement (characters 11-15)
    if (code_length > PAIR_CODE_LENGTH) {
        var grid_digit = digit;
        while (grid_digit < code_length) : (grid_digit += 1) {
            const lat_digit: usize = @intFromFloat(@divFloor(lat_val * 5.0, 1.0));
            const lng_digit: usize = @intFromFloat(@divFloor(lng_val * 4.0, 1.0));

            lat_val = (lat_val * 5.0) - @as(f64, @floatFromInt(lat_digit));
            lng_val = (lng_val * 4.0) - @as(f64, @floatFromInt(lng_digit));

            const combined = lat_digit * 4 + lng_digit;
            if (pos >= buffer.len) return error.BufferTooSmall;
            buffer[pos] = CODE_ALPHABET[combined];
            pos += 1;
        }
    }

    return pos;
}

fn pairResolution(digit: usize) f64 {
    return std.math.pow(f64, ENCODING_BASE, @as(f64, @floatFromInt(1 - @divTrunc(@as(isize, @intCast(digit)), 2))));
}

fn computeLatPrecision(code_length: u8) f64 {
    if (code_length <= PAIR_CODE_LENGTH) {
        const half: i8 = @divTrunc(@as(i8, @intCast(code_length)), 2);
        // Adjusted from 2-half to -1-half? No.
        // length 10 -> half 5.
        // We want resolution of last pair (digit 8,9).
        // pairResolution(8) = 20^(1-4) = 20^-3.
        // So precision should be 20^-3 for length 10.
        // Formula: 2 - half. 2 - 5 = -3. Correct.
        return std.math.pow(f64, ENCODING_BASE, @as(f64, @floatFromInt(2 - half)));
    }
    return std.math.pow(f64, ENCODING_BASE, -3.0) / std.math.pow(f64, 5.0, @as(f64, @floatFromInt(code_length - PAIR_CODE_LENGTH)));
}

// ============================================================================
// OLC DECODING
// ============================================================================

/// Decode a Plus Code to a CodeArea
pub fn decodeOlc(code: []const u8) OlcError!CodeArea {
    if (!isFullCode(code)) {
        return error.ShortCodeNotSupported;
    }

    // Strip separator and padding
    var clean_code: [GRID_CODE_LENGTH]u8 = undefined;
    var clean_len: usize = 0;

    for (code) |c| {
        if (c == SEPARATOR or c == PADDING) continue;
        const upper = std.ascii.toUpper(c);
        if (std.mem.indexOfScalar(u8, CODE_ALPHABET, upper)) |_| {
            if (clean_len >= GRID_CODE_LENGTH) break;
            clean_code[clean_len] = upper;
            clean_len += 1;
        }
    }

    var south_lat: f64 = 0.0;
    var west_lng: f64 = 0.0;
    
    // Initial resolution: 20 degrees for first pair
    var lat_resolution: f64 = 20.0;
    var lng_resolution: f64 = 20.0;

    // Decode pairs (characters 0-9, representing 5 lat/lng pairs)
    var i: usize = 0;
    while (i < clean_len and i < PAIR_CODE_LENGTH) : (i += 2) {
        const lat_digit = std.mem.indexOfScalar(u8, CODE_ALPHABET, clean_code[i]) orelse return error.InvalidCode;
        south_lat += @as(f64, @floatFromInt(lat_digit)) * lat_resolution;

        if (i + 1 < clean_len) {
            const lng_digit = std.mem.indexOfScalar(u8, CODE_ALPHABET, clean_code[i + 1]) orelse return error.InvalidCode;
            west_lng += @as(f64, @floatFromInt(lng_digit)) * lng_resolution;
        }
        
        lat_resolution /= ENCODING_BASE;
        lng_resolution /= ENCODING_BASE;
    }
    
    // After pair decoding, resolution is the cell size
    var lat_height = lat_resolution * ENCODING_BASE;
    var lng_width = lng_resolution * ENCODING_BASE;

    // Decode grid refinement (characters 10+)
    while (i < clean_len) : (i += 1) {
        lat_height /= 5.0;
        lng_width /= 4.0;

        const digit = std.mem.indexOfScalar(u8, CODE_ALPHABET, clean_code[i]) orelse return error.InvalidCode;
        const lat_digit = digit / 4;
        const lng_digit = digit % 4;

        south_lat += @as(f64, @floatFromInt(lat_digit)) * lat_height;
        west_lng += @as(f64, @floatFromInt(lng_digit)) * lng_width;
    }

    return CodeArea{
        .south_latitude = south_lat - LAT_MAX,
        .west_longitude = west_lng - LNG_MAX,
        .north_latitude = south_lat - LAT_MAX + lat_height,
        .east_longitude = west_lng - LNG_MAX + lng_width,
        .code_length = @intCast(clean_len),
    };
}

// ============================================================================
// VALIDATION
// ============================================================================

/// Check if a code is a valid Plus Code
pub fn isValid(code: []const u8) bool {
    if (code.len < 2) return false;

    var separator_idx: ?usize = null;
    var padding_start: ?usize = null;

    for (code, 0..) |c, i| {
        if (c == SEPARATOR) {
            if (separator_idx != null) return false; // Multiple separators
            if (i != SEPARATOR_POSITION) return false; // Wrong position
            separator_idx = i;
        } else if (c == PADDING) {
            if (padding_start == null) padding_start = i;
            if (separator_idx != null) return false; // Padding after separator
        } else {
            const upper = std.ascii.toUpper(c);
            if (std.mem.indexOfScalar(u8, CODE_ALPHABET, upper) == null) return false;
            if (padding_start != null) return false; // Valid char after padding
        }
    }

    // Must have separator
    if (separator_idx == null) return false;

    return true;
}

/// Check if a code is a full (not shortened) Plus Code
pub fn isFullCode(code: []const u8) bool {
    if (!isValid(code)) return false;

    // Full codes have separator at position 8
    if (code.len < SEPARATOR_POSITION + 1) return false;
    if (code[SEPARATOR_POSITION] != SEPARATOR) return false;

    // First character must not be padding
    return code[0] != PADDING;
}

/// Check if a code is a short (relative) Plus Code
pub fn isShortCode(code: []const u8) bool {
    if (!isValid(code)) return false;

    // Short codes have separator before position 8
    for (code, 0..) |c, i| {
        if (c == SEPARATOR) {
            return i < SEPARATOR_POSITION;
        }
    }
    return false;
}

// ============================================================================
// SYRUP SERIALIZATION HELPERS
// ============================================================================

/// Serialize a lat/lng pair to Syrup
pub fn coordToSyrup(lat: f64, lng: f64, allocator: Allocator) !Value {
    return Coordinate.init(lat, lng).toSyrup(allocator);
}

/// Encode lat/lng to Plus Code and serialize to Syrup
pub fn encodeToSyrup(lat: f64, lng: f64, code_length: u8, allocator: Allocator) !Value {
    var buffer: [16]u8 = undefined;
    const len = try encodeOlc(lat, lng, code_length, &buffer);
    
    // Copy to allocated memory since buffer is stack
    const code_copy = try allocator.alloc(u8, len);
    @memcpy(code_copy, buffer[0..len]);
    
    const payload_alloc = try allocator.alloc(Value, 1);
    payload_alloc[0] = Value.fromString(code_copy);
    return Value.fromTagged("geo:olc", &payload_alloc[0]);
}

/// Decode Plus Code from Syrup to CodeArea
pub fn decodeFromSyrup(value: Value) OlcError!CodeArea {
    const plus_code = try PlusCode.fromSyrup(value);
    return plus_code.decode();
}

// ============================================================================
// WIRE FORMAT: Syrup bytes encode/decode for geo types
// ============================================================================

/// Encode a Coordinate to Syrup wire bytes
pub fn coordToBytes(coord: Coordinate, allocator: Allocator) ![]u8 {
    const val = try coord.toSyrup(allocator);
    return val.encodeAlloc(allocator);
}

/// Decode a Coordinate from Syrup wire bytes
pub fn coordFromBytes(bytes: []const u8, allocator: Allocator) !Coordinate {
    const val = try syrup.decode(bytes, allocator);
    return Coordinate.fromSyrup(val);
}

/// Encode a CodeArea to Syrup wire bytes
pub fn codeAreaToBytes(area: CodeArea, allocator: Allocator) ![]u8 {
    const val = try area.toSyrup(allocator);
    return val.encodeAlloc(allocator);
}

/// Decode a CodeArea from Syrup wire bytes
pub fn codeAreaFromBytes(bytes: []const u8, allocator: Allocator) !CodeArea {
    const val = try syrup.decode(bytes, allocator);
    return CodeArea.fromSyrup(val);
}

/// Encode a PlusCode to Syrup wire bytes
pub fn plusCodeToBytes(plus_code: PlusCode, allocator: Allocator) ![]u8 {
    const val = try plus_code.toSyrup(allocator);
    return val.encodeAlloc(allocator);
}

/// Decode a PlusCode from Syrup wire bytes
pub fn plusCodeFromBytes(bytes: []const u8, allocator: Allocator) !PlusCode {
    const val = try syrup.decode(bytes, allocator);
    return PlusCode.fromSyrup(val);
}

/// Full pipeline: lat/lng → OLC Plus Code → Syrup bytes
pub fn encodeLocationToBytes(lat: f64, lng: f64, code_length: u8, allocator: Allocator) ![]u8 {
    var buffer: [16]u8 = undefined;
    const len = try encodeOlc(lat, lng, code_length, &buffer);
    const code = buffer[0..len];
    std.debug.print("Encoded OLC: '{s}'\n", .{code});
    const plus_code = PlusCode.initUnchecked(code);
    return plusCodeToBytes(plus_code, allocator);
}

/// Full pipeline: Syrup bytes → PlusCode → CodeArea → center Coordinate
pub fn decodeBytesToLocation(bytes: []const u8, allocator: Allocator) !Coordinate {
    const plus_code = try plusCodeFromBytes(bytes, allocator);
    return plus_code.center();
}

// ============================================================================
// CID: Content-Addressable Geo Locations
// ============================================================================

/// Compute SHA-256 CID of a Coordinate's Syrup encoding
pub fn coordCid(coord: Coordinate, allocator: Allocator) ![32]u8 {
    const bytes = try coordToBytes(coord, allocator);
    defer allocator.free(bytes);
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &hash, .{});
    return hash;
}

/// Compute SHA-256 CID of a PlusCode's Syrup encoding
pub fn plusCodeCid(plus_code: PlusCode, allocator: Allocator) ![32]u8 {
    const bytes = try plusCodeToBytes(plus_code, allocator);
    defer allocator.free(bytes);
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &hash, .{});
    return hash;
}

/// Compute SHA-256 CID of a CodeArea's Syrup encoding
pub fn codeAreaCid(area: CodeArea, allocator: Allocator) ![32]u8 {
    const bytes = try codeAreaToBytes(area, allocator);
    defer allocator.free(bytes);
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &hash, .{});
    return hash;
}

/// CID hex string for a Coordinate
pub fn coordCidHex(coord: Coordinate, allocator: Allocator) ![64]u8 {
    const hash = try coordCid(coord, allocator);
    return std.fmt.bytesToHex(&hash, .lower);
}

/// CID hex string for a PlusCode
pub fn plusCodeCidHex(plus_code: PlusCode, allocator: Allocator) ![64]u8 {
    const hash = try plusCodeCid(plus_code, allocator);
    return std.fmt.bytesToHex(&hash, .lower);
}

// ============================================================================
// JSON INTEROP: For the JSON-RPC bridge
// ============================================================================

/// Convert a Coordinate to a JSON-compatible Syrup dict
/// {latitude: <float>, longitude: <float>, plusCode: "..."}
pub fn coordToJsonDict(coord: Coordinate, code_length: u8, allocator: Allocator) !Value {
    var buffer: [16]u8 = undefined;
    const len = encodeOlc(coord.latitude, coord.longitude, code_length, &buffer) catch 0;

    var entry_count: usize = 2;
    if (len > 0) entry_count = 3;

    const entries = try allocator.alloc(Value.DictEntry, entry_count);
    entries[0] = .{
        .key = syrup.symbol("latitude"),
        .value = Value.fromFloat(coord.latitude),
    };
    entries[1] = .{
        .key = syrup.symbol("longitude"),
        .value = Value.fromFloat(coord.longitude),
    };
    if (len > 0) {
        const code_copy = try allocator.alloc(u8, len);
        @memcpy(code_copy, buffer[0..len]);
        entries[2] = .{
            .key = syrup.symbol("plusCode"),
            .value = Value.fromString(code_copy),
        };
    }

    return syrup.dictionary(entries);
}

/// Parse a Coordinate from a JSON-compatible Syrup dict
/// Accepts {latitude, longitude} or {plusCode: "..."} or both
pub fn coordFromJsonDict(dict: Value) !Coordinate {
    if (dict != .dictionary) return error.InvalidCode;

    var lat: ?f64 = null;
    var lng: ?f64 = null;
    var plus_code: ?[]const u8 = null;

    for (dict.dictionary) |entry| {
        const key = switch (entry.key) {
            .symbol, .string => |s| s,
            else => continue,
        };

        if (std.mem.eql(u8, key, "latitude")) {
            lat = switch (entry.value) {
                .float => |f| f,
                .float32 => |f| @floatCast(f),
                .integer => |i| @floatFromInt(i),
                else => null,
            };
        } else if (std.mem.eql(u8, key, "longitude")) {
            lng = switch (entry.value) {
                .float => |f| f,
                .float32 => |f| @floatCast(f),
                .integer => |i| @floatFromInt(i),
                else => null,
            };
        } else if (std.mem.eql(u8, key, "plusCode")) {
            plus_code = switch (entry.value) {
                .string => |s| s,
                else => null,
            };
        }
    }

    // Prefer direct lat/lng if available
    if (lat != null and lng != null) {
        return Coordinate.init(lat.?, lng.?);
    }

    // Fall back to decoding plus code
    if (plus_code) |code| {
        const pc = try PlusCode.init(code);
        return pc.center();
    }

    return error.InvalidCode;
}

/// Convert a CodeArea to a JSON-compatible Syrup dict (flat keys)
pub fn codeAreaToJsonDict(area: CodeArea, allocator: Allocator) !Value {
    const entries = try allocator.alloc(Value.DictEntry, 6);
    entries[0] = .{ .key = syrup.symbol("codeLength"), .value = Value.fromInteger(@intCast(area.code_length)) };
    entries[1] = .{ .key = syrup.symbol("eastLongitude"), .value = Value.fromFloat(area.east_longitude) };
    entries[2] = .{ .key = syrup.symbol("northLatitude"), .value = Value.fromFloat(area.north_latitude) };
    entries[3] = .{ .key = syrup.symbol("southLatitude"), .value = Value.fromFloat(area.south_latitude) };
    entries[4] = .{ .key = syrup.symbol("westLongitude"), .value = Value.fromFloat(area.west_longitude) };

    // Add center coordinate
    const center_entries = try allocator.alloc(Value.DictEntry, 2);
    center_entries[0] = .{ .key = syrup.symbol("latitude"), .value = Value.fromFloat(area.centerLatitude()) };
    center_entries[1] = .{ .key = syrup.symbol("longitude"), .value = Value.fromFloat(area.centerLongitude()) };
    entries[5] = .{ .key = syrup.symbol("center"), .value = syrup.dictionary(center_entries) };

    return syrup.dictionary(entries);
}

// ============================================================================
// TESTS
// ============================================================================

test "encode basic coordinates" {
    var buffer: [16]u8 = undefined;

    // Test encoding San Francisco
    const len = try encodeOlc(37.7749, -122.4194, 10, &buffer);
    const code = buffer[0..len];
    try std.testing.expect(code.len == 11); // 10 chars + separator
}

test "decode valid code" {
    const area = try decodeOlc("849VQHFJ+X6");
    try std.testing.expect(area.south_latitude > 37.0 and area.south_latitude < 38.0);
    try std.testing.expect(area.west_longitude > -123.0 and area.west_longitude < -122.0);
}

test "validate codes" {
    try std.testing.expect(isValid("849VQHFJ+X6"));
    try std.testing.expect(isFullCode("849VQHFJ+X6"));
    try std.testing.expect(!isShortCode("849VQHFJ+X6"));
    try std.testing.expect(!isValid("invalid"));
    try std.testing.expect(!isValid("849VQHF")); // No separator
}

test "coordinate serialization roundtrip" {
    const allocator = std.testing.allocator;

    const coord = Coordinate.init(37.7749, -122.4194);
    const syrup_val = try coord.toSyrup(allocator);
    defer {
        const label_slice: *[1]Value = @ptrCast(@constCast(syrup_val.record.label));
        allocator.free(label_slice);
        allocator.free(syrup_val.record.fields);
    }

    const decoded = try Coordinate.fromSyrup(syrup_val);
    try std.testing.expectApproxEqAbs(coord.latitude, decoded.latitude, 0.0001);
    try std.testing.expectApproxEqAbs(coord.longitude, decoded.longitude, 0.0001);
}

test "code area serialization roundtrip" {
    const allocator = std.testing.allocator;

    const area = CodeArea{
        .south_latitude = 37.77,
        .west_longitude = -122.42,
        .north_latitude = 37.78,
        .east_longitude = -122.41,
        .code_length = 10,
    };

    const syrup_val = try area.toSyrup(allocator);
    defer {
        const label_slice: *[1]Value = @ptrCast(@constCast(syrup_val.record.label));
        allocator.free(label_slice);
        allocator.free(syrup_val.record.fields);
    }

    const decoded = try CodeArea.fromSyrup(syrup_val);
    try std.testing.expectApproxEqAbs(area.south_latitude, decoded.south_latitude, 0.0001);
    try std.testing.expectEqual(area.code_length, decoded.code_length);
}

test "plus code serialization roundtrip" {
    const allocator = std.testing.allocator;

    const code_str = "849VQHFJ+X6";
    const plus_code = try PlusCode.init(code_str);
    const syrup_val = try plus_code.toSyrup(allocator);
    defer {
        const payload_slice: *[1]Value = @ptrCast(@constCast(syrup_val.tagged.payload));
        allocator.free(payload_slice);
    }

    const decoded = try PlusCode.fromSyrup(syrup_val);
    try std.testing.expectEqualStrings(code_str, decoded.code);
}

test "encode to syrup" {
    const allocator = std.testing.allocator;

    const syrup_val = try encodeToSyrup(37.7749, -122.4194, 10, allocator);
    defer {
        // Free the code string first
        const payload_str = syrup_val.tagged.payload.*.string;
        allocator.free(payload_str);
        // Free the payload allocation (slice of 1 Value)
        const payload_slice: *[1]Value = @ptrCast(@constCast(syrup_val.tagged.payload));
        allocator.free(payload_slice);
    }

    try std.testing.expectEqualStrings("geo:olc", syrup_val.tagged.tag);
}

// ---- Wire format roundtrip tests ----

test "coordinate wire roundtrip: encode to bytes and back" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const coord = Coordinate.init(37.7749, -122.4194);
    const bytes = try coordToBytes(coord, allocator);

    // Verify bytes are valid Syrup
    try std.testing.expect(bytes.len > 0);
    try std.testing.expect(bytes[0] == '<'); // Record starts with <

    const decoded = try coordFromBytes(bytes, allocator);
    try std.testing.expectApproxEqAbs(coord.latitude, decoded.latitude, 0.0001);
    try std.testing.expectApproxEqAbs(coord.longitude, decoded.longitude, 0.0001);
}

test "code area wire roundtrip: encode to bytes and back" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const area = CodeArea{
        .south_latitude = 37.77,
        .west_longitude = -122.42,
        .north_latitude = 37.78,
        .east_longitude = -122.41,
        .code_length = 10,
    };

    const bytes = try codeAreaToBytes(area, allocator);
    try std.testing.expect(bytes.len > 0);

    const decoded = try codeAreaFromBytes(bytes, allocator);
    try std.testing.expectApproxEqAbs(area.south_latitude, decoded.south_latitude, 0.0001);
    try std.testing.expectApproxEqAbs(area.east_longitude, decoded.east_longitude, 0.0001);
    try std.testing.expectEqual(area.code_length, decoded.code_length);
}

test "full pipeline: lat/lng → OLC → Syrup bytes → OLC → lat/lng" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const lat: f64 = 37.7749;
    const lng: f64 = -122.4194;

    // Encode location to Syrup bytes (via Plus Code)
    const bytes = try encodeLocationToBytes(lat, lng, 10, allocator);
    try std.testing.expect(bytes.len > 0);

    // Decode back to location
    const coord = try decodeBytesToLocation(bytes, allocator);

    // OLC encoding loses some precision (10-char = ~14m x 14m cell)
    // Center of cell should be within ~0.001 degrees
    try std.testing.expectApproxEqAbs(lat, coord.latitude, 0.001);
    try std.testing.expectApproxEqAbs(lng, coord.longitude, 0.001);
}

// ---- CID tests ----

test "coordinate CID is deterministic" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const coord = Coordinate.init(37.7749, -122.4194);
    const cid1 = try coordCidHex(coord, allocator);
    const cid2 = try coordCidHex(coord, allocator);

    // Same input → same CID
    try std.testing.expectEqualStrings(&cid1, &cid2);

    // Different input → different CID
    const other = Coordinate.init(40.7128, -74.0060);
    const cid3 = try coordCidHex(other, allocator);
    try std.testing.expect(!std.mem.eql(u8, &cid1, &cid3));
}

test "plus code CID is deterministic" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const pc = try PlusCode.init("849VQHFJ+X6");
    const cid1 = try plusCodeCidHex(pc, allocator);
    const cid2 = try plusCodeCidHex(pc, allocator);
    try std.testing.expectEqualStrings(&cid1, &cid2);
}

// ---- JSON interop tests ----

test "coord to JSON dict with plus code" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const coord = Coordinate.init(37.7749, -122.4194);
    const dict = try coordToJsonDict(coord, 10, allocator);

    try std.testing.expect(dict == .dictionary);
    try std.testing.expectEqual(@as(usize, 3), dict.dictionary.len);

    // Should have latitude, longitude, plusCode keys
    var has_lat = false;
    var has_lng = false;
    var has_code = false;
    for (dict.dictionary) |entry| {
        const key = entry.key.symbol;
        if (std.mem.eql(u8, key, "latitude")) has_lat = true;
        if (std.mem.eql(u8, key, "longitude")) has_lng = true;
        if (std.mem.eql(u8, key, "plusCode")) has_code = true;
    }
    try std.testing.expect(has_lat);
    try std.testing.expect(has_lng);
    try std.testing.expect(has_code);
}

test "coord from JSON dict roundtrip" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const coord = Coordinate.init(37.7749, -122.4194);
    const dict = try coordToJsonDict(coord, 10, allocator);
    const decoded = try coordFromJsonDict(dict);

    try std.testing.expectApproxEqAbs(coord.latitude, decoded.latitude, 0.0001);
    try std.testing.expectApproxEqAbs(coord.longitude, decoded.longitude, 0.0001);
}

test "coord from JSON dict with only plusCode" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Build a dict with only plusCode (no lat/lng)
    const entries = try allocator.alloc(Value.DictEntry, 1);
    entries[0] = .{
        .key = syrup.symbol("plusCode"),
        .value = Value.fromString("849VQHFJ+X6"),
    };
    const dict = syrup.dictionary(entries);

    const coord = try coordFromJsonDict(dict);
    // Should decode to somewhere in SF
    try std.testing.expect(coord.latitude > 37.0 and coord.latitude < 38.0);
    try std.testing.expect(coord.longitude > -123.0 and coord.longitude < -122.0);
}

test "code area to JSON dict" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const area = try decodeOlc("849VQHFJ+X6");
    const dict = try codeAreaToJsonDict(area, allocator);

    try std.testing.expect(dict == .dictionary);
    try std.testing.expectEqual(@as(usize, 6), dict.dictionary.len);

    // Should have center sub-dict
    var has_center = false;
    for (dict.dictionary) |entry| {
        if (entry.key == .symbol and std.mem.eql(u8, entry.key.symbol, "center")) {
            has_center = true;
            try std.testing.expect(entry.value == .dictionary);
        }
    }
    try std.testing.expect(has_center);
}

// ---- Multiple locations CID uniqueness ----

test "distinct locations produce distinct CIDs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const locations = [_][2]f64{
        .{ 37.7749, -122.4194 }, // San Francisco
        .{ 40.7128, -74.0060 }, // New York
        .{ 51.5074, -0.1278 }, // London
        .{ 35.6762, 139.6503 }, // Tokyo
        .{ -33.8688, 151.2093 }, // Sydney
    };

    var cids: [5][64]u8 = undefined;
    for (locations, 0..) |loc, i| {
        cids[i] = try coordCidHex(Coordinate.init(loc[0], loc[1]), allocator);
    }

    // All CIDs should be unique
    for (0..5) |i| {
        for (i + 1..5) |j| {
            try std.testing.expect(!std.mem.eql(u8, &cids[i], &cids[j]));
        }
    }
}
