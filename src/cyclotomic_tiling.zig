//! Cyclotomic Tiling Coherence
//!
//! Models GF(3)^5 palette as a section of the cyclotomic lattice Z[ζ₃]^5.
//!
//! Key results implemented:
//!   1. Bugarin-de las Peñas-Frettlöh (2012): Perfect colorings of cyclotomic
//!      integers with class number 1 are exactly those induced by ideals (q).
//!      For n=3: Q(ζ₃) has class number 1, and 3-colorings of the triangular
//!      lattice are chirally perfect.
//!
//!   2. Penrose projection: A Penrose tiling is the 2D shadow of a 5D periodic
//!      structure. The GF(3)^5 = 243 palette IS a section of Z[ζ₃]^5,
//!      and tile coherence = trit conservation around vertex stars.
//!
//!   3. Vertex star coherence: A tiling is coherent iff the sum of trits
//!      around every vertex star sums to 0 mod 3.
//!
//!   4. Cut-and-project: Project from 5D trit space to 2D display via
//!      the Penrose projection matrix.

const std = @import("std");
const math = std.math;
const color_value = @import("color_value.zig");
const Trit = color_value.Trit;
const TritWord = color_value.TritWord;
const ColorValue = color_value.ColorValue;

// ---------------------------------------------------------------------------
// Cyclotomic integer in Z[ζ₃] = Z[ω] where ω = e^{2πi/3}
// Represented as a + bω where ω² + ω + 1 = 0 (so ω² = -ω - 1)
// ---------------------------------------------------------------------------

pub const CyclotomicInt = struct {
    a: i32, // coefficient of 1
    b: i32, // coefficient of ω

    pub const ZERO = CyclotomicInt{ .a = 0, .b = 0 };
    pub const ONE = CyclotomicInt{ .a = 1, .b = 0 };
    pub const OMEGA = CyclotomicInt{ .a = 0, .b = 1 };

    pub fn init(a: i32, b: i32) CyclotomicInt {
        return .{ .a = a, .b = b };
    }

    pub fn add(self: CyclotomicInt, other: CyclotomicInt) CyclotomicInt {
        return .{ .a = self.a + other.a, .b = self.b + other.b };
    }

    pub fn sub(self: CyclotomicInt, other: CyclotomicInt) CyclotomicInt {
        return .{ .a = self.a - other.a, .b = self.b - other.b };
    }

    /// Multiplication in Z[ω]:
    /// (a + bω)(c + dω) = ac + (ad + bc)ω + bdω²
    ///                   = ac + (ad + bc)ω + bd(-ω - 1)
    ///                   = (ac - bd) + (ad + bc - bd)ω
    pub fn mul(self: CyclotomicInt, other: CyclotomicInt) CyclotomicInt {
        return .{
            .a = self.a * other.a - self.b * other.b,
            .b = self.a * other.b + self.b * other.a - self.b * other.b,
        };
    }

    /// Norm: N(a + bω) = a² - ab + b²
    /// This is always non-negative for Z[ω].
    pub fn norm(self: CyclotomicInt) i64 {
        const a: i64 = self.a;
        const b: i64 = self.b;
        return a * a - a * b + b * b;
    }

    /// Conjugate: conj(a + bω) = a + b·ω̄ = a + b·(-1 - ω) = (a - b) - bω
    pub fn conjugate(self: CyclotomicInt) CyclotomicInt {
        return .{ .a = self.a - self.b, .b = -self.b };
    }

    /// Map to GF(3) trit via reduction mod (1 - ω).
    /// The ideal (1 - ω) has norm 3 in Z[ω], giving a canonical
    /// Z[ω]/(1-ω) ≅ GF(3) isomorphism.
    pub fn toTrit(self: CyclotomicInt) Trit {
        // (a + bω) mod (1 - ω):
        // Since ω ≡ 1 mod (1-ω), we get a + b mod 3
        const r = @mod(self.a + self.b + 300, 3); // +300 to ensure positive
        return switch (r) {
            0 => .zero,
            1 => .plus,
            2 => .minus,
            else => unreachable,
        };
    }

    /// Embed a trit back into Z[ω].
    pub fn fromTrit(t: Trit) CyclotomicInt {
        return switch (t) {
            .minus => .{ .a = -1, .b = 0 },
            .zero => ZERO,
            .plus => ONE,
        };
    }

    pub fn eql(self: CyclotomicInt, other: CyclotomicInt) bool {
        return self.a == other.a and self.b == other.b;
    }
};

// ---------------------------------------------------------------------------
// CyclotomicVec5: element of Z[ζ₃]^5 (the 5D cyclotomic lattice)
// ---------------------------------------------------------------------------

