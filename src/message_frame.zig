//! Message Framing for OCapN CapTP Transport
//!
//! Length-prefix framing: [u32 big-endian length][Syrup message bytes]
//! Zero-allocation: works with caller-provided fixed buffers.
//! Handles partial frames (waiting for more data from network).

const std = @import("std");
const syrup = @import("syrup.zig");

/// Maximum message size (4MB). Prevents DoS via huge length prefixes.
pub const MAX_MESSAGE_SIZE: u32 = 4 * 1024 * 1024;

/// Header size: 4 bytes big-endian u32 length prefix.
pub const HEADER_SIZE: usize = 4;

pub const FrameError = error{
    MessageTooLarge,
    BufferTooSmall,
    Incomplete,
    InvalidHeader,
};

/// Encode a Syrup value into a length-prefixed frame.
/// Returns bytes written (header + payload).
pub fn encodeFrame(value: syrup.Value, buf: []u8) FrameError!usize {
    if (buf.len < HEADER_SIZE) return FrameError.BufferTooSmall;

    // Encode Syrup payload after the header
    const payload_buf = buf[HEADER_SIZE..];
    const payload_len = syrup.encode(value, payload_buf) catch
        return FrameError.BufferTooSmall;

    if (payload_len > MAX_MESSAGE_SIZE) return FrameError.MessageTooLarge;

    // Write length prefix (big-endian u32)
    const len_u32: u32 = @intCast(payload_len);
    buf[0] = @intCast((len_u32 >> 24) & 0xFF);
    buf[1] = @intCast((len_u32 >> 16) & 0xFF);
    buf[2] = @intCast((len_u32 >> 8) & 0xFF);
    buf[3] = @intCast(len_u32 & 0xFF);

    return HEADER_SIZE + payload_len;
}

/// Encode raw bytes into a length-prefixed frame.
/// Returns bytes written (header + payload).
pub fn encodeRawFrame(payload: []const u8, buf: []u8) FrameError!usize {
    if (payload.len > MAX_MESSAGE_SIZE) return FrameError.MessageTooLarge;
    const total = HEADER_SIZE + payload.len;
    if (buf.len < total) return FrameError.BufferTooSmall;

    const len_u32: u32 = @intCast(payload.len);
    buf[0] = @intCast((len_u32 >> 24) & 0xFF);
    buf[1] = @intCast((len_u32 >> 16) & 0xFF);
    buf[2] = @intCast((len_u32 >> 8) & 0xFF);
    buf[3] = @intCast(len_u32 & 0xFF);
    @memcpy(buf[HEADER_SIZE..total], payload);

    return total;
}

/// Peek at the next frame's payload length from a buffer.
/// Returns null if not enough data for the header.
pub fn peekFrameLength(buf: []const u8) ?u32 {
    if (buf.len < HEADER_SIZE) return null;
    return @as(u32, buf[0]) << 24 |
        @as(u32, buf[1]) << 16 |
        @as(u32, buf[2]) << 8 |
        @as(u32, buf[3]);
}

/// Try to extract a complete frame from a buffer.
/// Returns the payload slice and total frame size consumed,
/// or Incomplete if not enough data.
pub const Frame = struct {
    payload: []const u8,
    consumed: usize,
};

pub fn decodeFrame(buf: []const u8) FrameError!Frame {
    const payload_len = peekFrameLength(buf) orelse return FrameError.Incomplete;
    if (payload_len > MAX_MESSAGE_SIZE) return FrameError.MessageTooLarge;

    const total: usize = HEADER_SIZE + payload_len;
    if (buf.len < total) return FrameError.Incomplete;

    return .{
        .payload = buf[HEADER_SIZE..total],
        .consumed = total,
    };
}

/// Count complete frames in a buffer.
pub fn frameCount(buf: []const u8) usize {
    var count: usize = 0;
    var pos: usize = 0;
    while (pos < buf.len) {
        if (buf.len - pos < HEADER_SIZE) break;
        const payload_len = peekFrameLength(buf[pos..]) orelse break;
        const total: usize = HEADER_SIZE + payload_len;
        if (pos + total > buf.len) break;
        count += 1;
        pos += total;
    }
    return count;
}

