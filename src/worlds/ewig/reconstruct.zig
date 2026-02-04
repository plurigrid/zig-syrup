//! reconstruct.zig - State reconstruction for Ewig
//!
//! Replay events to build state with:
//! - Replay events to build state
//! - Snapshot caching for fast access
//! - Incremental reconstruction
//! - Parallel replay for large histories
//! - Verification (reconstructed == expected)

const std = @import("std");
const Allocator = std.mem.Allocator;
const format = @import("format.zig");
const log = @import("log.zig");
const store = @import("store.zig");
const timeline = @import("timeline.zig");

const Hash = format.Hash;
const Event = log.Event;
const EventType = format.EventType;
const MemoryStore = store.MemoryStore;

// ============================================================================
// STATE SNAPSHOT
// ============================================================================

/// A point-in-time state snapshot
pub const StateSnapshot = struct {
    hash: Hash,
    timestamp: i64,
    seq: u64,
    data: []const u8,
    event_hash: Hash,
    
    const Self = @This();
    
    pub fn computeHash(data: []const u8, timestamp: i64, seq: u64) Hash {
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        hasher.update(data);
        hasher.update(std.mem.asBytes(&timestamp));
        hasher.update(std.mem.asBytes(&seq));
        var h: Hash = undefined;
        hasher.final(&h);
        return h;
    }
};

/// Cache entry for snapshots
const CacheEntry = struct {
    snapshot: StateSnapshot,
    last_accessed: i64,
    access_count: u64,
};

// ============================================================================
// SNAPSHOT CACHE
// ============================================================================

/// LRU cache for state snapshots
pub const SnapshotCache = struct {
    allocator: Allocator,
    entries: std.HashMap(Hash, CacheEntry, format.HashContext, std.hash_map.default_max_load_percentage),
    max_size: usize,
    current_size: usize,
    mutex: std.Thread.Mutex,
    hits: u64,
    misses: u64,
    
    const Self = @This();
    
    pub fn init(allocator: Allocator, max_size: usize) Self {
        return .{
            .allocator = allocator,
            .entries = std.HashMap(Hash, CacheEntry, format.HashContext, std.hash_map.default_max_load_percentage).init(allocator),
            .max_size = max_size,
            .current_size = 0,
            .mutex = .{},
            .hits = 0,
            .misses = 0,
        };
    }
    
    pub fn deinit(self: *Self) void {
        var it = self.entries.valueIterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.snapshot.data);
        }
        self.entries.deinit();
    }
    
    /// Get a snapshot from cache
    pub fn get(self: *Self, hash: Hash) ?StateSnapshot {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        if (self.entries.getPtr(hash)) |entry| {
            entry.last_accessed = std.time.nanoTimestamp();
            entry.access_count += 1;
            self.hits += 1;
            return entry.snapshot;
        }
        
        self.misses += 1;
        return null;
    }
    
    /// Put a snapshot in cache
    pub fn put(self: *Self, snapshot: StateSnapshot) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        // Check if already cached
        if (self.entries.contains(snapshot.hash)) {
            return;
        }
        
        // Make room if needed
        while (self.current_size >= self.max_size and self.entries.count() > 0) {
            self.evictLRU();
        }
        
        // Copy data
        const data_copy = try self.allocator.dupe(u8, snapshot.data);
        errdefer self.allocator.free(data_copy);
        
        var snap_copy = snapshot;
        snap_copy.data = data_copy;
        
        try self.entries.put(snap_copy.hash, .{
            .snapshot = snap_copy,
            .last_accessed = std.time.nanoTimestamp(),
            .access_count = 1,
        });
        
        self.current_size += 1;
    }
    
    /// Evict least recently used entry
    fn evictLRU(self: *Self) void {
        var oldest_time: i64 = std.math.maxInt(i64);
        var oldest_hash: ?Hash = null;
        
        var it = self.entries.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.last_accessed < oldest_time) {
                oldest_time = entry.value_ptr.last_accessed;
                oldest_hash = entry.key_ptr.*;
            }
        }
        
        if (oldest_hash) |h| {
            if (self.entries.fetchRemove(h)) |kv| {
                self.allocator.free(kv.value.snapshot.data);
                self.current_size -= 1;
            }
        }
    }
    
    /// Get cache statistics
    pub fn stats(self: Self) struct { hits: u64, misses: u64, size: usize, capacity: usize } {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        return .{
            .hits = self.hits,
            .misses = self.misses,
            .size = self.current_size,
            .capacity = self.max_size,
        };
    }
    
    /// Clear the cache
    pub fn clear(self: *Self) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        var it = self.entries.valueIterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.snapshot.data);
        }
        self.entries.clearRetainingCapacity();
        self.current_size = 0;
    }
};

