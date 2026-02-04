//! A/B Testing Engine for World Variants
//!
//! Manages multiple world variants (A, B, C)
//! Player assignment and statistical analysis

const std = @import("std");
const World = @import("world.zig").World;
const WorldVariant = @import("world.zig").WorldVariant;
const ArrayList = std.ArrayList;
const StringHashMap = std.StringHashMap;
const Random = std.Random;

/// Metrics collected for each player session
pub const SessionMetrics = struct {
    player_id: []const u8,
    world_uri: []const u8,
    start_time: i64,
    end_time: ?i64,
    events: u32,
    actions: u32,
    engagement_score: f64, // 0-100
    success_score: f64, // 0-100
    error_count: u32,
    
    pub fn duration(self: SessionMetrics) i64 {
        const end = self.end_time orelse std.time.milliTimestamp();
        return end - self.start_time;
    }
};

/// Aggregated metrics for a variant
pub const VariantMetrics = struct {
    variant: WorldVariant,
    sessions: u32,
    total_duration_ms: i64,
    avg_engagement: f64,
    avg_success: f64,
    total_errors: u32,
    conversion_rate: f64,
};

/// Statistical test result
pub const TestResult = struct {
    variant_a: WorldVariant,
    variant_b: WorldVariant,
    winner: ?WorldVariant,
    confidence: f64, // 0-1 (p-value complement)
    improvement_pct: f64,
    significant: bool,
};

/// A/B Test configuration
pub const ABTestConfig = struct {
    name: []const u8,
    duration_ms: i64,
    min_samples: u32,
    confidence_threshold: f64, // e.g., 0.95 for 95%
    metric_weights: struct {
        engagement: f64,
        success: f64,
        duration: f64,
    },
};

