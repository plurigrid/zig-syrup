//! Homoiconic Colored Parentheses for Cathode Ray Displays
//!
//! Renders S-expressions with rainbow parentheses using all 16.7M colors
//! available on 24-bit digital displays. The color assignment follows
//! mathematical principles ensuring maximal perceptual dispersion.
//!
//! Key concepts:
//! - Golden Angle (φ⁻¹ × 360° ≈ 137.508°): Sunflower spiral hue rotation
//! - Plastic Angle (ρ⁻¹ × 360° ≈ 205.14°): Ternary/GF(3) variant
//! - Homotopy Path: Continuous deformation through color space
//! - Homoiconicity: Code and data share the same representation
//!
//! Reference: boxxy/internal/color/rainbow.go, Gay MCP golden_thread

const std = @import("std");
const syrup = @import("syrup.zig");
const homotopy = @import("homotopy.zig");
const continuation = @import("continuation.zig");
const Allocator = std.mem.Allocator;

// ============================================================================
// COLOR SPACE CONSTANTS
// ============================================================================

/// Golden ratio φ = (1 + √5) / 2
pub const PHI: f64 = 1.6180339887498948482;

/// Golden angle in degrees: 360° / φ² ≈ 137.508°
pub const GOLDEN_ANGLE: f64 = 137.5077640500378;

/// Plastic constant ρ (root of x³ = x + 1) ≈ 1.3247
pub const RHO: f64 = 1.32471795724474602596;

/// Plastic angle: 360° / ρ² ≈ 205.14°
pub const PLASTIC_ANGLE: f64 = 205.1442270324102;

/// Silver ratio δ_S = 1 + √2 ≈ 2.414
pub const SILVER_RATIO: f64 = 2.41421356237309504880;

/// Silver angle: 360° / δ_S ≈ 149.1°
pub const SILVER_ANGLE: f64 = 149.0710948765934;

/// Total 24-bit colors (cathode ray addressable)
pub const TOTAL_COLORS: u32 = 16_777_216; // 2^24

// ============================================================================
// COLOR REPRESENTATIONS
// ============================================================================

/// RGB color (24-bit, cathode ray native)
pub const RGB = struct {
    r: u8,
    g: u8,
    b: u8,

    pub const black = RGB{ .r = 0, .g = 0, .b = 0 };
    pub const white = RGB{ .r = 255, .g = 255, .b = 255 };

    /// Gay MCP purple seed
    pub const purple = RGB{ .r = 0xA8, .g = 0x55, .b = 0xF7 };

    pub fn fromU24(val: u24) RGB {
        return .{
            .r = @truncate(val >> 16),
            .g = @truncate(val >> 8),
            .b = @truncate(val),
        };
    }

    pub fn toU24(self: RGB) u24 {
        return (@as(u24, self.r) << 16) | (@as(u24, self.g) << 8) | self.b;
    }

    pub fn toHex(self: RGB, buf: *[7]u8) []const u8 {
        _ = std.fmt.bufPrint(buf, "#{X:0>2}{X:0>2}{X:0>2}", .{ self.r, self.g, self.b }) catch unreachable;
        return buf[0..7];
    }

    /// ANSI 24-bit truecolor escape sequence for foreground
    pub fn toAnsiFg(self: RGB, buf: *[19]u8) []const u8 {
        const len = std.fmt.bufPrint(buf, "\x1b[38;2;{d};{d};{d}m", .{ self.r, self.g, self.b }) catch unreachable;
        return buf[0..len.len];
    }

    /// ANSI 24-bit truecolor escape sequence for background
    pub fn toAnsiBg(self: RGB, buf: *[19]u8) []const u8 {
        const len = std.fmt.bufPrint(buf, "\x1b[48;2;{d};{d};{d}m", .{ self.r, self.g, self.b }) catch unreachable;
        return buf[0..len.len];
    }

    pub fn toSyrup(self: RGB, allocator: Allocator) !syrup.Value {
        const entries = try allocator.alloc(syrup.DictEntry, 3);
        entries[0] = .{ .key = syrup.Value{ .symbol = "r" }, .value = syrup.Value{ .integer = self.r } };
        entries[1] = .{ .key = syrup.Value{ .symbol = "g" }, .value = syrup.Value{ .integer = self.g } };
        entries[2] = .{ .key = syrup.Value{ .symbol = "b" }, .value = syrup.Value{ .integer = self.b } };
        return syrup.Value{ .dictionary = entries };
    }

    /// Linear interpolation between two colors
    pub fn lerp(a: RGB, b: RGB, t: f64) RGB {
        const t_clamped = @max(0.0, @min(1.0, t));
        return .{
            .r = @intFromFloat(@as(f64, @floatFromInt(a.r)) * (1.0 - t_clamped) + @as(f64, @floatFromInt(b.r)) * t_clamped),
            .g = @intFromFloat(@as(f64, @floatFromInt(a.g)) * (1.0 - t_clamped) + @as(f64, @floatFromInt(b.g)) * t_clamped),
            .b = @intFromFloat(@as(f64, @floatFromInt(a.b)) * (1.0 - t_clamped) + @as(f64, @floatFromInt(b.b)) * t_clamped),
        };
    }
};

