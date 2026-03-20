///! Generate OLC-annotated bibliography from all .bib files across worlds/
///! Maps institutions and author locations to Plus Codes with GF(3) trits.
///!
///! Sources:
///!   d/poly-structures/Library20250509.bib
///!   d/dependent-types/Library20240927.bib
///!   e/infinity-cosmos/blueprint/src/RVbiblio.bib
///!   o/discopy/docs/discopy.bib
///!   v/CatTheory4All/references.bib
///!   v/basictex/all.bib
///!   v/dialecticaLambek/references.bib
///!   d/concordia/CITATION.bib

const std = @import("std");

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

const Institution = struct {
    name: []const u8,
    lat: f64,
    lng: f64,
    bib_keys: []const []const u8,
    world: u8, // letter-world
};

const institutions = [_]Institution{
    // ── Cambridge ──
    .{ .name = "Cambridge University Press / DPMMS", .lat = 52.2043, .lng = 0.1149,
       .bib_keys = &.{ "RiehlVerity:2022eo", "CoeckeKissinger17", "depaiva1990" }, .world = 'e' },
    // ── Johns Hopkins (Emily Riehl) ──
    .{ .name = "Johns Hopkins University (Riehl)", .lat = 39.3299, .lng = -76.6205,
       .bib_keys = &.{ "RiehlVerity:2021ce", "RiehlVerity:2022eo" }, .world = 'e' },
    // ── Macquarie University (Verity, Lack, Street) ──
    .{ .name = "Macquarie University (Verity/Lack)", .lat = -33.7738, .lng = 151.1126,
       .bib_keys = &.{ "Lack:2010tc", "BLV:2020af" }, .world = 'e' },
    // ── Oxford (Abramsky, Coecke, Kissinger) ──
    .{ .name = "University of Oxford (CompSci)", .lat = 51.7600, .lng = -1.2588,
       .bib_keys = &.{ "Abramsky96", "CoeckeKissinger17" }, .world = 'o' },
    // ── UCL (DisCoPy — de Felice, Toumi) ──
    .{ .name = "UCL (DisCoPy group)", .lat = 51.5246, .lng = -0.1340,
       .bib_keys = &.{ "DelpeuchVicary22", "DunnVicary19" }, .world = 'o' },
    // ── Tallinn (Gepner) ──
    .{ .name = "TalTech (Gepner)", .lat = 59.3953, .lng = 24.6713,
       .bib_keys = &.{ "GepnerHaugsengKock:2021oa" }, .world = 'e' },
    // ── NTNU (Haugseng) ──
    .{ .name = "NTNU Trondheim (Haugseng)", .lat = 63.4184, .lng = 10.4017,
       .bib_keys = &.{ "GepnerHaugsengKock:2021oa" }, .world = 'e' },
    // ── UAB Barcelona (Kock) ──
    .{ .name = "UAB Barcelona (Kock)", .lat = 41.5006, .lng = 2.1094,
       .bib_keys = &.{ "GepnerHaugsengKock:2021oa" }, .world = 'e' },
    // ── Lund (Astrom) ──
    .{ .name = "Lund University (Astrom)", .lat = 55.7127, .lng = 13.2100,
       .bib_keys = &.{ "Aastrom.Wittenmark:2013a" }, .world = 'd' },
    // ── Leicester (Abbott containers) ──
    .{ .name = "University of Leicester (Abbott)", .lat = 52.6219, .lng = -1.1253,
       .bib_keys = &.{ "abbot2003categoriesthesis", "abbott2003categories" }, .world = 'd' },
    // ── Nottingham (Altenkirch) ──
    .{ .name = "University of Nottingham (Altenkirch)", .lat = 52.9388, .lng = -1.1966,
       .bib_keys = &.{ "abbott2003categories", "abbott2005containers" }, .world = 'd' },
    // ── Topos Institute (Spivak, Aberle) ──
    .{ .name = "Topos Institute, Berkeley", .lat = 37.8717, .lng = -122.2597,
       .bib_keys = &.{ "aberle2024polynomial" }, .world = 'd' },
    // ── Pisa (Bonchi, Zanasi — string diagrams) ──
    .{ .name = "University of Pisa (Bonchi)", .lat = 43.7228, .lng = 10.4017,
       .bib_keys = &.{ "BonchiEtAl22", "Abramsky:1996a" }, .world = 'o' },
    // ── Tallinn/IOCL (Di Lavore — monoidal streams) ──
    .{ .name = "Tallinn Univ of Technology", .lat = 59.3953, .lng = 24.6713,
       .bib_keys = &.{ "DiLavoreEtAl22" }, .world = 'o' },
    // ── Birmingham (de Paiva) ──
    .{ .name = "University of Birmingham (de Paiva)", .lat = 52.4508, .lng = -1.9305,
       .bib_keys = &.{ "depaiva1991", "depaiva1996", "depaiva2007" }, .world = 'v' },
    // ── Amsterdam (Dialectica Lambek colloquium) ──
    .{ .name = "University of Amsterdam", .lat = 52.3563, .lng = 4.9553,
       .bib_keys = &.{ "depaiva1991" }, .world = 'v' },
    // ── McGill (Lambek) ──
    .{ .name = "McGill University (Lambek)", .lat = 45.5048, .lng = -73.5772,
       .bib_keys = &.{ "lambek1988" }, .world = 'v' },
    // ── ENS Lyon (Gimenez) ──
    .{ .name = "ENS Lyon (Gimenez)", .lat = 45.7296, .lng = 4.8272,
       .bib_keys = &.{ "gimenez:recursion" }, .world = 'v' },
    // ── Stanford (Aczel — non-well-founded sets) ──
    .{ .name = "Stanford CSLI (Aczel)", .lat = 37.4275, .lng = -122.1697,
       .bib_keys = &.{ "aczel:afa", "aczel:rrs" }, .world = 'v' },
    // ── UPenn (Scedrov) ──
    .{ .name = "UPenn (Scedrov)", .lat = 39.9522, .lng = -75.1932,
       .bib_keys = &.{ "scedrov:ist", "scedrov:forcing" }, .world = 'v' },
    // ── Darmstadt (Streicher) ──
    .{ .name = "TU Darmstadt (Streicher)", .lat = 49.8779, .lng = 8.6542,
       .bib_keys = &.{ "streicher:semtt", "lafont1991" }, .world = 'v' },
    // ── Queen Mary London (Hyland) ──
    .{ .name = "DPMMS Cambridge (Hyland)", .lat = 52.2043, .lng = 0.1157,
       .bib_keys = &.{ "hyland2002" }, .world = 'v' },
    // ── ITU Copenhagen (Biering) ──
    .{ .name = "ITU Copenhagen (Biering)", .lat = 55.6596, .lng = 12.5912,
       .bib_keys = &.{ "biering2008" }, .world = 'v' },
    // ── Queen Mary London (Oliva) ──
    .{ .name = "Queen Mary Univ London (Oliva)", .lat = 51.5233, .lng = -0.0418,
       .bib_keys = &.{ "oliva2014" }, .world = 'v' },
    // ── Grandis/Pare — Genova/Dalhousie ──
    .{ .name = "Universita di Genova (Grandis)", .lat = 44.4133, .lng = 8.9625,
       .bib_keys = &.{ "GrandisPare2004:ad" }, .world = 'e' },
    .{ .name = "Dalhousie University (Pare)", .lat = 44.6366, .lng = -63.5917,
       .bib_keys = &.{ "GrandisPare2004:ad" }, .world = 'e' },
    // ── Fritz (Innsbruck — Markov categories) ──
    .{ .name = "Univ of Innsbruck (Fritz)", .lat = 47.2633, .lng = 11.3861,
       .bib_keys = &.{ "FritzLiang23" }, .world = 'o' },
    // ── Vanderbilt (Bohmann — spectra) ──
    .{ .name = "Vanderbilt University (Bohmann)", .lat = 36.1447, .lng = -86.8027,
       .bib_keys = &.{ "bohmann:globalspectra" }, .world = 'v' },
    // ── Peter Henry (UWO) ──
    .{ .name = "Western Ontario (Henry)", .lat = 43.0096, .lng = -81.2737,
       .bib_keys = &.{ "Henry:2020lm" }, .world = 'e' },
    // ── Anel/Lejay (CMU/Paris) ──
    .{ .name = "CMU (Anel)", .lat = 40.4433, .lng = -79.9436,
       .bib_keys = &.{ "AnelLejay:2018eh" }, .world = 'e' },
    // ── PIXEL LAST SEEN ──
    .{ .name = "** PIXEL 10 PRO FOLD (last seen) **", .lat = 37.4276, .lng = -122.1407,
       .bib_keys = &.{ "mantissa_phone_2026" }, .world = 'y' },
    // ── InterContinental SF (current position) ──
    .{ .name = "** YOU: InterContinental SF 8F **", .lat = 37.7835, .lng = -122.4028,
       .bib_keys = &.{ "current_position_2026" }, .world = 'y' },
};

