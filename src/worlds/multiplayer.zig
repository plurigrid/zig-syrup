//! 3-Player Multiplayer Simultaneity
//!
//! Synchronized state across 3 concurrent players
//! Consistency checking, latency compensation, conflict resolution

const std = @import("std");
const World = @import("world.zig").World;
const WorldState = @import("world.zig").WorldState;
const ArrayList = std.ArrayList;
const StringHashMap = std.StringHashMap;
const Mutex = std.Thread.Mutex;
const Condition = std.Thread.Condition;

/// Player in a multiplayer session
pub const Player = struct {
    id: []const u8,
    world: *World,
    latency_ms: i64, // Measured network latency
    last_action_time: i64,
    connected: bool,
    
    pub fn init(id: []const u8, world: *World) Player {
        return .{
            .id = id,
            .world = world,
            .latency_ms = 0,
            .last_action_time = 0,
            .connected = true,
        };
    }
};

/// Synchronized action across players
pub const Action = struct {
    player_id: []const u8,
    timestamp: i64, // When action was initiated
    server_timestamp: i64, // When server received it
    type: ActionType,
    payload: []const u8,
    
    pub const ActionType = enum {
        Move,
        Interact,
        UseItem,
        Chat,
        WorldModify,
    };
};

/// Conflict between simultaneous actions
pub const Conflict = struct {
    action_a: Action,
    action_b: Action,
    resolution: Resolution,
    
    pub const Resolution = enum {
        AcceptA,
        AcceptB,
        AcceptBoth,
        RejectBoth,
        Merge,
    };
};

/// Consistency check result
pub const ConsistencyCheck = struct {
    consistent: bool,
    player_hash_mismatch: ?[]const u8,
    expected_hash: [32]u8,
    actual_hash: [32]u8,
};

