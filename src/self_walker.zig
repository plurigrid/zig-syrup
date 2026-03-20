//! Self-Walker: OLC × Syrup autopoietic spatial traversal
//!
//! A self-walker is an entity that moves through Open Location Code tiles,
//! serializes its own state via Syrup, and carries its trajectory as part
//! of its identity. Each step produces a new content-addressed state.
//!
//! The "self" in self-walker: the walker contains enough information to
//! reconstruct itself from bytes and continue walking. Its CID changes
//! with each step — the trajectory IS the identity.
//!
//! GF(3) trit coloring assigns each tile a charge (-1, 0, +1) via the
//! OLC digit sum mod 3. The walker accumulates a trit trace that must
//! balance over time (conservation law).
//!
//! Integration:
//!   - open-location-code-zig (bmorphism): spatial encoding
//!   - zig-syrup (plurigrid): serialization + CID
//!   - Gay.jl bridge: MAC seed → color_at(0; seed=mac_seed) for Julia interop
//!
//! Julia bridge (Gay.jl):
//!   ```julia
//!   using Gay: color_at, splitmix64
//!   mac_seed = UInt64(0xbc5c177a0804)  # MAC → 48-bit seed
//!   primary = color_at(0; seed=mac_seed)  # deterministic RGB
//!   trit = Int(mod(mac_seed, 3)) - 1     # GF(3): -1/0/+1
//!   ```
//!
//! Wire format (Syrup record):
//!   <'self:walker <code> <lat> <lng> <trit> <step> [trail...] <seed>>

const std = @import("std");
const syrup = @import("syrup");
const geo = @import("geo");
const Allocator = std.mem.Allocator;
const Value = syrup.Value;

// ============================================================================
// CONSTANTS
// ============================================================================

const CODE_ALPHABET = "23456789CFGHJMPQRVWX";

/// Cardinal + diagonal directions for tile adjacency
pub const Direction = enum(u4) {
    north = 0,
    northeast = 1,
    east = 2,
    southeast = 3,
    south = 4,
    southwest = 5,
    west = 6,
    northwest = 7,

    /// Lat/lng delta for this direction at a given resolution
    pub fn delta(self: Direction, lat_res: f64, lng_res: f64) [2]f64 {
        return switch (self) {
            .north => .{ lat_res, 0 },
            .northeast => .{ lat_res, lng_res },
            .east => .{ 0, lng_res },
            .southeast => .{ -lat_res, lng_res },
            .south => .{ -lat_res, 0 },
            .southwest => .{ -lat_res, -lng_res },
            .west => .{ 0, -lng_res },
            .northwest => .{ lat_res, -lng_res },
        };
    }

    /// Opposite direction
    pub fn reverse(self: Direction) Direction {
        return @enumFromInt((@intFromEnum(self) + 4) % 8);
    }

    pub fn toSymbol(self: Direction) []const u8 {
        return switch (self) {
            .north => "N",
            .northeast => "NE",
            .east => "E",
            .southeast => "SE",
            .south => "S",
            .southwest => "SW",
            .west => "W",
            .northwest => "NW",
        };
    }
};

// ============================================================================
// GF(3) TRIT FROM OLC CODE
// ============================================================================

/// Compute the GF(3) trit for an OLC code.
/// trit = (sum of character values in CODE_ALPHABET) mod 3, mapped to {-1, 0, +1}
pub fn codeTrit(code: []const u8) i8 {
    var sum: u32 = 0;
    for (code) |c| {
        if (c == '+' or c == '0') continue;
        sum += charVal(c);
    }
    const m: i32 = @intCast(@mod(sum, 3));
    return @intCast(m - 1);
}

fn charVal(c: u8) u32 {
    for (CODE_ALPHABET, 0..) |a, i| {
        if (c == a or c == std.ascii.toLower(a)) return @intCast(i);
    }
    return 0;
}

/// Resolution (in degrees) for a given OLC code length
fn olcResolution(code_length: u8) [2]f64 {
    if (code_length <= 10) {
        const pairs = @as(u8, code_length) / 2;
        const base: f64 = 20.0;
        const lat = std.math.pow(f64, base, @as(f64, @floatFromInt(1 - @as(i8, @intCast(pairs - 1)))));
        const lng = lat;
        return .{ lat, lng };
    }
    // Grid refinement: each extra digit divides by 5 (lat) and 4 (lng)
    const grid_digits = code_length - 10;
    const pair_res = olcResolution(10);
    const lat = pair_res[0] / std.math.pow(f64, 5.0, @as(f64, @floatFromInt(grid_digits)));
    const lng = pair_res[1] / std.math.pow(f64, 4.0, @as(f64, @floatFromInt(grid_digits)));
    return .{ lat, lng };
}

// ============================================================================
// TRAIL ENTRY
// ============================================================================

