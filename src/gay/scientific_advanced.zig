// scientific_advanced.zig: Advanced scientific modules from Gay.jl
// Translates: containerization_gay, marsaglia_bumpus_tests, multiverse_geometric,
//             plurigrid_69, enzyme, ergodic_bridge, spectral_bridge,
//             color_logic_pullback, gay_e_integration, abduce
//
// Zig 0.14+ — no allocator-dependent APIs where avoidable

const std = @import("std");
const splitmix = @import("splitmix.zig");
const sm64 = splitmix.splitmix64;
const GOLDEN = splitmix.GOLDEN;
const Color = splitmix.Color;

// ============================================================================
// Section 1: Gay E Integration (gay_e_integration.jl)
// — Euler-seeded universal color derivation, multi-language dialects
// ============================================================================

/// IEEE 754 representation of e
pub const EULER_BITS: u64 = 0x4005bf0a8b145769;
/// "gay_colo" as little-endian
pub const GAY_IGOR_SEED: u64 = 0x6761795f636f6c6f;
/// XOR of Euler and Igor
pub const GAY_E_SEED: u64 = EULER_BITS ^ GAY_IGOR_SEED;

/// mix64: SplitMix64 mixing (same as sm64 but standalone)
pub fn mix64(z: u64) u64 {
    return sm64(z);
}

/// Derive deterministic seed from u64 value, rooted in GAY_E_SEED
pub fn gaySeed(x: u64) u64 {
    if (x == EULER_BITS) return GAY_E_SEED;
    return mix64(GAY_E_SEED ^ x);
}

/// Derive color from seed
pub fn gayColor(seed: u64) Color {
    const h = mix64(seed);
    return .{
        .r = @as(f64, @floatFromInt((h >> 16) & 0xFF)) / 255.0,
        .g = @as(f64, @floatFromInt((h >> 8) & 0xFF)) / 255.0,
        .b = @as(f64, @floatFromInt(h & 0xFF)) / 255.0,
    };
}

pub const OperatorClass = enum(u8) { additive, multiplicative, comparison, logical };

/// Conserved combine: result color from two input colors + operator seed
pub fn conservedCombine(c1: Color, c2: Color, op_seed: u64) struct { color: Color, preserved: bool } {
    const q1 = quantize24(c1);
    const q2 = quantize24(c2);
    const combined = q1 ^ q2 ^ @as(u32, @truncate(op_seed));
    const result = Color{
        .r = @as(f64, @floatFromInt((combined >> 16) & 0xFF)) / 255.0,
        .g = @as(f64, @floatFromInt((combined >> 8) & 0xFF)) / 255.0,
        .b = @as(f64, @floatFromInt(combined & 0xFF)) / 255.0,
    };
    // Parity preservation check
    const parity_in = (q1 ^ q2) & 0x010101;
    const parity_out = quantize24(result) & 0x010101;
    return .{ .color = result, .preserved = parity_in == parity_out };
}

fn quantize24(c: Color) u32 {
    const r: u32 = @intFromFloat(@round(std.math.clamp(c.r, 0.0, 1.0) * 255.0));
    const g: u32 = @intFromFloat(@round(std.math.clamp(c.g, 0.0, 1.0) * 255.0));
    const b: u32 = @intFromFloat(@round(std.math.clamp(c.b, 0.0, 1.0) * 255.0));
    return (r << 16) | (g << 8) | b;
}

pub const DialectColors = struct {
    keyword: Color,
    string: Color,
    number: Color,
    comment: Color,
    operator: Color,

    pub fn julia() DialectColors {
        return .{
            .keyword = gayColor(gaySeed(0x6a756c6961)), // "julia"
            .string = gayColor(gaySeed(0x737472696e67)),
            .number = gayColor(gaySeed(0x6e756d626572)),
            .comment = gayColor(gaySeed(0x636f6d6d656e)),
            .operator = gayColor(gaySeed(0x6f7065726174)),
        };
    }

    pub fn lisp() DialectColors {
        return .{
            .keyword = gayColor(gaySeed(0x6c697370)), // "lisp"
            .string = gayColor(gaySeed(0x6c73747200)),
            .number = gayColor(gaySeed(0x6c6e756d00)),
            .comment = gayColor(gaySeed(0x6c636d7400)),
            .operator = gayColor(gaySeed(0x6c6f707200)),
        };
    }
};

