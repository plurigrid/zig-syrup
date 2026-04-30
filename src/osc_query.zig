//! OSC Terminal Color Query Protocol
//!
//! Sends OSC 10/11/4 queries to the terminal and parses the response.
//! The terminal responds with `rgb:RRRR/GGGG/BBBB` (16-bit per channel).
//! This is the observation channel for the learnable color loop:
//!   seed 1069 → HCL → RGB → ANSI → terminal → OSC query → observed RGB
//!
//! OSC 10;?  → query foreground color
//! OSC 11;?  → query background color
//! OSC 4;N;? → query palette color N

const std = @import("std");
const lux = @import("lux_color");
const RGB = lux.RGB;

pub const OscColor = struct {
    r: u16, // 0..65535
    g: u16,
    b: u16,

    pub fn toRgb8(self: OscColor) RGB {
        return .{
            .r = @intCast(self.r >> 8),
            .g = @intCast(self.g >> 8),
            .b = @intCast(self.b >> 8),
        };
    }

    pub fn fromRgb8(rgb: RGB) OscColor {
        return .{
            .r = @as(u16, rgb.r) << 8 | @as(u16, rgb.r),
            .g = @as(u16, rgb.g) << 8 | @as(u16, rgb.g),
            .b = @as(u16, rgb.b) << 8 | @as(u16, rgb.b),
        };
    }

    pub fn distance(self: OscColor, other: OscColor) f64 {
        const dr: f64 = @as(f64, @floatFromInt(@as(i32, self.r) - @as(i32, other.r))) / 65535.0;
        const dg: f64 = @as(f64, @floatFromInt(@as(i32, self.g) - @as(i32, other.g))) / 65535.0;
        const db: f64 = @as(f64, @floatFromInt(@as(i32, self.b) - @as(i32, other.b))) / 65535.0;
        return @sqrt(dr * dr + dg * dg + db * db);
    }
};

pub const QueryKind = enum(u2) {
    foreground,  // OSC 10
    background,  // OSC 11
    palette,     // OSC 4;N
};

// Format an OSC query escape sequence
pub fn formatQuery(buf: []u8, kind: QueryKind, palette_idx: ?u8) usize {
    var pos: usize = 0;
    buf[pos] = 0x1b; pos += 1; // ESC
    buf[pos] = ']';  pos += 1; // ]

    switch (kind) {
        .foreground => {
            buf[pos] = '1'; pos += 1;
            buf[pos] = '0'; pos += 1;
        },
        .background => {
            buf[pos] = '1'; pos += 1;
            buf[pos] = '1'; pos += 1;
        },
        .palette => {
            buf[pos] = '4'; pos += 1;
            buf[pos] = ';'; pos += 1;
            if (palette_idx) |idx| {
                if (idx >= 100) { buf[pos] = '0' + idx / 100; pos += 1; }
                if (idx >= 10) { buf[pos] = '0' + (idx / 10) % 10; pos += 1; }
                buf[pos] = '0' + idx % 10; pos += 1;
            }
        },
    }

    buf[pos] = ';'; pos += 1;
    buf[pos] = '?'; pos += 1;
    // ST (String Terminator)
    buf[pos] = 0x1b; pos += 1;
    buf[pos] = '\\';  pos += 1;
    return pos;
}

// Parse OSC response: `\x1b]N;rgb:RRRR/GGGG/BBBB\x1b\\` or `\x1b]N;rgb:RRRR/GGGG/BBBB\x07`
pub fn parseResponse(data: []const u8) ?OscColor {
    // Find "rgb:" prefix
    const rgb_prefix = "rgb:";
    const start = std.mem.indexOf(u8, data, rgb_prefix) orelse return null;
    const rest = data[start + rgb_prefix.len ..];

    // Parse RRRR/GGGG/BBBB
    const slash1 = std.mem.indexOfScalar(u8, rest, '/') orelse return null;
    const after_slash1 = rest[slash1 + 1 ..];
    const slash2 = std.mem.indexOfScalar(u8, after_slash1, '/') orelse return null;
    const after_slash2 = after_slash1[slash2 + 1 ..];

    // Find end (ESC or BEL)
    var end: usize = after_slash2.len;
    for (after_slash2, 0..) |c, i| {
        if (c == 0x1b or c == 0x07) { end = i; break; }
    }

    const r_str = rest[0..slash1];
    const g_str = after_slash1[0..slash2];
    const b_str = after_slash2[0..end];

    return .{
        .r = parseHex16(r_str) orelse return null,
        .g = parseHex16(g_str) orelse return null,
        .b = parseHex16(b_str) orelse return null,
    };
}