/// A single step in the walker's trajectory
pub const TrailEntry = struct {
    code: [16]u8,
    code_len: u8,
    trit: i8,
    direction: ?Direction,

    pub fn codeSlice(self: *const TrailEntry) []const u8 {
        return self.code[0..self.code_len];
    }

    pub fn toSyrup(self: *const TrailEntry, allocator: Allocator) !Value {
        const label_alloc = try allocator.alloc(Value, 1);
        label_alloc[0] = Value.fromSymbol("self:step");

        const fields = try allocator.alloc(Value, 3);

        const code_copy = try allocator.alloc(u8, self.code_len);
        @memcpy(code_copy, self.code[0..self.code_len]);
        fields[0] = Value.fromString(code_copy);
        fields[1] = Value.fromInteger(@intCast(self.trit));
        fields[2] = if (self.direction) |d|
            Value.fromSymbol(d.toSymbol())
        else
            Value.fromNull();

        return Value.fromRecord(&label_alloc[0], fields);
    }
};

// ============================================================================
// SELF-WALKER
// ============================================================================

pub const SelfWalker = struct {
    /// Current OLC code (Plus Code)
    current_code: [16]u8 = undefined,
    current_code_len: u8 = 0,

    /// Current center coordinate
    latitude: f64 = 0,
    longitude: f64 = 0,

    /// GF(3) trit at current tile
    trit: i8 = 0,

    /// OLC precision (code_length parameter, 2-15)
    precision: u8 = 10,

    /// Step counter
    step_count: u64 = 0,

    /// Accumulated trit sum (for conservation tracking)
    trit_sum: i64 = 0,

    /// Trail of visited tiles (ring buffer of last N)
    trail: std.ArrayListUnmanaged(TrailEntry),

    /// Maximum trail length (0 = unlimited)
    max_trail: usize = 256,

    /// Seed for deterministic behavior
    seed: u64 = 0,

    allocator: Allocator,

    const Self = @This();

    /// Initialize a self-walker at a geographic position
    pub fn init(allocator: Allocator, lat: f64, lng: f64, precision: u8, seed: u64) !Self {
        var walker = Self{
            .allocator = allocator,
            .trail = .{},
            .precision = if (precision < 2) 10 else precision,
            .seed = seed,
        };

        // Encode initial position
        const len = try geo.encodeOlc(lat, lng, walker.precision, &walker.current_code);
        walker.current_code_len = @intCast(len);

        // Decode back to get exact tile center
        const area = try geo.decodeOlc(walker.current_code[0..len]);
        walker.latitude = area.centerLatitude();
        walker.longitude = area.centerLongitude();

        // Compute trit
        walker.trit = codeTrit(walker.current_code[0..len]);
        walker.trit_sum = @intCast(walker.trit);

        // Record initial position in trail
        var entry = TrailEntry{
            .code = undefined,
            .code_len = @intCast(len),
            .trit = walker.trit,
            .direction = null,
        };
        @memcpy(entry.code[0..len], walker.current_code[0..len]);
        try walker.trail.append(allocator, entry);

        return walker;
    }

    /// Initialize from Syrup bytes (self-reconstruction)
    pub fn fromBytes(allocator: Allocator, bytes: []const u8) !Self {
        const val = try syrup.decode(bytes, allocator);
        return fromSyrup(allocator, val);
    }

    /// Reconstruct walker from a Syrup value
    pub fn fromSyrup(allocator: Allocator, val: Value) !Self {
        if (val != .record) return error.InvalidCode;
        const rec = val.record;

        const label_str = switch (rec.label.*) {
            .symbol => |s| s,
            .string => |s| s,
            else => return error.InvalidCode,
        };
        if (!std.mem.eql(u8, label_str, "self:walker")) return error.InvalidCode;
        if (rec.fields.len < 7) return error.InvalidLength;

        // fields: code, lat, lng, trit, step, trail_list, seed
        const code_str = switch (rec.fields[0]) {
            .string => |s| s,
            else => return error.InvalidCode,
        };
        const lat = switch (rec.fields[1]) {
            .float => |f| f,
            .float32 => |f| @as(f64, @floatCast(f)),
            else => return error.InvalidLatitude,
        };
        const lng = switch (rec.fields[2]) {
            .float => |f| f,
            .float32 => |f| @as(f64, @floatCast(f)),
            else => return error.InvalidLongitude,
        };
        const trit_val: i8 = switch (rec.fields[3]) {
            .integer => |i| @intCast(i),
            else => return error.InvalidCode,
        };
        const step_val: u64 = switch (rec.fields[4]) {
            .integer => |i| @intCast(i),
            else => return error.InvalidCode,
        };
        const seed_val: u64 = switch (rec.fields[6]) {
            .integer => |i| @intCast(i),
            else => return error.InvalidCode,
        };

        var walker = Self{
            .allocator = allocator,
            .trail = .{},
            .latitude = lat,
            .longitude = lng,
            .trit = trit_val,
            .step_count = step_val,
            .seed = seed_val,
        };

        // Copy code
        if (code_str.len > 16) return error.InvalidLength;
        walker.current_code_len = @intCast(code_str.len);
        @memcpy(walker.current_code[0..code_str.len], code_str);

        // Rebuild trit_sum from trail
        if (rec.fields[5] == .list) {
            for (rec.fields[5].list) |item| {
                if (item != .record) continue;
                const srec = item.record;
                if (srec.fields.len < 2) continue;
                const entry_trit: i8 = switch (srec.fields[1]) {
                    .integer => |i| @intCast(i),
                    else => continue,
                };
                walker.trit_sum += @intCast(entry_trit);

                var entry = TrailEntry{
                    .code = undefined,
                    .code_len = 0,
                    .trit = entry_trit,
                    .direction = null,
                };
                if (srec.fields[0] == .string) {
                    const s = srec.fields[0].string;
                    if (s.len <= 16) {
                        entry.code_len = @intCast(s.len);
                        @memcpy(entry.code[0..s.len], s);
                    }
                }
                try walker.trail.append(allocator, entry);
            }
        }

        return walker;
    }

    pub fn deinit(self: *Self) void {
        self.trail.deinit(self.allocator);
    }

    // ---- Movement ----

    /// Step in a cardinal/diagonal direction
    pub fn step(self: *Self, dir: Direction) !void {
        const res = olcResolution(self.precision);
        const d = dir.delta(res[0], res[1]);

        const new_lat = std.math.clamp(self.latitude + d[0], -90.0, 90.0);
        var new_lng = self.longitude + d[1];
        // Wrap longitude
        if (new_lng > 180.0) new_lng -= 360.0;
        if (new_lng <= -180.0) new_lng += 360.0;

        // Encode new position
        const len = try geo.encodeOlc(new_lat, new_lng, self.precision, &self.current_code);
        self.current_code_len = @intCast(len);

        // Decode for exact center
        const area = try geo.decodeOlc(self.current_code[0..len]);
        self.latitude = area.centerLatitude();
        self.longitude = area.centerLongitude();

        // Update trit
        self.trit = codeTrit(self.current_code[0..len]);
        self.trit_sum += @intCast(self.trit);
        self.step_count += 1;

        // Record in trail
        var entry = TrailEntry{
            .code = undefined,
            .code_len = @intCast(len),
            .trit = self.trit,
            .direction = dir,
        };
        @memcpy(entry.code[0..len], self.current_code[0..len]);

        if (self.max_trail > 0 and self.trail.items.len >= self.max_trail) {
            // Ring: drop oldest
            _ = self.trail.orderedRemove(0);
        }
        try self.trail.append(self.allocator, entry);
    }

    /// Step to an absolute coordinate
    pub fn stepTo(self: *Self, lat: f64, lng: f64) !void {
        const len = try geo.encodeOlc(lat, lng, self.precision, &self.current_code);
        self.current_code_len = @intCast(len);

        const area = try geo.decodeOlc(self.current_code[0..len]);
        self.latitude = area.centerLatitude();
        self.longitude = area.centerLongitude();

        self.trit = codeTrit(self.current_code[0..len]);
        self.trit_sum += @intCast(self.trit);
        self.step_count += 1;

        var entry = TrailEntry{
            .code = undefined,
            .code_len = @intCast(len),
            .trit = self.trit,
            .direction = null,
        };
        @memcpy(entry.code[0..len], self.current_code[0..len]);

        if (self.max_trail > 0 and self.trail.items.len >= self.max_trail) {
            _ = self.trail.orderedRemove(0);
        }
        try self.trail.append(self.allocator, entry);
    }

    /// Deterministic walk: use seed + step_count to pick direction
    pub fn autoStep(self: *Self) !void {
        // SplitMix64-derived direction selection
        var x = self.seed +% self.step_count *% 0x9e3779b97f4a7c15;
        x = (x ^ (x >> 30)) *% 0xbf58476d1ce4e5b9;
        x = (x ^ (x >> 27)) *% 0x94d049bb133111eb;
        x = x ^ (x >> 31);

        const dir: Direction = @enumFromInt(@as(u4, @truncate(x % 8)));
        try self.step(dir);
    }

    // ---- Queries ----

    /// Current OLC code as slice
    pub fn code(self: *const Self) []const u8 {
        return self.current_code[0..self.current_code_len];
    }

    /// Current position as geo.Coordinate
    pub fn coordinate(self: *const Self) geo.Coordinate {
        return geo.Coordinate.init(self.latitude, self.longitude);
    }

    /// Is the trit sum balanced (≡ 0 mod 3)?
    pub fn isBalanced(self: *const Self) bool {
        return @mod(self.trit_sum, 3) == 0;
    }

    /// Trit sum modulo 3, mapped to {-1, 0, +1}
    pub fn tritBalance(self: *const Self) i8 {
        const m: i64 = @mod(self.trit_sum, 3);
        return @intCast(m - 1);
    }

    /// Trail as slice
    pub fn trailSlice(self: *const Self) []const TrailEntry {
        return self.trail.items;
    }

    // ---- Serialization ----

    /// Serialize to Syrup Value
    /// <'self:walker <code> <lat> <lng> <trit> <step> [trail...] <seed>>
    pub fn toSyrup(self: *const Self, allocator: Allocator) !Value {
        const label_alloc = try allocator.alloc(Value, 1);
        label_alloc[0] = Value.fromSymbol("self:walker");

        const fields = try allocator.alloc(Value, 7);

        // field 0: current code
        const code_copy = try allocator.alloc(u8, self.current_code_len);
        @memcpy(code_copy, self.current_code[0..self.current_code_len]);
        fields[0] = Value.fromString(code_copy);

        // field 1-2: lat/lng
        fields[1] = Value.fromFloat(self.latitude);
        fields[2] = Value.fromFloat(self.longitude);

        // field 3: trit
        fields[3] = Value.fromInteger(@intCast(self.trit));

        // field 4: step count
        fields[4] = Value.fromInteger(@intCast(self.step_count));

        // field 5: trail (list of step records)
        const trail_items = try allocator.alloc(Value, self.trail.items.len);
        for (self.trail.items, 0..) |*entry, i| {
            trail_items[i] = try entry.toSyrup(allocator);
        }
        fields[5] = Value.fromList(trail_items);

        // field 6: seed
        fields[6] = Value.fromInteger(@intCast(self.seed));

        return Value.fromRecord(&label_alloc[0], fields);
    }

    /// Serialize to Syrup wire bytes
    pub fn toBytes(self: *const Self, allocator: Allocator) ![]u8 {
        const val = try self.toSyrup(allocator);
        return val.encodeAlloc(allocator);
    }

    /// Compute SHA-256 CID of the walker's current state
    pub fn cid(self: *const Self, allocator: Allocator) ![32]u8 {
        const bytes = try self.toBytes(allocator);
        defer allocator.free(bytes);
        var hash: [32]u8 = undefined;
        std.crypto.hash.Blake3.hash(bytes, &hash, .{});
        return hash;
    }

    /// CID as hex string
    pub fn cidHex(self: *const Self, allocator: Allocator) ![64]u8 {
        const hash = try self.cid(allocator);
        return std.fmt.bytesToHex(hash, .lower);
    }

    /// Serialize to JSON-compatible Syrup dict (for JSON-RPC bridge)
    pub fn toJsonDict(self: *const Self, allocator: Allocator) !Value {
        const entry_count: usize = 8;
        const entries = try allocator.alloc(Value.DictEntry, entry_count);

        const code_copy = try allocator.alloc(u8, self.current_code_len);
        @memcpy(code_copy, self.current_code[0..self.current_code_len]);

        entries[0] = .{ .key = syrup.symbol("code"), .value = Value.fromString(code_copy) };
        entries[1] = .{ .key = syrup.symbol("latitude"), .value = Value.fromFloat(self.latitude) };
        entries[2] = .{ .key = syrup.symbol("longitude"), .value = Value.fromFloat(self.longitude) };
        entries[3] = .{ .key = syrup.symbol("precision"), .value = Value.fromInteger(@intCast(self.precision)) };
        entries[4] = .{ .key = syrup.symbol("seed"), .value = Value.fromInteger(@intCast(self.seed)) };
        entries[5] = .{ .key = syrup.symbol("step"), .value = Value.fromInteger(@intCast(self.step_count)) };
        entries[6] = .{ .key = syrup.symbol("trit"), .value = Value.fromInteger(@intCast(self.trit)) };
        entries[7] = .{ .key = syrup.symbol("tritSum"), .value = Value.fromInteger(self.trit_sum) };

        return syrup.dictionary(entries);
    }
};