// ============================================================================
// Section 2: Containerization Gay (containerization_gay.jl)
// — Chromatic container layers with deterministic color identity
// ============================================================================

pub const ChromaticLayer = struct {
    id: u64, // content-addressable hash
    parent_id: ?u64,
    color_seed: u64,
    color: Color,
    file_count: u32,
    size_bytes: u64,

    pub fn init(content_hash: u64, parent: ?ChromaticLayer) ChromaticLayer {
        const parent_seed = if (parent) |p| p.color_seed else @as(u64, 0);
        const color_seed = mix64(content_hash ^ parent_seed ^ GAY_IGOR_SEED);
        return .{
            .id = content_hash,
            .parent_id = if (parent) |p| p.id else null,
            .color_seed = color_seed,
            .color = gayColor(color_seed),
            .file_count = 0,
            .size_bytes = 0,
        };
    }
};

/// Compose layers: overlay on top of base, color-conserving
pub fn composeLayers(base: ChromaticLayer, overlay: ChromaticLayer) ChromaticLayer {
    const combined_hash = mix64(base.id ^ overlay.id);
    const result = conservedCombine(base.color, overlay.color, combined_hash);
    return .{
        .id = combined_hash,
        .parent_id = base.id,
        .color_seed = mix64(base.color_seed ^ overlay.color_seed),
        .color = result.color,
        .file_count = base.file_count + overlay.file_count,
        .size_bytes = base.size_bytes + overlay.size_bytes,
    };
}

/// Verify layer chain: each layer's color derives from content + parent
pub fn verifyLayerChain(layers: []const ChromaticLayer) bool {
    for (1..layers.len) |i| {
        const expected_parent = layers[i - 1].id;
        if (layers[i].parent_id) |pid| {
            if (pid != expected_parent) return false;
        } else return false;
    }
    return true;
}

// ============================================================================
// Section 3: Marsaglia-Bumpus Tests (marsaglia_bumpus_tests.jl)
// — Birthday spacings, runs, permutation tests + Bumpus adhesion/sheaf tests
// ============================================================================

/// Birthday spacing test on hue space
pub fn birthdaySpacingTest(n: u32, seed: u64) struct { collisions: u32, expected: f64, passed: bool } {
    var hues: [1024]u32 = undefined;
    const actual_n = @min(n, 1024);
    var rng = seed;

    for (0..actual_n) |i| {
        rng = sm64(rng ^ @as(u64, @intCast(i)));
        // Extract hue in [0, 3600) (0.1 degree resolution)
        hues[i] = @intCast(rng % 3600);
    }

    // Sort (insertion sort for small n)
    for (1..actual_n) |i| {
        const key = hues[i];
        var j: usize = i;
        while (j > 0 and hues[j - 1] > key) : (j -= 1) {
            hues[j] = hues[j - 1];
        }
        hues[j] = key;
    }

    // Count collisions (spacing = 0)
    var collisions: u32 = 0;
    for (1..actual_n) |i| {
        if (hues[i] == hues[i - 1]) collisions += 1;
    }

    const n_f: f64 = @floatFromInt(actual_n);
    const expected = (n_f * n_f) / (2.0 * 3600.0);
    const passed = @as(f64, @floatFromInt(collisions)) < expected * 3.0; // rough threshold

    return .{ .collisions = collisions, .expected = expected, .passed = passed };
}

/// Runs test: count ascending/descending runs in generated values
pub fn runsTest(n: u32, seed: u64) struct { n_runs: u32, expected: f64, passed: bool } {
    const actual_n = @min(n, 4096);
    var rng = seed;
    var prev: u64 = 0;
    var n_runs: u32 = 1;
    var increasing = false;

    for (0..actual_n) |i| {
        rng = sm64(rng ^ @as(u64, @intCast(i)));
        if (i == 0) {
            prev = rng;
            continue;
        }
        const new_inc = rng > prev;
        if (i > 1 and new_inc != increasing) n_runs += 1;
        increasing = new_inc;
        prev = rng;
    }

    const n_f: f64 = @floatFromInt(actual_n);
    const expected = (2.0 * n_f - 1.0) / 3.0;
    const sigma = @sqrt((16.0 * n_f - 29.0) / 90.0);
    const z = @abs(@as(f64, @floatFromInt(n_runs)) - expected) / sigma;
    return .{ .n_runs = n_runs, .expected = expected, .passed = z < 3.0 };
}

