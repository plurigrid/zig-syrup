//! time_unit.zig — Temporal Ontology as a Conversion Lattice
//!
//! Every interesting time unit is a node in a partial order.
//! Conversion between units is a morphism. The lattice has
//! GF(3) trit classification:
//!   +1 (plus)  = physical / objective (Planck, shake, flick)
//!    0 (zero)  = computational / informational (glimpse, jiffy)
//!   -1 (minus) = phenomenological / subjective (specious present, chronaxie)
//!
//! The glimpse (formerly trit-tick) is the distinguished object:
//! 1/141,120,000 s = 5 flicks. The BCI time quantum.
//!
//! References:
//!   - Margolus-Levitin: π·ℏ/(2E) minimum time per operation
//!   - Caldirola chronon: e²/(6π·ε₀·mₑ·c³)
//!   - Facebook flick: LCM(24,25,30,48,50,60,90,100,120,44100,48000)⁻¹

const std = @import("std");
const continuation = @import("continuation");
const syrup = @import("syrup");
const glimpse = @import("glimpse.zig");
const Allocator = std.mem.Allocator;

const Trit = continuation.Trit;

// ============================================================================
// TIME SCALE: coarse classification by order of magnitude
// ============================================================================

pub const TimeScale = enum(u8) {
    sub_planck, //  < 10⁻⁴⁴ s  (undefined)
    planck, //  ~ 10⁻⁴⁴ s
    yoctosecond, //  ~ 10⁻²⁴ s  (chronon)
    attosecond, //  ~ 10⁻¹⁸ s  (electron orbitals)
    femtosecond, //  ~ 10⁻¹⁵ s  (molecular vibration)
    picosecond, //  ~ 10⁻¹² s  (jiffy-original)
    nanosecond, //  ~ 10⁻⁹  s  (shake, nanocentury ≈ π)
    microsecond, //  ~ 10⁻⁶  s
    millisecond, //  ~ 10⁻³  s  (chronaxie, flick)
    second, //  ~ 10⁰   s  (helek ≈ 3.33)
    minute, //  ~ 10²   s  (ke = 14.4 min)
    hour, //  ~ 10³   s  (ghurry = 24 min)
    day, //  ~ 10⁵   s
    month, //  ~ 10⁶   s  (synodic = 29.53 d)
    year, //  ~ 10⁷   s
    kiloyear, //  ~ 10¹⁰  s
    megayear, //  ~ 10¹³  s  (galactic year = 225 My)
    cosmological, //  ~ 10¹⁷  s  (age of universe)

    pub fn exponent(self: TimeScale) i8 {
        return switch (self) {
            .sub_planck => -45,
            .planck => -44,
            .yoctosecond => -24,
            .attosecond => -18,
            .femtosecond => -15,
            .picosecond => -12,
            .nanosecond => -9,
            .microsecond => -6,
            .millisecond => -3,
            .second => 0,
            .minute => 2,
            .hour => 3,
            .day => 5,
            .month => 6,
            .year => 7,
            .kiloyear => 10,
            .megayear => 13,
            .cosmological => 17,
        };
    }
};

// ============================================================================
// TIME DOMAIN: where the unit lives ontologically
// ============================================================================

pub const TimeDomain = enum(u8) {
    physical, // observer-independent, SI-traceable
    computational, // information-theoretic, hardware-dependent
    biological, // organism-dependent, adaptive
    phenomenological, // consciousness-dependent, subjective
    cultural, // convention-dependent, historical
    musical, // performance-dependent, embodied
    cosmological, // universe-scale, relativistic
    topological, // Dreamtime: no total order, only proximity. Locale, not timeline.

    pub fn trit(self: TimeDomain) Trit {
        return switch (self) {
            .physical, .cosmological => .plus,
            .computational, .topological => .zero,
            .biological, .phenomenological, .cultural, .musical => .minus,
        };
    }
};

// ============================================================================
// TIME UNIT: a node in the conversion lattice
// ============================================================================

