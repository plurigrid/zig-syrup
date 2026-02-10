//! Worlds Module - A/B Testing Multiplayer System
//!
//! 3-player simultaneity with immutable data structures
//! a:// b:// c:// URI schemes
//! Ewig (eternal) persistence

const std = @import("std");

// Core world types
pub const world = @import("world.zig");
pub const World = world.World;
pub const WorldState = world.WorldState;
pub const WorldVariant = world.WorldVariant;
pub const WorldUri = world.WorldUri;

// A/B testing
pub const ab_test = @import("ab_test.zig");
pub const ABTest = ab_test.ABTest;
pub const ABTestConfig = ab_test.ABTestConfig;
pub const SessionMetrics = ab_test.SessionMetrics;
pub const TestResult = ab_test.TestResult;

// Multiplayer
// pub const multiplayer = @import("multiplayer.zig");
// pub const Session3P = multiplayer.Session3P;
// pub const Player = multiplayer.Player;
// pub const Action = multiplayer.Action;
// pub const Conflict = multiplayer.Conflict;

// Immutable data structures
// pub const immer = @import("immer.zig");
// pub const ImmutableArray = immer.ImmutableArray;
// pub const ImmutableMap = immer.ImmutableMap;

// URI handling
pub const uri = @import("uri.zig");
pub const UriResolver = uri.UriResolver;
pub const ParsedUri = uri.ParsedUri;
pub const ProtocolRegistry = uri.ProtocolRegistry;

// Simulation
// pub const simulation = @import("simulation.zig");
// pub const Simulation = simulation.Simulation;
// pub const SimConfig = simulation.SimConfig;
// pub const Tick = simulation.Tick;
// pub const DeterministicRng = simulation.DeterministicRng;

// Ewig (eternal) persistence
// pub const ewig = @import("ewig/ewig.zig");

// BCI-Aptos Bridge
pub const bci_aptos = @import("bci_aptos.zig");
pub const BciAptosBridge = bci_aptos.BciAptosBridge;
pub const BrainAction = bci_aptos.BrainAction;
pub const Neurofeedback = bci_aptos.Neurofeedback;

// Colored Parentheses World
pub const colored_parens = @import("colored_parens.zig");
pub const ColoredParensWorld = colored_parens.ColoredParensWorld;
pub const Expr = colored_parens.Expr;

// World Enumeration Engine (326 worlds via combinatorial cheatcodes)
pub const world_enum = @import("world_enum.zig");
pub const WorldEnumerator = world_enum.WorldEnumerator;
pub const WorldConfig = world_enum.WorldConfig;

/// Module version
pub const version = "0.1.0";

/// Initialize the worlds module
pub fn init(allocator: std.mem.Allocator) WorldsContext {
    return WorldsContext{
        .allocator = allocator,
        .resolver = UriResolver.init(allocator, 100 * 1024 * 1024),
    };
}

/// Context for world operations
pub const WorldsContext = struct {
    allocator: std.mem.Allocator,
    resolver: UriResolver,
    
    pub fn deinit(self: *WorldsContext) void {
        self.resolver.deinit();
    }
    
    /// Create a world from URI
    pub fn createWorld(self: *WorldsContext, uri_str: []const u8) !*World {
        return try self.resolver.resolve(uri_str);
    }
    
    /// Create A/B test
    pub fn createABTest(
        self: *WorldsContext,
        name: []const u8,
        variants: []const WorldVariant,
    ) !ABTest {
        const config = ABTestConfig{
            .name = name,
            .duration_ms = 60 * 60 * 1000, // 1 hour
            .min_samples = 100,
            .confidence_threshold = 0.95,
            .metric_weights = .{
                .engagement = 0.4,
                .success = 0.4,
                .duration = 0.2,
            },
        };
        
        var ab_test_instance = try ABTest.init(self.allocator, config, @intCast(std.time.milliTimestamp()));
        
        // Create worlds for variants
        for (variants) |variant| {
            const uri_str = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{
                variant.prefix(),
                name,
            });
            defer self.allocator.free(uri_str);
            
            const world_ptr = try self.createWorld(uri_str);
            try ab_test_instance.addWorld(variant, world_ptr);
        }
        
        return ab_test_instance;
    }
    
    // /// Create 3-player session
    // pub fn createSession3P(
    //     self: *WorldsContext,
    //     session_id: []const u8,
    // ) !*Session3P {
    //     return try Session3P.init(self.allocator, session_id, 20);
    // }
    
    // /// Create simulation
    // pub fn createSimulation(
    //     self: *WorldsContext,
    //     world_ptr: *World,
    //     tick_rate: u32,
    //     random_seed: u64,
    // ) !*Simulation {
    //     const config = SimConfig{
    //         .tick_rate_hz = tick_rate,
    //         .max_ticks = 1_000_000,
    //         .random_seed = random_seed,
    //         .deterministic = true,
    //     };
    //     
    //     return try Simulation.init(self.allocator, config, world_ptr);
    // }
};

/// Quick world creation helpers
pub fn worldA(allocator: std.mem.Allocator, name: []const u8) !*World {
    const uri_str = try std.fmt.allocPrint(allocator, "a://{s}", .{name});
    defer allocator.free(uri_str);
    return try World.create(allocator, uri_str, null);
}

pub fn worldB(allocator: std.mem.Allocator, name: []const u8) !*World {
    const uri_str = try std.fmt.allocPrint(allocator, "b://{s}", .{name});
    defer allocator.free(uri_str);
    return try World.create(allocator, uri_str, null);
}

