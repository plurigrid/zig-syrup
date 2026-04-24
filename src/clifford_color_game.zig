//! Geometric Color Game Oracle
//!
//! Lifts the three color games (conservation, distinguishability, entropy)
//! into Clifford algebra so that game equilibria become geometric fixed points
//! of rotor actions, verifiable via the type system and TOFU fingerprinting.
//!
//! The three games from open_color_games.py as geometric operations:
//!
//! 1. **Conservation Game** (Fixed Point):
//!    A derangement sigma permutes players. Each player has a color (trit).
//!    Equilibrium iff trit sum = 0 (mod 3) across each sigma-orbit.
//!    GEOMETRIC: colors are multivectors, conservation = sandwich norm preservation.
//!    R * v * R~ has |R*v*R~| = |v|. The rotor IS the derangement.
//!
//! 2. **Distinguishability Game**:
//!    Two agents must be distinguishable by their colors.
//!    GEOMETRIC: inner product <a,b> / (|a||b|) measures similarity.
//!    Distinguishable iff angle > threshold. Wedge product a^b != 0.
//!
//! 3. **Entropy Witness Game**:
//!    A sequence of trits must carry real entropy (not degenerate).
//!    GEOMETRIC: the multivector sum of N random elements should fill
//!    multiple grades. Grade concentration = low entropy.
//!
//! The algebra: Algebra(2,0,1) -- 2D color space + 1 degenerate availability.
//!   e0: R-channel axis (minus trit)
//!   e1: G-channel axis (plus trit)
//!   e2: degenerate luminosity (zero trit, e2^2 = 0)
//!
//! This matches entangle.zig: sigma permutes (R,G,B) channels cyclically,
//! which in the algebra is a 120-degree rotor in the e0-e1 plane.

const std = @import("std");
const math = std.math;
const testing = std.testing;
const clifford = @import("clifford");
const clifford_analytic = @import("clifford_analytic");

/// The color game algebra: 2 Euclidean + 1 degenerate.
/// dim = 2^3 = 8 basis blades.
const CGA = clifford.Algebra(2, 0, 1);
const Ana = clifford_analytic.Analytic(2, 0, 1);

/// GF(3) trit matching existing codebase convention.
pub const Trit = enum(i8) {
    minus = -1,
    zero = 0,
    plus = 1,

    pub fn add(a: Trit, b: Trit) Trit {
        const sum = @as(i16, @intFromEnum(a)) + @as(i16, @intFromEnum(b));
        return switch (@mod(sum + 3, 3)) {
            0 => .zero,
            1 => .plus,
            2 => .minus,
            else => unreachable,
        };
    }

    pub fn neg(self: Trit) Trit {
        return switch (self) {
            .minus => .plus,
            .zero => .zero,
            .plus => .minus,
        };
    }
};

// ============================================================================
// Color -> Multivector embedding
// ============================================================================

/// Embed an RGB color into the algebra as a vector (grade 1).
///
/// R maps to e0 (Euclidean, squares to +1)
/// G maps to e1 (Euclidean, squares to +1)
/// B maps to e2 (degenerate, squares to 0)
///
/// Normalization: channels scaled to [0, 1] as direct intensities.
pub fn embedColor(r: u8, g: u8, b: u8) CGA {
    var mv = CGA.zero();
    mv.coeffs[1] = @as(f64, @floatFromInt(r)) / 255.0; // e0: red intensity
    mv.coeffs[2] = @as(f64, @floatFromInt(g)) / 255.0; // e1: green intensity
    mv.coeffs[4] = @as(f64, @floatFromInt(b)) / 255.0; // e2: blue (degenerate)
    return mv;
}

/// Embed a trit as a unit multivector.
/// minus -> -e0 (red dominant)
/// zero  -> e2  (balanced/degenerate)
/// plus  -> +e1 (green dominant)
pub fn embedTrit(t: Trit) CGA {
    return switch (t) {
        .minus => blk: {
            var mv = CGA.zero();
            mv.coeffs[1] = -1.0; // -e0
            break :blk mv;
        },
        .zero => blk: {
            var mv = CGA.zero();
            mv.coeffs[4] = 1.0; // e2 (degenerate)
            break :blk mv;
        },
        .plus => blk: {
            var mv = CGA.zero();
            mv.coeffs[2] = 1.0; // +e1
            break :blk mv;
        },
    };
}

/// Embedding strategy selector.
pub const EmbeddingKind = enum {
    /// v * R: color times sigma rotor. Grade spread: 2/4.
    rotor_product,
    /// exp(v): exponential map of the color vector. Grade spread: 2/4 (even grades only for vectors).
    exponential,
    /// v + v^R + scalar(|v|): vector + bivector wedge + scalar norm. Manually fills 3 grades.
    wedge_augmented,
    /// v * R + R * v: anticommutator. Symmetric part = scalar + bivector contributions.
    anticommutator,
    /// exp(v * e01): rotor from color-weighted bivector. All-grade spread for non-axis-aligned colors.
    bivector_rotor,
};

/// Rich embedding: multiple strategies for lifting RGB into mixed-grade multivectors.
///
/// The plain embedding (embedColor) lives entirely in grade 1, giving zero
/// grade entropy. Rich embeddings spread energy across grades, enabling
/// the entropy witness game to measure real information content.
///
/// Each strategy has different geometric meaning:
///   rotor_product:   "how does this color transform under sigma?"
///   exponential:     "what rotation does this color generate?"
///   wedge_augmented: "color + its area element + its magnitude"
///   anticommutator:  "symmetric interaction between color and sigma"
///   bivector_rotor:  "the rotor living in this color's bivector plane"
pub fn embedColorRich(r: u8, g: u8, b: u8) CGA {
    return embedColorRichWith(r, g, b, .rotor_product);
}