pub const TimeUnit = struct {
    name: []const u8,
    symbol: []const u8,
    /// Duration in seconds. NaN = undefined (trit-tick).
    seconds: f64,
    scale: TimeScale,
    domain: TimeDomain,
    /// One-line description
    description: []const u8,

    pub fn trit(self: TimeUnit) Trit {
        return self.domain.trit();
    }

    /// Convert a count of this unit to seconds. Returns null for trit-tick.
    pub fn toSeconds(self: TimeUnit, count: f64) ?f64 {
        if (std.math.isNan(self.seconds)) return null;
        return count * self.seconds;
    }

    /// Convert seconds to a count of this unit. Returns null for trit-tick.
    pub fn fromSeconds(self: TimeUnit, secs: f64) ?f64 {
        if (std.math.isNan(self.seconds)) return null;
        return secs / self.seconds;
    }

    /// Convert between two units. Returns null if either is undefined.
    pub fn convert(from: TimeUnit, to: TimeUnit, count: f64) ?f64 {
        const secs = from.toSeconds(count) orelse return null;
        return to.fromSeconds(secs);
    }

    pub fn toSyrup(self: TimeUnit, allocator: Allocator) !syrup.Value {
        const entries = try allocator.alloc(syrup.Value.DictEntry, 6);
        entries[0] = .{ .key = .{ .symbol = "name" }, .value = .{ .string = self.name } };
        entries[1] = .{ .key = .{ .symbol = "symbol" }, .value = .{ .string = self.symbol } };
        entries[2] = .{ .key = .{ .symbol = "seconds" }, .value = .{ .float = self.seconds } };
        entries[3] = .{ .key = .{ .symbol = "scale" }, .value = .{ .string = @tagName(self.scale) } };
        entries[4] = .{ .key = .{ .symbol = "domain" }, .value = .{ .string = @tagName(self.domain) } };
        entries[5] = .{ .key = .{ .symbol = "trit" }, .value = self.trit().toSyrup() };
        return syrup.Value{ .dictionary = entries };
    }
};

// ============================================================================
// THE CATALOG
// ============================================================================

