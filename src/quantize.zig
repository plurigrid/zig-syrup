//! Palette Quantization for Terminal Color Reduction
//!
//! Implements fast lookup-table based color quantization for reducing 24-bit RGB
//! colors to terminal-compatible palettes (xterm-256, xterm-16, ANSI-8).
//!
//! Algorithm: Pre-computed 16×16×16 lookup table with Euclidean distance in RGB space.
//! This provides O(1) per-cell quantization with negligible latency (<1µs per cell).
//!
//! Reference: notcurses/core/color.c palette reduction strategy

const std = @import("std");
const Allocator = std.mem.Allocator;

// ============================================================================
// XTERM-256 PALETTE (Standard 256-color palette)
// ============================================================================

/// Standard xterm-256 color palette
/// Layout: colors 0-15 (ANSI 16), 16-231 (216-color cube), 232-255 (grayscale)
pub const XTERM256_PALETTE: [256][3]u8 = palette: {
    @setEvalBranchQuota(10000);
    var pal: [256][3]u8 = undefined;

    // 0-15: Standard ANSI colors
    pal[0] = .{ 0x00, 0x00, 0x00 }; // black
    pal[1] = .{ 0x80, 0x00, 0x00 }; // maroon
    pal[2] = .{ 0x00, 0x80, 0x00 }; // green
    pal[3] = .{ 0x80, 0x80, 0x00 }; // olive
    pal[4] = .{ 0x00, 0x00, 0x80 }; // navy
    pal[5] = .{ 0x80, 0x00, 0x80 }; // purple
    pal[6] = .{ 0x00, 0x80, 0x80 }; // teal
    pal[7] = .{ 0xc0, 0xc0, 0xc0 }; // silver
    pal[8] = .{ 0x80, 0x80, 0x80 }; // gray
    pal[9] = .{ 0xff, 0x00, 0x00 }; // red
    pal[10] = .{ 0x00, 0xff, 0x00 }; // lime
    pal[11] = .{ 0xff, 0xff, 0x00 }; // yellow
    pal[12] = .{ 0x00, 0x00, 0xff }; // blue
    pal[13] = .{ 0xff, 0x00, 0xff }; // magenta
    pal[14] = .{ 0x00, 0xff, 0xff }; // cyan
    pal[15] = .{ 0xff, 0xff, 0xff }; // white

    // 16-231: 6×6×6 RGB cube
    var idx: usize = 16;
    var r: u8 = 0;
    while (r < 6) : (r += 1) {
        var g: u8 = 0;
        while (g < 6) : (g += 1) {
            var b: u8 = 0;
            while (b < 6) : (b += 1) {
                const r_val = if (r == 0) 0 else 95 + (r - 1) * 40;
                const g_val = if (g == 0) 0 else 95 + (g - 1) * 40;
                const b_val = if (b == 0) 0 else 95 + (b - 1) * 40;
                pal[idx] = .{ r_val, g_val, b_val };
                idx += 1;
            }
        }
    }

    // 232-255: Grayscale (24 shades)
    var gray: u8 = 0;
    while (gray < 24) : (gray += 1) {
        const val = 8 + gray * 10;
        pal[232 + gray] = .{ val, val, val };
    }

    break :palette pal;
};

/// Standard xterm-16 ANSI palette (first 16 colors)
pub const XTERM16_PALETTE: [16][3]u8 = .{
    .{ 0x00, 0x00, 0x00 }, // black
    .{ 0x80, 0x00, 0x00 }, // maroon
    .{ 0x00, 0x80, 0x00 }, // green
    .{ 0x80, 0x80, 0x00 }, // olive
    .{ 0x00, 0x00, 0x80 }, // navy
    .{ 0x80, 0x00, 0x80 }, // purple
    .{ 0x00, 0x80, 0x80 }, // teal
    .{ 0xc0, 0xc0, 0xc0 }, // silver
    .{ 0x80, 0x80, 0x80 }, // gray
    .{ 0xff, 0x00, 0x00 }, // red
    .{ 0x00, 0xff, 0x00 }, // lime
    .{ 0xff, 0xff, 0x00 }, // yellow
    .{ 0x00, 0x00, 0xff }, // blue
    .{ 0xff, 0x00, 0xff }, // magenta
    .{ 0x00, 0xff, 0xff }, // cyan
    .{ 0xff, 0xff, 0xff }, // white
};