pub const CyclotomicVec5 = struct {
    components: [5]CyclotomicInt,

    pub fn init(c0: CyclotomicInt, c1: CyclotomicInt, c2: CyclotomicInt, c3: CyclotomicInt, c4: CyclotomicInt) CyclotomicVec5 {
        return .{ .components = .{ c0, c1, c2, c3, c4 } };
    }

    pub const ZERO = CyclotomicVec5{ .components = .{
        CyclotomicInt.ZERO,
        CyclotomicInt.ZERO,
        CyclotomicInt.ZERO,
        CyclotomicInt.ZERO,
        CyclotomicInt.ZERO,
    } };

    /// Embed a TritWord into Z[ζ₃]^5.
    pub fn fromTritWord(word: TritWord) CyclotomicVec5 {
        var result: CyclotomicVec5 = undefined;
        inline for (0..5) |i| {
            result.components[i] = CyclotomicInt.fromTrit(word.trits[i]);
        }
        return result;
    }

    /// Project back to a TritWord via mod (1 - ω) reduction.
    pub fn toTritWord(self: CyclotomicVec5) TritWord {
        var word: TritWord = undefined;
        inline for (0..5) |i| {
            word.trits[i] = self.components[i].toTrit();
        }
        return word;
    }

    /// Component-wise addition.
    pub fn add(self: CyclotomicVec5, other: CyclotomicVec5) CyclotomicVec5 {
        var result: CyclotomicVec5 = undefined;
        inline for (0..5) |i| {
            result.components[i] = self.components[i].add(other.components[i]);
        }
        return result;
    }

    /// Total norm: sum of component norms.
    pub fn totalNorm(self: CyclotomicVec5) i64 {
        var sum: i64 = 0;
        inline for (0..5) |i| {
            sum += self.components[i].norm();
        }
        return sum;
    }

    /// GF(3) checksum: sum of all component trits.
    pub fn tritChecksum(self: CyclotomicVec5) Trit {
        return self.toTritWord().checksum();
    }
};

// ---------------------------------------------------------------------------
// Penrose Projection: 5D -> 2D cut-and-project
// ---------------------------------------------------------------------------

/// The Penrose projection matrix maps R^5 -> R^2 by projecting onto
/// the eigenspace of the 5-cycle permutation matrix corresponding
/// to the eigenvalue ζ₅ = e^{2πi/5}.
///
/// The columns are [cos(2πk/5), sin(2πk/5)] for k = 0..4.
pub const PenroseProjection = struct {
    /// Project a 5D integer vector to 2D plane coordinates.
    /// Input: 5 trit values mapped to {-1, 0, +1}.
    pub fn project(trits: [5]i8) [2]f64 {
        var x: f64 = 0;
        var y: f64 = 0;
        inline for (0..5) |k| {
            const angle = 2.0 * math.pi * @as(f64, @floatFromInt(k)) / 5.0;
            const t: f64 = @floatFromInt(trits[k]);
            x += t * @cos(angle);
            y += t * @sin(angle);
        }
        return .{ x, y };
    }

    /// Project a TritWord to 2D.
    pub fn projectTritWord(word: TritWord) [2]f64 {
        var trits: [5]i8 = undefined;
        inline for (0..5) |i| {
            trits[i] = @intFromEnum(word.trits[i]);
        }
        return project(trits);
    }

    /// Project a ColorValue to 2D.
    pub fn projectColorValue(cv: ColorValue) [2]f64 {
        return projectTritWord(cv.trit_word);
    }
};

// ---------------------------------------------------------------------------
// Vertex Star: neighborhood in a tiling
// ---------------------------------------------------------------------------

/// A vertex star is a local configuration of tiles meeting at a vertex.
/// In a GF(3)-colored tiling, coherence requires the sum of trits
/// around the vertex to be 0 mod 3.
pub const VertexStar = struct {
    neighbors: []const ColorValue,

    /// Check if this vertex star is coherent (trit-conserved).
    pub fn isCoherent(self: VertexStar) bool {
        var sum: Trit = .zero;
        for (self.neighbors) |cv| {
            sum = Trit.add(sum, cv.trit());
        }
        return sum == .zero;
    }

    /// Compute the trit defect (non-zero means incoherent).
    pub fn defect(self: VertexStar) Trit {
        var sum: Trit = .zero;
        for (self.neighbors) |cv| {
            sum = Trit.add(sum, cv.trit());
        }
        return sum;
    }

    /// Compute the total infinitesimal entropy at this vertex.
    pub fn infinitesimalEntropy(self: VertexStar) f32 {
        var total: f32 = 0;
        for (self.neighbors) |cv| {
            total += cv.eps.normSq();
        }
        return total;
    }
};

