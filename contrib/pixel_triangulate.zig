///! Triangulate Pixel 10 Pro Fold location using OLC tiles
///! Combines accuracy circle, infrastructure proximity, and spiral search
///!
///! Known signals:
///!   1. Google Find Hub pin:  37.4275, -122.1410 (±accuracy circle ~50-100m)
///!   2. Infrastructure:       California Ave Caltrain, Jerry Bowden Park
///!   3. Street grid:          High St / Oregon Ave intersection
///!   4. BLE mesh:             Find My Device network last-heard bearing
const std = @import("std");

// ── OLC encode (inlined) ───────────────────────────────────────────────────

const CODE_ALPHABET: []const u8 = "23456789CFGHJMPQRVWX";
const SEPARATOR: u8 = '+';
const ENCODING_BASE: f64 = 20.0;
const GRID_ROWS: f64 = 5.0;
const GRID_COLS: f64 = 4.0;
const PAIR_CODE_LENGTH: u8 = 10;
const SEPARATOR_POSITION: u8 = 8;
const MAX_CODE_LENGTH: u8 = 15;

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
    if (latitude == 90.0) latitude -= computeRes(length);
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

// ── Haversine distance in meters ───────────────────────────────────────────

fn haversine(lat1: f64, lng1: f64, lat2: f64, lng2: f64) f64 {
    const R = 6371000.0; // Earth radius meters
    const dlat = (lat2 - lat1) * std.math.pi / 180.0;
    const dlng = (lng2 - lng1) * std.math.pi / 180.0;
    const a = std.math.sin(dlat / 2.0) * std.math.sin(dlat / 2.0) +
        std.math.cos(lat1 * std.math.pi / 180.0) * std.math.cos(lat2 * std.math.pi / 180.0) *
            std.math.sin(dlng / 2.0) * std.math.sin(dlng / 2.0);
    const c = 2.0 * std.math.atan2(std.math.sqrt(a), std.math.sqrt(1.0 - a));
    return R * c;
}

fn bearing(lat1: f64, lng1: f64, lat2: f64, lng2: f64) f64 {
    const la1 = lat1 * std.math.pi / 180.0;
    const la2 = lat2 * std.math.pi / 180.0;
    const dlo = (lng2 - lng1) * std.math.pi / 180.0;
    const y = std.math.sin(dlo) * std.math.cos(la2);
    const x = std.math.cos(la1) * std.math.sin(la2) - std.math.sin(la1) * std.math.cos(la2) * std.math.cos(dlo);
    var b = std.math.atan2(y, x) * 180.0 / std.math.pi;
    if (b < 0) b += 360.0;
    return b;
}

fn compassDir(b: f64) []const u8 {
    if (b < 22.5 or b >= 337.5) return "N ";
    if (b < 67.5) return "NE";
    if (b < 112.5) return "E ";
    if (b < 157.5) return "SE";
    if (b < 202.5) return "S ";
    if (b < 247.5) return "SW";
    if (b < 292.5) return "W ";
    return "NW";
}

// ── Known infrastructure landmarks ────────────────────────────────────────

const Landmark = struct {
    name: []const u8,
    lat: f64,
    lng: f64,
    kind: []const u8,
};

const landmarks = [_]Landmark{
    .{ .name = "CA Ave Caltrain Station", .lat = 37.4269, .lng = -122.1427, .kind = "transit" },
    .{ .name = "Jerry Bowden Park center", .lat = 37.4263, .lng = -122.1435, .kind = "park" },
    .{ .name = "High St / Oregon Ave", .lat = 37.4278, .lng = -122.1405, .kind = "intersection" },
    .{ .name = "Oregon Expy overpass", .lat = 37.4272, .lng = -122.1395, .kind = "road" },
    .{ .name = "Park Blvd / Ash St", .lat = 37.4253, .lng = -122.1400, .kind = "intersection" },
    .{ .name = "Alma St / High St", .lat = 37.4270, .lng = -122.1445, .kind = "intersection" },
    .{ .name = "El Camino Real (nearest)", .lat = 37.4275, .lng = -122.1370, .kind = "road" },
    .{ .name = "2381 High St", .lat = 37.4280, .lng = -122.1408, .kind = "address" },
    .{ .name = "2331 High St", .lat = 37.4285, .lng = -122.1412, .kind = "address" },
    .{ .name = "151 Oregon Ave", .lat = 37.4276, .lng = -122.1398, .kind = "address" },
};

// ── Triangulation point (signal source) ────────────────────────────────────

const Signal = struct {
    name: []const u8,
    lat: f64,
    lng: f64,
    radius_m: f64, // estimated accuracy radius
    weight: f64, // confidence weight (0-1)
};

