//! DSI-24 Parser — Wearable Sensing DSI-24 Dry EEG Packet Decoding
//!
//! Parses Wearable Sensing DSI-24 binary packets from Bluetooth SPP or
//! DSI-Streamer LSL relay. 21 EEG channels + 3 aux, dry electrodes,
//! ADS1299 ADC (same chip as OpenBCI Cyton).
//!
//! Packet format (DSI-Streamer binary output):
//!   - 1 byte: packet type (0x01 = EEG data)
//!   - 4 bytes: sample counter (big-endian u32)
//!   - 4 bytes: timestamp (big-endian u32, device clock µs)
//!   - 72 bytes: 24 channels × 3 bytes each (24-bit signed, big-endian)
//!     Channels 0-20: EEG (full 10-20 montage)
//!     Channels 21-23: AUX (trigger, reference, status)
//!   - 1 byte: trigger input (TTL 0-255)
//!   - 1 byte: battery level (0-100%)
//!   - 1 byte: impedance flag
//!   - Total: 84 bytes per sample @ 300 Hz = 25.2 KB/sec
//!
//! Channel montage (10-20 system, 21 EEG channels):
//!   Fp1, Fp2, F7, F3, Fz, F4, F8,
//!   T7, C3, Cz, C4, T8,
//!   P7, P3, Pz, P4, P8,
//!   O1, O2,
//!   A1 (left mastoid ref), A2 (right mastoid ref)
//!
//! Also supports reading from LSL via liblsl C API (see lsl_inlet.zig).

const std = @import("std");

// ============================================================================
// CONSTANTS
// ============================================================================

pub const DSI24_PACKET_TYPE_EEG: u8 = 0x01;
pub const DSI24_PACKET_TYPE_IMPEDANCE: u8 = 0x02;
pub const DSI24_PACKET_TYPE_EVENT: u8 = 0x03;

pub const DSI24_PACKET_LEN: usize = 84;
pub const DSI24_NUM_EEG_CHANNELS: usize = 21;
pub const DSI24_NUM_AUX_CHANNELS: usize = 3;
pub const DSI24_NUM_TOTAL_CHANNELS: usize = 24;
pub const DSI24_SAMPLE_RATE: f64 = 300.0;

// ADS1299 parameters (same chip as OpenBCI Cyton)
pub const DSI24_GAIN: f64 = 24.0;
pub const DSI24_VREF: f64 = 4.5;
pub const DSI24_SCALE: f64 = (DSI24_VREF / (DSI24_GAIN * @as(f64, 1 << 24))) * 1e6;

// Channel labels: full 10-20 montage + references
pub const CHANNEL_LABELS = [DSI24_NUM_TOTAL_CHANNELS][]const u8{
    "Fp1",  "Fp2",  "F7",   "F3", "Fz", "F4", "F8",
    "T7",   "C3",   "Cz",   "C4", "T8", "P7", "P3",
    "Pz",   "P4",   "P8",   "O1", "O2", "A1", "A2",
    "AUX1", "AUX2", "AUX3",
};

// ============================================================================
// DATA STRUCTURES
// ============================================================================

pub const DSI24Sample = struct {
    timestamp_us: u32, // Device clock (microseconds)
    sample_counter: u32,
    eeg_channels: [DSI24_NUM_EEG_CHANNELS]f32, // 21 EEG in microvolts
    aux_channels: [DSI24_NUM_AUX_CHANNELS]f32, // 3 AUX in microvolts
    trigger: u8, // TTL trigger input (0-255)
    battery_pct: u8, // Battery level (0-100%)
    impedance_flag: u8, // Impedance check active

    pub fn allChannels(self: *const DSI24Sample) [DSI24_NUM_TOTAL_CHANNELS]f32 {
        var result: [DSI24_NUM_TOTAL_CHANNELS]f32 = undefined;
        @memcpy(result[0..DSI24_NUM_EEG_CHANNELS], &self.eeg_channels);
        @memcpy(result[DSI24_NUM_EEG_CHANNELS..], &self.aux_channels);
        return result;
    }

    pub fn format(
        self: DSI24Sample,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        try writer.print("DSI24Sample{{ counter={}, trigger={}, battery={}%, channels=[", .{
            self.sample_counter,
            self.trigger,
            self.battery_pct,
        });
        for (self.eeg_channels[0..5], 0..) |ch, i| {
            if (i > 0) try writer.writeAll(", ");
            try writer.print("{d:.2}", .{ch});
        }
        try writer.writeAll(", ...] }}");
    }
};

