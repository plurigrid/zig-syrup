/// WebSocket Backpressure & Write Queue Management
///
/// Provides non-blocking write queuing to prevent client starvation
/// when a slow receiver can't keep up with the server's output rate.
///
/// Design:
/// - Per-connection write queue (fixed-size ring buffer)
/// - Non-blocking frame append (returns error if queue full)
/// - Flush queue in server loop (async-like behavior without async/await)
/// - Track metrics: dropped frames, queue depth, send latency

const std = @import("std");

/// Frame with metadata for queue operations
pub const QueuedFrame = struct {
    msg_type: u8,                    // MessageType enum value
    payload: [4096]u8,               // Fixed-size payload buffer
    payload_len: usize,              // Actual payload length
    encoded_len: usize,              // Pre-calculated encoded length
    timestamp_ms: i64,               // When queued (for latency tracking)
    compression_flag: bool = false,  // Is payload compressed?
};

/// Ring buffer for non-blocking queue operations
pub const WriteQueue = struct {
    allocator: std.mem.Allocator,
    buffer: []QueuedFrame,           // Ring buffer storage
    write_idx: usize = 0,            // Next write position
    read_idx: usize = 0,             // Next read position
    len: usize = 0,
    
    pub fn init(allocator: std.mem.Allocator, cap: usize) !WriteQueue {
        const buffer = try allocator.alloc(QueuedFrame, cap);
        return WriteQueue{
            .allocator = allocator,
            .buffer = buffer,
        };
    }
    
    pub fn deinit(self: *WriteQueue) void {
        self.allocator.free(self.buffer);
    }
    
    /// Check if queue is empty
    pub fn isEmpty(self: WriteQueue) bool {
        return self.len == 0;
    }
    
    /// Check if queue is full
    pub fn isFull(self: WriteQueue) bool {
        return self.len >= self.buffer.len;
    }
    
    /// Current queue depth (number of frames pending)
    pub fn depth(self: WriteQueue) usize {
        return self.len;
    }
    
    /// Capacity of queue
    pub fn capacity(self: WriteQueue) usize {
        return self.buffer.len;
    }
    
    /// Append frame to queue (non-blocking, fails if full)
    pub fn append(self: *WriteQueue, frame: QueuedFrame) !void {
        if (self.isFull()) {
            return error.QueueFull;
        }
        
        self.buffer[self.write_idx] = frame;
        self.write_idx = (self.write_idx + 1) % self.buffer.len;
        self.len += 1;
    }
    
    /// Peek at next frame without removing
    pub fn peek(self: WriteQueue) ?QueuedFrame {
        if (self.isEmpty()) return null;
        return self.buffer[self.read_idx];
    }
    
    /// Pop next frame from queue
    pub fn pop(self: *WriteQueue) ?QueuedFrame {
        if (self.isEmpty()) return null;
        
        const frame = self.buffer[self.read_idx];
        self.read_idx = (self.read_idx + 1) % self.buffer.len;
        self.len -= 1;
        return frame;
    }
    
    /// Clear all frames from queue
    pub fn clear(self: *WriteQueue) void {
        self.len = 0;
        self.read_idx = 0;
        self.write_idx = 0;
    }
};

