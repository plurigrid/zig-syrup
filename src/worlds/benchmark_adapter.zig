//! Benchmark adapter for world A/B testing
//!
//! Integrates with zig-syrup's benchmark system to measure
//! world variant performance and memory usage.

const std = @import("std");
const Allocator = std.mem.Allocator;
const syrup = @import("syrup");
const World = @import("world.zig").World;
const WorldVariant = @import("world.zig").WorldVariant;
const ABTest = @import("ab_test.zig").ABTest;
const ABTestConfig = @import("ab_test.zig").ABTestConfig;

/// Memory tracker for immer-style structures
pub const MemoryTracker = struct {
    const Self = @This();

    total_allocated: usize,
    total_freed: usize,
    peak_usage: usize,
    current_usage: usize,
    allocation_count: u64,

    pub fn init() Self {
        return .{
            .total_allocated = 0,
            .total_freed = 0,
            .peak_usage = 0,
            .current_usage = 0,
            .allocation_count = 0,
        };
    }

    pub fn recordAllocation(self: *Self, size: usize) void {
        self.total_allocated += size;
        self.current_usage += size;
        self.allocation_count += 1;
        if (self.current_usage > self.peak_usage) {
            self.peak_usage = self.current_usage;
        }
    }

    pub fn recordFree(self: *Self, size: usize) void {
        self.total_freed += size;
        self.current_usage -= size;
    }

    pub fn getStats(self: Self) MemoryStats {
        return .{
            .total_allocated = self.total_allocated,
            .current_usage = self.current_usage,
            .peak_usage = self.peak_usage,
            .allocation_count = self.allocation_count,
        };
    }

    pub const MemoryStats = struct {
        total_allocated: usize,
        current_usage: usize,
        peak_usage: usize,
        allocation_count: u64,
    };
};

/// World benchmark result
pub const WorldBenchmark = struct {
    /// World URI
    world_uri: []const u8,
    /// Number of iterations
    iterations: usize,
    /// Total time in nanoseconds
    total_ns: i128,
    /// Average time per operation
    avg_ns: i128,
    /// Operations per second
    ops_per_sec: i128,
    /// Memory statistics
    memory: MemoryTracker.MemoryStats,
    /// World-specific metrics
    world_metrics: WorldMetrics,

    pub const WorldMetrics = struct {
        player_count: usize,
        tick_count: u64,
        state_size_bytes: usize,
    };

    pub fn format(
        self: WorldBenchmark,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;

        try writer.print(
            "WorldBenchmark({s}): {d} ops, {d} ns/op, {d} ops/sec\n",
            .{
                self.world_uri,
                self.iterations,
                self.avg_ns,
                self.ops_per_sec,
            },
        );
        try writer.print(
            "  Memory: peak={d}B, allocs={d}\n",
            .{ self.memory.peak_usage, self.memory.allocation_count },
        );
        try writer.print(
            "  World: players={d}, ticks={d}, state={d}B\n",
            .{
                self.world_metrics.player_count,
                self.world_metrics.tick_count,
                self.world_metrics.state_size_bytes,
            },
        );
    }
};

/// Benchmark comparison result
pub const BenchmarkComparison = struct {
    /// Baseline benchmark
    baseline: WorldBenchmark,
    /// Variant benchmarks
    variants: []const WorldBenchmark,
    /// Statistical comparison
    comparisons: []const VariantComparison,

    pub const VariantComparison = struct {
        variant_uri: []const u8,
        /// Relative performance (1.0 = same, 0.5 = 2x faster)
        relative_speed: f64,
        /// Relative memory usage
        relative_memory: f64,
        /// Significance level (p-value approximation)
        significance: f64,
    };

    /// Generate report
    pub fn generateReport(self: BenchmarkComparison, allocator: Allocator) ![]const u8 {
        var report = std.ArrayList(u8).init(allocator);
        defer report.deinit();

        const writer = report.writer();

        try writer.print("World Benchmark Comparison Report\n", .{});
        try writer.print("=================================\n\n", .{});

        try writer.print("Baseline: {s}\n", .{self.baseline.world_uri});
        try writer.print("  Performance: {d} ns/op\n", .{self.baseline.avg_ns});
        try writer.print("  Memory peak: {d} bytes\n\n", .{self.baseline.memory.peak_usage});

        for (self.variants, self.comparisons) |variant, comp| {
            try writer.print("Variant: {s}\n", .{variant.world_uri});
            try writer.print("  Performance: {d} ns/op ({d:.1}x)\n", .{
                variant.avg_ns,
                1.0 / comp.relative_speed,
            });
            try writer.print("  Memory: {d:.1}x baseline\n", .{comp.relative_memory});
            try writer.print("  Significance: p={d:.3}\n\n", .{comp.significance});
        }

        return report.toOwnedSlice();
    }
};