// ============================================================================
// PACKET PARSING
// ============================================================================

pub const ParseError = error{
    InvalidLength,
    InvalidPacketType,
    InvalidChannelData,
};

/// Parse a 24-bit big-endian signed integer from 3 bytes
fn parseADC24(bytes: [3]u8) f32 {
    var raw: i32 = 0;
    raw |= @as(i32, bytes[0]) << 16;
    raw |= @as(i32, bytes[1]) << 8;
    raw |= @as(i32, bytes[2]);

    // Sign-extend from 24-bit to 32-bit
    if ((raw & 0x800000) != 0) {
        raw |= @as(i32, -16777216); // 0xFF000000
    }

    return @as(f32, @floatFromInt(raw)) * @as(f32, @floatCast(DSI24_SCALE));
}

/// Parse a single DSI-24 binary packet (84 bytes)
pub fn parseDSI24Packet(data: []const u8) ParseError!DSI24Sample {
    if (data.len < DSI24_PACKET_LEN) {
        return ParseError.InvalidLength;
    }

    if (data[0] != DSI24_PACKET_TYPE_EEG) {
        return ParseError.InvalidPacketType;
    }

    // Sample counter (bytes 1-4, big-endian u32)
    const sample_counter: u32 =
        @as(u32, data[1]) << 24 |
        @as(u32, data[2]) << 16 |
        @as(u32, data[3]) << 8 |
        @as(u32, data[4]);

    // Timestamp (bytes 5-8, big-endian u32, microseconds)
    const timestamp_us: u32 =
        @as(u32, data[5]) << 24 |
        @as(u32, data[6]) << 16 |
        @as(u32, data[7]) << 8 |
        @as(u32, data[8]);

    // Parse 24 channels (3 bytes each, starting at byte 9)
    var eeg_channels: [DSI24_NUM_EEG_CHANNELS]f32 = undefined;
    var aux_channels: [DSI24_NUM_AUX_CHANNELS]f32 = undefined;

    for (0..DSI24_NUM_TOTAL_CHANNELS) |i| {
        const offset = 9 + i * 3;
        const adc_bytes = [3]u8{ data[offset], data[offset + 1], data[offset + 2] };
        const uv = parseADC24(adc_bytes);
        if (i < DSI24_NUM_EEG_CHANNELS) {
            eeg_channels[i] = uv;
        } else {
            aux_channels[i - DSI24_NUM_EEG_CHANNELS] = uv;
        }
    }

    // Metadata (bytes 81-83)
    return DSI24Sample{
        .timestamp_us = timestamp_us,
        .sample_counter = sample_counter,
        .eeg_channels = eeg_channels,
        .aux_channels = aux_channels,
        .trigger = data[81],
        .battery_pct = data[82],
        .impedance_flag = data[83],
    };
}

/// Parse a stream of DSI-24 packets
pub fn parseStream(
    data: []const u8,
    allocator: std.mem.Allocator,
) (ParseError || error{OutOfMemory})![]DSI24Sample {
    var samples = std.ArrayListUnmanaged(DSI24Sample){};
    errdefer samples.deinit(allocator);

    var i: usize = 0;
    while (i + DSI24_PACKET_LEN <= data.len) {
        // Find next EEG packet type byte
        while (i < data.len and data[i] != DSI24_PACKET_TYPE_EEG) {
            i += 1;
        }
        if (i + DSI24_PACKET_LEN > data.len) break;

        if (parseDSI24Packet(data[i .. i + DSI24_PACKET_LEN])) |sample| {
            try samples.append(allocator, sample);
            i += DSI24_PACKET_LEN;
        } else |_| {
            i += 1; // Skip and resync
        }
    }

    return samples.toOwnedSlice(allocator);
}

/// Convert DSI24Sample to the format expected by fft_bands.extractBands
/// Returns per-channel f32 slices suitable for FFT processing
pub fn sampleToChannelArrays(
    samples: []const DSI24Sample,
    channel: usize,
    allocator: std.mem.Allocator,
) ![]f32 {
    if (channel >= DSI24_NUM_EEG_CHANNELS) return error.InvalidChannelData;
    const out = try allocator.alloc(f32, samples.len);
    for (samples, 0..) |s, i| {
        out[i] = s.eeg_channels[channel];
    }
    return out;
}