// ============================================================================
// DEVICE RECORD: MAC × IP × OLC × GF(3) × Gay Color
// ============================================================================

pub const DeviceStatus = enum(u2) {
    unknown = 0,
    reachable = 1,
    no_route = 2,
    filtered = 3,

    pub fn toSymbol(self: DeviceStatus) []const u8 {
        return @tagName(self);
    }
};

/// A device discovered during spatial exploration, colored by its MAC seed.
/// Wire format: <'self:device <mac> <ip> <seed> <color> <trit> <manufacturer> <olc> <status>>
pub const DeviceRecord = struct {
    /// MAC address as 6 raw bytes
    mac: [6]u8,
    /// IPv4 as 4 bytes
    ip: [4]u8,
    /// SplitMix64 seed derived from MAC (48-bit → u64)
    seed: u64,
    /// Gay-derived primary color (RGB)
    color: [3]u8,
    /// GF(3) trit from seed mod 3
    trit: i8,
    /// OUI manufacturer name
    manufacturer: []const u8,
    /// OLC code at device location (if geolocated)
    olc_code: [16]u8,
    olc_code_len: u8,
    /// Network reachability status
    status: DeviceStatus,

    /// Create from MAC bytes (derives seed, trit, color)
    pub fn fromMac(mac: [6]u8, ip: [4]u8, manufacturer: []const u8) DeviceRecord {
        // MAC → 48-bit seed
        var seed: u64 = 0;
        for (mac) |b| {
            seed = (seed << 8) | @as(u64, b);
        }

        // SplitMix64 one round for color
        var x = seed;
        x = (x ^ (x >> 30)) *% 0xbf58476d1ce4e5b9;
        x = (x ^ (x >> 27)) *% 0x94d049bb133111eb;
        x = x ^ (x >> 31);

        const color = [3]u8{
            @truncate(x >> 16),
            @truncate(x >> 8),
            @truncate(x),
        };

        // GF(3) trit from seed
        const trit: i8 = @intCast(@as(i32, @intCast(@mod(seed, 3))) - 1);

        return .{
            .mac = mac,
            .ip = ip,
            .seed = seed,
            .color = color,
            .trit = trit,
            .manufacturer = manufacturer,
            .olc_code = undefined,
            .olc_code_len = 0,
            .status = .unknown,
        };
    }

    /// Set device location via OLC encoding
    pub fn setLocation(self: *DeviceRecord, lat: f64, lng: f64, precision: u8) !void {
        const len = try geo.encodeOlc(lat, lng, precision, &self.olc_code);
        self.olc_code_len = @intCast(len);
    }

    /// OLC code as slice
    pub fn olcSlice(self: *const DeviceRecord) []const u8 {
        return self.olc_code[0..self.olc_code_len];
    }

    /// MAC as hex string "bc:5c:17:7a:08:04"
    pub fn macHex(self: *const DeviceRecord) [17]u8 {
        const hex_chars = "0123456789abcdef";
        var buf: [17]u8 = undefined;
        for (self.mac, 0..) |b, i| {
            buf[i * 3] = hex_chars[b >> 4];
            buf[i * 3 + 1] = hex_chars[b & 0x0f];
            if (i < 5) buf[i * 3 + 2] = ':';
        }
        return buf;
    }

    /// Color as hex "#RRGGBB"
    pub fn colorHex(self: *const DeviceRecord) [7]u8 {
        const hex_chars = "0123456789abcdef";
        var buf: [7]u8 = undefined;
        buf[0] = '#';
        inline for (0..3) |i| {
            buf[1 + i * 2] = hex_chars[self.color[i] >> 4];
            buf[2 + i * 2] = hex_chars[self.color[i] & 0x0f];
        }
        return buf;
    }

    /// IP as dotted string
    pub fn ipStr(self: *const DeviceRecord) [15]u8 {
        var buf: [15]u8 = .{' '} ** 15;
        var pos: usize = 0;
        for (self.ip, 0..) |b, i| {
            if (b >= 100) {
                buf[pos] = '0' + b / 100;
                pos += 1;
            }
            if (b >= 10) {
                buf[pos] = '0' + (b / 10) % 10;
                pos += 1;
            }
            buf[pos] = '0' + b % 10;
            pos += 1;
            if (i < 3) {
                buf[pos] = '.';
                pos += 1;
            }
        }
        return buf;
    }

    /// Serialize to Syrup record
    pub fn toSyrup(self: *const DeviceRecord, allocator: Allocator) !Value {
        const label_alloc = try allocator.alloc(Value, 1);
        label_alloc[0] = Value.fromSymbol("self:device");

        const fields = try allocator.alloc(Value, 8);

        // field 0: MAC as bytes
        const mac_copy = try allocator.alloc(u8, 6);
        @memcpy(mac_copy, &self.mac);
        fields[0] = Value.fromBytes(mac_copy);

        // field 1: IP as bytes
        const ip_copy = try allocator.alloc(u8, 4);
        @memcpy(ip_copy, &self.ip);
        fields[1] = Value.fromBytes(ip_copy);

        // field 2: seed
        fields[2] = Value.fromInteger(@intCast(self.seed));

        // field 3: color as bytes
        const color_copy = try allocator.alloc(u8, 3);
        @memcpy(color_copy, &self.color);
        fields[3] = Value.fromBytes(color_copy);

        // field 4: trit
        fields[4] = Value.fromInteger(@intCast(self.trit));

        // field 5: manufacturer
        const mfg_copy = try allocator.alloc(u8, self.manufacturer.len);
        @memcpy(mfg_copy, self.manufacturer);
        fields[5] = Value.fromString(mfg_copy);

        // field 6: OLC code
        if (self.olc_code_len > 0) {
            const olc_copy = try allocator.alloc(u8, self.olc_code_len);
            @memcpy(olc_copy, self.olc_code[0..self.olc_code_len]);
            fields[6] = Value.fromString(olc_copy);
        } else {
            fields[6] = Value.fromNull();
        }

        // field 7: status
        fields[7] = Value.fromSymbol(self.status.toSymbol());

        return Value.fromRecord(&label_alloc[0], fields);
    }

    /// Serialize to wire bytes
    pub fn toBytes(self: *const DeviceRecord, allocator: Allocator) ![]u8 {
        const val = try self.toSyrup(allocator);
        return val.encodeAlloc(allocator);
    }

    /// Content-addressed identity
    pub fn cid(self: *const DeviceRecord, allocator: Allocator) ![32]u8 {
        const bytes = try self.toBytes(allocator);
        defer allocator.free(bytes);
        var hash: [32]u8 = undefined;
        std.crypto.hash.Blake3.hash(bytes, &hash, .{});
        return hash;
    }

    /// Spawn a SelfWalker seeded from this device
    pub fn spawnWalker(self: *const DeviceRecord, allocator: Allocator, lat: f64, lng: f64, precision: u8) !SelfWalker {
        return SelfWalker.init(allocator, lat, lng, precision, self.seed);
    }
};

