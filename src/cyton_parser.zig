//! Cyton Parser — OpenBCI Cyton 8-Channel EEG Packet Decoding
//!
//! Parses OpenBCI Cyton 33-byte frames into structured EEG samples.
//! Each frame contains:
//!   - 1 start byte (0xA0)
//!   - 1 sample counter (0-255)
//!   - 24 bytes of channel data (8 channels × 3 bytes each, 24-bit ADC)
//!   - 6 bytes of aux data (3 × int16 accelerometer)
//!   - 1 stop byte (0xC0)
//!
//! Total: 33 bytes @ 250 Hz = 8.25 KB/sec
//!
//! Channels: [Fp1, Fp2, C3, C4, P3, P4, O1, O2] (10-20 electrode placement)
//! Gain: 24 (6x bioamplifier gain)
//! ADC Reference: 4.5V
//! Scale: (Vref / (Gain × 2^24)) × 1e6 to get microvolts

const std = @import("std");

// ============================================================================
// CONSTANTS
// ============================================================================

pub const CYTON_START_BYTE: u8 = 0xA0;
pub const CYTON_STOP_BYTE: u8 = 0xC0;
pub const CYTON_PACKET_LEN: usize = 33;
pub const CYTON_NUM_CHANNELS: usize = 8;
pub const CYTON_SAMPLE_RATE: f64 = 250.0;

// Amplifier gain (fixed at 24)
pub const CYTON_GAIN: f64 = 24.0;

// ADC reference voltage
pub const CYTON_VREF: f64 = 4.5;

// Precomputed scale factor: Vref / (Gain × 2^24) × 1e6 (to microvolts)
pub const CYTON_SCALE: f64 = (CYTON_VREF / (CYTON_GAIN * @as(f64, 1 << 24))) * 1e6;

// Channel labels (10-20 electrode placement, 8-channel Cyton)
pub const CHANNEL_LABELS = [_][]const u8{ "Fp1", "Fp2", "C3", "C4", "P3", "P4", "O1", "O2" };

// ============================================================================
// DATA STRUCTURES
// ============================================================================

/// Raw 24-bit signed integer ADC value
pub const ADC24 = i32;  // Stored in i32 but only 24 bits used

/// Single EEG sample from Cyton device
pub const CytonSample = struct {
    timestamp: i64,                        // Nanoseconds (or milliseconds from device)
    sample_number: u8,                     // 0-255 counter (wraps)
    channels: [CYTON_NUM_CHANNELS]f32,    // 8 channels in microvolts
    accel: [3]i16,                         // 3-axis accelerometer (raw)

    pub fn format(
        self: CytonSample,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;

        try writer.print("CytonSample{{ sample_num={}, channels=[", .{self.sample_number});
        for (self.channels, 0..) |ch, i| {
            if (i > 0) try writer.writeAll(", ");
            try writer.print("{d:.2}", .{ch});
        }
        try writer.print("], accel=[{}, {}, {}] }}", .{ self.accel[0], self.accel[1], self.accel[2] });
    }
};

// ============================================================================
// PACKET PARSING
// ============================================================================

/// Parse error types
pub const ParseError = error{
    InvalidLength,
    InvalidStartByte,
    InvalidStopByte,
    InvalidChannelData,
    AllocationFailed,
};

/// Parse a single 33-byte Cyton packet
pub fn parseCytonPacket(data: [CYTON_PACKET_LEN]u8, timestamp: i64) ParseError!CytonSample {
    if (data[0] != CYTON_START_BYTE) {
        return ParseError.InvalidStartByte;
    }
    if (data[32] != CYTON_STOP_BYTE) {
        return ParseError.InvalidStopByte;
    }

    const sample_number = data[1];

    // Parse 8 channels (3 bytes each, big-endian 24-bit signed)
    var channels: [CYTON_NUM_CHANNELS]f32 = undefined;
    for (0..CYTON_NUM_CHANNELS) |i| {
        const offset = 2 + i * 3;

        // Read 3 bytes in big-endian, convert to 32-bit signed
        var raw: i32 = 0;
        raw |= @as(i32, data[offset]) << 16;
        raw |= @as(i32, data[offset + 1]) << 8;
        raw |= @as(i32, data[offset + 2]);

        // Sign-extend from 24-bit to 32-bit
        if ((raw & 0x800000) != 0) {
            raw |= @as(i32, -16777216);  // 0xFF000000 in 32-bit signed
        }

        // Convert to microvolts
        channels[i] = @as(f32, @floatFromInt(raw)) * @as(f32, @floatCast(CYTON_SCALE));
    }

    // Parse accelerometer (3 × int16, big-endian)
    var accel: [3]i16 = undefined;
    accel[0] = @as(i16, @bitCast((@as(u16, data[26]) << 8) | data[27]));
    accel[1] = @as(i16, @bitCast((@as(u16, data[28]) << 8) | data[29]));
    accel[2] = @as(i16, @bitCast((@as(u16, data[30]) << 8) | data[31]));

    return CytonSample{
        .timestamp = timestamp,
        .sample_number = sample_number,
        .channels = channels,
        .accel = accel,
    };
}