/// Benchmark adapter for world performance testing
pub const BenchmarkAdapter = struct {
    const Self = @This();

    allocator: Allocator,
    memory_tracker: MemoryTracker,
    results: std.ArrayListUnmanaged(WorldBenchmark),

    pub fn init(allocator: Allocator) !Self {
        return .{
            .allocator = allocator,
            .memory_tracker = MemoryTracker.init(),
            .results = .{},
        };
    }

    pub fn deinit(self: *Self) void {
        self.results.deinit(self.allocator);
    }

    /// Benchmark a single world
    pub fn benchmarkWorld(
        self: *Self,
        world_uri: []const u8,
        iterations: usize,
        comptime benchmark_type: BenchmarkType,
    ) !WorldBenchmark {
        const start_time = std.time.nanoTimestamp();

        // Track memory at start
        const mem_start = self.memory_tracker.getStats();

        // Create world
        const world = try World.create(self.allocator, world_uri, null);
        defer world.destroy();

        // Run benchmark using available World operations
        switch (benchmark_type) {
            .tick => {
                for (0..iterations) |i| {
                    try world.setParam("tick", .{ .Int = @intCast(i) });
                }
            },
            .serialization => {
                for (0..iterations) |i| {
                    try world.setParam("ser_iter", .{ .Int = @intCast(i) });
                    _ = try world.snapshot();
                }
            },
            .full_simulation => {
                for (0..iterations) |i| {
                    try world.setParam("sim_iter", .{ .Int = @intCast(i) });
                    if (i % 10 == 0) {
                        _ = try world.snapshot();
                    }
                }
            },
        }

        const end_time = std.time.nanoTimestamp();
        const total_ns = end_time - start_time;
        const avg_ns = @divFloor(total_ns, iterations);
        const ops_per_sec = if (avg_ns > 0) @divFloor(@as(i128, 1_000_000_000), avg_ns) else 0;

        // Get memory stats
        const mem_end = self.memory_tracker.getStats();

        const benchmark = WorldBenchmark{
            .world_uri = world_uri,
            .iterations = iterations,
            .total_ns = total_ns,
            .avg_ns = avg_ns,
            .ops_per_sec = ops_per_sec,
            .memory = .{
                .total_allocated = mem_end.total_allocated - mem_start.total_allocated,
                .current_usage = mem_end.current_usage,
                .peak_usage = mem_end.peak_usage - mem_start.peak_usage,
                .allocation_count = mem_end.allocation_count - mem_start.allocation_count,
            },
            .world_metrics = .{
                .player_count = 0,
                .tick_count = iterations,
                .state_size_bytes = 0,
            },
        };

        try self.results.append(self.allocator, benchmark);
        return benchmark;
    }

    /// Run comparison between multiple world URIs (variants)
    pub fn runComparison(
        self: *Self,
        world_uris: []const []const u8,
        iterations: usize,
    ) !BenchmarkComparison {
        if (world_uris.len < 2) {
            return error.InsufficientVariants;
        }

        var benchmarks = std.ArrayListUnmanaged(WorldBenchmark){};
        defer benchmarks.deinit(self.allocator);

        // Benchmark each variant
        for (world_uris) |uri| {
            const result = try self.benchmarkWorld(uri, iterations, .full_simulation);
            try benchmarks.append(self.allocator, result);
        }

        // Calculate comparisons
        var comparisons = std.ArrayListUnmanaged(BenchmarkComparison.VariantComparison){};
        defer comparisons.deinit(self.allocator);

        const baseline = benchmarks.items[0];

        for (benchmarks.items[1..]) |variant| {
            const relative_speed = if (baseline.avg_ns > 0)
                @as(f64, @floatFromInt(baseline.avg_ns)) / @as(f64, @floatFromInt(variant.avg_ns))
            else
                1.0;

            const relative_memory = if (baseline.memory.peak_usage > 0)
                @as(f64, @floatFromInt(variant.memory.peak_usage)) / @as(f64, @floatFromInt(baseline.memory.peak_usage))
            else
                1.0;

            try comparisons.append(self.allocator, .{
                .variant_uri = variant.world_uri,
                .relative_speed = relative_speed,
                .relative_memory = relative_memory,
                .significance = 0.05, // Placeholder
            });
        }

        return BenchmarkComparison{
            .baseline = baseline,
            .variants = try self.allocator.dupe(WorldBenchmark, benchmarks.items[1..]),
            .comparisons = try self.allocator.dupe(BenchmarkComparison.VariantComparison, comparisons.items),
        };
    }

    /// Benchmark A/B test framework overhead
    pub fn benchmarkABTest(
        self: *Self,
        variant_count: usize,
        assignments_per_variant: usize,
    ) !ABTestBenchmark {
        const start_time = std.time.nanoTimestamp();

        // Create A/B test with default config
        const config = ABTestConfig{
            .name = "benchmark",
            .duration_ms = 60 * 60 * 1000,
            .min_samples = 10,
            .confidence_threshold = 0.95,
            .metric_weights = .{ .engagement = 0.4, .success = 0.4, .duration = 0.2 },
        };
        var ab_test = try ABTest.init(self.allocator, config, 42);
        defer ab_test.deinit();

        ab_test.start();

        // Run assignments
        const total_assignments = variant_count * assignments_per_variant;
        for (0..total_assignments) |i| {
            const player_id = try std.fmt.allocPrint(self.allocator, "player_{d}", .{i});
            defer self.allocator.free(player_id);
            _ = try ab_test.assignPlayer(player_id, .RoundRobin, null);
        }

        const end_time = std.time.nanoTimestamp();
        const total_ns = end_time - start_time;

        return ABTestBenchmark{
            .variant_count = variant_count,
            .assignments = total_assignments,
            .total_ns = total_ns,
            .ns_per_assignment = @divFloor(total_ns, total_assignments),
        };
    }

    pub const ABTestBenchmark = struct {
        variant_count: usize,
        assignments: usize,
        total_ns: i128,
        ns_per_assignment: i128,
    };

    /// Get all results
    pub fn getResults(self: Self) []const WorldBenchmark {
        return self.results.items;
    }

    /// Generate summary report
    pub fn generateReport(self: Self, allocator: Allocator) ![]const u8 {
        var report = std.ArrayListUnmanaged(u8){};
        defer report.deinit(allocator);

        const writer = report.writer(allocator);

        try writer.print("World Benchmark Summary\n", .{});
        try writer.print("=======================\n\n", .{});

        for (self.results.items) |result| {
            try writer.print("{s}\n", .{result});
        }

        return report.toOwnedSlice(allocator);
    }

    /// Clear all results
    pub fn clearResults(self: *Self) void {
        self.results.clearRetainingCapacity();
    }
};