// ============================================================================
// TESTS
// ============================================================================

test "self-walker: init at San Francisco" {
    const allocator = std.testing.allocator;
    var walker = try SelfWalker.init(allocator, 37.7749, -122.4194, 10, 42);
    defer walker.deinit();

    try std.testing.expect(walker.current_code_len > 0);
    try std.testing.expect(geo.isFullCode(walker.code()));
    try std.testing.expect(walker.latitude > 37.0 and walker.latitude < 38.0);
    try std.testing.expect(walker.longitude > -123.0 and walker.longitude < -122.0);
    try std.testing.expectEqual(@as(u64, 0), walker.step_count);
    try std.testing.expectEqual(@as(usize, 1), walker.trail.items.len);
}

test "self-walker: step north changes position" {
    const allocator = std.testing.allocator;
    var walker = try SelfWalker.init(allocator, 37.7749, -122.4194, 10, 0);
    defer walker.deinit();

    const old_lat = walker.latitude;
    try walker.step(.north);

    try std.testing.expect(walker.latitude > old_lat);
    try std.testing.expectEqual(@as(u64, 1), walker.step_count);
    try std.testing.expectEqual(@as(usize, 2), walker.trail.items.len);
}

test "self-walker: step south changes position" {
    const allocator = std.testing.allocator;
    var walker = try SelfWalker.init(allocator, 37.7749, -122.4194, 10, 0);
    defer walker.deinit();

    const old_lat = walker.latitude;
    try walker.step(.south);

    try std.testing.expect(walker.latitude < old_lat);
}

