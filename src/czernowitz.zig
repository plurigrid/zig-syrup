//! Czernowitz / Chernivtsi: All location codes now or ever associated
//!
//! A city at the crossroads of empires — Habsburg, Romanian, Soviet, Ukrainian —
//! each administration layering its own names, codes, and coordinate systems.
//! This module captures them all as comptime data with OLC integration.
//!
//! Coordinates: 48.2920°N, 25.9358°E (city center, Tsentralna Ploshcha)

const std = @import("std");
const geo = @import("geo");
const syrup = @import("syrup");
const Allocator = std.mem.Allocator;
const Value = syrup.Value;

// ============================================================================
// CITY CENTER
// ============================================================================

/// City center coordinate (Tsentralna Ploshcha / Central Square)
pub const center = geo.Coordinate.init(48.2920, 25.9358);

/// Airport coordinate (Chernivtsi International)
pub const airport = geo.Coordinate.init(48.2593, 25.9808);

// ============================================================================
// NAMES ACROSS ADMINISTRATIONS
// ============================================================================

pub const Name = struct {
    language: []const u8,
    name: []const u8,
    script: ?[]const u8 = null,
    period: ?[]const u8 = null,
};

pub const names = [_]Name{
    .{ .language = "uk", .name = "Чернівці", .script = "Cyrillic", .period = "1991-present" },
    .{ .language = "de", .name = "Czernowitz", .period = "1775-1918" },
    .{ .language = "ro", .name = "Cernăuți", .period = "1918-1940, 1941-1944" },
    .{ .language = "ru", .name = "Черновцы", .script = "Cyrillic", .period = "1944-1991" },
    .{ .language = "pl", .name = "Czerniowce" },
    .{ .language = "hu", .name = "Csernovic" },
    .{ .language = "yi", .name = "טשערנאָוויץ", .script = "Hebrew", .period = "historical" },
    .{ .language = "la", .name = "Czernovicium", .period = "archival" },
};

// ============================================================================
// SOVEREIGNTY TIMELINE
// ============================================================================

pub const Sovereignty = struct {
    period: []const u8,
    sovereign: []const u8,
    name_used: []const u8,
    code_system: []const u8,
};

pub const sovereignty_timeline = [_]Sovereignty{
    .{ .period = "pre-1775", .sovereign = "Moldavia", .name_used = "Cernăuți", .code_system = "none" },
    .{ .period = "1775-1918", .sovereign = "Habsburg / Austria-Hungary", .name_used = "Czernowitz", .code_system = "crownland+bezirk" },
    .{ .period = "1918-1940", .sovereign = "Romania", .name_used = "Cernăuți", .code_system = "județ" },
    .{ .period = "1940-1941", .sovereign = "Soviet Union", .name_used = "Черновцы", .code_system = "SOATO" },
    .{ .period = "1941-1944", .sovereign = "Romania", .name_used = "Cernăuți", .code_system = "guvernamant" },
    .{ .period = "1944-1991", .sovereign = "Soviet Union (Ukrainian SSR)", .name_used = "Черновцы", .code_system = "SOATO" },
    .{ .period = "1991-present", .sovereign = "Ukraine", .name_used = "Чернівці", .code_system = "KOATUU/KATOTTG/ISO" },
};

// ============================================================================
// STANDARD CODES
// ============================================================================

/// ISO 3166-2 oblast code
pub const iso_3166_2 = "UA-77";

/// UN/LOCODE
pub const un_locode = "UA CWC";

/// IATA airport code
pub const iata = "CWC";

/// ICAO airport code
pub const icao = "UKLN";

/// Main postal code
pub const postal_code = "58000";

/// Postal code range (city)
pub const postal_range = .{ .start = 58000, .end = 58499 };

/// Postal code range (oblast)
pub const postal_range_oblast = .{ .start = 58000, .end = 60499 };

/// International dialing
pub const phone_code = "+380 372";

/// KOATUU city code (deprecated 2020)
pub const koatuu = "7310100000";

/// KOATUU oblast prefix
pub const koatuu_oblast = "73";

/// KATOTTG city code (since 2020)
pub const katottg = "UA73060610010033137";

/// GeoNames ID
pub const geonames_id = 710719;

/// Wikidata ID (city)
pub const wikidata_city = "Q157725";

/// Wikidata ID (oblast)
pub const wikidata_oblast = "Q168856";

/// FIPS 10-4 / GEC (oblast)
pub const fips = "UP04";

/// HASC (oblast)
pub const hasc = "UA.CV";