pub fn worldC(allocator: std.mem.Allocator, name: []const u8) !*World {
    const uri_str = try std.fmt.allocPrint(allocator, "c://{s}", .{name});
    defer allocator.free(uri_str);
    return try World.create(allocator, uri_str, null);
}

/// Example: Create and run A/B test
pub fn exampleABTest(allocator: std.mem.Allocator) !void {
    var ctx = init(allocator);
    defer ctx.deinit();
    
    // Create worlds
    const baseline = try ctx.createWorld("a://baseline");
    const variant = try ctx.createWorld("b://variant");
    
    // Set different parameters
    try baseline.setParam("difficulty", .{ .Int = 5 });
    try variant.setParam("difficulty", .{ .Int = 7 });
    
    // Create test
    var ab_test_instance = try ctx.createABTest("my_test", &[_]WorldVariant{ .A, .B });
    defer ab_test_instance.deinit();
    
    // Add worlds
    try ab_test_instance.addWorld(.A, baseline);
    try ab_test_instance.addWorld(.B, variant);
    
    // Assign players
    _ = try ab_test_instance.assignPlayer("player1", .RoundRobin, null);
    _ = try ab_test_instance.assignPlayer("player2", .RoundRobin, null);
    _ = try ab_test_instance.assignPlayer("player3", .RoundRobin, null);
    
    // Start and collect metrics
    ab_test_instance.start();
    
    // ... run test ...
    
    // Get results
    const winner = try ab_test_instance.determineWinner();
    if (winner) |w| {
        std.log.info("Winner: {s}", .{w.prefix()});
    }
}

// /// Example: 3-player multiplayer
// pub fn exampleMultiplayer(allocator: std.mem.Allocator) !void {
//     var ctx = init(allocator);
//     defer ctx.deinit();
//     
//     // Create session
//     const session = try ctx.createSession3P("session-001");
//     defer session.deinit();
//     
//     // Create worlds for each player
//     const world1 = try ctx.createWorld("a://player1");
//     const world2 = try ctx.createWorld("a://player2");
//     const world3 = try ctx.createWorld("a://player3");
//     
//     // Add players
//     try session.addPlayer("alice", world1);
//     try session.addPlayer("bob", world2);
//     try session.addPlayer("charlie", world3);
//     
//     // Process actions
//     try session.receiveAction("alice", .Move, "x:10,y:20");
//     try session.receiveAction("bob", .Move, "x:15,y:25");
//     
//     try session.processActions();
//     try session.synchronize();
//     
//     // Check consistency
//     const check = session.checkConsistency();
//     if (!check.consistent) {
//         std.log.warn("Desync detected: {s}", .{check.player_hash_mismatch.?});
//     }
// }

// /// Example: Immutable data structures
// pub fn exampleImmer(allocator: std.mem.Allocator) !void {
//     // Array
//     var arr = ImmutableArray(i32).init(allocator);
//     defer arr.deinit();
//     
//     var arr2 = try arr.append(1);
//     defer arr2.deinit();
//     
//     var arr3 = try arr2.append(2);
//     defer arr3.deinit();
//     
//     std.log.info("arr[0] = {d}", .{arr3.get(0).?});
//     std.log.info("arr[1] = {d}", .{arr3.get(1).?});
//     
//     // Map
//     var map = ImmutableMap([]const u8, i32).init(allocator);
//     defer map.deinit();
//     
//     var map2 = try map.assoc("key1", 100);
//     defer map2.deinit();
//     
//     var map3 = try map2.assoc("key2", 200);
//     defer map3.deinit();
//     
//     std.log.info("map[key1] = {d}", .{map3.get("key1").?});
//     std.log.info("map[key2] = {d}", .{map3.get("key2").?});
// }

// /// Example: Deterministic simulation
// pub fn exampleSimulation(allocator: std.mem.Allocator) !void {
//     var ctx = init(allocator);
//     defer ctx.deinit();
//     
//     const world_ptr = try ctx.createWorld("a://sim-test");
//     defer world_ptr.destroy();
//     
//     const sim = try ctx.createSimulation(world_ptr, 60, 12345);
//     defer sim.deinit();
//     
//     // Run for 1000 ticks
//     var i: u64 = 0;
//     while (i < 1000) : (i += 1) {
//         try sim.tick();
//     }
//     
//     // Export history
//     try sim.exportHistory("replay.log");
//     
//     // Benchmark
//     const bench = try sim.benchmark(100);
//     std.log.info("TPS: {d:.2}", .{bench.ticks_per_second});
// }

// ============================================================================
// Tests
// ============================================================================

test "module integration" {
    const allocator = std.testing.allocator;
    
    var ctx = init(allocator);
    defer ctx.deinit();
    
    // Create worlds
    const w = try ctx.createWorld("a://test");
    try w.setParam("x", .{ .Int = 42 });
    
    try std.testing.expectEqual(@as(i64, 42), w.getParam("x").?.Int);
}

test "world helpers" {
    const allocator = std.testing.allocator;
    
    const wa = try worldA(allocator, "test-a");
    defer wa.destroy();
    
    const wb = try worldB(allocator, "test-b");
    defer wb.destroy();
    
    const wc = try worldC(allocator, "test-c");
    defer wc.destroy();
    
    try std.testing.expectEqual(WorldVariant.A, wa.uri.variant);
    try std.testing.expectEqual(WorldVariant.B, wb.uri.variant);
    try std.testing.expectEqual(WorldVariant.C, wc.uri.variant);
}