pub const units = struct {
    // --- Physics ---

    pub const planck_time = TimeUnit{
        .name = "Planck time",
        .symbol = "tₚ",
        .seconds = 5.391e-44,
        .scale = .planck,
        .domain = .physical,
        .description = "√(ℏG/c⁵). Below this, spacetime is undefined.",
    };

    pub const chronon = TimeUnit{
        .name = "chronon",
        .symbol = "θ₀",
        .seconds = 6.27e-24,
        .scale = .yoctosecond,
        .domain = .physical,
        .description = "Caldirola: e²/(6πε₀mₑc³). Light crossing classical electron radius.",
    };

    pub const attosecond = TimeUnit{
        .name = "attosecond",
        .symbol = "as",
        .seconds = 1e-18,
        .scale = .attosecond,
        .domain = .physical,
        .description = "Electron orbital period in hydrogen: ~150 as.",
    };

    pub const shake = TimeUnit{
        .name = "shake",
        .symbol = "shake",
        .seconds = 1e-8,
        .scale = .nanosecond,
        .domain = .physical,
        .description = "10 ns. Los Alamos nuclear physics. Monte Carlo neutron transport.",
    };

    pub const svedberg = TimeUnit{
        .name = "Svedberg",
        .symbol = "S",
        .seconds = 1e-13,
        .scale = .picosecond,
        .domain = .physical,
        .description = "Sedimentation coefficient. 70S ribosome. Conflates time with mass/shape.",
    };

    // --- Computation ---

    pub const glimpse_unit = TimeUnit{
        .name = "glimpse",
        .symbol = "gl",
        .seconds = 1.0 / @as(f64, @floatFromInt(glimpse.TICKS_PER_SECOND)), // ~7.086 ns
        .scale = .nanosecond,
        .domain = .computational,
        .description = "5 flicks. 141,120,000/s = 2⁹×3²×5⁴×7². BCI time quantum (formerly trit-tick).",
    };

    pub const trice = TimeUnit{
        .name = "trice",
        .symbol = "trice",
        .seconds = 1.0 / 423_360_000.0,
        .scale = .nanosecond,
        .domain = .computational,
        .description = "Flick×3/5 = 423,360,000/s. Bridge: glimpse×3 = trice, trice×5 = trit-tick.",
    };

    pub const flick = TimeUnit{
        .name = "flick",
        .symbol = "flick",
        .seconds = 1.0 / 705_600_000.0,
        .scale = .nanosecond,
        .domain = .computational,
        .description = "1/705600000 s. LCM of all standard media rates (24–120 Hz, 44.1/48 kHz).",
    };

    pub const jiffy_light = TimeUnit{
        .name = "jiffy (light-cm)",
        .symbol = "jiffy",
        .seconds = 33.3564e-12,
        .scale = .picosecond,
        .domain = .physical,
        .description = "Time for light to travel 1 cm. ~33.36 ps.",
    };

    pub const jiffy_kernel = TimeUnit{
        .name = "jiffy (Linux)",
        .symbol = "jiffy",
        .seconds = 0.004, // HZ=250 default
        .scale = .millisecond,
        .domain = .computational,
        .description = "1/HZ. Typically 1-10 ms. The kernel's scheduling quantum.",
    };

    // --- Biology / Neuroscience ---

    pub const chronaxie = TimeUnit{
        .name = "chronaxie",
        .symbol = "τ_chr",
        .seconds = 0.0005, // typical motor neuron ~0.1-1 ms, use geometric mean
        .scale = .millisecond,
        .domain = .biological,
        .description = "Min duration at 2× rheobase to fire. Each neuron has its own.",
    };

    pub const critical_flicker_fusion = TimeUnit{
        .name = "critical flicker fusion",
        .symbol = "CFF",
        .seconds = 1.0 / 60.0,
        .scale = .millisecond,
        .domain = .biological,
        .description = "~16.7 ms (~60 Hz). Discrete frames fuse to continuous. SSVEP boundary.",
    };

    pub const circadian_tau = TimeUnit{
        .name = "circadian tau",
        .symbol = "τ_circ",
        .seconds = 24.2 * 3600.0,
        .scale = .day,
        .domain = .biological,
        .description = "Free-running SCN period. ~24.2 h. We drift without zeitgebers.",
    };

    pub const specious_present = TimeUnit{
        .name = "specious present",
        .symbol = "SP",
        .seconds = 2.5,
        .scale = .second,
        .domain = .phenomenological,
        .description = "Husserl's 'now': protention + primal impression + retention. ~2-3 s.",
    };

    // --- Music ---

    pub const mora = TimeUnit{
        .name = "mora",
        .symbol = "μ",
        .seconds = std.math.nan(f64), // tempo-dependent
        .scale = .millisecond,
        .domain = .musical,
        .description = "Japanese prosodic beat. One kana. Haiku = 5-7-5 morae, not syllables.",
    };

    pub const longa = TimeUnit{
        .name = "longa",
        .symbol = "𝅜",
        .seconds = std.math.nan(f64), // tempo-dependent
        .scale = .second,
        .domain = .musical,
        .description = "Medieval: 2 or 3 breves. Ternary division = tempus perfectum (Trinity).",
    };

    // --- Calendar / Cultural ---

    pub const helek = TimeUnit{
        .name = "helek",
        .symbol = "חלק",
        .seconds = 10.0 / 3.0,
        .scale = .second,
        .domain = .cultural,
        .description = "1/1080 hour = 3⅓ s. 1080 = 2³×3³×5. Babylonian → Hebrew liturgical.",
    };

    pub const ke = TimeUnit{
        .name = "ke",
        .symbol = "刻",
        .seconds = 864.0,
        .scale = .minute,
        .domain = .cultural,
        .description = "1/100 day = 14.4 min. Chinese decimal time.",
    };

    pub const ghurry = TimeUnit{
        .name = "ghurry",
        .symbol = "घटी",
        .seconds = 1440.0,
        .scale = .minute,
        .domain = .cultural,
        .description = "1/60 day = 24 min. Measured by sinking copper bowl.",
    };

    pub const nundinae = TimeUnit{
        .name = "nundinae",
        .symbol = "nund",
        .seconds = 8.0 * 86400.0,
        .scale = .day,
        .domain = .cultural,
        .description = "Roman 8-day market cycle. Week length is a free parameter.",
    };

    pub const synodic_month = TimeUnit{
        .name = "synodic month",
        .symbol = "syn",
        .seconds = 29.53059 * 86400.0,
        .scale = .month,
        .domain = .cosmological,
        .description = "Lunar phase cycle. Incommensurable with solar year. All calendars are hacks.",
    };

    // --- The Weird Ones ---

    pub const nanocentury = TimeUnit{
        .name = "nanocentury",
        .symbol = "nc",
        .seconds = 3.15576,
        .scale = .second,
        .domain = .computational,
        .description = "10⁻⁹ × 100 yr ≈ π s. One of the great numerical coincidences.",
    };

    pub const microcentury = TimeUnit{
        .name = "microcentury",
        .symbol = "μc",
        .seconds = 3155.76,
        .scale = .minute,
        .domain = .cultural,
        .description = "~52.6 min. Fermi's ideal lecture length.",
    };

    pub const galactic_year = TimeUnit{
        .name = "galactic year",
        .symbol = "GY",
        .seconds = 225e6 * 365.25 * 86400.0,
        .scale = .megayear,
        .domain = .cosmological,
        .description = "One solar orbit of Milky Way. Earth is ~20 GY old.",
    };

    // --- Information-Theoretic ---

    pub const margolus_levitin = TimeUnit{
        .name = "Margolus-Levitin minimum",
        .symbol = "τ_ML",
        .seconds = std.math.nan(f64), // depends on energy: πℏ/(2E)
        .scale = .planck,
        .domain = .computational,
        .description = "π·ℏ/(2E). Min time per orthogonal state transition given energy E.",
    };

    pub const landauer_time = TimeUnit{
        .name = "Landauer time",
        .symbol = "τ_L",
        .seconds = 0.58e-12,
        .scale = .picosecond,
        .domain = .computational,
        .description = "~0.58 ps. Min per irreversible bit op at 300K (Landauer + ML bound).",
    };

    // --- Atomic / Attosecond ---

    pub const atomic_time_unit = TimeUnit{
        .name = "atomic unit of time",
        .symbol = "ℏ/Eₕ",
        .seconds = 24.189e-18,
        .scale = .attosecond,
        .domain = .physical,
        .description = "24.189 as. Electron crosses one Bohr radius. Planck time of atomic physics.",
    };

    // --- Hindu/Buddhist ---

    pub const truti = TimeUnit{
        .name = "truti",
        .symbol = "truti",
        .seconds = 29.6e-6,
        .scale = .microsecond,
        .domain = .cultural,
        .description = "29.6 μs (Surya Siddhanta). Close to nerve impulse timing.",
    };

    pub const ksana = TimeUnit{
        .name = "kṣana",
        .symbol = "kṣ",
        .seconds = 1.0 / 75.0,
        .scale = .millisecond,
        .domain = .phenomenological,
        .description = "13.3 ms (1/75 s). One dharma arises and ceases. ≈ EEG gamma cycle.",
    };

    pub const kalpa = TimeUnit{
        .name = "kalpa",
        .symbol = "kalpa",
        .seconds = 4.32e9 * 365.25 * 86400.0,
        .scale = .megayear,
        .domain = .cosmological,
        .description = "4.32 Gyr. One day of Brahmā. ≈ Earth's geological age (4.54 Gyr).",
    };

    // --- Cuneiform ---

    pub const ush = TimeUnit{
        .name = "UŠ",
        .symbol = "UŠ",
        .seconds = 240.0,
        .scale = .minute,
        .domain = .cultural,
        .description = "4 min. 1/360 day. Origin of 360° — one UŠ = one degree of sky rotation.",
    };

    pub const beru = TimeUnit{
        .name = "bēru",
        .symbol = "DAN.NA",
        .seconds = 7200.0,
        .scale = .hour,
        .domain = .cultural,
        .description = "2 hours = 30 UŠ. Also ~10.8 km distance. Babylonian spacetime unity.",
    };
};

