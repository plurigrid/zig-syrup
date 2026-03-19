///! Reverse simplex trace: Pixel 10 Pro Fold → InterContinental SF
///!
///! The forward trace (pixel_simplex_trace.zig) goes YOU→PIXEL (SF→PA).
///! This is the RETURN: PIXEL→YOU (PA→SF), recovered device in hand.
///!
///! Vertices of the 2-simplex (reversed orientation):
///!   v0: Pixel last-seen — High St / Oregon Ave, Palo Alto
///!   v1: YOU — InterContinental SF, 888 Howard St, 8F
///!   v2: Transit midpoint — Millbrae Caltrain/BART interchange
///!
///! "fastest in the world" — the 849V OLC prefix tile contains:
///!   - Pixel device (849VCVH5+2P)
///!   - Stanford CSLI / Aczel's AFA (849VCRHJ+24) — 2.56 km away
///!   - California Ave Caltrain (849VCVJ4+xx) — 193m away
///!   All three share the same length-4 OLC prefix: 849V
///!   This is the fastest geo tile for GeoACSet operations:
///!   a single length-4 cell (~110km x 110km) covering the entire
///!   recovery simplex from Palo Alto to SF.

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

// ── Simplex vertices (REVERSED from pixel_simplex_trace.zig) ─────────────

const Vertex = struct {
    name: []const u8,
    lat: f64,
    lng: f64,
    alt_m: f64,
    desc: []const u8,
};

// v0 is now PIXEL (start of return journey)
const v0 = Vertex{
    .name = "PIXEL (recovered)",
    .lat = 37.427619,
    .lng = -122.140716,
    .alt_m = 10.0,
    .desc = "High St / Oregon Ave, Palo Alto (849VCVH5+2P)",
};

// v1 is now YOU (destination)
const v1 = Vertex{
    .name = "YOU (InterContinental SF)",
    .lat = 37.7835,
    .lng = -122.4028,
    .alt_m = 30.0,
    .desc = "888 Howard St, 8F, San Francisco",
};

// v2 remains transit midpoint
const v2 = Vertex{
    .name = "TRANSIT (Millbrae)",
    .lat = 37.5998,
    .lng = -122.3866,
    .alt_m = 5.0,
    .desc = "Millbrae Caltrain/BART interchange",
};

// ── Caltrain corridor NORTHBOUND (PA → SF) ──────────────────────────────

const Waypoint = struct {
    name: []const u8,
    lat: f64,
    lng: f64,
};

const caltrain_northbound = [_]Waypoint{
    .{ .name = "California Ave",        .lat = 37.4291, .lng = -122.1422 },
    .{ .name = "Palo Alto",             .lat = 37.4433, .lng = -122.1649 },
    .{ .name = "Menlo Park",            .lat = 37.4546, .lng = -122.1825 },
    .{ .name = "Redwood City",          .lat = 37.4857, .lng = -122.2320 },
    .{ .name = "San Mateo",             .lat = 37.5680, .lng = -122.3240 },
    .{ .name = "Hillsdale",             .lat = 37.5381, .lng = -122.3459 },
    .{ .name = "Millbrae",              .lat = 37.5998, .lng = -122.3866 },
    .{ .name = "San Bruno",             .lat = 37.6306, .lng = -122.4118 },
    .{ .name = "South SF",              .lat = 37.6559, .lng = -122.4050 },
    .{ .name = "Bayshore",              .lat = 37.7094, .lng = -122.4014 },
    .{ .name = "22nd St",               .lat = 37.7577, .lng = -122.3920 },
    .{ .name = "SF 4th & King",         .lat = 37.7764, .lng = -122.3941 },
};

// ── GeoACSet speed tiers ─────────────────────────────────────────────────
//
// OLC length → tile size → query domain for GeoACSet.jl:
//   len 2:  ~2200 km   continent-scale (single tile: all of western NA)
//   len 4:  ~110 km    metro-scale     ** FASTEST: 849V covers SF→PA **
//   len 6:  ~5.5 km    neighborhood    separates SF/Millbrae/PA
//   len 8:  ~275 m     block-scale     individual stops
//   len 10: ~14 m      building-scale  device search grid
//   len 11: ~3 m       room-scale      final approach
//
// The "fastest in the world" insight: at OLC length 4, the ENTIRE
// recovery simplex (SF ↔ PA ↔ Millbrae) fits in ONE tile: 849V.
// A GeoACSet query at this resolution is O(1) — single cell lookup.
// For comparison, bibliography_olc.zig spans tiles 4RRH (Sydney) to
// 9GF6 (Tallinn): 11 distinct length-4 tiles across the globe.

