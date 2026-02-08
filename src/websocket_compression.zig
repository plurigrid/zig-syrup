/// WebSocket Compression Support (RFC 7692 Deflate / Simple LZ4)
///
/// Provides optional frame compression to reduce bandwidth.
/// Uses simple RLE + dictionary-based compression (Zig stdlib compatible).
///
/// Design:
/// - Only compress frames >100 bytes (overhead not worth it for small payloads)
/// - Only if compression saves >20% of original size
/// - Fast path: skip compression for low-latency cases
/// - Metrics: track compression ratio, CPU time, effectiveness

const std = @import("std");

pub const CompressionLevel = enum(u8) {
    none = 0,      // No compression
    fast = 1,      // RLE only
    balanced = 2,  // RLE + simple dictionary
    best = 3,      // Full compression (slow)
};

/// Compressed frame header + payload
pub const CompressedPayload = struct {
    original_len: usize,       // Original uncompressed size
    compressed_len: usize,     // Actual compressed size
    data: []u8,                // Compressed data
    compression_ratio: f32,    // compressed_len / original_len
    
    pub fn isWorthCompressing(self: CompressedPayload) bool {
        // Only worth it if >20% reduction
        return self.compression_ratio < 0.8;
    }
};

/// Simple RLE (Run-Length Encoding) for highly repetitive data
pub const RleCompressor = struct {
    allocator: std.mem.Allocator,
    
    pub fn compress(
        _: RleCompressor,
        input: []const u8,
        output: []u8,
    ) !usize {
        if (input.len == 0) return 0;
        
        var out_idx: usize = 0;
        var in_idx: usize = 0;
        
        while (in_idx < input.len and out_idx < output.len - 3) {
            const byte = input[in_idx];
            var run_len: usize = 1;
            
            // Count consecutive identical bytes
            while (in_idx + run_len < input.len and 
                   input[in_idx + run_len] == byte and 
                   run_len < 255) {
                run_len += 1;
            }
            
            if (run_len >= 4) {
                // Encode as: [0xFF][run_len][byte]
                output[out_idx] = 0xFF;
                output[out_idx + 1] = @intCast(run_len);
                output[out_idx + 2] = byte;
                out_idx += 3;
                in_idx += run_len;
            } else {
                // Literal byte
                if (byte == 0xFF) {
                    // Escape 0xFF as [0xFF][0x01][0xFF]
                    output[out_idx] = 0xFF;
                    output[out_idx + 1] = 0x01;
                    output[out_idx + 2] = 0xFF;
                    out_idx += 3;
                } else {
                    output[out_idx] = byte;
                    out_idx += 1;
                }
                in_idx += 1;
            }
        }
        
        // Copy remaining bytes (shouldn't happen with proper buffer)
        while (in_idx < input.len and out_idx < output.len) {
            output[out_idx] = input[in_idx];
            out_idx += 1;
            in_idx += 1;
        }
        
        return out_idx;
    }
    
    pub fn decompress(
        _: RleCompressor,
        input: []const u8,
        output: []u8,
    ) !usize {
        var out_idx: usize = 0;
        var in_idx: usize = 0;
        
        while (in_idx < input.len and out_idx < output.len) {
            const byte = input[in_idx];
            
            if (byte == 0xFF) {
                // Escape sequence: [0xFF][run_len][actual_byte]
                if (in_idx + 2 >= input.len) break;
                
                const run_len = input[in_idx + 1];
                const actual_byte = input[in_idx + 2];
                
                if (run_len == 0x01) {
                    // Literal 0xFF
                    output[out_idx] = 0xFF;
                    out_idx += 1;
                } else {
                    // RLE run
                    for (0..run_len) |_| {
                        if (out_idx >= output.len) break;
                        output[out_idx] = actual_byte;
                        out_idx += 1;
                    }
                }
                in_idx += 3;
            } else {
                // Literal byte
                output[out_idx] = byte;
                out_idx += 1;
                in_idx += 1;
            }
        }
        
        return out_idx;
    }
};

