//! ewig.zig - Eternal/forever persistent storage for world history
//!
//! Ewig provides:
//! - Append-only event log for immutable history
//! - Content-addressed storage with Merkle DAG
//! - Time-travel queries to any point in history
//! - Git-like branching and merging
//! - State reconstruction with caching
//! - Multi-node synchronization
//! - SQL-like query interface
//!
//! Example usage:
//! ```zig
//! var ewig = try Ewig.init(allocator, ".ewig_data");
//! defer ewig.deinit();
//!
//! // Append event
//! const event = try ewig.append(.{
//!     .world_uri = "a://baseline",
//!     .type = .PlayerAction,
//!     .payload = action_data,
//! });
//!
//! // Get state at time T
//! const state = try ewig.timeline("a://baseline").at(1699123456789);
//!
//! // Branch history
//! const branch_point = try ewig.branch("a://baseline", "experiment-1", event.hash);
//! ```

const std = @import("std");
const Allocator = std.mem.Allocator;

// Sub-modules
pub const format = @import("format.zig");
pub const log = @import("log.zig");
pub const store = @import("store.zig");
pub const timeline = @import("timeline.zig");
pub const branch = @import("branch.zig");
pub const reconstruct = @import("reconstruct.zig");
pub const sync = @import("sync.zig");
pub const query = @import("query.zig");

// Re-export common types
pub const Event = log.Event;
pub const EventType = format.EventType;
pub const EventLog = log.EventLog;
pub const EventBatch = log.EventBatch;
pub const EventIterator = log.EventIterator;
pub const FilteredIterator = log.FilteredIterator;
pub const Filter = log.FilteredIterator.Filter;

pub const Hash = format.Hash;
pub const HashContext = format.HashContext;
pub const computeHash = format.computeHash;
pub const combineHashes = format.combineHashes;
pub const hashToHex = format.hashToHex;
pub const hexToHash = format.hexToHash;

pub const MemoryStore = store.MemoryStore;
pub const FileStore = store.FileStore;
pub const MerkleTree = store.MerkleTree;
pub const MerkleNode = store.MerkleNode;
pub const CAS = store.CAS;

pub const Timeline = timeline.Timeline;
pub const TimelineEntry = timeline.TimelineEntry;
pub const TimelineManager = timeline.TimelineManager;
pub const WorldSnapshot = timeline.WorldSnapshot;
pub const BranchDetector = timeline.BranchDetector;
pub const RangeResult = timeline.RangeResult;

pub const Branch = branch.Branch;
pub const BranchManager = branch.BranchManager;
pub const MergeEngine = branch.MergeEngine;
pub const MergeResult = branch.MergeResult;
pub const MergeStrategy = branch.MergeEngine.MergeStrategy;
pub const Conflict = branch.Conflict;
pub const BranchVisualizer = branch.BranchVisualizer;

pub const StateSnapshot = reconstruct.StateSnapshot;
pub const SnapshotCache = reconstruct.SnapshotCache;
pub const StateReconstructor = reconstruct.StateReconstructor;
pub const IncrementalReconstructor = reconstruct.IncrementalReconstructor;
pub const ParallelReconstructor = reconstruct.ParallelReconstructor;
pub const StateVerifier = reconstruct.StateVerifier;

pub const SyncEngine = sync.SyncEngine;
pub const SyncResult = sync.SyncResult;
pub const SyncMessage = sync.SyncMessage;
pub const MerkleSync = sync.MerkleSync;
pub const DeltaEncoder = sync.DeltaEncoder;
pub const CRDTMerge = sync.CRDTMerge;

pub const Query = query.Query;
pub const QueryExecutor = query.QueryExecutor;
pub const QueryResult = query.QueryResult;
pub const QueryParser = query.QueryParser;
pub const Expr = query.Expr;
pub const Value = query.Value;
pub const BinaryOp = query.BinaryOp;
pub const AggregateFunction = query.AggregateFunction;

// ============================================================================
// MAIN EWIG API
// ============================================================================