pub fn main() !void {
    const p = std.debug.print;

    p("\n", .{});
    p("╔══════════════════════════════════════════════════════════════════════════════════════╗\n", .{});
    p("║  BIBLIOGRAPHY x OLC: All .bib references across worlds/, geocoded                  ║\n", .{});
    p("║  {d} institutions / author locations mapped to Plus Codes                         ║\n", .{institutions.len});
    p("╚══════════════════════════════════════════════════════════════════════════════════════╝\n", .{});

    p("\n  OLC              Trit  World  Institution                              Keys\n", .{});
    p("  ───────────────  ────  ─────  ─────────────────────────────────────────  ────────────\n", .{});

    var buf: [20]u8 = undefined;
    var trit_counts = [3]u32{ 0, 0, 0 };

    for (institutions) |inst| {
        const len = encode(inst.lat, inst.lng, 10, &buf) catch continue;
        const code = buf[0..len];
        const trit = codeTrit(code);
        trit_counts[@intCast(@as(i32, trit) + 1)] += 1;

        // Print first key, truncated
        const first_key = if (inst.bib_keys.len > 0) inst.bib_keys[0] else "???";
        const key_suffix: []const u8 = if (inst.bib_keys.len > 1) " ..." else "";

        p("  {s}  [{c}]   {c}      {s: <40} {s}{s}\n", .{
            code, tritSymbol(trit), inst.world, inst.name, first_key, key_suffix,
        });
    }

    p("\n  ─────────────────────────────────────────────────────────────────────────────────────\n", .{});
    p("  GF(3) distribution: [-]={d}  [0]={d}  [+]={d}  (total {d})\n", .{
        trit_counts[0], trit_counts[1], trit_counts[2],
        trit_counts[0] + trit_counts[1] + trit_counts[2],
    });

    p("\n── BIB FILES BY WORLD ──────────────────────────────────────────────────────────────\n\n", .{});

    const BibFile = struct { world: u8, path: []const u8, entries: u16 };
    const bib_files = [_]BibFile{
        .{ .world = 'd', .path = "d/poly-structures/Library20250509.bib", .entries = 500 },
        .{ .world = 'd', .path = "d/dependent-types/Library20240927.bib", .entries = 300 },
        .{ .world = 'd', .path = "d/concordia/CITATION.bib", .entries = 1 },
        .{ .world = 'e', .path = "e/infinity-cosmos/blueprint/src/RVbiblio.bib", .entries = 50 },
        .{ .world = 'o', .path = "o/discopy/docs/discopy.bib", .entries = 80 },
        .{ .world = 'v', .path = "v/CatTheory4All/references.bib", .entries = 2 },
        .{ .world = 'v', .path = "v/basictex/all.bib", .entries = 400 },
        .{ .world = 'v', .path = "v/dialecticaLambek/references.bib", .entries = 20 },
        .{ .world = 'v', .path = "v/ConstructiveModalLogic/.../references.bib", .entries = 15 },
        .{ .world = 'v', .path = "v/Encyclopedia/Source/bibliographies/*.bib", .entries = 2000 },
    };

    for (bib_files) |bf| {
        p("  [{c}]  ~{d:>4} entries  {s}\n", .{ bf.world, bf.entries, bf.path });
    }

    p("\n  Total estimated entries: ~3,368 across 4 letter-worlds (d, e, o, v)\n", .{});

    p("\n── GEOGRAPHIC CLUSTERS ─────────────────────────────────────────────────────────────\n\n", .{});

    const Cluster = struct { name: []const u8, count: u8, region: []const u8 };
    const clusters = [_]Cluster{
        .{ .name = "UK (Cambridge/Oxford/London/Birmingham/Leicester/Nottingham)", .count = 8, .region = "9C2-9C4" },
        .{ .name = "Scandinavia (Lund/Trondheim/Copenhagen)", .count = 3, .region = "9F6-9GC" },
        .{ .name = "Central Europe (Darmstadt/Innsbruck)", .count = 2, .region = "8FW-9F2" },
        .{ .name = "Mediterranean (Pisa/Genova/Barcelona)", .count = 3, .region = "8FG-8FQ" },
        .{ .name = "Baltics (Tallinn)", .count = 2, .region = "9GFG" },
        .{ .name = "Bay Area (Topos/Stanford/Pixel)", .count = 3, .region = "849V" },
        .{ .name = "East Coast NA (JHU/UPenn/CMU/Vanderbilt)", .count = 4, .region = "87F-87G" },
        .{ .name = "Canada (McGill/Dalhousie/Western)", .count = 3, .region = "87PM-87QM" },
        .{ .name = "France (ENS Lyon)", .count = 1, .region = "8FQ6" },
        .{ .name = "Netherlands (Amsterdam)", .count = 1, .region = "9F46" },
        .{ .name = "Australia (Macquarie)", .count = 1, .region = "4RRH" },
    };

    for (clusters) |cl| {
        p("  {s: <60}  {d:>2} sites  OLC prefix {s}\n", .{ cl.name, cl.count, cl.region });
    }

    p("\n── SIMPLEX: YOU → PIXEL → STANFORD CSLI (Aczel) ─────────────────────────────────\n\n", .{});

    // Triangle: InterContinental SF → Pixel last seen → Stanford CSLI
    const v0_lat: f64 = 37.7835;
    const v0_lng: f64 = -122.4028;
    const v1_lat: f64 = 37.4276;
    const v1_lng: f64 = -122.1407;
    const v2_lat: f64 = 37.4275;
    const v2_lng: f64 = -122.1697;

    const points = [_]struct { name: []const u8, lat: f64, lng: f64 }{
        .{ .name = "YOU (InterContinental SF)", .lat = v0_lat, .lng = v0_lng },
        .{ .name = "PIXEL (triangulated)",      .lat = v1_lat, .lng = v1_lng },
        .{ .name = "Stanford CSLI (Aczel)",     .lat = v2_lat, .lng = v2_lng },
    };

    for (points) |pt| {
        const len = encode(pt.lat, pt.lng, 10, &buf) catch continue;
        const trit = codeTrit(buf[0..len]);
        p("  {s}  {s: <30}  [{c}]\n", .{ buf[0..len], pt.name, tritSymbol(trit) });
    }

    // Distance from Pixel to Stanford CSLI
    const dlat = (v1_lat - v2_lat) * std.math.pi / 180.0;
    const dlng = (v1_lng - v2_lng) * std.math.pi / 180.0;
    const a = std.math.sin(dlat / 2.0) * std.math.sin(dlat / 2.0) +
        std.math.cos(v1_lat * std.math.pi / 180.0) * std.math.cos(v2_lat * std.math.pi / 180.0) *
        std.math.sin(dlng / 2.0) * std.math.sin(dlng / 2.0);
    const d = 6371000.0 * 2.0 * std.math.atan2(std.math.sqrt(a), std.math.sqrt(1.0 - a));

    p("\n  PIXEL → Stanford CSLI: {d:.0}m ({d:.2} km)\n", .{ d, d / 1000.0 });
    p("  Aczel's Non-well-founded Sets published from CSLI, Stanford, CA\n", .{});
    p("  — same OLC prefix 849V as the Pixel's last position\n", .{});

    p("\n══════════════════════════════════════════════════════════════════════════════════════\n", .{});
}