pub fn embedColorRichWith(r: u8, g: u8, b: u8, kind: EmbeddingKind) CGA {
    const v = embedColor(r, g, b);
    return switch (kind) {
        .rotor_product => blk: {
            // v * R is mixed-grade: vector * (scalar + bivector) = scalar + vector + bivector + trivector
            break :blk v.mul(sigmaRotor(1));
        },
        .exponential => blk: {
            // exp(v) = cosh(|v|) + sinh(|v|)/|v| * v for Euclidean vectors
            // For degenerate components: exp(ae2) = 1 + ae2 (nilpotent)
            const result = Ana.exp(v);
            break :blk result.value;
        },
        .wedge_augmented => blk: {
            // Manually construct: scalar(|v|) + v + v^sigma(v) fills grades 0,1,2
            const rotor = sigmaRotor(1);
            const rv = rotor.sandwich(v);
            const wedge_part = v.wedge(rv);
            const norm_scalar = CGA.scalar(v.norm());
            // Also add pseudoscalar from triple product for grade 3
            const e0 = CGA.basis(0);
            const e1 = CGA.basis(1);
            const e2 = CGA.basis(2);
            const ps = e0.wedge(e1).wedge(e2);
            const lum = (v.coeffs[1] + v.coeffs[2] + v.coeffs[4]) / 3.0;
            break :blk norm_scalar.add(v).add(wedge_part).add(ps.scale(lum));
        },
        .anticommutator => blk: {
            // {v, R} = v*R + R*v: symmetric part extracts scalar + bivector
            const rotor = sigmaRotor(1);
            const vr = v.mul(rotor);
            const rv = rotor.mul(v);
            break :blk vr.add(rv).scale(0.5);
        },
        .bivector_rotor => blk: {
            // Build a bivector from color channels, then exponentiate
            // B = r*e01 + g*e02 + b*e12, then exp(B) = cos|B| + sin|B|/|B| * B
            const rf = @as(f64, @floatFromInt(r)) / 255.0;
            const gf = @as(f64, @floatFromInt(g)) / 255.0;
            const bf = @as(f64, @floatFromInt(b)) / 255.0;
            var bv = CGA.zero();
            bv.coeffs[0b011] = rf; // e01
            bv.coeffs[0b101] = gf; // e02
            bv.coeffs[0b110] = bf; // e12
            const result = Ana.exp(bv);
            break :blk result.value;
        },
    };
}

/// Extract trit from a multivector by dominant channel.
pub fn extractTrit(mv: CGA) Trit {
    const r_mag = @abs(mv.coeffs[1]); // e0
    const g_mag = @abs(mv.coeffs[2]); // e1
    const b_mag = @abs(mv.coeffs[4]); // e2
    if (r_mag > g_mag and r_mag > b_mag) return .minus;
    if (g_mag > r_mag and g_mag > b_mag) return .plus;
    return .zero;
}

// ============================================================================
// The CNOT3 rotor: cyclic permutation as 120-degree rotation
// ============================================================================

/// The sigma rotor: 120-degree rotation in the e0-e1 plane.
/// sigma^0 = identity, sigma^1 = rotate 120, sigma^2 = rotate 240.
///
/// This is exp(2*pi/3 / 2 * e01) = cos(pi/3) + sin(pi/3) * e01
///                                = 0.5 + 0.866 * e01
///
/// Matches entangle.zig: sigma^1(R,G,B) = (G,B,R)
pub fn sigmaRotor(order: i8) CGA {
    if (order == 0) return CGA.scalar(1.0);
    const angle: f64 = @as(f64, @floatFromInt(order)) * 2.0 * math.pi / 3.0;
    const e0 = CGA.basis(0);
    const e1 = CGA.basis(1);
    const e01 = e0.wedge(e1);
    const half = angle / 2.0;
    return CGA.scalar(@cos(half)).add(e01.scale(@sin(half)));
}

// ============================================================================
// Game 1: Conservation (Fixed Point Game)
// ============================================================================

/// Result of the conservation game for a pair of players.
pub const ConservationResult = struct {
    /// Trit sum of the pair (should be 0 for equilibrium).
    trit_sum: i8,
    /// Whether the pair is in equilibrium.
    equilibrium: bool,
    /// Norm of player A's color after sandwich by derangement rotor.
    norm_preserved: bool,
    /// The rotor that maps player A to player B's frame.
    rotor_angle: f64,
};

/// Conservation game: does the derangement sigma preserve the trit sum?
///
/// Geometric version: apply the sigma rotor as a sandwich product.
/// If R * colorA * R~ has the same norm as colorA, norm is conserved.
/// If trit(colorA) + trit(R * colorA * R~) = 0 mod 3, equilibrium holds.
pub fn conservationGame(color_a: CGA, color_b: CGA, sigma_order: i8) ConservationResult {
    const rotor = sigmaRotor(sigma_order);
    const rotated = rotor.sandwich(color_a);

    const norm_a = color_a.norm();
    const norm_rot = rotated.norm();
    const norm_preserved = @abs(norm_a - norm_rot) < 1e-8 or norm_a < 1e-12;

    const trit_a = extractTrit(color_a);
    const trit_b = extractTrit(color_b);
    const sum = @as(i8, @intFromEnum(trit_a)) + @as(i8, @intFromEnum(trit_b));
    const equilibrium = @mod(sum + 6, 3) == 0;

    const angle: f64 = @as(f64, @floatFromInt(sigma_order)) * 2.0 * math.pi / 3.0;

    return .{
        .trit_sum = @intCast(@mod(sum + 6, 3)),
        .equilibrium = equilibrium,
        .norm_preserved = norm_preserved,
        .rotor_angle = angle,
    };
}

// ============================================================================
// Game 2: Distinguishability
// ============================================================================

/// Result of the distinguishability game for a pair.
pub const DistinguishResult = struct {
    /// Cosine similarity (inner product / norms). 1.0 = identical, 0.0 = orthogonal.
    cosine_similarity: f64,
    /// Wedge product norm: magnitude of the bivector part.
    /// Zero means collinear (indistinguishable direction).
    wedge_norm: f64,
    /// Whether the pair is distinguishable (wedge_norm > threshold).
    distinguishable: bool,
    /// Hamming-analog: Euclidean distance in the algebra.
    distance: f64,
};

/// Distinguishability game: can two colors be told apart?
///
/// Geometric version: compute the inner product (scalar of a*reverse(b))
/// and the wedge product (antisymmetric part).
///
/// - Inner product measures overlap (cosine similarity).
/// - Wedge product measures independence (area of parallelogram).
/// - If wedge is zero, the colors are collinear = indistinguishable.
pub fn distinguishGame(color_a: CGA, color_b: CGA, threshold: f64) DistinguishResult {
    // Inner product: scalar part of a * reverse(b)
    const inner = color_a.mul(color_b.reverse()).scalarPart();
    const norm_a = color_a.norm();
    const norm_b = color_b.norm();
    const denom = norm_a * norm_b;
    const cosine = if (denom > 1e-12) inner / denom else 0.0;

    // Wedge product: antisymmetric part
    const wedge = color_a.wedge(color_b);
    const wedge_norm = wedge.norm();

    // Distance: norm of difference
    const diff = color_a.sub(color_b);
    const distance = diff.norm();

    return .{
        .cosine_similarity = cosine,
        .wedge_norm = wedge_norm,
        .distinguishable = wedge_norm > threshold or distance > threshold,
        .distance = distance,
    };
}

// ============================================================================
// Game 3: Entropy Witness
// ============================================================================