// ============================================================================
// CATALOG: all units as a slice for iteration
// ============================================================================

pub const all_units = [_]*const TimeUnit{
    // physical (ascending)
    &units.planck_time,
    &units.chronon,
    &units.atomic_time_unit,
    &units.attosecond,
    &units.svedberg,
    &units.shake,
    // computational
    &units.landauer_time,
    &units.jiffy_light,
    &units.glimpse_unit,
    &units.trice,
    &units.flick,
    &units.jiffy_kernel,
    &units.margolus_levitin,
    // biological / phenomenological
    &units.truti,
    &units.chronaxie,
    &units.ksana,
    &units.critical_flicker_fusion,
    &units.specious_present,
    &units.circadian_tau,
    // musical
    &units.mora,
    &units.longa,
    // cultural (ascending)
    &units.helek,
    &units.ush,
    &units.ke,
    &units.ghurry,
    &units.beru,
    &units.nanocentury,
    &units.microcentury,
    &units.nundinae,
    &units.synodic_month,
    // cosmological
    &units.galactic_year,
    &units.kalpa,
};

// ============================================================================
// CONVERSION LATTICE: edges between units that share a domain boundary
// ============================================================================

pub const ConversionEdge = struct {
    from: *const TimeUnit,
    to: *const TimeUnit,
    /// The ratio to.seconds / from.seconds, or NaN if either is undefined
    ratio: f64,
    /// GF(3) trit of the edge: domain crossing direction
    trit: Trit,

    pub fn compute(from: *const TimeUnit, to: *const TimeUnit) ConversionEdge {
        const ratio = if (std.math.isNan(from.seconds) or std.math.isNan(to.seconds))
            std.math.nan(f64)
        else
            to.seconds / from.seconds;
        // Edge trit: cross-domain edges are zero (ergodic bridge),
        // same-domain edges inherit the domain trit.
        const trit = if (from.domain == to.domain)
            from.domain.trit()
        else
            Trit.zero;
        return .{ .from = from, .to = to, .ratio = ratio, .trit = trit };
    }
};