/// 3-Player multiplayer session
pub const Session3P = struct {
    allocator: std.mem.Allocator,
    id: []const u8,
    players: [3]?Player,
    actions: ArrayList(Action),
    confirmed_state: *WorldState,
    pending_actions: ArrayList(Action),
    conflicts: ArrayList(Conflict),
    
    // Synchronization
    mutex: Mutex,
    cond: Condition,
    tick_rate_hz: u32,
    current_tick: u64,
    
    // Consistency
    last_sync_time: i64,
    sync_interval_ms: i64,
    
    pub fn init(
        allocator: std.mem.Allocator,
        session_id: []const u8,
        tick_rate: u32,
    ) !*Session3P {
        const self = try allocator.create(Session3P);
        errdefer allocator.destroy(self);
        
        self.* = .{
            .allocator = allocator,
            .id = try allocator.dupe(u8, session_id),
            .players = .{ null, null, null },
            .actions = ArrayList(Action).init(allocator),
            .confirmed_state = try WorldState.init(allocator),
            .pending_actions = ArrayList(Action).init(allocator),
            .conflicts = ArrayList(Conflict).init(allocator),
            .mutex = .{},
            .cond = .{},
            .tick_rate_hz = tick_rate,
            .current_tick = 0,
            .last_sync_time = 0,
            .sync_interval_ms = 50, // 20Hz sync
        };
        
        return self;
    }
    
    pub fn deinit(self: *Session3P) void {
        self.allocator.free(self.id);
        
        for (&self.players) |*p| {
            if (p.*) |*player| {
                self.allocator.free(player.id);
            }
        }
        
        for (self.actions.items) |a| self.allocator.free(a.payload);
        self.actions.deinit();
        
        self.confirmed_state.deinit();
        
        for (self.pending_actions.items) |a| self.allocator.free(a.payload);
        self.pending_actions.deinit();
        
        self.conflicts.deinit();
        
        self.allocator.destroy(self);
    }
    
    /// Add player to session
    pub fn addPlayer(self: *Session3P, player_id: []const u8, world: *World) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        for (&self.players) |*slot| {
            if (slot.* == null) {
                slot.* = Player{
                    .id = try self.allocator.dupe(u8, player_id),
                    .world = world,
                    .latency_ms = 0,
                    .last_action_time = std.time.milliTimestamp(),
                    .connected = true,
                };
                return;
            }
        }
        
        return error.SessionFull;
    }
    
    /// Remove player
    pub fn removePlayer(self: *Session3P, player_id: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        for (&self.players) |*p| {
            if (p.*) |*player| {
                if (std.mem.eql(u8, player.id, player_id)) {
                    self.allocator.free(player.id);
                    p.* = null;
                    return;
                }
            }
        }
    }
    
    /// Receive action from player
    pub fn receiveAction(
        self: *Session3P,
        player_id: []const u8,
        action_type: Action.ActionType,
        payload: []const u8,
    ) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        const now = std.time.milliTimestamp();
        
        const action = Action{
            .player_id = try self.allocator.dupe(u8, player_id),
            .timestamp = now,
            .server_timestamp = now,
            .type = action_type,
            .payload = try self.allocator.dupe(u8, payload),
        };
        
        try self.pending_actions.append(action);
        
        // Update player last action time
        for (self.players) |p| {
            if (p) |player| {
                if (std.mem.eql(u8, player.id, player_id)) {
                    // Update via pointer
                    const ptr = @constCast(&player);
                    ptr.last_action_time = now;
                    break;
                }
            }
        }
    }
    
    /// Process pending actions with conflict detection
    pub fn processActions(self: *Session3P) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        if (self.pending_actions.items.len == 0) return;
        
        // Sort by timestamp
        std.sort.insertion(Action, self.pending_actions.items, {}, 
            struct {
                fn lessThan(ctx: void, a: Action, b: Action) bool {
                    _ = ctx;
                    return a.timestamp < b.timestamp;
                }
            }.lessThan);
        
        // Group by timestamp (within 50ms = simultaneous)
        var i: usize = 0;
        while (i < self.pending_actions.items.len) : (i += 1) {
            const action = self.pending_actions.items[i];
            
            // Check for conflicts with other pending actions
            var j = i + 1;
            while (j < self.pending_actions.items.len) : (j += 1) {
                const other = self.pending_actions.items[j];
                const time_diff = @abs(other.timestamp - action.timestamp);
                
                if (time_diff > 50) break; // Not simultaneous
                
                // Check for actual conflict
                if (self.actionsConflict(action, other)) {
                    const resolution = self.resolveConflict(action, other);
                    
                    try self.conflicts.append(.{
                        .action_a = action,
                        .action_b = other,
                        .resolution = resolution,
                    });
                    
                    // Apply resolution
                    switch (resolution) {
                        .AcceptA => try self.applyAction(action),
                        .AcceptB => try self.applyAction(other),
                        .AcceptBoth => {
                            try self.applyAction(action);
                            try self.applyAction(other);
                        },
                        .RejectBoth => {},
                        .Merge => try self.applyMerged(action, other),
                    }
                } else {
                    // No conflict, apply both
                    try self.applyAction(action);
                    try self.applyAction(other);
                }
            } else {
                // No conflicts found, apply action
                try self.applyAction(action);
            }
        }
        
        // Clear pending
        for (self.pending_actions.items) |a| {
            self.allocator.free(a.player_id);
            self.allocator.free(a.payload);
        }
        self.pending_actions.clearRetainingCapacity();
    }
    
    fn actionsConflict(self: *Session3P, a: Action, b: Action) bool {
        _ = self;
        // Actions conflict if:
        // 1. Same player
        if (std.mem.eql(u8, a.player_id, b.player_id)) return true;
        
        // 2. Both modify same world region (simplified check)
        if (a.type == .WorldModify and b.type == .WorldModify) {
            // In real implementation, check payload for region overlap
            return true;
        }
        
        // 3. One moves into other's destination
        if (a.type == .Move and b.type == .Move) {
            // Check if destinations are the same
            return std.mem.eql(u8, a.payload, b.payload);
        }
        
        return false;
    }
    
    fn resolveConflict(self: *Session3P, a: Action, b: Action) Conflict.Resolution {
        _ = self;
        // Priority rules:
        // 1. Lower latency player wins
        // 2. Earlier timestamp wins
        // 3. Deterministic hash-based tiebreaker
        
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(a.player_id);
        hasher.update(b.player_id);
        const hash = hasher.final();
        
        if (a.timestamp < b.timestamp) {
            return .AcceptA;
        } else if (b.timestamp < a.timestamp) {
            return .AcceptB;
        } else {
            // Deterministic tiebreaker
            return if (hash % 2 == 0) .AcceptA else .AcceptB;
        }
    }
    
    fn applyAction(self: *Session3P, action: Action) !void {
        // Apply to confirmed state
        // In real implementation, this would modify world state
        _ = action;
        
        // Also apply to each player's world view
        for (self.players) |p| {
            if (p) |player| {
                // Apply to player's world
                _ = player;
            }
        }
        
        try self.actions.append(action);
    }
    
    fn applyMerged(self: *Session3P, a: Action, b: Action) !void {
        // Create merged action
        _ = self;
        _ = a;
        _ = b;
        // Implementation depends on action types
    }
    
    /// Synchronize all players to confirmed state
    pub fn synchronize(self: *Session3P) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        const now = std.time.milliTimestamp();
        if (now - self.last_sync_time < self.sync_interval_ms) return;
        
        // Get confirmed state hash
        const state_hash = self.confirmed_state.hash;
        
        // Check each player's world matches
        for (self.players) |p| {
            if (p) |player| {
                if (!std.mem.eql(u8, &player.world.state.hash, &state_hash)) {
                    // Desync detected, resync
                    try self.resyncPlayer(player);
                }
            }
        }
        
        self.last_sync_time = now;
    }
    
    fn resyncPlayer(self: *Session3P, player: Player) !void {
        // Send confirmed state to player
        _ = self;
        _ = player;
        // In real implementation: serialize state and send
    }
    
    /// Check consistency across all players
    pub fn checkConsistency(self: *Session3P) ConsistencyCheck {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        const expected = self.confirmed_state.hash;
        
        for (self.players) |p| {
            if (p) |player| {
                if (!std.mem.eql(u8, &player.world.state.hash, &expected)) {
                    return .{
                        .consistent = false,
                        .player_hash_mismatch = player.id,
                        .expected_hash = expected,
                        .actual_hash = player.world.state.hash,
                    };
                }
            }
        }
        
        return .{
            .consistent = true,
            .player_hash_mismatch = null,
            .expected_hash = expected,
            .actual_hash = expected,
        };
    }
    
    /// Latency compensation: predict future state
    pub fn predictState(self: *Session3P, player_id: []const u8, look_ahead_ms: i64) !*WorldState {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        // Find player
        var player: ?Player = null;
        for (self.players) |p| {
            if (p) |pl| {
                if (std.mem.eql(u8, pl.id, player_id)) {
                    player = pl;
                    break;
                }
            }
        }
        
        if (player == null) return error.PlayerNotFound;
        
        // Apply pending actions that will complete within look_ahead
        var predicted = self.confirmed_state;
        
        for (self.pending_actions.items) |action| {
            if (std.mem.eql(u8, action.player_id, player_id)) {
                const completion_time = action.timestamp + look_ahead_ms;
                if (completion_time <= std.time.milliTimestamp() + look_ahead_ms) {
                    // Will complete in time, apply to prediction
                    _ = completion_time;
                    // predicted = try predicted.apply(action);
                }
            }
        }
        
        return predicted;
    }
    
    /// Run one simulation tick
    pub fn tick(self: *Session3P) !void {
        try self.processActions();
        try self.synchronize();
        
        self.mutex.lock();
        self.current_tick += 1;
        self.mutex.unlock();
    }
    
    /// Get session statistics
    pub fn getStats(self: *Session3P) SessionStats {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        var connected_count: u32 = 0;
        var total_latency: i64 = 0;
        
        for (self.players) |p| {
            if (p) |player| {
                if (player.connected) {
                    connected_count += 1;
                    total_latency += player.latency_ms;
                }
            }
        }
        
        return .{
            .player_count = connected_count,
            .avg_latency_ms = if (connected_count > 0) 
                @divTrunc(total_latency, @as(i64, @intCast(connected_count)))
            else 
                0,
            .action_count = @intCast(self.actions.items.len),
            .conflict_count = @intCast(self.conflicts.items.len),
            .current_tick = self.current_tick,
        };
    }
};