/// Per-connection backpressure metrics
pub const BackpressureMetrics = struct {
    frames_queued_total: u64 = 0,     // Total frames ever queued
    frames_sent_total: u64 = 0,       // Total frames successfully sent
    frames_dropped: u64 = 0,          // Frames dropped due to queue overflow
    
    bytes_queued: u64 = 0,            // Total bytes queued
    bytes_sent: u64 = 0,              // Total bytes sent
    bytes_dropped: u64 = 0,           // Total bytes lost to drops
    
    queue_depth_max: usize = 0,       // Peak queue depth
    queue_depth_avg: f32 = 0,         // Running average
    
    send_latency_ms_max: f32 = 0,     // Max time in queue before send
    send_latency_ms_avg: f32 = 0,     // Average time in queue
    
    last_queue_full_at: i64 = 0,      // Timestamp of last overflow
    queue_full_count: u64 = 0,        // How many times queue overflowed
    
    /// Record a successful send
    pub fn recordSend(
        self: *BackpressureMetrics,
        frame_len: usize,
        latency_ms: f32
    ) void {
        self.frames_sent_total += 1;
        self.bytes_sent += frame_len;
        
        const n = @as(f32, @floatFromInt(self.frames_sent_total));
        self.send_latency_ms_avg = (self.send_latency_ms_avg * (n - 1) + latency_ms) / n;
        self.send_latency_ms_max = @max(self.send_latency_ms_max, latency_ms);
    }
    
    /// Record a dropped frame
    pub fn recordDrop(self: *BackpressureMetrics, frame_len: usize, now: i64) void {
        self.frames_dropped += 1;
        self.bytes_dropped += frame_len;
        self.queue_full_count += 1;
        self.last_queue_full_at = now;
    }
    
    /// Update queue depth statistics
    pub fn recordQueueDepth(self: *BackpressureMetrics, depth: usize) void {
        self.queue_depth_max = @max(self.queue_depth_max, depth);
        
        const n = @as(f32, @floatFromInt(self.frames_queued_total + 1));
        self.queue_depth_avg = (self.queue_depth_avg * (n - 1) + @as(f32, @floatFromInt(depth))) / n;
    }
};

/// WebSocket connection with backpressure support
pub const BackpressuredConnection = struct {
    allocator: std.mem.Allocator,
    stream: std.net.Stream,
    write_queue: WriteQueue,
    metrics: BackpressureMetrics = .{},
    
    pub fn init(
        allocator: std.mem.Allocator,
        stream: std.net.Stream,
        queue_capacity: usize,
    ) !BackpressuredConnection {
        return BackpressuredConnection{
            .allocator = allocator,
            .stream = stream,
            .write_queue = try WriteQueue.init(allocator, queue_capacity),
        };
    }
    
    pub fn deinit(self: *BackpressuredConnection) void {
        self.write_queue.deinit();
        self.stream.close();
    }
    
    /// Queue a frame for non-blocking send
    pub fn queueFrame(
        self: *BackpressuredConnection,
        msg_type: u8,
        payload: []const u8,
        now: i64,
    ) !void {
        if (payload.len > 4096) {
            return error.PayloadTooLarge;
        }
        
        var frame: QueuedFrame = undefined;
        frame.msg_type = msg_type;
        frame.payload_len = payload.len;
        @memcpy(frame.payload[0..payload.len], payload);
        frame.timestamp_ms = now;
        frame.compression_flag = false;
        
        // Estimate encoded length (4-byte header + payload)
        frame.encoded_len = 5 + payload.len;
        
        self.write_queue.append(frame) catch |err| {
            // Queue full - record drop and fail
            self.metrics.recordDrop(frame.encoded_len, now);
            return err;
        };
        
        self.metrics.frames_queued_total += 1;
        self.metrics.bytes_queued += payload.len;
        self.metrics.recordQueueDepth(self.write_queue.depth());
    }
    
    /// Flush pending frames to stream (non-blocking, returns when blocked)
    pub fn flushWriteQueue(self: *BackpressuredConnection, now: i64) !usize {
        var frames_sent: usize = 0;
        var buf: [4096 + 5]u8 = undefined;
        
        while (!self.write_queue.isEmpty()) {
            const frame = self.write_queue.peek() orelse break;
            
            // Encode frame: [u32 len][u8 type][payload]
            const len_bytes: [4]u8 = @bitCast(@as(u32, @intCast(frame.payload_len + 1)));
            @memcpy(buf[0..4], &len_bytes);
            buf[4] = frame.msg_type;
            @memcpy(buf[5..][0..frame.payload_len], frame.payload[0..frame.payload_len]);
            
            const total_len = 5 + frame.payload_len;
            
            // Try to write (non-blocking on would-block)
            self.stream.writeAll(buf[0..total_len]) catch |err| {
                if (err == error.WouldBlock) {
                    break;  // Client can't accept more, stop trying
                }
                // Connection error - pop and drop frame, continue
                _ = self.write_queue.pop();
                self.metrics.recordDrop(total_len, now);
                continue;
            };
            
            // Successfully sent - remove from queue and record metrics
            _ = self.write_queue.pop();
            frames_sent += 1;
            
            const latency_ms: f32 = @floatFromInt(now - frame.timestamp_ms);
            self.metrics.recordSend(total_len, latency_ms);
        }
        
        return frames_sent;
    }
    
    /// Get current backpressure status
    pub fn getStatus(self: BackpressuredConnection) BackpressureStatus {
        return BackpressureStatus{
            .queue_depth = self.write_queue.depth(),
            .queue_capacity = self.write_queue.capacity(),
            .utilization = @as(f32, @floatFromInt(self.write_queue.depth())) / 
                          @as(f32, @floatFromInt(self.write_queue.capacity())),
            .frames_dropped = self.metrics.frames_dropped,
            .send_latency_ms_avg = self.metrics.send_latency_ms_avg,
        };
    }
};