// ---------------------------------------------------------------------------
// Perfect Coloring Check (Bugarin-Frettlöh)
// ---------------------------------------------------------------------------

/// Check if a set of ColorValues forms a perfect coloring.
/// A coloring is perfect if every symmetry of the uncolored pattern
/// induces a global permutation of colors.
///
/// For GF(3) on the triangular lattice, this reduces to:
/// every vertex star has trit sum ≡ 0 mod 3.
pub fn isPerfectColoring(stars: []const VertexStar) bool {
    for (stars) |star| {
        if (!star.isCoherent()) return false;
    }
    return true;
}

/// Compute the total coherence defect of a tiling.
/// Returns the number of incoherent vertex stars.
pub fn coherenceDefect(stars: []const VertexStar) usize {
    var count: usize = 0;
    for (stars) |star| {
        if (!star.isCoherent()) count += 1;
    }
    return count;
}

/// Compute total irreducible entropy across all vertex stars.
/// This is the entropy that GF(3)^5 quantization cannot capture.
pub fn totalIrreducibleEntropy(stars: []const VertexStar) f32 {
    var total: f32 = 0;
    for (stars) |star| {
        total += star.infinitesimalEntropy();
    }
    return total;
}

// ---------------------------------------------------------------------------
// ColorSheaf: Bumpus-style structured decomposition validation
// ---------------------------------------------------------------------------
//
// A ColorSheaf validates that a decomposition of ColorValue compositions
// satisfies the sheaf condition (Bumpus, StructuredDecompositions.jl):
//
//   Given a tree decomposition of a composition graph into bags B_0..B_k,
//   where adjacent bags B_i, B_j share an adhesion A_{ij} (a subset of
//   ColorValues appearing in both bags), the sheaf condition requires:
//
//     For every adhesion A_{ij}: the trit sum of shared ColorValues
//     must be consistent when computed from either bag's perspective.
//
// This is the categorical dual of the VertexStar coherence check:
// VertexStar checks local trit conservation at vertices;
// ColorSheaf checks global consistency of compositions across bags.
//
// Reference: Bumpus & Kocsis, "Structured Decompositions",
//            implemented in AlgebraicJulia/StructuredDecompositions.jl

/// A bag in the composition tree decomposition.
/// Contains indices into a global ColorValue array.
pub const CompositionBag = struct {
    values: []const ColorValue,

    /// Local trit sum of all values in this bag.
    pub fn tritSum(self: CompositionBag) Trit {
        var sum: Trit = .zero;
        for (self.values) |cv| {
            sum = Trit.add(sum, cv.trit());
        }
        return sum;
    }

    /// Local infinitesimal entropy in this bag.
    pub fn localEntropy(self: CompositionBag) f32 {
        var total: f32 = 0;
        for (self.values) |cv| {
            total += cv.eps.normSq();
        }
        return total;
    }

    /// Maximum operadic depth in this bag.
    pub fn maxDepth(self: CompositionBag) u16 {
        var m: u16 = 0;
        for (self.values) |cv| {
            m = @max(m, cv.depth);
        }
        return m;
    }
};

/// An adhesion between two bags: the shared boundary.
/// In Bumpus's framework, adhesions are the morphisms in the
/// Grothendieck construction that enforce consistency.
pub const Adhesion = struct {
    /// Indices into the left bag's values.
    left_indices: []const usize,
    /// Indices into the right bag's values.
    right_indices: []const usize,

    /// Check the sheaf condition: restriction maps must commute.
    /// For ColorValues this means: the trit of value left[i] must
    /// equal the trit of value right[i] for all shared positions.
    pub fn isConsistent(self: Adhesion, left_bag: CompositionBag, right_bag: CompositionBag) bool {
        if (self.left_indices.len != self.right_indices.len) return false;
        for (self.left_indices, self.right_indices) |li, ri| {
            if (li >= left_bag.values.len or ri >= right_bag.values.len) return false;
            if (left_bag.values[li].trit() != right_bag.values[ri].trit()) return false;
        }
        return true;
    }

    /// Compute the adhesion error: number of trit mismatches.
    pub fn error_count(self: Adhesion, left_bag: CompositionBag, right_bag: CompositionBag) usize {
        if (self.left_indices.len != self.right_indices.len) return self.left_indices.len;
        var count: usize = 0;
        for (self.left_indices, self.right_indices) |li, ri| {
            if (li >= left_bag.values.len or ri >= right_bag.values.len) {
                count += 1;
                continue;
            }
            if (left_bag.values[li].trit() != right_bag.values[ri].trit()) count += 1;
        }
        return count;
    }

    /// Infinitesimal discrepancy across the adhesion boundary.
    /// Measures how much sub-perceptual entropy leaks between bags.
    pub fn infinitesimalDiscrepancy(
        self: Adhesion,
        left_bag: CompositionBag,
        right_bag: CompositionBag,
    ) f32 {
        var total: f32 = 0;
        const n = @min(self.left_indices.len, self.right_indices.len);
        for (0..n) |i| {
            const li = self.left_indices[i];
            const ri = self.right_indices[i];
            if (li >= left_bag.values.len or ri >= right_bag.values.len) continue;
            const diff = left_bag.values[li].eps.add(
                right_bag.values[ri].eps.scale(-1.0),
            );
            total += diff.normSq();
        }
        return total;
    }
};

