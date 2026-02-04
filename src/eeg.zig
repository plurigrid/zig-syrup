//! EEG Processing Binary - Tier 1 Brain Wave Color Indexing
//!
//! Reads OpenBCI Cyton packets from stdin, extracts frequency bands,
//! derives GF(3)-balanced triadic colors, and outputs JSON to stdout.
//!
//! Usage:
//!   echo '[raw 33-byte packet bytes]' | eeg > output.json
//!
//! Or from Python subprocess:
//!   proc = spawn(["./eeg"])
//!   proc.stdin.write(packet_bytes)
//!   result = proc.stdout.read()

const std = @import("std");
const cyton_parser = @import("cyton_parser.zig");
const fft_bands = @import("fft_bands.zig");

// ============================================================================
// CONSTANTS
// ============================================================================

const SAMPLE_RATE: f64 = 250.0;
const BUFFER_SIZE: usize = 256 * 1024; // 256 KB input buffer
const OUTPUT_SIZE: usize = 64 * 1024;  // 64 KB output buffer

// ============================================================================
// TYPES
// ============================================================================

/// GF(3) trit assignment based on frequency band
pub const TriadicColor = struct {
    t1: i2,      // Band-based trit: -1, 0, +1
    t2: i2,      // Variance-based trit
    t3: i2,      // Auto-balanced to make sum ≡ 0 (mod 3)
    hex: [7]u8, // "#RRGGBB" format
    dominant_band: []const u8, // "alpha" etc (no null terminator needed)
    band_power: f32,
    integration: f32, // Coherence metric

    pub fn format(
        self: TriadicColor,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        try writer.print("TriadicColor{{ t1={}, t2={}, t3={}, hex={s}, dominant_band={s}, integration={d:.3} }}", .{
            self.t1,
            self.t2,
            self.t3,
            self.hex,
            self.dominant_band,
            self.integration,
        });
    }
};

/// Output message format (matches Python indexer)
pub const EEGOutput = struct {
    ts: i64,
    seq: u32,
    epoch: u32,
    color: TriadicColor,
    powers: fft_bands.BandPowers,
    gf3_sum: i2,
};

// ============================================================================
// COLOR MAPPING
// ============================================================================

/// Map frequency bands to GF(3) trits
fn bandToTrit(band: fft_bands.Band) i2 {
    return switch (band) {
        .delta => -1,  // Low frequencies: contraction
        .theta => -1,  // Meditation: contraction
        .alpha => 0,   // Neutral: balanced
        .beta => 1,    // Active: expansion
        .gamma => 1,   // Cognitive: expansion
    };
}

/// Find dominant band (highest power)
const DominantBand = struct {
    band: fft_bands.Band,
    power: f32,
};

fn findDominantBand(powers: fft_bands.BandPowers) DominantBand {
    const bands = [_]DominantBand{
        .{ .band = .delta, .power = powers.delta },
        .{ .band = .theta, .power = powers.theta },
        .{ .band = .alpha, .power = powers.alpha },
        .{ .band = .beta, .power = powers.beta },
        .{ .band = .gamma, .power = powers.gamma },
    };

    var max_band = bands[0];
    for (bands[1..]) |b| {
        if (b.power > max_band.power) {
            max_band = b;
        }
    }
    return max_band;
}

/// Sanitize floating point values (handle NaN/Inf)
fn sanitizeValue(val: f32) f32 {
    if (!std.math.isFinite(val)) {
        return 0.0;
    }
    return val;
}

/// Derive GF(3)-balanced triadic color from band powers
fn deriveColor(powers: fft_bands.BandPowers, allocator: std.mem.Allocator) !TriadicColor {
    _ = allocator; // For future Syrup encoding

    // Sanitize input powers (handle NaN/Inf from FFT edge cases)
    const clean_powers = fft_bands.BandPowers{
        .delta = sanitizeValue(powers.delta),
        .theta = sanitizeValue(powers.theta),
        .alpha = sanitizeValue(powers.alpha),
        .beta = sanitizeValue(powers.beta),
        .gamma = sanitizeValue(powers.gamma),
    };

    const dominant = findDominantBand(clean_powers);
    const t1 = bandToTrit(dominant.band);

    // Variance-based trit (energy spread across bands)
    const avg_power = (clean_powers.delta + clean_powers.theta + clean_powers.alpha + clean_powers.beta + clean_powers.gamma) / 5.0;
    const variance = ((clean_powers.delta - avg_power) * (clean_powers.delta - avg_power) +
        (clean_powers.theta - avg_power) * (clean_powers.theta - avg_power) +
        (clean_powers.alpha - avg_power) * (clean_powers.alpha - avg_power) +
        (clean_powers.beta - avg_power) * (clean_powers.beta - avg_power) +
        (clean_powers.gamma - avg_power) * (clean_powers.gamma - avg_power)) / 5.0;

    const t2: i2 = if (variance > avg_power * 0.5) 1 else if (variance < avg_power * 0.1) -1 else 0;

    // Auto-balance: t3 = -(t1 + t2) mod 3
    const sum = @as(i32, @intCast(t1)) + @as(i32, @intCast(t2));
    const t3: i2 = @intCast(@mod(-sum, 3));

    // Generate hex color using golden angle (137.508°) mapping
    // For now, use a simple hue map based on dominant band
    const hue_offset: i32 = switch (dominant.band) {
        .delta => 240,   // Blue: delta
        .theta => 210,   // Cyan: theta
        .alpha => 120,   // Green: alpha
        .beta => 30,     // Yellow/Orange: beta
        .gamma => 0,     // Red: gamma
    };

    // Simplified RGB (full saturation, medium lightness)
    const r = @as(u8, @intCast(@divTrunc(@mod(hue_offset + 120, 360) * 255, 360)));
    const g = @as(u8, @intCast(@divTrunc(@mod(hue_offset + 240, 360) * 255, 360)));
    const b = @as(u8, @intCast(@divTrunc(@mod(hue_offset, 360) * 255, 360)));

    var hex_buf: [7]u8 = undefined;
    _ = try std.fmt.bufPrint(&hex_buf, "#{X:0>2}{X:0>2}{X:0>2}", .{ r, g, b });

    const band_name = dominant.band.name();
    const integration = dominant.power / (avg_power + 0.001);

    return TriadicColor{
        .t1 = t1,
        .t2 = t2,
        .t3 = t3,
        .hex = hex_buf,
        .dominant_band = band_name,
        .band_power = dominant.power,
        .integration = integration,
    };
}