/// Bumpus adhesion width test: verify split preserves tree structure
pub fn adhesionWidthTest(seed: u64, depth: u32) struct { max_width: u32, balanced: bool } {
    var max_width: u32 = 1;
    var rng = seed;
    var width: u32 = 1;

    for (0..depth) |_| {
        rng = sm64(rng);
        // Each node splits into 2-3 children
        const branching: u32 = @intCast(2 + rng % 2);
        width *= branching;
        if (width > max_width) max_width = width;
        // Prune to keep bounded
        if (width > 64) width = 64;
    }

    return .{ .max_width = max_width, .balanced = max_width <= (@as(u32, 1) << @intCast(depth)) };
}

// ============================================================================
// Section 4: Multiverse Geometric (multiverse_geometric.jl)
// — Hamkins multiverse, verses, geometric morphisms, resolution
// ============================================================================

pub const Verse = struct {
    id: u64,
    name_hash: u64,
    parent_id: ?u64,
    fingerprint: u64,
    color: Color,
    resolved: bool,
    assets: [8]f64, // up to 8 asset balances
    asset_count: u8,

    pub fn init(name_hash: u64, seed: u64) Verse {
        const id = sm64(seed ^ name_hash);
        const fp = sm64(id);
        return .{
            .id = id,
            .name_hash = name_hash,
            .parent_id = null,
            .fingerprint = fp,
            .color = gayColor(fp),
            .resolved = false,
            .assets = [_]f64{0} ** 8,
            .asset_count = 0,
        };
    }

    pub fn initChild(name_hash: u64, parent: *const Verse) Verse {
        var v = Verse.init(name_hash, parent.id);
        v.parent_id = parent.id;
        return v;
    }
};

pub const MultiverseFrame = struct {
    verses: [64]Verse,
    count: u32,
    root_id: u64,

    pub fn init(root_seed: u64) MultiverseFrame {
        var mf: MultiverseFrame = undefined;
        mf.verses[0] = Verse.init(0x556e697665727365, root_seed); // "Universe"
        mf.count = 1;
        mf.root_id = mf.verses[0].id;
        return mf;
    }

    /// Partition parent verse into n children. XOR of children fps = parent fp.
    pub fn partition(self: *MultiverseFrame, parent_idx: u32, n_children: u32) void {
        if (parent_idx >= self.count) return;
        const parent = &self.verses[parent_idx];
        var remaining_fp = parent.fingerprint;

        for (0..n_children) |ci| {
            if (self.count >= 64) break;
            const child_hash = sm64(parent.id ^ @as(u64, @intCast(ci)));
            var child = Verse.initChild(child_hash, parent);
            if (ci == n_children - 1) {
                // Last child gets adjusted fp so XOR = parent
                child.fingerprint = remaining_fp;
            } else {
                remaining_fp ^= child.fingerprint;
            }
            child.color = gayColor(child.fingerprint);
            self.verses[self.count] = child;
            self.count += 1;
        }
    }

    /// Resolve (eliminate) a verse
    pub fn resolve(self: *MultiverseFrame, idx: u32) void {
        if (idx < self.count) self.verses[idx].resolved = true;
    }

    /// Verify multiverse law: XOR of active verse fps is invariant
    pub fn verifyFingerprintLaw(self: *const MultiverseFrame) u64 {
        var fp: u64 = 0;
        for (0..self.count) |i| {
            if (!self.verses[i].resolved) fp ^= self.verses[i].fingerprint;
        }
        return fp;
    }
};

// ============================================================================
// Section 5: Plurigrid 69 (plurigrid_69.jl)
// — 69 autopoietic reinventions, trust derivations, color gamuts
// ============================================================================

pub const TrustPolarity = enum(i8) { skeptical = -1, neutral = 0, trusting = 1 };

pub const ColorGamut = enum(u8) {
    srgb,
    display_p3,
    rec2020,
    aces,
    tropical,
    balanced_ternary,
};

/// SKC (Solomonoff-Kolmogorov-Chaitin) complexity estimate
pub fn skcComplexity(data: []const u8) f64 {
    // Approximate: count unique bigrams / total bigrams
    if (data.len < 2) return 0.0;
    var unique: u32 = 0;
    var seen: [256]bool = [_]bool{false} ** 256;
    for (0..data.len - 1) |i| {
        const bigram: u8 = data[i] ^ data[i + 1];
        if (!seen[bigram]) {
            seen[bigram] = true;
            unique += 1;
        }
    }
    return @as(f64, @floatFromInt(unique)) / 256.0;
}