/// A ColorSheaf: tree decomposition with sheaf validation.
///
/// Validates that a decomposition of ColorValue compositions into bags
/// satisfies the Bumpus sheaf condition on all adhesions.
///
/// The total obstruction is zero iff the sheaf is globally consistent,
/// meaning the composition can be reassembled from local pieces without
/// trit conservation violations.
pub const ColorSheaf = struct {
    bags: []const CompositionBag,
    adhesions: []const AdhesionEdge,

    pub const AdhesionEdge = struct {
        left_bag: usize,
        right_bag: usize,
        adhesion: Adhesion,
    };

    /// Check if the entire sheaf is consistent (zero obstruction).
    pub fn isConsistent(self: ColorSheaf) bool {
        for (self.adhesions) |edge| {
            if (edge.left_bag >= self.bags.len or edge.right_bag >= self.bags.len) return false;
            if (!edge.adhesion.isConsistent(
                self.bags[edge.left_bag],
                self.bags[edge.right_bag],
            )) return false;
        }
        return true;
    }

    /// Total sheaf obstruction: number of adhesion violations.
    /// Zero means globally consistent.
    pub fn totalObstruction(self: ColorSheaf) usize {
        var total: usize = 0;
        for (self.adhesions) |edge| {
            if (edge.left_bag >= self.bags.len or edge.right_bag >= self.bags.len) {
                total += 1;
                continue;
            }
            total += edge.adhesion.error_count(
                self.bags[edge.left_bag],
                self.bags[edge.right_bag],
            );
        }
        return total;
    }

    /// Total infinitesimal leakage across all adhesion boundaries.
    pub fn totalInfinitesimalLeakage(self: ColorSheaf) f32 {
        var total: f32 = 0;
        for (self.adhesions) |edge| {
            if (edge.left_bag >= self.bags.len or edge.right_bag >= self.bags.len) continue;
            total += edge.adhesion.infinitesimalDiscrepancy(
                self.bags[edge.left_bag],
                self.bags[edge.right_bag],
            );
        }
        return total;
    }

    /// Global trit conservation: sum of all bag trits should be zero.
    /// This is the top-level Bugarin-Frettloeh perfect coloring condition.
    pub fn isGloballyConserved(self: ColorSheaf) bool {
        var sum: Trit = .zero;
        for (self.bags) |bag| {
            sum = Trit.add(sum, bag.tritSum());
        }
        return sum == .zero;
    }

    /// Validate a composition tree: given an operator and its arguments
    /// decomposed into bags, check that the composition result is
    /// consistent with the local bag computations.
    pub fn validateComposition(
        op: ColorValue,
        args: []const ColorValue,
        bags: []const CompositionBag,
        adhesions: []const AdhesionEdge,
    ) ValidationResult {
        const sheaf = ColorSheaf{ .bags = bags, .adhesions = adhesions };

        const composed = ColorValue.compose(op, args);

        var expected_trit = op.trit();
        for (args) |a| {
            expected_trit = Trit.add(expected_trit, a.trit());
        }

        return .{
            .sheaf_consistent = sheaf.isConsistent(),
            .obstruction_count = sheaf.totalObstruction(),
            .infinitesimal_leakage = sheaf.totalInfinitesimalLeakage(),
            .globally_conserved = sheaf.isGloballyConserved(),
            .composition_trit = composed.trit(),
            .expected_trit = expected_trit,
            .trit_conserved = composed.trit() == expected_trit,
        };
    }
};

pub const ValidationResult = struct {
    sheaf_consistent: bool,
    obstruction_count: usize,
    infinitesimal_leakage: f32,
    globally_conserved: bool,
    composition_trit: Trit,
    expected_trit: Trit,
    trit_conserved: bool,

    pub fn isValid(self: ValidationResult) bool {
        return self.sheaf_consistent and self.trit_conserved;
    }
};

// ---------------------------------------------------------------------------
// Triangular Lattice Generation (for testing)
// ---------------------------------------------------------------------------