// ============================================================================
// STATE RECONSTRUCTOR
// ============================================================================

/// Reconstructs state by replaying events
pub const StateReconstructor = struct {
    allocator: Allocator,
    cache: SnapshotCache,
    events: *log.EventLog,
    store: *MemoryStore,
    
    const Self = @This();
    
    pub fn init(allocator: Allocator, events: *log.EventLog, store: *MemoryStore, cache_size: usize) Self {
        return .{
            .allocator = allocator,
            .cache = SnapshotCache.init(allocator, cache_size),
            .events = events,
            .store = store,
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.cache.deinit();
    }
    
    /// Reconstruct state at a specific event
    pub fn reconstructAt(self: *Self, target_hash: Hash) !StateSnapshot {
        // Check cache first
        if (self.cache.get(target_hash)) |snapshot| {
            var copy = snapshot;
            copy.data = try self.allocator.dupe(u8, snapshot.data);
            return copy;
        }
        
        // Find nearest cached ancestor
        const nearest = try self.findNearestCachedAncestor(target_hash);
        
        // Build list of events to replay
        var events_to_replay = std.ArrayList(Event).init(self.allocator);
        defer events_to_replay.deinit();
        
        var current = target_hash;
        const zero_hash = [_]u8{0} ** 32;
        
        while (!std.mem.eql(u8, &current, &zero_hash) and 
               !std.mem.eql(u8, &current, &nearest.hash)) {
            const event = self.events.getByHash(current) orelse break;
            try events_to_replay.append(event);
            current = event.parent;
        }
        
        // Reverse to get chronological order
        std.mem.reverse(Event, events_to_replay.items);
        
        // Start from base state
        var state_data = try self.allocator.dupe(u8, nearest.data);
        errdefer self.allocator.free(state_data);
        
        // Replay events
        for (events_to_replay.items) |event| {
            state_data = try self.applyEvent(state_data, event);
        }
        
        // Get the final event for metadata
        const final_event = self.events.getByHash(target_hash).?;
        
        const snapshot = StateSnapshot{
            .hash = undefined,
            .timestamp = final_event.timestamp,
            .seq = final_event.seq,
            .data = state_data,
            .event_hash = target_hash,
        };
        
        // Compute hash
        var snap_with_hash = snapshot;
        snap_with_hash.hash = StateSnapshot.computeHash(state_data, snapshot.timestamp, snapshot.seq);
        
        // Cache it
        try self.cache.put(snap_with_hash);
        
        // Also store in CAS
        _ = try self.store.put(state_data);
        
        return snap_with_hash;
    }
    
    /// Find the nearest cached ancestor
    fn findNearestCachedAncestor(self: *Self, target_hash: Hash) !StateSnapshot {
        var current = target_hash;
        const zero_hash = [_]u8{0} ** 32;
        
        // Walk back until we find a cached snapshot or reach genesis
        while (!std.mem.eql(u8, &current, &zero_hash)) {
            if (self.cache.get(current)) |snapshot| {
                var copy = snapshot;
                copy.data = try self.allocator.dupe(u8, snapshot.data);
                return copy;
            }
            
            if (self.events.getByHash(current)) |event| {
                current = event.parent;
            } else {
                break;
            }
        }
        
        // Return genesis state
        return StateSnapshot{
            .hash = [_]u8{0} ** 32,
            .timestamp = 0,
            .seq = 0,
            .data = try self.allocator.dupe(u8, "{}"),
            .event_hash = [_]u8{0} ** 32,
        };
    }
    
    /// Apply a single event to state
    fn applyEvent(self: *Self, state: []const u8, event: Event) ![]u8 {
        // This is a simplified version - real implementation would
        // parse JSON/MsgPack and apply changes
        
        return switch (event.type) {
            .WorldCreated => self.allocator.dupe(u8, event.payload),
            .StateChanged => try self.mergeState(state, event.payload),
            .StateBatch => try self.applyBatch(state, event.payload),
            .PlayerAction => try self.applyAction(state, event.payload),
            .ObjectCreated => try self.addObject(state, event.payload),
            .ObjectDestroyed => try self.removeObject(state, event.payload),
            .ObjectMoved => try self.moveObject(state, event.payload),
            else => self.allocator.dupe(u8, state),
        };
    }
    
    /// Merge state changes
    fn mergeState(self: *Self, state: []const u8, change: []const u8) ![]u8 {
        // Simplified: just concatenate with marker
        // Real implementation would do proper JSON merge
        if (state.len == 0 or std.mem.eql(u8, state, "{}")) {
            return self.allocator.dupe(u8, change);
        }
        
        // Remove closing brace from state, add comma and change, add closing brace
        const result = try std.fmt.allocPrint(self.allocator, "{s},{s}", .{ state, change });
        return result;
    }
    
    /// Apply batch of changes
    fn applyBatch(self: *Self, state: []const u8, batch: []const u8) ![]u8 {
        // Simplified
        _ = batch;
        return self.allocator.dupe(u8, state);
    }
    
    /// Apply player action
    fn applyAction(self: *Self, state: []const u8, action: []const u8) ![]u8 {
        _ = action;
        return self.allocator.dupe(u8, state);
    }
    
    /// Add object to state
    fn addObject(self: *Self, state: []const u8, obj: []const u8) ![]u8 {
        return std.fmt.allocPrint(self.allocator, "{s}+obj:{s}", .{ state, obj });
    }
    
    /// Remove object from state
    fn removeObject(self: *Self, state: []const u8, obj: []const u8) ![]u8 {
        return std.fmt.allocPrint(self.allocator, "{s}-obj:{s}", .{ state, obj });
    }
    
    /// Move object in state
    fn moveObject(self: *Self, state: []const u8, move_data: []const u8) ![]u8 {
        return std.fmt.allocPrint(self.allocator, "{s}~move:{s}", .{ state, move_data });
    }
    
    /// Create a checkpoint/snapshot at current state
    pub fn checkpoint(self: *Self, event_hash: Hash) !Hash {
        const snapshot = try self.reconstructAt(event_hash);
        defer self.allocator.free(snapshot.data);
        
        try self.cache.put(snapshot);
        
        // Store in CAS
        const hash = try self.store.put(snapshot.data);
        return hash;
    }
    
    /// Verify that reconstruction produces expected hash
    pub fn verify(self: *Self, event_hash: Hash, expected_state_hash: Hash) !bool {
        const snapshot = try self.reconstructAt(event_hash);
        defer self.allocator.free(snapshot.data);
        
        return std.mem.eql(u8, &snapshot.hash, &expected_state_hash);
    }
};

// ============================================================================
// PARALLEL RECONSTRUCTION
// ============================================================================

/// Parallel state reconstruction for large histories
pub const ParallelReconstructor = struct {
    allocator: Allocator,
    events: *log.EventLog,
    thread_count: usize,
    
    const Self = @This();
    
    pub fn init(allocator: Allocator, events: *log.EventLog, thread_count: usize) Self {
        return .{
            .allocator = allocator,
            .events = events,
            .thread_count = thread_count,
        };
    }
    
    /// Reconstruct by processing chunks in parallel
    pub fn reconstructParallel(
        self: Self,
        checkpoints: []const Hash,
        target: Hash,
    ) !StateSnapshot {
        // Find which checkpoint to start from
        var best_checkpoint: ?Hash = null;
        var min_distance: usize = std.math.maxInt(usize);
        
        for (checkpoints) |cp| {
            const distance = try self.distanceTo(cp, target);
            if (distance < min_distance) {
                min_distance = distance;
                best_checkpoint = cp;
            }
        }
        
        if (best_checkpoint == null) {
            return error.NoCheckpointFound;
        }
        
        // In a real implementation, this would parallelize the replay
        // For now, fall back to sequential
        _ = self;
        _ = best_checkpoint;
        
        return error.NotImplemented;
    }
    
    /// Calculate distance between two event hashes
    fn distanceTo(self: Self, from: Hash, to: Hash) !usize {
        var count: usize = 0;
        var current = to;
        const zero_hash = [_]u8{0} ** 32;
        
        while (!std.mem.eql(u8, &current, &zero_hash)) {
            if (std.mem.eql(u8, &current, &from)) {
                return count;
            }
            
            if (self.events.getByHash(current)) |event| {
                current = event.parent;
                count += 1;
            } else {
                break;
            }
        }
        
        return std.math.maxInt(usize);
    }
    
    /// Parallel map over events
    pub fn parallelMap(
        self: Self,
        start: Hash,
        end: Hash,
        comptime T: type,
        map_fn: *const fn (Event) T,
        reduce_fn: *const fn (T, T) T,
    ) !T {
        // Collect events
        var events_list = std.ArrayList(Event).init(self.allocator);
        defer events_list.deinit();
        
        var current = end;
        while (!std.mem.eql(u8, &current, &start)) {
            const event = self.events.getByHash(current) orelse break;
            try events_list.append(event);
            current = event.parent;
        }
        
        // Process in parallel chunks
        const events_slice = events_list.items;
        const chunk_size = events_slice.len / self.thread_count + 1;
        
        // For now, sequential processing
        var result: T = undefined;
        var first = true;
        
        var i: usize = 0;
        while (i < events_slice.len) : (i += chunk_size) {
            const end_idx = @min(i + chunk_size, events_slice.len);
            
            var chunk_result: T = undefined;
            var chunk_first = true;
            
            for (events_slice[i..end_idx]) |event| {
                const mapped = map_fn(event);
                if (chunk_first) {
                    chunk_result = mapped;
                    chunk_first = false;
                } else {
                    chunk_result = reduce_fn(chunk_result, mapped);
                }
            }
            
            if (first) {
                result = chunk_result;
                first = false;
            } else {
                result = reduce_fn(result, chunk_result);
            }
        }
        
        return result;
    }
};

// ============================================================================
// INCREMENTAL RECONSTRUCTION
// ============================================================================

/// Incremental reconstruction that updates state efficiently
pub const IncrementalReconstructor = struct {
    allocator: Allocator,
    base_reconstructor: *StateReconstructor,
    pending_events: std.ArrayList(Event),
    last_computed: ?StateSnapshot,
    
    const Self = @This();
    
    pub fn init(allocator: Allocator, base: *StateReconstructor) Self {
        return .{
            .allocator = allocator,
            .base_reconstructor = base,
            .pending_events = std.ArrayList(Event).init(allocator),
            .last_computed = null,
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.pending_events.deinit();
        if (self.last_computed) |*snap| {
            self.allocator.free(snap.data);
        }
    }
    
    /// Add an event to be applied incrementally
    pub fn addEvent(self: *Self, event: Event) !void {
        try self.pending_events.append(event);
    }
    
    /// Compute or update state
    pub fn compute(self: *Self) !StateSnapshot {
        if (self.pending_events.items.len == 0) {
            if (self.last_computed) |snap| {
                var copy = snap;
                copy.data = try self.allocator.dupe(u8, snap.data);
                return copy;
            }
            return error.NoState;
        }
        
        // Start from base or last computed
        var state: []u8 = undefined;
        if (self.last_computed) |snap| {
            state = try self.allocator.dupe(u8, snap.data);
        } else {
            const last_pending = self.pending_events.items[self.pending_events.items.len - 1];
            const base = try self.base_reconstructor.reconstructAt(last_pending.parent);
            state = base.data;
            // Don't free base.data as we moved it to state
        }
        
        // Apply pending events
        for (self.pending_events.items) |event| {
            const new_state = try self.base_reconstructor.applyEvent(state, event);
            self.allocator.free(state);
            state = new_state;
        }
        
        // Update last computed
        if (self.last_computed) |*snap| {
            self.allocator.free(snap.data);
        }
        
        const last_event = self.pending_events.items[self.pending_events.items.len - 1];
        self.last_computed = StateSnapshot{
            .hash = undefined,
            .timestamp = last_event.timestamp,
            .seq = last_event.seq,
            .data = state,
            .event_hash = last_event.hash,
        };
        
        // Clear pending
        self.pending_events.clearRetainingCapacity();
        
        var result = self.last_computed.?;
        result.hash = StateSnapshot.computeHash(result.data, result.timestamp, result.seq);
        result.data = try self.allocator.dupe(u8, result.data);
        
        return result;
    }
    
    /// Reset incremental state
    pub fn reset(self: *Self) void {
        self.pending_events.clearRetainingCapacity();
        if (self.last_computed) |*snap| {
            self.allocator.free(snap.data);
            self.last_computed = null;
        }
    }
};

// ============================================================================
// VERIFICATION
// ============================================================================

/// Verifies reconstructed state matches expected
pub const StateVerifier = struct {
    allocator: Allocator,
    
    const Self = @This();
    
    pub fn init(allocator: Allocator) Self {
        return .{ .allocator = allocator };
    }
    
    /// Verify a range of events
    pub fn verifyRange(
        self: Self,
        reconstructor: *StateReconstructor,
        start_hash: Hash,
        end_hash: Hash,
        expected_hashes: []const Hash,
    ) !bool {
        _ = self;
        
        var current = end_hash;
        var idx: usize = expected_hashes.len;
        
        while (!std.mem.eql(u8, &current, &start_hash)) {
            if (idx == 0) return false;
            idx -= 1;
            
            const snapshot = reconstructor.reconstructAt(current) catch return false;
            defer reconstructor.allocator.free(snapshot.data);
            
            if (!std.mem.eql(u8, &snapshot.hash, &expected_hashes[idx])) {
                return false;
            }
            
            const event = reconstructor.events.getByHash(current) orelse return false;
            current = event.parent;
        }
        
        return true;
    }
    
    /// Verify entire chain integrity
    pub fn verifyChain(
        self: Self,
        events: *log.EventLog,
        head: Hash,
    ) !bool {
        _ = self;
        
        var current = head;
        const zero_hash = [_]u8{0} ** 32;
        var prev_hash = zero_hash;
        
        while (!std.mem.eql(u8, &current, &zero_hash)) {
            const event = events.getByHash(current) orelse return false;
            
            // Verify hash chain
            if (!std.mem.eql(u8, &event.parent, &prev_hash) and
                !std.mem.eql(u8, &prev_hash, &zero_hash)) {
                return false;
            }
            
            // Verify event hash
            if (!event.verifyHash()) {
                return false;
            }
            
            prev_hash = event.hash;
            current = event.parent;
        }
        
        return true;
    }
};

// ============================================================================
// TESTS
// ============================================================================

const testing = std.testing;

test "snapshot cache" {
    var cache = SnapshotCache.init(testing.allocator, 10);
    defer cache.deinit();
    
    const snap = StateSnapshot{
        .hash = [_]u8{0xAA} ** 32,
        .timestamp = 1000,
        .seq = 1,
        .data = "test state",
        .event_hash = [_]u8{0xBB} ** 32,
    };
    
    // Put
    try cache.put(snap);
    
    // Get
    const got = cache.get(snap.hash).?;
    try testing.expectEqualStrings(snap.data, got.data);
    
    // Stats
    const stats = cache.stats();
    try testing.expectEqual(@as(u64, 1), stats.hits);
    try testing.expectEqual(@as(usize, 1), stats.size);
}

test "state reconstructor" {
    var events = try log.EventLog.initInMemory(testing.allocator);
    defer events.deinit();
    
    var memory_store = MemoryStore.init(testing.allocator);
    defer memory_store.deinit();
    
    var reconstructor = StateReconstructor.init(testing.allocator, &events, &memory_store, 10);
    defer reconstructor.deinit();
    
    // Create some events
    const e1 = try events.append(.WorldCreated, "a://world", "{\"players\":[]}");
    const e2 = try events.append(.PlayerJoined, "a://world", "{\"player\":\"Alice\"}");
    const e3 = try events.append(.PlayerJoined, "a://world", "{\"player\":\"Bob\"}");
    
    // Reconstruct at e3
    const state = try reconstructor.reconstructAt(e3.hash);
    defer testing.allocator.free(state.data);
    
    try testing.expect(state.data.len > 0);
    try testing.expectEqual(@as(u64, 3), state.seq);
    
    // Reconstruct at e2 (should use cache for part)
    const state2 = try reconstructor.reconstructAt(e2.hash);
    defer testing.allocator.free(state2.data);
    
    try testing.expectEqual(@as(u64, 2), state2.seq);
    
    // Verify
    const verified = try reconstructor.verify(e3.hash, state.hash);
    try testing.expect(verified);
}

test "incremental reconstructor" {
    var events = try log.EventLog.initInMemory(testing.allocator);
    defer events.deinit();
    
    var memory_store = MemoryStore.init(testing.allocator);
    defer memory_store.deinit();
    
    var base = StateReconstructor.init(testing.allocator, &events, &memory_store, 10);
    defer base.deinit();
    
    var inc = IncrementalReconstructor.init(testing.allocator, &base);
    defer inc.deinit();
    
    // Add some events
    const e1 = try events.append(.WorldCreated, "a://world", "{\"init\":true}");
    _ = e1;
    
    const e2 = try events.append(.StateChanged, "a://world", "{\"x\":1}");
    try inc.addEvent(e2);
    
    // Compute
    const state = try inc.compute();
    defer testing.allocator.free(state.data);
    
    try testing.expectEqual(@as(u64, 2), state.seq);
}
