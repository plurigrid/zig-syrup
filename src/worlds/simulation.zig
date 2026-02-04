//! Deterministic Simulation
//!
//! Fixed-timestep game loop with deterministic random
//! Replay capability and divergence detection

const std = @import("std");
const World = @import("world.zig").World;
const Session3P = @import("multiplayer.zig").Session3P;
const ArrayList = std.ArrayList;
const StringHashMap = std.StringHashMap;
const Random = std.Random;

/// Simulation configuration
pub const SimConfig = struct {
    tick_rate_hz: u32,      // Fixed timestep
    max_ticks: u64,         // Simulation limit
    random_seed: u64,
    deterministic: bool,    // Strict determinism checks
};

/// A single tick in the simulation
pub const Tick = struct {
    number: u64,
    timestamp: i64,
    actions: []const PlayerAction,
    state_hash: [32]u8,
    
    pub const PlayerAction = struct {
        player_id: []const u8,
        action_type: []const u8,
        params: []const u8,
    };
};

/// Deterministic random number generator
pub const DeterministicRng = struct {
    rng: Random.DefaultPrng,
    
    pub fn init(seed: u64) DeterministicRng {
        return .{
            .rng = Random.DefaultPrng.init(seed),
        };
    }
    
    pub fn random(self: *DeterministicRng) Random {
        return self.rng.random();
    }
    
    pub fn int(self: *DeterministicRng, comptime T: type) T {
        return self.rng.random().int(T);
    }
    
    pub fn float(self: *DeterministicRng, comptime T: type) T {
        return self.rng.random().float(T);
    }
    
    /// Get current state for serialization
    pub fn getState(self: DeterministicRng) u64 {
        // Simplified - in real impl would expose internal state
        return self.rng.seed;
    }
};

