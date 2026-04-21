///! Tile the Pixel 10 Pro Fold search area around Jerry Bowden Park, Palo Alto
///! with Open Location Code (Plus Code) cells at ~14m resolution (length 10)
///! and ~3m resolution (length 11).
///!
///! Search area bounding box (from Google Find Hub screenshot):
///!   Jerry Bowden Park → High St & Oregon Ave intersection
///!   Lat:  ~37.4240 to ~37.4295
///!   Lng: ~-122.1460 to ~-122.1380
const std = @import("std");

// ── OLC constants ──────────────────────────────────────────────────────────

const CODE_ALPHABET: []const u8 = "23456789CFGHJMPQRVWX";
const SEPARATOR: u8 = '+';
const ENCODING_BASE: f64 = 20.0;
const GRID_ROWS: f64 = 5.0;
const GRID_COLS: f64 = 4.0;
const PAIR_CODE_LENGTH: u8 = 10;
const SEPARATOR_POSITION: u8 = 8;
const MAX_CODE_LENGTH: u8 = 15;

// ── Inline OLC encode (self-contained) ─────────────────────────────────────

fn encode(lat: f64, lng: f64, code_length: u8, buffer: []u8) !usize {
    var length = code_length;
    if (length < 2) length = 10;
    if (length > MAX_CODE_LENGTH) length = MAX_CODE_LENGTH;
    if (length < SEPARATOR_POSITION and length % 2 == 1) length += 1;

    const required: usize = @as(usize, length) + 1;
    if (buffer.len < required) return error.BufferTooSmall;

    var latitude = @min(90.0, @max(-90.0, lat));
    var longitude = lng;
    while (longitude < -180.0) longitude += 360.0;
    while (longitude >= 180.0) longitude -= 360.0;

    if (latitude == 90.0) {
        latitude -= computeRes(length);
    }

    latitude += 90.0;
    longitude += 180.0;

    var idx: usize = 0;
    var digit: u8 = 0;

    var lat_val = latitude;
    var lng_val = longitude;

    while (digit < length and digit < PAIR_CODE_LENGTH) {
        const res = pairRes(digit);
        var lat_digit = @as(usize, @intFromFloat(@floor(lat_val / res)));
        if (lat_digit >= CODE_ALPHABET.len) lat_digit = CODE_ALPHABET.len - 1;
        lat_val = @mod(lat_val, res);
        buffer[idx] = CODE_ALPHABET[lat_digit];
        idx += 1;
        digit += 1;

        if (digit == SEPARATOR_POSITION) {
            buffer[idx] = SEPARATOR;
            idx += 1;
        }
        if (digit >= length) break;

        var lng_digit = @as(usize, @intFromFloat(@floor(lng_val / res)));
        if (lng_digit >= CODE_ALPHABET.len) lng_digit = CODE_ALPHABET.len - 1;
        lng_val = @mod(lng_val, res);
        buffer[idx] = CODE_ALPHABET[lng_digit];
        idx += 1;
        digit += 1;

        if (digit == SEPARATOR_POSITION) {
            buffer[idx] = SEPARATOR;
            idx += 1;
        }
    }

    while (digit < SEPARATOR_POSITION) {
        buffer[idx] = '0';
        idx += 1;
        digit += 1;
        if (digit == SEPARATOR_POSITION) {
            buffer[idx] = SEPARATOR;
            idx += 1;
        }
    }

    if (length > PAIR_CODE_LENGTH) {
        const lat_res_base = pairRes(PAIR_CODE_LENGTH - 2);
        const lng_res_base = lat_res_base;
        var grid_lat = lat_val;
        var grid_lng = lng_val;
        var step: u8 = 0;

        while (digit < length) {
            const lat_step = lat_res_base / std.math.pow(f64, GRID_ROWS, @as(f64, @floatFromInt(step + 1)));
            const lng_step = lng_res_base / std.math.pow(f64, GRID_COLS, @as(f64, @floatFromInt(step + 1)));

            var row = @as(usize, @intFromFloat(@floor(grid_lat / lat_step)));
            var col = @as(usize, @intFromFloat(@floor(grid_lng / lng_step)));
            if (row >= 5) row = 4;
            if (col >= 4) col = 3;

            buffer[idx] = CODE_ALPHABET[row * 4 + col];
            idx += 1;
            digit += 1;
            step += 1;

            grid_lat = @mod(grid_lat, lat_step);
            grid_lng = @mod(grid_lng, lng_step);
        }
    }

    return idx;
}

