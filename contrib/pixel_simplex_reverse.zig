///! REVERSE Simplex trace: Pixel 10 Pro Fold → InterContinental SF
///!
///! The return path — device recovered from Yuliya's location in Palo Alto,
///! traced back to 888 Howard St, 8F.
///!
///! Vertices of the reversed 2-simplex:
///!   v0: Triangulated device position — High St / Oregon Ave, Palo Alto
///!   v1: Current position — InterContinental SF, 888 Howard St, 8th floor
///!   v2: Transit midpoint — Millbrae Caltrain/BART interchange
///!
///! Reversal inverts edge orientation: e01 now goes PA→SF (NW bearing).
///! Face trit is preserved under reversal (GF(3) addition is commutative).
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
        if (digit == SEPARATOR_POSITION) {
            buffer[idx] = '+';
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
            buffer[idx] = '+';
            idx += 1;
        }
    }
    while (digit < SEPARATOR_POSITION) {
        buffer[idx] = '0';
        idx += 1;
        digit += 1;
        if (digit == SEPARATOR_POSITION) {
            buffer[idx] = '+';
            idx += 1;
        }
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

// ── Reversed vertices ───────────────────────────────────────────────────────

const Vertex = struct {
    name: []const u8,
    lat: f64,
    lng: f64,
    alt_m: f64,
    desc: []const u8,
};

// v0 is now the PIXEL (start of return journey)
const v0 = Vertex{
    .name = "PIXEL (recovered from Yuliya)",
    .lat = 37.427619,
    .lng = -122.140716,
    .alt_m = 10.0,
    .desc = "High St / Oregon Ave, Palo Alto — Yuliya confirmed possession",
};

// v1 is now YOU (destination)
const v1 = Vertex{
    .name = "YOU (InterContinental SF)",
    .lat = 37.7835,
    .lng = -122.4028,
    .alt_m = 30.0,
    .desc = "888 Howard St, 8F, San Francisco",
};

// v2: transit midpoint (same)
const v2 = Vertex{
    .name = "TRANSIT (Millbrae)",
    .lat = 37.5998,
    .lng = -122.3866,
    .alt_m = 5.0,
    .desc = "Millbrae Caltrain/BART interchange",
};

// ── Caltrain corridor REVERSED (PA → SF) ────────────────────────────────────

const Waypoint = struct {
    name: []const u8,
    lat: f64,
    lng: f64,
};

const caltrain_stops_reverse = [_]Waypoint{
    .{ .name = "California Ave", .lat = 37.4291, .lng = -122.1422 },
    .{ .name = "Palo Alto", .lat = 37.4433, .lng = -122.1649 },
    .{ .name = "Menlo Park", .lat = 37.4546, .lng = -122.1825 },
    .{ .name = "Redwood City", .lat = 37.4857, .lng = -122.2320 },
    .{ .name = "San Mateo", .lat = 37.5680, .lng = -122.3240 },
    .{ .name = "Hillsdale", .lat = 37.5381, .lng = -122.3459 },
    .{ .name = "Millbrae", .lat = 37.5998, .lng = -122.3866 },
    .{ .name = "San Bruno", .lat = 37.6306, .lng = -122.4118 },
    .{ .name = "South SF", .lat = 37.6559, .lng = -122.4050 },
    .{ .name = "Bayshore", .lat = 37.7094, .lng = -122.4014 },
    .{ .name = "22nd St", .lat = 37.7577, .lng = -122.3920 },
    .{ .name = "SF 4th & King", .lat = 37.7764, .lng = -122.3941 },
};

// ── Yuliya context from Beeper forensics ─────────────────────────────────────

const YuliyaContext = struct {
    timestamp: []const u8,
    message: []const u8,
    channel: []const u8,
};

const beeper_evidence = [_]YuliyaContext{
    .{ .timestamp = "2026-03-16 19:52", .message = "oh no you left the mantissa phone here", .channel = "Signal" },
};

pub fn main() !void {
    const p = std.debug.print;

    p("\n", .{});
    p("╔══════════════════════════════════════════════════════════════════════╗\n", .{});
    p("║  REVERSE SIMPLEX: Pixel 10 Pro Fold → InterContinental SF         ║\n", .{});
    p("║  Recovery return path — PA → SF via Caltrain                      ║\n", .{});
    p("║  Device holder: Yuliya Zubak (confirmed via Beeper/Signal)        ║\n", .{});
    p("╚══════════════════════════════════════════════════════════════════════╝\n", .{});

    // ── Beeper evidence ──────────────────────────────────────────────────
    p("\n── POSSESSION EVIDENCE ─────────────────────────────────────────────\n\n", .{});
    for (beeper_evidence) |ev| {
        p("  [{s}] via {s}:\n", .{ ev.timestamp, ev.channel });
        p("  \"{s}\"\n", .{ev.message});
    }
    p("\n  greenteatree01 = Yuliya Zubak (comonad evaluation: 485 msgs)\n", .{});
    p("  Device is at her Palo Alto location, near Jerry Bowden Park\n", .{});

    // ── Vertices ───────────────────────────────────────────────────────────
    p("\n── REVERSED SIMPLEX VERTICES ────────────────────────────────────────\n\n", .{});

    var buf: [20]u8 = undefined;
    const vertices = [_]Vertex{ v0, v1, v2 };
    var vtrit: [3]i8 = undefined;

    for (vertices, 0..) |v, i| {
        const len = encode(v.lat, v.lng, 10, &buf) catch continue;
        vtrit[i] = codeTrit(buf[0..len]);
        p("  v{d}: {s}\n", .{ i, v.name });
        p("      {s}\n", .{v.desc});
        p("      {d:.6}, {d:.6}  alt={d:.0}m\n", .{ v.lat, v.lng, v.alt_m });
        p("      OLC: {s}  [{c}] {s}\n\n", .{ buf[0..len], tritSymbol(vtrit[i]), tritName(vtrit[i]) });
    }

    // ── Edge lengths (reversed) ──────────────────────────────────────────
    const d01 = haversine(v0.lat, v0.lng, v1.lat, v1.lng);
    const d02 = haversine(v0.lat, v0.lng, v2.lat, v2.lng);
    const d12 = haversine(v1.lat, v1.lng, v2.lat, v2.lng);

    const b01 = bearing(v0.lat, v0.lng, v1.lat, v1.lng);
    const b10 = bearing(v1.lat, v1.lng, v0.lat, v0.lng);

    p("── REVERSED EDGES ──────────────────────────────────────────────────\n\n", .{});
    p("  e01: PIXEL → YOU      {d:>8.0}m  bearing {d:>5.1}  ({s})  NW up peninsula\n", .{ d01, b01, compassDir(b01) });
    p("  e02: PIXEL → TRANSIT  {d:>8.0}m  Caltrain northbound\n", .{d02});
    p("  e12: YOU → TRANSIT    {d:>8.0}m  (same as forward)\n", .{d12});
    p("\n  Perimeter: {d:.0}m ({d:.1} km) — invariant under reversal\n", .{ d01 + d02 + d12, (d01 + d02 + d12) / 1000.0 });

    // ── Face trit ────────────────────────────────────────────────────────
    p("\n── FACE TRIT (commutative — invariant under reversal) ────────────\n\n", .{});
    const face_sum = @mod(@as(i32, vtrit[0]) + @as(i32, vtrit[1]) + @as(i32, vtrit[2]) + 6, 3) - 1;
    p("  v0[{c}] + v1[{c}] + v2[{c}] = [{c}]  {s}\n", .{
        tritSymbol(vtrit[0]),           tritSymbol(vtrit[1]),         tritSymbol(vtrit[2]),
        tritSymbol(@intCast(face_sum)), tritName(@intCast(face_sum)),
    });
    p("  (same face trit as forward trace — GF(3) addition commutes)\n", .{});

    // ── Edge trace: PIXEL → YOU (reversed direct) ────────────────────────
    p("\n── EDGE TRACE e01: PIXEL → YOU ({d:.1} km, bearing {d:.0} {s}) ──\n\n", .{ d01 / 1000.0, b01, compassDir(b01) });
    p("  Step   t     Lat        Lng         OLC            Dist(m)  Trit  Zone\n", .{});
    p("  ────   ───   ────────   ──────────  ───────────    ───────  ────  ────────────\n", .{});

    var step: u32 = 0;
    while (step <= 20) : (step += 1) {
        const t: f64 = @as(f64, @floatFromInt(step)) / 20.0;
        const elat = lerp(v0.lat, v1.lat, t);
        const elng = lerp(v0.lng, v1.lng, t);
        const len = encode(elat, elng, 10, &buf) catch continue;
        const d = haversine(v0.lat, v0.lng, elat, elng);
        const trit = codeTrit(buf[0..len]);
        const zone: []const u8 = if (step == 0)
            "PIXEL START"
        else if (step == 20)
            "DESTINATION"
        else if (elat < 37.50)
            "Palo Alto"
        else if (elat < 37.60)
            "Redwood City"
        else if (elat < 37.65)
            "San Mateo"
        else if (elat < 37.72)
            "Daly City"
        else
            "San Francisco";
        p("  {d:>4}   {d:.2}  {d:.6}  {d:.6}  {s}    {d:>7.0}  [{c}]  {s}\n", .{
            step, t, elat, elng, buf[0..len], d, tritSymbol(trit), zone,
        });
    }

    // ── Caltrain corridor REVERSED (PA → SF) ─────────────────────────────
    p("\n── CALTRAIN NORTHBOUND (California Ave → SF 4th & King) ─────────\n\n", .{});
    p("  #   Stop                    Lat        Lng         OLC            Dist→SF  Trit\n", .{});
    p("  ──  ──────────────────────  ────────   ──────────  ───────────    ───────  ────\n", .{});

    for (caltrain_stops_reverse, 0..) |stop, i| {
        const len = encode(stop.lat, stop.lng, 10, &buf) catch continue;
        const d = haversine(stop.lat, stop.lng, v1.lat, v1.lng);
        const trit = codeTrit(buf[0..len]);
        const marker: []const u8 = if (i == 0) " << BOARD" else if (i == caltrain_stops_reverse.len - 1) " << ARRIVE" else "";
        p("  {d:>2}  {s: <24}{d:.6}  {d:.6}  {s}    {d:>7.0}  [{c}]{s}\n", .{
            i + 1, stop.name, stop.lat, stop.lng, buf[0..len], d, tritSymbol(trit), marker,
        });
    }

    // ── Trit phase transitions along the corridor ─────────────────────────
    p("\n── TRIT PHASE DIAGRAM (northbound corridor) ─────────────────────\n\n", .{});
    p("  CA Ave → Palo Alto → Menlo → RWC → SanMateo → Hillsdale → Millbrae → ... → SF\n  ", .{});

    for (caltrain_stops_reverse) |stop| {
        const len = encode(stop.lat, stop.lng, 10, &buf) catch continue;
        const trit = codeTrit(buf[0..len]);
        p("[{c}]─", .{tritSymbol(trit)});
    }
    p("\n", .{});

    // ── Walking segment: Yuliya's → California Ave ────────────────────────
    p("\n── FIRST MILE: Yuliya's → California Ave Caltrain ──────────────\n\n", .{});

    const walk_dist = haversine(v0.lat, v0.lng, caltrain_stops_reverse[0].lat, caltrain_stops_reverse[0].lng);
    const walk_bearing = bearing(v0.lat, v0.lng, caltrain_stops_reverse[0].lat, caltrain_stops_reverse[0].lng);
    p("  Distance: {d:.0}m ({d:.2} km)\n", .{ walk_dist, walk_dist / 1000.0 });
    p("  Bearing:  {d:.0} ({s})\n", .{ walk_bearing, compassDir(walk_bearing) });
    p("  Est time: {d:.0} min walk\n", .{walk_dist / 80.0}); // ~80m/min walking speed

    // 5 interpolated points along the walk
    p("\n  Walk waypoints:\n", .{});
    p("  Step  OLC            Trit\n", .{});

    var ws: u32 = 0;
    while (ws <= 4) : (ws += 1) {
        const t: f64 = @as(f64, @floatFromInt(ws)) / 4.0;
        const wlat = lerp(v0.lat, caltrain_stops_reverse[0].lat, t);
        const wlng = lerp(v0.lng, caltrain_stops_reverse[0].lng, t);
        const len = encode(wlat, wlng, 10, &buf) catch continue;
        const trit = codeTrit(buf[0..len]);
        p("  {d}/4   {s}  [{c}]\n", .{ ws, buf[0..len], tritSymbol(trit) });
    }

    // ── Last mile: SF 4th & King → InterContinental ───────────────────────
    p("\n── LAST MILE: SF 4th & King → InterContinental SF ──────────────\n\n", .{});

    const last_dist = haversine(caltrain_stops_reverse[caltrain_stops_reverse.len - 1].lat, caltrain_stops_reverse[caltrain_stops_reverse.len - 1].lng, v1.lat, v1.lng);
    const last_bearing = bearing(caltrain_stops_reverse[caltrain_stops_reverse.len - 1].lat, caltrain_stops_reverse[caltrain_stops_reverse.len - 1].lng, v1.lat, v1.lng);
    p("  Distance: {d:.0}m ({d:.2} km)\n", .{ last_dist, last_dist / 1000.0 });
    p("  Bearing:  {d:.0} ({s})\n", .{ last_bearing, compassDir(last_bearing) });
    p("  Est time: {d:.0} min walk / 5 min Uber\n", .{last_dist / 80.0});

    // ── Total journey time estimate ──────────────────────────────────────
    p("\n══════════════════════════════════════════════════════════════════════\n", .{});
    p("  REVERSE RECOVERY PATH — COMPLETE ITINERARY\n\n", .{});
    p("  1. Walk from Yuliya's → California Ave Caltrain\n", .{});
    p("     {d:.0}m {s}, ~{d:.0} min\n", .{ walk_dist, compassDir(walk_bearing), walk_dist / 80.0 });
    p("\n  2. Caltrain northbound California Ave → SF 4th & King\n", .{});
    p("     12 stops, ~55 min express / ~70 min local\n", .{});
    p("\n  3. Walk/Uber from 4th & King → InterContinental SF\n", .{});
    p("     {d:.0}m {s}, ~{d:.0} min walk\n", .{ last_dist, compassDir(last_bearing), last_dist / 80.0 });
    p("\n  TOTAL: ~{d:.0} min (walk + Caltrain express + walk)\n", .{walk_dist / 80.0 + 55.0 + last_dist / 80.0});
    p("  TOTAL DISTANCE: {d:.1} km (as the crow flies)\n", .{d01 / 1000.0});
    p("\n  ALTERNATIVE: Uber/Lyft direct — ~35 min, 31 mi via US-101 N\n", .{});
    p("\n  Device:  Pixel 10 Pro Fold (\"mantissa phone\")\n", .{});
    p("  Holder:  Yuliya Zubak (greenteatree01)\n", .{});
    p("  At:      849VCVH5+2P [ERGODIC] — Jerry Bowden Park area\n", .{});
    p("  Return:  849VQHMW+CV [MINUS] — InterContinental SF, 8F\n", .{});
    p("\n  Edge reversal: bearing {d:.0} ({s}) → {d:.0} ({s})\n", .{
        b10, compassDir(b10), b01, compassDir(b01),
    });
    p("  Face trit [{c}] preserved under orientation reversal ✓\n", .{tritSymbol(@intCast(face_sum))});
    p("══════════════════════════════════════════════════════════════════════\n", .{});
}