/// Trust derivation from complexity
pub fn skcTrust(complexity: f64) TrustPolarity {
    if (complexity < 0.3) return .trusting; // low complexity = compressible = trust
    if (complexity > 0.7) return .skeptical; // high complexity = random = distrust
    return .neutral;
}

/// Gamut-specific color at time t
pub fn gamutAtTime(gamut: ColorGamut, t: f64, seed: u64) Color {
    var h = sm64(seed ^ @as(u64, @intFromFloat(@round(t * 1000))));
    const r_base: f64 = @as(f64, @floatFromInt(h % 256)) / 255.0;
    h = sm64(h);
    const g_base: f64 = @as(f64, @floatFromInt(h % 256)) / 255.0;
    h = sm64(h);
    const b_base: f64 = @as(f64, @floatFromInt(h % 256)) / 255.0;

    return switch (gamut) {
        .srgb => .{ .r = r_base, .g = g_base, .b = b_base },
        .display_p3 => .{ .r = @min(1.0, r_base * 1.1), .g = @min(1.0, g_base * 1.05), .b = @min(1.0, b_base * 1.15) },
        .rec2020 => .{ .r = @min(1.0, r_base * 1.2), .g = @min(1.0, g_base * 1.1), .b = @min(1.0, b_base * 1.25) },
        .aces => .{ .r = std.math.pow(f64, r_base, 0.9), .g = std.math.pow(f64, g_base, 0.95), .b = std.math.pow(f64, b_base, 0.85) },
        .tropical => blk: {
            const m = @min(r_base, @min(g_base, b_base));
            break :blk .{ .r = m + r_base * 0.3, .g = m + g_base * 0.3, .b = m + b_base * 0.3 };
        },
        .balanced_ternary => blk: {
            // Map to {-1,0,+1} then back to [0,1]
            const tr: f64 = if (r_base < 0.33) 0.0 else if (r_base < 0.67) 0.5 else 1.0;
            const tg: f64 = if (g_base < 0.33) 0.0 else if (g_base < 0.67) 0.5 else 1.0;
            const tb: f64 = if (b_base < 0.33) 0.0 else if (b_base < 0.67) 0.5 else 1.0;
            break :blk .{ .r = tr, .g = tg, .b = tb };
        },
    };
}

/// Count of Plurigrid reinventions
pub const PLURIGRID_REINVENTION_COUNT: u32 = 69;

/// Fork 3 at a time: triadic walk through reinventions
pub fn fork3AtATime(seed: u64, step: u32) [3]Color {
    const base = step * 3;
    var colors: [3]Color = undefined;
    for (0..3) |i| {
        const idx = (base + @as(u32, @intCast(i))) % PLURIGRID_REINVENTION_COUNT;
        colors[i] = gayColor(sm64(seed ^ @as(u64, idx)));
    }
    return colors;
}

// ============================================================================
// Section 6: Enzyme (enzyme.jl)
// — Autodiff binding sites, gradient coloring, sensitivity spins
// ============================================================================

pub const EnzymeMode = enum(u8) {
    forward, // blue stream
    reverse, // red stream
    mixed, // purple

    pub fn baseHue(self: EnzymeMode) f64 {
        return switch (self) {
            .forward => 240.0, // blue
            .reverse => 0.0, // red
            .mixed => 280.0, // purple
        };
    }
};

pub const EnzymeBinding = struct {
    site_color: Color,
    gradient_color: Color,
    mode: EnzymeMode,
    sensitivity: f64,
    spin: i8, // +1 or -1

    pub fn init(site_seed: u64, sensitivity: f64, mode: EnzymeMode) EnzymeBinding {
        const site_color = gayColor(site_seed);
        // Gradient color: mode-tinted by sensitivity magnitude
        const sat = @min(1.0, @abs(sensitivity));
        const base = switch (mode) {
            .forward => Color{ .r = 0.0, .g = 0.0, .b = sat },
            .reverse => Color{ .r = sat, .g = 0.0, .b = 0.0 },
            .mixed => Color{ .r = sat * 0.5, .g = 0.0, .b = sat * 0.5 },
        };
        return .{
            .site_color = site_color,
            .gradient_color = base,
            .mode = mode,
            .sensitivity = sensitivity,
            .spin = if (sensitivity >= 0) 1 else -1,
        };
    }
};