/// Result of the entropy witness game for a sequence.
pub const EntropyResult = struct {
    /// Number of grades with significant energy.
    active_grades: u32,
    /// Total grades possible (N+1 for Algebra(N)).
    total_grades: u32,
    /// Grade entropy: -sum(p_k * log(p_k)) where p_k = energy_k / total_energy.
    grade_entropy: f64,
    /// Maximum possible entropy (log(total_grades)).
    max_entropy: f64,
    /// Entropy ratio: grade_entropy / max_entropy. 1.0 = maximally spread.
    entropy_ratio: f64,
    /// Whether the sequence passes the entropy witness test.
    sufficient_entropy: bool,
};

/// Entropy witness game: does a sequence of multivectors carry real entropy?
///
/// Geometric version: sum N multivectors and measure how many grades
/// have significant energy. If the sum concentrates in one grade,
/// entropy is low (degenerate sequence). If energy spreads across
/// all grades, entropy is high.
///
/// This replaces the trit-window pattern counting from open_color_games.py
/// with a grade-spread measure that captures higher-order correlations.
pub fn entropyWitness(elements: []const CGA, min_ratio: f64) EntropyResult {
    const N = CGA.N; // 3 for Algebra(2,0,1)
    const total_grades: u32 = N + 1; // grades 0, 1, 2, 3

    // Accumulate energy per grade
    var grade_energy: [total_grades]f64 = [_]f64{0} ** total_grades;
    var total_energy: f64 = 0;

    for (elements) |elem| {
        for (0..CGA.DIM) |bi| {
            const g = @popCount(@as(u32, @intCast(bi)));
            const e = elem.coeffs[bi] * elem.coeffs[bi];
            grade_energy[g] += e;
            total_energy += e;
        }
    }

    if (total_energy < 1e-14) {
        return .{
            .active_grades = 0,
            .total_grades = total_grades,
            .grade_entropy = 0,
            .max_entropy = @log(@as(f64, @floatFromInt(total_grades))),
            .entropy_ratio = 0,
            .sufficient_entropy = false,
        };
    }

    // Compute Shannon entropy over grade distribution
    var entropy: f64 = 0;
    var active: u32 = 0;
    for (0..total_grades) |k| {
        const p = grade_energy[k] / total_energy;
        if (p > 1e-12) {
            entropy -= p * @log(p);
            active += 1;
        }
    }

    const max_ent = @log(@as(f64, @floatFromInt(total_grades)));
    const ratio = if (max_ent > 0) entropy / max_ent else 0;

    return .{
        .active_grades = active,
        .total_grades = total_grades,
        .grade_entropy = entropy,
        .max_entropy = max_ent,
        .entropy_ratio = ratio,
        .sufficient_entropy = ratio >= min_ratio,
    };
}

// ============================================================================
// Game 4: Bisimulation (behavioral equivalence)
// ============================================================================

/// Result of the bisimulation game for a pair.
pub const BisimulationResult = struct {
    /// Trit of color A.
    trit_a: Trit,
    /// Trit of color B (deranged partner).
    trit_b: Trit,
    /// Whether the pair is bisimilar (same observable behavior = same trit).
    bisimilar: bool,
    /// Geometric distance between the two color embeddings.
    /// Bisimilar pairs should have small angular distance modulo the sigma rotor.
    angular_distance: f64,
    /// Inner product of the trit embeddings (1.0 = same direction, -1.0 = opposite).
    trit_alignment: f64,
};

/// Bisimulation game: do two colors exhibit the same observable behavior?
///
/// In open_color_games.py: bisimilar iff trit_i == trit_sigma(i).
/// Geometric version: embed both trits, compute their inner product.
/// Bisimilar iff the trit embeddings are parallel (inner product = +1).
///
/// Additionally, we measure the angular distance between the full color
/// multivectors after normalizing, which captures higher-order similarity
/// beyond just the dominant channel.
pub fn bisimulationGame(color_a: CGA, color_b: CGA) BisimulationResult {
    const trit_a = extractTrit(color_a);
    const trit_b = extractTrit(color_b);

    // Trit-level: embed and inner product
    const ta = embedTrit(trit_a);
    const tb = embedTrit(trit_b);
    const trit_inner = ta.mul(tb.reverse()).scalarPart();
    const ta_norm = ta.norm();
    const tb_norm = tb.norm();
    const trit_denom = ta_norm * tb_norm;
    const trit_alignment = if (trit_denom > 1e-12) trit_inner / trit_denom else 0.0;

    // Full color angular distance
    const na = color_a.norm();
    const nb = color_b.norm();
    const inner = color_a.mul(color_b.reverse()).scalarPart();
    const denom = na * nb;
    const cos_angle = if (denom > 1e-12) @min(1.0, @max(-1.0, inner / denom)) else 0.0;
    const angular_distance = math.acos(cos_angle);

    return .{
        .trit_a = trit_a,
        .trit_b = trit_b,
        .bisimilar = trit_a == trit_b,
        .angular_distance = angular_distance,
        .trit_alignment = trit_alignment,
    };
}

// ============================================================================
// Game 5: Indistinguishability (epsilon-close clustering)
// ============================================================================

/// Result of the indistinguishability game for a pair.
pub const IndistinguishabilityResult = struct {
    /// Euclidean distance in the algebra.
    distance: f64,
    /// Whether the pair is within epsilon (indistinguishable).
    indistinguishable: bool,
    /// The grade at which the difference is concentrated.
    /// If difference is purely in the degenerate (grade with e2),
    /// the colors are "perceptually" indistinguishable.
    degenerate_fraction: f64,
};

/// Indistinguishability game: are two colors epsilon-close?
///
/// In open_color_games.py: colors are bucketed by hue prefix.
/// Geometric version: compute the difference multivector and decompose it.
/// If the difference lives mostly in the degenerate direction (e2),
/// the colors are perceptually indistinguishable even if numerically different.
///
/// This captures a subtlety the Python version misses: two colors can differ
/// in luminosity (degenerate axis) without being distinguishable in hue.
pub fn indistinguishabilityGame(color_a: CGA, color_b: CGA, epsilon: f64) IndistinguishabilityResult {
    const diff = color_a.sub(color_b);
    const distance = diff.norm();

    // Decompose: how much of the difference is in the degenerate direction?
    // e2 is basis index 4 (binary 100)
    const degen_energy = diff.coeffs[4] * diff.coeffs[4];
    const total_energy = blk: {
        var sum: f64 = 0;
        for (diff.coeffs) |c| sum += c * c;
        break :blk sum;
    };
    const degenerate_fraction = if (total_energy > 1e-14) degen_energy / total_energy else 0.0;

    return .{
        .distance = distance,
        .indistinguishable = distance < epsilon or degenerate_fraction > 0.9,
        .degenerate_fraction = degenerate_fraction,
    };
}