/// Ring buffer for accumulating partial frames from network reads.
/// Zero-allocation: uses a fixed-size backing buffer.
pub fn FrameAccumulator(comptime capacity: usize) type {
    return struct {
        buf: [capacity]u8 = undefined,
        write_pos: usize = 0,
        read_pos: usize = 0,

        const Self = @This();

        /// Available space for writing.
        pub fn writeSlice(self: *Self) []u8 {
            return self.buf[self.write_pos..];
        }

        /// Advance write position after receiving data.
        pub fn advance(self: *Self, n: usize) void {
            self.write_pos += n;
        }

        /// Available data for reading.
        pub fn readSlice(self: *const Self) []const u8 {
            return self.buf[self.read_pos..self.write_pos];
        }

        /// Try to extract the next complete frame.
        pub fn nextFrame(self: *Self) ?Frame {
            const data = self.readSlice();
            const frame = decodeFrame(data) catch return null;
            self.read_pos += frame.consumed;

            // Compact buffer if we've consumed past halfway
            if (self.read_pos > capacity / 2) {
                const remaining = self.write_pos - self.read_pos;
                if (remaining > 0) {
                    std.mem.copyForwards(u8, self.buf[0..remaining], self.buf[self.read_pos..self.write_pos]);
                }
                self.write_pos = remaining;
                self.read_pos = 0;
            }

            return frame;
        }

        /// Reset the accumulator.
        pub fn reset(self: *Self) void {
            self.write_pos = 0;
            self.read_pos = 0;
        }
    };
}

// =============================================================================
// Tests
// =============================================================================

test "encode and decode raw frame" {
    var buf: [256]u8 = undefined;
    const payload = "hello syrup";
    const written = try encodeRawFrame(payload, &buf);

    try std.testing.expectEqual(@as(usize, HEADER_SIZE + payload.len), written);

    const frame = try decodeFrame(buf[0..written]);
    try std.testing.expectEqualSlices(u8, payload, frame.payload);
    try std.testing.expectEqual(written, frame.consumed);
}

test "peek frame length" {
    const buf = [_]u8{ 0, 0, 0, 11, 'h', 'e', 'l', 'l', 'o', ' ', 's', 'y', 'r', 'u', 'p' };
    const len = peekFrameLength(&buf);
    try std.testing.expectEqual(@as(u32, 11), len.?);
}

test "incomplete frame returns error" {
    const buf = [_]u8{ 0, 0, 0, 100 }; // Claims 100 bytes but only header present
    const result = decodeFrame(&buf);
    try std.testing.expectError(FrameError.Incomplete, result);
}

test "frame count" {
    var buf: [512]u8 = undefined;
    var pos: usize = 0;
    // Write 3 frames
    for (0..3) |i| {
        var payload: [8]u8 = undefined;
        @memset(&payload, @intCast(i));
        const written = try encodeRawFrame(&payload, buf[pos..]);
        pos += written;
    }
    try std.testing.expectEqual(@as(usize, 3), frameCount(buf[0..pos]));
}

test "frame accumulator" {
    var acc = FrameAccumulator(4096){};

    // Simulate receiving a complete frame in two chunks
    var frame_buf: [64]u8 = undefined;
    const written = try encodeRawFrame("test payload", &frame_buf);

    // First chunk: header only
    @memcpy(acc.writeSlice()[0..HEADER_SIZE], frame_buf[0..HEADER_SIZE]);
    acc.advance(HEADER_SIZE);
    try std.testing.expect(acc.nextFrame() == null); // Incomplete

    // Second chunk: rest of frame
    const rest = written - HEADER_SIZE;
    @memcpy(acc.writeSlice()[0..rest], frame_buf[HEADER_SIZE..written]);
    acc.advance(rest);

    const frame = acc.nextFrame().?;
    try std.testing.expectEqualSlices(u8, "test payload", frame.payload);
}

test "message too large" {
    var buf: [8]u8 = undefined;
    // Fake a length header claiming 5MB (exceeds MAX_MESSAGE_SIZE)
    buf[0] = 0;
    buf[1] = 0x50;
    buf[2] = 0;
    buf[3] = 0;
    const result = decodeFrame(&buf);
    try std.testing.expectError(FrameError.MessageTooLarge, result);
}
