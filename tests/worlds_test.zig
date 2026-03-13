//! Worlds integration smoke tests against the current public API.

const std = @import("std");
const testing = std.testing;
const worlds = @import("worlds");

test "world helper constructors create expected variants" {
    const allocator = testing.allocator;

    const a = try worlds.worldA(allocator, "baseline");
    defer a.destroy();
    const b = try worlds.worldB(allocator, "variant");
    defer b.destroy();
    const c = try worlds.worldC(allocator, "control");
    defer c.destroy();

    try testing.expectEqual(worlds.WorldVariant.A, a.uri.variant);
    try testing.expectEqual(worlds.WorldVariant.B, b.uri.variant);
    try testing.expectEqual(worlds.WorldVariant.C, c.uri.variant);
    try testing.expectEqualStrings("baseline", a.uri.name);
}

test "ab test hash assignment is stable" {
    const allocator = testing.allocator;

    var ab_test = try worlds.ABTest.init(allocator, .{
        .name = "smoke",
        .duration_ms = 1_000,
        .min_samples = 2,
        .confidence_threshold = 0.95,
        .metric_weights = .{
            .engagement = 0.4,
            .success = 0.4,
            .duration = 0.2,
        },
    }, 42);
    defer ab_test.deinit();

    const first = try ab_test.assignPlayer("alice", .HashBased, null);
    const second = try ab_test.assignPlayer("alice", .HashBased, null);

    try testing.expectEqual(first, second);
}

test "persistent vector and versioned state exports work" {
    const allocator = testing.allocator;

    var vec = worlds.PersistentVector(i64).init(allocator);
    defer vec.deinit();
    try testing.expect(vec.isEmpty());

    var state = try worlds.VersionedState(i64).init(allocator, 0);
    defer state.deinit();
    try state.commit(10);
    try state.commit(20);
    try testing.expectEqual(@as(i64, 20), state.getCurrent());
    try testing.expect(state.undo());
    try testing.expectEqual(@as(i64, 10), state.getCurrent());
}

test "brain state serializes to syrup" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

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
    try testing.expect(syrup_val == .dictionary);
}

test "benchmark adapter runs world benchmark" {
    const allocator = testing.allocator;

    var adapter = try worlds.BenchmarkAdapter.init(allocator);
    defer adapter.deinit();

    const result = try adapter.benchmarkWorld("a://benchmark-test", 10, .tick);
    try testing.expectEqualStrings("a://benchmark-test", result.world_uri);
    try testing.expectEqual(@as(usize, 10), result.iterations);
    try testing.expect(result.avg_ns > 0);
}

test "module version" {
    try testing.expectEqualStrings("0.1.0", worlds.getVersion());
}
