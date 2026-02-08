/// WebSocket Performance Metrics & Monitoring
///
/// Tracks latency, throughput, compression, and backpressure metrics
/// for performance monitoring and diagnostics.
///
/// Exports via HTTP /metrics endpoint (JSON format).

const std = @import("std");

/// Per-connection performance metrics
pub const ConnectionMetrics = struct {
    // Timing
    connected_at_ms: i64,
    last_frame_at_ms: i64,
    last_ping_at_ms: i64,
    last_pong_at_ms: i64,
    
    // Throughput
    frames_sent: u64 = 0,
    frames_received: u64 = 0,
    bytes_sent: u64 = 0,
    bytes_received: u64 = 0,
    
    // Latency (ms)
    rtt_ms: f32 = 0,              // Round-trip time (PING/PONG)
    rtt_ms_max: f32 = 0,
    rtt_ms_avg: f32 = 0,
    
    // Compression
    bytes_compressed: u64 = 0,
    compression_ratio_avg: f32 = 1.0,
    
    // Backpressure
    frames_dropped: u64 = 0,
    queue_depth_max: usize = 0,
    queue_full_events: u64 = 0,
    
    pub fn init(now_ms: i64) ConnectionMetrics {
        return ConnectionMetrics{
            .connected_at_ms = now_ms,
            .last_frame_at_ms = now_ms,
            .last_ping_at_ms = now_ms,
            .last_pong_at_ms = now_ms,
        };
    }
    
    pub fn uptime_ms(self: ConnectionMetrics, now_ms: i64) i64 {
        return now_ms - self.connected_at_ms;
    }
    
    pub fn idle_ms(self: ConnectionMetrics, now_ms: i64) i64 {
        return now_ms - self.last_frame_at_ms;
    }
    
    pub fn throughput_bytes_per_second(self: ConnectionMetrics, now_ms: i64) f32 {
        const uptime = self.uptime_ms(now_ms);
        if (uptime == 0) return 0;
        return @as(f32, @floatFromInt(self.bytes_sent)) * 1000.0 / @as(f32, @floatFromInt(uptime));
    }
};

/// Server-wide metrics aggregator
pub const ServerMetrics = struct {
    allocator: std.mem.Allocator,
    
    // Global counters
    total_connections: u64 = 0,
    active_connections: u64 = 0,
    frames_sent_total: u64 = 0,
    bytes_sent_total: u64 = 0,
    
    // Performance percentiles
    rtt_p50_ms: f32 = 0,
    rtt_p95_ms: f32 = 0,
    rtt_p99_ms: f32 = 0,
    
    compression_ratio_avg: f32 = 1.0,
    
    frames_dropped_total: u64 = 0,
    queue_full_events_total: u64 = 0,
    
    started_at_ms: i64,
    last_updated_at_ms: i64,
    
    pub fn init(allocator: std.mem.Allocator, now_ms: i64) ServerMetrics {
        return ServerMetrics{
            .allocator = allocator,
            .started_at_ms = now_ms,
            .last_updated_at_ms = now_ms,
        };
    }
    
    pub fn uptime_ms(self: ServerMetrics, now_ms: i64) i64 {
        return now_ms - self.started_at_ms;
    }
    
    pub fn throughput_bytes_per_second(self: ServerMetrics, now_ms: i64) f32 {
        const uptime = self.uptime_ms(now_ms);
        if (uptime == 0) return 0;
        return @as(f32, @floatFromInt(self.bytes_sent_total)) * 1000.0 / @as(f32, @floatFromInt(uptime));
    }
    
    /// Export metrics as JSON string
    pub fn toJson(self: ServerMetrics, allocator: std.mem.Allocator, now_ms: i64) ![]u8 {
        var buffer: [2048]u8 = undefined;
        var stream = std.io.fixedBufferStream(&buffer);
        const writer = stream.writer();
        
        try writer.print(
            \\{{
            \\  "uptime_ms": {},
            \\  "active_connections": {},
            \\  "total_connections": {},
            \\  "frames_sent": {},
            \\  "bytes_sent": {},
            \\  "throughput_bps": {d:.2},
            \\  "compression_ratio": {d:.3},
            \\  "frames_dropped": {},
            \\  "queue_full_events": {},
            \\  "rtt_p50_ms": {d:.2},
            \\  "rtt_p95_ms": {d:.2},
            \\  "rtt_p99_ms": {d:.2}
            \\}}
        ,
            .{
                self.uptime_ms(now_ms),
                self.active_connections,
                self.total_connections,
                self.frames_sent_total,
                self.bytes_sent_total,
                self.throughput_bytes_per_second(now_ms),
                self.compression_ratio_avg,
                self.frames_dropped_total,
                self.queue_full_events_total,
                self.rtt_p50_ms,
                self.rtt_p95_ms,
                self.rtt_p99_ms,
            },
        );
        
        const result = buffer[0..stream.pos];
        const owned = try allocator.dupe(u8, result);
        return owned;
    }
};

