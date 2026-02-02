const std = @import("std");
const syrup = @import("syrup");

// Inline RGB type for terminal output
const RGB = struct {
    r: u8,
    g: u8,
    b: u8,

    fn lerp(a: RGB, b: RGB, t: f32) RGB {
        const tc = @max(0.0, @min(1.0, t));
        return .{
            .r = @intFromFloat(@as(f32, @floatFromInt(a.r)) * (1.0 - tc) + @as(f32, @floatFromInt(b.r)) * tc),
            .g = @intFromFloat(@as(f32, @floatFromInt(a.g)) * (1.0 - tc) + @as(f32, @floatFromInt(b.g)) * tc),
            .b = @intFromFloat(@as(f32, @floatFromInt(a.b)) * (1.0 - tc) + @as(f32, @floatFromInt(b.b)) * tc),
        };
    }
};

const WIDTH = 80;
const HEIGHT = 24;
const GOLDEN_ANGLE: f32 = 137.508;
const PI: f32 = std.math.pi;

/// Fragment shader signature: (x, y, time) -> RGB
const ShaderFn = *const fn (f32, f32, f32) RGB;

fn renderGrid(shader: ShaderFn, t: f32, writer: anytype) !void {
    var y: usize = 0;
    while (y < HEIGHT) : (y += 1) {
        var x: usize = 0;
        while (x < WIDTH) : (x += 1) {
            const fx: f32 = @as(f32, @floatFromInt(x)) / @as(f32, @floatFromInt(WIDTH));
            const fy: f32 = @as(f32, @floatFromInt(y)) / @as(f32, @floatFromInt(HEIGHT));
            const color = shader(fx, fy, t);
            // ANSI 24-bit color with Unicode full block for terminal rendering
            try writer.print("\x1b[38;2;{d};{d};{d}m\u{2588}", .{ color.r, color.g, color.b });
        }
        try writer.writeAll("\x1b[0m\n");
    }
    try writer.writeAll("\x1b[0m");
}

// Shader 1: Golden Spiral
fn goldenSpiralShader(x: f32, y: f32, _: f32) RGB {
    const cx = x - 0.5;
    const cy = y - 0.5;
    const r = @sqrt(cx * cx + cy * cy);
    const angle = std.math.atan2(cy, cx);
    const hue_deg = @mod(angle * 180.0 / PI + r * GOLDEN_ANGLE * 10.0, 360.0);
    return hueToRGB(hue_deg, 0.8);
}

// Shader 2: Homotopy Paths - plot roots of x^2-1 as bright dots
fn homotopyPathShader(x: f32, y: f32, _: f32) RGB {
    // Map to complex plane [-2, 2] x [-2, 2]
    const re = (x - 0.5) * 4.0;
    const im = (y - 0.5) * 4.0;

    // Roots of x^2 - 1 are at +1 and -1
    const d1 = @sqrt((re - 1.0) * (re - 1.0) + im * im);
    const d2 = @sqrt((re + 1.0) * (re + 1.0) + im * im);
    const min_d = @min(d1, d2);

    if (min_d < 0.15) {
        return RGB{ .r = 255, .g = 255, .b = 100 }; // bright yellow for roots
    } else if (min_d < 0.4) {
        const fade: f32 = (0.4 - min_d) / 0.25;
        return RGB{
            .r = @intFromFloat(100.0 * fade),
            .g = @intFromFloat(150.0 * fade),
            .b = @intFromFloat(255.0 * fade),
        };
    }

    // Background: subtle grid
    const grid_x = @abs(@mod(re, 1.0) - 0.5);
    const grid_y = @abs(@mod(im, 1.0) - 0.5);
    if (grid_x < 0.02 or grid_y < 0.02) {
        return RGB{ .r = 40, .g = 40, .b = 60 };
    }
    return RGB{ .r = 15, .g = 15, .b = 25 };
}

// Shader 3: Damage Heat Map
fn damageHeatMapShader(x: f32, y: f32, _: f32) RGB {
    // Simulate dirty regions
    const cx1: f32 = 0.3;
    const cy1: f32 = 0.4;
    const cx2: f32 = 0.7;
    const cy2: f32 = 0.6;

    const d1 = @sqrt((x - cx1) * (x - cx1) + (y - cy1) * (y - cy1));
    const d2 = @sqrt((x - cx2) * (x - cx2) + (y - cy2) * (y - cy2));
    const heat = @max(0.0, 1.0 - @min(d1, d2) * 3.0);

    // Green (clean) -> Yellow -> Red (dirty)
    if (heat < 0.5) {
        return RGB.lerp(
            RGB{ .r = 20, .g = 100, .b = 20 },
            RGB{ .r = 200, .g = 200, .b = 20 },
            heat * 2.0,
        );
    } else {
        return RGB.lerp(
            RGB{ .r = 200, .g = 200, .b = 20 },
            RGB{ .r = 255, .g = 50, .b = 20 },
            (heat - 0.5) * 2.0,
        );
    }
}

// Shader 4: GF(3) Trit Field
fn tritFieldShader(x: f32, y: f32, _: f32) RGB {
    const ix: i32 = @intFromFloat(x * 12.0);
    const iy: i32 = @intFromFloat(y * 8.0);
    const trit: i32 = @mod(ix + iy * 3 + ix * iy, 3);
    return switch (trit) {
        0 => RGB{ .r = 80, .g = 80, .b = 80 }, // zero: gray
        1 => RGB{ .r = 50, .g = 200, .b = 80 }, // plus: green
        2 => RGB{ .r = 168, .g = 85, .b = 247 }, // minus: purple
        else => RGB{ .r = 0, .g = 0, .b = 0 },
    };
}