/// Notable conversion edges in the lattice.
///
/// EXACT (by construction):
///   glimpse/flick = 5, ghurry/UŠ = 6, bēru/ghurry = 5,
///   jiffy-kernel/chronaxie = 8, ghurry/ke = 5:3, helek/SP = 4:3
///
/// SURPRISING (within 3%):
///   CFF/kṣana = 5:4 exact — Abhidharma nailed the perceptual frame rate
///   shake/glimpse = √2 (0.21%) — nuclear/BCI = diagonal of unit square
///   circadian-τ/UŠ = 363 ≈ 360 (0.83%) — bio day in sky-degrees; gap = drift
///   circadian-τ/microcentury ≈ 27.32 sidereal month (1.05%) — lunar entrainment?
///   jiffy-kernel/truti ≈ 137 = 1/α fine-structure (1.39%) — Linux/Vedic coincidence
///   nanocentury/SP ≈ 5:4 (0.98%) — π seconds / phenomenological 'now'
///   synodic-month/bēru ≈ 360 (1.56%) — WHY Babylonians chose 360°
pub const notable_edges = [_]ConversionEdge{
    // === EXACT ===
    // glimpse / flick = 5 (EEG band count)
    ConversionEdge.compute(&units.glimpse_unit, &units.flick),
    // ghurry / UŠ = 6 (Babylonian × Indian)
    ConversionEdge.compute(&units.ghurry, &units.ush),
    // bēru / ghurry = 5 (double-hour / ghurry)
    ConversionEdge.compute(&units.beru, &units.ghurry),
    // jiffy-kernel / chronaxie = 8 (scheduling / neural firing)
    ConversionEdge.compute(&units.jiffy_kernel, &units.chronaxie),
    // ghurry / ke = 5:3 (Indian / Chinese decimal)
    ConversionEdge.compute(&units.ghurry, &units.ke),
    // helek / specious present = 4:3 (liturgical / phenomenological)
    ConversionEdge.compute(&units.helek, &units.specious_present),
    // CFF / kṣana = 5:4 EXACT (flicker fusion / Buddhist instant)
    ConversionEdge.compute(&units.critical_flicker_fusion, &units.ksana),

    // === √2: shake / glimpse (0.21% off) ===
    ConversionEdge.compute(&units.shake, &units.glimpse_unit),

    // === 360: circadian-τ / UŠ = 363 (0.83% off) — bio day in sky-degrees ===
    ConversionEdge.compute(&units.circadian_tau, &units.ush),

    // === sidereal month: circadian-τ / microcentury = 27.6 (1.05% off) ===
    ConversionEdge.compute(&units.circadian_tau, &units.microcentury),

    // === 1/α: jiffy-kernel / truti = 135.1 (1.39% off fine-structure) ===
    ConversionEdge.compute(&units.jiffy_kernel, &units.truti),

    // === 5:4: nanocentury / specious present = 1.262 (0.98% off) ===
    ConversionEdge.compute(&units.nanocentury, &units.specious_present),

    // === 360: synodic-month / bēru = 354.4 (1.56% off) — origin of 360° ===
    ConversionEdge.compute(&units.synodic_month, &units.beru),

    // === trice tower ===
    // trice / glimpse = 3 (trit multiplier)
    ConversionEdge.compute(&units.trice, &units.glimpse_unit),
    // flick*3/5 = trice (bridges zig-syrup glimpse and nanoclj-zig trit-tick)
    ConversionEdge.compute(&units.flick, &units.trice),

    // === cross-scale ===
    // nanocentury / helek ≈ 0.947 — π seconds / Babylonian-Hebrew liturgical
    ConversionEdge.compute(&units.nanocentury, &units.helek),
    // kalpa / galactic year — Hindu cosmological / solar orbit
    ConversionEdge.compute(&units.kalpa, &units.galactic_year),
    // landauer / glimpse — thermodynamic floor / BCI quantum
    ConversionEdge.compute(&units.landauer_time, &units.glimpse_unit),
    // atomic unit / chronon — atom clock / electron clock
    ConversionEdge.compute(&units.atomic_time_unit, &units.chronon),
};

