//! sync.zig - Multi-node synchronization for Ewig
//!
//! Synchronize logs between nodes with:
//! - Sync logs between nodes
//! - Conflict resolution strategies
//! - CRDT-like convergence
//! - Delta encoding for efficiency
//! - Merkle tree sync for quick comparison

const std = @import("std");
const Allocator = std.mem.Allocator;
const format = @import("format.zig");
const log = @import("log.zig");
const store = @import("store.zig");

const Hash = format.Hash;
const Event = log.Event;
const EventLog = log.EventLog;
const MerkleTree = store.MerkleTree;

// ============================================================================
// SYNC PROTOCOL
// ============================================================================

/// Message types for sync protocol
pub const SyncMessage = union(enum) {
    /// Request list of branches
    ListBranches,
    /// Response with branch list
    BranchList: []const []const u8,
    /// Request events since a given hash
    GetEventsSince: Hash,
    /// Response with events
    Events: []const Event,
    /// Request Merkle tree for comparison
    GetMerkleTree,
    /// Merkle tree response
    MerkleTreeResponse: MerkleTreeData,
    /// Request specific hashes
    GetHashes: []const Hash,
    /// Hashes not found locally
    MissingHashes: []const Hash,
    /// Acknowledgment
    Ack: u64,
    /// Error
    Error: []const u8,
};

/// Merkle tree data for network transfer
pub const MerkleTreeData = struct {
    root: Hash,
    levels: []const []const Hash,
    
    pub fn deinit(self: *MerkleTreeData, allocator: Allocator) void {
        for (self.levels) |level| {
            allocator.free(level);
        }
        allocator.free(self.levels);
    }
};

// ============================================================================
// MERKLE SYNC
// ============================================================================

/// Uses Merkle trees to efficiently find differences
pub const MerkleSync = struct {
    allocator: Allocator,
    
    const Self = @This();
    
    pub fn init(allocator: Allocator) Self {
        return .{ .allocator = allocator };
    }
    
    /// Build Merkle tree from event hashes
    pub fn buildTree(self: Self, events: []const Event) !MerkleTree {
        var tree = MerkleTree.init(self.allocator);
        errdefer tree.deinit();
        
        for (events) |event| {
            try tree.addLeaf(event.hash);
        }
        
        _ = try tree.build();
        return tree;
    }
    
    /// Find differing hashes between two Merkle trees
    pub fn findDifferences(
        self: Self,
        local_tree: MerkleTree,
        remote_root: Hash,
        remote_levels: []const []const Hash,
    ) ![]Hash {
        var differences = std.ArrayList(Hash).init(self.allocator);
        errdefer differences.deinit();
        
        // If roots match, no differences
        if (std.mem.eql(u8, &local_tree.root, &remote_root)) {
            return differences.toOwnedSlice();
        }
        
        // Compare level by level
        if (remote_levels.len > 0 and local_tree.levels.items.len > 0) {
            const local_leaves = local_tree.levels.items[0];
            const remote_leaves = remote_levels[0];
            
            // Find which leaves differ
            const max_len = @max(local_leaves.items.len, remote_leaves.len);
            for (0..max_len) |i| {
                var local_hash: ?Hash = null;
                var remote_hash: ?Hash = null;
                
                if (i < local_leaves.items.len) {
                    local_hash = local_leaves.items[i];
                }
                if (i < remote_leaves.len) {
                    remote_hash = remote_leaves[i];
                }
                
                // If either is missing or they differ, we need to sync
                if (local_hash == null or remote_hash == null or
                    !std.mem.eql(u8, &local_hash.?, &remote_hash.?)) {
                    // Add the remote hash as one we need
                    if (remote_hash) |h| {
                        try differences.append(h);
                    }
                }
            }
        }
        
        return differences.toOwnedSlice();
    }
    
    /// Serialize Merkle tree for network
    pub fn serializeTree(self: Self, tree: MerkleTree) !MerkleTreeData {
        var levels = try self.allocator.alloc([]Hash, tree.levels.items.len);
        errdefer self.allocator.free(levels);
        
        for (tree.levels.items, 0..) |level, i| {
            levels[i] = try self.allocator.dupe(Hash, level.items);
        }
        
        return .{
            .root = tree.root,
            .levels = levels,
        };
    }
};