// ============================================================================
// MAIN
// ============================================================================

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // For stdin: read from file descriptor 0
    var input_buffer: [BUFFER_SIZE]u8 = undefined;
    const bytes_read = try std.posix.read(std.posix.STDIN_FILENO, &input_buffer);

    if (bytes_read == 0) {
        _ = try std.posix.write(std.posix.STDOUT_FILENO, "{\"error\": \"no input\"}\n");
        return;
    }

    // Try to parse as raw 33-byte Cyton packet
    if (bytes_read == cyton_parser.CYTON_PACKET_LEN) {
        var packet: [cyton_parser.CYTON_PACKET_LEN]u8 = undefined;
        @memcpy(&packet, input_buffer[0..cyton_parser.CYTON_PACKET_LEN]);

        // Parse packet
        const sample = cyton_parser.parseCytonPacket(packet, 0) catch |err| {
            var error_buf: [256]u8 = undefined;
            const error_msg = switch (err) {
                cyton_parser.ParseError.InvalidStartByte => "invalid_start_byte",
                cyton_parser.ParseError.InvalidStopByte => "invalid_stop_byte",
                cyton_parser.ParseError.InvalidChannelData => "invalid_channel_data",
                else => "parse_error",
            };
            const json = try std.fmt.bufPrint(&error_buf, "{{\"error\": \"{s}\"}}\n", .{error_msg});
            _ = try std.posix.write(std.posix.STDOUT_FILENO, json);
            return;
        };

        // Extract bands from 1-second window
        // For now, use channels as synthetic time series
        var synthetic_signal: [256]f32 = undefined;
        for (0..256) |i| {
            synthetic_signal[i] = sample.channels[i % 8];
        }

        const powers = try fft_bands.extractBands(&synthetic_signal, SAMPLE_RATE, allocator);
        const color = try deriveColor(powers, allocator);

        // Create output
        const output = EEGOutput{
            .ts = std.time.milliTimestamp(),
            .seq = sample.sample_number,
            .epoch = 0,
            .color = color,
            .powers = powers,
            .gf3_sum = @as(i2, @intCast(@mod(@as(i32, color.t1) + @as(i32, color.t2) + @as(i32, color.t3), 3))),
        };

        // Write JSON output (sanitize floating point values)
        var output_buf: [OUTPUT_SIZE]u8 = undefined;
        const json = try std.fmt.bufPrint(&output_buf,
            \\{{"ts": {d}, "seq": {d}, "epoch": {d}, "color": {{"t1": {d}, "t2": {d}, "t3": {d}, "hex": "{s}", "dominant_band": "{s}", "integration": {d:.3}}}, "powers": {{"delta": {d:.6}, "theta": {d:.6}, "alpha": {d:.6}, "beta": {d:.6}, "gamma": {d:.6}}}, "gf3_sum": {d}}}
        ,
            .{
                output.ts,
                output.seq,
                output.epoch,
                output.color.t1,
                output.color.t2,
                output.color.t3,
                output.color.hex,
                output.color.dominant_band,
                sanitizeValue(output.color.integration),
                sanitizeValue(output.powers.delta),
                sanitizeValue(output.powers.theta),
                sanitizeValue(output.powers.alpha),
                sanitizeValue(output.powers.beta),
                sanitizeValue(output.powers.gamma),
                output.gf3_sum,
            },
        );
        _ = try std.posix.write(std.posix.STDOUT_FILENO, json);
        _ = try std.posix.write(std.posix.STDOUT_FILENO, "\n");
    } else {
        var err_buf: [256]u8 = undefined;
        const err_msg = try std.fmt.bufPrint(&err_buf, "{{\"error\": \"expected {d} bytes, got {d}\"}}\n", .{ cyton_parser.CYTON_PACKET_LEN, bytes_read });
        _ = try std.posix.write(std.posix.STDOUT_FILENO, err_msg);
    }
}

// ============================================================================
// TESTS
// ============================================================================

test "derive color from band powers" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const powers = fft_bands.BandPowers{
        .delta = 0.01,
        .theta = 0.02,
        .alpha = 0.15,
        .beta = 0.05,
        .gamma = 0.01,
    };

    const color = try deriveColor(powers, allocator);
    try std.testing.expect(color.t1 == 0); // alpha is neutral
    try std.testing.expectEqual(color.integration > 1.0, true);
}

test "find dominant band" {
    const powers = fft_bands.BandPowers{
        .delta = 0.01,
        .theta = 0.02,
        .alpha = 0.50,
        .beta = 0.05,
        .gamma = 0.01,
    };

    const dominant = findDominantBand(powers);
    try std.testing.expectEqual(dominant.band, .alpha);
    try std.testing.expectApproxEqAbs(dominant.power, 0.50, 0.001);
}
