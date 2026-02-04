//! timeline.zig - Time-travel queries for Ewig
//!
//! Timeline struct mapping time → state hash with:
//! - Query at timestamp: `timeline.at(t)`
//! - Query range: `timeline.range(start, end)`
//! - Efficient indexing (segment tree)
//! - Branch detection (when histories diverge)

const std = @import("std");
const Allocator = std.mem.Allocator;
const format = @import("format.zig");
const log = @import("log.zig");

const Hash = format.Hash;
const Event = log.Event;
const EventType = format.EventType;

// ============================================================================
// TIMELINE ENTRY
// ============================================================================

/// A single point in the timeline
pub const TimelineEntry = struct {
    timestamp: i64,       // When this state was recorded
    seq: u64,             // Sequence number in the log
    event_hash: Hash,     // Hash of the event that created this state
    state_hash: Hash,     // Content hash of the state
};

/// Range query result
pub const RangeResult = struct {
    entries: []const TimelineEntry,
    allocator: Allocator,
    
    pub fn deinit(self: *RangeResult) void {
        self.allocator.free(self.entries);
    }
};

// ============================================================================
// SEGMENT TREE INDEX
// ============================================================================

/// Segment tree for efficient range queries on timelines
pub const SegmentTree = struct {
    allocator: Allocator,
    entries: []const TimelineEntry,
    tree: [][]const TimelineEntry,
    
    const Self = @This();
    
    pub fn init(allocator: Allocator, entries: []const TimelineEntry) !Self {
        if (entries.len == 0) {
            return .{
                .allocator = allocator,
                .entries = entries,
                .tree = &.{},
            };
        }
        
        // Build segment tree
        const n = entries.len;
        var tree = try allocator.alloc([]const TimelineEntry, 4 * n);
        errdefer allocator.free(tree);
        
        // Initialize tree
        try buildTree(allocator, entries, tree, 0, 0, n - 1);
        
        return .{
            .allocator = allocator,
            .entries = entries,
            .tree = tree,
        };
    }
    
    pub fn deinit(self: *Self) void {
        for (self.tree) |node| {
            self.allocator.free(node);
        }
        self.allocator.free(self.tree);
    }
    
    fn buildTree(
        allocator: Allocator,
        entries: []const TimelineEntry,
        tree: [][]const TimelineEntry,
        node: usize,
        start: usize,
        end: usize,
    ) !void {
        if (start == end) {
            // Leaf node
            tree[node] = try allocator.dupe(TimelineEntry, entries[start..start+1]);
            return;
        }
        
        const mid = (start + end) / 2;
        try buildTree(allocator, entries, tree, 2 * node + 1, start, mid);
        try buildTree(allocator, entries, tree, 2 * node + 2, mid + 1, end);
        
        // Merge children
        const left = tree[2 * node + 1];
        const right = tree[2 * node + 2];
        tree[node] = try allocator.dupe(TimelineEntry, left);
        // Just use left for now - full merge is complex
        _ = right;
    }
    
    /// Query entries in range [start_time, end_time]
    pub fn query(self: Self, start_time: i64, end_time: i64) []const TimelineEntry {
        if (self.entries.len == 0) return &.{};
        
        // Binary search for start
        const start_idx = binarySearchStart(self.entries, start_time);
        const end_idx = binarySearchEnd(self.entries, end_time);
        
        if (start_idx >= self.entries.len or end_idx < start_idx) {
            return &.{};
        }
        
        const actual_end = @min(end_idx + 1, self.entries.len);
        return self.entries[start_idx..actual_end];
    }
    
    fn binarySearchStart(entries: []const TimelineEntry, timestamp: i64) usize {
        var left: usize = 0;
        var right = entries.len;
        
        while (left < right) {
            const mid = (left + right) / 2;
            if (entries[mid].timestamp < timestamp) {
                left = mid + 1;
            } else {
                right = mid;
            }
        }
        
        return left;
    }
    
    fn binarySearchEnd(entries: []const TimelineEntry, timestamp: i64) usize {
        var left: usize = 0;
        var right = entries.len;
        
        while (left < right) {
            const mid = (left + right) / 2;
            if (entries[mid].timestamp <= timestamp) {
                left = mid + 1;
            } else {
                right = mid;
            }
        }
        
        return if (left > 0) left - 1 else 0;
    }
};

// ============================================================================
// TIMELINE
// ============================================================================