// ============================================================================
// Game 6: Derangement Cycle (Hamiltonian traversal with running GF(3) sum)
// ============================================================================

/// Result of traversing the derangement cycle.
pub const CycleResult = struct {
    /// Length of the cycle traversed.
    cycle_length: u32,
    /// Running GF(3) sum at the end.
    final_trit_sum: Trit,
    /// Whether GF(3) is conserved (sum = 0 mod 3).
    gf3_conserved: bool,
    /// Geometric: norm of the accumulated multivector sum.
    /// If conserved, the sum should be close to zero or a fixed point.
    accumulated_norm: f64,
    /// Geometric: the product of all sigma rotors along the cycle.
    /// For a Hamiltonian cycle with prime offset, this should be identity (mod double cover).
    cycle_rotor_scalar: f64,
};

/// Derangement cycle game: traverse the permutation cycle, tracking GF(3) sum.
///
/// In open_color_games.py: follow sigma until we return to start.
/// Geometric version: accumulate the multivector sum along the cycle
/// and compose the sigma rotors. The cycle rotor product reveals
/// whether the derangement is orientation-preserving.
pub fn derangementCycleGame(colors: []const CGA, sigma: []const u32) CycleResult {
    if (colors.len == 0 or sigma.len == 0) {
        return .{
            .cycle_length = 0,
            .final_trit_sum = .zero,
            .gf3_conserved = true,
            .accumulated_norm = 0,
            .cycle_rotor_scalar = 1.0,
        };
    }

    var accumulated = CGA.zero();
    var trit_sum: i16 = 0;
    var cycle_rotor = CGA.scalar(1.0);
    const r1 = sigmaRotor(1);

    var current: u32 = 0;
    var length: u32 = 0;
    const max_steps = @as(u32, @intCast(colors.len));

    while (length < max_steps) : (length += 1) {
        accumulated = accumulated.add(colors[current]);
        trit_sum += @as(i16, @intFromEnum(extractTrit(colors[current])));
        cycle_rotor = cycle_rotor.mul(r1);
        const next = sigma[current];
        if (next == 0 and length > 0) break; // returned to start
        current = next;
    }

    const mod_sum = @mod(trit_sum + 3 * @as(i16, @intCast(length + 1)), 3);
    const final_trit: Trit = switch (mod_sum) {
        0 => .zero,
        1 => .plus,
        2 => .minus,
        else => unreachable,
    };

    return .{
        .cycle_length = length + 1,
        .final_trit_sum = final_trit,
        .gf3_conserved = final_trit == .zero,
        .accumulated_norm = accumulated.norm(),
        .cycle_rotor_scalar = @abs(cycle_rotor.scalarPart()),
    };
}

// ============================================================================
// Composed Lens Product: all 6 games as a single verdict
// ============================================================================

/// Full oracle verdict for a color pair, composing all games.
pub const OracleVerdict = struct {
    conservation: ConservationResult,
    distinguishability: DistinguishResult,
    bisimulation: BisimulationResult,
    indistinguishability: IndistinguishabilityResult,
    /// true iff conservation equilibrium AND distinguishable AND NOT indistinguishable
    all_pass: bool,
};

/// Run the full geometric oracle on a color pair.
/// This is the lens product: all games run in parallel on the same inputs,
/// and the composite verdict is the conjunction.
pub fn oracle(
    color_a: CGA,
    color_b: CGA,
    sigma_order: i8,
    distinguish_threshold: f64,
    indistinguish_epsilon: f64,
) OracleVerdict {
    const cons = conservationGame(color_a, color_b, sigma_order);
    const dist = distinguishGame(color_a, color_b, distinguish_threshold);
    const bisim = bisimulationGame(color_a, color_b);
    const indist = indistinguishabilityGame(color_a, color_b, indistinguish_epsilon);

    return .{
        .conservation = cons,
        .distinguishability = dist,
        .bisimulation = bisim,
        .indistinguishability = indist,
        .all_pass = cons.equilibrium and dist.distinguishable and !indist.indistinguishable,
    };
}

// ============================================================================
// Tests
// ============================================================================

test "embedColor roundtrips through extractTrit" {
    // Pure red -> minus
    try testing.expectEqual(Trit.minus, extractTrit(embedColor(255, 0, 0)));
    // Pure green -> plus
    try testing.expectEqual(Trit.plus, extractTrit(embedColor(0, 255, 0)));
    // Balanced -> zero (blue is degenerate, so low R and G -> zero)
    try testing.expectEqual(Trit.zero, extractTrit(embedColor(128, 128, 255)));
}

test "embedTrit produces correct basis vectors" {
    const minus_mv = embedTrit(.minus);
    try testing.expectApproxEqAbs(minus_mv.coeffs[1], -1.0, 1e-12); // -e0

    const plus_mv = embedTrit(.plus);
    try testing.expectApproxEqAbs(plus_mv.coeffs[2], 1.0, 1e-12); // +e1

    const zero_mv = embedTrit(.zero);
    try testing.expectApproxEqAbs(zero_mv.coeffs[4], 1.0, 1e-12); // +e2
}

test "sigmaRotor: identity at order 0" {
    const r0 = sigmaRotor(0);
    try testing.expectApproxEqAbs(r0.scalarPart(), 1.0, 1e-12);
}

test "sigmaRotor: 120-degree rotation at order 1" {
    const r1 = sigmaRotor(1);
    // cos(pi/3) = 0.5
    try testing.expectApproxEqAbs(r1.scalarPart(), @cos(math.pi / 3.0), 1e-10);
    // sin(pi/3) * e01 component
    try testing.expectApproxEqAbs(r1.coeffs[0b11], @sin(math.pi / 3.0), 1e-10);
}

test "sigmaRotor: triple application is identity" {
    @setEvalBranchQuota(100000);
    const r1 = sigmaRotor(1);
    // R^3 should be identity (or -1, rotor double cover)
    const r3 = r1.mul(r1).mul(r1);
    // For 120-degree rotation, R^3 = -1 (double cover: 3*120 = 360 in rotor = -1)
    try testing.expectApproxEqAbs(@abs(r3.scalarPart()), 1.0, 1e-10);
}

test "conservation game: sandwich preserves norm" {
    @setEvalBranchQuota(100000);
    const red = embedColor(255, 50, 50);
    const green = embedColor(50, 255, 50);

    const result = conservationGame(red, green, 1);
    try testing.expect(result.norm_preserved);
}