/// Benchmark type selection
pub const BenchmarkType = enum {
    /// Benchmark tick simulation only
    tick,
    /// Benchmark serialization
    serialization,
    /// Benchmark full simulation (tick + snapshot)
    full_simulation,
};

// Tests
const testing = std.testing;

test "memory tracker" {
    var tracker = MemoryTracker.init();

    tracker.recordAllocation(100);
    tracker.recordAllocation(200);
    tracker.recordFree(100);

    const stats = tracker.getStats();
    try testing.expectEqual(@as(usize, 300), stats.total_allocated);
    try testing.expectEqual(@as(usize, 200), stats.current_usage);
    try testing.expectEqual(@as(usize, 300), stats.peak_usage);
}

test "benchmark adapter" {
    const allocator = testing.allocator;

    var adapter = try BenchmarkAdapter.init(allocator);
    defer adapter.deinit();

    const result = try adapter.benchmarkWorld("a://benchmark-test", 10, .tick);

    try testing.expectEqualStrings("a://benchmark-test", result.world_uri);
    try testing.expectEqual(@as(usize, 10), result.iterations);
    try testing.expect(result.avg_ns > 0);
}

test "ab test benchmark" {
    const allocator = testing.allocator;

    var adapter = try BenchmarkAdapter.init(allocator);
    defer adapter.deinit();

    const result = try adapter.benchmarkABTest(3, 10);

    try testing.expectEqual(@as(usize, 3), result.variant_count);
    try testing.expectEqual(@as(usize, 30), result.assignments);
}