/// License plate code (oblast)
pub const license_plate = "CE";

/// OpenStreetMap node ID (city point)
pub const osm_node = 337594677;

/// OpenStreetMap relation ID (city boundary)
pub const osm_relation = 1742393;

/// OpenStreetMap relation ID (oblast)
pub const osm_relation_oblast = 72526;

// ============================================================================
// HABSBURG-ERA ADMINISTRATIVE UNITS
// ============================================================================

pub const HabsburgPeriod = struct {
    period: []const u8,
    unit: []const u8,
    status: []const u8,
};

pub const habsburg = [_]HabsburgPeriod{
    .{ .period = "1775-1786", .unit = "Bukowiner Kreis, Kingdom of Galicia and Lodomeria", .status = "Kreis" },
    .{ .period = "1786-1849", .unit = "Czernowitzer Kreis, Kingdom of Galicia and Lodomeria", .status = "District capital" },
    .{ .period = "1849-1918", .unit = "Herzogtum Bukowina (Duchy of Bukovina)", .status = "Crownland capital" },
};

// ============================================================================
// KALINOVSKI RYNOK (KALINKA BAZAAR)
// ============================================================================
//
// КП МТК "Калинівський ринок" — founded 1990-06-19
// 39.2 hectares, ~10,000 trading units, ~20,000 entrepreneurs
// One of four largest markets in Ukraine (with 7th Km, Barabashovo, Troieshchyna)
// Uniquely publicly owned by the Chernivtsi territorial community
// Open: Tue-Sun 06:00-14:00, closed Mondays
// vul. Kalynivska, 13-A, Chernivtsi, 58020
// EDRPOU: 22849693

/// Kalinka market center coordinate (Stara Zhuchka district, left-bank Prut)
pub const kalinka = geo.Coordinate.init(48.285, 25.905);

/// Market postal code
pub const kalinka_postal = "58020";

/// GF(3) trit classification for market speculator archetypes
/// Maps bazaar trader roles to bmorphism repo correspondences
pub const Trit = enum(i2) {
    minus = -1, // validators / shuttle traders who verify goods at source
    zero = 0, // arbitrageurs / stall holders who provide liquidity
    plus = 1, // speculators / scouts who bet on new goods & routes
};

/// A market speculator archetype mapped to a bmorphism repo
pub const Speculator = struct {
    /// Bazaar role (Kalinka trader archetype)
    role: []const u8,
    /// Ukrainian colloquial term
    term_uk: []const u8,
    /// What they do at the market
    activity: []const u8,
    /// GF(3) trit classification
    trit: Trit,
    /// Corresponding bmorphism repo (GitHub)
    repo: []const u8,
    /// Why this repo corresponds to this speculator type
    correspondence: []const u8,
    /// Literary source documenting this archetype
    literary_source: []const u8,
};