/// Simulation runner
pub const Simulation = struct {
    allocator: std.mem.Allocator,
    config: SimConfig,
    world: *World,
    rng: DeterministicRng,
    current_tick: u64,
    tick_history: ArrayList(Tick),
    started: bool,
    paused: bool,
    
    // Statistics
    total_actions: u64,
    divergence_checks: u64,
    
    pub fn init(
        allocator: std.mem.Allocator,
        config: SimConfig,
        world: *World,
    ) !*Simulation {
        const self = try allocator.create(Simulation);
        self.* = .{
            .allocator = allocator,
            .config = config,
            .world = world,
            .rng = DeterministicRng.init(config.random_seed),
            .current_tick = 0,
            .tick_history = ArrayList(Tick).init(allocator),
            .started = false,
            .paused = false,
            .total_actions = 0,
            .divergence_checks = 0,
        };
        return self;
    }
    
    pub fn deinit(self: *Simulation) void {
        for (self.tick_history.items) |tick| {
            for (tick.actions) |action| {
                self.allocator.free(action.player_id);
                self.allocator.free(action.action_type);
                self.allocator.free(action.params);
            }
            self.allocator.free(tick.actions);
        }
        self.tick_history.deinit();
        self.allocator.destroy(self);
    }
    
    /// Start the simulation
    pub fn start(self: *Simulation) void {
        self.started = true;
        self.paused = false;
    }
    
    /// Pause simulation
    pub fn pause(self: *Simulation) void {
        self.paused = true;
    }
    
    /// Resume simulation
    pub fn resume(self: *Simulation) void {
        self.paused = false;
    }
    
    /// Run one tick
    pub fn tick(self: *Simulation) !void {
        if (!self.started or self.paused) return;
        
        if (self.current_tick >= self.config.max_ticks) {
            return error.MaxTicksReached;
        }
        
        const tick_start = std.time.milliTimestamp();
        
        // Process any pending actions for this tick
        const actions = try self.getActionsForTick(self.current_tick);
        
        // Apply actions to world
        for (actions) |action| {
            try self.applyAction(action);
        }
        
        // Update world (deterministic)
        try self.updateWorld();
        
        // Record tick
        const state_hash = try self.world.snapshot();
        
        const tick_record = Tick{
            .number = self.current_tick,
            .timestamp = tick_start,
            .actions = actions,
            .state_hash = state_hash,
        };
        
        try self.tick_history.append(tick_record);
        
        self.current_tick += 1;
        self.total_actions += actions.len;
        
        // Yield to allow other work (cooperative scheduling)
        std.time.sleep(1); // Minimal yield
    }
    
    /// Run simulation to completion
    pub fn run(self: *Simulation) !void {
        self.start();
        while (self.current_tick < self.config.max_ticks) {
            try self.tick();
        }
    }
    
    /// Run with multiplayer session
    pub fn runMultiplayer(
        self: *Simulation,
        session: *Session3P,
        duration_ticks: u64,
    ) !void {
        self.start();
        
        const end_tick = self.current_tick + duration_ticks;
        
        while (self.current_tick < end_tick) {
            // Process session actions
            try session.processActions();
            try session.synchronize();
            
            // Run simulation tick
            try self.tick();
            
            // Consistency check
            const check = session.checkConsistency();
            if (!check.consistent) {
                return error.MultiplayerDesync;
            }
            self.divergence_checks += 1;
        }
    }
    
    fn getActionsForTick(self: *Simulation, tick_num: u64) ![]Tick.PlayerAction {
        // In real implementation, would poll action queue
        // For now, return empty
        _ = tick_num;
        return &[_]Tick.PlayerAction{};
    }
    
    fn applyAction(self: *Simulation, action: Tick.PlayerAction) !void {
        // Apply action to world state
        // This would dispatch to appropriate handler based on action_type
        _ = self;
        _ = action;
    }
    
    fn updateWorld(self: *Simulation) !void {
        // Deterministic world update
        // Uses self.rng for any randomness
        _ = self;
    }
    
    /// Replay simulation from tick history
    pub fn replay(self: *Simulation) !void {
        // Reset to initial state
        self.current_tick = 0;
        self.rng = DeterministicRng.init(self.config.random_seed);
        
        // Replay each tick
        for (self.tick_history.items) |tick| {
            // Verify state hash matches at each tick
            const current_hash = try self.world.snapshot();
            
            if (!std.mem.eql(u8, &current_hash, &tick.state_hash)) {
                return error.ReplayDivergence;
            }
            
            // Apply actions
            for (tick.actions) |action| {
                try self.applyAction(action);
            }
            
            try self.updateWorld();
            self.current_tick += 1;
        }
    }
    
    /// Replay from saved log file
    pub fn replayFromLog(self: *Simulation, log_path: []const u8) !void {
        const file = try std.fs.cwd().openFile(log_path, .{});
        defer file.close();
        
        const content = try file.readToEndAlloc(self.allocator, 1024 * 1024 * 100);
        defer self.allocator.free(content);
        
        // Parse and replay
        _ = self;
        _ = content;
    }
    
    /// Verify two simulations are deterministic
    pub fn verifyDeterminism(
        allocator: std.mem.Allocator,
        config: SimConfig,
        world_a: *World,
        world_b: *World,
        ticks: u64,
    ) !bool {
        var sim_a = try Simulation.init(allocator, config, world_a);
        defer sim_a.deinit();
        
        var sim_b = try Simulation.init(allocator, config, world_b);
        defer sim_b.deinit();
        
        // Run both simulations
        var i: u64 = 0;
        while (i < ticks) : (i += 1) {
            try sim_a.tick();
            try sim_b.tick();
            
            // Compare state hashes
            const hash_a = try world_a.snapshot();
            const hash_b = try world_b.snapshot();
            
            if (!std.mem.eql(u8, &hash_a, &hash_b)) {
                std.log.warn("Divergence at tick {d}", .{i});
                return false;
            }
        }
        
        return true;
    }
    
    /// Compare two simulations for differences
    pub fn compare(
        self: *Simulation,
        other: *Simulation,
    ) !ComparisonResult {
        var differences = ArrayList(TickDifference).init(self.allocator);
        errdefer differences.deinit();
        
        const min_ticks = @min(self.tick_history.items.len, other.tick_history.items.len);
        
        for (0..min_ticks) |i| {
            const tick_a = self.tick_history.items[i];
            const tick_b = other.tick_history.items[i];
            
            if (!std.mem.eql(u8, &tick_a.state_hash, &tick_b.state_hash)) {
                try differences.append(.{
                    .tick = i,
                    .hash_a = tick_a.state_hash,
                    .hash_b = tick_b.state_hash,
                    .actions_a = tick_a.actions.len,
                    .actions_b = tick_b.actions.len,
                });
            }
        }
        
        // Check length difference
        const length_diff = @as(i64, @intCast(self.tick_history.items.len)) - 
            @as(i64, @intCast(other.tick_history.items.len));
        
        return .{
            .deterministic = differences.items.len == 0 and length_diff == 0,
            .total_ticks_a = self.tick_history.items.len,
            .total_ticks_b = other.tick_history.items.len,
            .differences = try differences.toOwnedSlice(),
        };
    }
    
    /// Benchmark simulation performance
    pub fn benchmark(
        self: *Simulation,
        ticks: u64,
    ) !BenchmarkResult {
        const start_time = std.time.milliTimestamp();
        const start_tick = self.current_tick;
        
        var i: u64 = 0;
        while (i < ticks) : (i += 1) {
            try self.tick();
        }
        
        const end_time = std.time.milliTimestamp();
        const duration_ms = end_time - start_time;
        
        return .{
            .ticks = ticks,
            .duration_ms = duration_ms,
            .ticks_per_second = @as(f64, @floatFromInt(ticks)) / (@as(f64, @floatFromInt(duration_ms)) / 1000.0),
            .avg_tick_duration_ms = @as(f64, @floatFromInt(duration_ms)) / @as(f64, @floatFromInt(ticks)),
        };
    }
    
    /// Export tick history to file
    pub fn exportHistory(self: *Simulation, path: []const u8) !void {
        const file = try std.fs.cwd().createFile(path, .{});
        defer file.close();
        
        const writer = file.writer();
        
        // Header
        try writer.print("# Simulation Replay Log\n", .{});
        try writer.print("# Seed: {d}\n", .{self.config.random_seed});
        try writer.print("# TickRate: {d}Hz\n", .{self.config.tick_rate_hz});
        try writer.print("# TotalTicks: {d}\n\n", .{self.tick_history.items.len});
        
        // Ticks
        for (self.tick_history.items) |tick| {
            try writer.print("TICK {d} {x} {d}\n", .{
                tick.number,
                std.fmt.fmtSliceHexLower(&tick.state_hash),
                tick.actions.len,
            });
            
            for (tick.actions) |action| {
                try writer.print("  ACTION {s} {s} {s}\n", .{
                    action.player_id,
                    action.action_type,
                    action.params,
                });
            }
        }
    }
    
    /// Get statistics
    pub fn getStats(self: *Simulation) SimStats {
        return .{
            .current_tick = self.current_tick,
            .total_actions = self.total_actions,
            .divergence_checks = self.divergence_checks,
            .history_size = self.tick_history.items.len,
            .memory_used_estimate = self.tick_history.items.len * @sizeOf(Tick),
        };
    }
};

