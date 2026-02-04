//! branch.zig - Branching and merging for Ewig
//!
//! Git-like branching for world histories:
//! - Branch from any point in history
//! - Named branches
//! - Merge divergent branches (3-way merge)
//! - Conflict detection and resolution
//! - Branch visualization

const std = @import("std");
const Allocator = std.mem.Allocator;
const format = @import("format.zig");
const log = @import("log.zig");
const timeline = @import("timeline.zig");

const Hash = format.Hash;
const Event = log.Event;
const EventType = format.EventType;
const Timeline = timeline.Timeline;

// ============================================================================
// BRANCH
// ============================================================================

/// A branch in world history
pub const Branch = struct {
    name: []const u8,
    world_uri: []const u8,
    head: Hash,              // Latest event hash on this branch
    base_hash: Hash,         // Event hash where branch diverged
    created_at: i64,
    metadata: std.StringHashMap([]const u8),
    
    const Self = @This();
    
    pub fn init(allocator: Allocator, name: []const u8, world_uri: []const u8, head: Hash, base_hash: Hash) !Self {
        var metadata = std.StringHashMap([]const u8).init(allocator);
        errdefer metadata.deinit();
        
        return .{
            .name = try allocator.dupe(u8, name),
            .world_uri = try allocator.dupe(u8, world_uri),
            .head = head,
            .base_hash = base_hash,
            .created_at = std.time.nanoTimestamp(),
            .metadata = metadata,
        };
    }
    
    pub fn deinit(self: *Self, allocator: Allocator) void {
        var it = self.metadata.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        self.metadata.deinit();
        allocator.free(self.name);
        allocator.free(self.world_uri);
    }
    
    pub fn setMetadata(self: *Self, key: []const u8, value: []const u8) !void {
        const k = try self.metadata.allocator.dupe(u8, key);
        errdefer self.metadata.allocator.free(k);
        const v = try self.metadata.allocator.dupe(u8, value);
        
        if (self.metadata.fetchRemove(k)) |old| {
            self.metadata.allocator.free(old.key);
            self.metadata.allocator.free(old.value);
        }
        
        try self.metadata.put(k, v);
    }
    
    pub fn getMetadata(self: Self, key: []const u8) ?[]const u8 {
        return self.metadata.get(key);
    }
};

// ============================================================================
// BRANCH MANAGER
// ============================================================================

/// Manages all branches for a world
pub const BranchManager = struct {
    allocator: Allocator,
    branches: std.StringHashMap(*Branch),
    active_branch: []const u8,
    mutex: std.Thread.Mutex,
    
    const Self = @This();
    
    pub fn init(allocator: Allocator, default_branch: []const u8) !Self {
        return .{
            .allocator = allocator,
            .branches = std.StringHashMap(*Branch).init(allocator),
            .active_branch = try allocator.dupe(u8, default_branch),
            .mutex = .{},
        };
    }
    
    pub fn deinit(self: *Self) void {
        var it = self.branches.valueIterator();
        while (it.next()) |branch| {
            branch.*.deinit(self.allocator);
            self.allocator.destroy(branch.*);
        }
        self.branches.deinit();
        self.allocator.free(self.active_branch);
    }
    
    /// Create a new branch from a point in history
    pub fn createBranch(
        self: *Self,
        name: []const u8,
        world_uri: []const u8,
        from_hash: Hash,
    ) !*Branch {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        // Check if branch already exists
        if (self.branches.contains(name)) {
            return error.BranchAlreadyExists;
        }
        
        const branch = try self.allocator.create(Branch);
        errdefer self.allocator.destroy(branch);
        
        branch.* = try Branch.init(self.allocator, name, world_uri, from_hash, from_hash);
        try self.branches.put(branch.name, branch);
        
        return branch;
    }
    
    /// Get a branch by name
    pub fn getBranch(self: *Self, name: []const u8) ?*Branch {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        return self.branches.get(name);
    }
    
    /// Get or create main branch
    pub fn getOrCreateMain(self: *Self, world_uri: []const u8, initial_hash: Hash) !*Branch {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        if (self.branches.get("main")) |branch| {
            return branch;
        }
        
        const branch = try self.allocator.create(Branch);
        errdefer self.allocator.destroy(branch);
        
        branch.* = try Branch.init(self.allocator, "main", world_uri, initial_hash, initial_hash);
        try self.branches.put(branch.name, branch);
        
        return branch;
    }
    
    /// Update branch head
    pub fn updateHead(self: *Self, branch_name: []const u8, new_head: Hash) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        const branch = self.branches.get(branch_name) orelse return error.BranchNotFound;
        branch.head = new_head;
    }
    
    /// Switch to a different branch
    pub fn switchBranch(self: *Self, name: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        if (!self.branches.contains(name)) {
            return error.BranchNotFound;
        }
        
        self.allocator.free(self.active_branch);
        self.active_branch = try self.allocator.dupe(u8, name);
    }
    
    /// Get the active branch
    pub fn getActiveBranch(self: *Self) ?*Branch {
        return self.getBranch(self.active_branch);
    }
    
    /// List all branches
    pub fn listBranches(self: *Self, allocator: Allocator) ![][]const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        var names = std.ArrayList([]const u8).init(allocator);
        errdefer names.deinit();
        
        var it = self.branches.keyIterator();
        while (it.next()) |key| {
            const copy = try allocator.dupe(u8, key.*);
            try names.append(copy);
        }
        
        return names.toOwnedSlice();
    }
    
    /// Delete a branch
    pub fn deleteBranch(self: *Self, name: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        if (std.mem.eql(u8, name, self.active_branch)) {
            return error.CannotDeleteActiveBranch;
        }
        
        const branch = self.branches.fetchRemove(name) orelse return error.BranchNotFound;
        branch.value.deinit(self.allocator);
        self.allocator.destroy(branch.value);
    }
};