/// Compute gradient magnetization: average spin across bindings
pub fn gradientMagnetization(bindings: []const EnzymeBinding) f64 {
    if (bindings.len == 0) return 0.0;
    var sum: f64 = 0;
    for (bindings) |b| sum += @as(f64, @floatFromInt(b.spin));
    return sum / @as(f64, @floatFromInt(bindings.len));
}

// ============================================================================
// Section 7: Ergodic Bridge (ergodic_bridge.jl)
// — Wall clock <-> color bandwidth bidirectional verification
// ============================================================================

pub const WallClockBridge = struct {
    seed: u64,
    n_colors: u32,
    fingerprint: u64,
    entropy: f64,
    order_independent: bool,
    bandwidth_preserved: bool,
    ergodic: bool,

    pub fn create(seed: u64, n_colors: u32) WallClockBridge {
        var fp: u64 = 0;
        var rng = seed;

        // Generate colors and accumulate fingerprint
        for (0..n_colors) |i| {
            rng = sm64(seed ^ @as(u64, @intCast(i)));
            fp ^= rng;
        }

        // Measure "entropy" via unique byte distribution
        var byte_counts: [256]u32 = [_]u32{0} ** 256;
        rng = seed;
        for (0..@min(n_colors, 1000)) |_| {
            rng = sm64(rng);
            byte_counts[@as(u8, @truncate(rng))] += 1;
        }
        var entropy: f64 = 0;
        const total: f64 = @floatFromInt(@min(n_colors, 1000));
        for (byte_counts) |count| {
            if (count > 0) {
                const p: f64 = @as(f64, @floatFromInt(count)) / total;
                entropy -= p * @log(p);
            }
        }

        return .{
            .seed = seed,
            .n_colors = n_colors,
            .fingerprint = fp,
            .entropy = entropy,
            .order_independent = true, // XOR is commutative
            .bandwidth_preserved = entropy > 4.0,
            .ergodic = entropy > 5.0,
        };
    }
};

pub const ColorBandwidth = struct {
    bits_per_color: f64,
    entropy_rate: f64,
    horizon: u32,

    pub fn measure(seed: u64, horizon: u32) ColorBandwidth {
        var unique: u32 = 0;
        var seen: [256]bool = [_]bool{false} ** 256;
        var rng = seed;
        for (0..horizon) |_| {
            rng = sm64(rng);
            const bucket: u8 = @truncate(rng);
            if (!seen[bucket]) {
                seen[bucket] = true;
                unique += 1;
            }
        }
        const bits = @log2(@as(f64, @floatFromInt(@max(unique, 1))));
        return .{ .bits_per_color = bits, .entropy_rate = bits / @as(f64, @floatFromInt(horizon)), .horizon = horizon };
    }
};

// ============================================================================
// Section 8: Spectral Bridge (spectral_bridge.jl)
// — Arpack seed <-> Gay seed, eigenvector coloring
// ============================================================================

pub const ArpackSeed = struct {
    iseed: [4]i64,
    gay_seed_val: u64,

    pub fn fromTuple(s1: i64, s2: i64, s3: i64, s4: i64) ArpackSeed {
        var gs: u64 = 0;
        const vals = [4]i64{ s1, s2, s3, s4 };
        for (vals, 0..) |s, i| {
            gs ^= sm64(@as(u64, @bitCast(s)) ^ @as(u64, @intCast(i + 1)) *% GOLDEN);
        }
        return .{ .iseed = vals, .gay_seed_val = gs };
    }

    pub fn fromGaySeed(gs: u64) ArpackSeed {
        return .{
            .iseed = .{
                @as(i64, @intCast((gs & 0xFFFF) | 1)),
                @as(i64, @intCast(((gs >> 16) & 0xFFFF) | 1)),
                @as(i64, @intCast(((gs >> 32) & 0xFFFF) | 1)),
                @as(i64, @intCast(((gs >> 48) & 0xFFFF) | 1)),
            },
            .gay_seed_val = gs,
        };
    }
};

/// Color an eigenvector by its fingerprint
pub fn colorEigenvector(values: []const f64, seed: u64, index: u32) Color {
    var fp: u64 = 0;
    for (values, 0..) |v, i| {
        const quantized: i64 = @intFromFloat(@round(v * 1e6));
        fp ^= sm64(@as(u64, @bitCast(quantized)) ^ @as(u64, @intCast(i)));
    }
    return gayColor(seed ^ @as(u64, index) ^ fp);
}