/// A/B Test engine
pub const ABTest = struct {
    allocator: std.mem.Allocator,
    config: ABTestConfig,
    worlds: StringHashMap(*World),
    player_assignments: StringHashMap(WorldVariant),
    metrics: ArrayList(SessionMetrics),
    random: Random,
    start_time: ?i64,
    
    pub fn init(
        allocator: std.mem.Allocator,
        config: ABTestConfig,
        random_seed: u64,
    ) !ABTest {
        var prng = std.Random.DefaultPrng.init(random_seed);
        
        return ABTest{
            .allocator = allocator,
            .config = config,
            .worlds = StringHashMap(*World).init(allocator),
            .player_assignments = StringHashMap(WorldVariant).init(allocator),
            .metrics = ArrayList(SessionMetrics).init(allocator),
            .random = prng.random(),
            .start_time = null,
        };
    }
    
    pub fn deinit(self: *ABTest) void {
        var it = self.worlds.valueIterator();
        while (it.next()) |world| world.*.destroy();
        self.worlds.deinit();
        
        self.player_assignments.deinit();
        self.metrics.deinit();
    }
    
    /// Register a world variant
    pub fn addWorld(self: *ABTest, variant: WorldVariant, world: *World) !void {
        const key = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{
            variant.prefix(),
            world.uri.name,
        });
        try self.worlds.put(key, world);
    }
    
    /// Get world by variant
    pub fn getWorld(self: *ABTest, variant: WorldVariant, name: []const u8) ?*World {
        const key = std.fmt.allocPrint(self.allocator, "{s}{s}", .{
            variant.prefix(), name,
        }) catch return null;
        defer self.allocator.free(key);
        return self.worlds.get(key);
    }
    
    /// Assignment strategies
    pub const AssignmentStrategy = enum {
        RoundRobin,
        HashBased,
        Random,
        Manual,
    };
    
    /// Assign player to variant
    pub fn assignPlayer(
        self: *ABTest,
        player_id: []const u8,
        strategy: AssignmentStrategy,
        manual_variant: ?WorldVariant,
    ) !WorldVariant {
        // Check if already assigned
        if (self.player_assignments.get(player_id)) |existing| {
            return existing;
        }
        
        const variant = switch (strategy) {
            .RoundRobin => self.roundRobinAssign(),
            .HashBased => self.hashBasedAssign(player_id),
            .Random => self.randomAssign(),
            .Manual => manual_variant orelse self.randomAssign(),
        };
        
        try self.player_assignments.put(
            try self.allocator.dupe(u8, player_id),
            variant,
        );
        
        return variant;
    }
    
    fn roundRobinAssign(self: *ABTest) WorldVariant {
        const count = self.player_assignments.count();
        return switch (count % 3) {
            0 => .A,
            1 => .B,
            else => .C,
        };
    }
    
    fn hashBasedAssign(self: *ABTest, player_id: []const u8) WorldVariant {
        _ = self;
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(player_id);
        const hash = hasher.final();
        return switch (hash % 3) {
            0 => .A,
            1 => .B,
            else => .C,
        };
    }
    
    fn randomAssign(self: *ABTest) WorldVariant {
        return switch (self.random.int(u8) % 3) {
            0 => .A,
            1 => .B,
            else => .C,
        };
    }
    
    /// Start the test
    pub fn start(self: *ABTest) void {
        self.start_time = std.time.milliTimestamp();
    }
    
    /// Record session metrics
    pub fn recordMetrics(self: *ABTest, metrics: SessionMetrics) !void {
        try self.metrics.append(metrics);
    }
    
    /// Check if test should end
    pub fn shouldEnd(self: *ABTest) bool {
        if (self.start_time == null) return false;
        
        const elapsed = std.time.milliTimestamp() - self.start_time.?;
        if (elapsed >= self.config.duration_ms) return true;
        
        if (self.metrics.items.len >= self.config.min_samples) return true;
        
        return false;
    }
    
    /// Get metrics aggregated by variant
    pub fn getVariantMetrics(self: *ABTest) !StringHashMap(VariantMetrics) {
        var result = StringHashMap(VariantMetrics).init(self.allocator);
        errdefer result.deinit();
        
        // Initialize all variants
        for ([_]WorldVariant{ .A, .B, .C }) |v| {
            try result.put(v.prefix(), .{
                .variant = v,
                .sessions = 0,
                .total_duration_ms = 0,
                .avg_engagement = 0,
                .avg_success = 0,
                .total_errors = 0,
                .conversion_rate = 0,
            });
        }
        
        // Aggregate metrics
        for (self.metrics.items) |m| {
            const variant = WorldVariant.fromString(m.world_uri) orelse continue;
            const key = variant.prefix();
            
            if (result.getPtr(key)) |agg| {
                agg.sessions += 1;
                agg.total_duration_ms += m.duration();
                agg.total_errors += m.error_count;
                
                // Running average for engagement and success
                const n = @as(f64, @floatFromInt(agg.sessions));
                agg.avg_engagement = ((agg.avg_engagement * (n - 1)) + m.engagement_score) / n;
                agg.avg_success = ((agg.avg_success * (n - 1)) + m.success_score) / n;
            }
        }
        
        // Calculate conversion rates
        var it = result.valueIterator();
        while (it.next()) |agg| {
            if (agg.sessions > 0) {
                // Conversion = sessions with success > 80%
                var conversions: u32 = 0;
                for (self.metrics.items) |m| {
                    const variant = WorldVariant.fromString(m.world_uri) orelse continue;
                    if (variant == agg.variant and m.success_score > 80) {
                        conversions += 1;
                    }
                }
                agg.conversion_rate = @as(f64, @floatFromInt(conversions)) / 
                    @as(f64, @floatFromInt(agg.sessions));
            }
        }
        
        return result;
    }
    
    /// Calculate composite score for a variant
    fn compositeScore(self: *ABTest, metrics: VariantMetrics) f64 {
        const weights = self.config.metric_weights;
        return 
            metrics.avg_engagement * weights.engagement +
            metrics.avg_success * weights.success +
            @as(f64, @floatFromInt(metrics.total_duration_ms)) / 1000.0 * weights.duration;
    }
    
    /// Statistical test between two variants (Welch's t-test approximation)
    pub fn compareVariants(
        self: *ABTest,
        a: WorldVariant,
        b: WorldVariant,
    ) !TestResult {
        // Collect scores for each variant
        var scores_a = ArrayList(f64).init(self.allocator);
        defer scores_a.deinit();
        
        var scores_b = ArrayList(f64).init(self.allocator);
        defer scores_b.deinit();
        
        for (self.metrics.items) |m| {
            const variant = WorldVariant.fromString(m.world_uri) orelse continue;
            const score = m.engagement_score * 0.4 + m.success_score * 0.6;
            
            if (variant == a) {
                try scores_a.append(score);
            } else if (variant == b) {
                try scores_b.append(score);
            }
        }
        
        if (scores_a.items.len < 2 or scores_b.items.len < 2) {
            return TestResult{
                .variant_a = a,
                .variant_b = b,
                .winner = null,
                .confidence = 0,
                .improvement_pct = 0,
                .significant = false,
            };
        }
        
        // Calculate means
        const mean_a = mean(scores_a.items);
        const mean_b = mean(scores_b.items);
        
        // Calculate standard errors
        const se_a = stdError(scores_a.items);
        const se_b = stdError(scores_b.items);
        
        // t-statistic
        const se_diff = @sqrt(se_a * se_a + se_b * se_b);
        const t_stat = @abs(mean_a - mean_b) / se_diff;
        
        // Degrees of freedom (Welch-Satterthwaite)
        const n_a = @as(f64, @floatFromInt(scores_a.items.len));
        const n_b = @as(f64, @floatFromInt(scores_b.items.len));
        const df = @floor((se_a * se_a + se_b * se_b) * (se_a * se_a + se_b * se_b) /
            ((se_a * se_a * se_a * se_a) / (n_a - 1) + (se_b * se_b * se_b * se_b) / (n_b - 1)));
        _ = df;
        
        // Approximate p-value (simplified)
        // For 95% confidence, t > 1.96 for large df
        const critical_t = 1.96;
        const significant = t_stat > critical_t;
        
        const confidence = @min(1.0, t_stat / critical_t * 0.95);
        
        const winner = if (significant)
            (if (mean_a > mean_b) a else b)
        else
            null;
        
        const improvement = if (mean_b > 0)
            @abs(mean_a - mean_b) / mean_b * 100
        else
            0;
        
        return TestResult{
            .variant_a = a,
            .variant_b = b,
            .winner = winner,
            .confidence = confidence,
            .improvement_pct = improvement,
            .significant = significant,
        };
    }
    
    /// Determine overall winner across all variants
    pub fn determineWinner(self: *ABTest) !?WorldVariant {
        const comparisons = try self.compareVariants(.A, .B);
        if (!comparisons.significant) return null;
        
        const best = comparisons.winner.?;
        const vs_c = try self.compareVariants(best, .C);
        
        if (vs_c.significant and vs_c.winner == .C) {
            return .C;
        }
        return best;
    }
    
    /// Generate report
    pub fn generateReport(self: *ABTest, writer: anytype) !void {
        try writer.print("A/B Test Report: {s}\n", .{self.config.name});
        try writer.print("================================\n\n", .{});
        
        const variant_metrics = try self.getVariantMetrics();
        defer variant_metrics.deinit();
        
        try writer.print("Variant Performance:\n", .{});
        var it = variant_metrics.iterator();
        while (it.next()) |entry| {
            const m = entry.value_ptr.*;
            try writer.print("  {s}: sessions={d}, engagement={d:.1}%, success={d:.1}%, conversion={d:.1}%\n", .{
                entry.key_ptr.*,
                m.sessions,
                m.avg_engagement,
                m.avg_success,
                m.conversion_rate * 100,
            });
        }
        
        try writer.print("\nStatistical Comparisons:\n", .{});
        
        const pairs = [_]struct { WorldVariant, WorldVariant }{
            .{ .A, .B },
            .{ .A, .C },
            .{ .B, .C },
        };
        
        for (pairs) |pair| {
            const result = try self.compareVariants(pair[0], pair[1]);
            try writer.print("  {s} vs {s}: ", .{ pair[0].prefix(), pair[1].prefix() });
            if (result.significant) {
                try writer.print("Winner={s}, confidence={d:.1}%, improvement={d:.1}%\n", .{
                    result.winner.?.prefix(),
                    result.confidence * 100,
                    result.improvement_pct,
                });
            } else {
                try writer.print("No significant difference\n", .{});
            }
        }
        
        if (try self.determineWinner()) |winner| {
            try writer.print("\nOVERALL WINNER: {s}\n", .{winner.prefix()});
        } else {
            try writer.print("\nNo clear winner detected\n", .{});
        }
    }
};