test "conservation game: complementary trits in equilibrium" {
    @setEvalBranchQuota(100000);
    // minus + plus = 0 mod 3 -> equilibrium
    const red = embedTrit(.minus);
    const green = embedTrit(.plus);
    const result = conservationGame(red, green, 1);
    try testing.expect(result.equilibrium);
}

test "conservation game: same trits NOT in equilibrium" {
    @setEvalBranchQuota(100000);
    const a = embedTrit(.plus);
    const b = embedTrit(.plus);
    const result = conservationGame(a, b, 1);
    // plus + plus = 2, not 0 mod 3
    try testing.expect(!result.equilibrium);
}

test "distinguishability: orthogonal colors are distinguishable" {
    @setEvalBranchQuota(100000);
    const red = embedTrit(.minus); // -e0
    const green = embedTrit(.plus); // +e1
    const result = distinguishGame(red, green, 0.1);
    try testing.expect(result.distinguishable);
    // Orthogonal: cosine ~ 0
    try testing.expectApproxEqAbs(result.cosine_similarity, 0.0, 1e-10);
    // Wedge should be nonzero
    try testing.expect(result.wedge_norm > 0.5);
}

test "distinguishability: identical colors are NOT distinguishable" {
    @setEvalBranchQuota(100000);
    const a = embedTrit(.plus);
    const b = embedTrit(.plus);
    const result = distinguishGame(a, b, 0.1);
    try testing.expect(!result.distinguishable);
    // Wedge of parallel vectors is zero
    try testing.expectApproxEqAbs(result.wedge_norm, 0.0, 1e-10);
    try testing.expectApproxEqAbs(result.distance, 0.0, 1e-10);
}

test "entropy witness: spread across grades = high entropy" {
    @setEvalBranchQuota(100000);
    // Mix of scalar, vector, bivector, trivector elements
    const e0 = CGA.basis(0);
    const e1 = CGA.basis(1);
    const e2 = CGA.basis(2);
    const e01 = e0.wedge(e1);

    const elements = [_]CGA{
        CGA.scalar(1.0), // grade 0
        e0, // grade 1
        e01, // grade 2
        e0.wedge(e1).wedge(e2), // grade 3 (pseudoscalar)
        e1.add(CGA.scalar(0.5)), // mixed
    };
    const result = entropyWitness(&elements, 0.5);
    try testing.expect(result.active_grades >= 3);
    try testing.expect(result.sufficient_entropy);
}

test "entropy witness: pure scalars = low entropy" {
    @setEvalBranchQuota(100000);
    const elements = [_]CGA{
        CGA.scalar(1.0),
        CGA.scalar(2.0),
        CGA.scalar(3.0),
        CGA.scalar(4.0),
    };
    const result = entropyWitness(&elements, 0.5);
    try testing.expectEqual(@as(u32, 1), result.active_grades);
    try testing.expect(!result.sufficient_entropy);
    try testing.expectApproxEqAbs(result.grade_entropy, 0.0, 1e-12);
}

test "bisimulation: same trit is bisimilar" {
    @setEvalBranchQuota(100000);
    const a = embedColor(200, 50, 30); // red-dominant -> minus
    const b = embedColor(180, 40, 20); // also red-dominant -> minus
    const result = bisimulationGame(a, b);
    try testing.expect(result.bisimilar);
    try testing.expectEqual(result.trit_a, result.trit_b);
    try testing.expectApproxEqAbs(result.trit_alignment, 1.0, 1e-10);
}

test "bisimulation: different trits are not bisimilar" {
    @setEvalBranchQuota(100000);
    const red = embedTrit(.minus);
    const green = embedTrit(.plus);
    const result = bisimulationGame(red, green);
    try testing.expect(!result.bisimilar);
    // Orthogonal trit embeddings -> alignment = 0
    try testing.expectApproxEqAbs(result.trit_alignment, 0.0, 1e-10);
}

test "indistinguishability: identical colors are indistinguishable" {
    @setEvalBranchQuota(100000);
    const a = embedColor(100, 200, 50);
    const b = embedColor(100, 200, 50);
    const result = indistinguishabilityGame(a, b, 0.05);
    try testing.expect(result.indistinguishable);
    try testing.expectApproxEqAbs(result.distance, 0.0, 1e-12);
}

test "indistinguishability: luminosity-only difference is degenerate" {
    @setEvalBranchQuota(100000);
    // Same R and G, different B (degenerate axis)
    const a = embedColor(128, 128, 50);
    const b = embedColor(128, 128, 200);
    const result = indistinguishabilityGame(a, b, 0.05);
    // Difference is purely in e2 (degenerate) -> degenerate_fraction = 1.0
    try testing.expectApproxEqAbs(result.degenerate_fraction, 1.0, 1e-10);
    try testing.expect(result.indistinguishable);
}

test "indistinguishability: hue difference is distinguishable" {
    @setEvalBranchQuota(100000);
    const a = embedColor(255, 0, 0); // pure red
    const b = embedColor(0, 255, 0); // pure green
    const result = indistinguishabilityGame(a, b, 0.05);
    try testing.expect(!result.indistinguishable);
    try testing.expect(result.distance > 0.5);
}

test "derangement cycle: 3-element cycle with prime offset" {
    @setEvalBranchQuota(100000);
    // 3 colors, sigma offset 2 (prime, coprime to 3 -> single cycle)
    const colors = [_]CGA{
        embedTrit(.minus), // index 0
        embedTrit(.zero), // index 1
        embedTrit(.plus), // index 2
    };
    // sigma(i) = (i + 2) mod 3: 0->2, 1->0, 2->1
    const sigma = [_]u32{ 2, 0, 1 };
    const result = derangementCycleGame(&colors, &sigma);
    try testing.expectEqual(@as(u32, 3), result.cycle_length);
    // minus + zero + plus = 0 mod 3
    try testing.expect(result.gf3_conserved);
}

test "derangement cycle: non-conserved sum" {
    @setEvalBranchQuota(100000);
    const colors = [_]CGA{
        embedTrit(.plus),
        embedTrit(.plus),
        embedTrit(.plus),
    };
    const sigma = [_]u32{ 2, 0, 1 };
    const result = derangementCycleGame(&colors, &sigma);
    try testing.expectEqual(@as(u32, 3), result.cycle_length);
    // plus + plus + plus = 3 = 0 mod 3, actually conserved!
    try testing.expect(result.gf3_conserved);
}

test "oracle: full pass for complementary colors" {
    @setEvalBranchQuota(100000);
    const red = embedTrit(.minus);
    const green = embedTrit(.plus);
    const verdict = oracle(red, green, 1, 0.1, 0.05);
    try testing.expect(verdict.conservation.equilibrium);
    try testing.expect(verdict.distinguishability.distinguishable);
    try testing.expect(!verdict.indistinguishability.indistinguishable);
    try testing.expect(verdict.all_pass);
}