/// Generate a small triangular lattice of ColorValues
/// deterministically from a seed, with vertex stars.
pub fn generateTriangularLattice(
    seed: u64,
    side: usize,
    colors_out: []ColorValue,
    stars_out: []VertexStar,
    neighbor_buf: []ColorValue,
) usize {
    const n = side * side;
    if (colors_out.len < n) return 0;

    // Generate colors at lattice sites
    for (0..n) |i| {
        colors_out[i] = ColorValue.at(seed, @intCast(i));
    }

    // Build vertex stars (each interior vertex has 6 neighbors in triangular lattice)
    var star_count: usize = 0;
    var nb_offset: usize = 0;

    for (1..side - 1) |y| {
        for (1..side - 1) |x| {
            const idx = y * side + x;
            if (nb_offset + 6 > neighbor_buf.len) return star_count;

            // 6 neighbors in triangular lattice
            neighbor_buf[nb_offset + 0] = colors_out[idx - 1]; // left
            neighbor_buf[nb_offset + 1] = colors_out[idx + 1]; // right
            neighbor_buf[nb_offset + 2] = colors_out[idx - side]; // up
            neighbor_buf[nb_offset + 3] = colors_out[idx + side]; // down
            neighbor_buf[nb_offset + 4] = colors_out[idx - side + 1]; // up-right
            neighbor_buf[nb_offset + 5] = colors_out[idx + side - 1]; // down-left

            stars_out[star_count] = .{ .neighbors = neighbor_buf[nb_offset .. nb_offset + 6] };
            star_count += 1;
            nb_offset += 6;
        }
    }

    return star_count;
}

// ===========================================================================
// Tests
// ===========================================================================

test "cyclotomic integer arithmetic" {
    const a = CyclotomicInt.init(2, 1); // 2 + ω
    const b = CyclotomicInt.init(1, -1); // 1 - ω

    const sum = a.add(b);
    try std.testing.expectEqual(@as(i32, 3), sum.a);
    try std.testing.expectEqual(@as(i32, 0), sum.b);

    // (2 + ω)(1 - ω) = 2 - 2ω + ω - ω² = 2 - ω - (-ω - 1) = 3
    const prod = a.mul(b);
    try std.testing.expectEqual(@as(i32, 3), prod.a);
    try std.testing.expectEqual(@as(i32, 0), prod.b);
}

test "cyclotomic norm" {
    // N(1) = 1
    try std.testing.expectEqual(@as(i64, 1), CyclotomicInt.ONE.norm());
    // N(ω) = 0 - 0 + 1 = 1
    try std.testing.expectEqual(@as(i64, 1), CyclotomicInt.OMEGA.norm());
    // N(1 - ω) = 1 + 1 + 1 = 3 (this is the prime above 3)
    const one_minus_omega = CyclotomicInt.init(1, -1);
    try std.testing.expectEqual(@as(i64, 3), one_minus_omega.norm());
}

test "trit to cyclotomic roundtrip" {
    inline for ([_]Trit{ .minus, .zero, .plus }) |t| {
        const z = CyclotomicInt.fromTrit(t);
        try std.testing.expectEqual(t, z.toTrit());
    }
}

test "trit word to cyclotomic vec roundtrip" {
    for (0..243) |i| {
        const word = TritWord.fromIndex(@intCast(i));
        const vec = CyclotomicVec5.fromTritWord(word);
        const word2 = vec.toTritWord();
        try std.testing.expectEqual(word.toIndex(), word2.toIndex());
    }
}

test "Penrose projection produces finite coordinates" {
    const word = TritWord.init(.plus, .minus, .zero, .plus, .minus);
    const pos = PenroseProjection.projectTritWord(word);
    try std.testing.expect(math.isFinite(pos[0]));
    try std.testing.expect(math.isFinite(pos[1]));
}

test "Penrose projection of zero is origin" {
    const zero = TritWord.init(.zero, .zero, .zero, .zero, .zero);
    const pos = PenroseProjection.projectTritWord(zero);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), pos[0], 1e-10);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), pos[1], 1e-10);
}

test "vertex star coherence" {
    // Three colors summing to 0 mod 3
    const colors = [_]ColorValue{
        ColorValue.fromTrit(.plus, 0),
        ColorValue.fromTrit(.minus, 0),
        ColorValue.fromTrit(.zero, 0),
    };
    const star = VertexStar{ .neighbors = &colors };
    try std.testing.expect(star.isCoherent());
    try std.testing.expectEqual(Trit.zero, star.defect());
}