/// Parse a stream of packets from raw bytes (synchronized to start byte)
/// Returns a list of CytonSample structs
pub fn parseStream(
    data: []const u8,
    allocator: std.mem.Allocator,
) ParseError![]CytonSample {
    var samples = std.ArrayList(CytonSample).init(allocator);
    errdefer samples.deinit();

    var i: usize = 0;
    var timestamp: i64 = 0;

    while (i < data.len) {
        // Find next sync byte (0xA0)
        while (i < data.len and data[i] != CYTON_START_BYTE) {
            i += 1;
        }

        if (i + CYTON_PACKET_LEN > data.len) {
            break; // Not enough data for complete packet
        }

        // Extract 33-byte packet
        var packet: [CYTON_PACKET_LEN]u8 = undefined;
        @memcpy(&packet, data[i .. i + CYTON_PACKET_LEN]);

        // Try to parse
        if (parseCytonPacket(packet, timestamp)) |sample| {
            try samples.append(sample);
            timestamp += @as(i64, @intFromFloat(1e9 / CYTON_SAMPLE_RATE)); // ~4ms intervals
        } else |_| {
            // Skip this packet and continue searching
        }

        i += 1;
    }

    return samples.toOwnedSlice();
}

// ============================================================================
// TESTS
// ============================================================================

test "parse valid cyton packet" {
    // Construct a valid packet
    var packet: [CYTON_PACKET_LEN]u8 = undefined;
    packet[0] = CYTON_START_BYTE;
    packet[1] = 42; // sample number

    // All channels set to 0x000000 (0 µV)
    for (0..CYTON_NUM_CHANNELS) |i| {
        packet[2 + i * 3] = 0;
        packet[2 + i * 3 + 1] = 0;
        packet[2 + i * 3 + 2] = 0;
    }

    // Accelerometer set to 0
    for (26..32) |i| {
        packet[i] = 0;
    }
    packet[32] = CYTON_STOP_BYTE;

    const sample = try parseCytonPacket(packet, 0);
    try std.testing.expectEqual(sample.sample_number, 42);
    for (sample.channels) |ch| {
        try std.testing.expectApproxEqAbs(ch, 0.0, 0.001);
    }
}

test "parse positive adc value" {
    var packet: [CYTON_PACKET_LEN]u8 = undefined;
    packet[0] = CYTON_START_BYTE;
    packet[1] = 0;

    // Channel 0: 0x800000 (8388608, midpoint)
    packet[2] = 0x80;
    packet[3] = 0x00;
    packet[4] = 0x00;

    // All other channels 0
    for (5..26) |i| {
        packet[i] = 0;
    }
    for (26..32) |i| {
        packet[i] = 0;
    }
    packet[32] = CYTON_STOP_BYTE;

    const sample = try parseCytonPacket(packet, 0);
    // 0x800000 × scale ≈ 0.268 µV (very small)
    try std.testing.expectApproxEqAbs(sample.channels[0], 0.268, 0.001);
}

test "reject invalid start byte" {
    var packet: [CYTON_PACKET_LEN]u8 = undefined;
    packet[0] = 0xFF; // Invalid start byte
    packet[32] = CYTON_STOP_BYTE;

    const result = parseCytonPacket(packet, 0);
    try std.testing.expectError(ParseError.InvalidStartByte, result);
}

test "reject invalid stop byte" {
    var packet: [CYTON_PACKET_LEN]u8 = undefined;
    packet[0] = CYTON_START_BYTE;
    packet[32] = 0xFF; // Invalid stop byte

    const result = parseCytonPacket(packet, 0);
    try std.testing.expectError(ParseError.InvalidStopByte, result);
}

test "parse stream with multiple packets" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create stream: valid packet + garbage + valid packet
    var stream: [CYTON_PACKET_LEN * 2 + 10]u8 = undefined;

    // Packet 1
    stream[0] = CYTON_START_BYTE;
    stream[1] = 10;
    for (2..26) |i| {
        stream[i] = 0;
    }
    for (26..32) |i| {
        stream[i] = 0;
    }
    stream[32] = CYTON_STOP_BYTE;

    // Garbage
    for (33..38) |i| {
        stream[i] = 0xFF;
    }

    // Packet 2
    stream[38] = CYTON_START_BYTE;
    stream[39] = 11;
    for (40..64) |i| {
        stream[i] = 0;
    }
    for (64..70) |i| {
        stream[i] = 0;
    }
    stream[70] = CYTON_STOP_BYTE;

    const samples = try parseStream(&stream, allocator);
    defer allocator.free(samples);

    try std.testing.expectEqual(samples.len, 2);
    try std.testing.expectEqual(samples[0].sample_number, 10);
    try std.testing.expectEqual(samples[1].sample_number, 11);
}