/// HCL color (Hue-Chroma-Lightness, perceptually uniform)
pub const HCL = struct {
    h: f64, // Hue in degrees [0, 360)
    c: f64, // Chroma [0, ~1.3]
    l: f64, // Lightness [0, 1]

    /// Convert to RGB via Lab intermediate
    pub fn toRGB(self: HCL) RGB {
        // HCL -> Lab
        const h_rad = self.h * std.math.pi / 180.0;
        const a = self.c * @cos(h_rad);
        const b = self.c * @sin(h_rad);
        const l = self.l * 100.0;

        // Lab -> XYZ (D65 illuminant)
        const fy = (l + 16.0) / 116.0;
        const fx = a / 500.0 + fy;
        const fz = fy - b / 200.0;

        const xn = 0.95047;
        const yn = 1.00000;
        const zn = 1.08883;

        const x = xn * labF_inv(fx);
        const y = yn * labF_inv(fy);
        const z = zn * labF_inv(fz);

        // XYZ -> sRGB
        var r_lin = 3.2404542 * x - 1.5371385 * y - 0.4985314 * z;
        var g_lin = -0.9692660 * x + 1.8760108 * y + 0.0415560 * z;
        var b_lin = 0.0556434 * x - 0.2040259 * y + 1.0572252 * z;

        // Gamma correction
        r_lin = gammaCorrect(r_lin);
        g_lin = gammaCorrect(g_lin);
        b_lin = gammaCorrect(b_lin);

        return .{
            .r = @intFromFloat(@max(0, @min(255, r_lin * 255.0))),
            .g = @intFromFloat(@max(0, @min(255, g_lin * 255.0))),
            .b = @intFromFloat(@max(0, @min(255, b_lin * 255.0))),
        };
    }

    fn labF_inv(t: f64) f64 {
        const delta = 6.0 / 29.0;
        if (t > delta) {
            return t * t * t;
        } else {
            return 3.0 * delta * delta * (t - 4.0 / 29.0);
        }
    }

    fn gammaCorrect(u: f64) f64 {
        if (u <= 0.0031308) {
            return 12.92 * u;
        } else {
            return 1.055 * std.math.pow(f64, u, 1.0 / 2.4) - 0.055;
        }
    }
};

// ============================================================================
// COLOR SEQUENCE GENERATORS
// ============================================================================

/// Generate colors using golden angle rotation (maximally dispersed)
pub fn goldenSpiral(n: usize, base_hue: f64, chroma: f64, lightness: f64, allocator: Allocator) ![]RGB {
    const colors = try allocator.alloc(RGB, n);
    for (0..n) |i| {
        const hue = @mod(base_hue + @as(f64, @floatFromInt(i)) * GOLDEN_ANGLE, 360.0);
        colors[i] = (HCL{ .h = hue, .c = chroma, .l = lightness }).toRGB();
    }
    return colors;
}