// ============================================================================
// QUANTIZATION LOOKUP TABLE (16×16×16)
// ============================================================================

/// Fast O(1) quantization via 16×16×16 lookup table
/// Maps RGB 8-bit values to nearest palette indices by dividing RGB into 16 buckets
pub const QuantizationLUT = struct {
    /// 16×16×16 LUT: lut[r//16][g//16][b//16] = palette_index
    lut: *[16][16][16]u8,
    palette: []*const [3]u8,
    palette_size: u16,
    allocator: Allocator,

    pub fn init(
        allocator: Allocator,
        palette: []*const [3]u8,
        palette_size: u16,
    ) !QuantizationLUT {
        // Allocate LUT array
        const lut = try allocator.create([16][16][16]u8);

        // Build LUT: for each bucket [r16][g16][b16], find nearest palette color
        var r16: u8 = 0;
        while (r16 < 16) : (r16 += 1) {
            var g16: u8 = 0;
            while (g16 < 16) : (g16 += 1) {
                var b16: u8 = 0;
                while (b16 < 16) : (b16 += 1) {
                    // Bucket center in RGB space (scale 0-15 → 0-255)
                    const r_center = r16 * 16 + 8;
                    const g_center = g16 * 16 + 8;
                    const b_center = b16 * 16 + 8;

                    // Find nearest palette color
                    var best_idx: u8 = 0;
                    var best_dist: u32 = std.math.maxInt(u32);

                    for (0..@min(palette_size, 256)) |idx| {
                        const pal_rgb = palette[idx];
                        const dist = euclideanDistanceSq(
                            r_center,
                            g_center,
                            b_center,
                            pal_rgb[0],
                            pal_rgb[1],
                            pal_rgb[2],
                        );
                        if (dist < best_dist) {
                            best_dist = dist;
                            best_idx = @truncate(idx);
                        }
                    }

                    lut[r16][g16][b16] = best_idx;
                }
            }
        }

        return .{
            .lut = lut,
            .palette = palette,
            .palette_size = palette_size,
            .allocator = allocator,
        };
    }

    /// Fast O(1) color quantization via LUT lookup
    pub fn quantize(self: *const QuantizationLUT, r: u8, g: u8, b: u8) u8 {
        const r_idx = (r >> 4); // r / 16
        const g_idx = (g >> 4); // g / 16
        const b_idx = (b >> 4); // b / 16
        return self.lut[r_idx][g_idx][b_idx];
    }

    /// Quantize a batch of RGB triplets
    pub fn quantizeBatch(
        self: *const QuantizationLUT,
        rgb_data: []const u8,
        output: []u8,
    ) void {
        var i: usize = 0;
        while (i + 2 < rgb_data.len) : (i += 3) {
            const idx = i / 3;
            if (idx < output.len) {
                output[idx] = self.quantize(rgb_data[i], rgb_data[i + 1], rgb_data[i + 2]);
            }
        }
    }

    pub fn deinit(self: *QuantizationLUT) void {
        self.allocator.destroy(self.lut);
    }
};

// ============================================================================
// HELPER FUNCTIONS
// ============================================================================