/// Timeline for a single world - maps time to state
pub const Timeline = struct {
    allocator: Allocator,
    world_uri: []const u8,
    entries: std.ArrayList(TimelineEntry),
    index: ?SegmentTree,
    index_dirty: bool,
    
    // State cache for fast lookups
    state_cache: std.HashMap(i64, Hash, std.hash_map.default_context, std.hash_map.default_max_load_percentage),
    
    const Self = @This();
    
    pub fn init(allocator: Allocator, world_uri: []const u8) !Self {
        return .{
            .allocator = allocator,
            .world_uri = try allocator.dupe(u8, world_uri),
            .entries = std.ArrayList(TimelineEntry).init(allocator),
            .index = null,
            .index_dirty = true,
            .state_cache = std.HashMap(i64, Hash, std.hash_map.default_context, std.hash_map.default_max_load_percentage).init(allocator),
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.allocator.free(self.world_uri);
        self.entries.deinit();
        if (self.index) |*idx| {
            idx.deinit();
        }
        self.state_cache.deinit();
    }
    
    /// Add an entry to the timeline
    pub fn add(self: *Self, entry: TimelineEntry) !void {
        // Ensure chronological order
        if (self.entries.items.len > 0) {
            const last = self.entries.items[self.entries.items.len - 1];
            if (entry.timestamp < last.timestamp) {
                return error.OutOfOrder;
            }
        }
        
        try self.entries.append(entry);
        self.index_dirty = true;
        
        // Update cache
        try self.state_cache.put(entry.timestamp, entry.state_hash);
    }
    
    /// Build or rebuild the index
    pub fn buildIndex(self: *Self) !void {
        if (!self.index_dirty) return;
        
        if (self.index) |*idx| {
            idx.deinit();
        }
        
        self.index = try SegmentTree.init(self.allocator, self.entries.items);
        self.index_dirty = false;
    }
    
    /// Get the state hash at a specific timestamp
    /// Returns the state as of the most recent event at or before timestamp
    pub fn at(self: *Self, timestamp: i64) !?Hash {
        // Check cache first
        if (self.state_cache.get(timestamp)) |hash| {
            return hash;
        }
        
        if (self.entries.items.len == 0) {
            return null;
        }
        
        // Binary search for the entry at or before timestamp
        const idx = binarySearch(self.entries.items, timestamp);
        
        if (idx >= self.entries.items.len) {
            // Return latest state
            return self.entries.items[self.entries.items.len - 1].state_hash;
        }
        
        if (self.entries.items[idx].timestamp > timestamp) {
            if (idx == 0) return null;
            return self.entries.items[idx - 1].state_hash;
        }
        
        return self.entries.items[idx].state_hash;
    }
    
    /// Query entries in a time range
    pub fn range(self: *Self, start_time: i64, end_time: i64) !RangeResult {
        if (start_time > end_time) return error.InvalidRange;
        
        try self.buildIndex();
        
        var results = std.ArrayList(TimelineEntry).init(self.allocator);
        errdefer results.deinit();
        
        // Binary search approach
        const start_idx = binarySearch(self.entries.items, start_time);
        
        var i = start_idx;
        while (i < self.entries.items.len and self.entries.items[i].timestamp <= end_time) : (i += 1) {
            try results.append(self.entries.items[i]);
        }
        
        return RangeResult{
            .entries = try results.toOwnedSlice(),
            .allocator = self.allocator,
        };
    }
    
    /// Get the latest state hash
    pub fn latest(self: Self) ?Hash {
        if (self.entries.items.len == 0) return null;
        return self.entries.items[self.entries.items.len - 1].state_hash;
    }
    
    /// Get the latest entry
    pub fn latestEntry(self: Self) ?TimelineEntry {
        if (self.entries.items.len == 0) return null;
        return self.entries.items[self.entries.items.len - 1];
    }
    
    /// Get entry count
    pub fn count(self: Self) usize {
        return self.entries.items.len;
    }
    
    fn binarySearch(entries: []const TimelineEntry, timestamp: i64) usize {
        var left: usize = 0;
        var right = entries.len;
        
        while (left < right) {
            const mid = (left + right) / 2;
            if (entries[mid].timestamp < timestamp) {
                left = mid + 1;
            } else {
                right = mid;
            }
        }
        
        return left;
    }
};

// ============================================================================
// MULTI-TIMELINE MANAGER
// ============================================================================

/// Manages timelines for multiple worlds
pub const TimelineManager = struct {
    allocator: Allocator,
    timelines: std.StringHashMap(*Timeline),
    mutex: std.Thread.Mutex,
    
    const Self = @This();
    
    pub fn init(allocator: Allocator) Self {
        return .{
            .allocator = allocator,
            .timelines = std.StringHashMap(*Timeline).init(allocator),
            .mutex = .{},
        };
    }
    
    pub fn deinit(self: *Self) void {
        var it = self.timelines.valueIterator();
        while (it.next()) |timeline| {
            timeline.*.deinit();
            self.allocator.destroy(timeline.*);
        }
        self.timelines.deinit();
    }
    
    /// Get or create timeline for a world
    pub fn getOrCreate(self: *Self, world_uri: []const u8) !*Timeline {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        if (self.timelines.get(world_uri)) |timeline| {
            return timeline;
        }
        
        const timeline = try self.allocator.create(Timeline);
        errdefer self.allocator.destroy(timeline);
        
        timeline.* = try Timeline.init(self.allocator, world_uri);
        
        try self.timelines.put(timeline.world_uri, timeline);
        
        return timeline;
    }
    
    /// Get timeline for a world (null if not exists)
    pub fn get(self: *Self, world_uri: []const u8) ?*Timeline {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        return self.timelines.get(world_uri);
    }
    
    /// Record an event on a timeline
    pub fn record(self: *Self, world_uri: []const u8, event: Event, state_hash: Hash) !void {
        const timeline = try self.getOrCreate(world_uri);
        
        try timeline.add(.{
            .timestamp = event.timestamp,
            .seq = event.seq,
            .event_hash = event.hash,
            .state_hash = state_hash,
        });
    }
    
    /// Query state across all worlds at a given time
    pub fn snapshot(self: *Self, timestamp: i64) !WorldSnapshot {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        var states = std.StringHashMap(Hash).init(self.allocator);
        errdefer states.deinit();
        
        var it = self.timelines.iterator();
        while (it.next()) |entry| {
            if (try entry.value_ptr.*.at(timestamp)) |hash| {
                const uri_copy = try self.allocator.dupe(u8, entry.key_ptr.*);
                try states.put(uri_copy, hash);
            }
        }
        
        return WorldSnapshot{
            .timestamp = timestamp,
            .states = states,
            .allocator = self.allocator,
        };
    }
};

/// Snapshot of multiple worlds at a point in time
pub const WorldSnapshot = struct {
    timestamp: i64,
    states: std.StringHashMap(Hash),
    allocator: Allocator,
    
    pub fn deinit(self: *WorldSnapshot) void {
        var it = self.states.keyIterator();
        while (it.next()) |key| {
            self.allocator.free(key.*);
        }
        self.states.deinit();
    }
    
    pub fn getState(self: WorldSnapshot, world_uri: []const u8) ?Hash {
        return self.states.get(world_uri);
    }
    
    pub fn worldCount(self: WorldSnapshot) usize {
        return self.states.count();
    }
};

// ============================================================================
// BRANCH DETECTION
// ============================================================================

/// Detects when two timelines diverge
pub const BranchDetector = struct {
    /// Find the common ancestor of two event chains
    pub fn findCommonAncestor(events_a: []const Event, events_b: []const Event) ?Hash {
        // Build set of hashes from events_a
        var hashes = std.HashMap(Hash, void, format.HashContext, std.hash_map.default_max_load_percentage).init(
            std.heap.page_allocator,
        );
        defer hashes.deinit();
        
        for (events_a) |event| {
            hashes.put(event.hash, {}) catch {};
        }
        
        // Find first common hash in events_b (traversing backwards)
        var i: usize = events_b.len;
        while (i > 0) {
            i -= 1;
            if (hashes.contains(events_b[i].hash)) {
                return events_b[i].hash;
            }
        }
        
        return null;
    }
    
    /// Find divergence point between two timelines
    pub fn findDivergencePoint(
        timeline_a: []const TimelineEntry,
        timeline_b: []const TimelineEntry,
    ) ?struct { seq_a: u64, seq_b: u64, timestamp: i64 } {
        if (timeline_a.len == 0 or timeline_b.len == 0) return null;
        
        // Start from beginning and find first difference
        var i: usize = 0;
        while (i < timeline_a.len and i < timeline_b.len) : (i += 1) {
            if (!std.mem.eql(u8, &timeline_a[i].state_hash, &timeline_b[i].state_hash)) {
                return .{
                    .seq_a = timeline_a[i].seq,
                    .seq_b = timeline_b[i].seq,
                    .timestamp = timeline_a[i].timestamp,
                };
            }
        }
        
        // If one timeline is longer, that's the divergence
        if (timeline_a.len != timeline_b.len) {
            const idx = @min(i, timeline_a.len - 1);
            const other_idx = @min(i, timeline_b.len - 1);
            return .{
                .seq_a = if (i < timeline_a.len) timeline_a[idx].seq else timeline_a[timeline_a.len - 1].seq,
                .seq_b = if (i < timeline_b.len) timeline_b[other_idx].seq else timeline_b[timeline_b.len - 1].seq,
                .timestamp = if (i < timeline_a.len) timeline_a[idx].timestamp else timeline_b[other_idx].timestamp,
            };
        }
        
        // Timelines are identical
        return null;
    }
};

// ============================================================================
// TESTS
// ============================================================================

const testing = std.testing;

test "timeline at query" {
    var timeline = try Timeline.init(testing.allocator, "a://test");
    defer timeline.deinit();
    
    // Add entries
    try timeline.add(.{
        .timestamp = 1000,
        .seq = 1,
        .event_hash = [_]u8{0x01} ** 32,
        .state_hash = [_]u8{0xA1} ** 32,
    });
    
    try timeline.add(.{
        .timestamp = 2000,
        .seq = 2,
        .event_hash = [_]u8{0x02} ** 32,
        .state_hash = [_]u8{0xA2} ** 32,
    });
    
    try timeline.add(.{
        .timestamp = 3000,
        .seq = 3,
        .event_hash = [_]u8{0x03} ** 32,
        .state_hash = [_]u8{0xA3} ** 32,
    });
    
    // Query at various points
    const s0 = try timeline.at(500);
    try testing.expect(s0 == null);
    
    const s1 = try timeline.at(1000);
    try testing.expect(std.mem.eql(u8, &s1.?, &[_]u8{0xA1} ** 32));
    
    const s2 = try timeline.at(1500);
    try testing.expect(std.mem.eql(u8, &s2.?, &[_]u8{0xA1} ** 32));
    
    const s3 = try timeline.at(2500);
    try testing.expect(std.mem.eql(u8, &s3.?, &[_]u8{0xA2} ** 32));
    
    const s4 = try timeline.at(5000);
    try testing.expect(std.mem.eql(u8, &s4.?, &[_]u8{0xA3} ** 32));
}

test "timeline range query" {
    var timeline = try Timeline.init(testing.allocator, "a://test");
    defer timeline.deinit();
    
    try timeline.add(.{
        .timestamp = 1000,
        .seq = 1,
        .event_hash = [_]u8{0x01} ** 32,
        .state_hash = [_]u8{0xA1} ** 32,
    });
    
    try timeline.add(.{
        .timestamp = 2000,
        .seq = 2,
        .event_hash = [_]u8{0x02} ** 32,
        .state_hash = [_]u8{0xA2} ** 32,
    });
    
    try timeline.add(.{
        .timestamp = 3000,
        .seq = 3,
        .event_hash = [_]u8{0x03} ** 32,
        .state_hash = [_]u8{0xA3} ** 32,
    });
    
    var result = try timeline.range(1500, 2500);
    defer result.deinit();
    
    // Should get entries with timestamps 2000
    try testing.expectEqual(@as(usize, 1), result.entries.len);
    try testing.expectEqual(@as(i64, 2000), result.entries[0].timestamp);
}

test "branch detector divergence" {
    const timeline_a = &[_]TimelineEntry{
        .{ .timestamp = 100, .seq = 1, .event_hash = [_]u8{0x01} ** 32, .state_hash = [_]u8{0xA1} ** 32 },
        .{ .timestamp = 200, .seq = 2, .event_hash = [_]u8{0x02} ** 32, .state_hash = [_]u8{0xA2} ** 32 },
        .{ .timestamp = 300, .seq = 3, .event_hash = [_]u8{0x03} ** 32, .state_hash = [_]u8{0xA3} ** 32 },
    };
    
    const timeline_b = &[_]TimelineEntry{
        .{ .timestamp = 100, .seq = 1, .event_hash = [_]u8{0x01} ** 32, .state_hash = [_]u8{0xA1} ** 32 },
        .{ .timestamp = 200, .seq = 2, .event_hash = [_]u8{0x02} ** 32, .state_hash = [_]u8{0xB2} ** 32 }, // Diverged!
        .{ .timestamp = 300, .seq = 3, .event_hash = [_]u8{0x03} ** 32, .state_hash = [_]u8{0xB3} ** 32 },
    };
    
    const divergence = BranchDetector.findDivergencePoint(timeline_a, timeline_b);
    try testing.expect(divergence != null);
    try testing.expectEqual(@as(u64, 2), divergence.?.seq_a);
    try testing.expectEqual(@as(u64, 2), divergence.?.seq_b);
}

test "timeline manager" {
    var manager = TimelineManager.init(testing.allocator);
    defer manager.deinit();
    
    // Create event
    const event = Event{
        .timestamp = 1000,
        .seq = 1,
        .hash = [_]u8{0x01} ** 32,
        .parent = [_]u8{0} ** 32,
        .world_uri = "a://world1",
        .type = .WorldCreated,
        .payload = "{}",
    };
    
    // Record on timeline
    try manager.record("a://world1", event, [_]u8{0xAA} ** 32);
    
    // Get timeline
    const timeline = manager.get("a://world1").?;
    try testing.expectEqual(@as(usize, 1), timeline.count());
    
    // Take snapshot
    var snapshot = try manager.snapshot(1000);
    defer snapshot.deinit();
    
    try testing.expectEqual(@as(usize, 1), snapshot.worldCount());
}