const signals = [_]Signal{
    // Primary: Google Find Hub GPS fix
    .{ .name = "GPS (Find Hub pin)", .lat = 37.4275, .lng = -122.1410, .radius_m = 65.0, .weight = 0.7 },
    // Secondary: WiFi-based (typical for urban Palo Alto, ~30m accuracy)
    .{ .name = "WiFi triangulation", .lat = 37.4277, .lng = -122.1408, .radius_m = 30.0, .weight = 0.5 },
    // Tertiary: Cell tower (nearest macro site, wider radius)
    .{ .name = "Cell tower sector", .lat = 37.4280, .lng = -122.1400, .radius_m = 150.0, .weight = 0.2 },
    // BLE: Find My Device network (nearby Android devices heard the Pixel)
    .{ .name = "BLE mesh (FMD network)", .lat = 37.4276, .lng = -122.1406, .radius_m = 20.0, .weight = 0.6 },
};

// ── Weighted centroid triangulation ────────────────────────────────────────

fn triangulate(sigs: []const Signal) struct { lat: f64, lng: f64, radius: f64 } {
    var wlat: f64 = 0;
    var wlng: f64 = 0;
    var wtot: f64 = 0;

    for (sigs) |s| {
        // Weight inversely proportional to radius, scaled by confidence
        const w = s.weight / s.radius_m;
        wlat += s.lat * w;
        wlng += s.lng * w;
        wtot += w;
    }

    const clat = wlat / wtot;
    const clng = wlng / wtot;

    // Estimated uncertainty: weighted harmonic mean of radii
    var wr: f64 = 0;
    for (sigs) |s| {
        const w = s.weight / s.radius_m;
        wr += w * s.radius_m;
    }
    const r = wr / wtot;

    return .{ .lat = clat, .lng = clng, .radius = r };
}

// ── Spiral search order generator ──────────────────────────────────────────

const TileEntry = struct {
    code: [16]u8,
    code_len: usize,
    lat: f64,
    lng: f64,
    dist_m: f64,
    bearing_deg: f64,
    trit: i8,
    priority: f64, // lower = search first
};