/// Histogram for tracking latency distributions
pub const LatencyHistogram = struct {
    allocator: std.mem.Allocator,
    buckets: [20]u64 = [_]u64{0} ** 20,  // 0-1ms, 1-2ms, ..., 19-20ms
    overflow: u64 = 0,
    
    pub fn init(allocator: std.mem.Allocator) LatencyHistogram {
        return LatencyHistogram{ .allocator = allocator };
    }
    
    pub fn record(self: *LatencyHistogram, latency_ms: f32) void {
        const bucket_idx = @min(19, @as(usize, @intFromFloat(latency_ms)));
        self.buckets[bucket_idx] += 1;
        
        if (latency_ms >= 20.0) {
            self.overflow += 1;
        }
    }
    
    pub fn percentile(self: LatencyHistogram, p: f32) f32 {
        var total: u64 = 0;
        for (self.buckets) |count| {
            total += count;
        }
        total += self.overflow;
        
        if (total == 0) return 0;
        
        const target = @as(f32, @floatFromInt(total)) * (p / 100.0);
        var sum: f32 = 0;
        
        for (0..self.buckets.len) |i| {
            sum += @floatFromInt(self.buckets[i]);
            if (sum >= target) {
                return @as(f32, @floatFromInt(i));
            }
        }
        
        return 20.0 + @as(f32, @floatFromInt(self.overflow));
    }
};

/// Event log for debugging
pub const EventLog = struct {
    allocator: std.mem.Allocator,
    events: std.ArrayListUnmanaged(Event) = .{},
    max_events: usize = 1000,  // Ring buffer size
    
    pub const Event = struct {
        timestamp_ms: i64,
        event_type: EventType,
        message: []const u8,
        
        pub fn deinit(self: Event, allocator: std.mem.Allocator) void {
            allocator.free(self.message);
        }
    };
    
    pub const EventType = enum {
        connection_opened,
        connection_closed,
        frame_sent,
        frame_dropped,
        queue_full,
        compression_applied,
        backpressure_detected,
        error_event,
    };
    
    pub fn init(allocator: std.mem.Allocator) EventLog {
        return EventLog{ .allocator = allocator };
    }
    
    pub fn deinit(self: *EventLog) void {
        for (self.events.items) |event| {
            event.deinit(self.allocator);
        }
        self.events.deinit(self.allocator);
    }
    
    pub fn log(
        self: *EventLog,
        timestamp_ms: i64,
        event_type: EventType,
        message: []const u8,
    ) !void {
        // Keep ring buffer at max_events
        if (self.events.items.len >= self.max_events) {
            self.events.items[0].deinit(self.allocator);
            _ = self.events.orderedRemove(0);
        }
        
        const msg_copy = try self.allocator.dupe(u8, message);
        try self.events.append(self.allocator, .{
            .timestamp_ms = timestamp_ms,
            .event_type = event_type,
            .message = msg_copy,
        });
    }
    
    pub fn getRecent(self: EventLog, count: usize) []Event {
        const start = if (self.events.items.len > count)
            self.events.items.len - count
        else
            0;
        return self.events.items[start..];
    }
};

/// Health check status
pub const HealthStatus = enum {
    healthy,
    degraded,
    critical,
    
    pub fn fromMetrics(metrics: ServerMetrics) HealthStatus {
        if (metrics.frames_dropped_total > 100 or metrics.queue_full_events_total > 50) {
            return .critical;
        } else if (metrics.frames_dropped_total > 10 or metrics.queue_full_events_total > 5) {
            return .degraded;
        }
        return .healthy;
    }
};

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "testConnectionMetrics" {
    var metrics = ConnectionMetrics.init(1000);
    
    metrics.frames_sent = 100;
    metrics.bytes_sent = 10000;
    
    try testing.expectEqual(metrics.frames_sent, 100);
    try testing.expectEqual(metrics.uptime_ms(2000), 1000);
    try testing.expectEqual(metrics.idle_ms(3000), 2000);
    
    const throughput = metrics.throughput_bytes_per_second(11000);
    try testing.expect(throughput > 900 and throughput < 1100);  // ~1000 bps
}

test "testServerMetrics" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    var metrics = ServerMetrics.init(allocator, 1000);
    
    metrics.active_connections = 5;
    metrics.frames_sent_total = 1000;
    metrics.bytes_sent_total = 100000;
    
    const json = try metrics.toJson(allocator, 2000);
    defer allocator.free(json);
    
    try testing.expect(std.mem.containsAtLeast(u8, json, 1, "active_connections"));
    try testing.expect(std.mem.containsAtLeast(u8, json, 1, "100000"));
}

test "testLatencyHistogram" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    var hist = LatencyHistogram.init(allocator);
    
    // Record some latencies
    hist.record(1.5);
    hist.record(2.1);
    hist.record(2.5);
    hist.record(3.0);
    hist.record(5.0);
    
    const p50 = hist.percentile(50.0);
    const p95 = hist.percentile(95.0);
    
    try testing.expect(p50 > 0 and p50 < 10);
    try testing.expect(p95 > 0 and p95 < 10);
}

test "testEventLog" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    var log = EventLog.init(allocator);
    defer log.deinit();
    
    try log.log(1000, .connection_opened, "Client connected");
    try log.log(2000, .frame_sent, "Sent 1000 bytes");
    
    try testing.expectEqual(log.events.items.len, 2);
    try testing.expectEqual(log.events.items[0].event_type, .connection_opened);
}
