//! log.zig - Append-only event log for Ewig
//!
//! Append-only log with:
//! - Event struct with timestamp, type, payload
//! - Log append (never modify existing)
//! - Iterator over events (forward/backward)
//! - Event batching for efficiency
//! - Binary format with checksums

const std = @import("std");
const Allocator = std.mem.Allocator;
const format = @import("format.zig");

const EventHeader = format.EventHeader;
const EventType = format.EventType;
const Hash = format.Hash;
const computeHash = format.computeHash;
const computeChecksum = format.computeChecksum;

// ============================================================================
// EVENT STRUCT
// ============================================================================

/// A single event in the world history
pub const Event = struct {
    timestamp: i64,           // Nanoseconds since epoch
    seq: u64,                 // Sequence number (strictly increasing)
    hash: Hash,               // SHA-256 of event content
    parent: Hash,             // Previous event hash (forms chain)
    world_uri: []const u8,    // a://, b://, c://, etc.
    type: EventType,          // WorldCreated, StateChanged, PlayerAction, etc.
    payload: []const u8,      // Event-specific data
    
    const Self = @This();
    
    /// Compute the hash of this event (excluding the hash field itself)
    pub fn computeEventHash(self: Self) Hash {
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        
        // Hash all fields except hash itself
        hasher.update(std.mem.asBytes(&self.timestamp));
        hasher.update(std.mem.asBytes(&self.seq));
        hasher.update(&self.parent);
        hasher.update(self.world_uri);
        hasher.update(std.mem.asBytes(&self.type));
        hasher.update(self.payload);
        
        var hash: Hash = undefined;
        hasher.final(&hash);
        return hash;
    }
    
    /// Verify that the stored hash matches computed hash
    pub fn verifyHash(self: Self) bool {
        const computed = self.computeEventHash();
        return std.mem.eql(u8, &self.hash, &computed);
    }
    
    /// Convert to binary header format
    pub fn toHeader(self: Self) EventHeader {
        return .{
            .magic = "EVNT".*,
            .version = 1,
            .flags = 0,
            .type = self.type,
            .reserved = 0,
            .timestamp = self.timestamp,
            .seq = self.seq,
            .hash = self.hash,
            .parent = self.parent,
            .world_uri_len = @intCast(self.world_uri.len),
            .payload_len = @intCast(self.payload.len),
            .checksum = 0,
        };
    }
    
    /// Create from header and data
    pub fn fromHeader(header: EventHeader, world_uri: []const u8, payload: []const u8) Self {
        return .{
            .timestamp = header.timestamp,
            .seq = header.seq,
            .hash = header.hash,
            .parent = header.parent,
            .world_uri = world_uri,
            .type = header.type,
            .payload = payload,
        };
    }
};