/// Kalinovski Rynok speculator archetypes ↔ bmorphism repos
///
/// The mapping follows the tripartite market structure from protocol-evolution-markets:
///   MINUS (-1) = Validators: verify, check compliance, short failing specs
///   ZERO  ( 0) = Arbitrageurs: provide liquidity, balance, hedge
///   PLUS  (+1) = Speculators: bet on new features, fund development, long innovation
pub const speculators = [_]Speculator{
    // ── MINUS (-1): Validators / Source Verifiers ──────────────────────
    .{
        .role = "Shuttle Trader (Chelnok)",
        .term_uk = "човник",
        .activity = "Travels to Istanbul/Bucharest to source goods, verifies quality at origin",
        .trit = .minus,
        .repo = "bmorphism/ocaml-mcp-sdk",
        .correspondence = "Type-safe protocol verification at the source — OCaml's type system validates before anything crosses the border",
        .literary_source = "Zhadan, Depeche Mode (2004): Vasia the Communist's cross-border vodka arbitrage in Belgorod; Karpa, Good and Evil (2008): autobiographical — parents shuttled to Yugoslavia/China, she sold deodorants at trolleybus stops",
    },
    .{
        .role = "Customs Broker",
        .term_uk = "митник",
        .activity = "Navigates border regulations, ensures paperwork compliance",
        .trit = .minus,
        .repo = "bmorphism/anti-bullshit-mcp-server",
        .correspondence = "Filters contraband claims from legitimate ones — the compliance layer that rejects what doesn't pass inspection",
        .literary_source = "Andrukhovych, The Moscoviad (1993): Otto von F. navigating Moscow's underground of 'giant rats, masked patriots' — the picaresque of survival at border crossings between legal and illegal",
    },
    .{
        .role = "Quality Inspector",
        .term_uk = "перевірник",
        .activity = "Tests fabrics, checks stitching, spots counterfeits",
        .trit = .minus,
        .repo = "bmorphism/syrup-verify",
        .correspondence = "Content-addressable verification — every item gets a deterministic hash, counterfeits fail the CID check",
        .literary_source = "Poderviansky, Snobs (Сноби): absurdist micro-plays in surzhyk where 'self-made intellectuals spout scientific-sounding nonsense' — the quality inspector as comic figure who mistakes counterfeit for authentic",
    },

    // ── ZERO (0): Arbitrageurs / Liquidity Providers ──────────────────
    .{
        .role = "Stall Holder",
        .term_uk = "продавець",
        .activity = "Maintains permanent kiosk, provides consistent daily supply",
        .trit = .zero,
        .repo = "bmorphism/babashka-mcp-server",
        .correspondence = "Reliable infrastructure that's always there — the permanent stall that connects producers to buyers via scripting",
        .literary_source = "Zhadan, Voroshilovgrad (2010): Herman's gas station as permanent stall — Kocha the smalltime gangster and Traumatized the ex-footballer defend their kiosk against oligarchic encroachment by Pastushok",
    },
    .{
        .role = "Currency Exchanger",
        .term_uk = "валютник",
        .activity = "Converts hryvnia/lei/euro/dollars at market rates, provides liquidity",
        .trit = .zero,
        .repo = "bmorphism/Gay.jl",
        .correspondence = "Color space conversion as currency exchange — maps between gamuts like the valutnik maps between currencies",
        .literary_source = "Zhadan interview, Lyuk Media: described 1990s Kharkiv as 'times of crisis with currency exchange points, bootleg alcohol, crime' (часи кризи з обмінниками валют, паленим алкоголем, криміналом)",
    },
    .{
        .role = "Porter/Carrier",
        .term_uk = "вантажник",
        .activity = "Moves goods between sectors, loads/unloads trucks at dawn",
        .trit = .zero,
        .repo = "bmorphism/nats-mcp-server",
        .correspondence = "Message transport layer — moves payloads between sectors without caring about contents, pure logistics",
        .literary_source = "Zhadan, The Orphanage/Internat (2017): Pasha the teacher carrying his nephew through the warzone — the porter archetype literalized as 'a Dantesque journey through hell', hungry, thirsty, carrying what matters",
    },
    .{
        .role = "Row Boss",
        .term_uk = "рядовий",
        .activity = "Organizes a row of stalls, mediates disputes, sets sector norms",
        .trit = .zero,
        .repo = "bmorphism/awesome-applied-category-theory",
        .correspondence = "The index that organizes everything into coherent rows — categorical structure for the bazaar's topology",
        .literary_source = "Meridian Czernowitz III (2012): poets read between stalls at Kalynivsky market — Zabuzhko read 'Russian Motif', vendor Anna gifted her raspberries; Pomerantsev bought black socks; the row boss is the festival organizer imposing literary order on bazaar chaos",
    },

    // ── PLUS (+1): Speculators / Innovation Scouts ────────────────────
    .{
        .role = "Trend Scout",
        .term_uk = "розвідник",
        .activity = "Travels ahead to spot next season's fashions, bets on new goods",
        .trit = .plus,
        .repo = "bmorphism/manifold-mcp-server",
        .correspondence = "Prediction markets for what will sell — the scout who bets real money on which trends cross the border next",
        .literary_source = "Andrukhovych, Perverzion (1996): Perfetsky at Venice conference 'Post-Carnival Absurdity of the World: What is on the Horizon?' — the Ukrainian intellectual as cultural trend scout mapping trade routes between East and West",
    },
    .{
        .role = "Container Speculator",
        .term_uk = "контейнерник",
        .activity = "Buys container lots sight-unseen, gambles on contents",
        .trit = .plus,
        .repo = "bmorphism/multiverse-color-game",
        .correspondence = "Holographic multiverse betting — you open the container and collapse the wavefunction of what's inside",
        .literary_source = "Malyarchuk, Biography of a Chance Miracle (2012): 'In 1996 everything went to pieces and San Francisco sank into the black waters of the free market' — the container as sealed fate, opened only by chance miracle",
    },
    .{
        .role = "Route Pioneer",
        .term_uk = "першопрохідець",
        .activity = "Opens new supply routes (China, Vietnam) before others discover them",
        .trit = .plus,
        .repo = "bmorphism/penrose-mcp",
        .correspondence = "Diagrammatic reasoning to find paths nobody else sees — the geometric intuition that discovers new trade routes",
        .literary_source = "Zhadan, Anarchy in the UKR (2005): following Makhno's anarchist routes through Donbas — 'constantly on the move, on trains or through bizarre landscapes' — the route pioneer as nomad seeking 'what is will-freedom-anarchy?'",
    },
    .{
        .role = "Wholesale Buyer",
        .term_uk = "оптовик",
        .activity = "Buys in bulk from shuttlers, redistributes to smaller markets across Bukovina",
        .trit = .plus,
        .repo = "bmorphism/say-mcp-server",
        .correspondence = "Amplification and broadcast — takes a single voice/signal and distributes it across the entire network",
        .literary_source = "Zhadan, Depeche Mode (2004): Vakha the Georgian wholesaler who keeps 'chocolates, colas, heroin, and other lollipops' in a room, pays off police, sells undiluted vodka — the fixed-point distributor who amplifies supply across the network",
    },

    // ── ZIG-NATIVE ROLES (bmorphism Zig repos) ───────────────────────
    .{
        .role = "Display Board Operator",
        .term_uk = "табличник",
        .activity = "Writes prices on the big board at sector entrance, updates exchange rates, renders the bazaar's state",
        .trit = .zero,
        .repo = "bmorphism/trittty",
        .correspondence = "Ghostty fork with 497 Zig files — the terminal emulator IS the display board; every speculator's prices render through this layer",
        .literary_source = "Pomerantsev, Chernivtsi Palimpsest (2022): recalled visiting the central market as a six-year-old hearing 'extraordinary conversations in a mixture of Yiddish and the Hutsul dialect' — the display board makes the polyglot bazaar legible",
    },
    .{
        .role = "Reseller/Flipper",
        .term_uk = "перекупник",
        .activity = "Buys from one stall, walks three rows, sells at markup — AI-assisted spatial arbitrage across the bazaar topology",
        .trit = .plus,
        .repo = "bmorphism/duck-rs",
        .correspondence = "Polyglot repo (15MB Zig + Rust + C++) with embedded ghostty traces and Codex CLI — the AI agent that autonomously navigates bazaar topology to find price differentials",
        .literary_source = "Zabuzhko, Museum of Abandoned Secrets (2009): 'the world is no longer run by elected governments but by corporations' — the перекупник is the micro-scale version, an autonomous agent exploiting information asymmetry between rows",
    },
};