// ============================================================================
// MERGE
// ============================================================================

/// Result of a merge operation
pub const MergeResult = struct {
    success: bool,
    merge_commit: ?Hash,
    conflicts: []const Conflict,
    allocator: Allocator,
    
    pub fn deinit(self: *MergeResult) void {
        for (self.conflicts) |conflict| {
            self.allocator.free(conflict.path);
        }
        self.allocator.free(self.conflicts);
    }
};

/// A conflict during merge
pub const Conflict = struct {
    path: []const u8,
    base_value: ?[]const u8,
    our_value: ?[]const u8,
    their_value: ?[]const u8,
    resolution: Resolution,
    
    pub const Resolution = enum {
        Unresolved,
        Ours,
        Theirs,
        Union,
        Custom,
    };
};

/// 3-way merge strategy
pub const MergeStrategy = enum {
    FastForward,      // If possible, just move the pointer
    Ours,             // Always prefer our changes
    Theirs,           // Always prefer their changes
    ThreeWay,         // Standard 3-way merge
    Recursive,        // Recursive merge for criss-cross
};

/// Merge engine for combining divergent histories
pub const MergeEngine = struct {
    allocator: Allocator,
    
    const Self = @This();
    
    pub fn init(allocator: Allocator) Self {
        return .{ .allocator = allocator };
    }
    
    /// Perform a 3-way merge
    pub fn merge(
        self: Self,
        base: Hash,
        ours: Hash,
        theirs: Hash,
        events: *log.EventLog,
        strategy: MergeStrategy,
    ) !MergeResult {
        // Fast-forward check
        if (strategy == .FastForward or strategy == .ThreeWay) {
            // If theirs is ancestor of ours, already up-to-date
            if (try self.isAncestor(events, theirs, ours)) {
                return MergeResult{
                    .success = true,
                    .merge_commit = ours,
                    .conflicts = &.{},
                    .allocator = self.allocator,
                };
            }
            
            // If ours is ancestor of theirs, fast-forward
            if (try self.isAncestor(events, ours, theirs)) {
                return MergeResult{
                    .success = true,
                    .merge_commit = theirs,
                    .conflicts = &.{},
                    .allocator = self.allocator,
                };
            }
        }
        
        // Get event chains
        const base_events = try self.getChain(events, base);
        defer self.allocator.free(base_events);
        
        const ours_events = try self.getChain(events, ours);
        defer self.allocator.free(ours_events);
        
        const theirs_events = try self.getChain(events, theirs);
        defer self.allocator.free(theirs_events);
        
        // Apply strategy
        switch (strategy) {
            .Ours => {
                return MergeResult{
                    .success = true,
                    .merge_commit = ours,
                    .conflicts = &.{},
                    .allocator = self.allocator,
                };
            },
            .Theirs => {
                return MergeResult{
                    .success = true,
                    .merge_commit = theirs,
                    .conflicts = &.{},
                    .allocator = self.allocator,
                };
            },
            .ThreeWay, .FastForward => {
                return self.threeWayMerge(base_events, ours_events, theirs_events);
            },
            .Recursive => {
                return self.recursiveMerge(base, ours, theirs, events);
            },
        }
    }
    
    /// Check if 'ancestor' is in the history of 'descendant'
    fn isAncestor(
        self: Self,
        events: *log.EventLog,
        ancestor: Hash,
        descendant: Hash,
    ) !bool {
        _ = self;
        
        var current = descendant;
        const zero_hash = [_]u8{0} ** 32;
        
        while (!std.mem.eql(u8, &current, &zero_hash)) {
            if (std.mem.eql(u8, &current, &ancestor)) {
                return true;
            }
            
            const event = events.getByHash(current) orelse break;
            current = event.parent;
        }
        
        return false;
    }
    
    /// Get chain of events from head to base
    fn getChain(self: Self, events: *log.EventLog, head: Hash) ![]Event {
        var chain = std.ArrayList(Event).init(self.allocator);
        errdefer chain.deinit();
        
        var current = head;
        const zero_hash = [_]u8{0} ** 32;
        
        while (!std.mem.eql(u8, &current, &zero_hash)) {
            const event = events.getByHash(current) orelse break;
            try chain.append(event);
            current = event.parent;
        }
        
        // Reverse to get chronological order
        std.mem.reverse(Event, chain.items);
        
        return chain.toOwnedSlice();
    }
    
    /// Perform 3-way merge
    fn threeWayMerge(
        self: Self,
        base: []Event,
        ours: []Event,
        theirs: []Event,
    ) !MergeResult {
        var conflicts = std.ArrayList(Conflict).init(self.allocator);
        errdefer {
            for (conflicts.items) |*c| {
                self.allocator.free(c.path);
            }
            conflicts.deinit();
        }
        
        // Find diverged events
        const our_changes = try self.findChanges(base, ours);
        defer self.allocator.free(our_changes);
        
        const their_changes = try self.findChanges(base, theirs);
        defer self.allocator.free(their_changes);
        
        // Check for conflicts
        for (our_changes) |our_change| {
            for (their_changes) |their_change| {
                if (std.mem.eql(u8, our_change.path, their_change.path)) {
                    if (!std.mem.eql(u8, our_change.value, their_change.value)) {
                        try conflicts.append(.{
                            .path = try self.allocator.dupe(u8, our_change.path),
                            .base_value = our_change.base_value,
                            .our_value = our_change.value,
                            .their_value = their_change.value,
                            .resolution = .Unresolved,
                        });
                    }
                }
            }
        }
        
        const conflict_slice = try conflicts.toOwnedSlice();
        
        return MergeResult{
            .success = conflict_slice.len == 0,
            .merge_commit = null, // Would be created after resolution
            .conflicts = conflict_slice,
            .allocator = self.allocator,
        };
    }
    
    const Change = struct {
        path: []const u8,
        value: []const u8,
        base_value: ?[]const u8,
    };
    
    /// Find changes between base and head
    fn findChanges(self: Self, base: []Event, head: []Event) ![]Change {
        var changes = std.ArrayList(Change).init(self.allocator);
        errdefer {
            for (changes.items) |c| {
                self.allocator.free(c.path);
                self.allocator.free(c.value);
            }
            changes.deinit();
        }
        
        // Find common prefix length
        var common_len: usize = 0;
        while (common_len < base.len and common_len < head.len) {
            if (!std.mem.eql(u8, &base[common_len].hash, &head[common_len].hash)) {
                break;
            }
            common_len += 1;
        }
        
        // Events after common prefix are changes
        for (head[common_len..]) |event| {
            // Simplified: treat each event as a change
            const path = try std.fmt.allocPrint(self.allocator, "event:{d}", .{event.seq});
            const value = try self.allocator.dupe(u8, event.payload);
            
            try changes.append(.{
                .path = path,
                .value = value,
                .base_value = null,
            });
        }
        
        return changes.toOwnedSlice();
    }
    
    /// Recursive merge for complex histories
    fn recursiveMerge(
        self: Self,
        base: Hash,
        ours: Hash,
        theirs: Hash,
        events: *log.EventLog,
    ) !MergeResult {
        // For now, fall back to 3-way merge
        const base_events = try self.getChain(events, base);
        defer self.allocator.free(base_events);
        
        const ours_events = try self.getChain(events, ours);
        defer self.allocator.free(ours_events);
        
        const theirs_events = try self.getChain(events, theirs);
        defer self.allocator.free(theirs_events);
        
        return self.threeWayMerge(base_events, ours_events, theirs_events);
    }
    
    /// Resolve conflicts using a resolution strategy
    pub fn resolveConflicts(
        self: Self,
        conflicts: []const Conflict,
        strategy: enum { Ours, Theirs, Union },
    ) ![]Change {
        var resolved = std.ArrayList(Change).init(self.allocator);
        errdefer resolved.deinit();
        
        for (conflicts) |conflict| {
            const value = switch (strategy) {
                .Ours => conflict.our_value,
                .Theirs => conflict.their_value,
                .Union => try self.unionMerge(conflict.our_value, conflict.their_value),
            };
            
            if (value) |v| {
                try resolved.append(.{
                    .path = try self.allocator.dupe(u8, conflict.path),
                    .value = try self.allocator.dupe(u8, v),
                    .base_value = conflict.base_value,
                });
            }
        }
        
        return resolved.toOwnedSlice();
    }
    
    /// Union merge - combine both versions
    fn unionMerge(self: Self, ours: ?[]const u8, theirs: ?[]const u8) !?[]const u8 {
        if (ours == null) return theirs;
        if (theirs == null) return ours;
        if (std.mem.eql(u8, ours.?, theirs.?)) return ours;
        
        // Try to parse as JSON objects and merge
        // Simplified: concatenate with separator
        return std.mem.concat(self.allocator, u8, &.{ ours.?, ",", theirs.? });
    }
};