/// Main Ewig storage system
pub const Ewig = struct {
    allocator: Allocator,
    base_path: []const u8,
    
    // Core components
    event_log: EventLog,
    storage: MemoryStore,
    timelines: TimelineManager,
    branches: BranchManager,
    
    // Reconstruction
    reconstructor: StateReconstructor,
    
    // Query
    executor: QueryExecutor,
    
    // Configuration
    config: Config,
    
    const Self = @This();
    
    pub const Config = struct {
        cache_size: usize = 1000,
        sync_strategy: sync.SyncEngine.ConflictStrategy = .Timestamp,
    };
    
    /// Initialize Ewig storage system
    pub fn init(allocator: Allocator, base_path: []const u8, config: Config) !Self {
        // Create directory if needed
        try std.fs.cwd().makePath(base_path);
        
        // Open event log
        const log_path = try std.fs.path.join(allocator, &.{ base_path, "events.log" });
        defer allocator.free(log_path);
        
        var event_log = try EventLog.init(allocator, log_path);
        errdefer event_log.deinit();
        
        var storage = MemoryStore.init(allocator);
        errdefer storage.deinit();
        
        var timelines = TimelineManager.init(allocator);
        errdefer timelines.deinit();
        
        var branches = try BranchManager.init(allocator, "main");
        errdefer branches.deinit();
        
        var reconstructor = StateReconstructor.init(
            allocator,
            &event_log,
            &storage,
            config.cache_size,
        );
        errdefer reconstructor.deinit();
        
        return .{
            .allocator = allocator,
            .base_path = try allocator.dupe(u8, base_path),
            .event_log = event_log,
            .storage = storage,
            .timelines = timelines,
            .branches = branches,
            .reconstructor = reconstructor,
            .executor = QueryExecutor.init(allocator),
            .config = config,
        };
    }
    
    /// Initialize in-memory Ewig (no persistence)
    pub fn initInMemory(allocator: Allocator, config: Config) !Self {
        var event_log = try EventLog.initInMemory(allocator);
        errdefer event_log.deinit();
        
        var storage = MemoryStore.init(allocator);
        errdefer storage.deinit();
        
        var timelines = TimelineManager.init(allocator);
        errdefer timelines.deinit();
        
        var branches = try BranchManager.init(allocator, "main");
        errdefer branches.deinit();
        
        var reconstructor = StateReconstructor.init(
            allocator,
            &event_log,
            &storage,
            config.cache_size,
        );
        errdefer reconstructor.deinit();
        
        return .{
            .allocator = allocator,
            .base_path = &.{},
            .event_log = event_log,
            .storage = storage,
            .timelines = timelines,
            .branches = branches,
            .reconstructor = reconstructor,
            .executor = QueryExecutor.init(allocator),
            .config = config,
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.allocator.free(self.base_path);
        self.event_log.deinit();
        self.storage.deinit();
        self.timelines.deinit();
        self.branches.deinit();
        self.reconstructor.deinit();
    }
    
    // ========================================================================
    // EVENT OPERATIONS
    // ========================================================================
    
    /// Append a new event
    pub fn append(self: *Self, event_type: EventType, world_uri: []const u8, payload: []const u8) !Event {
        const event = try self.event_log.append(event_type, world_uri, payload);
        
        // Update timeline
        // State hash would be computed from reconstruction
        const state_hash = event.hash; // Simplified
        try self.timelines.record(world_uri, event, state_hash);
        
        // Update branch head if this is the active branch
        if (self.branches.getActiveBranch()) |b| {
            if (std.mem.eql(u8, b.world_uri, world_uri)) {
                b.head = event.hash;
            }
        }
        
        return event;
    }
    
    /// Append with struct payload (auto-serialized to JSON)
    pub fn appendStruct(self: *Self, event_type: EventType, world_uri: []const u8, payload: anytype) !Event {
        const json = try std.json.stringifyAlloc(self.allocator, payload, .{});
        defer self.allocator.free(json);
        return self.append(event_type, world_uri, json);
    }
    
    /// Get event by hash
    pub fn getEvent(self: *Self, hash: Hash) ?Event {
        return self.event_log.getByHash(hash);
    }
    
    /// Get latest event
    pub fn getLatest(self: *Self) ?Event {
        return self.event_log.getLatest();
    }
    
    /// Get event count
    pub fn eventCount(self: *Self) usize {
        return self.event_log.count();
    }
    
    /// Create event iterator
    pub fn iterator(self: *Self, direction: EventIterator.Direction) EventIterator {
        return EventIterator.init(&self.event_log, direction);
    }
    
    /// Create filtered iterator
    pub fn filter(self: *Self, direction: EventIterator.Direction, f: Filter) FilteredIterator {
        return FilteredIterator.init(&self.event_log, direction, f);
    }
    
    // ========================================================================
    // STATE OPERATIONS
    // ========================================================================
    
    /// Get state hash at a specific time
    pub fn at(self: *Self, world_uri: []const u8, timestamp: i64) !?Hash {
        const timeline_obj = self.timelines.get(world_uri) orelse return null;
        return timeline_obj.at(timestamp);
    }
    
    /// Get state in a time range
    pub fn range(self: *Self, world_uri: []const u8, start: i64, end: i64) !timeline.RangeResult {
        const timeline_obj = self.timelines.get(world_uri) orelse {
            return timeline.RangeResult{
                .entries = &.{},
                .allocator = self.allocator,
            };
        };
        return timeline_obj.range(start, end);
    }
    
    /// Get the latest state hash for a world
    pub fn latest(self: *Self, world_uri: []const u8) ?Hash {
        const timeline_obj = self.timelines.get(world_uri) orelse return null;
        return timeline_obj.latest();
    }
    
    /// Reconstruct full state at a specific event
    pub fn reconstruct(self: *Self, event_hash: Hash) !StateSnapshot {
        return self.reconstructor.reconstructAt(event_hash);
    }
    
    /// Create a checkpoint (snapshot)
    pub fn checkpoint(self: *Self, event_hash: Hash) !Hash {
        return self.reconstructor.checkpoint(event_hash);
    }
    
    // ========================================================================
    // BRANCH OPERATIONS
    // ========================================================================
    
    /// Create a new branch
    pub fn createBranch(self: *Self, name: []const u8, world_uri: []const u8, from_hash: Hash) !*Branch {
        return self.branches.createBranch(name, world_uri, from_hash);
    }
    
    /// Get branch by name
    pub fn getBranch(self: *Self, name: []const u8) ?*Branch {
        return self.branches.getBranch(name);
    }
    
    /// Switch to a branch
    pub fn switchBranch(self: *Self, name: []const u8) !void {
        return self.branches.switchBranch(name);
    }
    
    /// Get active branch
    pub fn getActiveBranch(self: *Self) ?*Branch {
        return self.branches.getActiveBranch();
    }
    
    /// Merge branches
    pub fn merge(self: *Self, branch_name: []const u8, strategy: MergeStrategy) !MergeResult {
        const target_branch = self.branches.getBranch(branch_name) orelse return error.BranchNotFound;
        const current_branch = self.branches.getActiveBranch() orelse return error.NoActiveBranch;
        
        const engine = MergeEngine.init(self.allocator);
        return engine.merge(
            target_branch.base_hash,
            current_branch.head,
            target_branch.head,
            &self.event_log,
            strategy,
        );
    }
    
    /// Visualize branch history
    pub fn visualizeBranches(self: *Self) ![]u8 {
        const viz = BranchVisualizer.init(self.allocator);
        return viz.visualize(&self.branches, &self.event_log);
    }
    
    // ========================================================================
    // QUERY OPERATIONS
    // ========================================================================
    
    /// Execute a query
    pub fn query(self: *Self, q: Query) !QueryResult {
        return self.executor.execute(q, &self.event_log);
    }
    
    /// Query with SQL-like string
    pub fn querySql(self: *Self, sql: []const u8) !QueryResult {
        var parser = QueryParser.init(self.allocator, sql);
        var q = try parser.parse();
        defer q.deinit(self.allocator);
        return self.executor.execute(q, &self.event_log);
    }
    
    /// Query events by type
    pub fn queryByType(self: *Self, event_type: EventType, limit: ?usize) ![]Event {
        var results = std.ArrayList(Event).init(self.allocator);
        errdefer results.deinit();
        
        var it = self.iterator(.Forward);
        while (it.next()) |event| {
            if (event.type == event_type) {
                try results.append(event);
                if (limit) |l| {
                    if (results.items.len >= l) break;
                }
            }
        }
        
        return results.toOwnedSlice();
    }
    
    /// Query events by world
    pub fn queryByWorld(self: *Self, world_uri: []const u8, limit: ?usize) ![]Event {
        var results = std.ArrayList(Event).init(self.allocator);
        errdefer results.deinit();
        
        var it = self.iterator(.Forward);
        while (it.next()) |event| {
            if (std.mem.eql(u8, event.world_uri, world_uri)) {
                try results.append(event);
                if (limit) |l| {
                    if (results.items.len >= l) break;
                }
            }
        }
        
        return results.toOwnedSlice();
    }
    
    // ========================================================================
    // SYNC OPERATIONS
    // ========================================================================
    
    /// Synchronize with another Ewig instance
    pub fn syncWith(self: *Self, other: *Self) !SyncResult {
        var engine = SyncEngine.init(self.allocator, self.config.sync_strategy);
        return engine.syncBidirectional(&self.event_log, &other.event_log);
    }
    
    /// Get sync statistics
    pub fn syncStats(self: *Self) SyncStats {
        const cache_stats = self.reconstructor.cache.stats();
        
        return .{
            .events = self.event_log.count(),
            .cached_snapshots = cache_stats.size,
            .cache_hits = cache_stats.hits,
            .cache_misses = cache_stats.misses,
            .stored_objects = 0, // Would get from storage
        };
    }
    
    // ========================================================================
    // VERIFICATION
    // ========================================================================
    
    /// Verify log integrity
    pub fn verify(self: *Self) !bool {
        return self.event_log.verify();
    }
    
    /// Verify state reconstruction
    pub fn verifyState(self: *Self, event_hash: Hash, expected_hash: Hash) !bool {
        return self.reconstructor.verify(event_hash, expected_hash);
    }
};

pub const SyncStats = struct {
    events: usize,
    cached_snapshots: usize,
    cache_hits: u64,
    cache_misses: u64,
    stored_objects: usize,
};

// ============================================================================
// BUILDER PATTERN HELPERS
// ============================================================================

/// Builder for creating events fluently
pub const EventBuilder = struct {
    ewig: *Ewig,
    event_type: ?EventType,
    world_uri: ?[]const u8,
    payload: ?[]const u8,
    
    const Self = @This();
    
    pub fn init(ewig: *Ewig) Self {
        return .{
            .ewig = ewig,
            .event_type = null,
            .world_uri = null,
            .payload = null,
        };
    }
    
    pub fn ofType(self: *Self, event_type: EventType) *Self {
        self.event_type = event_type;
        return self;
    }
    
    pub fn inWorld(self: *Self, world_uri: []const u8) *Self {
        self.world_uri = world_uri;
        return self;
    }
    
    pub fn withPayload(self: *Self, payload: []const u8) *Self {
        self.payload = payload;
        return self;
    }
    
    pub fn withStruct(self: *Self, payload: anytype) !*Self {
        const json = try std.json.stringifyAlloc(self.ewig.allocator, payload, .{});
        self.payload = json;
        return self;
    }
    
    pub fn send(self: *Self) !Event {
        const et = self.event_type orelse return error.NoEventType;
        const uri = self.world_uri orelse return error.NoWorldUri;
        const pl = self.payload orelse "{}";
        
        const event = try self.ewig.append(et, uri, pl);
        
        // Clean up if we allocated
        if (self.payload) |p| {
            if (p != "{}") {
                self.ewig.allocator.free(p);
            }
        }
        
        return event;
    }
};

// ============================================================================
// TESTS
// ============================================================================

const testing = std.testing;

test "ewig basic operations" {
    var ewig = try Ewig.initInMemory(testing.allocator, .{});
    defer ewig.deinit();
    
    // Append events
    const e1 = try ewig.append(.WorldCreated, "a://world1", "{\"name\":\"Test World\"}");
    try testing.expectEqual(@as(u64, 1), e1.seq);
    
    const e2 = try ewig.append(.PlayerJoined, "a://world1", "{\"player\":\"Alice\"}");
    try testing.expectEqual(@as(u64, 2), e2.seq);
    
    // Query
    const events = try ewig.queryByWorld("a://world1", null);
    defer testing.allocator.free(events);
    
    try testing.expectEqual(@as(usize, 2), events.len);
    
    // Verify
    try testing.expect(try ewig.verify());
}

test "ewig branching" {
    var ewig = try Ewig.initInMemory(testing.allocator, .{});
    defer ewig.deinit();
    
    // Create initial events
    const e1 = try ewig.append(.WorldCreated, "a://world1", "{}");
    _ = try ewig.append(.StateChanged, "a://world1", "{\"x\":1}");
    
    // Create branch
    const branch_ref = try ewig.createBranch("feature", "a://world1", e1.hash);
    try testing.expectEqualStrings("feature", branch_ref.name);
    
    // Switch to branch and add events
    try ewig.switchBranch("feature");
    
    // Get active branch
    const active = ewig.getActiveBranch().?;
    try testing.expectEqualStrings("feature", active.name);
}

test "ewig event builder" {
    var ewig = try Ewig.initInMemory(testing.allocator, .{});
    defer ewig.deinit();
    
    var builder = EventBuilder.init(&ewig);
    const event = try builder
        .ofType(.PlayerAction)
        .inWorld("a://world1")
        .withPayload("{\"action\":\"jump\"}")
        .send();
    
    try testing.expectEqual(EventType.PlayerAction, event.type);
    try testing.expectEqualStrings("a://world1", event.world_uri);
}

test "ewig query by type" {
    var ewig = try Ewig.initInMemory(testing.allocator, .{});
    defer ewig.deinit();
    
    _ = try ewig.append(.WorldCreated, "a://world1", "{}");
    _ = try ewig.append(.PlayerAction, "a://world1", "{\"a\":1}");
    _ = try ewig.append(.PlayerAction, "a://world1", "{\"a\":2}");
    _ = try ewig.append(.StateChanged, "a://world1", "{}");
    
    const actions = try ewig.queryByType(.PlayerAction, null);
    defer testing.allocator.free(actions);
    
    try testing.expectEqual(@as(usize, 2), actions.len);
}