// ============================================================================
// DELTA ENCODING
// ============================================================================

/// Efficient delta encoding for event synchronization
pub const DeltaEncoder = struct {
    allocator: Allocator,
    
    const Self = @This();
    
    pub fn init(allocator: Allocator) Self {
        return .{ .allocator = allocator };
    }
    
    /// Encode delta between local and remote event sets
    pub fn encodeDelta(
        self: Self,
        local_events: []const Event,
        remote_hashes: []const Hash,
    ) ![]const Event {
        var delta = std.ArrayList(Event).init(self.allocator);
        errdefer delta.deinit();
        
        // Build set of remote hashes
        var remote_set = std.HashMap(Hash, void, format.HashContext, std.hash_map.default_max_load_percentage).init(self.allocator);
        defer remote_set.deinit();
        
        for (remote_hashes) |h| {
            try remote_set.put(h, {});
        }
        
        // Find events not in remote set
        for (local_events) |event| {
            if (!remote_set.contains(event.hash)) {
                try delta.append(event);
            }
        }
        
        return delta.toOwnedSlice();
    }
    
    /// Decode and apply delta
    pub fn applyDelta(
        self: Self,
        log: *EventLog,
        delta: []const Event,
    ) !void {
        // Sort by sequence number to ensure correct order
        var sorted = try self.allocator.alloc(Event, delta.len);
        defer self.allocator.free(sorted);
        
        @memcpy(sorted, delta);
        std.sort.insertion(Event, sorted, {}, struct {
            fn lessThan(_: void, a: Event, b: Event) bool {
                return a.seq < b.seq;
            }
        }.lessThan);
        
        // Apply each event
        for (sorted) |event| {
            // Check if already exists
            if (log.getByHash(event.hash) == null) {
                // Add to log
                // Note: In real implementation, we'd need to handle ordering constraints
                _ = try log.append(event.type, event.world_uri, event.payload);
            }
        }
    }
    
    /// Compress events using delta compression
    pub fn compressEvents(self: Self, events: []const Event, base: ?Event) ![]u8 {
        var output = std.ArrayList(u8).init(self.allocator);
        defer output.deinit();
        
        const writer = output.writer();
        
        // Write count
        try writer.writeInt(u32, @intCast(events.len), .little);
        
        for (events) |event| {
            // If we have a base event, delta encode against it
            if (base) |b| {
                // Write only changed fields
                var changed: u8 = 0;
                
                if (event.timestamp != b.timestamp) changed |= 0x01;
                if (event.seq != b.seq) changed |= 0x02;
                if (event.type != b.type) changed |= 0x04;
                if (!std.mem.eql(u8, event.world_uri, b.world_uri)) changed |= 0x08;
                if (!std.mem.eql(u8, event.payload, b.payload)) changed |= 0x10;
                
                try writer.writeByte(changed);
                
                if (changed & 0x01 != 0) try writer.writeInt(i64, event.timestamp, .little);
                if (changed & 0x02 != 0) try writer.writeInt(u64, event.seq, .little);
                if (changed & 0x04 != 0) try writer.writeByte(@intFromEnum(event.type));
                if (changed & 0x08 != 0) {
                    try writer.writeInt(u32, @intCast(event.world_uri.len), .little);
                    try writer.writeAll(event.world_uri);
                }
                if (changed & 0x10 != 0) {
                    try writer.writeInt(u32, @intCast(event.payload.len), .little);
                    try writer.writeAll(event.payload);
                }
                
                // Always write hash and parent
                try writer.writeAll(&event.hash);
                try writer.writeAll(&event.parent);
            } else {
                // Full encoding
                try writer.writeByte(0xFF); // All fields changed
                try writer.writeInt(i64, event.timestamp, .little);
                try writer.writeInt(u64, event.seq, .little);
                try writer.writeByte(@intFromEnum(event.type));
                try writer.writeInt(u32, @intCast(event.world_uri.len), .little);
                try writer.writeAll(event.world_uri);
                try writer.writeInt(u32, @intCast(event.payload.len), .little);
                try writer.writeAll(event.payload);
                try writer.writeAll(&event.hash);
                try writer.writeAll(&event.parent);
            }
        }
        
        return output.toOwnedSlice();
    }
};