fn mean(data: []const f64) f64 {
    if (data.len == 0) return 0;
    var sum: f64 = 0;
    for (data) |x| sum += x;
    return sum / @as(f64, @floatFromInt(data.len));
}

fn stdError(data: []const f64) f64 {
    if (data.len < 2) return 0;
    const m = mean(data);
    var sum_sq: f64 = 0;
    for (data) |x| {
        const diff = x - m;
        sum_sq += diff * diff;
    }
    const variance = sum_sq / @as(f64, @floatFromInt(data.len - 1));
    return @sqrt(variance / @as(f64, @floatFromInt(data.len)));
}

// ============================================================================
// Tests
// ============================================================================

test "ABTest player assignment" {
    const allocator = std.testing.allocator;
    
    var ab_test_instance = try ABTest.init(allocator, .{
        .name = "test",
        .duration_ms = 60000,
        .min_samples = 10,
        .confidence_threshold = 0.95,
        .metric_weights = .{ .engagement = 0.3, .success = 0.5, .duration = 0.2 },
    }, 12345);
    defer ab_test_instance.deinit();
    
    // Test round-robin
    const v1 = try ab_test_instance.assignPlayer("player1", .RoundRobin, null);
    const v2 = try ab_test_instance.assignPlayer("player2", .RoundRobin, null);
    const v3 = try ab_test_instance.assignPlayer("player3", .RoundRobin, null);
    const v4 = try ab_test_instance.assignPlayer("player4", .RoundRobin, null);
    
    try std.testing.expectEqual(WorldVariant.A, v1);
    try std.testing.expectEqual(WorldVariant.B, v2);
    try std.testing.expectEqual(WorldVariant.C, v3);
    try std.testing.expectEqual(WorldVariant.A, v4); // Wraps around
}