/// Batch of events for efficient processing
pub const EventBatch = struct {
    allocator: Allocator,
    events: std.ArrayList(Event),
    max_size: usize,
    
    const Self = @This();
    
    pub fn init(allocator: Allocator, max_size: usize) Self {
        return .{
            .allocator = allocator,
            .events = std.ArrayList(Event).empty,
            .max_size = max_size,
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.events.deinit(self.allocator);
    }
    
    pub fn isFull(self: Self) bool {
        return self.events.items.len >= self.max_size;
    }
    
    pub fn isEmpty(self: Self) bool {
        return self.events.items.len == 0;
    }
    
    pub fn add(self: *Self, event: Event) !void {
        try self.events.append(self.allocator, event);
    }
    
    pub fn clear(self: *Self) void {
        self.events.clearRetainingCapacity();
    }
};

// ============================================================================
// APPEND-ONLY LOG
// ============================================================================

/// Append-only event log with crash-safe persistence
pub const EventLog = struct {
    allocator: Allocator,
    file: ?std.fs.File,
    path: []const u8,
    
    // In-memory index
    events: std.ArrayList(Event),
    hash_index: std.HashMap(Hash, usize, HashContext, std.hash_map.default_max_load_percentage),
    seq_index: std.HashMap(u64, usize, std.hash_map.AutoContext(u64), std.hash_map.default_max_load_percentage),
    
    // Current state
    last_hash: Hash,
    next_seq: u64,
    
    // Sync
    mutex: std.Thread.Mutex,
    
    const Self = @This();
    
    pub const HashContext = struct {
        pub fn hash(_: @This(), key: Hash) u64 {
            // Use first 8 bytes as hash
            return std.mem.readInt(u64, key[0..8], .little);
        }
        
        pub fn eql(_: @This(), a: Hash, b: Hash) bool {
            return std.mem.eql(u8, &a, &b);
        }
    };
    
    /// Open or create an event log at the given path
    pub fn init(allocator: Allocator, path: []const u8) !Self {
        const file = try std.fs.cwd().createFile(path, .{
            .read = true,
            .truncate = false,
        });
        errdefer file.close();
        
        var self = Self{
            .allocator = allocator,
            .file = file,
            .path = try allocator.dupe(u8, path),
            .events = std.ArrayList(Event).init(allocator),
            .hash_index = std.HashMap(Hash, usize, HashContext, std.hash_map.default_max_load_percentage).init(allocator),
            .seq_index = std.HashMap(u64, usize, std.hash_map.default_context, std.hash_map.default_max_load_percentage).init(allocator),
            .last_hash = [_]u8{0} ** 32,
            .next_seq = 1,
            .mutex = .{},
        };
        
        // Load existing events
        try self.loadFromDisk();
        
        return self;
    }
    
    /// Open in-memory log (no persistence)
    pub fn initInMemory(allocator: Allocator) !Self {
        return Self{
            .allocator = allocator,
            .file = null,
            .path = &.{},
            .events = std.ArrayList(Event).empty,
            .hash_index = std.HashMap(Hash, usize, HashContext, std.hash_map.default_max_load_percentage).init(allocator),
            .seq_index = std.HashMap(u64, usize, std.hash_map.AutoContext(u64), std.hash_map.default_max_load_percentage).init(allocator),
            .last_hash = [_]u8{0} ** 32,
            .next_seq = 1,
            .mutex = .{},
        };
    }
    
    pub fn deinit(self: *Self) void {
        if (self.file) |*f| {
            f.close();
        }
        self.allocator.free(self.path);
        
        // Free event data
        for (self.events.items) |event| {
            self.allocator.free(event.world_uri);
            self.allocator.free(event.payload);
        }
        
        self.events.deinit(self.allocator);
        self.hash_index.deinit();
        self.seq_index.deinit();
    }
    
    /// Append a new event to the log
    pub fn append(self: *Self, event_type: EventType, world_uri: []const u8, payload: []const u8) !Event {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        // Copy data
        const uri_copy = try self.allocator.dupe(u8, world_uri);
        errdefer self.allocator.free(uri_copy);
        
        const payload_copy = try self.allocator.dupe(u8, payload);
        errdefer self.allocator.free(payload_copy);
        
        const timestamp: i64 = @intCast(std.time.nanoTimestamp());
        
        var event = Event{
            .timestamp = timestamp,
            .seq = self.next_seq,
            .hash = undefined, // Will be computed
            .parent = self.last_hash,
            .world_uri = uri_copy,
            .type = event_type,
            .payload = payload_copy,
        };
        
        // Compute hash
        event.hash = event.computeEventHash();
        
        // Add to index
        const idx = self.events.items.len;
        try self.events.append(self.allocator, event);
        try self.hash_index.put(event.hash, idx);
        try self.seq_index.put(event.seq, idx);
        
        // Update state
        self.last_hash = event.hash;
        self.next_seq += 1;
        
        // Persist to disk
        if (self.file) |_| {
            try self.appendToDisk(event);
        }
        
        return event;
    }
    
    /// Append a batch of events efficiently
    pub fn appendBatch(self: *Self, batch: EventBatch) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        // TODO: Optimize batch persistence
        for (batch.events.items) |event| {
            const idx = self.events.items.len;
            try self.events.append(self.allocator, event);
            try self.hash_index.put(self.allocator, event.hash, idx);
            try self.seq_index.put(self.allocator, event.seq, idx);
            
            self.last_hash = event.hash;
            self.next_seq = event.seq + 1;
            
            if (self.file) |_| {
                try self.appendToDisk(event);
            }
        }
    }
    
    /// Get event by hash
    pub fn getByHash(self: *Self, hash: Hash) ?Event {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        const idx = self.hash_index.get(hash) orelse return null;
        return self.events.items[idx];
    }
    
    /// Get event by sequence number
    pub fn getBySeq(self: *Self, seq: u64) ?Event {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        const idx = self.seq_index.get(seq) orelse return null;
        return self.events.items[idx];
    }
    
    /// Get the latest event
    pub fn getLatest(self: *Self) ?Event {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        if (self.events.items.len == 0) return null;
        return self.events.items[self.events.items.len - 1];
    }
    
    /// Get total event count
    pub fn count(self: *Self) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.events.items.len;
    }
    
    /// Load events from disk
    fn loadFromDisk(self: *Self) !void {
        const f = self.file orelse return;
        
        const stat = try f.stat();
        if (stat.size == 0) return;
        
        try f.seekTo(0);
        var reader = f.reader();
        
        while (true) {
            // Read header (64 bytes)
            var header_buf: [64]u8 = undefined;
            reader.readNoEof(&header_buf) catch |err| switch (err) {
                error.EndOfStream => break,
                else => return err,
            };
            
            const header = format.deserializeHeader(header_buf) catch |err| {
                std.log.warn("Failed to deserialize header at offset {}: {}", .{ try f.getPos(), err });
                break;
            };
            
            // Read world URI
            const world_uri = try self.allocator.alloc(u8, header.world_uri_len);
            errdefer self.allocator.free(world_uri);
            try reader.readNoEof(world_uri);
            
            // Read payload
            const payload = try self.allocator.alloc(u8, header.payload_len);
            errdefer self.allocator.free(payload);
            try reader.readNoEof(payload);
            
            const event = Event.fromHeader(header, world_uri, payload);
            
            // Add to index
            const idx = self.events.items.len;
            try self.events.append(self.allocator, event);
            try self.hash_index.put(event.hash, idx);
            try self.seq_index.put(event.seq, idx);
            
            self.last_hash = event.hash;
            self.next_seq = event.seq + 1;
        }
    }
    
    /// Append single event to disk
    fn appendToDisk(self: *Self, event: Event) !void {
        const f = self.file.?;
        
        // Seek to end
        try f.seekFromEnd(0);
        
        // Write header with checksum
        var header = event.toHeader();
        header.checksum = format.computeChecksum(std.mem.asBytes(&header));
        const header_bytes = format.serializeHeader(header);
        
        var buf: [4096]u8 = undefined;
        var stream = std.io.fixedBufferStream(&buf);
        var writer = stream.writer();
        
        try writer.writeAll(&header_bytes);
        try writer.writeAll(event.world_uri);
        try writer.writeAll(event.payload);
        
        const written = stream.pos;
        _ = try f.write(buf[0..written]);
        
        // Sync to ensure durability
        try f.sync();
    }
    
    /// Verify integrity of entire log
    pub fn verify(self: *Self) !bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        var prev_hash = [_]u8{0} ** 32;
        
        for (self.events.items) |event| {
            // Verify hash chain
            if (!std.mem.eql(u8, &event.parent, &prev_hash)) {
                return false;
            }
            
            // Verify event hash
            if (!event.verifyHash()) {
                return false;
            }
            
            prev_hash = event.hash;
        }
        
        return true;
    }
};