test "self-walker: step east changes position" {
    const allocator = std.testing.allocator;
    var walker = try SelfWalker.init(allocator, 37.7749, -122.4194, 10, 0);
    defer walker.deinit();

    const old_lng = walker.longitude;
    try walker.step(.east);

    try std.testing.expect(walker.longitude > old_lng);
}

test "self-walker: step west changes position" {
    const allocator = std.testing.allocator;
    var walker = try SelfWalker.init(allocator, 37.7749, -122.4194, 10, 0);
    defer walker.deinit();

    const old_lng = walker.longitude;
    try walker.step(.west);

    try std.testing.expect(walker.longitude < old_lng);
}

test "self-walker: trit is in valid range" {
    const allocator = std.testing.allocator;
    var walker = try SelfWalker.init(allocator, 37.7749, -122.4194, 10, 0);
    defer walker.deinit();

    try std.testing.expect(walker.trit >= -1 and walker.trit <= 1);

    // Walk several steps, all trits should be valid
    var i: usize = 0;
    while (i < 20) : (i += 1) {
        try walker.autoStep();
        try std.testing.expect(walker.trit >= -1 and walker.trit <= 1);
    }
}

test "self-walker: autoStep is deterministic" {
    const allocator = std.testing.allocator;
    var w1 = try SelfWalker.init(allocator, 48.2920, 25.9358, 10, 1738);
    defer w1.deinit();
    var w2 = try SelfWalker.init(allocator, 48.2920, 25.9358, 10, 1738);
    defer w2.deinit();

    var i: usize = 0;
    while (i < 10) : (i += 1) {
        try w1.autoStep();
        try w2.autoStep();
    }

    try std.testing.expectEqualStrings(w1.code(), w2.code());
    try std.testing.expectEqual(w1.trit_sum, w2.trit_sum);
    try std.testing.expectEqual(w1.step_count, w2.step_count);
}