/// Count speculators by trit
pub fn countByTrit(trit: Trit) usize {
    var count: usize = 0;
    for (speculators) |s| {
        if (s.trit == trit) count += 1;
    }
    return count;
}

/// Encode Kalinka market to Plus Code
pub fn encodeKalinkaPlusCode(buffer: []u8) geo.OlcError!usize {
    return geo.encodeOlc(kalinka.latitude, kalinka.longitude, 10, buffer);
}

/// Serialize speculators as Syrup list of records
pub fn speculatorsToSyrup(allocator: Allocator) !Value {
    const items = try allocator.alloc(Value, speculators.len);
    for (speculators, 0..) |s, i| {
        const label_alloc = try allocator.alloc(Value, 1);
        label_alloc[0] = Value.fromSymbol("kalinka:speculator");

        const sfields = try allocator.alloc(Value, 6);
        sfields[0] = Value.fromString(s.role);
        sfields[1] = Value.fromString(s.term_uk);
        sfields[2] = Value.fromInteger(@as(i64, @intCast(@intFromEnum(s.trit))));
        sfields[3] = Value.fromString(s.repo);
        sfields[4] = Value.fromString(s.correspondence);
        sfields[5] = Value.fromString(s.literary_source);

        items[i] = Value.fromRecord(&label_alloc[0], sfields);
    }
    return Value.fromList(items);
}

// ============================================================================
// ROAD SYSTEMS
// ============================================================================

pub const Road = struct {
    ref_code: []const u8,
    name_uk: []const u8,
    classification: []const u8,
    distance_km: ?f32 = null,
    destination: []const u8,
};