// ============================================================================
// EVENT ITERATOR
// ============================================================================

/// Iterator over events in the log
pub const EventIterator = struct {
    log: *EventLog,
    direction: Direction,
    current: usize,
    end: usize,
    
    pub const Direction = enum {
        Forward,
        Backward,
    };
    
    const Self = @This();
    
    pub fn init(log: *EventLog, direction: Direction) Self {
        const count = log.count();
        return switch (direction) {
            .Forward => .{
                .log = log,
                .direction = direction,
                .current = 0,
                .end = count,
            },
            .Backward => .{
                .log = log,
                .direction = direction,
                .current = count,
                .end = 0,
            },
        };
    }
    
    pub fn initRange(log: *const EventLog, start_seq: u64, end_seq: u64) Self {
        const start_idx = log.seq_index.get(start_seq) orelse 0;
        const end_idx = log.seq_index.get(end_seq) orelse log.count();
        
        return .{
            .log = log,
            .direction = .Forward,
            .current = start_idx,
            .end = end_idx + 1,
        };
    }
    
    pub fn next(self: *Self) ?Event {
        switch (self.direction) {
            .Forward => {
                if (self.current >= self.end) return null;
                const event = self.log.events.items[self.current];
                self.current += 1;
                return event;
            },
            .Backward => {
                if (self.current == 0 or self.current <= self.end) return null;
                self.current -= 1;
                return self.log.events.items[self.current];
            },
        }
    }
    
    pub fn reset(self: *Self) void {
        switch (self.direction) {
            .Forward => {
                self.current = 0;
                self.end = self.log.count();
            },
            .Backward => {
                self.current = self.log.count();
                self.end = 0;
            },
        }
    }
};