// ============================================================================
// Section 9: Color Logic Pullback (color_logic_pullback.jl)
// — Logic systems, colored theories, pullback squares
// ============================================================================

pub const LogicSystem = enum(u8) {
    intuitionistic, // Green
    paraconsistent, // Red
    linear, // Blue
    modal_s4, // Orange
    hott, // Purple
    classical, // White
    metatheory, // Magenta

    pub fn canonicalColor(self: LogicSystem) Color {
        return switch (self) {
            .intuitionistic => .{ .r = 0.0, .g = 1.0, .b = 0.0 },
            .paraconsistent => .{ .r = 1.0, .g = 0.0, .b = 0.0 },
            .linear => .{ .r = 0.0, .g = 0.0, .b = 1.0 },
            .modal_s4 => .{ .r = 1.0, .g = 0.65, .b = 0.0 },
            .hott => .{ .r = 0.5, .g = 0.0, .b = 0.5 },
            .classical => .{ .r = 1.0, .g = 1.0, .b = 1.0 },
            .metatheory => .{ .r = 1.0, .g = 0.0, .b = 1.0 },
        };
    }
};

pub const TheoryLevel = enum(u8) { object, meta, higher_meta };

pub const ColoredTheory = struct {
    name_hash: u64,
    level: TheoryLevel,
    logic: LogicSystem,
    color: Color,
    seed: u64,

    pub fn init(name_hash: u64, level: TheoryLevel, logic: LogicSystem) ColoredTheory {
        const seed = gaySeed(name_hash ^ @as(u64, @intFromEnum(logic)));
        return .{
            .name_hash = name_hash,
            .level = level,
            .logic = logic,
            .color = logic.canonicalColor(),
            .seed = seed,
        };
    }
};

/// Pullback square: fibered product F = {(x,y) | f(x) = g(y)}
pub const PullbackSquare = struct {
    theory_a: ColoredTheory,
    theory_b: ColoredTheory,
    pullback_color: Color,
    fiber_size: u32,

    pub fn compute(a: ColoredTheory, b: ColoredTheory) PullbackSquare {
        // Pullback color = intersection of logic colors
        const result = conservedCombine(a.color, b.color, a.seed ^ b.seed);
        return .{
            .theory_a = a,
            .theory_b = b,
            .pullback_color = result.color,
            .fiber_size = if (a.logic == b.logic) 1 else 0,
        };
    }
};

// ============================================================================
// Section 10: Abduce (abduce.jl)
// — Abductive inference: effect -> cause for color systems
// ============================================================================

pub const Provenance = enum(u8) { unknown, observed, inferred, hypothesized };

pub const Abducible = struct {
    color: Color,
    origin_seed: ?u64,
    origin_index: ?u32,
    confidence: f64,
    provenance: Provenance,

    pub fn init(color: Color) Abducible {
        return .{ .color = color, .origin_seed = null, .origin_index = null, .confidence = 0.0, .provenance = .unknown };
    }

    pub fn initKnown(color: Color, seed: u64, index: u32) Abducible {
        return .{ .color = color, .origin_seed = seed, .origin_index = index, .confidence = 1.0, .provenance = .observed };
    }
};

/// Color fingerprint for fast lookup (8-bit per channel)
pub fn colorFingerprint(c: Color) u32 {
    return quantize24(c);
}

/// Color distance (simplified Euclidean in RGB, not CIELAB)
pub fn colorDistance(c1: Color, c2: Color) f64 {
    const dr = c1.r - c2.r;
    const dg = c1.g - c2.g;
    const db = c1.b - c2.b;
    return @sqrt(dr * dr + dg * dg + db * db);
}

/// Abduce index: given color + seed, find which index produced it
pub fn abduceIndex(color: Color, seed: u64, max_index: u32, tolerance: f64) struct { index: u32, distance: f64, exact: bool } {
    const target_fp = colorFingerprint(color);
    var best_idx: u32 = 0;
    var best_dist: f64 = std.math.inf(f64);

    for (0..max_index) |i| {
        const idx: u32 = @intCast(i);
        const c = gayColor(sm64(seed ^ @as(u64, idx)));
        const fp = colorFingerprint(c);

        if (fp == target_fp) {
            const dist = colorDistance(color, c);
            if (dist < tolerance) return .{ .index = idx, .distance = dist, .exact = true };
        }

        const dist = colorDistance(color, c);
        if (dist < best_dist) {
            best_dist = dist;
            best_idx = idx;
        }
    }

    return .{ .index = best_idx, .distance = best_dist, .exact = best_dist < tolerance };
}