/// International, national, regional, and territorial roads through Chernivtsi
pub const roads = [_]Road{
    // International
    .{
        .ref_code = "E 85",
        .name_uk = "Європейський автошлях E 85",
        .classification = "e-road",
        .destination = "Klaipeda (LT) ↔ Alexandroupoli (GR)",
    },
    // National
    .{
        .ref_code = "М-19",
        .name_uk = "Доманове – Ковель – Чернівці – Тереблече",
        .classification = "national",
        .distance_km = 534.1,
        .destination = "Bucharest (via Terebleche border)",
    },
    .{
        .ref_code = "Н-10",
        .name_uk = "Стрий – Івано-Франківськ – Чернівці – Мамалига",
        .classification = "national",
        .distance_km = 269.3,
        .destination = "Chisinau (via Mamalyga border)",
    },
    // Regional
    .{
        .ref_code = "Р-62",
        .name_uk = "Криворівня – Усть-Путила – Вижниця – Сторожинець – Чернівці",
        .classification = "regional",
        .distance_km = 111.1,
        .destination = "Kryvorivnia (Carpathian highlands)",
    },
    // Territorial
    .{
        .ref_code = "Т-26-01",
        .name_uk = "через Вашківці – Путила",
        .classification = "territorial",
        .distance_km = 120.3,
        .destination = "Vashkivtsi / Putyla",
    },
    .{
        .ref_code = "Т-26-02",
        .name_uk = "Чернівці – Заставна – М-19",
        .classification = "territorial",
        .distance_km = 26.8,
        .destination = "Zastavna (M-19 junction)",
    },
    .{
        .ref_code = "Т-26-03",
        .name_uk = "Чернівці – Недобоївці – Хотин",
        .classification = "territorial",
        .distance_km = 38.6,
        .destination = "Khotyn fortress",
    },
    .{
        .ref_code = "Т-26-04",
        .name_uk = "Чернівці – Герца – КПП Дяківці",
        .classification = "territorial",
        .distance_km = 32.0,
        .destination = "Romania (Hertsa border crossing)",
    },
};

/// Shuttle trader (човник) corridors from Kalinka bazaar, each along a road
pub const TradeRoute = struct {
    direction: []const u8,
    road_ref: []const u8,
    destination: []const u8,
    speculator: []const u8,
    goods: []const u8,
};

pub const trade_routes = [_]TradeRoute{
    .{
        .direction = "south",
        .road_ref = "Т-26-04/E85/М-19",
        .destination = "Bucharest → Istanbul Sirkeci",
        .speculator = "човник",
        .goods = "Turkish clothing, shoes, leather goods",
    },
    .{
        .direction = "west",
        .road_ref = "Н-10",
        .destination = "Ivano-Frankivsk → Przemysl/Rzeszow (PL)",
        .speculator = "човник",
        .goods = "Polish electronics, cosmetics, household goods",
    },
    .{
        .direction = "east",
        .road_ref = "Н-10",
        .destination = "Mamalyga → Chisinau (MD)",
        .speculator = "оптовик",
        .goods = "Bulk redistribution, wholesale lots",
    },
    .{
        .direction = "north",
        .road_ref = "М-19",
        .destination = "Kovel → Kyiv (Troieshchyna market)",
        .speculator = "оптовик",
        .goods = "Domestic redistribution across Bukovina",
    },
    .{
        .direction = "mountain",
        .road_ref = "Р-62",
        .destination = "Storozhynets → Vyzhnytsia → Kryvorivnia",
        .speculator = "вантажник",
        .goods = "Hutsul cheese, wool, mushrooms, herbs",
    },
};

/// Habsburg-era German street names still present in OSM data
pub const PalimpsestStreet = struct {
    name_uk: []const u8,
    name_de: []const u8,
    meaning: []const u8,
};