// ============================================================================
// FILTERED ITERATOR
// ============================================================================

/// Iterator that filters events by criteria
pub const FilteredIterator = struct {
    inner: EventIterator,
    filter: Filter,
    
    pub const Filter = struct {
        event_type: ?EventType = null,
        world_uri: ?[]const u8 = null,
        start_time: ?i64 = null,
        end_time: ?i64 = null,
        
        pub fn matches(self: Filter, event: Event) bool {
            if (self.event_type) |t| {
                if (event.type != t) return false;
            }
            if (self.world_uri) |uri| {
                if (!std.mem.eql(u8, event.world_uri, uri)) return false;
            }
            if (self.start_time) |t| {
                if (event.timestamp < t) return false;
            }
            if (self.end_time) |t| {
                if (event.timestamp > t) return false;
            }
            return true;
        }
    };
    
    const Self = @This();
    
    pub fn init(log: *const EventLog, direction: EventIterator.Direction, filter: Filter) Self {
        return .{
            .inner = EventIterator.init(log, direction),
            .filter = filter,
        };
    }
    
    pub fn next(self: *Self) ?Event {
        while (self.inner.next()) |event| {
            if (self.filter.matches(event)) {
                return event;
            }
        }
        return null;
    }
};

// ============================================================================
// TESTS
// ============================================================================

const testing = std.testing;

test "event hash verification" {
    const event = Event{
        .timestamp = 1699123456789,
        .seq = 1,
        .hash = undefined,
        .parent = [_]u8{0} ** 32,
        .world_uri = "a://test",
        .type = .WorldCreated,
        .payload = "{}",
    };
    
    var event_with_hash = event;
    event_with_hash.hash = event.computeEventHash();
    
    try testing.expect(event_with_hash.verifyHash());
}

test "in-memory event log" {
    var log = try EventLog.initInMemory(testing.allocator);
    defer log.deinit();
    
    // Append some events
    const e1 = try log.append(.WorldCreated, "a://world1", "{}");
    try testing.expectEqual(@as(u64, 1), e1.seq);
    
    const e2 = try log.append(.StateChanged, "a://world1", "{\"x\":1}");
    try testing.expectEqual(@as(u64, 2), e2.seq);
    
    // Verify retrieval
    const got_e1 = log.getBySeq(1).?;
    try testing.expectEqual(e1.seq, got_e1.seq);
    try testing.expectEqualStrings(e1.world_uri, got_e1.world_uri);
    
    const got_e2 = log.getByHash(e2.hash).?;
    try testing.expectEqual(e2.seq, got_e2.seq);
    
    // Verify chain
    try testing.expect(std.mem.eql(u8, &e2.parent, &e1.hash));
}

test "event iterator" {
    var log = try EventLog.initInMemory(testing.allocator);
    defer log.deinit();
    
    _ = try log.append(.WorldCreated, "a://world1", "{}");
    _ = try log.append(.StateChanged, "a://world1", "{\"x\":1}");
    _ = try log.append(.PlayerAction, "a://world1", "{\"action\":\"jump\"}");
    
    // Forward iteration
    var forward = EventIterator.init(&log, .Forward);
    var count: usize = 0;
    while (forward.next()) |_| {
        count += 1;
    }
    try testing.expectEqual(@as(usize, 3), count);
    
    // Backward iteration
    var backward = EventIterator.init(&log, .Backward);
    count = 0;
    while (backward.next()) |_| {
        count += 1;
    }
    try testing.expectEqual(@as(usize, 3), count);
}

test "log integrity verification" {
    var log = try EventLog.initInMemory(testing.allocator);
    defer log.deinit();
    
    _ = try log.append(.WorldCreated, "a://world1", "{}");
    _ = try log.append(.StateChanged, "a://world1", "{\"x\":1}");
    
    try testing.expect(try log.verify());
}