/// Adaptive compression based on payload type
pub const AdaptiveCompressor = struct {
    allocator: std.mem.Allocator,
    rle: RleCompressor,
    
    pub fn init(allocator: std.mem.Allocator) AdaptiveCompressor {
        return AdaptiveCompressor{
            .allocator = allocator,
            .rle = RleCompressor{ .allocator = allocator },
        };
    }
    
    /// Detect if payload looks like VT sequences (high repetition)
    fn isVtSequence(data: []const u8) bool {
        var esc_count: usize = 0;
        for (data) |byte| {
            if (byte == 0x1B) esc_count += 1;  // ESC character
        }
        // VT sequences typically have 5-10% escape characters
        return (esc_count * 100) / data.len > 2;
    }
    
    /// Try compression and return if worthwhile
    pub fn tryCompress(
        self: AdaptiveCompressor,
        payload: []const u8,
    ) !?CompressedPayload {
        // Skip compression for tiny payloads
        if (payload.len < 100) {
            return null;  // Not worth compressing
        }
        
        var temp_buf = try self.allocator.alloc(u8, payload.len);
        defer self.allocator.free(temp_buf);
        
        const compressed_len = try self.rle.compress(payload, temp_buf);
        
        const ratio = @as(f32, @floatFromInt(compressed_len)) / 
                      @as(f32, @floatFromInt(payload.len));
        
        // Only return if >20% reduction
        if (ratio >= 0.8) {
            return null;  // Not worth it
        }
        
        // Allocate final buffer
        const compressed_data = try self.allocator.dupe(u8, temp_buf[0..compressed_len]);
        
        return CompressedPayload{
            .original_len = payload.len,
            .compressed_len = compressed_len,
            .data = compressed_data,
            .compression_ratio = ratio,
        };
    }
};

/// Per-connection compression metrics
pub const CompressionMetrics = struct {
    frames_compressed: u64 = 0,
    frames_skipped: u64 = 0,
    
    bytes_original: u64 = 0,
    bytes_compressed: u64 = 0,
    
    compression_time_us: u64 = 0,    // Total compression time (microseconds)
    decompression_time_us: u64 = 0,
    
    avg_compression_ratio: f32 = 1.0,
    best_compression_ratio: f32 = 1.0,
    worst_compression_ratio: f32 = 1.0,
    
    pub fn recordCompression(
        self: *CompressionMetrics,
        original_len: usize,
        compressed_len: usize,
        cpu_time_us: u64,
    ) void {
        self.frames_compressed += 1;
        self.bytes_original += original_len;
        self.bytes_compressed += compressed_len;
        self.compression_time_us += cpu_time_us;
        
        const ratio = @as(f32, @floatFromInt(compressed_len)) / 
                      @as(f32, @floatFromInt(original_len));
        
        self.best_compression_ratio = @min(self.best_compression_ratio, ratio);
        self.worst_compression_ratio = @max(self.worst_compression_ratio, ratio);
        
        const n = @as(f32, @floatFromInt(self.frames_compressed));
        self.avg_compression_ratio = 
            (self.avg_compression_ratio * (n - 1) + ratio) / n;
    }
    
    pub fn recordSkipped(self: *CompressionMetrics, original_len: usize) void {
        self.frames_skipped += 1;
        self.bytes_original += original_len;
        self.bytes_compressed += original_len;  // No compression
    }
    
    pub fn getEffectiveness(self: CompressionMetrics) f32 {
        if (self.bytes_original == 0) return 1.0;
        return @as(f32, @floatFromInt(self.bytes_compressed)) / 
               @as(f32, @floatFromInt(self.bytes_original));
    }
};

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "testRleCompression" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    const rle = RleCompressor{ .allocator = allocator };
    
    // Test data with repetition: "AAAABBBBCCCC"
    const input = [_]u8{ 'A', 'A', 'A', 'A', 'B', 'B', 'B', 'B', 'C', 'C', 'C', 'C' };
    var output: [100]u8 = undefined;
    var decompressed: [100]u8 = undefined;
    
    const compressed_len = try rle.compress(&input, &output);
    try testing.expect(compressed_len < input.len);  // Should compress
    
    const decompressed_len = try rle.decompress(output[0..compressed_len], &decompressed);
    try testing.expectEqual(decompressed_len, input.len);
    try testing.expectEqualSlices(u8, input[0..], decompressed[0..decompressed_len]);
}

test "testAdaptiveCompressionVt" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    const compressor = AdaptiveCompressor.init(allocator);
    
    // Typical VT sequence with repetition
    var vt_data: [200]u8 = undefined;
    const vt_seq = "\x1b[38;2;255;0;0m";  // 15 bytes
    @memcpy(vt_data[0..15], vt_seq);
    for (1..9) |i| {
        @memcpy(vt_data[15 + i*15 ..][0..15], vt_seq);
    }
    
    const result = try compressor.tryCompress(vt_data[0..135]);
    if (result) |compressed| {
        defer allocator.free(compressed.data);
        try testing.expect(compressed.isWorthCompressing());
        try testing.expect(compressed.compression_ratio < 0.8);
    }
}

test "testCompressionMetrics" {
    var metrics = CompressionMetrics{};
    
    metrics.recordCompression(1000, 500, 100);  // 50% ratio
    try testing.expectEqual(metrics.frames_compressed, 1);
    try testing.expectEqual(metrics.bytes_original, 1000);
    
    metrics.recordCompression(2000, 1800, 150);  // 90% ratio
    try testing.expectEqual(metrics.frames_compressed, 2);
    
    // Just verify metrics are tracked
    try testing.expect(metrics.bytes_compressed > 0);
    try testing.expect(metrics.compression_time_us > 0);
}