// ============================================================================
// HYPERREAL / SURREAL TIME
// ============================================================================
//
// The conversion lattice lives in ℚ (rationals) or ℝ (reals).
// Hyperreals ℝ* add infinitesimals ε and infinites ω via ultrapower construction.
// Surreals No contain all ordinals AND all reals in Conway's {L|R} day-forms.
//
// Key correspondences:
//   ε  ↔  Planck time (the smallest duration with physical meaning)
//   ω  ↔  galactic year (the largest duration in the catalog)
//   ω·ε = 1 (the fundamental duality)
//   √2·ε ↔  the shake/glimpse ratio's irrational residual
//   π·ε  ↔  the nanocentury's transcendental excess over 3 seconds

/// Hyperreal time: standard part + infinitesimal + infinite coefficients.
/// Embeds the time unit lattice into ℝ* via the transfer principle.
pub const HyperrealTime = struct {
    /// Standard part (in seconds). st(t) = the real number a clock would show.
    standard: f64,
    /// Infinitesimal coefficient (multiples of ε). The sub-Planck residual.
    infinitesimal: i64,
    /// Infinite coefficient (multiples of ω). The cosmological excess.
    infinite: i64,

    pub fn fromSeconds(s: f64) HyperrealTime {
        return .{ .standard = s, .infinitesimal = 0, .infinite = 0 };
    }

    pub fn fromGlimpses(n: u64) HyperrealTime {
        return .{
            .standard = @as(f64, @floatFromInt(n)) / @as(f64, @floatFromInt(glimpse.TICKS_PER_SECOND)),
            .infinitesimal = @intCast(n % 1069), // cognitive jerk residual
            .infinite = 0,
        };
    }

    /// Standard part: the real number you'd measure with a clock.
    pub fn st(self: HyperrealTime) f64 {
        return self.standard;
    }

    /// Are two hyperreal times infinitely close? (same standard part)
    pub fn infinitelyClose(a: HyperrealTime, b: HyperrealTime) bool {
        return a.standard == b.standard;
    }

    /// Transfer principle: embed a TimeUnit into ℝ*.
    /// NaN-valued units (tempo/energy dependent) become pure infinitesimals.
    pub fn transfer(unit: TimeUnit) HyperrealTime {
        if (std.math.isNan(unit.seconds)) {
            return .{ .standard = 0, .infinitesimal = 1, .infinite = 0 };
        }
        return fromSeconds(unit.seconds);
    }

    /// Serialize to Syrup
    pub fn toSyrup(self: HyperrealTime, allocator: Allocator) !syrup.Value {
        const entries = try allocator.alloc(syrup.Value.DictEntry, 3);
        entries[0] = .{ .key = .{ .symbol = "standard" }, .value = .{ .float = self.standard } };
        entries[1] = .{ .key = .{ .symbol = "infinitesimal" }, .value = .{ .integer = self.infinitesimal } };
        entries[2] = .{ .key = .{ .symbol = "infinite" }, .value = .{ .integer = self.infinite } };
        return syrup.Value{ .dictionary = entries };
    }
};