pub const palimpsest_streets = [_]PalimpsestStreet{
    .{ .name_uk = "Центральна площа", .name_de = "Ringplatz", .meaning = "Ring Square" },
    .{ .name_uk = "Соборна площа", .name_de = "Austria-Platz", .meaning = "Austria Square" },
    .{ .name_uk = "Головна вулиця", .name_de = "Siebenbürger Straße", .meaning = "Transylvanian Road" },
    .{ .name_uk = "Руська вулиця", .name_de = "Russische Gasse", .meaning = "Russian Lane" },
    .{ .name_uk = "вул. Шолом-Алейхема", .name_de = "Judengasse", .meaning = "Jewish Lane" },
    .{ .name_uk = "Вірменська вулиця", .name_de = "Armenier-Gasse", .meaning = "Armenian Lane" },
    .{ .name_uk = "Вокзальна вулиця", .name_de = "Bahnhofstraße", .meaning = "Station Street" },
    .{ .name_uk = "Університетська вулиця", .name_de = "Residenzgasse", .meaning = "Residence Lane" },
    .{ .name_uk = "вул. Івана Франка", .name_de = "Liliengasse", .meaning = "Lily Lane" },
    .{ .name_uk = "Садова вулиця", .name_de = "Erzherzog-Eugen-Gasse", .meaning = "Archduke Eugene Lane" },
    .{ .name_uk = "вул. Тараса Шевченка", .name_de = "Neue-Welt-Gasse", .meaning = "New World Lane" },
    .{ .name_uk = "вул. Лук'яна Кобилиці", .name_de = "Brauhaus-Gasse", .meaning = "Brewery Lane" },
    .{ .name_uk = "Шкільна вулиця", .name_de = "Schulgasse", .meaning = "School Lane" },
    .{ .name_uk = "Кафедральна вулиця", .name_de = "Kathedralgasse", .meaning = "Cathedral Lane" },
    .{ .name_uk = "Сучавська вулиця", .name_de = "Färber-Gasse", .meaning = "Dyers' Lane" },
    .{ .name_uk = "вул. Андрея Шептицького", .name_de = "Landhaus Gasse", .meaning = "Country House Lane" },
    .{ .name_uk = "вул. Лесі Українки", .name_de = "Jubiläumsallee", .meaning = "Jubilee Avenue" },
    .{ .name_uk = "вул. Йозефа Главки", .name_de = "Dominik-Gasse", .meaning = "Dominic Lane" },
    .{ .name_uk = "вул. Михайла Коцюбинського", .name_de = "Priestergasse", .meaning = "Priest Lane" },
    .{ .name_uk = "Сторожинецька вулиця", .name_de = "Starosynetzer Str.", .meaning = "Storozhynets Road" },
};

// ============================================================================
// OLC / PLUS CODE ENCODING
// ============================================================================

/// Encode city center to Plus Code at default (10-char) resolution
/// Returns "8GW77WRP+R8" or similar for 48.2920, 25.9358
pub fn encodeCenterPlusCode(buffer: []u8) geo.OlcError!usize {
    return geo.encodeOlc(center.latitude, center.longitude, 10, buffer);
}

/// Encode airport to Plus Code
pub fn encodeAirportPlusCode(buffer: []u8) geo.OlcError!usize {
    return geo.encodeOlc(airport.latitude, airport.longitude, 10, buffer);
}

/// Encode city center at specified precision
pub fn encodeCenterAtPrecision(code_length: u8, buffer: []u8) geo.OlcError!usize {
    return geo.encodeOlc(center.latitude, center.longitude, code_length, buffer);
}

// ============================================================================
// SYRUP SERIALIZATION
// ============================================================================

/// Serialize all Czernowitz codes as a Syrup record
pub fn toSyrup(allocator: Allocator) !Value {
    const label_alloc = try allocator.alloc(Value, 1);
    label_alloc[0] = Value.fromSymbol("geo:czernowitz");

    const fields = try allocator.alloc(Value, 12);
    fields[0] = Value.fromFloat(center.latitude);
    fields[1] = Value.fromFloat(center.longitude);
    fields[2] = Value.fromString(iso_3166_2);
    fields[3] = Value.fromString(un_locode);
    fields[4] = Value.fromString(iata);
    fields[5] = Value.fromString(icao);
    fields[6] = Value.fromString(postal_code);
    fields[7] = Value.fromString(koatuu);
    fields[8] = Value.fromString(katottg);
    fields[9] = Value.fromString(wikidata_city);
    fields[10] = Value.fromInteger(geonames_id);
    fields[11] = Value.fromString(fips);

    return Value.fromRecord(&label_alloc[0], fields);
}

/// Serialize sovereignty timeline as Syrup list
pub fn sovereigntyToSyrup(allocator: Allocator) !Value {
    const items = try allocator.alloc(Value, sovereignty_timeline.len);
    for (sovereignty_timeline, 0..) |s, i| {
        const label_alloc = try allocator.alloc(Value, 1);
        label_alloc[0] = Value.fromSymbol("geo:sovereignty");

        const sfields = try allocator.alloc(Value, 4);
        sfields[0] = Value.fromString(s.period);
        sfields[1] = Value.fromString(s.sovereign);
        sfields[2] = Value.fromString(s.name_used);
        sfields[3] = Value.fromString(s.code_system);

        items[i] = Value.fromRecord(&label_alloc[0], sfields);
    }
    return Value.fromList(items);
}