test "oracle: fail for identical colors" {
    @setEvalBranchQuota(100000);
    const a = embedTrit(.plus);
    const b = embedTrit(.plus);
    const verdict = oracle(a, b, 1, 0.1, 0.05);
    try testing.expect(!verdict.distinguishability.distinguishable);
    try testing.expect(verdict.indistinguishability.indistinguishable);
    try testing.expect(!verdict.all_pass);
}

test "CNOT3 rotor matches entangle.zig sigma permutation" {
    @setEvalBranchQuota(100000);
    // sigma^1(R,G,B) = (G,B,R) in entangle.zig
    // In the algebra: rotating -e0 (red) by 120 degrees should move toward +e1 (green)
    const r1 = sigmaRotor(1);
    const red = embedTrit(.minus); // -e0

    const rotated = r1.sandwich(red);
    // After 120-degree rotation, the e0 component should decrease
    // and the e1 component should increase
    const e0_after = rotated.coeffs[1];
    const e1_after = rotated.coeffs[2];

    // The rotated red should have significant e1 component (moved toward green)
    try testing.expect(@abs(e1_after) > 0.5);
    // And reduced e0 component
    try testing.expect(@abs(e0_after) < @abs(red.coeffs[1]));
}

test "analytic continuation of sigma rotor: slerp between identity and sigma" {
    @setEvalBranchQuota(100000);
    const r1 = sigmaRotor(1);

    // At t=0: identity (no rotation)
    const at_0 = Ana.slerp(r1, 0.0).?;
    try testing.expectApproxEqAbs(at_0.scalarPart(), 1.0, 1e-10);

    // At t=1: full sigma rotation
    const at_1 = Ana.slerp(r1, 1.0).?;
    try testing.expect(at_1.approxEql(r1, 1e-10));

    // At t=0.5: half-sigma (60 degrees instead of 120)
    const at_half = Ana.slerp(r1, 0.5).?;
    // cos(pi/6) = cos(30) = 0.866...
    try testing.expectApproxEqAbs(at_half.scalarPart(), @cos(math.pi / 6.0), 1e-10);
}

// ============================================================================
// Concrete game playground: seed 69, 7 players, prime derangement offset 5
// ============================================================================

/// SplitMix64 for seed-derived colors (matches open_color_games.py)
fn splitmix64(state: u64) struct { next: u64, val: u64 } {
    const s = state +% 0x9E3779B97F4A7C15;
    var z = s;
    z = (z ^ (z >> 30)) *% 0xBF58476D1CE4E5B9;
    z = (z ^ (z >> 27)) *% 0x94D049BB133111EB;
    z = z ^ (z >> 31);
    return .{ .next = s, .val = z };
}

fn seedColor(seed: u64, index: u64) struct { r: u8, g: u8, b: u8 } {
    var state = seed;
    var val: u64 = 0;
    for (0..index + 1) |_| {
        const result = splitmix64(state);
        state = result.next;
        val = result.val;
    }
    return .{
        .r = @truncate((val >> 16) & 0xFF),
        .g = @truncate((val >> 8) & 0xFF),
        .b = @truncate(val & 0xFF),
    };
}

test "playground: seed 69, 7 players, all 6 games" {
    @setEvalBranchQuota(200000);
    const seed: u64 = 69;
    const N = 7;
    const offset = 5; // prime, coprime to 7

    // Generate colors from seed
    var colors: [N]CGA = undefined;
    var trits: [N]Trit = undefined;
    var sigma: [N]u32 = undefined;

    std.debug.print("\n=== GEOMETRIC COLOR GAME PLAYGROUND (seed=69, N=7, offset=5) ===\n", .{});

    for (0..N) |i| {
        const c = seedColor(seed, @intCast(i));
        colors[i] = embedColor(c.r, c.g, c.b);
        trits[i] = extractTrit(colors[i]);
        sigma[i] = @intCast((i + offset) % N);
        const trit_char: u8 = switch (trits[i]) {
            .minus => '-',
            .zero => '0',
            .plus => '+',
        };
        std.debug.print("  Player {d}: RGB({d:3},{d:3},{d:3}) trit={c} -> sigma({d})\n", .{ i, c.r, c.g, c.b, trit_char, sigma[i] });
    }

    // Game 1: Conservation (all pairs under derangement)
    std.debug.print("\n--- Conservation Game ---\n", .{});
    var equil_count: u32 = 0;
    for (0..N) |i| {
        const j = sigma[i];
        const result = conservationGame(colors[i], colors[j], 1);
        if (result.equilibrium) equil_count += 1;
        const eq_str = if (result.equilibrium) "EQUIL" else "  ---";
        std.debug.print("  {d}->{d}: {s} norm_ok={} angle={d:.2}\n", .{ i, j, eq_str, result.norm_preserved, result.rotor_angle });
    }
    std.debug.print("  Equilibrium: {d}/{d}\n", .{ equil_count, N });

    // Game 2: Distinguishability (all pairs)
    std.debug.print("\n--- Distinguishability Game ---\n", .{});
    var dist_count: u32 = 0;
    for (0..N) |i| {
        const j = sigma[i];
        const result = distinguishGame(colors[i], colors[j], 0.1);
        if (result.distinguishable) dist_count += 1;
    }
    std.debug.print("  Distinguishable: {d}/{d}\n", .{ dist_count, N });

    // Game 3: Entropy witness
    std.debug.print("\n--- Entropy Witness Game ---\n", .{});
    const ew = entropyWitness(&colors, 0.3);
    std.debug.print("  Active grades: {d}/{d}, entropy ratio: {d:.4}, sufficient: {}\n", .{ ew.active_grades, ew.total_grades, ew.entropy_ratio, ew.sufficient_entropy });

    // Game 4: Bisimulation
    std.debug.print("\n--- Bisimulation Game ---\n", .{});
    var bisim_count: u32 = 0;
    for (0..N) |i| {
        const j = sigma[i];
        const result = bisimulationGame(colors[i], colors[j]);
        if (result.bisimilar) bisim_count += 1;
    }
    std.debug.print("  Bisimilar: {d}/{d}\n", .{ bisim_count, N });

    // Game 5: Indistinguishability
    std.debug.print("\n--- Indistinguishability Game ---\n", .{});
    var indist_count: u32 = 0;
    for (0..N) |i| {
        for (i + 1..N) |j| {
            const result = indistinguishabilityGame(colors[i], colors[j], 0.15);
            if (result.indistinguishable) {
                indist_count += 1;
                std.debug.print("  INDIST pair ({d},{d}): dist={d:.4} degen={d:.4}\n", .{ i, j, result.distance, result.degenerate_fraction });
            }
        }
    }
    std.debug.print("  Indistinguishable pairs: {d}/{d}\n", .{ indist_count, N * (N - 1) / 2 });

    // Game 6: Derangement cycle
    std.debug.print("\n--- Derangement Cycle Game ---\n", .{});
    const cycle = derangementCycleGame(&colors, &sigma);
    std.debug.print("  Cycle length: {d}/{d}, GF(3) conserved: {}, accumulated norm: {d:.4}\n", .{ cycle.cycle_length, N, cycle.gf3_conserved, cycle.accumulated_norm });

    // Composite oracle on first pair
    std.debug.print("\n--- Composite Oracle (player 0 vs sigma(0)) ---\n", .{});
    const v = oracle(colors[0], colors[sigma[0]], 1, 0.1, 0.15);
    std.debug.print("  conservation.equil={}, distinguish={}, bisim={}, indist={}\n", .{ v.conservation.equilibrium, v.distinguishability.distinguishable, v.bisimulation.bisimilar, v.indistinguishability.indistinguishable });
    std.debug.print("  ALL_PASS: {}\n", .{v.all_pass});

    // GF(3) trit sum
    var trit_sum: i16 = 0;
    for (0..N) |i| trit_sum += @intFromEnum(trits[i]);
    std.debug.print("\n  GF(3) trit sum: {d} (mod 3 = {d})\n", .{ trit_sum, @mod(trit_sum + 30, 3) });

    // Rich embedding entropy
    std.debug.print("\n--- Entropy Witness (Rich Embedding) ---\n", .{});
    var rich_colors: [N]CGA = undefined;
    for (0..N) |i| {
        const c = seedColor(seed, @intCast(i));
        rich_colors[i] = embedColorRich(c.r, c.g, c.b);
    }
    const ew_rich = entropyWitness(&rich_colors, 0.3);
    std.debug.print("  Active grades: {d}/{d}, entropy ratio: {d:.4}, sufficient: {}\n", .{ ew_rich.active_grades, ew_rich.total_grades, ew_rich.entropy_ratio, ew_rich.sufficient_entropy });

    // Verify: at least some tests pass to ensure the playground ran correctly
    try testing.expect(dist_count > 0);
    try testing.expect(cycle.cycle_length == N); // prime offset -> Hamiltonian
    try testing.expect(ew_rich.active_grades > 1); // rich embedding spreads grades
}

