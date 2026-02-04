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
        var hasher = crypto.hash.sha2.Sha256.init(.{});
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
            var hasher = crypto.hash.sha2.Sha256.init(.{});
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
        var hasher = crypto.hash.sha2.Sha256.init(.{});
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
            var hasher = crypto.hash.sha2.Sha256.init(.{});
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