/// Serialize all names as Syrup list
pub fn namesToSyrup(allocator: Allocator) !Value {
    const items = try allocator.alloc(Value, names.len);
    for (names, 0..) |n, i| {
        const label_alloc = try allocator.alloc(Value, 1);
        label_alloc[0] = Value.fromSymbol("geo:toponym");

        const nfields = try allocator.alloc(Value, 2);
        nfields[0] = Value.fromString(n.language);
        nfields[1] = Value.fromString(n.name);

        items[i] = Value.fromRecord(&label_alloc[0], nfields);
    }
    return Value.fromList(items);
}

// ============================================================================
// TESTS
// ============================================================================

test "czernowitz center coordinate" {
    try std.testing.expectApproxEqAbs(center.latitude, 48.2920, 0.0001);
    try std.testing.expectApproxEqAbs(center.longitude, 25.9358, 0.0001);
}

test "czernowitz center plus code" {
    var buf: [32]u8 = undefined;
    const len = try encodeCenterPlusCode(&buf);
    const code = buf[0..len];
    // Should be a valid 10-char Plus Code starting with 8GW7
    try std.testing.expect(len > 0);
    try std.testing.expect(code.len >= 11); // 10 chars + separator
    try std.testing.expect(geo.isValid(code));
    try std.testing.expect(geo.isFullCode(code));

    // Decode back and verify proximity
    const area = try geo.decodeOlc(code);
    try std.testing.expectApproxEqAbs(area.centerLatitude(), 48.2920, 0.01);
    try std.testing.expectApproxEqAbs(area.centerLongitude(), 25.9358, 0.01);
}

test "czernowitz airport plus code" {
    var buf: [32]u8 = undefined;
    const len = try encodeAirportPlusCode(&buf);
    const code = buf[0..len];
    try std.testing.expect(geo.isValid(code));

    const area = try geo.decodeOlc(code);
    try std.testing.expectApproxEqAbs(area.centerLatitude(), 48.2593, 0.01);
    try std.testing.expectApproxEqAbs(area.centerLongitude(), 25.9808, 0.01);
}

test "czernowitz precision levels" {
    var buf: [32]u8 = undefined;

    // 4-char: ~62.5 km resolution
    const len4 = try encodeCenterAtPrecision(4, &buf);
    try std.testing.expect(geo.isValid(buf[0..len4]));

    // 6-char: ~1.5 km
    const len6 = try encodeCenterAtPrecision(6, &buf);
    try std.testing.expect(geo.isValid(buf[0..len6]));

    // 10-char: ~14 m (default)
    const len10 = try encodeCenterAtPrecision(10, &buf);
    try std.testing.expect(geo.isValid(buf[0..len10]));

    // 15-char: ~1.4 cm (max precision)
    const len15 = try encodeCenterAtPrecision(15, &buf);
    try std.testing.expect(len15 > len10);
}

test "czernowitz names count" {
    try std.testing.expectEqual(@as(usize, 8), names.len);
    // Ukrainian is first (current official)
    try std.testing.expectEqualStrings("uk", names[0].language);
    // German second (historical Habsburg)
    try std.testing.expectEqualStrings("de", names[1].language);
}

test "czernowitz sovereignty timeline" {
    try std.testing.expectEqual(@as(usize, 7), sovereignty_timeline.len);
    // Begins with Moldavia
    try std.testing.expectEqualStrings("Moldavia", sovereignty_timeline[0].sovereign);
    // Ends with Ukraine
    try std.testing.expectEqualStrings("Ukraine", sovereignty_timeline[6].sovereign);
}

test "czernowitz standard codes" {
    try std.testing.expectEqualStrings("UA-77", iso_3166_2);
    try std.testing.expectEqualStrings("CWC", iata);
    try std.testing.expectEqualStrings("UKLN", icao);
    try std.testing.expectEqualStrings("58000", postal_code);
    try std.testing.expectEqualStrings("7310100000", koatuu);
    try std.testing.expectEqualStrings("Q157725", wikidata_city);
    try std.testing.expectEqual(@as(u32, 710719), geonames_id);
}

test "czernowitz syrup serialization" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const val = try toSyrup(allocator);
    switch (val) {
        .record => |rec| {
            const label_str = switch (rec.label.*) {
                .symbol => |s| s,
                else => unreachable,
            };
            try std.testing.expectEqualStrings("geo:czernowitz", label_str);
            try std.testing.expectEqual(@as(usize, 12), rec.fields.len);
        },
        else => unreachable,
    }
}