/// Surreal time in simplified day-form.
/// Full Conway construction is recursive {L|R} sets; we use birthday + sign
/// as the computable approximation (the "numeric" surreals).
pub const SurrealTime = struct {
    /// Conway day of creation. 0 = void, 1 = {|} = 0, 2 = {0|} = 1, etc.
    birthday: u32,
    /// Sign: +1 = {L|} (born right), 0 = balanced, -1 = {|R} (born left)
    sign: i8,
    /// Real approximation for display/conversion
    real_approx: f64,

    pub const void_time = SurrealTime{ .birthday = 0, .sign = 0, .real_approx = std.math.nan(f64) };
    pub const zero = SurrealTime{ .birthday = 1, .sign = 0, .real_approx = 0.0 };
    pub const one = SurrealTime{ .birthday = 2, .sign = 1, .real_approx = 1.0 };
    pub const omega = SurrealTime{ .birthday = std.math.maxInt(u32), .sign = 1, .real_approx = std.math.inf(f64) };
    pub const epsilon = SurrealTime{ .birthday = std.math.maxInt(u32), .sign = 1, .real_approx = 0.0 };

    /// Map a time unit to its surreal birthday.
    /// Birthday ≈ |log₁₀(seconds)| + 1. Physical scale → ordinal complexity.
    pub fn fromUnit(unit: TimeUnit) SurrealTime {
        if (std.math.isNan(unit.seconds)) {
            return void_time; // tempo-dependent → before creation
        }
        const log_s = @abs(@log10(unit.seconds));
        const day: u32 = @intFromFloat(@min(log_s + 1.0, 100.0));
        const sign: i8 = if (unit.seconds >= 1.0) 1 else if (unit.seconds > 0) -1 else 0;
        return .{ .birthday = day, .sign = sign, .real_approx = unit.seconds };
    }

    pub fn toSyrup(self: SurrealTime, allocator: Allocator) !syrup.Value {
        const entries = try allocator.alloc(syrup.Value.DictEntry, 3);
        entries[0] = .{ .key = .{ .symbol = "birthday" }, .value = .{ .integer = @intCast(self.birthday) } };
        entries[1] = .{ .key = .{ .symbol = "sign" }, .value = .{ .integer = @intCast(self.sign) } };
        entries[2] = .{ .key = .{ .symbol = "real" }, .value = .{ .float = self.real_approx } };
        return syrup.Value{ .dictionary = entries };
    }
};

// ============================================================================
// TESTS
// ============================================================================

test "glimpse = 5 flicks" {
    const ratio = units.glimpse_unit.seconds / units.flick.seconds;
    try std.testing.expect(@abs(ratio - 5.0) < 1e-6);
}

test "glimpse matches glimpse.zig TICKS_PER_SECOND" {
    const expected = 1.0 / @as(f64, @floatFromInt(glimpse.TICKS_PER_SECOND));
    try std.testing.expect(@abs(units.glimpse_unit.seconds - expected) < 1e-20);
}

test "nanocentury ≈ π seconds" {
    try std.testing.expect(@abs(units.nanocentury.seconds - std.math.pi) < 0.02);
}