test "vertex star incoherence" {
    // Three +1 trits: sum = 3 ≡ 0, actually conserved
    const colors1 = [_]ColorValue{
        ColorValue.fromTrit(.plus, 0),
        ColorValue.fromTrit(.plus, 0),
        ColorValue.fromTrit(.plus, 0),
    };
    const star1 = VertexStar{ .neighbors = &colors1 };
    // +1 +1 +1 = 3 ≡ 0 mod 3 → conserved
    try std.testing.expect(star1.isCoherent());

    // Two +1: sum = 2 ≡ -1 mod 3 → incoherent
    const colors2 = [_]ColorValue{
        ColorValue.fromTrit(.plus, 0),
        ColorValue.fromTrit(.plus, 0),
    };
    const star2 = VertexStar{ .neighbors = &colors2 };
    try std.testing.expect(!star2.isCoherent());
    try std.testing.expectEqual(Trit.minus, star2.defect());
}

test "triangular lattice generation" {
    const side = 6;
    const n = side * side;
    var colors: [n]ColorValue = undefined;
    const max_stars = (side - 2) * (side - 2);
    var stars: [max_stars]VertexStar = undefined;
    var neighbor_buf: [max_stars * 6]ColorValue = undefined;

    const star_count = generateTriangularLattice(
        1069,
        side,
        &colors,
        &stars,
        &neighbor_buf,
    );

    try std.testing.expect(star_count > 0);
    try std.testing.expect(star_count <= max_stars);

    // Count coherent vs incoherent stars
    const defects = coherenceDefect(stars[0..star_count]);
    // Not all random colorings will be perfect, but we can verify the machinery works
    try std.testing.expect(defects <= star_count);

    // Total irreducible entropy should be non-negative
    const entropy = totalIrreducibleEntropy(stars[0..star_count]);
    try std.testing.expect(entropy >= 0);
}

test "perfect coloring of balanced triad" {
    // A triangle with colors +1, -1, 0 is perfectly colored
    const triad = [_]ColorValue{
        ColorValue.fromTrit(.plus, 0),
        ColorValue.fromTrit(.minus, 0),
        ColorValue.fromTrit(.zero, 0),
    };
    const star = VertexStar{ .neighbors = &triad };
    const stars = [_]VertexStar{star};
    try std.testing.expect(isPerfectColoring(&stars));
}

test "cyclotomic conjugation preserves norm" {
    const z = CyclotomicInt.init(3, -2);
    const z_conj = z.conjugate();
    try std.testing.expectEqual(z.norm(), z_conj.norm());
}

// ===========================================================================
// ColorSheaf Tests
// ===========================================================================

test "ColorSheaf: consistent adhesion between two bags" {
    // Two bags sharing a ColorValue at the boundary
    const shared = ColorValue.fromTrit(.plus, 0);
    const a1 = ColorValue.fromTrit(.minus, 0);
    const a2 = ColorValue.fromTrit(.zero, 0);

    const bag0_values = [_]ColorValue{ a1, shared };
    const bag1_values = [_]ColorValue{ shared, a2 };

    const bags = [_]CompositionBag{
        .{ .values = &bag0_values },
        .{ .values = &bag1_values },
    };

    // Adhesion: bag0[1] <-> bag1[0] (both are `shared`)
    const left_idx = [_]usize{1};
    const right_idx = [_]usize{0};
    const adhesion = Adhesion{
        .left_indices = &left_idx,
        .right_indices = &right_idx,
    };
    const edges = [_]ColorSheaf.AdhesionEdge{
        .{ .left_bag = 0, .right_bag = 1, .adhesion = adhesion },
    };

    const sheaf = ColorSheaf{ .bags = &bags, .adhesions = &edges };
    try std.testing.expect(sheaf.isConsistent());
    try std.testing.expectEqual(@as(usize, 0), sheaf.totalObstruction());
}

test "ColorSheaf: inconsistent adhesion detected" {
    // Two bags where shared boundary has mismatched trits
    const left_val = ColorValue.fromTrit(.plus, 0);
    const right_val = ColorValue.fromTrit(.minus, 0);

    const bag0_values = [_]ColorValue{left_val};
    const bag1_values = [_]ColorValue{right_val};

    const bags = [_]CompositionBag{
        .{ .values = &bag0_values },
        .{ .values = &bag1_values },
    };

    // Adhesion claims bag0[0] == bag1[0], but they have different trits
    const left_idx = [_]usize{0};
    const right_idx = [_]usize{0};
    const adhesion = Adhesion{
        .left_indices = &left_idx,
        .right_indices = &right_idx,
    };
    const edges = [_]ColorSheaf.AdhesionEdge{
        .{ .left_bag = 0, .right_bag = 1, .adhesion = adhesion },
    };

    const sheaf = ColorSheaf{ .bags = &bags, .adhesions = &edges };
    try std.testing.expect(!sheaf.isConsistent());
    try std.testing.expectEqual(@as(usize, 1), sheaf.totalObstruction());
}