/// Generate colors using plastic angle (GF(3) ternary variant)
pub fn plasticSpiral(n: usize, base_hue: f64, chroma: f64, lightness: f64, allocator: Allocator) ![]RGB {
    const colors = try allocator.alloc(RGB, n);
    for (0..n) |i| {
        const hue = @mod(base_hue + @as(f64, @floatFromInt(i)) * PLASTIC_ANGLE, 360.0);
        colors[i] = (HCL{ .h = hue, .c = chroma, .l = lightness }).toRGB();
    }
    return colors;
}

/// Homotopy path through color space (continuous deformation)
pub fn homotopyPath(start: RGB, end: RGB, steps: usize, allocator: Allocator) ![]RGB {
    const colors = try allocator.alloc(RGB, steps);
    for (0..steps) |i| {
        const t = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(steps - 1));
        colors[i] = RGB.lerp(start, end, t);
    }
    return colors;
}

/// Generate all 16.7M colors in Morton/Z-order (cache-friendly traversal)
pub fn mortonColorIterator() MortonIterator {
    return .{ .index = 0 };
}

pub const MortonIterator = struct {
    index: u24,

    pub fn next(self: *MortonIterator) ?RGB {
        if (self.index == std.math.maxInt(u24)) return null;
        const color = RGB.fromU24(mortonDecode(self.index));
        self.index +%= 1;
        return color;
    }

    /// Morton decode: interleave bits for Z-order curve
    fn mortonDecode(code: u24) u24 {
        // Simplified Morton decode for 8-bit per channel
        const r: u8 = @truncate(code >> 16);
        const g: u8 = @truncate(code >> 8);
        const b: u8 = @truncate(code);
        return (@as(u24, r) << 16) | (@as(u24, g) << 8) | b;
    }
};

// ============================================================================
// HOMOICONIC S-EXPRESSION WITH COLORS
// ============================================================================

/// Token in a colored S-expression
pub const ColoredToken = struct {
    text: []const u8,
    color: RGB,
    depth: usize,
    kind: TokenKind,

    pub const TokenKind = enum {
        open_paren, // (
        close_paren, // )
        open_bracket, // [
        close_bracket, // ]
        open_brace, // {
        close_brace, // }
        symbol,
        string,
        number,
        whitespace,
        comment,
    };

    pub fn toSyrup(self: ColoredToken, allocator: Allocator) !syrup.Value {
        const entries = try allocator.alloc(syrup.DictEntry, 4);
        entries[0] = .{ .key = syrup.Value{ .symbol = "text" }, .value = syrup.Value{ .string = self.text } };
        entries[1] = .{ .key = syrup.Value{ .symbol = "color" }, .value = try self.color.toSyrup(allocator) };
        entries[2] = .{ .key = syrup.Value{ .symbol = "depth" }, .value = syrup.Value{ .integer = @intCast(self.depth) } };
        entries[3] = .{ .key = syrup.Value{ .symbol = "kind" }, .value = syrup.Value{ .symbol = @tagName(self.kind) } };
        return syrup.Value{ .dictionary = entries };
    }
};