test "tournament: seed 69, 69 players, prime offset 67" {
    @setEvalBranchQuota(500000);
    const seed: u64 = 69;
    const N = 69;
    const offset = 67; // prime, coprime to 69

    var colors: [N]CGA = undefined;
    var rich: [N]CGA = undefined;
    var trits: [N]Trit = undefined;
    var sigma: [N]u32 = undefined;
    var trit_counts = [_]u32{ 0, 0, 0 }; // minus, zero, plus

    for (0..N) |i| {
        const c = seedColor(seed, @intCast(i));
        colors[i] = embedColor(c.r, c.g, c.b);
        rich[i] = embedColorRich(c.r, c.g, c.b);
        trits[i] = extractTrit(colors[i]);
        sigma[i] = @intCast((i + offset) % N);
        switch (trits[i]) {
            .minus => trit_counts[0] += 1,
            .zero => trit_counts[1] += 1,
            .plus => trit_counts[2] += 1,
        }
    }

    std.debug.print("\n=== TOURNAMENT (seed=69, N=69, offset=67) ===\n", .{});
    std.debug.print("  Trit distribution: -={d} 0={d} +={d}\n", .{ trit_counts[0], trit_counts[1], trit_counts[2] });

    var trit_sum: i16 = 0;
    for (0..N) |i| trit_sum += @intFromEnum(trits[i]);
    std.debug.print("  GF(3) sum: {d} (mod 3 = {d})\n", .{ trit_sum, @mod(trit_sum + 300, 3) });

    // Conservation
    var equil: u32 = 0;
    for (0..N) |i| {
        const result = conservationGame(colors[i], colors[sigma[i]], 1);
        if (result.equilibrium) equil += 1;
    }
    std.debug.print("  Conservation equilibria: {d}/{d} ({d:.1}%)\n", .{ equil, N, @as(f64, @floatFromInt(equil)) * 100.0 / @as(f64, N) });

    // Distinguishability
    var dist_ok: u32 = 0;
    for (0..N) |i| {
        const result = distinguishGame(colors[i], colors[sigma[i]], 0.1);
        if (result.distinguishable) dist_ok += 1;
    }
    std.debug.print("  Distinguishable pairs: {d}/{d}\n", .{ dist_ok, N });

    // Bisimulation
    var bisim: u32 = 0;
    for (0..N) |i| {
        const result = bisimulationGame(colors[i], colors[sigma[i]]);
        if (result.bisimilar) bisim += 1;
    }
    std.debug.print("  Bisimilar pairs: {d}/{d}\n", .{ bisim, N });

    // Entropy: plain vs rich
    const ew_plain = entropyWitness(&colors, 0.3);
    const ew_rich = entropyWitness(&rich, 0.3);
    std.debug.print("  Entropy (plain): grades={d}/{d} ratio={d:.4}\n", .{ ew_plain.active_grades, ew_plain.total_grades, ew_plain.entropy_ratio });
    std.debug.print("  Entropy (rich):  grades={d}/{d} ratio={d:.4}\n", .{ ew_rich.active_grades, ew_rich.total_grades, ew_rich.entropy_ratio });

    // Derangement cycle
    const cycle = derangementCycleGame(&colors, &sigma);
    std.debug.print("  Cycle: len={d} hamiltonian={} gf3_conserved={}\n", .{ cycle.cycle_length, cycle.cycle_length == N, cycle.gf3_conserved });

    // Indistinguishability scan (pairs under derangement only)
    var indist: u32 = 0;
    for (0..N) |i| {
        const result = indistinguishabilityGame(colors[i], colors[sigma[i]], 0.15);
        if (result.indistinguishable) indist += 1;
    }
    std.debug.print("  Indistinguishable (sigma pairs): {d}/{d}\n", .{ indist, N });

    // Full oracle pass rate
    var oracle_pass: u32 = 0;
    for (0..N) |i| {
        const v = oracle(colors[i], colors[sigma[i]], 1, 0.1, 0.15);
        if (v.all_pass) oracle_pass += 1;
    }
    std.debug.print("  Oracle ALL_PASS: {d}/{d} ({d:.1}%)\n", .{ oracle_pass, N, @as(f64, @floatFromInt(oracle_pass)) * 100.0 / @as(f64, N) });

    // Slerp sweep: interpolate the sigma rotor and track how rotated trits evolve.
    // At t=0 (identity), rotated trit = original trit.
    // At t=1 (full 120-deg), rotated trit should shift by one step.
    // The sweep reveals phase transitions where trit assignments flip.
    std.debug.print("\n--- Slerp Sweep (t=0.0 to t=1.0 in 11 steps) ---\n", .{});
    const r1 = sigmaRotor(1);
    for (0..11) |step| {
        const t: f64 = @as(f64, @floatFromInt(step)) / 10.0;
        const partial_rotor = Ana.slerp(r1, t) orelse CGA.scalar(1.0);

        var sweep_equil: u32 = 0;
        var sweep_norm_ok: u32 = 0;
        var trit_flips: u32 = 0;
        var sweep_dist_ok: u32 = 0;
        for (0..N) |i| {
            const j = sigma[i];
            const rotated_i = partial_rotor.sandwich(colors[i]);
            const norm_orig = colors[i].norm();
            const norm_rot = rotated_i.norm();
            if (@abs(norm_orig - norm_rot) < 1e-6 or norm_orig < 1e-12) sweep_norm_ok += 1;

            // Track trit of rotated color vs original
            const orig_trit = extractTrit(colors[i]);
            const rot_trit = extractTrit(rotated_i);
            if (orig_trit != rot_trit) trit_flips += 1;

            // Dynamic equilibrium: rotated trit of i + original trit of sigma(i)
            const tj = extractTrit(colors[j]);
            const s = @as(i16, @intFromEnum(rot_trit)) + @as(i16, @intFromEnum(tj));
            if (@mod(s + 6, 3) == 0) sweep_equil += 1;

            // Dynamic distinguishability: rotated i vs original sigma(i)
            const d = distinguishGame(rotated_i, colors[j], 0.1);
            if (d.distinguishable) sweep_dist_ok += 1;
        }
        std.debug.print("  t={d:.1}: equil={d}/{d} flips={d} dist={d}/{d} norm_ok={d}/{d}\n", .{ t, sweep_equil, N, trit_flips, sweep_dist_ok, N, sweep_norm_ok, N });
    }

    try testing.expect(cycle.cycle_length == N);
    try testing.expect(ew_rich.active_grades > 1);
    try testing.expect(oracle_pass > 0);
}