test "czernowitz names syrup" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const val = try namesToSyrup(allocator);
    switch (val) {
        .list => |items| {
            try std.testing.expectEqual(@as(usize, 8), items.len);
        },
        else => unreachable,
    }
}

test "kalinka market coordinate" {
    // Kalinka is south-southwest of city center, near Prut bridge
    try std.testing.expectApproxEqAbs(kalinka.latitude, 48.285, 0.001);
    try std.testing.expectApproxEqAbs(kalinka.longitude, 25.905, 0.001);
    // Market is south of city center
    try std.testing.expect(kalinka.latitude < center.latitude);
}

test "kalinka market plus code" {
    var buf: [32]u8 = undefined;
    const len = try encodeKalinkaPlusCode(&buf);
    const code = buf[0..len];
    try std.testing.expect(geo.isValid(code));
    try std.testing.expect(geo.isFullCode(code));

    const area = try geo.decodeOlc(code);
    try std.testing.expectApproxEqAbs(area.centerLatitude(), 48.285, 0.01);
    try std.testing.expectApproxEqAbs(area.centerLongitude(), 25.905, 0.01);
}

test "speculator triadic balance" {
    // GF(3) balance: the three trit classes should all be populated
    const minus_count = countByTrit(.minus);
    const zero_count = countByTrit(.zero);
    const plus_count = countByTrit(.plus);

    try std.testing.expect(minus_count > 0);
    try std.testing.expect(zero_count > 0);
    try std.testing.expect(plus_count > 0);

    // Total should match array length
    try std.testing.expectEqual(speculators.len, minus_count + zero_count + plus_count);

    // 3 validators, 5 arbitrageurs, 5 speculators = 13 total
    try std.testing.expectEqual(@as(usize, 3), minus_count);
    try std.testing.expectEqual(@as(usize, 5), zero_count);
    try std.testing.expectEqual(@as(usize, 5), plus_count);
}

test "speculator repos are all bmorphism" {
    for (speculators) |s| {
        try std.testing.expect(std.mem.startsWith(u8, s.repo, "bmorphism/"));
    }
}

test "speculator syrup serialization" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const val = try speculatorsToSyrup(allocator);
    switch (val) {
        .list => |items| {
            try std.testing.expectEqual(@as(usize, 13), items.len);
            // First item should be a kalinka:speculator record
            switch (items[0]) {
                .record => |rec| {
                    const label_str = switch (rec.label.*) {
                        .symbol => |s| s,
                        else => unreachable,
                    };
                    try std.testing.expectEqualStrings("kalinka:speculator", label_str);
                    try std.testing.expectEqual(@as(usize, 6), rec.fields.len);
                },
                else => unreachable,
            }
        },
        else => unreachable,
    }
}

test "czernowitz road network" {
    // 8 roads: 1 e-road, 2 national, 1 regional, 4 territorial
    try std.testing.expectEqual(@as(usize, 8), roads.len);
    try std.testing.expectEqualStrings("E 85", roads[0].ref_code);
    try std.testing.expectEqualStrings("e-road", roads[0].classification);
    try std.testing.expectEqualStrings("М-19", roads[1].ref_code);
    try std.testing.expectApproxEqAbs(roads[1].distance_km.?, 534.1, 0.1);
}

test "czernowitz trade routes from kalinka" {
    try std.testing.expectEqual(@as(usize, 5), trade_routes.len);
    // All five cardinal directions covered
    try std.testing.expectEqualStrings("south", trade_routes[0].direction);
    try std.testing.expectEqualStrings("west", trade_routes[1].direction);
    try std.testing.expectEqualStrings("east", trade_routes[2].direction);
    try std.testing.expectEqualStrings("north", trade_routes[3].direction);
    try std.testing.expectEqualStrings("mountain", trade_routes[4].direction);
    // Mountain route carries the вантажник
    try std.testing.expectEqualStrings("вантажник", trade_routes[4].speculator);
}

test "czernowitz palimpsest streets" {
    try std.testing.expectEqual(@as(usize, 20), palimpsest_streets.len);
    // Ringplatz is first (the central square)
    try std.testing.expectEqualStrings("Ringplatz", palimpsest_streets[0].name_de);
    // Judengasse survives in OSM
    try std.testing.expectEqualStrings("Judengasse", palimpsest_streets[4].name_de);
}

test "czernowitz sovereignty syrup" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const val = try sovereigntyToSyrup(allocator);
    switch (val) {
        .list => |items| {
            try std.testing.expectEqual(@as(usize, 7), items.len);
        },
        else => unreachable,
    }
}