pub const BackpressureStatus = struct {
    queue_depth: usize,
    queue_capacity: usize,
    utilization: f32,              // 0.0-1.0
    frames_dropped: u64,
    send_latency_ms_avg: f32,
};

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "WriteQueueBasic" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    var queue = try WriteQueue.init(allocator, 10);
    defer queue.deinit();
    
    try testing.expectEqual(queue.depth(), 0);
    try testing.expectEqual(queue.isEmpty(), true);
    try testing.expectEqual(queue.isFull(), false);
    
    var frame: QueuedFrame = undefined;
    frame.msg_type = 0x01;
    frame.payload_len = 5;
    @memcpy(frame.payload[0..5], "hello");
    frame.timestamp_ms = 1000;
    
    try queue.append(frame);
    try testing.expectEqual(queue.depth(), 1);
    try testing.expectEqual(queue.isEmpty(), false);
    
    const peeked = queue.peek();
    try testing.expect(peeked != null);
    try testing.expectEqual(peeked.?.msg_type, 0x01);
    
    const popped = queue.pop();
    try testing.expect(popped != null);
    try testing.expectEqual(queue.depth(), 0);
}

test "WriteQueueOverflow" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    var queue = try WriteQueue.init(allocator, 3);
    defer queue.deinit();
    
    var frame: QueuedFrame = undefined;
    frame.msg_type = 0x01;
    frame.payload_len = 1;
    frame.timestamp_ms = 0;
    
    // Fill queue
    try queue.append(frame);
    try queue.append(frame);
    try queue.append(frame);
    
    try testing.expectEqual(queue.isFull(), true);
    
    // Next append should fail
    try testing.expectError(error.QueueFull, queue.append(frame));
}

test "BackpressureMetrics" {
    var metrics = BackpressureMetrics{};
    
    metrics.recordSend(100, 5.0);
    try testing.expectEqual(metrics.frames_sent_total, 1);
    try testing.expectEqual(metrics.bytes_sent, 100);
    try testing.expectEqual(metrics.send_latency_ms_avg, 5.0);
    
    metrics.recordSend(200, 10.0);
    try testing.expectEqual(metrics.frames_sent_total, 2);
    try testing.expectEqual(metrics.bytes_sent, 300);
    // Average: (5 + 10) / 2 = 7.5
    try testing.expect(metrics.send_latency_ms_avg > 7.0 and metrics.send_latency_ms_avg < 8.0);
    
    metrics.recordDrop(50, 1000);
    try testing.expectEqual(metrics.frames_dropped, 1);
    try testing.expectEqual(metrics.bytes_dropped, 50);
}