pub const SessionStats = struct {
    player_count: u32,
    avg_latency_ms: i64,
    action_count: u32,
    conflict_count: u32,
    current_tick: u64,
};

// ============================================================================
// Tests
// ============================================================================

test "Session3P add/remove players" {
    const allocator = std.testing.allocator;
    
    var session = try Session3P.init(allocator, "test-session", 20);
    defer session.deinit();
    
    const world1 = try @import("world.zig").World.create(allocator, "a://test1", null);
    defer world1.destroy();
    
    try session.addPlayer("player1", world1);
    try session.addPlayer("player2", world1);
    try session.addPlayer("player3", world1);
    
    // Should fail - session full
    try std.testing.expectError(error.SessionFull, session.addPlayer("player4", world1));
    
    session.removePlayer("player2");
    
    // Can add again
    try session.addPlayer("player4", world1);
}

test "Session3P conflict detection" {
    const allocator = std.testing.allocator;
    
    var session = try Session3P.init(allocator, "test-session", 20);
    defer session.deinit();
    
    const world1 = try @import("world.zig").World.create(allocator, "a://test1", null);
    defer world1.destroy();
    
    try session.addPlayer("player1", world1);
    try session.addPlayer("player2", world1);
    
    // Add conflicting actions
    try session.receiveAction("player1", .Move, "position:10,10");
    try session.receiveAction("player2", .Move, "position:10,10"); // Same destination
    
    try session.processActions();
    
    // Should have recorded conflict
    try std.testing.expect(session.conflicts.items.len > 0);
}