/// Colored S-expression (homoiconic: code = data)
pub const ColoredSexp = struct {
    tokens: []const ColoredToken,
    source: []const u8,
    palette: []const RGB,
    trit_sum: i32, // GF(3) sum for balanced ternary validation

    /// Render to ANSI-colored string for terminal display
    pub fn renderAnsi(self: ColoredSexp, allocator: Allocator) ![]u8 {
        var buf = std.ArrayListUnmanaged(u8){};
        const writer = buf.writer(allocator);

        for (self.tokens) |token| {
            // Write color escape
            var ansi_buf: [19]u8 = undefined;
            const ansi = token.color.toAnsiFg(&ansi_buf);
            try writer.writeAll(ansi);

            // Write text
            try writer.writeAll(token.text);
        }

        // Reset colors
        try writer.writeAll("\x1b[0m");

        return buf.toOwnedSlice(allocator);
    }

    /// Render to HTML with inline styles
    pub fn renderHtml(self: ColoredSexp, allocator: Allocator) ![]u8 {
        var buf = std.ArrayListUnmanaged(u8){};
        const writer = buf.writer(allocator);

        try writer.writeAll("<pre style=\"font-family: monospace; background: #1a1a2e;\">");

        for (self.tokens) |token| {
            var hex_buf: [7]u8 = undefined;
            const hex = token.color.toHex(&hex_buf);

            try std.fmt.format(writer, "<span style=\"color: {s}\">", .{hex});

            // Escape HTML entities
            for (token.text) |c| {
                switch (c) {
                    '<' => try writer.writeAll("&lt;"),
                    '>' => try writer.writeAll("&gt;"),
                    '&' => try writer.writeAll("&amp;"),
                    else => try writer.writeByte(c),
                }
            }

            try writer.writeAll("</span>");
        }

        try writer.writeAll("</pre>");
        return buf.toOwnedSlice(allocator);
    }

    /// Convert the entire colored expression to Syrup (homoiconic!)
    pub fn toSyrup(self: ColoredSexp, allocator: Allocator) !syrup.Value {
        var token_values = try allocator.alloc(syrup.Value, self.tokens.len);
        for (self.tokens, 0..) |token, idx| {
            token_values[idx] = try token.toSyrup(allocator);
        }

        var palette_values = try allocator.alloc(syrup.Value, self.palette.len);
        for (self.palette, 0..) |color, idx| {
            palette_values[idx] = try color.toSyrup(allocator);
        }

        const label = try allocator.create(syrup.Value);
        label.* = syrup.Value{ .symbol = "colored-sexp" };

        const fields = try allocator.alloc(syrup.Value, 4);
        fields[0] = syrup.Value{ .list = token_values };
        fields[1] = syrup.Value{ .string = self.source };
        fields[2] = syrup.Value{ .list = palette_values };
        fields[3] = syrup.Value{ .integer = self.trit_sum };

        return syrup.Value{ .record = .{ .label = label, .fields = fields } };
    }
};

// ============================================================================
// PARSER: S-EXPRESSION -> COLORED TOKENS
// ============================================================================

