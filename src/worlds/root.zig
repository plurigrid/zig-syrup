//! Multiplayer World A/B Testing Framework for zig-syrup
//! 
//! This module provides comprehensive world A/B testing capabilities:
//! - Immutable data structures (immer) for efficient state management
//! - URI-based world references (a://, b://, c://)
//! - Persistent state storage (ewig) with append-only logs
//! - 3-player multiplayer simultaneity with synchronization
//! - Deterministic simulation with replay capability
//! - Statistical A/B testing with significance testing
//!
//! ## Quick Start
//! 
//! ```zig
//! const worlds = @import("worlds");
//!
//! // Create a test
//! var manager = worlds.ABTestManager.init(allocator);
//! defer manager.deinit();
//!
//! var config = worlds.ABTestConfig{
//!     .name = "Physics Test",
//!     .assignment_strategy = .round_robin,
//! };
//!
//! var test = try manager.createTest(config);
//! test.start();
//!
//! // Assign player to variant
//! const variant = try test.assignPlayer(player_id, world_id);
//! ```

const std = @import("std");

// Core modules
pub const immer = @import("immer.zig");
pub const uri = @import("uri.zig");
pub const world = @import("world.zig");
pub const ewig = @import("ewig.zig");
pub const multiplayer = @import("multiplayer.zig");
pub const simulation = @import("simulation.zig");
pub const ab_test = @import("ab_test.zig");

// Re-export commonly used types
pub const World = world.World;
pub const WorldConfig = world.WorldConfig;
pub const WorldSnapshot = world.WorldSnapshot;
pub const PhysicsParams = world.PhysicsParams;
pub const Entity = world.Entity;

pub const WorldURI = uri.WorldURI;
pub const WorldVariant = uri.WorldVariant;
pub const URIResolver = uri.URIResolver;
pub const TestURIGenerator = uri.TestURIGenerator;

pub const ImmutableArray = immer.ImmutableArray;
pub const ImmutableMap = immer.ImmutableMap;
pub const ImmutableSet = immer.ImmutableSet;

pub const Session = multiplayer.Session;
pub const SessionManager = multiplayer.SessionManager;
pub const Player = multiplayer.Player;
pub const PlayerAction = multiplayer.PlayerAction;

pub const ABTest = ab_test.ABTest;
pub const ABTestManager = ab_test.ABTestManager;
pub const ABTestConfig = ab_test.ABTestConfig;
pub const AssignmentStrategy = ab_test.AssignmentStrategy;
pub const Metric = ab_test.Metric;
pub const TestResult = ab_test.TestResult;

pub const SimulationRunner = simulation.SimulationRunner;
pub const DeterministicRandom = simulation.DeterministicRandom;
pub const GameLoop = simulation.GameLoop;

pub const EternalStorage = ewig.EternalStorage;
pub const EventLog = ewig.EventLog;

/// Version of the worlds framework
pub const VERSION = "0.1.0";

/// Initialize the framework
pub fn init(allocator: std.mem.Allocator) Framework {
    return Framework{
        .allocator = allocator,
        .test_manager = ABTestManager.init(allocator),
        .session_manager = SessionManager.init(allocator),
        .uri_generator = undefined, // Initialized per test
    };
}

/// Framework context
pub const Framework = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    test_manager: ABTestManager,
    session_manager: SessionManager,
    uri_generator: ?TestURIGenerator,

    pub fn deinit(self: *Self) void {
        self.test_manager.deinit();
        self.session_manager.deinit();
        if (self.uri_generator) |*gen| {
            gen.deinit();
        }
    }

    /// Create a new A/B test with worlds
    pub fn createTest(
        self: *Self,
        name: []const u8,
        strategy: AssignmentStrategy,
    ) error{OutOfMemory}!*ABTest {
        const config = ABTestConfig{
            .name = name,
            .start_time = std.time.milliTimestamp(),
            .assignment_strategy = strategy,
        };

        return self.test_manager.createTest(config);
    }

    /// Create a multiplayer session for 3 players
    pub fn createSession(self: *Self, tick_rate: u32) error{OutOfMemory}!*Session {
        return self.session_manager.createSession(tick_rate);
    }

    /// Run a complete A/B test simulation
    pub fn runSimulation(
        self: *Self,
        ab_test_ptr: *ABTest,
        config: SimulationConfig,
    ) error{OutOfMemory}!void {
        // Create worlds for each variant
        const variants = [_]WorldVariant{ .baseline, .variant, .experimental };
        
        for (variants, 0..) |variant, i| {
            const uri_str = try std.fmt.allocPrint(
                self.allocator,
                "{s}://test-{s}",
                .{ variant.toString(), ab_test_ptr.config.name },
            );
            defer self.allocator.free(uri_str);

            const parsed_uri = try WorldURI.parse(self.allocator, uri_str);
            
            const physics = switch (variant) {
                .baseline => PhysicsParams.baseline(),
                .variant => PhysicsParams.variantB(),
                .experimental => PhysicsParams.experimental(),
            };

            const w = try World.create(
                self.allocator,
                @intCast(i),
                parsed_uri,
                config.world_config,
                physics,
            );

            ab_test_ptr.worlds[i] = w;
        }

        // Run simulation for specified duration
        var runner = SimulationRunner.init(self.allocator);
        defer runner.deinit();

        for (ab_test_ptr.worlds) |maybe_world| {
            if (maybe_world) |w| {
                try runner.addWorld(w, config.random_seed);
            }
        }

        try runner.runTicks(config.duration_ticks);
    }
};

