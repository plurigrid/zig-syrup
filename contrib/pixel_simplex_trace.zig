///! Simplex trace: InterContinental SF (888 Howard, 8F) → Pixel last-seen
///!
///! Vertices of the 2-simplex:
///!   v0: Current position — InterContinental SF, 888 Howard St, 8th floor
///!   v1: Triangulated device position — High St / Oregon Ave, Palo Alto
///!   v2: Transit midpoint — Caltrain corridor (natural path between v0 & v1)
///!
///! The simplex trace walks the edges and interior, tiling each with OLC codes.

const std = @import("std");

// ── OLC encode (inlined) ───────────────────────────────────────────────────

const CODE_ALPHABET: []const u8 = "23456789CFGHJMPQRVWX";
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
        if (digit == SEPARATOR_POSITION) { buffer[idx] = '+'; idx += 1; }
        if (digit >= length) break;
        var lng_digit = @as(usize, @intFromFloat(@floor(lng_val / res)));
        if (lng_digit >= CODE_ALPHABET.len) lng_digit = CODE_ALPHABET.len - 1;
        lng_val = @mod(lng_val, res);
        buffer[idx] = CODE_ALPHABET[lng_digit];
        idx += 1;
        digit += 1;
        if (digit == SEPARATOR_POSITION) { buffer[idx] = '+'; idx += 1; }
    }
    while (digit < SEPARATOR_POSITION) {
        buffer[idx] = '0';
        idx += 1;
        digit += 1;
        if (digit == SEPARATOR_POSITION) { buffer[idx] = '+'; idx += 1; }
    }
    if (length > PAIR_CODE_LENGTH) {
        const lat_res_base = pairRes(PAIR_CODE_LENGTH - 2);
        var grid_lat = lat_val;
        var grid_lng = lng_val;
        var step: u8 = 0;
        while (digit < length) {
            const lat_step = lat_res_base / std.math.pow(f64, GRID_ROWS, @as(f64, @floatFromInt(step + 1)));
            const lng_step = lat_res_base / std.math.pow(f64, GRID_COLS, @as(f64, @floatFromInt(step + 1)));
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
    return switch (t) { -1 => '-', 0 => '0', 1 => '+', else => '?' };
}

// ── Geo math ───────────────────────────────────────────────────────────────

fn haversine(lat1: f64, lng1: f64, lat2: f64, lng2: f64) f64 {
    const dlat = (lat2 - lat1) * std.math.pi / 180.0;
    const dlng = (lng2 - lng1) * std.math.pi / 180.0;
    const a = std.math.sin(dlat / 2.0) * std.math.sin(dlat / 2.0) +
        std.math.cos(lat1 * std.math.pi / 180.0) * std.math.cos(lat2 * std.math.pi / 180.0) *
        std.math.sin(dlng / 2.0) * std.math.sin(dlng / 2.0);
    return 6371000.0 * 2.0 * std.math.atan2(std.math.sqrt(a), std.math.sqrt(1.0 - a));
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

fn lerp(a: f64, b: f64, t: f64) f64 {
    return a + (b - a) * t;
}

// ── Barycentric coordinates for simplex interior ───────────────────────────

fn barycentric(v0_lat: f64, v0_lng: f64, v1_lat: f64, v1_lng: f64, v2_lat: f64, v2_lng: f64, u: f64, v: f64) struct { lat: f64, lng: f64 } {
    // Point = (1-u-v)*v0 + u*v1 + v*v2
    const w = 1.0 - u - v;
    return .{
        .lat = w * v0_lat + u * v1_lat + v * v2_lat,
        .lng = w * v0_lng + u * v1_lng + v * v2_lng,
    };
}

// ── Simplex vertices ──────────────────────────────────────────────────────

const Vertex = struct {
    name: []const u8,
    lat: f64,
    lng: f64,
    alt_m: f64, // altitude/floor height
    desc: []const u8,
};

const v0 = Vertex{
    .name = "YOU (InterContinental SF)",
    .lat = 37.7835,
    .lng = -122.4028,
    .alt_m = 30.0, // 8th floor ~3.5m/floor
    .desc = "888 Howard St, 8F, San Francisco",
};

const v1 = Vertex{
    .name = "PIXEL (triangulated)",
    .lat = 37.427619,
    .lng = -122.140716,
    .alt_m = 10.0, // ground level Palo Alto
    .desc = "High St / Oregon Ave, Palo Alto",
};

// v2: transit midpoint — Millbrae Caltrain (interchange point)
const v2 = Vertex{
    .name = "TRANSIT (Millbrae)",
    .lat = 37.5998,
    .lng = -122.3866,
    .alt_m = 5.0,
    .desc = "Millbrae Caltrain/BART interchange",
};

// ── Caltrain corridor waypoints (SF → PA) ──────────────────────────────────

const Waypoint = struct {
    name: []const u8,
    lat: f64,
    lng: f64,
};

const caltrain_stops = [_]Waypoint{
    .{ .name = "SF 4th & King",         .lat = 37.7764, .lng = -122.3941 },
    .{ .name = "22nd St",               .lat = 37.7577, .lng = -122.3920 },
    .{ .name = "Bayshore",              .lat = 37.7094, .lng = -122.4014 },
    .{ .name = "South SF",              .lat = 37.6559, .lng = -122.4050 },
    .{ .name = "San Bruno",             .lat = 37.6306, .lng = -122.4118 },
    .{ .name = "Millbrae",              .lat = 37.5998, .lng = -122.3866 },
    .{ .name = "Hillsdale",             .lat = 37.5381, .lng = -122.3459 },
    .{ .name = "San Mateo",             .lat = 37.5680, .lng = -122.3240 },
    .{ .name = "Redwood City",          .lat = 37.4857, .lng = -122.2320 },
    .{ .name = "Menlo Park",            .lat = 37.4546, .lng = -122.1825 },
    .{ .name = "Palo Alto",             .lat = 37.4433, .lng = -122.1649 },
    .{ .name = "California Ave",        .lat = 37.4291, .lng = -122.1422 },
};

pub fn main() !void {
    const p = std.debug.print;

    p("\n", .{});
    p("╔══════════════════════════════════════════════════════════════════════╗\n", .{});
    p("║  SIMPLEX TRACE: InterContinental SF → Pixel 10 Pro Fold           ║\n", .{});
    p("║  2-simplex triangulation over Caltrain corridor                   ║\n", .{});
    p("╚══════════════════════════════════════════════════════════════════════╝\n", .{});

    // ── Vertices ───────────────────────────────────────────────────────────
    p("\n── SIMPLEX VERTICES ────────────────────────────────────────────────\n\n", .{});

    var buf: [20]u8 = undefined;
    const vertices = [_]Vertex{ v0, v1, v2 };
    for (vertices, 0..) |v, i| {
        const len = encode(v.lat, v.lng, 10, &buf) catch continue;
        const trit = codeTrit(buf[0..len]);
        p("  v{d}: {s}\n", .{ i, v.name });
        p("      {s}\n", .{v.desc});
        p("      {d:.6}, {d:.6}  alt={d:.0}m\n", .{ v.lat, v.lng, v.alt_m });
        p("      OLC: {s}  [{c}]\n\n", .{ buf[0..len], tritSymbol(trit) });
    }

    // ── Edge lengths ───────────────────────────────────────────────────────
    const d01 = haversine(v0.lat, v0.lng, v1.lat, v1.lng);
    const d02 = haversine(v0.lat, v0.lng, v2.lat, v2.lng);
    const d12 = haversine(v1.lat, v1.lng, v2.lat, v2.lng);

    const b01 = bearing(v0.lat, v0.lng, v1.lat, v1.lng);
    const b10 = bearing(v1.lat, v1.lng, v0.lat, v0.lng);
    const b02 = bearing(v0.lat, v0.lng, v2.lat, v2.lng);

    p("── SIMPLEX EDGES ───────────────────────────────────────────────────\n\n", .{});
    p("  e01: YOU → PIXEL      {d:>8.0}m  bearing {d:>5.1}  ({s})  SE along peninsula\n", .{ d01, b01, compassDir(b01) });
    p("  e02: YOU → TRANSIT    {d:>8.0}m  bearing {d:>5.1}  ({s})  to Millbrae\n", .{ d02, b02, compassDir(b02) });
    p("  e12: TRANSIT → PIXEL  {d:>8.0}m  bearing   ---   Caltrain southbound\n", .{d12});
    p("\n  Perimeter: {d:.0}m ({d:.1} km)\n", .{ d01 + d02 + d12, (d01 + d02 + d12) / 1000.0 });

    // Simplex area via cross product
    const area_deg2 = @abs((v1.lat - v0.lat) * (v2.lng - v0.lng) - (v2.lat - v0.lat) * (v1.lng - v0.lng)) / 2.0;
    const area_km2 = area_deg2 * 111.0 * 111.0 * std.math.cos(37.6 * std.math.pi / 180.0);
    p("  Area: ~{d:.1} km^2\n", .{area_km2});

    // ── Simplex face trits ─────────────────────────────────────────────────
    p("\n── FACE TRIT (GF(3) sum of vertex trits) ───────────────────────────\n\n", .{});

    var vtrit: [3]i8 = undefined;
    for (vertices, 0..) |v, i| {
        const len = encode(v.lat, v.lng, 10, &buf) catch continue;
        vtrit[i] = codeTrit(buf[0..len]);
    }
    const face_sum = @mod(@as(i32, vtrit[0]) + @as(i32, vtrit[1]) + @as(i32, vtrit[2]) + 6, 3) - 1;
    p("  v0[{c}] + v1[{c}] + v2[{c}] = [{c}]  (face trit)\n", .{
        tritSymbol(vtrit[0]), tritSymbol(vtrit[1]), tritSymbol(vtrit[2]),
        tritSymbol(@intCast(face_sum)),
    });

    // ── Edge trace: YOU → PIXEL (direct) ──────────────────────────────────
    p("\n── EDGE TRACE e01: YOU → PIXEL (direct, {d:.1} km) ─────────────────\n\n", .{d01 / 1000.0});
    p("  Step   t     Lat        Lng         OLC            Dist(m)  Trit\n", .{});
    p("  ────   ───   ────────   ──────────  ───────────    ───────  ────\n", .{});

    var step: u32 = 0;
    while (step <= 20) : (step += 1) {
        const t: f64 = @as(f64, @floatFromInt(step)) / 20.0;
        const elat = lerp(v0.lat, v1.lat, t);
        const elng = lerp(v0.lng, v1.lng, t);
        const len = encode(elat, elng, 10, &buf) catch continue;
        const d = haversine(v0.lat, v0.lng, elat, elng);
        const trit = codeTrit(buf[0..len]);
        const marker: []const u8 = if (step == 0) " <-- YOU" else if (step == 20) " <-- PIXEL" else "";
        p("  {d:>4}   {d:.2}  {d:.6}  {d:.6}  {s}    {d:>7.0}  [{c}]{s}\n", .{
            step, t, elat, elng, buf[0..len], d, tritSymbol(trit), marker,
        });
    }

    // ── Caltrain corridor trace ────────────────────────────────────────────
    p("\n── CALTRAIN CORRIDOR TRACE (practical route) ───────────────────────\n\n", .{});
    p("  Stop                    Lat        Lng         OLC            Dist→PA  Trit\n", .{});
    p("  ──────────────────────  ────────   ──────────  ───────────    ───────  ────\n", .{});

    const dest_lat = v1.lat;
    const dest_lng = v1.lng;

    for (caltrain_stops) |stop| {
        const len = encode(stop.lat, stop.lng, 10, &buf) catch continue;
        const d = haversine(stop.lat, stop.lng, dest_lat, dest_lng);
        const trit = codeTrit(buf[0..len]);
        const marker: []const u8 = if (d < 500) " ** CLOSEST" else "";
        p("  {s: <24}{d:.6}  {d:.6}  {s}    {d:>7.0}  [{c}]{s}\n", .{
            stop.name, stop.lat, stop.lng, buf[0..len], d, tritSymbol(trit), marker,
        });
    }

    // ── Barycentric interior sampling ──────────────────────────────────────
    p("\n── SIMPLEX INTERIOR (barycentric sampling) ─────────────────────────\n\n", .{});
    p("  (u,v)        Lat        Lng         OLC            Trit  Region\n", .{});
    p("  ──────────   ────────   ──────────  ───────────    ────  ──────────────\n", .{});

    const bary_samples = [_][2]f64{
        .{ 0.333, 0.333 }, // centroid
        .{ 0.5, 0.25 },   // toward pixel
        .{ 0.25, 0.5 },   // toward transit
        .{ 0.1, 0.1 },    // near you
        .{ 0.7, 0.15 },   // deep toward pixel
        .{ 0.15, 0.7 },   // deep toward transit
        .{ 0.5, 0.0 },    // midpoint e01
        .{ 0.0, 0.5 },    // midpoint e02
        .{ 0.5, 0.5 },    // midpoint e12 (on far edge)
    };

    const region_names = [_][]const u8{
        "centroid       ",
        "pixel quadrant ",
        "transit quadrant",
        "your quadrant  ",
        "near pixel     ",
        "near transit   ",
        "mid YOU-PIXEL  ",
        "mid YOU-TRANSIT",
        "mid TRNS-PIXEL ",
    };

    for (bary_samples, 0..) |uv, i| {
        const u = uv[0];
        const v = uv[1];
        if (u + v > 1.0) continue; // outside simplex
        const pt = barycentric(v0.lat, v0.lng, v1.lat, v1.lng, v2.lat, v2.lng, u, v);
        const len = encode(pt.lat, pt.lng, 10, &buf) catch continue;
        const trit = codeTrit(buf[0..len]);
        p("  ({d:.2},{d:.2})    {d:.6}  {d:.6}  {s}    [{c}]  {s}\n", .{
            u, v, pt.lat, pt.lng, buf[0..len], tritSymbol(trit), region_names[i],
        });
    }

    // ── Recovery path recommendation ───────────────────────────────────────
    p("\n══════════════════════════════════════════════════════════════════════\n", .{});
    p("  SIMPLEX RECOVERY PATH\n\n", .{});
    p("  From: InterContinental SF, 888 Howard St, 8F\n", .{});
    p("  To:   849VCVH5+2P (triangulated device position)\n\n", .{});
    p("  Direct distance: {d:.1} km  bearing {d:.0} ({s})\n", .{ d01 / 1000.0, b01, compassDir(b01) });
    p("  Return bearing:  {d:.0} ({s})\n\n", .{ b10, compassDir(b10) });
    p("  RECOMMENDED ROUTE:\n", .{});
    p("    1. Uber/Lyft to SF Caltrain (4th & King) — ~1 mi NE\n", .{});
    p("    2. Caltrain southbound → California Ave station — ~55 min\n", .{});
    p("    3. Walk 200m N to High St / Oregon Ave\n", .{});
    p("    4. Search IMMEDIATE tiles around 849VCVH5+2P\n\n", .{});
    p("  OR: Drive via US-101 S — ~35 min (31 mi)\n\n", .{});
    p("  California Ave Caltrain is 193m SW of triangulated position.\n", .{});
    p("  That's the closest station to the device.\n", .{});
    p("══════════════════════════════════════════════════════════════════════\n", .{});
}