pub fn main() !void {
    const p = std.debug.print;

    p("\n", .{});
    p("╔══════════════════════════════════════════════════════════════════════╗\n", .{});
    p("║  REVERSE SIMPLEX TRACE: Pixel → InterContinental SF               ║\n", .{});
    p("║  Return path with recovered device (PA → SF, northbound)          ║\n", .{});
    p("╚══════════════════════════════════════════════════════════════════════╝\n", .{});

    // ── Vertices ───────────────────────────────────────────────────────────
    p("\n── SIMPLEX VERTICES (reversed orientation) ─────────────────────────\n\n", .{});

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

    // ── OLC prefix hierarchy (the "fastest" analysis) ────────────────────
    p("── OLC PREFIX HIERARCHY: fastest geo for GeoACSet ──────────────────\n\n", .{});

    const prefix_points = [_]struct { name: []const u8, lat: f64, lng: f64 }{
        .{ .name = "PIXEL device",           .lat = 37.427619, .lng = -122.140716 },
        .{ .name = "Stanford CSLI (Aczel)",  .lat = 37.4275,   .lng = -122.1697 },
        .{ .name = "California Ave Caltrain",.lat = 37.4291,   .lng = -122.1422 },
        .{ .name = "Topos Institute Berkeley",.lat = 37.8717,  .lng = -122.2597 },
        .{ .name = "InterContinental SF",    .lat = 37.7835,   .lng = -122.4028 },
        .{ .name = "Millbrae interchange",   .lat = 37.5998,   .lng = -122.3866 },
    };

    p("  Point                        len4  len6      len8        len10       \n", .{});
    p("  ───────────────────────────   ────  ──────    ────────    ──────────  \n", .{});

    for (prefix_points) |pt| {
        var b4: [20]u8 = undefined;
        var b6: [20]u8 = undefined;
        var b8: [20]u8 = undefined;
        var b10: [20]u8 = undefined;
        const l4 = encode(pt.lat, pt.lng, 4, &b4) catch continue;
        const l6 = encode(pt.lat, pt.lng, 6, &b6) catch continue;
        const l8 = encode(pt.lat, pt.lng, 8, &b8) catch continue;
        const l10 = encode(pt.lat, pt.lng, 10, &b10) catch continue;
        p("  {s: <30} {s}  {s}  {s}  {s}\n", .{
            pt.name, b4[0..l4], b6[0..l6], b8[0..l8], b10[0..l10],
        });
    }

    p("\n  KEY INSIGHT: All 6 points share OLC prefix 849V at length 4.\n", .{});
    p("  → Single-tile GeoACSet query covers the entire recovery simplex.\n", .{});
    p("  → At length 6, SF separates (849VQ vs 849VC) — 2-tile query.\n", .{});
    p("  → At length 8, each stop gets its own tile — 6+ tile query.\n", .{});

    // ── Edge lengths ───────────────────────────────────────────────────────
    const d01 = haversine(v0.lat, v0.lng, v1.lat, v1.lng);
    const d02 = haversine(v0.lat, v0.lng, v2.lat, v2.lng);
    const d12 = haversine(v1.lat, v1.lng, v2.lat, v2.lng);

    const b01 = bearing(v0.lat, v0.lng, v1.lat, v1.lng);
    _ = bearing(v1.lat, v1.lng, v0.lat, v0.lng);

    p("\n── SIMPLEX EDGES (reversed) ────────────────────────────────────────\n\n", .{});
    p("  e01: PIXEL → YOU      {d:>8.0}m  bearing {d:>5.1}  ({s})  NW up peninsula\n", .{ d01, b01, compassDir(b01) });
    p("  e02: PIXEL → TRANSIT  {d:>8.0}m  Caltrain northbound\n", .{d02});
    p("  e12: TRANSIT → YOU    {d:>8.0}m  Caltrain/BART → Uber\n", .{d12});
    p("\n  Perimeter: {d:.0}m ({d:.1} km)\n", .{ d01 + d02 + d12, (d01 + d02 + d12) / 1000.0 });

    // ── Face trit ────────────────────────────────────────────────────────
    p("\n── FACE TRIT (GF(3) — reversed orientation flips sign) ─────────────\n\n", .{});

    var vtrit: [3]i8 = undefined;
    for (vertices, 0..) |v, i| {
        const len = encode(v.lat, v.lng, 10, &buf) catch continue;
        vtrit[i] = codeTrit(buf[0..len]);
    }
    const face_sum = @mod(@as(i32, vtrit[0]) + @as(i32, vtrit[1]) + @as(i32, vtrit[2]) + 6, 3) - 1;
    const rev_face = @mod(-face_sum + 3, 3) - 1;
    p("  Forward:  v0[{c}] + v1[{c}] + v2[{c}] = [{c}]  (same vertices, same sum)\n", .{
        tritSymbol(vtrit[0]), tritSymbol(vtrit[1]), tritSymbol(vtrit[2]),
        tritSymbol(@intCast(face_sum)),
    });
    p("  Reversed orientation trit: [{c}]  (negated mod 3)\n", .{
        tritSymbol(@intCast(rev_face)),
    });

    // ── Edge trace: PIXEL → YOU (direct, northbound) ─────────────────────
    p("\n── EDGE TRACE e01: PIXEL → YOU (direct, {d:.1} km NW) ────────────\n\n", .{d01 / 1000.0});
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
        const marker: []const u8 = if (step == 0) " <-- PIXEL" else if (step == 20) " <-- YOU" else "";
        p("  {d:>4}   {d:.2}  {d:.6}  {d:.6}  {s}    {d:>7.0}  [{c}]{s}\n", .{
            step, t, elat, elng, buf[0..len], d, tritSymbol(trit), marker,
        });
    }

    // ── Caltrain NORTHBOUND trace ────────────────────────────────────────
    p("\n── CALTRAIN NORTHBOUND (practical return route) ─────────────────────\n\n", .{});
    p("  Stop                    Lat        Lng         OLC            Dist→SF  Trit\n", .{});
    p("  ──────────────────────  ────────   ──────────  ───────────    ───────  ────\n", .{});

    for (caltrain_northbound) |stop| {
        const len = encode(stop.lat, stop.lng, 10, &buf) catch continue;
        const d = haversine(stop.lat, stop.lng, v1.lat, v1.lng);
        const trit = codeTrit(buf[0..len]);
        const marker: []const u8 = if (d < 2000) " ** CLOSE" else "";
        p("  {s: <24}{d:.6}  {d:.6}  {s}    {d:>7.0}  [{c}]{s}\n", .{
            stop.name, stop.lat, stop.lng, buf[0..len], d, tritSymbol(trit), marker,
        });
    }

    // ── GeoACSet trit-flow along return path ─────────────────────────────
    p("\n── GF(3) TRIT FLOW: northbound trit sequence ──────────────────────\n\n", .{});
    p("  Each Caltrain stop's trit forms a sequence in GF(3).\n", .{});
    p("  Running sum mod 3 tracks conservation along the path:\n\n", .{});

    var running_sum: i32 = 0;
    p("  Stop                 Trit  Running\n", .{});
    p("  ───────────────────  ────  ───────\n", .{});
    for (caltrain_northbound) |stop| {
        const len = encode(stop.lat, stop.lng, 10, &buf) catch continue;
        const trit = codeTrit(buf[0..len]);
        running_sum = @mod(running_sum + @as(i32, trit) + 3, 3) - 1;
        p("  {s: <21} [{c}]   [{c}]\n", .{
            stop.name, tritSymbol(trit), tritSymbol(@intCast(running_sum + 1)),
        });
    }

    // ── Recovery return recommendation ───────────────────────────────────
    p("\n══════════════════════════════════════════════════════════════════════\n", .{});
    p("  RETURN PATH (device recovered)\n\n", .{});
    p("  From: 849VCVH5+2P (High St / Oregon Ave, Palo Alto)\n", .{});
    p("  To:   InterContinental SF, 888 Howard St, 8F\n\n", .{});
    p("  Direct distance: {d:.1} km  bearing {d:.0} ({s})\n\n", .{ d01 / 1000.0, b01, compassDir(b01) });
    p("  RECOMMENDED RETURN:\n", .{});
    p("    1. Walk 200m S to California Ave Caltrain\n", .{});
    p("    2. Caltrain NORTHBOUND → SF 4th & King — ~55 min\n", .{});
    p("       (or NORTHBOUND → Millbrae, transfer to BART)\n", .{});
    p("    3. Uber/Lyft from 4th & King to 888 Howard — ~5 min\n\n", .{});
    p("  OR: Uber/Lyft direct PA → SF — ~35 min (31 mi via US-101)\n\n", .{});
    p("  GEOACSET NOTE:\n", .{});
    p("    All points in the recovery simplex share OLC prefix 849V.\n", .{});
    p("    This is the FASTEST single-tile geo query for the entire\n", .{});
    p("    SF ↔ PA corridor. GeoACSet.jl at length-4 resolution:\n", .{});
    p("    one ACSet cell, O(1) spatial lookup, ~110km coverage.\n", .{});
    p("══════════════════════════════════════════════════════════════════════\n", .{});
}