// ============================================================================
// VISUALIZATION
// ============================================================================

/// Visual representation of branch history
pub const BranchVisualizer = struct {
    allocator: Allocator,
    
    const Self = @This();
    
    pub fn init(allocator: Allocator) Self {
        return .{ .allocator = allocator };
    }
    
    /// Generate ASCII visualization of branches
    pub fn visualize(
        self: Self,
        branches: *BranchManager,
        events: *log.EventLog,
    ) ![]u8 {
        var output = std.ArrayList(u8).init(self.allocator);
        errdefer output.deinit();
        
        const writer = output.writer();
        
        try writer.writeAll("\nBranch History:\n");
        try writer.writeAll("===============\n\n");
        
        var branch_list = try branches.listBranches(self.allocator);
        defer {
            for (branch_list) |name| {
                self.allocator.free(name);
            }
            self.allocator.free(branch_list);
        }
        
        for (branch_list) |name| {
            const branch = branches.getBranch(name).?;
            const is_active = std.mem.eql(u8, name, branches.active_branch);
            
            if (is_active) {
                try writer.print("* {s}\n", .{name});
            } else {
                try writer.print("  {s}\n", .{name});
            }
            
            try writer.print("    Head: {s}\n", .{format.hashToHex(branch.head)});
            try writer.print("    Base: {s}\n", .{format.hashToHex(branch.base_hash)});
            
            // Show recent events
            try writer.writeAll("    Recent: ");
            var count: usize = 0;
            var current = branch.head;
            const zero_hash = [_]u8{0} ** 32;
            
            while (!std.mem.eql(u8, &current, &zero_hash) and count < 5) : (count += 1) {
                if (events.getByHash(current)) |event| {
                    try writer.print("{d} ", .{event.seq});
                    current = event.parent;
                } else {
                    break;
                }
            }
            try writer.writeAll("\n\n");
        }
        
        return output.toOwnedSlice();
    }
    
    /// Generate Graphviz DOT format
    pub fn toDot(
        self: Self,
        branches: *BranchManager,
        events: *log.EventLog,
    ) ![]u8 {
        var output = std.ArrayList(u8).init(self.allocator);
        errdefer output.deinit();
        
        const writer = output.writer();
        
        try writer.writeAll("digraph History {\n");
        try writer.writeAll("  rankdir=TB;\n");
        try writer.writeAll("  node [shape=box];\n\n");
        
        // Collect all events
        var all_events = std.ArrayList(Event).init(self.allocator);
        defer all_events.deinit();
        
        var branch_list = try branches.listBranches(self.allocator);
        defer {
            for (branch_list) |name| {
                self.allocator.free(name);
            }
            self.allocator.free(branch_list);
        }
        
        for (branch_list) |name| {
            const branch = branches.getBranch(name).?;
            
            var current = branch.head;
            const zero_hash = [_]u8{0} ** 32;
            
            while (!std.mem.eql(u8, &current, &zero_hash)) {
                if (events.getByHash(current)) |event| {
                    try all_events.append(event);
                    current = event.parent;
                } else {
                    break;
                }
            }
        }
        
        // Create nodes
        for (all_events.items) |event| {
            const hash_str = format.hashToHex(event.hash);
            const short_hash = hash_str[0..8];
            try writer.print("  \"{s}\" [label=\"{s}\\n{d}\"];\n", .{
                short_hash,
                @tagName(event.type),
                event.seq,
            });
        }
        
        // Create edges
        try writer.writeAll("\n");
        for (all_events.items) |event| {
            const hash_str = format.hashToHex(event.hash);
            const parent_str = format.hashToHex(event.parent);
            const short_hash = hash_str[0..8];
            const short_parent = parent_str[0..8];
            
            const zero_hash = [_]u8{0} ** 32;
            if (!std.mem.eql(u8, &event.parent, &zero_hash)) {
                try writer.print("  \"{s}\" -> \"{s}\";\n", .{ short_hash, short_parent });
            }
        }
        
        // Mark branch heads
        try writer.writeAll("\n  // Branch heads\n");
        for (branch_list) |name| {
            const branch = branches.getBranch(name).?;
            const hash_str = format.hashToHex(branch.head);
            const short_hash = hash_str[0..8];
            try writer.print("  \"{s}\" [style=filled,fillcolor=lightblue,label=\"{s}\\n{s}\"];\n", .{
                short_hash,
                name,
                short_hash,
            });
        }
        
        try writer.writeAll("}\n");
        
        return output.toOwnedSlice();
    }
};