// ============================================================================
// TESTS
// ============================================================================

test "parse valid DSI-24 packet" {
    var packet = [_]u8{0} ** DSI24_PACKET_LEN;
    packet[0] = DSI24_PACKET_TYPE_EEG;
    // Sample counter = 1
    packet[4] = 1;
    // All channels zero → 0 µV

    const sample = try parseDSI24Packet(&packet);
    try std.testing.expectEqual(@as(u32, 1), sample.sample_counter);
    for (sample.eeg_channels) |ch| {
        try std.testing.expectApproxEqAbs(ch, 0.0, 0.001);
    }
}

test "parse positive ADC value (channel 0)" {
    var packet = [_]u8{0} ** DSI24_PACKET_LEN;
    packet[0] = DSI24_PACKET_TYPE_EEG;
    // Channel 0: 24 counts (0x000018)
    packet[9] = 0x00;
    packet[10] = 0x00;
    packet[11] = 0x18;

    const sample = try parseDSI24Packet(&packet);
    // Same ADS1299 as Cyton: 24 × scale ≈ 0.268 µV
    try std.testing.expectApproxEqAbs(sample.eeg_channels[0], 0.268, 0.001);
}

test "parse negative ADC value (sign extension)" {
    var packet = [_]u8{0} ** DSI24_PACKET_LEN;
    packet[0] = DSI24_PACKET_TYPE_EEG;
    // Channel 0: -1 (0xFFFFFF in 24-bit)
    packet[9] = 0xFF;
    packet[10] = 0xFF;
    packet[11] = 0xFF;

    const sample = try parseDSI24Packet(&packet);
    // -1 × scale ≈ -0.0112 µV
    try std.testing.expect(sample.eeg_channels[0] < 0);
}

test "reject invalid packet type" {
    var packet = [_]u8{0} ** DSI24_PACKET_LEN;
    packet[0] = 0xFF;
    try std.testing.expectError(ParseError.InvalidPacketType, parseDSI24Packet(&packet));
}

test "reject short packet" {
    const short = [_]u8{0x01} ** 10;
    try std.testing.expectError(ParseError.InvalidLength, parseDSI24Packet(&short));
}

test "parse stream with two packets" {
    const allocator = std.testing.allocator;

    var stream = [_]u8{0} ** (DSI24_PACKET_LEN * 2);
    // Packet 1
    stream[0] = DSI24_PACKET_TYPE_EEG;
    stream[4] = 10;
    // Packet 2
    stream[DSI24_PACKET_LEN] = DSI24_PACKET_TYPE_EEG;
    stream[DSI24_PACKET_LEN + 4] = 11;

    const samples = try parseStream(&stream, allocator);
    defer allocator.free(samples);

    try std.testing.expectEqual(@as(usize, 2), samples.len);
    try std.testing.expectEqual(@as(u32, 10), samples[0].sample_counter);
    try std.testing.expectEqual(@as(u32, 11), samples[1].sample_counter);
}

test "channel labels count" {
    try std.testing.expectEqual(@as(usize, 24), CHANNEL_LABELS.len);
    try std.testing.expect(std.mem.eql(u8, "Fp1", CHANNEL_LABELS[0]));
    try std.testing.expect(std.mem.eql(u8, "O2", CHANNEL_LABELS[18]));
    try std.testing.expect(std.mem.eql(u8, "A1", CHANNEL_LABELS[19]));
}

test "metadata fields parsed" {
    var packet = [_]u8{0} ** DSI24_PACKET_LEN;
    packet[0] = DSI24_PACKET_TYPE_EEG;
    packet[81] = 42; // trigger
    packet[82] = 85; // battery 85%
    packet[83] = 1; // impedance active

    const sample = try parseDSI24Packet(&packet);
    try std.testing.expectEqual(@as(u8, 42), sample.trigger);
    try std.testing.expectEqual(@as(u8, 85), sample.battery_pct);
    try std.testing.expectEqual(@as(u8, 1), sample.impedance_flag);
}

test "ADC scale matches Cyton (same ADS1299 chip)" {
    // Both use Vref=4.5V, Gain=24, 24-bit ADC
    const cyton_scale = (4.5 / (24.0 * @as(f64, 1 << 24))) * 1e6;
    try std.testing.expectApproxEqAbs(DSI24_SCALE, cyton_scale, 1e-10);
}