/// Configuration for simulation runs
pub const SimulationConfig = struct {
    world_config: WorldConfig = .{},
    duration_ticks: u32 = 1000,
    random_seed: u64 = 42,
};

/// Example: Create worlds for A/B/C testing
pub fn createABCWorlds(
    allocator: std.mem.Allocator,
    base_name: []const u8,
) error{OutOfMemory}![3]World {
    var worlds: [3]World = undefined;

    // World A: Baseline
    const uri_a = try std.fmt.allocPrint(allocator, "a://{s}", .{base_name});
    defer allocator.free(uri_a);
    var parsed_a = try WorldURI.parse(allocator, uri_a);
    worlds[0] = try World.create(
        allocator,
        1,
        parsed_a,
        WorldConfig{},
        PhysicsParams.baseline(),
    );

    // World B: Variant
    const uri_b = try std.fmt.allocPrint(allocator, "b://{s}", .{base_name});
    defer allocator.free(uri_b);
    var parsed_b = try WorldURI.parse(allocator, uri_b);
    worlds[1] = try World.create(
        allocator,
        2,
        parsed_b,
        WorldConfig{},
        PhysicsParams.variantB(),
    );

    // World C: Experimental
    const uri_c = try std.fmt.allocPrint(allocator, "c://{s}", .{base_name});
    defer allocator.free(uri_c);
    var parsed_c = try WorldURI.parse(allocator, uri_c);
    worlds[2] = try World.create(
        allocator,
        3,
        parsed_c,
        WorldConfig{},
        PhysicsParams.experimental(),
    );

    return worlds;
}

/// Example: Run a 3-player multiplayer test
pub fn runMultiplayerTest(
    allocator: std.mem.Allocator,
    framework: *Framework,
) !void {
    // Create a test
    var my_test = try framework.createTest("Multiplayer Test", .round_robin);
    ab_test.start();

    // Create session
    var session = try framework.createSession(60);

    // Create worlds for each player
    const world_a = try createTestWorld(allocator, .baseline);
    const world_b = try createTestWorld(allocator, .variant);
    const world_c = try createTestWorld(allocator, .experimental);

    // Join 3 players
    _ = try session.joinPlayer(1, "Alice", .baseline, world_a);
    _ = try session.joinPlayer(2, "Bob", .variant, world_b);
    _ = try session.joinPlayer(3, "Charlie", .experimental, world_c);

    // Run simulation
    var i: u32 = 0;
    while (i < 100) : (i += 1) {
        try session.tick();
    }
}

fn createTestWorld(allocator: std.mem.Allocator, variant: WorldVariant) !World {
    const uri_str = try std.fmt.allocPrint(allocator, "{s}://test", .{variant.toString()});
    defer allocator.free(uri_str);
    
    var parsed = try WorldURI.parse(allocator, uri_str);
    
    const physics = switch (variant) {
        .baseline => PhysicsParams.baseline(),
        .variant => PhysicsParams.variantB(),
        .experimental => PhysicsParams.experimental(),
    };

    return try World.create(
        allocator,
        1,
        parsed,
        WorldConfig{},
        physics,
    );
}

// ============== Tests ==============

test "Framework - create and run test" {
    const allocator = std.testing.allocator;

    var framework = init(allocator);
    defer framework.deinit();

    const test1 = try framework.createTest("Test1", .round_robin);
    test1.start();

    try std.testing.expectEqual(ABTest.TestStatus.running, test1.status);
}

test "createABCWorlds" {
    const allocator = std.testing.allocator;

    const worlds = try createABCWorlds(allocator, "abc-test");
    defer {
        for (&worlds) |*w| {
            w.destroy();
        }
    }

    try std.testing.expectEqual(PhysicsParams.baseline().gravity, worlds[0].physics.gravity);
    try std.testing.expectEqual(PhysicsParams.variantB().gravity, worlds[1].physics.gravity);
    try std.testing.expectEqual(PhysicsParams.experimental().gravity, worlds[2].physics.gravity);
}
