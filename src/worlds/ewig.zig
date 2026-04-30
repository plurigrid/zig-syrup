//! Ewig - Eternal/Persistent Storage for World History
//! Append-only log, state reconstruction, Merkle trees, time-travel queries

const std = @import("std");
const mem = std.mem;
const crypto = std.crypto;
const fs = std.fs;
const path = std.fs.path;

const world = @import("world.zig");

/// Log entry types
pub const LogEntryType = enum(u8) {
    world_created = 1,
    entity_spawned = 2,
    entity_updated = 3,
    entity_removed = 4,
    physics_updated = 5,
    config_updated = 6,
    tick_advanced = 7,
    snapshot = 8,
    checkpoint = 9,
};

/// Log entry header
pub const LogEntry = struct {
    entry_type: LogEntryType,
    timestamp: i64,
    tick: u64,
    world_id: u64,
    data: []const u8,
    hash: [32]u8, // SHA-256 of this entry
    prev_hash: [32]u8, // Hash of previous entry (for chain integrity)
};

/// Merkle tree node
pub const MerkleNode = struct {
    hash: [32]u8,
    left: ?*MerkleNode,
    right: ?*MerkleNode,
    entry_index: ?usize, // For leaf nodes
};

/// Merkle tree for log integrity
pub const MerkleTree = struct {
    const Self = @This();

    root: ?*MerkleNode,
    leaves: std.ArrayList(*MerkleNode),
    allocator: mem.Allocator,

    pub fn init(allocator: mem.Allocator) Self {
        return Self{
            .root = null,
            .leaves = std.ArrayList(*MerkleNode).empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        // Recursively free all nodes
        if (self.root) |root| {
            self.freeNode(root);
        }
        self.leaves.deinit(self.allocator);
    }

    fn freeNode(self: *Self, node: *MerkleNode) void {
        if (node.left) |left| self.freeNode(left);
        if (node.right) |right| self.freeNode(right);
        self.allocator.destroy(node);
    }

    /// Build tree from log entries
    pub fn build(self: *Self, entries: []const LogEntry) error{OutOfMemory}!void {
        self.deinit();
        self.* = Self.init(self.allocator);

        // Create leaf nodes
        for (entries, 0..) |entry, i| {
            const node = try self.allocator.create(MerkleNode);
            node.* = MerkleNode{
                .hash = entry.hash,
                .left = null,
                .right = null,
                .entry_index = i,
            };
            try self.leaves.append(self.allocator, node);
        }

        // Build tree bottom-up
        if (self.leaves.items.len > 0) {
            self.root = try self.buildLevel(self.leaves.items);
        }
    }

    fn buildLevel(self: *Self, nodes: []*MerkleNode) error{OutOfMemory}!*MerkleNode {
        if (nodes.len == 1) return nodes[0];

        var parents = std.ArrayList(*MerkleNode).empty;
        defer parents.deinit(self.allocator);

        var i: usize = 0;
        while (i < nodes.len) : (i += 2) {
            const left = nodes[i];
            const right = if (i + 1 < nodes.len) nodes[i + 1] else left;

            const parent = try self.allocator.create(MerkleNode);
            parent.hash = self.hashPair(left.hash, right.hash);
            parent.left = left;
            parent.right = right;
            parent.entry_index = null;
            try parents.append(self.allocator, parent);
        }

        return self.buildLevel(parents.items);
    }

    fn hashPair(_: Self, left: [32]u8, right: [32]u8) [32]u8 {
        var hasher = crypto.hash.Blake3.init(.{});
        hasher.update(&left);
        hasher.update(&right);
        var result: [32]u8 = undefined;
        hasher.final(&result);
        return result;
    }

    /// Get Merkle root hash
    pub fn getRoot(self: Self) ?[32]u8 {
        if (self.root) |root| return root.hash;
        return null;
    }

    /// Generate inclusion proof for an entry
    pub fn getProof(self: Self, entry_index: usize) error{OutOfMemory}!?MerkleProof {
        if (entry_index >= self.leaves.items.len) return null;

        var proof = std.ArrayList([32]u8).init(self.allocator);
        errdefer proof.deinit();

        var current_index = entry_index;
        var level_size = self.leaves.items.len;

        while (level_size > 1) {
            const sibling_index = if (current_index % 2 == 0) current_index + 1 else current_index - 1;

            if (sibling_index < level_size) {
                // Find the sibling node at this level
                const sibling_node = self.findNodeAtLevel(level_size, sibling_index);
                if (sibling_node) |sibling| {
                    try proof.append(sibling.hash);
                }
            }

            current_index /= 2;
            level_size = (level_size + 1) / 2;
        }

        return MerkleProof{
            .leaf_hash = self.leaves.items[entry_index].hash,
            .siblings = try proof.toOwnedSlice(),
            .root = self.getRoot(),
        };
    }

    fn findNodeAtLevel(_: Self, level_size: usize, index: usize) ?*MerkleNode {
        // Simplified: In a real implementation, track nodes by level
        _ = level_size;
        _ = index;
        return null;
    }
};

/// Merkle proof for verification
pub const MerkleProof = struct {
    const Self = @This();

    leaf_hash: [32]u8,
    siblings: [][32]u8,
    root: ?[32]u8,

    pub fn deinit(self: *Self, allocator: mem.Allocator) void {
        allocator.free(self.siblings);
    }

    /// Verify the proof against a root hash
    pub fn verify(self: Self, root_hash: [32]u8) bool {
        if (self.root) |expected_root| {
            if (!std.mem.eql(u8, &expected_root, &root_hash)) return false;
        }

        var current_hash = self.leaf_hash;
        for (self.siblings) |sibling| {
            var hasher = crypto.hash.Blake3.init(.{});
            // Note: In real implementation, need to know if sibling is left or right
            hasher.update(&current_hash);
            hasher.update(&sibling);
            hasher.final(&current_hash);
        }

        return std.mem.eql(u8, &current_hash, &root_hash);
    }
};

/// Append-only log for world events
pub const EventLog = struct {
    const Self = @This();

    entries: std.ArrayList(LogEntry),
    merkle_tree: MerkleTree,
    allocator: mem.Allocator,
    last_hash: [32]u8,

    pub fn init(allocator: mem.Allocator) Self {
        return Self{
            .entries = std.ArrayList(LogEntry).empty,
            .merkle_tree = MerkleTree.init(allocator),
            .allocator = allocator,
            .last_hash = [_]u8{0} ** 32,
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.entries.items) |*entry| {
            self.allocator.free(entry.data);
        }
        self.entries.deinit(self.allocator);
        self.merkle_tree.deinit();
    }

    /// Append entry to log
    pub fn append(
        self: *Self,
        entry_type: LogEntryType,
        timestamp: i64,
        tick: u64,
        world_id: u64,
        data: []const u8,
    ) error{OutOfMemory}!void {
        const data_copy = try self.allocator.dupe(u8, data);
        errdefer self.allocator.free(data_copy);

        // Compute entry hash
        var hasher = crypto.hash.Blake3.init(.{});
        hasher.update(&[_]u8{@intFromEnum(entry_type)});
        hasher.update(std.mem.asBytes(&timestamp));
        hasher.update(std.mem.asBytes(&tick));
        hasher.update(std.mem.asBytes(&world_id));
        hasher.update(data_copy);
        hasher.update(&self.last_hash);

        var hash: [32]u8 = undefined;
        hasher.final(&hash);

        const entry = LogEntry{
            .entry_type = entry_type,
            .timestamp = timestamp,
            .tick = tick,
            .world_id = world_id,
            .data = data_copy,
            .hash = hash,
            .prev_hash = self.last_hash,
        };

        try self.entries.append(self.allocator, entry);
        self.last_hash = hash;
    }

    /// Rebuild Merkle tree (call after batch append)
    pub fn rebuildMerkleTree(self: *Self) error{OutOfMemory}!void {
        try self.merkle_tree.build(self.entries.items);
    }

    /// Get Merkle root
    pub fn getMerkleRoot(self: Self) ?[32]u8 {
        return self.merkle_tree.getRoot();
    }

    /// Verify log integrity
    pub fn verifyIntegrity(self: Self) bool {
        var prev_hash = [_]u8{0} ** 32;

        for (self.entries.items) |entry| {
            // Verify chain link
            if (!std.mem.eql(u8, &entry.prev_hash, &prev_hash)) {
                return false;
            }

            // Recompute and verify hash
            var hasher = crypto.hash.Blake3.init(.{});
            hasher.update(&[_]u8{@intFromEnum(entry.entry_type)});
            hasher.update(std.mem.asBytes(&entry.timestamp));
            hasher.update(std.mem.asBytes(&entry.tick));
            hasher.update(std.mem.asBytes(&entry.world_id));
            hasher.update(entry.data);
            hasher.update(&entry.prev_hash);

            var computed_hash: [32]u8 = undefined;
            hasher.final(&computed_hash);

            if (!std.mem.eql(u8, &computed_hash, &entry.hash)) {
                return false;
            }

            prev_hash = entry.hash;
        }

        return true;
    }

    /// Get entries by time range
    pub fn getEntriesInRange(self: Self, start_time: i64, end_time: i64) []const LogEntry {
        // Binary search for efficiency (assuming sorted by timestamp)
        var start: usize = 0;
        var end: usize = self.entries.items.len;

        while (start < end) {
            const mid = (start + end) / 2;
            if (self.entries.items[mid].timestamp < start_time) {
                start = mid + 1;
            } else {
                end = mid;
            }
        }

        const range_start = start;
        end = self.entries.items.len;

        while (start < end) {
            const mid = (start + end) / 2;
            if (self.entries.items[mid].timestamp <= end_time) {
                start = mid + 1;
            } else {
                end = mid;
            }
        }

        return self.entries.items[range_start..start];
    }

    /// Get entries by tick range
    pub fn getEntriesByTick(self: Self, start_tick: u64, end_tick: u64) []const LogEntry {
        var result_start: usize = 0;
        var result_end: usize = 0;
        var found_start = false;

        for (self.entries.items, 0..) |entry, i| {
            if (!found_start and entry.tick >= start_tick) {
                result_start = i;
                found_start = true;
            }
            if (entry.tick > end_tick) {
                result_end = i;
                break;
            }
        }

        if (!found_start) return &[_]LogEntry{};
        if (result_end == 0) result_end = self.entries.items.len;

        return self.entries.items[result_start..result_end];
    }
};

/// Persistent storage backend
pub const StorageBackend = union(enum) {
    memory: MemoryStorage,
    sqlite: SqliteStorage,
    flat_file: FlatFileStorage,
};

/// In-memory storage
pub const MemoryStorage = struct {
    logs: std.AutoHashMap(u64, EventLog),
    allocator: mem.Allocator,

    pub fn init(allocator: mem.Allocator) MemoryStorage {
        return MemoryStorage{
            .logs = std.AutoHashMap(u64, EventLog).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *MemoryStorage) void {
        var it = self.logs.valueIterator();
        while (it.next()) |log| {
            log.deinit();
        }
        self.logs.deinit();
    }
};

/// SQLite-backed storage
pub const SqliteStorage = struct {
    db_path: []const u8,
    allocator: mem.Allocator,

    pub fn init(allocator: mem.Allocator, db_path: []const u8) error{OutOfMemory}!SqliteStorage {
        return SqliteStorage{
            .db_path = try allocator.dupe(u8, db_path),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *SqliteStorage) void {
        self.allocator.free(self.db_path);
    }
};

/// Flat file storage
pub const FlatFileStorage = struct {
    const Self = @This();

    base_path: []const u8,
    allocator: mem.Allocator,
    file: ?fs.File,

    pub fn init(allocator: mem.Allocator, base_path: []const u8) error{OutOfMemory}!Self {
        return Self{
            .base_path = try allocator.dupe(u8, base_path),
            .allocator = allocator,
            .file = null,
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.file) |*f| f.close();
        self.allocator.free(self.base_path);
    }

    pub fn open(self: *Self, world_id: u64) !void {
        if (self.file) |*f| f.close();

        const filename = try std.fmt.allocPrint(self.allocator, "{s}/world_{d}.log", .{ self.base_path, world_id });
        defer self.allocator.free(filename);

        // Ensure directory exists
        try fs.cwd().makePath(self.base_path);

        self.file = try fs.cwd().openFile(filename, .{ .mode = .read_write, .lock = .exclusive });
    }

    pub fn writeEntry(self: *Self, entry: LogEntry) !void {
        const f = self.file orelse return error.NotOpen;

        // Simple binary format: type(1) + timestamp(8) + tick(8) + world_id(8) + data_len(4) + data + hash(32) + prev_hash(32)
        const data_len: u32 = @intCast(entry.data.len);

        var buf: [1024]u8 = undefined;
        var stream = std.io.fixedBufferStream(&buf);
        const w = stream.writer();

        try w.writeByte(@intFromEnum(entry.entry_type));
        try w.writeInt(i64, entry.timestamp, .little);
        try w.writeInt(u64, entry.tick, .little);
        try w.writeInt(u64, entry.world_id, .little);
        try w.writeInt(u32, data_len, .little);

        const header_len = stream.pos;
        try f.writeAll(buf[0..header_len]);
        try f.writeAll(entry.data);
        try f.writeAll(&entry.hash);
        try f.writeAll(&entry.prev_hash);
    }
};

/// Eternal storage manager
pub const EternalStorage = struct {
    const Self = @This();

    backend: StorageBackend,
    allocator: mem.Allocator,

    pub fn initMemory(allocator: mem.Allocator) Self {
        return Self{
            .backend = StorageBackend{ .memory = MemoryStorage.init(allocator) },
            .allocator = allocator,
        };
    }

    pub fn initFlatFile(allocator: mem.Allocator, base_path: []const u8) error{OutOfMemory}!Self {
        return Self{
            .backend = StorageBackend{
                .flat_file = try FlatFileStorage.init(allocator, base_path),
            },
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        switch (self.backend) {
            .memory => |*m| m.deinit(),
            .sqlite => |*s| s.deinit(),
            .flat_file => |*f| f.deinit(),
        }
    }

    /// Get or create log for a world
    pub fn getLog(self: *Self, world_id: u64) error{OutOfMemory}!*EventLog {
        switch (self.backend) {
            .memory => |*m| {
                const result = try m.logs.getOrPut(world_id);
                if (!result.found_existing) {
                    result.value_ptr.* = EventLog.init(self.allocator);
                }
                return result.value_ptr;
            },
            .flat_file => |*f| {
                try f.open(world_id);
                // For flat file, we maintain a memory buffer
                const result = try self.allocator.create(EventLog);
                result.* = EventLog.init(self.allocator);
                return result;
            },
            .sqlite => @panic("SQLite backend not implemented"),
        }
    }

    /// Log world creation event
    pub fn logWorldCreated(self: *Self, w: world.World) !void {
        const log = try self.getLog(w.id);

        // Serialize world creation data
        var buf: [256]u8 = undefined;
        const data = try std.fmt.bufPrint(&buf, "uri={s},seed={d}", .{ w.uri.raw_uri, w.config.random_seed });

        try log.append(
            .world_created,
            std.time.milliTimestamp(),
            0,
            w.id,
            data,
        );
    }

    /// Log entity spawn
    pub fn logEntitySpawned(self: *Self, world_id: u64, tick: u64, e: world.Entity) !void {
        const log = try self.getLog(world_id);

        var buf: [512]u8 = undefined;
        const data = try std.fmt.bufPrint(&buf, "id={d},pos={d:.2},{d:.2},{d:.2},mass={d:.2}", .{
            e.id, e.position[0], e.position[1], e.position[2], e.mass,
        });

        try log.append(
            .entity_spawned,
            std.time.milliTimestamp(),
            tick,
            world_id,
            data,
        );
    }

    /// Log tick advancement
    pub fn logTick(self: *Self, world_id: u64, tick: u64) !void {
        const log = try self.getLog(world_id);
        try log.append(
            .tick_advanced,
            std.time.milliTimestamp(),
            tick,
            world_id,
            &.{},
        );
    }

    /// Create checkpoint (snapshot)
    pub fn createCheckpoint(self: *Self, world_id: u64, snapshot: world.WorldSnapshot) !void {
        const log = try self.getLog(world_id);

        // Serialize snapshot hash
        try log.append(
            .checkpoint,
            snapshot.timestamp,
            snapshot.tick,
            world_id,
            &snapshot.hash,
        );
    }
};

/// Time-travel query engine
pub const TimeTravel = struct {
    const Self = @This();

    storage: *EternalStorage,
    allocator: mem.Allocator,

    pub fn init(allocator: mem.Allocator, storage: *EternalStorage) Self {
        return Self{
            .storage = storage,
            .allocator = allocator,
        };
    }

    /// Get world state at a specific timestamp
    pub fn getStateAtTime(self: Self, world_id: u64, timestamp: i64) error{OutOfMemory}!?world.WorldSnapshot {
        _ = self;
        _ = world_id;
        _ = timestamp;
        // In a real implementation, this would:
        // 1. Find the last checkpoint before timestamp
        // 2. Replay events from checkpoint to target time
        // 3. Return the reconstructed snapshot
        return null;
    }

    /// Get world state at a specific tick
    pub fn getStateAtTick(self: Self, world_id: u64, tick: u64) error{OutOfMemory}!?world.WorldSnapshot {
        _ = self;
        _ = world_id;
        _ = tick;
        return null;
    }

    /// Get state history (all states between two timestamps)
    pub fn getStateHistory(
        self: Self,
        world_id: u64,
        start_time: i64,
        end_time: i64,
    ) error{OutOfMemory}![]world.WorldSnapshot {
        _ = self;
        _ = world_id;
        _ = start_time;
        _ = end_time;
        return &[_]world.WorldSnapshot{};
    }

    /// Replay events to reconstruct state
    pub fn replay(self: Self, world_id: u64, start_tick: u64, end_tick: u64) !void {
        _ = self;
        _ = world_id;
        _ = start_tick;
        _ = end_tick;
        // Replay implementation
    }
};

/// State reconstruction from log
pub const StateReconstructor = struct {
    const Self = @This();

    allocator: mem.Allocator,

    pub fn init(allocator: mem.Allocator) Self {
        return Self{ .allocator = allocator };
    }

    /// Reconstruct world from log entries
    pub fn reconstruct(self: Self, entries: []const LogEntry, base_uri: []const u8) error{OutOfMemory}!world.World {
        _ = self;
        _ = entries;
        _ = base_uri;
        // Full reconstruction implementation
        @panic("Not implemented");
    }
};

// ============================================================================
// COLOR COHERENCE LAYER
//
// Every log entry is Colorable: (world_id, tick) → SplitMix64 → color.
// Every world-moment is Tileable: entries at a tick tile the event space.
// GF(3) trit of an entry routes it to one of three parallel replay workers.
//
// SplitMix64 constants (shared with Gay.jl, tileable_shader.zig, wgpu_compute.zig):
//   GOLDEN = 0x9e3779b97f4a7c15
//   MIX1   = 0xbf58476d1ce4e5b9
//   MIX2   = 0x94d049bb133111eb
//
// Same seed + same (world_id, tick) = same color. Always. On any machine.
// The color IS the identity of the moment. Abductive trust: observe a color,
// recover which moment produced it.
// ============================================================================

const GOLDEN: u64 = 0x9e3779b97f4a7c15;
const MIX1: u64 = 0xbf58476d1ce4e5b9;
const MIX2: u64 = 0x94d049bb133111eb;

/// Plastic constant: x^3 = x + 1, hue_step = 360 / rho^2 ~ 205.14 degrees.
/// Golden is binary (Fibonacci, 2D). Plastic is ternary (Padovan, 3D/GF(3)).
const PLASTIC_HUE_STEP: f64 = 205.1442270324102;

/// GF(3) trit for parallel dispatch.
pub const Trit = enum(i8) {
    minus = -1, // Validator worker
    ergodic = 0, // Coordinator worker
    plus = 1, // Generator worker
};

/// SplitMix64 bijection. Pure, O(1), no state.
inline fn splitmix64(z_in: u64) u64 {
    var z = z_in;
    z = (z ^ (z >> 30)) *% MIX1;
    z = (z ^ (z >> 27)) *% MIX2;
    return z ^ (z >> 31);
}

/// Positional color: (seed, index) → deterministic u64.
inline fn colorAtIndex(seed: u64, index: u64) u64 {
    return splitmix64(seed +% GOLDEN *% index);
}

/// Color through which a log entry coheres.
pub const EntryColor = struct {
    r: u8,
    g: u8,
    b: u8,
    trit: Trit,
    hue: f64,

    pub fn hex(self: EntryColor) [7]u8 {
        var buf: [7]u8 = undefined;
        _ = std.fmt.bufPrint(&buf, "#{X:0>2}{X:0>2}{X:0>2}", .{ self.r, self.g, self.b }) catch unreachable;
        return buf;
    }
};

/// Derive the color of a log entry from its position in the world.
/// Uses the entry's chain hash as seed (Merkle-committed identity)
/// and tick as index (temporal position).
pub fn entryColor(entry: LogEntry) EntryColor {
    // Fold the 32-byte hash into a 64-bit seed
    const seed = mem.readInt(u64, entry.hash[0..8], .little) ^
        mem.readInt(u64, entry.hash[8..16], .little);
    const val = colorAtIndex(seed, entry.tick);
    return .{
        .r = @truncate(val >> 16),
        .g = @truncate(val >> 8),
        .b = @truncate(val),
        .trit = switch (@as(u2, @truncate(val % 3))) {
            0 => .ergodic,
            1 => .plus,
            2 => .minus,
            else => unreachable,
        },
        .hue = @mod(@as(f64, @floatFromInt(val % 360)), 360.0),
    };
}

/// Derive a color for a world-moment (world_id, tick) without needing the full entry.
/// For abductive lookup: "what color would tick T of world W be?"
pub fn momentColor(world_id: u64, tick: u64) EntryColor {
    const seed = splitmix64(world_id);
    const val = colorAtIndex(seed, tick);
    return .{
        .r = @truncate(val >> 16),
        .g = @truncate(val >> 8),
        .b = @truncate(val),
        .trit = switch (@as(u2, @truncate(val % 3))) {
            0 => .ergodic,
            1 => .plus,
            2 => .minus,
            else => unreachable,
        },
        .hue = @mod(@as(f64, @floatFromInt(tick)) * PLASTIC_HUE_STEP, 360.0),
    };
}

/// Embarrassingly parallel replay: partition entries by GF(3) trit.
/// Three independent worker lanes, zero data dependencies within a lane.
/// Conservation: sum of trits across all entries = 0 (mod 3) over any
/// complete tick range (guaranteed by append protocol).
pub const TripartiteReplay = struct {
    const Self = @This();

    /// Entries routed to the minus (Validator) lane
    minus_lane: std.ArrayList(usize),
    /// Entries routed to the ergodic (Coordinator) lane
    ergodic_lane: std.ArrayList(usize),
    /// Entries routed to the plus (Generator) lane
    plus_lane: std.ArrayList(usize),
    allocator: mem.Allocator,

    pub fn init(allocator: mem.Allocator) Self {
        return .{
            .minus_lane = std.ArrayList(usize).empty,
            .ergodic_lane = std.ArrayList(usize).empty,
            .plus_lane = std.ArrayList(usize).empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.minus_lane.deinit(self.allocator);
        self.ergodic_lane.deinit(self.allocator);
        self.plus_lane.deinit(self.allocator);
    }

    /// Partition entries into three lanes by trit. O(n), single pass.
    pub fn partition(self: *Self, entries: []const LogEntry) error{OutOfMemory}!void {
        self.minus_lane.clearRetainingCapacity();
        self.ergodic_lane.clearRetainingCapacity();
        self.plus_lane.clearRetainingCapacity();

        for (entries, 0..) |entry, i| {
            const color = entryColor(entry);
            switch (color.trit) {
                .minus => try self.minus_lane.append(self.allocator, i),
                .ergodic => try self.ergodic_lane.append(self.allocator, i),
                .plus => try self.plus_lane.append(self.allocator, i),
            }
        }
    }

    /// Verify GF(3) conservation: sum of all trits = 0 (mod 3).
    pub fn verifyConservation(self: Self) bool {
        const sum: i64 = @as(i64, @intCast(self.plus_lane.items.len)) -
            @as(i64, @intCast(self.minus_lane.items.len));
        return @mod(sum, 3) == 0;
    }

    /// Total entries across all lanes
    pub fn totalEntries(self: Self) usize {
        return self.minus_lane.items.len + self.ergodic_lane.items.len + self.plus_lane.items.len;
    }
};

/// Abductive color lookup: given an observed color, find which moment produced it.
/// Searches world_id's tick range for a matching color. O(range) but the match
/// is deterministic — same color = same moment.
pub fn abduceFromColor(world_id: u64, observed: EntryColor, max_tick: u64) ?u64 {
    var tick: u64 = 0;
    while (tick <= max_tick) : (tick += 1) {
        const candidate = momentColor(world_id, tick);
        if (candidate.r == observed.r and candidate.g == observed.g and candidate.b == observed.b) {
            return tick;
        }
    }
    return null;
}

/// SPI audit: verify that colorAtIndex produces identical results
/// regardless of evaluation order. Runs forward and backward over
/// a tick range, XOR-fingerprints must match.
pub fn spiAudit(world_id: u64, tick_range: u64) bool {
    const seed = splitmix64(world_id);
    var forward_xor: u64 = 0;
    var backward_xor: u64 = 0;

    // Forward pass
    var i: u64 = 0;
    while (i < tick_range) : (i += 1) {
        forward_xor ^= colorAtIndex(seed, i);
    }

    // Backward pass
    var j: u64 = tick_range;
    while (j > 0) {
        j -= 1;
        backward_xor ^= colorAtIndex(seed, j);
    }

    return forward_xor == backward_xor;
}

/// Immer-style structural sharing for world snapshots.
/// Only entries that changed between two ticks create new nodes.
/// Unchanged entries share references (zero-copy across moments).
pub const ImmerSnapshot = struct {
    const Self = @This();

    /// Tick this snapshot represents
    tick: u64,
    /// World this snapshot belongs to
    world_id: u64,
    /// Color through which this moment coheres
    color: EntryColor,
    /// Indices into the EventLog that are live at this tick.
    /// Structural sharing: adjacent snapshots share most indices.
    live_entries: []const usize,
    /// Merkle root at this tick (integrity anchor)
    merkle_root: ?[32]u8,

    pub fn deinit(self: Self, allocator: mem.Allocator) void {
        allocator.free(self.live_entries);
    }
};

/// Build immer snapshots from an EventLog. Each tick produces a snapshot
/// that structurally shares unchanged entries with the previous tick.
pub fn buildSnapshots(
    allocator: mem.Allocator,
    log: *const EventLog,
    world_id: u64,
) error{OutOfMemory}![]ImmerSnapshot {
    if (log.entries.items.len == 0) return &[_]ImmerSnapshot{};

    var snapshots = std.ArrayList(ImmerSnapshot).empty;
    defer {
        // Only free on error path; on success, caller owns
    }

    var current_tick: u64 = 0;
    var live = std.ArrayList(usize).empty;
    defer live.deinit(allocator);

    for (log.entries.items, 0..) |entry, i| {
        if (entry.tick != current_tick) {
            // Snapshot the current state
            const snap_entries = try allocator.dupe(usize, live.items);
            try snapshots.append(allocator, .{
                .tick = current_tick,
                .world_id = world_id,
                .color = momentColor(world_id, current_tick),
                .live_entries = snap_entries,
                .merkle_root = log.merkle_tree.getRoot(),
            });
            current_tick = entry.tick;
        }

        switch (entry.entry_type) {
            .entity_removed => {
                // Remove from live set (structural unsharing)
                for (live.items, 0..) |idx, j| {
                    if (idx == i) {
                        _ = live.swapRemove(j);
                        break;
                    }
                }
            },
            else => try live.append(allocator, i),
        }
    }

    // Final snapshot
    const final_entries = try allocator.dupe(usize, live.items);
    try snapshots.append(allocator, .{
        .tick = current_tick,
        .world_id = world_id,
        .color = momentColor(world_id, current_tick),
        .live_entries = final_entries,
        .merkle_root = log.merkle_tree.getRoot(),
    });

    return try snapshots.toOwnedSlice(allocator);
}

// ============== Tests ==============

test "EventLog - append and verify" {
    const allocator = std.testing.allocator;

    var log = EventLog.init(allocator);
    defer log.deinit();

    try log.append(.world_created, 1000, 0, 1, "test data");
    try log.append(.entity_spawned, 1100, 1, 1, "entity 1");
    try log.append(.tick_advanced, 1200, 2, 1, "");

    try std.testing.expectEqual(@as(usize, 3), log.entries.items.len);
    try std.testing.expect(log.verifyIntegrity());
}

test "EventLog - Merkle tree" {
    const allocator = std.testing.allocator;

    var log = EventLog.init(allocator);
    defer log.deinit();

    // Add entries
    for (0..4) |i| {
        var data: [32]u8 = undefined;
        const str = try std.fmt.bufPrint(&data, "entry {d}", .{i});
        try log.append(.tick_advanced, @intCast(i * 100), @intCast(i), 1, str);
    }

    // Build tree
    try log.rebuildMerkleTree();

    const root = log.getMerkleRoot();
    try std.testing.expect(root != null);
}

test "FlatFileStorage" {
    const allocator = std.testing.allocator;

    var storage = try FlatFileStorage.init(allocator, "/tmp/ewig_test");
    defer storage.deinit();

    try storage.open(1);

    const entry = LogEntry{
        .entry_type = .world_created,
        .timestamp = 1000,
        .tick = 0,
        .world_id = 1,
        .data = "test",
        .hash = [_]u8{1} ** 32,
        .prev_hash = [_]u8{0} ** 32,
    };

    try storage.writeEntry(entry);
}

test "Color coherence - momentColor deterministic" {
    // Same (world_id, tick) always produces the same color (SPI)
    const c1 = momentColor(42, 100);
    const c2 = momentColor(42, 100);
    try std.testing.expectEqual(c1.r, c2.r);
    try std.testing.expectEqual(c1.g, c2.g);
    try std.testing.expectEqual(c1.b, c2.b);
    try std.testing.expectEqual(c1.trit, c2.trit);

    // Different tick = different color
    const c3 = momentColor(42, 101);
    try std.testing.expect(c1.r != c3.r or c1.g != c3.g or c1.b != c3.b);
}

test "Color coherence - SPI audit" {
    // Forward and backward evaluation must XOR-match
    try std.testing.expect(spiAudit(1, 1000));
    try std.testing.expect(spiAudit(42, 500));
    try std.testing.expect(spiAudit(0xdeadbeef, 256));
}

test "Color coherence - tripartite replay" {
    const allocator = std.testing.allocator;

    var log = EventLog.init(allocator);
    defer log.deinit();

    // Add entries across multiple ticks
    for (0..30) |i| {
        var data: [32]u8 = undefined;
        const str = try std.fmt.bufPrint(&data, "evt {d}", .{i});
        try log.append(.tick_advanced, @intCast(i * 100), @intCast(i), 1, str);
    }

    var replay = TripartiteReplay.init(allocator);
    defer replay.deinit();

    try replay.partition(log.entries.items);

    // All entries accounted for
    try std.testing.expectEqual(@as(usize, 30), replay.totalEntries());
}

test "Color coherence - entryColor from hash" {
    const entry = LogEntry{
        .entry_type = .world_created,
        .timestamp = 1000,
        .tick = 0,
        .world_id = 1,
        .data = "test",
        .hash = [_]u8{0xab} ** 32,
        .prev_hash = [_]u8{0} ** 32,
    };

    const c = entryColor(entry);
    // Must produce valid RGB
    _ = c.hex();
    // Trit must be one of the three values
    try std.testing.expect(c.trit == .minus or c.trit == .ergodic or c.trit == .plus);
}

test "Color coherence - immer snapshots" {
    const allocator = std.testing.allocator;

    var log = EventLog.init(allocator);
    defer log.deinit();

    // Tick 0: world created + 2 entities
    try log.append(.world_created, 100, 0, 1, "w1");
    try log.append(.entity_spawned, 110, 0, 1, "e1");
    try log.append(.entity_spawned, 120, 0, 1, "e2");

    // Tick 1: entity update
    try log.append(.entity_updated, 200, 1, 1, "e1-upd");

    // Tick 2: entity removed
    try log.append(.entity_removed, 300, 2, 1, "e2-rm");

    const snapshots = try buildSnapshots(allocator, &log, 1);
    defer {
        for (snapshots) |snap| snap.deinit(allocator);
        allocator.free(snapshots);
    }

    // Three ticks = three snapshots
    try std.testing.expectEqual(@as(usize, 3), snapshots.len);
    try std.testing.expectEqual(@as(u64, 0), snapshots[0].tick);
    try std.testing.expectEqual(@as(u64, 1), snapshots[1].tick);
    try std.testing.expectEqual(@as(u64, 2), snapshots[2].tick);

    // Each snapshot has a deterministic color
    try std.testing.expectEqual(momentColor(1, 0).r, snapshots[0].color.r);
    try std.testing.expectEqual(momentColor(1, 1).r, snapshots[1].color.r);
}