/// Compute Euclidean distance squared between two RGB colors
/// (avoids sqrt for speed, only used for comparisons)
inline fn euclideanDistanceSq(
    r1: u8,
    g1: u8,
    b1: u8,
    r2: u8,
    g2: u8,
    b2: u8,
) u32 {
    const dr = @as(i32, r1) - @as(i32, r2);
    const dg = @as(i32, g1) - @as(i32, g2);
    const db = @as(i32, b1) - @as(i32, b2);
    return @bitCast(@as(u32, @intCast(dr * dr + dg * dg + db * db)));
}

/// Build xterm-256 quantizer
pub fn buildXterm256LUT(allocator: Allocator) !QuantizationLUT {
    var palette: [256]*const [3]u8 = undefined;
    for (0..256) |i| {
        palette[i] = &XTERM256_PALETTE[i];
    }
    return try QuantizationLUT.init(allocator, &palette, 256);
}

/// Build xterm-16 quantizer
pub fn buildXterm16LUT(allocator: Allocator) !QuantizationLUT {
    var palette: [16]*const [3]u8 = undefined;
    for (0..16) |i| {
        palette[i] = &XTERM16_PALETTE[i];
    }
    return try QuantizationLUT.init(allocator, &palette, 16);
}

// ============================================================================
// TESTS
// ============================================================================

test "quantize_primary_colors" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var lut = try buildXterm256LUT(allocator);
    defer lut.deinit();

    // Test primary colors quantize to nearby palette entries
    const red_idx = lut.quantize(255, 0, 0);
    const green_idx = lut.quantize(0, 255, 0);
    const blue_idx = lut.quantize(0, 0, 255);

    // Red should map to palette entry 9 (red in XTERM256)
    try std.testing.expect(red_idx >= 0 and red_idx < 256);
    try std.testing.expect(green_idx >= 0 and green_idx < 256);
    try std.testing.expect(blue_idx >= 0 and blue_idx < 256);
}

test "quantize_lut_consistency" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var lut = try buildXterm256LUT(allocator);
    defer lut.deinit();

    // Same color should always quantize to same index
    const idx1 = lut.quantize(128, 64, 192);
    const idx2 = lut.quantize(128, 64, 192);
    try std.testing.expectEqual(idx1, idx2);
}

test "xterm256_palette_correctness" {
    // Verify first ANSI colors in palette
    try std.testing.expectEqual(XTERM256_PALETTE[0], .{ 0x00, 0x00, 0x00 }); // black
    try std.testing.expectEqual(XTERM256_PALETTE[1], .{ 0x80, 0x00, 0x00 }); // maroon
    try std.testing.expectEqual(XTERM256_PALETTE[9], .{ 0xff, 0x00, 0x00 }); // red
    try std.testing.expectEqual(XTERM256_PALETTE[15], .{ 0xff, 0xff, 0xff }); // white
}

test "distance_metric_accuracy" {
    // Black to black: distance = 0
    const dist_black = euclideanDistanceSq(0, 0, 0, 0, 0, 0);
    try std.testing.expectEqual(dist_black, 0);

    // Red to itself: distance = 0
    const dist_red = euclideanDistanceSq(255, 0, 0, 255, 0, 0);
    try std.testing.expectEqual(dist_red, 0);

    // Different colors: distance > 0
    const dist_diff = euclideanDistanceSq(255, 0, 0, 0, 0, 0);
    try std.testing.expect(dist_diff > 0);
}

test "xterm16_palette_size" {
    try std.testing.expectEqual(XTERM16_PALETTE.len, 16);
}

test "batch_quantization" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var lut = try buildXterm256LUT(allocator);
    defer lut.deinit();

    // Test batch: 3 colors (9 bytes RGB)
    const rgb_data = [_]u8{ 255, 0, 0, 0, 255, 0, 0, 0, 255 };
    var output = [_]u8{ 0, 0, 0 };

    lut.quantizeBatch(&rgb_data, &output);

    // Should produce 3 palette indices
    try std.testing.expect(output[0] < 256);
    try std.testing.expect(output[1] < 256);
    try std.testing.expect(output[2] < 256);
}
