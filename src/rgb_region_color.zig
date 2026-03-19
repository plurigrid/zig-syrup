const std = @import("std");

pub const RegionPos = struct {
    x: i32,
    y: i32,

    pub fn init(x: i32, y: i32) RegionPos {
        return .{ .x = x, .y = y };
    }
};

pub const RegionColor = enum(u4) {
    c0 = 0,
    c1 = 1,
    c2 = 2,
    c3 = 3,
    c4 = 4,
    c5 = 5,
    c6 = 6,
    c7 = 7,
    c8 = 8,

    pub const all = [9]RegionColor{ .c0, .c1, .c2, .c3, .c4, .c5, .c6, .c7, .c8 };

    pub fn fromRegion(pos: RegionPos) RegionColor {
        const x: usize = @intCast(@mod(pos.x, 3));
        const y: usize = @intCast(@mod(pos.y, 3));
        return all[y * 3 + x];
    }

    pub fn symbol(self: RegionColor) u8 {
        return switch (self) {
            .c0 => '0',
            .c1 => '1',
            .c2 => '2',
            .c3 => '3',
            .c4 => '4',
            .c5 => '5',
            .c6 => '6',
            .c7 => '7',
            .c8 => '8',
        };
    }
};

pub fn colorAt(x: i32, y: i32) RegionColor {
    return RegionColor.fromRegion(.{ .x = x, .y = y });
}

test "rgb 3x3 region coloring has no adjacent conflicts" {
    var y: i32 = -10;
    while (y < 10) : (y += 1) {
        var x: i32 = -10;
        while (x < 10) : (x += 1) {
            const pos = RegionPos.init(x, y);
            const color = RegionColor.fromRegion(pos);

            var dy: i32 = -1;
            while (dy <= 1) : (dy += 1) {
                var dx: i32 = -1;
                while (dx <= 1) : (dx += 1) {
                    if (dx == 0 and dy == 0) continue;
                    const neighbor = RegionPos.init(x + dx, y + dy);
                    try std.testing.expect(color != RegionColor.fromRegion(neighbor));
                }
            }
        }
    }
}

test "rgb 3x3 pattern repeats every three steps" {
    const origin = colorAt(0, 0);
    try std.testing.expectEqual(origin, colorAt(3, 0));
    try std.testing.expectEqual(origin, colorAt(0, 3));
    try std.testing.expectEqual(colorAt(1, 2), colorAt(4, 5));
}

test "rgb region color visualization matches reference layout" {
    var rows: [6][9]u8 = undefined;
    for (0..6) |y| {
        for (0..9) |x| {
            rows[y][x] = colorAt(@intCast(x), @intCast(y)).symbol();
        }
    }

    try std.testing.expectEqualStrings("012012012", &rows[0]);
    try std.testing.expectEqualStrings("345345345", &rows[1]);
    try std.testing.expectEqualStrings("678678678", &rows[2]);
    try std.testing.expectEqualStrings("012012012", &rows[3]);
    try std.testing.expectEqualStrings("345345345", &rows[4]);
    try std.testing.expectEqualStrings("678678678", &rows[5]);
}