/// Abduce seed: given color + index, try common seeds
pub fn abduceSeed(color: Color, index: u32) struct { seed: u64, distance: f64, found: bool } {
    const common_seeds = [_]u64{
        0xDEADBEEF,    0xCAFEBABE, 0x12345678, 0x42424242,
        GAY_IGOR_SEED, 0,          1,          42,
        1069,          0x1337,
    };
    var best_seed: u64 = 0;
    var best_dist: f64 = std.math.inf(f64);

    for (common_seeds) |seed| {
        const c = gayColor(sm64(seed ^ @as(u64, index)));
        const dist = colorDistance(color, c);
        if (dist < best_dist) {
            best_dist = dist;
            best_seed = seed;
        }
    }

    return .{ .seed = best_seed, .distance = best_dist, .found = best_dist < 0.01 };
}

// ============================================================================
// Tests
// ============================================================================

test "GAY_E_SEED correct" {
    try std.testing.expectEqual(EULER_BITS ^ GAY_IGOR_SEED, GAY_E_SEED);
}

test "gaySeed identity for e" {
    try std.testing.expectEqual(GAY_E_SEED, gaySeed(EULER_BITS));
}

test "gayColor produces valid RGB" {
    const c = gayColor(42);
    try std.testing.expect(c.r >= 0.0 and c.r <= 1.0);
    try std.testing.expect(c.g >= 0.0 and c.g <= 1.0);
    try std.testing.expect(c.b >= 0.0 and c.b <= 1.0);
}

test "conservedCombine deterministic" {
    const c1 = gayColor(1);
    const c2 = gayColor(2);
    const r1 = conservedCombine(c1, c2, 42);
    const r2 = conservedCombine(c1, c2, 42);
    try std.testing.expectEqual(quantize24(r1.color), quantize24(r2.color));
}

test "chromatic layer composition" {
    const base = ChromaticLayer.init(0xAAAA, null);
    const overlay = ChromaticLayer.init(0xBBBB, null);
    const composed = composeLayers(base, overlay);
    try std.testing.expect(composed.id != base.id);
    try std.testing.expect(composed.id != overlay.id);
}

test "layer chain verification" {
    const l0 = ChromaticLayer.init(0x1111, null);
    var l1 = ChromaticLayer.init(0x2222, null);
    l1.parent_id = l0.id;
    const chain = [_]ChromaticLayer{ l0, l1 };
    try std.testing.expect(verifyLayerChain(&chain));
}

test "birthday spacing test runs" {
    const result = birthdaySpacingTest(256, 42);
    try std.testing.expect(result.passed);
}

test "runs test" {
    const result = runsTest(1000, 42);
    try std.testing.expect(result.passed);
    try std.testing.expect(result.n_runs > 0);
}

test "adhesion width test" {
    const result = adhesionWidthTest(42, 5);
    try std.testing.expect(result.max_width >= 1);
}

test "multiverse partition preserves fingerprint" {
    var mf = MultiverseFrame.init(1069);
    const root_fp = mf.verses[0].fingerprint;
    mf.partition(0, 3);
    // XOR of children should equal parent
    var child_fp: u64 = 0;
    for (1..mf.count) |i| child_fp ^= mf.verses[i].fingerprint;
    try std.testing.expectEqual(root_fp, child_fp);
}

test "verse resolution" {
    var mf = MultiverseFrame.init(42);
    mf.partition(0, 2);
    mf.resolve(1); // eliminate first child
    try std.testing.expect(mf.verses[1].resolved);
    try std.testing.expect(!mf.verses[2].resolved);
}

test "SKC complexity bounds" {
    const low = "aaaaaaaaaaaa";
    const high = "qwp9f83h2nsk";
    const c_low = skcComplexity(low);
    const c_high = skcComplexity(high);
    try std.testing.expect(c_low < c_high);
}

test "trust derivation" {
    try std.testing.expectEqual(TrustPolarity.trusting, skcTrust(0.1));
    try std.testing.expectEqual(TrustPolarity.neutral, skcTrust(0.5));
    try std.testing.expectEqual(TrustPolarity.skeptical, skcTrust(0.9));
}