test "ABTest metrics aggregation" {
    const allocator = std.testing.allocator;
    
    var ab_test_instance = try ABTest.init(allocator, .{
        .name = "test",
        .duration_ms = 60000,
        .min_samples = 2,
        .confidence_threshold = 0.95,
        .metric_weights = .{ .engagement = 0.3, .success = 0.5, .duration = 0.2 },
    }, 12345);
    defer ab_test_instance.deinit();
    
    // Record some metrics
    try ab_test_instance.recordMetrics(.{
        .player_id = "p1",
        .world_uri = "a://baseline",
        .start_time = 0,
        .end_time = 10000,
        .events = 100,
        .actions = 50,
        .engagement_score = 75.0,
        .success_score = 80.0,
        .error_count = 2,
    });
    
    try ab_test_instance.recordMetrics(.{
        .player_id = "p2",
        .world_uri = "a://baseline",
        .start_time = 0,
        .end_time = 12000,
        .events = 120,
        .actions = 60,
        .engagement_score = 85.0,
        .success_score = 90.0,
        .error_count = 0,
    });
    
    const metrics = try ab_test_instance.getVariantMetrics();
    defer metrics.deinit();
    
    const a_metrics = metrics.get("a://").?;
    try std.testing.expectEqual(@as(u32, 2), a_metrics.sessions);
    try std.testing.expectEqual(@as(f64, 80.0), a_metrics.avg_engagement);
    try std.testing.expectEqual(@as(f64, 85.0), a_metrics.avg_success);
}
