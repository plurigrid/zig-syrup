//! World A/B Testing Demo
//!
//! Demonstrates:
//! - Creating 3 world variants
//! - Running simulation with 3 players
//! - A/B test results
//! - Immer persistence

const std = @import("std");
const worlds = @import("worlds");
const syrup = @import("syrup");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    std.debug.print("\n╔══════════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║        World A/B Testing System - Demo                       ║\n", .{});
    std.debug.print("╚══════════════════════════════════════════════════════════════╝\n\n", .{});
    
    // Initialize worlds module
    worlds.init(.{ .debug = true });
    std.debug.print("✓ Worlds module initialized (version {s})\n\n", .{worlds.getVersion()});
    
    // ========================================
    // Part 1: Create 3 World Variants
    // ========================================
    std.debug.print("── Creating 3 World Variants ──\n\n", .{});
    
    // Variant A: Baseline
    var world_a = try worlds.createWorld(allocator, .{
        .uri = "a://baseline",
        .max_players = 3,
        .tile_system = .default,
        .persistent = true,
    });
    defer world_a.deinit();
    
    try world_a.setParameter("difficulty", 0.5);
    try world_a.setParameter("speed", 1.0);
    try world_a.setParameter("gravity", 9.8);
    
    std.debug.print("  Variant A (baseline): {s}\n", .{world_a.config.uri});
    std.debug.print("    - Difficulty: {d:.1}\n", .{world_a.getParameter("difficulty").?});
    std.debug.print("    - Speed: {d:.1}\n", .{world_a.getParameter("speed").?});
    
    // Variant B: Hard Mode
    var world_b = try worlds.createWorld(allocator, .{
        .uri = "b://hard_mode",
        .max_players = 3,
        .tile_system = .default,
        .persistent = true,
    });
    defer world_b.deinit();
    
    try world_b.setParameter("difficulty", 0.9);
    try world_b.setParameter("speed", 1.5);
    try world_b.setParameter("gravity", 15.0);
    
    std.debug.print("  Variant B (hard): {s}\n", .{world_b.config.uri});
    std.debug.print("    - Difficulty: {d:.1}\n", .{world_b.getParameter("difficulty").?});
    std.debug.print("    - Speed: {d:.1}\n", .{world_b.getParameter("speed").?});
    
    // Variant C: Zero-G Mode
    var world_c = try worlds.createWorld(allocator, .{
        .uri = "c://zero_g",
        .max_players = 3,
        .tile_system = .default,
        .persistent = true,
    });
    defer world_c.deinit();
    
    try world_c.setParameter("difficulty", 0.3);
    try world_c.setParameter("speed", 0.8);
    try world_c.setParameter("gravity", 0.1);
    
    std.debug.print("  Variant C (zero-g): {s}\n", .{world_c.config.uri});
    std.debug.print("    - Difficulty: {d:.1}\n", .{world_c.getParameter("difficulty").?});
    std.debug.print("    - Speed: {d:.1}\n", .{world_c.getParameter("speed").?});
    std.debug.print("    - Gravity: {d:.1} (near zero!)\n", .{world_c.getParameter("gravity").?});
    
    // ========================================
    // Part 2: Add 3 Players to Each World
    // ========================================
    std.debug.print("\n── Adding 3 Players to Each World ──\n\n", .{});
    
    const player_names = [_][]const u8{ "Alice", "Bob", "Charlie" };
    
    // Add to World A
    std.debug.print("  World A players:\n", .{});
    for (player_names) |name| {
        const id = try world_a.addPlayer(name);
        std.debug.print("    [{d}] {s}\n", .{ id, name });
    }
    
    // Add to World B
    std.debug.print("  World B players:\n", .{});
    for (player_names) |name| {
        const id = try world_b.addPlayer(name);
        std.debug.print("    [{d}] {s}\n", .{ id, name });
    }
    
    // Add to World C
    std.debug.print("  World C players:\n", .{});
    for (player_names) |name| {
        const id = try world_c.addPlayer(name);
        std.debug.print("    [{d}] {s}\n", .{ id, name });
    }
    
    // ========================================
    // Part 3: Run Simulations
    // ========================================
    std.debug.print("\n── Running Simulations ──\n\n", .{});
    
    // Simulate World A
    world_a.start();
    std.debug.print("  World A simulation:\n", .{});
    for (0..10) |i| {
        try world_a.tick();
        if (i % 3 == 0) {
            std.debug.print("    Tick {d}: {d} active players\n", .{
                world_a.getTick(),
                world_a.getPlayerCount(),
            });
        }
    }
    world_a.stop();
    try world_a.snapshot();
    std.debug.print("    ✓ Snapshot saved\n", .{});
    
    // Simulate World B
    world_b.start();
    std.debug.print("  World B simulation:\n", .{});
    for (0..10) |i| {
        try world_b.tick();
        if (i % 3 == 0) {
            std.debug.print("    Tick {d}: {d} active players\n", .{
                world_b.getTick(),
                world_b.getPlayerCount(),
            });
        }
    }
    world_b.stop();
    try world_b.snapshot();
    std.debug.print("    ✓ Snapshot saved\n", .{});
    
    // Simulate World C
    world_c.start();
    std.debug.print("  World C simulation:\n", .{});
    for (0..10) |i| {
        try world_c.tick();
        if (i % 3 == 0) {
            std.debug.print("    Tick {d}: {d} active players\n", .{
                world_c.getTick(),
                world_c.getPlayerCount(),
            });
        }
    }
    world_c.stop();
    try world_c.snapshot();
    std.debug.print("    ✓ Snapshot saved\n", .{});
    
    // ========================================
    // Part 4: A/B Test Framework
    // ========================================
    std.debug.print("\n── A/B Testing Framework ──\n\n", .{});
    
    const variants = &[_]worlds.Variant{
        .{
            .uri = "a://baseline",
            .name = "Baseline",
            .config = .{},
            .weight = 40,
        },
        .{
            .uri = "b://hard_mode",
            .name = "Hard Mode",
            .config = .{},
            .weight = 30,
        },
        .{
            .uri = "c://zero_g",
            .name = "Zero-G Mode",
            .config = .{},
            .weight = 30,
        },
    };
    
    var ab_test = try worlds.createABTest(allocator, variants);
    defer ab_test.deinit();
    
    // Configure test
    ab_test.config = .{
        .name = "World Mode Comparison",
        .description = "Comparing baseline, hard mode, and zero-g",
        .consistent_assignment = true,
    };
    
    try ab_test.start();
    std.debug.print("  Test: {s}\n", .{ab_test.config.name});
    std.debug.print("  Variants: {d} (weights: 40/30/30)\n", .{ab_test.variants.items.len});
    
    // Simulate player assignments
    std.debug.print("\n  Player Assignments:\n", .{});
    for (0..12) |i| {
        const player_id: u32 = @intCast(i);
        const uri = try ab_test.assignPlayer(player_id);
        
        // Simulate some metric
        const metric = switch (uri[0]) {
            'a' => 100.0 + @as(f64, @floatFromInt(i % 10)),
            'b' => 80.0 + @as(f64, @floatFromInt(i % 15)),
            'c' => 120.0 + @as(f64, @floatFromInt(i % 20)),
            else => 0.0,
        };
        try ab_test.recordMetric(uri, metric);
        
        if (i < 6) {
            std.debug.print("    Player {d} → {s} (score: {d:.0})\n", .{ player_id, uri, metric });
        } else if (i == 6) {
            std.debug.print("    ... ({d} more assignments)\n", .{12 - i});
        }
    }
    
    // Show metrics
    std.debug.print("\n  Variant Metrics:\n", .{});
    for (variants) |v| {
        const metrics = ab_test.getMetrics(v.uri).?;
        std.debug.print("    {s}: n={d}, mean={d:.1}, std={d:.1}\n", .{
            v.name,
            metrics.samples,
            metrics.mean(),
            metrics.stdDev(),
        });
    }
    
    // Comparison
    const comparison = ab_test.compareVariants("a://baseline", "b://hard_mode");
    std.debug.print("\n  Comparison (Baseline vs Hard):\n", .{});
    std.debug.print("    Difference: {d:.1}\n", .{comparison.difference});
    std.debug.print("    Relative: {d:.1}%\n", .{comparison.relative_change * 100});
    
    // ========================================
    // Part 5: Syrup Integration
    // ========================================
    std.debug.print("\n── Syrup Integration ──\n\n", .{});
    
    // Serialize World A to Syrup
    const world_syrup = try world_a.toSyrup(allocator);
    defer {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
    }
    
    var buf: [4096]u8 = undefined;
    const encoded = try world_syrup.encodeBuf(&buf);
    std.debug.print("  World A serialized: {d} bytes\n", .{encoded.len});
    
    // Serialize A/B test
    const test_syrup = try ab_test.toSyrup(allocator);
    const test_encoded = try test_syrup.encodeBuf(&buf);
    std.debug.print("  A/B test serialized: {d} bytes\n", .{test_encoded.len});
    
    // ========================================
    // Part 6: Circuit Integration
    // ========================================
    std.debug.print("\n── Circuit Integration ──\n\n", .{});
    
    var circuit_world = try worlds.createCircuitWorld(allocator, world_a);
    defer circuit_world.deinit();
    
    try circuit_world.compile();
    const stats = circuit_world.getStats();
    
    std.debug.print("  Circuit compiled:\n", .{});
    std.debug.print("    Gates: {d}\n", .{stats.num_gates});
    std.debug.print("    Wires: {d}\n", .{stats.num_wires});
    std.debug.print("    Public inputs: {d}\n", .{stats.num_public_inputs});
    
    // Evaluate circuit
    const circuit_input = worlds.CircuitInput{
        .player_inputs = &[_]worlds.CircuitInput.PlayerInput{
            .{ .player_id = 0, .action = .move, .data = 100 },
            .{ .player_id = 1, .action = .interact, .data = 50 },
            .{ .player_id = 2, .action = .defend, .data = 25 },
        },
        .parameters = &[_]worlds.CircuitInput.Parameter{
            .{ .name = "difficulty", .value = 5 },
            .{ .name = "seed", .value = 42 },
        },
        .seed = 12345,
    };
    
    const circuit_output = try circuit_world.evaluate(circuit_input);
    defer allocator.free(circuit_output.player_results);
    defer allocator.free(circuit_output.events);
    
    std.debug.print("  Circuit evaluated:\n", .{});
    std.debug.print("    Final tick: {d}\n", .{circuit_output.final_tick});
    std.debug.print("    Player results: {d}\n", .{circuit_output.player_results.len});
    
    // ========================================
    // Part 7: OpenBCI Bridge
    // ========================================
    std.debug.print("\n── OpenBCI Bridge ──\n\n", .{});
    
    var bridge = try worlds.createOpenBCIBridge(allocator, world_a);
    defer bridge.deinit();
    
    // Map players to EEG channels
    try bridge.mapPlayer(0, &[_]worlds.EEGChannel{ .ch1, .ch2 });
    try bridge.mapPlayer(1, &[_]worlds.EEGChannel{ .ch3, .ch4 });
    try bridge.mapPlayer(2, &[_]worlds.EEGChannel{ .ch5, .ch6 });
    
    std.debug.print("  Players mapped to EEG channels:\n", .{});
    std.debug.print("    Alice → Channels 1,2\n", .{});
    std.debug.print("    Bob → Channels 3,4\n", .{});
    std.debug.print("    Charlie → Channels 5,6\n", .{});
    
    // Simulate EEG data
    std.debug.print("\n  Simulating EEG data:\n", .{});
    for (0..5) |i| {
        const focus = 0.5 + @as(f32, @floatFromInt(i)) * 0.1;
        const sample = try bridge.createSimulatedSample(focus);
        try bridge.processSample(sample);
        
        if (i == 0) {
            std.debug.print("    Sample {d}: focus={d:.2}, ch1={d:.1}µV\n", .{
                i, focus, sample.channels[0],
            });
        }
    }
    
    const bridge_stats = bridge.getStats();
    std.debug.print("  Total samples processed: {d}\n", .{bridge_stats.total_samples});
    
    // ========================================
    // Part 8: Benchmark Results
    // ========================================
    std.debug.print("\n── Benchmark Results ──\n\n", .{});
    
    var bench_adapter = try worlds.BenchmarkAdapter.init(allocator);
    defer bench_adapter.deinit();
    
    const bench_result = try bench_adapter.benchmarkWorld(
        .{
            .uri = "demo://benchmark",
            .max_players = 3,
        },
        100,
        .full_simulation,
    );
    
    std.debug.print("  Benchmark: {s}\n", .{bench_result.world_uri});
    std.debug.print("  Iterations: {d}\n", .{bench_result.iterations});
    std.debug.print("  Average: {d} ns/op\n", .{bench_result.avg_ns});
    std.debug.print("  Throughput: {d} ops/sec\n", .{bench_result.ops_per_sec});
    std.debug.print("  State size: {d} bytes\n", .{bench_result.world_metrics.state_size_bytes});
    
    // ========================================
    // Summary
    // ========================================
    std.debug.print("\n╔══════════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║        Demo Complete!                                        ║\n", .{});
    std.debug.print("╚══════════════════════════════════════════════════════════════╝\n\n", .{});
    
    std.debug.print("Summary:\n", .{});
    std.debug.print("  ✓ Created 3 world variants (baseline, hard, zero-g)\n", .{});
    std.debug.print("  ✓ Added 3 players to each world\n", .{});
    std.debug.print("  ✓ Ran simulations with state snapshots\n", .{});
    std.debug.print("  ✓ Set up A/B test with weighted assignment\n", .{});
    std.debug.print("  ✓ Serialized worlds to Syrup format\n", .{});
    std.debug.print("  ✓ Compiled and evaluated circuit representation\n", .{});
    std.debug.print("  ✓ Integrated OpenBCI brain-computer interface\n", .{});
    std.debug.print("  ✓ Benchmarked performance\n", .{});
    std.debug.print("\nAll systems operational!\n", .{});
}