fn parseHex16(s: []const u8) ?u16 {
    if (s.len == 0 or s.len > 4) return null;
    var val: u16 = 0;
    for (s) |c| {
        val <<= 4;
        if (c >= '0' and c <= '9') {
            val |= @as(u16, c - '0');
        } else if (c >= 'a' and c <= 'f') {
            val |= @as(u16, c - 'a' + 10);
        } else if (c >= 'A' and c <= 'F') {
            val |= @as(u16, c - 'A' + 10);
        } else return null;
    }
    // Normalize: if only 2 hex digits, scale up (e.g., "ff" → 0xffff)
    if (s.len == 2) val = val << 8 | val;
    return val;
}

// OSC 1069 protocol extension
pub const Osc1069Action = enum(u3) {
    query,    // ?   — terminal reports seed 1069 color
    assert_eq, // =   — verify terminal matches expected
    gradient, // ∇   — request observed-expected delta
    policy,   // π   — send policy params for evaluation
};

pub fn formatOsc1069(buf: []u8, action: Osc1069Action, payload: []const u8) usize {
    var pos: usize = 0;
    buf[pos] = 0x1b; pos += 1;
    buf[pos] = ']';  pos += 1;
    // "1069"
    buf[pos] = '1'; pos += 1;
    buf[pos] = '0'; pos += 1;
    buf[pos] = '6'; pos += 1;
    buf[pos] = '9'; pos += 1;
    buf[pos] = ';'; pos += 1;

    const action_char: u8 = switch (action) {
        .query => '?',
        .assert_eq => '=',
        .gradient => 0xe2, // simplified; real impl uses UTF-8 ∇
        .policy => 0xcf,   // simplified; real impl uses UTF-8 π
    };
    buf[pos] = action_char; pos += 1;

    if (payload.len > 0) {
        buf[pos] = ';'; pos += 1;
        const copy_len = @min(payload.len, buf.len - pos - 2);
        @memcpy(buf[pos..][0..copy_len], payload[0..copy_len]);
        pos += copy_len;
    }

    buf[pos] = 0x1b; pos += 1;
    buf[pos] = '\\';  pos += 1;
    return pos;
}

// ============================================================================
// Tests
// ============================================================================

test "parse OSC foreground response" {
    const response = "\x1b]10;rgb:ffff/8080/0000\x1b\\";
    const color = parseResponse(response) orelse unreachable;
    try std.testing.expectEqual(@as(u16, 0xffff), color.r);
    try std.testing.expectEqual(@as(u16, 0x8080), color.g);
    try std.testing.expectEqual(@as(u16, 0x0000), color.b);
}

test "parse OSC short hex response" {
    const response = "\x1b]10;rgb:ff/80/00\x1b\\";
    const color = parseResponse(response) orelse unreachable;
    try std.testing.expectEqual(@as(u16, 0xffff), color.r);
    try std.testing.expectEqual(@as(u16, 0x8080), color.g);
    try std.testing.expectEqual(@as(u16, 0x0000), color.b);
}

test "parse OSC with BEL terminator" {
    const response = "\x1b]11;rgb:0000/ffff/8000\x07";
    const color = parseResponse(response) orelse unreachable;
    try std.testing.expectEqual(@as(u16, 0), color.r);
    try std.testing.expectEqual(@as(u16, 0xffff), color.g);
    try std.testing.expectEqual(@as(u16, 0x8000), color.b);
}

test "format query foreground" {
    var buf: [32]u8 = undefined;
    const len = formatQuery(&buf, .foreground, null);
    try std.testing.expectEqual(@as(usize, 8), len);
    try std.testing.expectEqual(@as(u8, 0x1b), buf[0]);
    try std.testing.expectEqual(@as(u8, ']'), buf[1]);
}

test "roundtrip OscColor to RGB8" {
    const osc = OscColor{ .r = 0xff00, .g = 0x8000, .b = 0x4000 };
    const rgb = osc.toRgb8();
    try std.testing.expectEqual(@as(u8, 0xff), rgb.r);
    try std.testing.expectEqual(@as(u8, 0x80), rgb.g);
    try std.testing.expectEqual(@as(u8, 0x40), rgb.b);
}

test "OscColor distance" {
    const a = OscColor{ .r = 0, .g = 0, .b = 0 };
    const b = OscColor{ .r = 0xffff, .g = 0xffff, .b = 0xffff };
    const d = a.distance(b);
    try std.testing.expect(d > 1.7 and d < 1.74); // sqrt(3) ≈ 1.732
}

test "format OSC 1069 query" {
    var buf: [64]u8 = undefined;
    const len = formatOsc1069(&buf, .query, "");
    try std.testing.expect(len > 0);
    try std.testing.expectEqual(@as(u8, 0x1b), buf[0]);
}