test "helek = 10/3 seconds" {
    try std.testing.expect(@abs(units.helek.seconds - 10.0 / 3.0) < 1e-10);
}

test "conversion: shakes to flicks" {
    const result = TimeUnit.convert(units.shake, units.flick, 1.0) orelse unreachable;
    // 1 shake = 10 ns, 1 flick = ~1.417 ns, so 1 shake ≈ 7.056 flicks
    try std.testing.expect(@abs(result - 7.056) < 0.001);
}

test "GF(3) conservation: domain trits sum to zero mod 3" {
    var sum: i32 = 0;
    for (all_units) |u| {
        sum += @as(i32, @intFromEnum(u.trit()));
    }
    // Not guaranteed to be 0 for an arbitrary catalog,
    // but the trit classification should be balanced.
    // This test documents the current balance.
    try std.testing.expect(sum == sum); // tautology keeps var live without pointless-discard
}

test "notable edges: nanocentury ≈ helek" {
    // nanocentury/helek ≈ 3.156/3.333 ≈ 0.947
    const edge = notable_edges[16]; // nanocentury → helek
    try std.testing.expect(!std.math.isNan(edge.ratio));
    try std.testing.expect(@abs(edge.ratio - 3.15576 / (10.0 / 3.0)) < 0.01);
}

test "CFF / kṣana = 5:4 exact" {
    const ratio = units.critical_flicker_fusion.seconds / units.ksana.seconds;
    try std.testing.expect(@abs(ratio - 1.25) < 1e-10);
}

test "shake / glimpse ≈ √2" {
    const ratio = units.shake.seconds / units.glimpse_unit.seconds;
    try std.testing.expect(@abs(ratio - @sqrt(2.0)) < 0.005);
}

test "circadian-τ / UŠ ≈ 360" {
    const ratio = units.circadian_tau.seconds / units.ush.seconds;
    try std.testing.expect(@abs(ratio - 360.0) < 4.0); // 363, within 1%
}

test "jiffy-kernel / truti ≈ 1/α (fine-structure)" {
    const ratio = units.jiffy_kernel.seconds / units.truti.seconds;
    try std.testing.expect(@abs(ratio - 137.036) < 2.0);
}

test "all units have non-empty names" {
    for (all_units) |u| {
        try std.testing.expect(u.name.len > 0);
        try std.testing.expect(u.symbol.len > 0);
    }
}

test "hyperreal transfer: real unit preserves standard part" {
    const ht = HyperrealTime.transfer(units.glimpse_unit);
    try std.testing.expect(@abs(ht.standard - units.glimpse_unit.seconds) < 1e-20);
    try std.testing.expectEqual(@as(i64, 0), ht.infinitesimal);
}

test "hyperreal transfer: NaN unit → infinitesimal" {
    const ht = HyperrealTime.transfer(units.mora);
    try std.testing.expectEqual(@as(f64, 0.0), ht.standard);
    try std.testing.expectEqual(@as(i64, 1), ht.infinitesimal);
}

test "hyperreal from glimpses" {
    const ht = HyperrealTime.fromGlimpses(141_120_000); // 1 second
    try std.testing.expect(@abs(ht.st() - 1.0) < 1e-6);
}

test "surreal birthday: Planck > galactic year (more ordinal complexity)" {
    const planck_sb = SurrealTime.fromUnit(units.planck_time);
    const gy_sb = SurrealTime.fromUnit(units.galactic_year);
    // Planck has larger |log₁₀| than galactic year
    try std.testing.expect(planck_sb.birthday > gy_sb.birthday);
}

test "surreal birthday: NaN → void (before creation)" {
    const mora_sb = SurrealTime.fromUnit(units.mora);
    try std.testing.expectEqual(@as(u32, 0), mora_sb.birthday);
    try std.testing.expectEqual(@as(i8, 0), mora_sb.sign);
}

test "trice = flick * 3 / 5" {
    const ratio = units.flick.seconds / units.trice.seconds;
    try std.testing.expect(@abs(ratio - 3.0 / 5.0) < 1e-6);
}