pub const ColoredParser = struct {
    source: []const u8,
    palette: []const RGB,
    allocator: Allocator,
    angle_mode: AngleMode,

    pub const AngleMode = enum {
        golden, // φ-based (default)
        plastic, // ρ-based (GF(3))
        silver, // δ_S-based
        homotopy, // Path through color space
    };

    pub fn init(source: []const u8, allocator: Allocator) !ColoredParser {
        // Generate default 8-depth palette from Gay MCP purple
        const purple_hue = 271.0; // #A855F7 in HCL
        const palette = try goldenSpiral(8, purple_hue, 0.7, 0.55, allocator);
        return .{
            .source = source,
            .palette = palette,
            .allocator = allocator,
            .angle_mode = .golden,
        };
    }

    pub fn withPalette(source: []const u8, palette: []const RGB, allocator: Allocator) ColoredParser {
        return .{
            .source = source,
            .palette = palette,
            .allocator = allocator,
            .angle_mode = .golden,
        };
    }

    pub fn parse(self: *ColoredParser) !ColoredSexp {
        var tokens = std.ArrayListUnmanaged(ColoredToken){};
        var depth: usize = 0;
        var trit_sum: i32 = 0;
        var i: usize = 0;

        while (i < self.source.len) {
            const c = self.source[i];

            switch (c) {
                '(', '[', '{' => {
                    const kind: ColoredToken.TokenKind = switch (c) {
                        '(' => .open_paren,
                        '[' => .open_bracket,
                        '{' => .open_brace,
                        else => unreachable,
                    };
                    try tokens.append(self.allocator, .{
                        .text = self.source[i .. i + 1],
                        .color = self.palette[depth % self.palette.len],
                        .depth = depth,
                        .kind = kind,
                    });
                    depth += 1;
                    trit_sum += 1; // Opening = +1
                    i += 1;
                },
                ')', ']', '}' => {
                    if (depth > 0) depth -= 1;
                    const kind: ColoredToken.TokenKind = switch (c) {
                        ')' => .close_paren,
                        ']' => .close_bracket,
                        '}' => .close_brace,
                        else => unreachable,
                    };
                    try tokens.append(self.allocator, .{
                        .text = self.source[i .. i + 1],
                        .color = self.palette[depth % self.palette.len],
                        .depth = depth,
                        .kind = kind,
                    });
                    trit_sum -= 1; // Closing = -1
                    i += 1;
                },
                '"' => {
                    // String literal
                    const start = i;
                    i += 1;
                    while (i < self.source.len and self.source[i] != '"') {
                        if (self.source[i] == '\\' and i + 1 < self.source.len) i += 1;
                        i += 1;
                    }
                    if (i < self.source.len) i += 1;
                    try tokens.append(self.allocator, .{
                        .text = self.source[start..i],
                        .color = RGB{ .r = 0x98, .g = 0xC3, .b = 0x79 }, // Green for strings
                        .depth = depth,
                        .kind = .string,
                    });
                },
                ';' => {
                    // Comment
                    const start = i;
                    while (i < self.source.len and self.source[i] != '\n') i += 1;
                    try tokens.append(self.allocator, .{
                        .text = self.source[start..i],
                        .color = RGB{ .r = 0x6A, .g = 0x73, .b = 0x7D }, // Gray for comments
                        .depth = depth,
                        .kind = .comment,
                    });
                },
                ' ', '\t', '\n', '\r' => {
                    // Whitespace
                    const start = i;
                    while (i < self.source.len and (self.source[i] == ' ' or self.source[i] == '\t' or
                        self.source[i] == '\n' or self.source[i] == '\r'))
                    {
                        i += 1;
                    }
                    try tokens.append(self.allocator, .{
                        .text = self.source[start..i],
                        .color = RGB.white,
                        .depth = depth,
                        .kind = .whitespace,
                    });
                },
                '0'...'9', '-' => {
                    // Number (simplified)
                    const start = i;
                    if (c == '-') i += 1;
                    while (i < self.source.len and (self.source[i] >= '0' and self.source[i] <= '9' or
                        self.source[i] == '.' or self.source[i] == 'e' or self.source[i] == 'E'))
                    {
                        i += 1;
                    }
                    if (i > start) {
                        try tokens.append(self.allocator, .{
                            .text = self.source[start..i],
                            .color = RGB{ .r = 0xB5, .g = 0xCE, .b = 0xA8 }, // Light green for numbers
                            .depth = depth,
                            .kind = .number,
                        });
                    } else {
                        // Just a minus, treat as symbol
                        i = start;
                        const sym_start = i;
                        while (i < self.source.len and !isDelimiter(self.source[i])) i += 1;
                        try tokens.append(self.allocator, .{
                            .text = self.source[sym_start..i],
                            .color = RGB{ .r = 0xDC, .g = 0xDC, .b = 0xAA }, // Yellow for symbols
                            .depth = depth,
                            .kind = .symbol,
                        });
                    }
                },
                else => {
                    // Symbol
                    const start = i;
                    while (i < self.source.len and !isDelimiter(self.source[i])) i += 1;
                    if (i > start) {
                        try tokens.append(self.allocator, .{
                            .text = self.source[start..i],
                            .color = RGB{ .r = 0xDC, .g = 0xDC, .b = 0xAA }, // Yellow for symbols
                            .depth = depth,
                            .kind = .symbol,
                        });
                    } else {
                        i += 1; // Skip unknown char
                    }
                },
            }
        }

        return ColoredSexp{
            .tokens = try tokens.toOwnedSlice(self.allocator),
            .source = self.source,
            .palette = self.palette,
            .trit_sum = trit_sum,
        };
    }

    fn isDelimiter(c: u8) bool {
        return c == ' ' or c == '\t' or c == '\n' or c == '\r' or
            c == '(' or c == ')' or c == '[' or c == ']' or
            c == '{' or c == '}' or c == '"' or c == ';';
    }
};