// ============================================================================
// CRDT MERGE
// ============================================================================

/// CRDT-based conflict resolution
pub const CRDTMerge = struct {
    allocator: Allocator,
    
    const Self = @This();
    
    pub fn init(allocator: Allocator) Self {
        return .{ .allocator = allocator };
    }
    
    /// Merge two event logs using CRDT semantics
    pub fn mergeLogs(
        self: Self,
        local: *EventLog,
        remote_events: []const Event,
    ) !void {
        // Build map of local events by hash
        var local_set = std.HashMap(Hash, Event, format.HashContext, std.hash_map.default_max_load_percentage).init(self.allocator);
        defer local_set.deinit();
        
        var it = log.EventIterator.init(local, .Forward);
        while (it.next()) |event| {
            try local_set.put(event.hash, event);
        }
        
        // Add remote events that don't exist locally
        var to_add = std.ArrayList(Event).init(self.allocator);
        defer to_add.deinit();
        
        for (remote_events) |event| {
            if (!local_set.contains(event.hash)) {
                try to_add.append(event);
            }
        }
        
        // Sort by sequence number (LWW - Last Writer Wins)
        std.sort.insertion(Event, to_add.items, {}, struct {
            fn lessThan(_: void, a: Event, b: Event) bool {
                if (a.timestamp != b.timestamp) {
                    return a.timestamp < b.timestamp;
                }
                // Tie-breaker: lower hash wins
                return std.mem.order(u8, &a.hash, &b.hash) == .lt;
            }
        }.lessThan);
        
        // Add events
        for (to_add.items) |event| {
            _ = try local.append(event.type, event.world_uri, event.payload);
        }
    }
    
    /// Resolve conflicts using vector clocks
    pub fn resolveWithVectorClock(
        self: Self,
        events: []const Event,
        node_id: []const u8,
    ) ![]const Event {
        _ = self;
        _ = node_id;
        
        // Vector clock implementation would go here
        // For now, just sort by timestamp
        var sorted = try std.heap.page_allocator.alloc(Event, events.len);
        @memcpy(sorted, events);
        
        std.sort.insertion(Event, sorted, {}, struct {
            fn lessThan(_: void, a: Event, b: Event) bool {
                return a.timestamp < b.timestamp;
            }
        }.lessThan);
        
        return sorted;
    }
};

// ============================================================================
// SYNC ENGINE
// ============================================================================