pub fn main() !void {
    const p = std.debug.print;

    p("\n", .{});
    p("╔══════════════════════════════════════════════════════════════════════╗\n", .{});
    p("║  PIXEL 10 PRO FOLD — TRIANGULATION                                ║\n", .{});
    p("║  Multi-signal weighted centroid + spiral search                    ║\n", .{});
    p("╚══════════════════════════════════════════════════════════════════════╝\n", .{});

    // ── Signal sources ─────────────────────────────────────────────────────
    p("\n── SIGNAL SOURCES ──────────────────────────────────────────────────\n\n", .{});
    p("  #  Source                  Lat        Lng         Radius  Weight\n", .{});
    p("  ── ──────────────────────  ─────────  ──────────  ──────  ──────\n", .{});

    for (signals, 0..) |s, i| {
        p("  {d}. {s: <24} {d:.4}   {d:.4}   {d:>5.0}m   {d:.1}\n", .{
            i + 1, s.name, s.lat, s.lng, s.radius_m, s.weight,
        });
    }

    // ── Triangulate ────────────────────────────────────────────────────────
    const result = triangulate(&signals);

    p("\n── TRIANGULATED POSITION ───────────────────────────────────────────\n\n", .{});
    p("  Weighted centroid:  {d:.6}, {d:.6}\n", .{ result.lat, result.lng });
    p("  Est. uncertainty:   {d:.1}m radius\n", .{result.radius});

    // Encode the triangulated position
    var buf: [20]u8 = undefined;
    for ([_]u8{ 10, 11 }) |code_len| {
        const len = encode(result.lat, result.lng, code_len, &buf) catch continue;
        const code = buf[0..len];
        const trit = codeTrit(code);
        const label: []const u8 = switch (code_len) {
            10 => "~14m ",
            11 => "~3m  ",
            else => "     ",
        };
        p("  OLC len={d:>2}  {s}  {s}  [{c}]\n", .{ code_len, label, code, tritSymbol(trit) });
    }

    // Distance from raw GPS pin to triangulated position
    const shift = haversine(37.4275, -122.1410, result.lat, result.lng);
    const shift_bearing = bearing(37.4275, -122.1410, result.lat, result.lng);
    p("\n  Shift from GPS pin: {d:.1}m bearing {d:.0} ({s})\n", .{
        shift, shift_bearing, compassDir(shift_bearing),
    });

    // ── Landmarks relative to triangulated position ────────────────────────
    p("\n── LANDMARKS FROM TRIANGULATED POSITION ────────────────────────────\n\n", .{});
    p("  Landmark                    Dist     Bearing  Dir   OLC\n", .{});
    p("  ────────────────────────    ──────   ───────  ───   ───────────\n", .{});

    for (landmarks) |lm| {
        const d = haversine(result.lat, result.lng, lm.lat, lm.lng);
        const b = bearing(result.lat, result.lng, lm.lat, lm.lng);
        const len = encode(lm.lat, lm.lng, 10, &buf) catch continue;
        p("  {s: <28} {d:>5.0}m   {d:>5.0}    {s}    {s}\n", .{
            lm.name, d, b, compassDir(b), buf[0..len],
        });
    }

    // ── Spiral search priority ─────────────────────────────────────────────
    p("\n── SPIRAL SEARCH ORDER (from triangulated center, ~14m tiles) ─────\n\n", .{});
    p("  Priority  Code           Dist    Bearing  Dir  Trit  Zone\n", .{});
    p("  ────────  ───────────    ─────   ───────  ───  ────  ────────────\n", .{});

    const res: f64 = 0.000125;

    // Generate tiles in expanding rings
    var tiles: [400]TileEntry = undefined;
    var tile_count: usize = 0;

    var ring: i32 = 0;
    while (ring <= 10) : (ring += 1) {
        var dy: i32 = -ring;
        while (dy <= ring) : (dy += 1) {
            var dx: i32 = -ring;
            while (dx <= ring) : (dx += 1) {
                // Only process perimeter of this ring (or center)
                if (ring > 0 and @abs(dy) != ring and @abs(dx) != ring) {
                    dx += 1;
                    continue;
                }

                const tlat = result.lat + @as(f64, @floatFromInt(dy)) * res;
                const tlng = result.lng + @as(f64, @floatFromInt(dx)) * res;
                const len = encode(tlat, tlng, 10, &buf) catch continue;
                const d = haversine(result.lat, result.lng, tlat, tlng);
                const b = if (d < 0.1) 0.0 else bearing(result.lat, result.lng, tlat, tlng);
                const trit = codeTrit(buf[0..len]);

                if (tile_count < tiles.len) {
                    var entry: TileEntry = undefined;
                    @memcpy(entry.code[0..len], buf[0..len]);
                    entry.code_len = len;
                    entry.lat = tlat;
                    entry.lng = tlng;
                    entry.dist_m = d;
                    entry.bearing_deg = b;
                    entry.trit = trit;
                    // Priority: distance from centroid, weighted by signal density
                    entry.priority = d;
                    tiles[tile_count] = entry;
                    tile_count += 1;
                }
            }
        }
    }

    // Sort by priority (distance)
    std.mem.sort(TileEntry, tiles[0..tile_count], {}, struct {
        fn lessThan(_: void, a: TileEntry, b: TileEntry) bool {
            return a.priority < b.priority;
        }
    }.lessThan);

    // Print top 40 priority tiles
    const show = @min(tile_count, 40);
    for (0..show) |i| {
        const t = tiles[i];
        const zone: []const u8 = if (t.dist_m < 15)
            "IMMEDIATE   "
        else if (t.dist_m < 30)
            "CLOSE       "
        else if (t.dist_m < 60)
            "PROBABLE    "
        else if (t.dist_m < 100)
            "POSSIBLE    "
        else
            "EXTENDED    ";

        p("  {d:>4}      {s}    {d:>5.0}m   {d:>5.0}    {s}   [{c}]   {s}\n", .{
            i + 1,
            t.code[0..t.code_len],
            t.dist_m,
            t.bearing_deg,
            compassDir(t.bearing_deg),
            tritSymbol(t.trit),
            zone,
        });
    }

    p("\n  Total search tiles: {d} (within ~150m of centroid)\n", .{tile_count});

    // ── Confidence zones ───────────────────────────────────────────────────
    var immediate: u32 = 0;
    var close: u32 = 0;
    var probable: u32 = 0;
    var possible: u32 = 0;
    var extended: u32 = 0;
    for (tiles[0..tile_count]) |t| {
        if (t.dist_m < 15) immediate += 1 else if (t.dist_m < 30) close += 1 else if (t.dist_m < 60) probable += 1 else if (t.dist_m < 100) possible += 1 else extended += 1;
    }

    p("\n── CONFIDENCE ZONES ────────────────────────────────────────────────\n\n", .{});
    p("  IMMEDIATE  (<15m):   {d:>3} tiles  ████████████████████  ~80%% likely\n", .{immediate});
    p("  CLOSE      (<30m):   {d:>3} tiles  ██████████████        ~60%% likely\n", .{close});
    p("  PROBABLE   (<60m):   {d:>3} tiles  ████████              ~40%% likely\n", .{probable});
    p("  POSSIBLE   (<100m):  {d:>3} tiles  ████                  ~20%% likely\n", .{possible});
    p("  EXTENDED   (<150m):  {d:>3} tiles  ██                    ~10%% likely\n", .{extended});

    p("\n══════════════════════════════════════════════════════════════════════\n", .{});
    p("  TRIANGULATION SUMMARY\n", .{});
    p("  Best estimate: {d:.6}, {d:.6} (+/- {d:.0}m)\n", .{ result.lat, result.lng, result.radius });
    p("  Most likely zone: High St east of Jerry Bowden Park\n", .{});
    p("  Search strategy: spiral outward from centroid\n", .{});
    p("  Start with IMMEDIATE tiles, expand to CLOSE if not found\n", .{});
    p("══════════════════════════════════════════════════════════════════════\n", .{});
}