test "self-walker: syrup serialization roundtrip" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var walker = try SelfWalker.init(allocator, 48.2920, 25.9358, 10, 42);
    try walker.step(.north);
    try walker.step(.east);
    try walker.step(.south);

    // Serialize
    const bytes = try walker.toBytes(allocator);
    try std.testing.expect(bytes.len > 0);
    try std.testing.expect(bytes[0] == '<'); // Record

    // Reconstruct
    var reconstructed = try SelfWalker.fromBytes(allocator, bytes);
    defer reconstructed.deinit();

    try std.testing.expectEqualStrings(walker.code(), reconstructed.code());
    try std.testing.expectApproxEqAbs(walker.latitude, reconstructed.latitude, 0.0001);
    try std.testing.expectApproxEqAbs(walker.longitude, reconstructed.longitude, 0.0001);
    try std.testing.expectEqual(walker.trit, reconstructed.trit);
    try std.testing.expectEqual(walker.step_count, reconstructed.step_count);
    try std.testing.expectEqual(walker.seed, reconstructed.seed);
}

test "self-walker: CID changes with each step" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var walker = try SelfWalker.init(allocator, 37.7749, -122.4194, 10, 0);

    const cid0 = try walker.cidHex(allocator);
    try walker.step(.north);
    const cid1 = try walker.cidHex(allocator);
    try walker.step(.east);
    const cid2 = try walker.cidHex(allocator);

    // All CIDs should be distinct
    try std.testing.expect(!std.mem.eql(u8, &cid0, &cid1));
    try std.testing.expect(!std.mem.eql(u8, &cid1, &cid2));
    try std.testing.expect(!std.mem.eql(u8, &cid0, &cid2));
}