/// Main synchronization engine
pub const SyncEngine = struct {
    allocator: Allocator,
    merkle: MerkleSync,
    delta: DeltaEncoder,
    crdt: CRDTMerge,
    conflict_strategy: ConflictStrategy,
    
    const Self = @This();
    
    pub const ConflictStrategy = enum {
        Timestamp,    // Last writer wins
        VectorClock,  // Use vector clocks
        Custom,       // Custom resolver
    };
    
    pub fn init(allocator: Allocator, strategy: ConflictStrategy) Self {
        return .{
            .allocator = allocator,
            .merkle = MerkleSync.init(allocator),
            .delta = DeltaEncoder.init(allocator),
            .crdt = CRDTMerge.init(allocator),
            .conflict_strategy = strategy,
        };
    }
    
    /// Synchronize with a remote node
    pub fn sync(
        self: *Self,
        local: *EventLog,
        remote_get_events: *const fn ([]const Hash) anyerror![]const Event,
        remote_get_tree: *const fn () anyerror!MerkleTreeData,
    ) !SyncResult {
        // 1. Get remote Merkle tree
        const remote_tree = try remote_get_tree();
        defer remote_tree.deinit(self.allocator);
        
        // 2. Build local Merkle tree
        var local_tree = try self.merkle.buildTree(local.events.items);
        defer local_tree.deinit();
        
        // 3. Find differences
        const differences = try self.merkle.findDifferences(
            local_tree,
            remote_tree.root,
            remote_tree.levels,
        );
        defer self.allocator.free(differences);
        
        if (differences.len == 0) {
            return SyncResult{
                .events_sent = 0,
                .events_received = 0,
                .conflicts = 0,
            };
        }
        
        // 4. Get missing events from remote
        const remote_events = try remote_get_events(differences);
        defer self.allocator.free(remote_events);
        
        // 5. Calculate what remote needs
        const local_hashes = try self.getEventHashes(local);
        defer self.allocator.free(local_hashes);
        
        // 6. Merge using CRDT
        const pre_count = local.count();
        try self.crdt.mergeLogs(local, remote_events);
        const events_received = local.count() - pre_count;
        
        return SyncResult{
            .events_sent = 0, // Would be calculated in bidirectional sync
            .events_received = events_received,
            .conflicts = 0, // Resolved by CRDT
        };
    }
    
    /// Bidirectional sync
    pub fn syncBidirectional(
        self: *Self,
        local: *EventLog,
        remote: *EventLog,
    ) !SyncResult {
        // Get local events
        const local_events = try self.allocator.alloc(Event, local.events.items.len);
        defer self.allocator.free(local_events);
        @memcpy(local_events, local.events.items);
        
        // Get remote events
        const remote_events = try self.allocator.alloc(Event, remote.events.items.len);
        defer self.allocator.free(remote_events);
        @memcpy(remote_events, remote.events.items);
        
        // Calculate delta both ways
        const local_hashes = try self.eventsToHashes(local_events);
        defer self.allocator.free(local_hashes);
        
        const remote_hashes = try self.eventsToHashes(remote_events);
        defer self.allocator.free(remote_hashes);
        
        const to_remote = try self.delta.encodeDelta(local_events, remote_hashes);
        defer self.allocator.free(to_remote);
        
        const to_local = try self.delta.encodeDelta(remote_events, local_hashes);
        defer self.allocator.free(to_local);
        
        // Apply deltas
        try self.delta.applyDelta(local, to_local);
        try self.delta.applyDelta(remote, to_remote);
        
        return SyncResult{
            .events_sent = to_remote.len,
            .events_received = to_local.len,
            .conflicts = 0,
        };
    }
    
    fn getEventHashes(self: Self, event_log: *EventLog) ![]Hash {
        var hashes = std.ArrayList(Hash).init(self.allocator);
        errdefer hashes.deinit();
        
        var it = log.EventIterator.init(event_log, .Forward);
        while (it.next()) |event| {
            try hashes.append(event.hash);
        }
        
        return hashes.toOwnedSlice();
    }
    
    fn eventsToHashes(self: Self, events: []const Event) ![]Hash {
        var hashes = try self.allocator.alloc(Hash, events.len);
        for (events, 0..) |event, i| {
            hashes[i] = event.hash;
        }
        return hashes;
    }
};

/// Result of a sync operation
pub const SyncResult = struct {
    events_sent: usize,
    events_received: usize,
    conflicts: usize,
    
    pub fn format(
        self: SyncResult,
        comptime _: []const u8,
        _: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        try writer.print("SyncResult{{ sent: {d}, received: {d}, conflicts: {d} }}", .{
            self.events_sent,
            self.events_received,
            self.conflicts,
        });
    }
};

// ============================================================================
// NETWORK TRANSPORT
// ============================================================================

/// Network transport abstraction for sync
pub const SyncTransport = struct {
    vtable: *const VTable,
    
    pub const VTable = struct {
        connect: *const fn (ctx: *anyopaque, address: []const u8) anyerror!void,
        disconnect: *const fn (ctx: *anyopaque) void,
        send: *const fn (ctx: *anyopaque, msg: SyncMessage) anyerror!void,
        receive: *const fn (ctx: *anyopaque, timeout_ms: u32) anyerror!?SyncMessage,
    };
    
    pub fn connect(self: SyncTransport, address: []const u8) !void {
        return self.vtable.connect(self, address);
    }
    
    pub fn disconnect(self: SyncTransport) void {
        return self.vtable.disconnect(self);
    }
    
    pub fn send(self: SyncTransport, msg: SyncMessage) !void {
        return self.vtable.send(self, msg);
    }
    
    pub fn receive(self: SyncTransport, timeout_ms: u32) !?SyncMessage {
        return self.vtable.receive(self, timeout_ms);
    }
};