test "embedding comparison: all 5 strategies on seed 69" {
    @setEvalBranchQuota(800000);
    const seed: u64 = 69;
    const N = 69;

    const strategies = [_]EmbeddingKind{
        .rotor_product,
        .exponential,
        .wedge_augmented,
        .anticommutator,
        .bivector_rotor,
    };
    const names = [_][]const u8{
        "rotor_product  ",
        "exponential    ",
        "wedge_augmented",
        "anticommutator ",
        "bivector_rotor ",
    };

    std.debug.print("\n=== EMBEDDING STRATEGY COMPARISON (seed=69, N=69) ===\n", .{});
    std.debug.print("  {s:17}  grades  entropy  ratio   trit_stable  norm_range\n", .{""});

    var best_ratio: f64 = 0;
    var best_idx: usize = 0;

    for (strategies, 0..) |strat, si| {
        var embedded: [N]CGA = undefined;
        var trit_match: u32 = 0;
        var min_norm: f64 = math.inf(f64);
        var max_norm: f64 = 0;

        for (0..N) |i| {
            const c = seedColor(seed, @intCast(i));
            embedded[i] = embedColorRichWith(c.r, c.g, c.b, strat);

            // Check if rich embedding preserves the trit assignment
            const plain_trit = extractTrit(embedColor(c.r, c.g, c.b));
            const rich_trit = extractTrit(embedded[i]);
            if (plain_trit == rich_trit) trit_match += 1;

            const n = embedded[i].norm();
            if (n < min_norm) min_norm = n;
            if (n > max_norm) max_norm = n;
        }

        const ew = entropyWitness(&embedded, 0.3);

        if (ew.entropy_ratio > best_ratio) {
            best_ratio = ew.entropy_ratio;
            best_idx = si;
        }

        std.debug.print("  {s}   {d}/4    {d:.4}  {d:.4}  {d:2}/{d:2}         [{d:.3},{d:.3}]\n", .{
            names[si],
            ew.active_grades,
            ew.grade_entropy,
            ew.entropy_ratio,
            trit_match,
            N,
            min_norm,
            max_norm,
        });
    }

    std.debug.print("  Best: {s} (ratio={d:.4})\n", .{ names[best_idx], best_ratio });

    // Grade energy breakdown for each strategy
    std.debug.print("\n  Grade energy distribution:\n", .{});
    std.debug.print("  {s:17}  g0(scalar)  g1(vector)  g2(bivec)  g3(pseudo)\n", .{""});
    for (strategies, 0..) |strat, si| {
        var grade_energy = [_]f64{ 0, 0, 0, 0 };
        var total: f64 = 0;
        for (0..N) |i| {
            const c = seedColor(seed, @intCast(i));
            const mv = embedColorRichWith(c.r, c.g, c.b, strat);
            for (0..CGA.DIM) |bi| {
                const g = @popCount(@as(u32, @intCast(bi)));
                const e = mv.coeffs[bi] * mv.coeffs[bi];
                grade_energy[g] += e;
                total += e;
            }
        }
        if (total > 1e-14) {
            std.debug.print("  {s}  {d:8.4}    {d:8.4}    {d:7.4}    {d:7.4}\n", .{
                names[si],
                grade_energy[0] / total,
                grade_energy[1] / total,
                grade_energy[2] / total,
                grade_energy[3] / total,
            });
        }
    }

    // Distinguishability comparison: which embedding separates colors best?
    std.debug.print("\n  Pairwise distinguishability (sigma pairs, threshold=0.1):\n", .{});
    const offset = 67;
    for (strategies, 0..) |strat, si| {
        var dist_ok: u32 = 0;
        var total_dist: f64 = 0;
        for (0..N) |i| {
            const j = (i + offset) % N;
            const ci = seedColor(seed, @intCast(i));
            const cj = seedColor(seed, @intCast(j));
            const ai = embedColorRichWith(ci.r, ci.g, ci.b, strat);
            const aj = embedColorRichWith(cj.r, cj.g, cj.b, strat);
            const result = distinguishGame(ai, aj, 0.1);
            if (result.distinguishable) dist_ok += 1;
            total_dist += result.distance;
        }
        std.debug.print("  {s}  dist={d}/{d}  avg_dist={d:.4}\n", .{ names[si], dist_ok, N, total_dist / @as(f64, N) });
    }

    try testing.expect(best_ratio > 0.3);
}