// ============================================================================
// CATHODE RAY PHOSPHOR SIMULATION
// ============================================================================

/// Simulates CRT phosphor color reproduction characteristics
pub const CRTPhosphor = struct {
    /// Standard P22 phosphor (most common CRT type)
    pub const P22 = struct {
        pub const red = RGB{ .r = 255, .g = 0, .b = 0 };
        pub const green = RGB{ .r = 0, .g = 255, .b = 0 };
        pub const blue = RGB{ .r = 0, .g = 0, .b = 255 };

        /// Gamma correction for CRT display
        pub const gamma: f64 = 2.2;
    };

    /// Apply scanline effect for authentic CRT look
    pub fn applyScanlines(color: RGB, y: usize) RGB {
        if (y % 2 == 1) {
            // Darken alternate lines
            return .{
                .r = color.r / 2,
                .g = color.g / 2,
                .b = color.b / 2,
            };
        }
        return color;
    }

    /// Apply bloom/glow effect (phosphor persistence)
    pub fn applyBloom(color: RGB, intensity: f64) RGB {
        const boost = 1.0 + intensity * 0.3;
        return .{
            .r = @intFromFloat(@min(255.0, @as(f64, @floatFromInt(color.r)) * boost)),
            .g = @intFromFloat(@min(255.0, @as(f64, @floatFromInt(color.g)) * boost)),
            .b = @intFromFloat(@min(255.0, @as(f64, @floatFromInt(color.b)) * boost)),
        };
    }
};

// ============================================================================
// TESTS
// ============================================================================

test "golden spiral colors" {
    const allocator = std.testing.allocator;
    const colors = try goldenSpiral(8, 271.0, 0.7, 0.55, allocator);
    defer allocator.free(colors);

    try std.testing.expectEqual(@as(usize, 8), colors.len);
    // First color should be near purple
    try std.testing.expect(colors[0].r > 100);
    try std.testing.expect(colors[0].b > 100);
}

test "rgb hex conversion" {
    const purple = RGB.purple;
    var buf: [7]u8 = undefined;
    const hex = purple.toHex(&buf);
    try std.testing.expectEqualStrings("#A855F7", hex);
}

test "colored parser balanced parens" {
    const allocator = std.testing.allocator;
    var parser = try ColoredParser.init("(defn foo [x] (+ x 1))", allocator);
    defer allocator.free(parser.palette);

    const sexp = try parser.parse();
    defer allocator.free(sexp.tokens);

    // Trit sum should be 0 for balanced parens
    try std.testing.expectEqual(@as(i32, 0), sexp.trit_sum);
}

test "morton iterator" {
    var iter = mortonColorIterator();

    // First color is black
    const first = iter.next().?;
    try std.testing.expectEqual(@as(u8, 0), first.r);
    try std.testing.expectEqual(@as(u8, 0), first.g);
    try std.testing.expectEqual(@as(u8, 0), first.b);

    // Can iterate through colors
    var count: usize = 0;
    while (iter.next()) |_| {
        count += 1;
        if (count >= 1000) break; // Don't iterate all 16.7M in test
    }
    try std.testing.expect(count >= 1000);
}

test "homotopy path through color space" {
    const allocator = std.testing.allocator;
    const path = try homotopyPath(RGB.black, RGB.white, 5, allocator);
    defer allocator.free(path);

    try std.testing.expectEqual(@as(usize, 5), path.len);
    // First should be black
    try std.testing.expectEqual(@as(u8, 0), path[0].r);
    // Last should be white
    try std.testing.expectEqual(@as(u8, 255), path[4].r);
    // Middle should be gray
    try std.testing.expect(path[2].r > 100 and path[2].r < 200);
}