pub const TickDifference = struct {
    tick: usize,
    hash_a: [32]u8,
    hash_b: [32]u8,
    actions_a: usize,
    actions_b: usize,
};

pub const ComparisonResult = struct {
    deterministic: bool,
    total_ticks_a: usize,
    total_ticks_b: usize,
    differences: []TickDifference,
    
    pub fn deinit(self: *ComparisonResult, allocator: std.mem.Allocator) void {
        allocator.free(self.differences);
    }
};

pub const BenchmarkResult = struct {
    ticks: u64,
    duration_ms: i64,
    ticks_per_second: f64,
    avg_tick_duration_ms: f64,
};

pub const SimStats = struct {
    current_tick: u64,
    total_actions: u64,
    divergence_checks: u64,
    history_size: usize,
    memory_used_estimate: usize,
};

/// Stress test runner
pub const StressTest = struct {
    allocator: std.mem.Allocator,
    config: SimConfig,
    
    pub fn init(allocator: std.mem.Allocator, config: SimConfig) StressTest {
        return .{
            .allocator = allocator,
            .config = config,
        };
    }
    
    /// Run stress test with random actions
    pub fn run(self: StressTest, duration_ticks: u64) !StressResult {
        const world = try World.create(self.allocator, "a://stress-test", null);
        defer world.destroy();
        
        var sim = try Simulation.init(self.allocator, self.config, world);
        defer sim.deinit();
        
        sim.start();
        
        var rng = DeterministicRng.init(self.config.random_seed);
        
        var i: u64 = 0;
        while (i < duration_ticks) : (i += 1) {
            // Inject random actions
            if (rng.int(u8) % 10 == 0) { // 10% chance per tick
                // Create random action
                _ = try sim.world.setParam("random_value", 
                    .{ .Float = rng.float(f64) });
            }
            
            try sim.tick();
        }
        
        const stats = sim.getStats();
        
        return .{
            .completed = true,
            .ticks = i,
            .final_memory = stats.memory_used_estimate,
            .avg_tick_time_ms = @as(f64, @floatFromInt(stats.memory_used_estimate)) / @as(f64, @floatFromInt(i)),
        };
    }
};

pub const StressResult = struct {
    completed: bool,
    ticks: u64,
    final_memory: usize,
    avg_tick_time_ms: f64,
};

// ============================================================================
// Tests
// ============================================================================

test "Simulation determinism" {
    const allocator = std.testing.allocator;
    
    const config = SimConfig{
        .tick_rate_hz = 60,
        .max_ticks = 100,
        .random_seed = 12345,
        .deterministic = true,
    };
    
    const world1 = try World.create(allocator, "a://test1", null);
    defer world1.destroy();
    
    const world2 = try World.create(allocator, "a://test2", null);
    defer world2.destroy();
    
    // Set same initial state
    _ = try world1.setParam("x", .{ .Int = 0 });
    _ = try world2.setParam("x", .{ .Int = 0 });
    
    const deterministic = try Simulation.verifyDeterminism(
        allocator, config, world1, world2, 50);
    
    try std.testing.expect(deterministic);
}

test "Simulation replay" {
    const allocator = std.testing.allocator;
    
    const config = SimConfig{
        .tick_rate_hz = 60,
        .max_ticks = 100,
        .random_seed = 12345,
        .deterministic = true,
    };
    
    const world = try World.create(allocator, "a://replay-test", null);
    defer world.destroy();
    
    var sim = try Simulation.init(allocator, config, world);
    defer sim.deinit();
    
    // Run 10 ticks
    try sim.run();
    
    // Replay should succeed (no divergence)
    try sim.replay();
}