test "self-walker: CID is deterministic" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var w1 = try SelfWalker.init(allocator, 37.7749, -122.4194, 10, 99);
    try w1.step(.north);

    var w2 = try SelfWalker.init(allocator, 37.7749, -122.4194, 10, 99);
    try w2.step(.north);

    const c1 = try w1.cidHex(allocator);
    const c2 = try w2.cidHex(allocator);
    try std.testing.expectEqualStrings(&c1, &c2);
}

test "self-walker: stepTo absolute coordinate" {
    const allocator = std.testing.allocator;
    var walker = try SelfWalker.init(allocator, 37.7749, -122.4194, 10, 0);
    defer walker.deinit();

    try walker.stepTo(51.5074, -0.1278); // London
    try std.testing.expect(walker.latitude > 51.0 and walker.latitude < 52.0);
    try std.testing.expect(walker.longitude > -1.0 and walker.longitude < 0.0);
    try std.testing.expectEqual(@as(u64, 1), walker.step_count);
}

test "self-walker: trail ring buffer limits" {
    const allocator = std.testing.allocator;
    var walker = try SelfWalker.init(allocator, 0.0, 0.0, 10, 0);
    defer walker.deinit();
    walker.max_trail = 5;

    // Walk 10 steps
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        try walker.step(.east);
    }

    // Trail should be capped at max_trail
    try std.testing.expect(walker.trail.items.len <= 5);
    try std.testing.expectEqual(@as(u64, 10), walker.step_count);
}

test "self-walker: codeTrit computes valid trits" {
    // Known Plus Codes from the skill doc
    try std.testing.expect(codeTrit("849VQHFJ+X6") >= -1);
    try std.testing.expect(codeTrit("849VQHFJ+X6") <= 1);
    try std.testing.expect(codeTrit("6FG22222+22") >= -1);
    try std.testing.expect(codeTrit("6FG22222+22") <= 1);
}

test "self-walker: direction reverse" {
    try std.testing.expectEqual(Direction.south, Direction.north.reverse());
    try std.testing.expectEqual(Direction.north, Direction.south.reverse());
    try std.testing.expectEqual(Direction.west, Direction.east.reverse());
    try std.testing.expectEqual(Direction.east, Direction.west.reverse());
    try std.testing.expectEqual(Direction.southwest, Direction.northeast.reverse());
}

test "self-walker: Czernowitz walk" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Start at Czernowitz central square
    var walker = try SelfWalker.init(allocator, 48.2920, 25.9358, 10, 1738);

    // Walk south toward Kalinka market
    var i: usize = 0;
    while (i < 5) : (i += 1) {
        try walker.step(.south);
    }

    // Should still be near Czernowitz
    try std.testing.expect(walker.latitude > 48.0 and walker.latitude < 49.0);
    try std.testing.expect(walker.longitude > 25.0 and walker.longitude < 27.0);

    // Should have a trail
    try std.testing.expectEqual(@as(usize, 6), walker.trail.items.len);

    // Serialize and verify CID
    const hex = try walker.cidHex(allocator);
    try std.testing.expectEqual(@as(usize, 64), hex.len);
}