// Shader 5: CRT Phosphor effect
fn crtPhosphorShader(x: f32, y: f32, _: f32) RGB {
    // Base gradient
    const hue = x * 360.0;
    var color = hueToRGB(hue, 0.7 + y * 0.3);

    // Scanline effect: darken odd rows
    const row: usize = @intFromFloat(y * @as(f32, @floatFromInt(@as(u32, HEIGHT))) * 2.0);
    if (row % 2 == 1) {
        color.r /= 2;
        color.g /= 2;
        color.b /= 2;
    }

    // Bloom in center
    const cx = x - 0.5;
    const cy = y - 0.5;
    const dist = @sqrt(cx * cx + cy * cy);
    if (dist < 0.3) {
        const bloom = (0.3 - dist) / 0.3;
        const boost = 1.0 + bloom * 0.3;
        color.r = @intFromFloat(@min(255.0, @as(f32, @floatFromInt(color.r)) * boost));
        color.g = @intFromFloat(@min(255.0, @as(f32, @floatFromInt(color.g)) * boost));
        color.b = @intFromFloat(@min(255.0, @as(f32, @floatFromInt(color.b)) * boost));
    }

    return color;
}

fn hueToRGB(hue_deg: f32, brightness: f32) RGB {
    const h = @mod(hue_deg, 360.0) / 60.0;
    const sector: u8 = @intFromFloat(@floor(h));
    const f = h - @as(f32, @floatFromInt(sector));
    const b = brightness;

    const v: u8 = @intFromFloat(255.0 * b);
    const p: u8 = 0;
    const q: u8 = @intFromFloat(255.0 * b * (1.0 - f));
    const t_val: u8 = @intFromFloat(255.0 * b * f);

    return switch (sector % 6) {
        0 => RGB{ .r = v, .g = t_val, .b = p },
        1 => RGB{ .r = q, .g = v, .b = p },
        2 => RGB{ .r = p, .g = v, .b = t_val },
        3 => RGB{ .r = p, .g = q, .b = v },
        4 => RGB{ .r = t_val, .g = p, .b = v },
        5 => RGB{ .r = v, .g = p, .b = q },
        else => RGB{ .r = 0, .g = 0, .b = 0 },
    };
}

fn encodeSyrupFrame(shader_name: []const u8, allocator: std.mem.Allocator, writer: anytype) !void {
    // Create a Syrup record for the frame
    const label = try allocator.create(syrup.Value);
    label.* = syrup.Value{ .symbol = "shader-frame" };

    const fields = try allocator.alloc(syrup.Value, 3);
    fields[0] = syrup.Value{ .string = shader_name };
    fields[1] = syrup.Value{ .integer = WIDTH };
    fields[2] = syrup.Value{ .integer = HEIGHT };

    const record = syrup.Value{ .record = .{ .label = label, .fields = fields } };

    var encode_buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&encode_buf);
    try record.encode(fbs.writer());
    const encoded = fbs.getWritten();

    // Compute simple CID (hash of encoded bytes)
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(encoded, &hash, .{});

    try writer.print("  Syrup: {d} bytes, CID: ", .{encoded.len});
    for (hash[0..8]) |b_byte| {
        try writer.print("{x:0>2}", .{b_byte});
    }
    try writer.writeAll("...\n");

    allocator.destroy(label);
    allocator.free(fields);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const out_buf = try allocator.alloc(u8, 512 * 1024);
    defer allocator.free(out_buf);
    var fbs = std.io.fixedBufferStream(out_buf);
    const stdout = fbs.writer();

    const shaders = [_]struct { name: []const u8, func: ShaderFn }{
        .{ .name = "Golden Spiral", .func = goldenSpiralShader },
        .{ .name = "Homotopy Paths (x^2-1 roots)", .func = homotopyPathShader },
        .{ .name = "Damage Heat Map", .func = damageHeatMapShader },
        .{ .name = "GF(3) Trit Field", .func = tritFieldShader },
        .{ .name = "CRT Phosphor", .func = crtPhosphorShader },
    };

    try stdout.writeAll("\x1b[2J\x1b[H"); // Clear screen
    try stdout.writeAll("\xe2\x95\x94\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x97\n");
    try stdout.writeAll("\xe2\x95\x91                    TERMINAL SHADER VISUALIZATION                               \xe2\x95\x91\n");
    try stdout.writeAll("\xe2\x95\x91                    zig-syrup fragment shaders (ANSI 24-bit)                     \xe2\x95\x91\n");
    try stdout.writeAll("\xe2\x95\x9a\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x9d\n\n");

    for (shaders) |shader| {
        try writer_print_header(stdout, shader.name);

        try renderGrid(shader.func, 0.0, stdout);

        try stdout.writeAll("\xe2\x94\x94");
        var i: usize = 0;
        while (i < 80) : (i += 1) {
            try stdout.writeAll("\xe2\x94\x80");
        }
        try stdout.writeAll("\xe2\x94\x98\n");

        try encodeSyrupFrame(shader.name, allocator, stdout);
        try stdout.writeAll("\n");
    }

    _ = try std.posix.write(std.posix.STDOUT_FILENO, fbs.getWritten());
}

fn writer_print_header(writer: anytype, name: []const u8) !void {
    // Print: ┌─ <name> ───...───┐
    try writer.writeAll("\xe2\x94\x8c\xe2\x94\x80 ");
    try writer.writeAll(name);
    try writer.writeAll(" ");
    // Fill remaining width with ─
    // 80 - 4 (for "┌─ " and " ") - name.len, but account for the closing ┐
    const used = 4 + name.len;
    if (used < 80) {
        var pad: usize = 80 - used;
        while (pad > 0) : (pad -= 1) {
            try writer.writeAll("\xe2\x94\x80");
        }
    }
    try writer.writeAll("\xe2\x94\x90\n");
}