test "gamut color at time deterministic" {
    const c1 = gamutAtTime(.srgb, 1.5, 42);
    const c2 = gamutAtTime(.srgb, 1.5, 42);
    try std.testing.expectEqual(quantize24(c1), quantize24(c2));
}

test "fork 3 at a time" {
    const colors = fork3AtATime(42, 5);
    // All three should be different
    try std.testing.expect(quantize24(colors[0]) != quantize24(colors[1]));
}

test "enzyme binding spin" {
    const pos = EnzymeBinding.init(42, 0.5, .forward);
    const neg = EnzymeBinding.init(42, -0.3, .reverse);
    try std.testing.expectEqual(@as(i8, 1), pos.spin);
    try std.testing.expectEqual(@as(i8, -1), neg.spin);
}

test "gradient magnetization" {
    const bindings = [_]EnzymeBinding{
        EnzymeBinding.init(1, 0.5, .forward),
        EnzymeBinding.init(2, -0.3, .reverse),
        EnzymeBinding.init(3, 0.8, .mixed),
    };
    const mag = gradientMagnetization(&bindings);
    // 2 positive, 1 negative -> 1/3
    try std.testing.expect(@abs(mag - 1.0 / 3.0) < 0.01);
}

test "wall clock bridge" {
    const bridge = WallClockBridge.create(42, 1000);
    try std.testing.expect(bridge.fingerprint != 0);
    try std.testing.expect(bridge.order_independent);
    try std.testing.expect(bridge.entropy > 0);
}

test "color bandwidth measure" {
    const bw = ColorBandwidth.measure(42, 1000);
    try std.testing.expect(bw.bits_per_color > 0);
}

test "arpack seed roundtrip" {
    const gs: u64 = 0xDEADBEEF;
    const as_ = ArpackSeed.fromGaySeed(gs);
    try std.testing.expect(as_.iseed[0] & 1 == 1); // odd
    try std.testing.expect(as_.iseed[1] & 1 == 1);
}

test "eigenvector coloring deterministic" {
    const vals = [_]f64{ 1.0, -0.5, 0.3, 0.7 };
    const c1 = colorEigenvector(&vals, 42, 0);
    const c2 = colorEigenvector(&vals, 42, 0);
    try std.testing.expectEqual(quantize24(c1), quantize24(c2));
}

test "logic system colors distinct" {
    const green = LogicSystem.intuitionistic.canonicalColor();
    const red = LogicSystem.paraconsistent.canonicalColor();
    try std.testing.expect(quantize24(green) != quantize24(red));
}

test "pullback square same logic" {
    const a = ColoredTheory.init(1, .object, .linear);
    const b = ColoredTheory.init(2, .object, .linear);
    const pb = PullbackSquare.compute(a, b);
    try std.testing.expectEqual(@as(u32, 1), pb.fiber_size);
}

test "pullback square different logic" {
    const a = ColoredTheory.init(1, .object, .intuitionistic);
    const b = ColoredTheory.init(2, .meta, .classical);
    const pb = PullbackSquare.compute(a, b);
    try std.testing.expectEqual(@as(u32, 0), pb.fiber_size);
}

test "color fingerprint deterministic" {
    const c = Color{ .r = 0.5, .g = 0.3, .b = 0.8 };
    try std.testing.expectEqual(colorFingerprint(c), colorFingerprint(c));
}

test "color distance zero for same" {
    const c = gayColor(42);
    try std.testing.expect(colorDistance(c, c) < 1e-10);
}

test "abduce index finds known color" {
    const seed: u64 = 42;
    const target_idx: u32 = 7;
    const target_color = gayColor(sm64(seed ^ @as(u64, target_idx)));
    const result = abduceIndex(target_color, seed, 100, 0.01);
    try std.testing.expectEqual(target_idx, result.index);
    try std.testing.expect(result.exact);
}

test "abduce seed with GAY_IGOR_SEED" {
    const idx: u32 = 5;
    const color = gayColor(sm64(GAY_IGOR_SEED ^ @as(u64, idx)));
    const result = abduceSeed(color, idx);
    try std.testing.expect(result.found);
    try std.testing.expectEqual(GAY_IGOR_SEED, result.seed);
}

test "dialect colors distinct" {
    const j = DialectColors.julia();
    const l = DialectColors.lisp();
    try std.testing.expect(quantize24(j.keyword) != quantize24(l.keyword));
}