fn pairRes(digit: u8) f64 {
    const pair = digit / 2;
    return ENCODING_BASE / std.math.pow(f64, ENCODING_BASE, @as(f64, @floatFromInt(pair)));
}

fn computeRes(len: u8) f64 {
    if (len <= PAIR_CODE_LENGTH) {
        const pairs: i32 = @as(i32, len / 2);
        return std.math.pow(f64, ENCODING_BASE, @as(f64, @floatFromInt(2 - pairs)));
    }
    const grid_steps = len - PAIR_CODE_LENGTH;
    return std.math.pow(f64, ENCODING_BASE, -3.0) / std.math.pow(f64, GRID_ROWS, @as(f64, @floatFromInt(grid_steps)));
}

fn charVal(c: u8) u8 {
    for (CODE_ALPHABET, 0..) |a, i| {
        if (c == a) return @intCast(i);
    }
    return 0;
}

// ── GF(3) trit computation ─────────────────────────────────────────────────

fn codeTrit(code: []const u8) i8 {
    var sum: u32 = 0;
    for (code) |c| {
        if (c == '+' or c == '0') continue;
        sum += charVal(c);
    }
    return @intCast(@as(i32, @intCast(@mod(sum, 3))) - 1);
}

fn tritSymbol(t: i8) u8 {
    return switch (t) {
        -1 => '-',
        0 => '0',
        1 => '+',
        else => '?',
    };
}

fn tritName(t: i8) []const u8 {
    return switch (t) {
        -1 => "MINUS",
        0 => "ERGODIC",
        1 => "PLUS",
        else => "???",
    };
}

// ── Main: tile the search area ─────────────────────────────────────────────