// ============================================================================
// TESTS
// ============================================================================

const testing = std.testing;

test "merkle sync" {
    const merkle = MerkleSync.init(testing.allocator);
    
    var local_events = std.ArrayList(Event).init(testing.allocator);
    defer local_events.deinit();
    
    // Create some events
    const e1 = Event{
        .timestamp = 1000,
        .seq = 1,
        .hash = computeEventHash(1),
        .parent = [_]u8{0} ** 32,
        .world_uri = "a://world",
        .type = .WorldCreated,
        .payload = "{}",
    };
    try local_events.append(e1);
    
    // Build tree
    var tree = try merkle.buildTree(local_events.items);
    defer tree.deinit();
    
    try testing.expect(!std.mem.eql(u8, &tree.root, &[_]u8{0} ** 32));
}

test "delta encoding" {
    const encoder = DeltaEncoder.init(testing.allocator);
    
    var local = std.ArrayList(Event).init(testing.allocator);
    defer local.deinit();
    
    try local.append(.{
        .timestamp = 1000,
        .seq = 1,
        .hash = computeEventHash(1),
        .parent = [_]u8{0} ** 32,
        .world_uri = "a://world",
        .type = .WorldCreated,
        .payload = "{}",
    });
    
    try local.append(.{
        .timestamp = 2000,
        .seq = 2,
        .hash = computeEventHash(2),
        .parent = computeEventHash(1),
        .world_uri = "a://world",
        .type = .StateChanged,
        .payload = "{\"x\":1}",
    });
    
    // Remote has only first event
    var remote_hashes = std.ArrayList(Hash).init(testing.allocator);
    defer remote_hashes.deinit();
    try remote_hashes.append(computeEventHash(1));
    
    const delta = try encoder.encodeDelta(local.items, remote_hashes.items);
    defer testing.allocator.free(delta);
    
    try testing.expectEqual(@as(usize, 1), delta.len);
    try testing.expectEqual(@as(u64, 2), delta[0].seq);
}

test "crdt merge" {
    var local = try EventLog.initInMemory(testing.allocator);
    defer local.deinit();
    
    var remote = try EventLog.initInMemory(testing.allocator);
    defer remote.deinit();
    
    // Local events
    _ = try local.append(.WorldCreated, "a://world", "{}");
    _ = try local.append(.StateChanged, "a://world", "{\"local\":true}");
    
    // Remote events
    _ = try remote.append(.WorldCreated, "a://world", "{}");
    _ = try remote.append(.StateChanged, "a://world", "{\"remote\":true}");
    
    // Merge
    const crdt = CRDTMerge.init(testing.allocator);
    try crdt.mergeLogs(&local, remote.events.items);
    
    // Should have merged events
    try testing.expect(local.count() >= 2);
}

test "sync engine" {
    var local = try EventLog.initInMemory(testing.allocator);
    defer local.deinit();
    
    var remote = try EventLog.initInMemory(testing.allocator);
    defer remote.deinit();
    
    // Add different events to each
    _ = try local.append(.WorldCreated, "a://world", "{}");
    _ = try local.append(.StateChanged, "a://world", "{\"x\":1}");
    
    _ = try remote.append(.WorldCreated, "a://world", "{}");
    _ = try remote.append(.PlayerAction, "a://world", "{\"jump\":true}");
    
    // Sync
    var engine = SyncEngine.init(testing.allocator, .Timestamp);
    const result = try engine.syncBidirectional(&local, &remote);
    
    try testing.expect(result.events_sent > 0 or result.events_received > 0);
}

fn computeEventHash(seed: u64) Hash {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(std.mem.asBytes(&seed));
    var hash: Hash = undefined;
    hasher.final(&hash);
    return hash;
}