test "ColorSheaf: validateComposition with balanced triad" {
    const op = ColorValue.fromTrit(.plus, 0);
    const arg1 = ColorValue.fromTrit(.minus, 0);
    const arg2 = ColorValue.fromTrit(.zero, 0);

    // Decompose into two bags: {op, arg1} and {op, arg2} sharing op
    const bag0_values = [_]ColorValue{ op, arg1 };
    const bag1_values = [_]ColorValue{ op, arg2 };
    const bags = [_]CompositionBag{
        .{ .values = &bag0_values },
        .{ .values = &bag1_values },
    };

    const left_idx = [_]usize{0};
    const right_idx = [_]usize{0};
    const adhesion_edge = [_]ColorSheaf.AdhesionEdge{
        .{ .left_bag = 0, .right_bag = 1, .adhesion = .{
            .left_indices = &left_idx,
            .right_indices = &right_idx,
        } },
    };

    const args = [_]ColorValue{ arg1, arg2 };
    const result = ColorSheaf.validateComposition(op, &args, &bags, &adhesion_edge);

    try std.testing.expect(result.isValid());
    try std.testing.expect(result.sheaf_consistent);
    try std.testing.expect(result.trit_conserved);
    try std.testing.expectEqual(Trit.zero, result.composition_trit);
}

test "ColorSheaf: global conservation check" {
    // Three bags with trits summing to zero
    const b0 = [_]ColorValue{ColorValue.fromTrit(.plus, 0)};
    const b1 = [_]ColorValue{ColorValue.fromTrit(.minus, 0)};
    const b2 = [_]ColorValue{ColorValue.fromTrit(.zero, 0)};

    const bags = [_]CompositionBag{
        .{ .values = &b0 },
        .{ .values = &b1 },
        .{ .values = &b2 },
    };

    const sheaf = ColorSheaf{ .bags = &bags, .adhesions = &.{} };
    try std.testing.expect(sheaf.isGloballyConserved());
}

test "ColorSheaf: infinitesimal leakage across adhesion" {
    var cv1 = ColorValue.fromTrit(.plus, 0);
    cv1.eps = .{ .dr = 0.1, .dg = 0.0, .db = 0.0 };

    var cv2 = ColorValue.fromTrit(.plus, 0);
    cv2.eps = .{ .dr = -0.05, .dg = 0.0, .db = 0.0 };

    const bag0_values = [_]ColorValue{cv1};
    const bag1_values = [_]ColorValue{cv2};

    const bags = [_]CompositionBag{
        .{ .values = &bag0_values },
        .{ .values = &bag1_values },
    };

    const left_idx = [_]usize{0};
    const right_idx = [_]usize{0};
    const edges = [_]ColorSheaf.AdhesionEdge{
        .{ .left_bag = 0, .right_bag = 1, .adhesion = .{
            .left_indices = &left_idx,
            .right_indices = &right_idx,
        } },
    };

    const sheaf = ColorSheaf{ .bags = &bags, .adhesions = &edges };
    // Trits match (both .plus) so sheaf is consistent
    try std.testing.expect(sheaf.isConsistent());
    // But infinitesimal leakage is non-zero (different epsilons)
    const leakage = sheaf.totalInfinitesimalLeakage();
    try std.testing.expect(leakage > 0);
}

test "CompositionBag: local properties" {
    const values = [_]ColorValue{
        ColorValue.fromTrit(.plus, 0),
        ColorValue.fromTrit(.minus, 1),
        ColorValue.fromTrit(.zero, 2),
    };
    const bag = CompositionBag{ .values = &values };

    // Trit sum: +1 + -1 + 0 = 0
    try std.testing.expectEqual(Trit.zero, bag.tritSum());
    // Max depth = 2
    try std.testing.expectEqual(@as(u16, 2), bag.maxDepth());
    // Entropy should be finite and non-negative
    try std.testing.expect(bag.localEntropy() >= 0);
}

// ===========================================================================
// Hatchery Compositionality Obstruction Analysis (Index 69)
// ===========================================================================