pub fn main() !void {
    const p = std.debug.print;

    // Search area bounding box — Jerry Bowden Park, Palo Alto
    const center_lat: f64 = 37.4275;
    const center_lng: f64 = -122.1410;

    const south: f64 = 37.4240;
    const north: f64 = 37.4310;
    const west: f64 = -122.1470;
    const east: f64 = -122.1350;

    p("\n", .{});
    p("╔══════════════════════════════════════════════════════════════════════╗\n", .{});
    p("║  PIXEL 10 PRO FOLD — OLC TILE SEARCH GRID                         ║\n", .{});
    p("║  Jerry Bowden Park, Palo Alto, CA                                  ║\n", .{});
    p("║  Center: {d:.4}, {d:.4}                                    ║\n", .{ center_lat, center_lng });
    p("╠══════════════════════════════════════════════════════════════════════╣\n", .{});
    p("║  S {d:.4}  N {d:.4}  W {d:.4}  E {d:.4}           ║\n", .{ south, north, west, east });
    p("║  ~770m x ~1050m search area                                       ║\n", .{});
    p("╚══════════════════════════════════════════════════════════════════════╝\n", .{});

    const res10_lat: f64 = 0.000125;
    const res10_lng: f64 = 0.000125;

    p("\n── LENGTH-10 TILES (~14m x 14m) — sampled ─────────────────────────\n\n", .{});
    p("  CODE             CENTER LAT    CENTER LNG    TRIT   GF(3)\n", .{});
    p("  ───────────────  ──────────    ──────────    ────   ─────\n", .{});

    var buf: [20]u8 = undefined;
    var count10: u32 = 0;
    var trit_counts = [3]u32{ 0, 0, 0 };

    var lat = south;
    while (lat < north) : (lat += res10_lat) {
        var lng = west;
        while (lng < east) : (lng += res10_lng) {
            const len = encode(lat, lng, 10, &buf) catch continue;
            const code = buf[0..len];
            const trit = codeTrit(code);

            if (count10 % 40 == 0) {
                p("  {s}   {d: >10.6}    {d: >11.6}    [{c}]    {s}\n", .{
                    code,
                    lat + res10_lat / 2.0,
                    lng + res10_lng / 2.0,
                    tritSymbol(trit),
                    tritName(trit),
                });
            }

            trit_counts[@intCast(@as(i32, trit) + 1)] += 1;
            count10 += 1;
        }
    }

    p("\n  Total length-10 tiles: {d}\n", .{count10});
    p("  GF(3) distribution: MINUS(-1)={d}  ERGODIC(0)={d}  PLUS(+1)={d}\n", .{ trit_counts[0], trit_counts[1], trit_counts[2] });

    const res8_lat: f64 = 0.0025;
    const res8_lng: f64 = 0.0025;

    p("\n── LENGTH-8 TILES (~275m x 275m) — COARSE GRID ──────────────────────\n\n", .{});
    p("  CODE          CENTER LAT    CENTER LNG    TRIT   GF(3)\n", .{});
    p("  ────────────  ──────────    ──────────    ────   ─────\n", .{});

    lat = south;
    while (lat < north) : (lat += res8_lat) {
        var lng = west;
        while (lng < east) : (lng += res8_lng) {
            const len = encode(lat, lng, 8, &buf) catch continue;
            const code = buf[0..len];
            const trit = codeTrit(code);

            p("  {s}      {d: >10.6}    {d: >11.6}    [{c}]    {s}\n", .{
                code,
                lat + res8_lat / 2.0,
                lng + res8_lng / 2.0,
                tritSymbol(trit),
                tritName(trit),
            });
        }
    }

    p("\n── PIN LOCATION (device last seen) ───────────────────────────────────\n\n", .{});

    for ([_]u8{ 8, 10, 11 }) |code_len| {
        const len = encode(center_lat, center_lng, code_len, &buf) catch continue;
        const code = buf[0..len];
        const trit = codeTrit(code);
        const label: []const u8 = switch (code_len) {
            8 => "~275m ",
            10 => "~14m  ",
            11 => "~3m   ",
            else => "      ",
        };
        p("  len={d:>2}  {s}  {s}  [{c}] {s}\n", .{
            code_len, label, code, tritSymbol(trit), tritName(trit),
        });
    }

    p("\n── 3x3 NEIGHBORHOOD AROUND PIN (length 10) ──────────────────────────\n\n", .{});

    const offsets = [_]f64{ -1.0, 0.0, 1.0 };
    for (offsets) |dlat| {
        for (offsets) |dlng| {
            const nlat = center_lat + dlat * res10_lat;
            const nlng = center_lng + dlng * res10_lng;
            const len = encode(nlat, nlng, 10, &buf) catch continue;
            const code = buf[0..len];
            const trit = codeTrit(code);
            const marker: []const u8 = if (dlat == 0 and dlng == 0) " << PIN" else "      ";
            p("  {s}  ({d: >10.6}, {d: >11.6})  [{c}]{s}\n", .{
                code, nlat, nlng, tritSymbol(trit), marker,
            });
        }
    }

    p("\n══════════════════════════════════════════════════════════════════════\n", .{});
    p("  Recovery guidance:\n", .{});
    p("    * Search tiles near the PIN first (3x3 neighborhood)\n", .{});
    p("    * Check ERGODIC(0) tiles -- phase boundaries between +1 and -1\n", .{});
    p("    * The device was last seen at the High St / Oregon Ave area\n", .{});
    p("    * Nearby: Jerry Bowden Park, California Ave Caltrain Station\n", .{});
    p("══════════════════════════════════════════════════════════════════════\n", .{});
}
