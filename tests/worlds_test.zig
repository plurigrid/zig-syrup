//! World A/B Testing Test Suite
//!
//! Tests world creation/destruction, A/B assignment correctness,
//! multiplayer synchronization, immer structures, and ewig persistence.

const std = @import("std");
const testing = std.testing;
const worlds = @import("worlds");

// ========================================
// World Creation/Destruction Tests
// ========================================

test "world initialization" {
    const allocator = testing.allocator;
    
    var world = try worlds.createWorld(allocator, .{
        .uri = "test://world",
        .max_players = 4,
        .tile_system = .default,
    });
    defer world.deinit();
    
    try testing.expectEqualStrings("test://world", world.config.uri);
    try testing.expectEqual(@as(usize, 4), world.config.max_players);
    try testing.expectEqual(@as(u64, 0), world.getTick());
    try testing.expect(!world.isRunning());
}

test "world lifecycle" {
    const allocator = testing.allocator;
    
    var world = try worlds.createWorld(allocator, .{
        .uri = "test://world",
        .max_players = 2,
    });
    defer world.deinit();
    
    world.start();
    try testing.expect(world.isRunning());
    
    try world.tick();
    try world.tick();
    try testing.expectEqual(@as(u64, 2), world.getTick());
    
    world.stop();
    try testing.expect(!world.isRunning());
}

test "player management" {
    const allocator = testing.allocator;
    
    var world = try worlds.createWorld(allocator, .{
        .uri = "test://world",
        .max_players = 3,
    });
    defer world.deinit();
    
    const p1 = try world.addPlayer("Alice");
    const p2 = try world.addPlayer("Bob");
    
    try testing.expectEqual(@as(usize, 2), world.getPlayerCount());
    
    const player = world.getPlayer(p1);
    try testing.expect(player != null);
    try testing.expectEqualStrings("Alice", player.?.name);
    
    try world.removePlayer(p1);
    try testing.expectEqual(@as(usize, 1), world.getPlayerCount());
}

test "ab test assignment" {
    const allocator = testing.allocator;
    
    const variants = &[_]worlds.Variant{
        .{ .uri = "a://", .name = "A", .config = .{}, .weight = 50 },
        .{ .uri = "b://", .name = "B", .config = .{}, .weight = 50 },
    };
    
    var ab_test = try worlds.createABTest(allocator, variants);
    defer ab_test.deinit();
    
    try ab_test.start();
    
    const uri = try ab_test.assignPlayer(1);
    try testing.expect(uri.len > 0);
    
    // Consistent assignment
    const uri2 = try ab_test.assignPlayer(1);
    try testing.expectEqualStrings(uri, uri2);
}

test "persistent vector" {
    const allocator = testing.allocator;
    
    var vec = worlds.PersistentVector(i64).init(allocator);
    defer vec.deinit();
    
    try testing.expect(vec.isEmpty());
}

test "versioned state" {
    const allocator = testing.allocator;
    
    var state = try worlds.VersionedState(i64).init(allocator, 0);
    defer state.deinit();
    
    try state.commit(10);
    try state.commit(20);
    
    try testing.expectEqual(@as(i64, 20), state.getCurrent());
    
    try testing.expect(state.undo());
    try testing.expectEqual(@as(i64, 10), state.getCurrent());
}

test "brain state" {
    const allocator = testing.allocator;
    
    const brain_state = worlds.BrainState{
        .timestamp = 0,
        .focus_level = 0.75,
        .relaxation_level = 0.60,
        .engagement_level = 0.80,
        .fatigue_level = 0.20,
        .band_powers = .{ 0.1, 0.2, 0.3, 0.4, 0.0 },
        .signal_quality = .{0.9} ** worlds.EEGChannel.COUNT,
    };
    
    const syrup_val = try brain_state.toSyrup(allocator);
    defer {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
    }
    
    try testing.expect(syrup_val == .dictionary);
}

test "circuit world" {
    const allocator = testing.allocator;
    
    var world = try worlds.createWorld(allocator, .{
        .uri = "circuit://test",
        .max_players = 2,
    });
    defer world.deinit();
    
    var circuit = try worlds.createCircuitWorld(allocator, world);
    defer circuit.deinit();
    
    try circuit.compile();
    _ = circuit.getStats();
}

test "benchmark adapter" {
    const allocator = testing.allocator;
    
    var adapter = try worlds.BenchmarkAdapter.init(allocator);
    defer adapter.deinit();
    
    const result = try adapter.benchmarkWorld(
        .{
            .uri = "benchmark://test",
            .max_players = 4,
        },
        10,
        .tick,
    );
    
    try testing.expectEqualStrings("benchmark://test", result.world_uri);
    try testing.expect(result.avg_ns > 0);
}

test "module version" {
    try testing.expectEqualStrings("0.1.0", worlds.getVersion());
}