test "self-walker: toJsonDict" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var walker = try SelfWalker.init(allocator, 37.7749, -122.4194, 10, 42);

    const dict = try walker.toJsonDict(allocator);
    try std.testing.expect(dict == .dictionary);
    try std.testing.expectEqual(@as(usize, 8), dict.dictionary.len);

    // Check keys exist
    var has_code = false;
    var has_trit = false;
    var has_step = false;
    for (dict.dictionary) |entry| {
        const key = entry.key.symbol;
        if (std.mem.eql(u8, key, "code")) has_code = true;
        if (std.mem.eql(u8, key, "trit")) has_trit = true;
        if (std.mem.eql(u8, key, "step")) has_step = true;
    }
    try std.testing.expect(has_code);
    try std.testing.expect(has_trit);
    try std.testing.expect(has_step);
}

// ============================================================================
// DEVICE RECORD TESTS
// ============================================================================

test "device-record: fromMac bc:5c:17:7a:08:04" {
    const mac = [6]u8{ 0xbc, 0x5c, 0x17, 0x7a, 0x08, 0x04 };
    const ip = [4]u8{ 10, 0, 0, 61 };
    var dev = DeviceRecord.fromMac(mac, ip, "Shenzhen iComm Semiconductor");

    // Seed = 0xbc5c177a0804 = 207103716886532
    try std.testing.expectEqual(@as(u64, 207103716886532), dev.seed);

    // Trit: 207640076498948 mod 3 = 2, trit = 2 - 1 = +1
    try std.testing.expectEqual(@as(i8, 1), dev.trit);

    // Color: 3 bytes from SplitMix64(seed)
    try std.testing.expectEqual(@as(usize, 3), dev.color.len);

    // MAC hex
    const mac_str = dev.macHex();
    try std.testing.expectEqualStrings("bc:5c:17:7a:08:04", &mac_str);

    // Color hex should be 7 chars starting with #
    const color_str = dev.colorHex();
    try std.testing.expectEqual(@as(u8, '#'), color_str[0]);

    // Set location
    try dev.setLocation(37.7749, -122.4194, 10);
    try std.testing.expect(dev.olc_code_len > 0);
    try std.testing.expect(geo.isFullCode(dev.olcSlice()));
}

test "device-record: syrup serialization" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const mac = [6]u8{ 0xbc, 0x5c, 0x17, 0x7a, 0x08, 0x04 };
    const ip = [4]u8{ 10, 0, 0, 61 };
    var dev = DeviceRecord.fromMac(mac, ip, "Shenzhen iComm Semiconductor");
    dev.status = .reachable;
    try dev.setLocation(37.7749, -122.4194, 10);

    const bytes = try dev.toBytes(allocator);
    try std.testing.expect(bytes.len > 0);
    try std.testing.expect(bytes[0] == '<'); // Record marker
}

test "device-record: CID is deterministic" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const mac = [6]u8{ 0xbc, 0x5c, 0x17, 0x7a, 0x08, 0x04 };
    const ip = [4]u8{ 10, 0, 0, 61 };
    var d1 = DeviceRecord.fromMac(mac, ip, "Shenzhen iComm Semiconductor");
    var d2 = DeviceRecord.fromMac(mac, ip, "Shenzhen iComm Semiconductor");

    const c1 = try d1.cid(allocator);
    const c2 = try d2.cid(allocator);
    try std.testing.expectEqualSlices(u8, &c1, &c2);
}

test "device-record: spawnWalker uses device seed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const mac = [6]u8{ 0xbc, 0x5c, 0x17, 0x7a, 0x08, 0x04 };
    const ip = [4]u8{ 10, 0, 0, 61 };
    const dev = DeviceRecord.fromMac(mac, ip, "Shenzhen iComm Semiconductor");

    var walker = try dev.spawnWalker(allocator, 37.7749, -122.4194, 10);
    defer walker.deinit();

    try std.testing.expectEqual(dev.seed, walker.seed);
    try std.testing.expect(walker.current_code_len > 0);

    // Walk deterministically
    try walker.autoStep();
    try walker.autoStep();
    try walker.autoStep();
    try std.testing.expectEqual(@as(u64, 3), walker.step_count);
}

test "device-record: IP string formatting" {
    const mac = [6]u8{ 0xbc, 0x5c, 0x17, 0x7a, 0x08, 0x04 };
    const ip = [4]u8{ 10, 0, 0, 61 };
    const dev = DeviceRecord.fromMac(mac, ip, "Shenzhen iComm Semiconductor");

    const ip_str = dev.ipStr();
    // Should start with "10.0.0.61"
    try std.testing.expect(ip_str[0] == '1');
    try std.testing.expect(ip_str[1] == '0');
    try std.testing.expect(ip_str[2] == '.');
}