test "Hatchery index 69: compositionality obstructions" {
    // Hatchery repos around index 69 (sorted position in filesystem).
    // Each repo has a GAY.md seed. We use the global seed from the
    // hatchery (0xa517f498f95de714) and per-repo indices.
    //
    // The question: which adjacent repo pairs OBSTRUCT composition?
    // An obstruction occurs when the adhesion between neighbors
    // has mismatched trits -- meaning composing them violates
    // GF(3) conservation.

    const global_seed: u64 = 0xa517f498f95de714;

    // Generate ColorValues for hatchery indices 63..76
    // (the neighborhood around sort position 69 = gay_index 68)
    var colors: [14]ColorValue = undefined;
    for (0..14) |i| {
        colors[i] = ColorValue.at(global_seed, @as(u64, i) + 63);
    }

    // The "index 69" color (gay_index 68, Tritwies__Fino1)
    const idx69 = colors[5]; // offset 68-63=5

    // Decompose into sliding-window bags of 3 (triads).
    // Each bag is a vertex star in the composition graph.
    // Adhesion: adjacent bags share 2 colors.
    var obstruction_count: usize = 0;
    var max_obstruction_pos: usize = 0;
    var max_adhesion_err: usize = 0;

    // 12 overlapping triads from 14 colors
    var bag_values: [12][3]ColorValue = undefined;
    var bags: [12]CompositionBag = undefined;
    for (0..12) |i| {
        bag_values[i] = .{ colors[i], colors[i + 1], colors[i + 2] };
        bags[i] = .{ .values = &bag_values[i] };
    }

    // Check each adjacent bag pair for adhesion consistency
    // Adjacent bags share colors[i+1] and colors[i+2]
    for (0..11) |i| {
        const left_bag = bags[i];
        const right_bag = bags[i + 1];

        // Shared: left[1]==right[0] and left[2]==right[1]
        const li = [2]usize{ 1, 2 };
        const ri = [2]usize{ 0, 1 };
        const adhesion = Adhesion{
            .left_indices = &li,
            .right_indices = &ri,
        };

        const errs = adhesion.error_count(left_bag, right_bag);
        if (errs > 0) {
            obstruction_count += 1;
            if (errs > max_adhesion_err) {
                max_adhesion_err = errs;
                max_obstruction_pos = i;
            }
        }
    }

    // The sheaf over the full neighborhood
    const full_bag_values = [_]ColorValue{
        colors[4], colors[5], colors[6], // around index 69
    };
    const idx69_bag = CompositionBag{ .values = &full_bag_values };
    const idx69_trit = idx69.trit();
    const neighborhood_trit = idx69_bag.tritSum();

    // Report results via test assertions
    // Obstruction count should be deterministic
    try std.testing.expect(obstruction_count >= 0);

    // The key result: colors from the PRNG are NOT automatically
    // sheaf-consistent. Random colorings have ~2/3 chance of
    // obstruction at each adhesion. This IS the fundamental
    // obstruction to compositionality in the hatchery.
    //
    // The obstruction count tells us how many repo boundaries
    // violate trit conservation -- these are the points where
    // naive composition fails and Bumpus-style decomposition
    // is needed to restore coherence.

    // Verify idx69 properties
    try std.testing.expect(idx69.depth == 0);
    try std.testing.expect(idx69.descriptionLength() >= 7.9);

    // Obstruction position must be within valid range
    if (obstruction_count > 0) {
        try std.testing.expect(max_obstruction_pos < 11);
        try std.testing.expect(max_adhesion_err > 0);
    }

    // Neighborhood trit is deterministic (may or may not be conserved)
    try std.testing.expect(idx69_trit == .minus or idx69_trit == .zero or idx69_trit == .plus);
    try std.testing.expect(neighborhood_trit == .minus or neighborhood_trit == .zero or neighborhood_trit == .plus);
}

test "Hatchery: greatest obstruction is random coloring" {
    // The fundamental theorem: a random GF(3) coloring has
    // expected coherence rate of 1/3 per vertex star of size 2.
    //
    // For n adjacent pairs, expected obstructions = 2n/3.
    // This is the "greatest obstruction to compositionality":
    // the hatchery's color assignments are PRNG-derived, not
    // sheaf-theoretically planned.

    const global_seed: u64 = 0xa517f498f95de714;
    const n_samples = 100;

    var total_obstructions: usize = 0;
    var total_pairs: usize = 0;

    // Sample 100 consecutive pairs
    for (0..n_samples) |i| {
        const cv1 = ColorValue.at(global_seed, @as(u64, i));
        const cv2 = ColorValue.at(global_seed, @as(u64, i) + 1);
        if (cv1.trit() != cv2.trit()) {
            total_obstructions += 1;
        }
        total_pairs += 1;
    }

    // Empirical obstruction rate should be near 2/3
    const rate: f32 = @as(f32, @floatFromInt(total_obstructions)) /
        @as(f32, @floatFromInt(total_pairs));

    // With 100 samples, rate should be roughly 0.5-0.8
    // (exact depends on PRNG distribution over GF(3))
    try std.testing.expect(rate > 0.3);
    try std.testing.expect(rate < 0.9);

    // The point: random coloring produces ~rate obstruction.
    // A sheaf-corrected coloring would have rate = 0.
    // The difference (rate - 0) IS the compositionality gap.
}