// ============================================================================
// TESTS
// ============================================================================

const testing = std.testing;

test "branch create and manage" {
    var manager = try BranchManager.init(testing.allocator, "main");
    defer manager.deinit();
    
    const head = [_]u8{0xAA} ** 32;
    
    // Create branch
    const branch = try manager.createBranch("feature", "a://world", head);
    try testing.expectEqualStrings("feature", branch.name);
    
    // Get branch
    const got = manager.getBranch("feature").?;
    try testing.expectEqual(branch, got);
    
    // List branches
    const list = try manager.listBranches(testing.allocator);
    defer {
        for (list) |name| testing.allocator.free(name);
        testing.allocator.free(list);
    }
    try testing.expectEqual(@as(usize, 1), list.len);
}

test "merge engine fast-forward" {
    var events = try log.EventLog.initInMemory(testing.allocator);
    defer events.deinit();
    
    const e1 = try events.append(.WorldCreated, "a://world", "{}");
    const e2 = try events.append(.StateChanged, "a://world", "{\"x\":1}");
    const e3 = try events.append(.StateChanged, "a://world", "{\"x\":2}");
    
    const engine = MergeEngine.init(testing.allocator);
    
    // Fast-forward: ours is ancestor of theirs
    var result = try engine.merge(e1.hash, e1.hash, e3.hash, &events, .FastForward);
    defer result.deinit();
    
    try testing.expect(result.success);
    try testing.expect(std.mem.eql(u8, &result.merge_commit.?, &e3.hash));
}

test "branch visualization" {
    var manager = try BranchManager.init(testing.allocator, "main");
    defer manager.deinit();
    
    var events = try log.EventLog.initInMemory(testing.allocator);
    defer events.deinit();
    
    const e1 = try events.append(.WorldCreated, "a://world", "{}");
    _ = try manager.getOrCreateMain("a://world", e1.hash);
    
    // Create visualizer
    const viz = BranchVisualizer.init(testing.allocator);
    
    // Generate visualization
    const ascii = try viz.visualize(&manager, &events);
    defer testing.allocator.free(ascii);
    
    try testing.expect(ascii.len > 0);
    
    // Generate DOT
    const dot = try viz.toDot(&manager, &events);
    defer testing.allocator.free(dot);
    
    try testing.expect(dot.len > 0);
    try testing.expect(std.mem.containsAtLeast(u8, dot, 1, "digraph"));
}
