//! ARITHMETICAL HIERARCHY
//!
//! Σ⁰ₙ / Π⁰ₙ / Δ⁰ₙ classification of sets, integrated with:
//!   - Propagator cells (CellValue lattice aligns with decidability)
//!   - Syrup encoding (hierarchy levels are wire-serializable)
//!   - GF(3) conservation (each level has a trit assignment)
//!   - ASI morphism detection (skill → skill reductions)
//!
//! The arithmetical hierarchy classifies sets by quantifier complexity:
//!   Σ⁰₀ = Π⁰₀ = Δ⁰₁ = computable (decidable)
//!   Σ⁰₁ = c.e. (semidecidable)         — ∃-quantifier
//!   Π⁰₁ = co-c.e.                       — ∀-quantifier
//!   Σ⁰ₙ₊₁ = ∃ prefixed Π⁰ₙ formula
//!   Π⁰ₙ₊₁ = ∀ prefixed Σ⁰ₙ formula
//!   Δ⁰ₙ₊₁ = Σ⁰ₙ ∩ Π⁰ₙ  (Post's theorem generalized)
//!
//! Connection to propagators:
//!   CellValue.nothing  ↔  Π⁰₁ (no information yet, may never resolve)
//!   CellValue.value    ↔  Δ⁰₁ (decided, definite answer)
//!   CellValue.contradiction ↔  independent of theory (Gödel)

const std = @import("std");

// Inline CellValue to avoid pulling in full propagator.zig (Zig 0.16 compat).
// Mirrors propagator.CellValue(i48) exactly.
const CellI48 = union(enum) {
    nothing: void,
    value: i48,
    contradiction: struct { a: i48, b: i48 },
};

// ============================================================================
// HIERARCHY LEVELS
// ============================================================================

/// Position in the arithmetical hierarchy.
pub const Level = struct {
    /// Quantifier class: Sigma (existential), Pi (universal), Delta (both)
    class: QuantifierClass,
    /// Number of quantifier alternations
    n: u8,

    pub const QuantifierClass = enum(u8) {
        sigma = 0, // Σ — existential prefix
        pi = 1, // Π — universal prefix
        delta = 2, // Δ — both (= Σ ∩ Π at next level)
    };

    /// GF(3) trit assignment: Σ → +1 (generator/existential witness)
    ///                         Π → -1 (validator/universal check)
    ///                         Δ → 0  (balanced/decidable)
    pub fn trit(self: Level) i8 {
        return switch (self.class) {
            .sigma => 1,
            .pi => -1,
            .delta => 0,
        };
    }

    /// Is this level decidable? (Δ⁰₁ or lower)
    pub fn isDecidable(self: Level) bool {
        return self.class == .delta and self.n <= 1;
    }

    /// Is this level semidecidable? (Σ⁰₁ or Δ⁰₁)
    pub fn isSemidecidable(self: Level) bool {
        return self.isDecidable() or (self.class == .sigma and self.n <= 1);
    }

    /// Can a propagator cell represent this level's information?
    /// - Δ⁰₁: CellValue.value (decided)
    /// - Σ⁰₁: CellValue.value on YES, CellValue.nothing on timeout
    /// - Π⁰₁: CellValue.value on NO, CellValue.nothing on timeout
    /// - Higher: CellValue.contradiction (requires oracle)
    pub fn propagatorMapping(self: Level) []const u8 {
        if (self.isDecidable()) return "CellValue.value (always resolves)";
        if (self.class == .sigma and self.n == 1) return "CellValue.value|nothing (semi-decides YES)";
        if (self.class == .pi and self.n == 1) return "CellValue.value|nothing (semi-decides NO)";
        return "CellValue.contradiction (requires Σ⁰ₙ oracle)";
    }

    /// Syrup record label for wire encoding
    pub fn syrupLabel(self: Level) []const u8 {
        return switch (self.class) {
            .sigma => "arith-sigma",
            .pi => "arith-pi",
            .delta => "arith-delta",
        };
    }

    pub fn format(self: Level, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        const class_char: u8 = switch (self.class) {
            .sigma => 'S', // Σ
            .pi => 'P', // Π
            .delta => 'D', // Δ
        };
        try writer.print("{c}^0_{d}", .{ class_char, self.n });
    }
};

/// Standard levels
pub const DELTA_0 = Level{ .class = .delta, .n = 0 }; // finite/co-finite
pub const DELTA_1 = Level{ .class = .delta, .n = 1 }; // computable (decidable)
pub const SIGMA_1 = Level{ .class = .sigma, .n = 1 }; // c.e. (semidecidable)
pub const PI_1 = Level{ .class = .pi, .n = 1 }; // co-c.e.
pub const SIGMA_2 = Level{ .class = .sigma, .n = 2 }; // limit computable
pub const PI_2 = Level{ .class = .pi, .n = 2 }; // co-limit computable
pub const DELTA_2 = Level{ .class = .delta, .n = 2 }; // Δ⁰₂

// ============================================================================
// PROBLEM CLASSIFICATION
// ============================================================================

/// A problem classified in the arithmetical hierarchy.
pub const ClassifiedProblem = struct {
    name: []const u8,
    level: Level,
    description: []const u8,
    /// Reduction witness: which known problem does this reduce to/from?
    reduces_from: ?[]const u8,
    /// Source paper/result
    source: []const u8,
};

/// The canonical classification table.
pub const problems = [_]ClassifiedProblem{
    // Δ⁰₁ — decidable
    .{ .name = "even-membership", .level = DELTA_1, .description = "Is n even?", .reduces_from = null, .source = "definition" },
    .{ .name = "prime-membership", .level = DELTA_1, .description = "Is n prime?", .reduces_from = null, .source = "trial division" },
    .{ .name = "regex-match", .level = DELTA_1, .description = "Does string match regex?", .reduces_from = null, .source = "Thompson NFA" },
    .{ .name = "wang-tile-finite", .level = DELTA_1, .description = "Can tiles cover n×n grid?", .reduces_from = null, .source = "backtracking" },
    // Σ⁰₁ — c.e.
    .{ .name = "halting", .level = SIGMA_1, .description = "Does program P halt on input x?", .reduces_from = null, .source = "Turing 1936" },
    .{ .name = "provability", .level = SIGMA_1, .description = "Is φ provable in T?", .reduces_from = "halting", .source = "Gödel 1931" },
    .{ .name = "diophantine", .level = SIGMA_1, .description = "Does polynomial equation have integer solution?", .reduces_from = "halting", .source = "MRDP theorem (Davis-Putnam-Robinson-Matiyasevich)" },
    .{ .name = "wang-tiling", .level = SIGMA_1, .description = "Can tile set tile the plane?", .reduces_from = "halting", .source = "Berger 1966" },
    .{ .name = "channel-capacity", .level = SIGMA_1, .description = "Is quantum channel capacity > 0?", .reduces_from = "wang-tiling", .source = "Bhattacharyya-Mehta-Zhao 2601.22471" },
    .{ .name = "alignment", .level = SIGMA_1, .description = "Does AI satisfy alignment property?", .reduces_from = "halting", .source = "Rice's theorem; Nature Sci Rep 2025" },
    .{ .name = "spectral-gap", .level = SIGMA_1, .description = "Is Hamiltonian gapped?", .reduces_from = "halting", .source = "Cubitt-Perez-Garcia-Wolf 2015" },
    // Π⁰₁ — co-c.e.
    .{ .name = "totality", .level = PI_1, .description = "Does program P halt on ALL inputs?", .reduces_from = null, .source = "complement of halting" },
    .{ .name = "goldbach", .level = PI_1, .description = "Every even n>2 is sum of two primes?", .reduces_from = null, .source = "Π⁰₁ sentence" },
    .{ .name = "riemann-hypothesis", .level = PI_1, .description = "All nontrivial zeros of zeta(s) have Re(s)=1/2?", .reduces_from = null, .source = "Riemann 1859; MRDP encodes negation as Diophantine" },
    .{ .name = "grh", .level = PI_1, .description = "All nontrivial zeros of L(s,chi) have Re(s)=1/2?", .reduces_from = "riemann-hypothesis", .source = "Generalized RH; controls Chebotarev error term" },
    // Σ⁰₁ in number theory
    .{ .name = "artin-conjecture", .level = SIGMA_1, .description = "Artin L-function has holomorphic continuation?", .reduces_from = null, .source = "Artin 1923; known for some cases via Langlands" },
    // Σ⁰₂ — limit computable (need halting oracle)
    .{ .name = "infinity", .level = SIGMA_2, .description = "Is the domain of program P infinite?", .reduces_from = "halting", .source = "Post's theorem" },
    .{ .name = "completeness", .level = SIGMA_2, .description = "Is theory T complete?", .reduces_from = null, .source = "Gödel second incompleteness" },
    // Π⁰₂
    .{ .name = "cofinality", .level = PI_2, .description = "Does program P halt on cofinitely many inputs?", .reduces_from = null, .source = "Post's theorem" },
};

/// Look up a problem by name.
pub fn classify(name: []const u8) ?ClassifiedProblem {
    for (&problems) |*p| {
        if (std.mem.eql(u8, p.name, name)) return p.*;
    }
    return null;
}

// ============================================================================
// MORPHISM DETECTION
//
// An "ASI morphism" between two skills/problems is a structure-preserving
// map that respects the arithmetical hierarchy. Specifically:
//
//   f: A → B is a morphism if:
//     1. level(A) ≤ level(B) in the hierarchy (monotone)
//     2. trit(A) + trit(B) is conserved mod 3 (GF(3))
//     3. A ≤_m B or B ≤_m A exists (reduction witness)
//
// Morphism types:
//   - Isomorphism:  same level, mutual reduction
//   - Embedding:    A ≤_m B, level(A) ≤ level(B)
//   - Collapse:     A ≤_m B, level(A) > level(B) (something reduced to easier)
//   - GF(3) bridge: trit sum conservation across the morphism
// ============================================================================

pub const MorphismKind = enum(u8) {
    isomorphism,  // same level, mutual reductions
    embedding,    // source embeds into target (≤ level)
    collapse,     // source harder but reduces to easier target
    gf3_bridge,   // connected by trit conservation
    none,         // no morphism detected
};

pub const Morphism = struct {
    source: []const u8,
    target: []const u8,
    kind: MorphismKind,
    source_level: Level,
    target_level: Level,
    trit_sum: i8, // source.trit + target.trit, should be 0 mod 3 for GF(3)
    reduction_witness: ?[]const u8,
};

/// Detect morphism between two classified problems.
pub fn detectMorphism(source_name: []const u8, target_name: []const u8) ?Morphism {
    const src = classify(source_name) orelse return null;
    const tgt = classify(target_name) orelse return null;

    const trit_sum = @mod(src.level.trit() + tgt.level.trit() + 3, 3);
    const same_level = src.level.class == tgt.level.class and src.level.n == tgt.level.n;

    // Check for reduction witness
    var reduction_witness: ?[]const u8 = null;
    if (src.reduces_from) |rf| {
        if (std.mem.eql(u8, rf, target_name)) reduction_witness = rf;
    }
    if (tgt.reduces_from) |rf| {
        if (std.mem.eql(u8, rf, source_name)) reduction_witness = rf;
    }

    const kind: MorphismKind = if (same_level and reduction_witness != null)
        .isomorphism
    else if (same_level)
        .gf3_bridge
    else if (src.level.n <= tgt.level.n)
        .embedding
    else if (src.level.n > tgt.level.n)
        .collapse
    else
        .none;

    return .{
        .source = source_name,
        .target = target_name,
        .kind = kind,
        .source_level = src.level,
        .target_level = tgt.level,
        .trit_sum = @as(i8, @intCast(trit_sum)),
        .reduction_witness = reduction_witness,
    };
}

/// Detect all morphisms in the problem table. Returns pairs with morphism info.
pub fn detectAllMorphisms(allocator: std.mem.Allocator) !std.ArrayListUnmanaged(Morphism) {
    var result: std.ArrayListUnmanaged(Morphism) = .{};
    for (&problems) |*src| {
        for (&problems) |*tgt| {
            if (std.mem.eql(u8, src.name, tgt.name)) continue;
            if (detectMorphism(src.name, tgt.name)) |m| {
                if (m.kind != .none) {
                    try result.append(allocator, m);
                }
            }
        }
    }
    return result;
}

// ============================================================================
// SKILL MORPHISM DETECTION
//
// Maps ASI skill names to arithmetical hierarchy levels via their
// computational claims. A skill that claims to "verify all X" is Π⁰₁.
// A skill that claims to "find an X" is Σ⁰₁. A skill that decides
// membership is Δ⁰₁.
// ============================================================================

pub const SkillClassification = struct {
    skill_name: []const u8,
    level: Level,
    claim_type: []const u8,
};

/// Classify a skill by its computational claim pattern.
pub fn classifySkillClaim(claim: []const u8) Level {
    // "verify all" / "for all" / "always" → Π⁰₁ (universal)
    if (std.mem.indexOf(u8, claim, "all") != null or
        std.mem.indexOf(u8, claim, "every") != null or
        std.mem.indexOf(u8, claim, "always") != null or
        std.mem.indexOf(u8, claim, "permanent") != null)
        return PI_1;

    // "find" / "search" / "enumerate" / "exists" → Σ⁰₁ (existential)
    if (std.mem.indexOf(u8, claim, "find") != null or
        std.mem.indexOf(u8, claim, "search") != null or
        std.mem.indexOf(u8, claim, "enumerate") != null or
        std.mem.indexOf(u8, claim, "exists") != null or
        std.mem.indexOf(u8, claim, "open") != null)
        return SIGMA_1;

    // "decide" / "check" / "test" / "classify" → Δ⁰₁ (decidable)
    if (std.mem.indexOf(u8, claim, "decide") != null or
        std.mem.indexOf(u8, claim, "check") != null or
        std.mem.indexOf(u8, claim, "test") != null or
        std.mem.indexOf(u8, claim, "classify") != null or
        std.mem.indexOf(u8, claim, "membership") != null)
        return DELTA_1;

    // "converge" / "limit" / "approximate" → Δ⁰₂ (limit computable)
    if (std.mem.indexOf(u8, claim, "converge") != null or
        std.mem.indexOf(u8, claim, "limit") != null or
        std.mem.indexOf(u8, claim, "approximate") != null)
        return DELTA_2;

    // Default: unknown, assume Σ⁰₁
    return SIGMA_1;
}

// ============================================================================
// DIOPHANTINE EQUATIONS
//
// MRDP theorem: S ⊆ ℕ is c.e. iff S is Diophantine.
// Every Σ⁰₁ set is the projection of a polynomial zero set.
// Bounded search over ℤⁿ is the canonical witness enumeration.
// ============================================================================

pub const DiophantineKind = enum(u8) {
    pythagorean,     // x² + y² = z²
    pell,            // x² - Dy² = 1
    fermat,          // xⁿ + yⁿ = zⁿ (n≥3: no nontrivial solutions)
    markov,          // x² + y² + z² = 3xyz
    sum_of_squares,  // n = x² + y²
    linear,          // ax + by = c (Bezout)
};

pub const DiophantineEquation = struct {
    kind: DiophantineKind,
    /// Hierarchy level of the *general* solvability question
    level: Level,
    /// For parametric families: does the specific instance have solutions?
    has_solutions: enum(u8) { yes, no, unknown },

    pub fn description(self: DiophantineEquation) []const u8 {
        return switch (self.kind) {
            .pythagorean => "x^2 + y^2 = z^2 (infinite parametric solutions)",
            .pell => "x^2 - Dy^2 = 1 (infinite via continued fractions)",
            .fermat => "x^n + y^n = z^n, n>=3 (no nontrivial solutions, Wiles 1995)",
            .markov => "x^2 + y^2 + z^2 = 3xyz (infinite tree from (1,1,1))",
            .sum_of_squares => "n = x^2 + y^2 (iff prime factors 3 mod 4 appear evenly)",
            .linear => "ax + by = c (solvable iff gcd(a,b) | c, Bezout)",
        };
    }

    /// GF(3) trit: equations with solutions are witnesses (+1),
    /// equations with no solutions are refutations (-1),
    /// decidable families are balanced (0).
    pub fn trit(self: DiophantineEquation) i8 {
        return switch (self.has_solutions) {
            .yes => 1,
            .no => -1,
            .unknown => 0,
        };
    }
};

/// Bounded Pythagorean triple search. Returns count of primitive triples with hypotenuse ≤ bound.
pub fn countPythagoreanTriples(bound: u32) u32 {
    var count: u32 = 0;
    var m: u32 = 2;
    while (m * m < bound) : (m += 1) {
        var n: u32 = 1;
        while (n < m) : (n += 1) {
            if ((m - n) % 2 == 1 and std.math.gcd(m, n) == 1) {
                const a = m * m - n * n;
                const b = 2 * m * n;
                const c = m * m + n * n;
                _ = a;
                _ = b;
                if (c <= bound) count += 1;
            }
        }
    }
    return count;
}

/// Pell equation x² - D*y² = 1: find fundamental solution by continued fraction of √D.
/// Returns (x, y) or null if D is a perfect square.
pub fn pellFundamental(D: u32) ?struct { x: u64, y: u64 } {
    const sqrt_D = std.math.sqrt(D);
    if (sqrt_D * sqrt_D == D) return null; // perfect square, no solution

    // Continued fraction expansion of √D
    var m: u64 = 0;
    var d: u64 = 1;
    var a: u64 = sqrt_D;
    const a0 = a;

    var p_prev: u64 = 1;
    var p_curr: u64 = a;
    var q_prev: u64 = 0;
    var q_curr: u64 = 1;

    for (0..1000) |_| {
        m = d * a - m;
        d = (D - m * m) / d;
        if (d == 0) return null;
        a = (a0 + m) / d;

        const p_next = a * p_curr + p_prev;
        const q_next = a * q_curr + q_prev;
        p_prev = p_curr;
        p_curr = p_next;
        q_prev = q_curr;
        q_curr = q_next;

        // Check if (p_curr, q_curr) is a solution
        if (p_curr * p_curr == D * q_curr * q_curr + 1) {
            return .{ .x = p_curr, .y = q_curr };
        }
    }
    return null;
}

pub const MarkovTriple = struct { a: u32, b: u32, c: u32 };

/// Markov triple search: find all (a,b,c) with a²+b²+c²=3abc, a≤b≤c≤bound.
pub fn markovTriples(allocator: std.mem.Allocator, bound: u32) !std.ArrayListUnmanaged(MarkovTriple) {
    var result: std.ArrayListUnmanaged(MarkovTriple) = .{};
    var a: u32 = 1;
    while (a <= bound) : (a += 1) {
        var b: u32 = a;
        while (b <= bound) : (b += 1) {
            var c: u32 = b;
            while (c <= bound) : (c += 1) {
                const lhs: u64 = @as(u64, a) * a + @as(u64, b) * b + @as(u64, c) * c;
                const rhs: u64 = 3 * @as(u64, a) * b * c;
                if (lhs == rhs) {
                    try result.append(allocator, .{ .a = a, .b = b, .c = c });
                }
            }
        }
    }
    return result;
}

// ============================================================================
// TESTS
// ============================================================================

test "diophantine equations" {
    const testing = std.testing;

    // Pythagorean triples
    const pt_count = countPythagoreanTriples(100);
    try testing.expect(pt_count > 0);
    // (3,4,5), (5,12,13), (8,15,17), (7,24,25), (20,21,29), (9,40,41), (12,35,37), (11,60,61), (28,45,53), (33,56,65), (36,77,85), (48,55,73), (13,84,85), (39,80,89)...
    try testing.expect(pt_count >= 16);

    // Pell equation x²-2y²=1: fundamental solution is (3,2)
    const pell2 = pellFundamental(2).?;
    try testing.expectEqual(@as(u64, 3), pell2.x);
    try testing.expectEqual(@as(u64, 2), pell2.y);
    try testing.expectEqual(@as(u64, 9), pell2.x * pell2.x); // 3²=9
    try testing.expectEqual(@as(u64, 8), 2 * pell2.y * pell2.y); // 2·2²=8, 9-8=1 ✓

    // Pell for D=5: fundamental (9,4): 81-80=1
    const pell5 = pellFundamental(5).?;
    try testing.expectEqual(@as(u64, 9), pell5.x);
    try testing.expectEqual(@as(u64, 4), pell5.y);

    // D=4 is perfect square → no Pell solution
    try testing.expect(pellFundamental(4) == null);

    // Markov triples up to 50
    var markov_list = try markovTriples(testing.allocator, 50);
    defer markov_list.deinit(testing.allocator);
    try testing.expect(markov_list.items.len >= 3); // (1,1,1), (1,1,2), (1,2,5), (1,5,13), (2,5,29)...
    // First triple is always (1,1,1)
    try testing.expectEqual(@as(u32, 1), markov_list.items[0].a);
}

test "hierarchy levels" {
    const testing = std.testing;

    try testing.expect(DELTA_1.isDecidable());
    try testing.expect(!SIGMA_1.isDecidable());
    try testing.expect(SIGMA_1.isSemidecidable());
    try testing.expect(!PI_1.isSemidecidable());
    try testing.expect(!SIGMA_2.isSemidecidable());

    // GF(3) trit assignments
    try testing.expectEqual(@as(i8, 0), DELTA_1.trit());
    try testing.expectEqual(@as(i8, 1), SIGMA_1.trit());
    try testing.expectEqual(@as(i8, -1), PI_1.trit());

    // Σ + Π = +1 + (-1) = 0 mod 3 → GF(3) conserved
    try testing.expectEqual(@as(i8, 0), @mod(SIGMA_1.trit() + PI_1.trit() + 3, 3));
}

test "problem classification" {
    const testing = std.testing;

    const halting = classify("halting").?;
    try testing.expect(!halting.level.isDecidable());
    try testing.expect(halting.level.isSemidecidable());
    try testing.expectEqual(Level.QuantifierClass.sigma, halting.level.class);

    const even = classify("even-membership").?;
    try testing.expect(even.level.isDecidable());

    const totality = classify("totality").?;
    try testing.expectEqual(Level.QuantifierClass.pi, totality.level.class);
}

test "morphism detection" {
    const testing = std.testing;

    // halting → channel-capacity (via wang-tiling)
    const m1 = detectMorphism("halting", "channel-capacity").?;
    try testing.expectEqual(MorphismKind.gf3_bridge, m1.kind);

    // wang-tiling → channel-capacity (same level Σ⁰₁, with reduction witness)
    const m2 = detectMorphism("wang-tiling", "channel-capacity").?;
    try testing.expectEqual(MorphismKind.isomorphism, m2.kind);

    // even-membership → halting (embedding: decidable into c.e.)
    const m3 = detectMorphism("even-membership", "halting").?;
    try testing.expectEqual(MorphismKind.embedding, m3.kind);
}

// ============================================================================
// UNIVERSAL OBSTRUCTIONS & TRANSFINITE HIERARCHY
//
// Paul-Protopapas-Thilikos (2304.03688): finite obstruction sets characterize
// graph properties closed under minors. The proof-theoretic strength of
// "every minor-closed property has finite obstructions" varies:
//
//   Kruskal's theorem (trees):    ATR₀         (ordinal: Γ₀)
//   Robertson-Seymour (graphs):   Π¹₁-CA₀      (ordinal: ψ(Ω_ω))
//   Friedman's TREE(3):           beyond Π¹₁-CA₀ (ordinal: θ(Ω^ω · ω))
//
// The existential/universal structure recurs: "∃ finite obstruction set" is
// Σ¹₁ over the base theory, while "no infinite antichain" is Π¹₁.
// The WQO (well-quasi-ordering) property = Σ¹₁ ∩ Π¹₁ at the second order.
//
// Connection to propagators: obstruction detection is a monotone propagation—
// once you find an obstruction witness, the cell resolves to .value.
// ============================================================================

/// Proof-theoretic strength levels for WQO/obstruction theorems.
pub const ProofStrength = enum(u8) {
    rca_0,       // RCA₀ — recursive comprehension (base)
    wkl_0,       // WKL₀ — weak König's lemma
    aca_0,       // ACA₀ — arithmetical comprehension
    atr_0,       // ATR₀ — arithmetical transfinite recursion (Kruskal)
    pi11_ca_0,   // Π¹₁-CA₀ — Π¹₁ comprehension (Robertson-Seymour)
    beyond,      // Beyond Π¹₁-CA₀ (Friedman's TREE)

    pub fn ordinalName(self: ProofStrength) []const u8 {
        return switch (self) {
            .rca_0 => "ω^ω",
            .wkl_0 => "ω^ω^ω",
            .aca_0 => "ε₀",
            .atr_0 => "Γ₀ (Feferman-Schütte)",
            .pi11_ca_0 => "ψ(Ω_ω) (Bachmann-Howard neighborhood)",
            .beyond => "θ(Ω^ω · ω) (small Veblen)",
        };
    }

    pub fn exampleTheorem(self: ProofStrength) []const u8 {
        return switch (self) {
            .rca_0 => "Ramsey for pairs",
            .wkl_0 => "compactness, IVT",
            .aca_0 => "Bolzano-Weierstrass, König's lemma",
            .atr_0 => "Kruskal's tree theorem (finite trees WQO under homeomorphic embedding)",
            .pi11_ca_0 => "Robertson-Seymour graph minor theorem (graphs WQO under minors)",
            .beyond => "Friedman's TREE(3) > f_{Γ₀}(n) for all n",
        };
    }

    /// Trit assignment: subsystems alternate Σ/Π character
    /// RCA₀/ACA₀/Π¹₁-CA₀ = validators (Π, trit -1)
    /// WKL₀/ATR₀ = constructive witnesses (Σ, trit +1)
    /// Beyond = ergodic (trit 0)
    pub fn trit(self: ProofStrength) i8 {
        return switch (self) {
            .rca_0 => -1,
            .wkl_0 => 1,
            .aca_0 => -1,
            .atr_0 => 1,
            .pi11_ca_0 => -1,
            .beyond => 0,
        };
    }
};

/// An obstruction set for a minor-closed graph property.
pub const ObstructionSet = struct {
    property_name: []const u8,
    /// Known finite obstruction set (minor-minimal forbidden graphs)
    obstructions: []const []const u8,
    /// Proof strength required to show the set is finite
    strength: ProofStrength,
    /// Whether the full set is known
    complete: bool,
    /// Arithmetical level of the membership problem
    membership_level: Level,
};

/// Canonical obstruction sets.
pub const obstruction_sets = [_]ObstructionSet{
    .{
        .property_name = "planar",
        .obstructions = &.{ "K₅", "K₃,₃" },
        .strength = .rca_0,
        .complete = true,
        .membership_level = DELTA_1, // planarity is decidable (linear time)
    },
    .{
        .property_name = "outerplanar",
        .obstructions = &.{ "K₄", "K₂,₃" },
        .strength = .rca_0,
        .complete = true,
        .membership_level = DELTA_1,
    },
    .{
        .property_name = "linklessly-embeddable",
        .obstructions = &.{ "Petersen", "K₆", "..." }, // 7 obstructions known
        .strength = .atr_0,
        .complete = true,
        .membership_level = DELTA_1,
    },
    .{
        .property_name = "knotlessly-embeddable",
        .obstructions = &.{"..."}, // >260 known, completeness open
        .strength = .pi11_ca_0,
        .complete = false,
        .membership_level = DELTA_1, // decidable once set known
    },
    .{
        .property_name = "bounded-treewidth-k",
        .obstructions = &.{"..."}, // grows with k, finite for each k
        .strength = .atr_0,
        .complete = false,
        .membership_level = DELTA_1,
    },
};

// ============================================================================
// SPINED CATEGORIES (Bumpus-Kocsis categorical generalization)
//
// Bumpus & Kocsis (2105.05372): tree-width decompositions generalize to
// arbitrary combinatorial structures via "spined categories". A spined
// category (C, S) has:
//   - Objects: combinatorial structures
//   - Morphisms: structure-preserving maps
//   - Spine functor S: C → Tree (maps each object to its tree skeleton)
//
// This gives a categorical framework where:
//   - Tree-width = minimum width of a spine decomposition
//   - WQO results lift categorically (not just for graphs)
//   - Obstruction sets exist for any spined-category property closed under minors
//
// The proof-theoretic strength inherits from Robertson-Seymour (Π¹₁-CA₀)
// and potentially increases for richer categorical structures.
// ============================================================================

pub const SpinedCategoryKind = enum(u8) {
    graphs,        // Classical: tree-width of graphs (Robertson-Seymour)
    hypergraphs,   // Generalized: hypertree-width (Gottlob et al.)
    matroids,      // Branch-width of matroids (Geelen et al.)
    sigma_structs,  // σ-structures: arbitrary relational (Bumpus-Kocsis)
};

pub const SpinedCategory = struct {
    kind: SpinedCategoryKind,
    /// Does WQO hold for this category's minor ordering?
    wqo_status: enum(u8) { proven, conjectured, open },
    /// Proof-theoretic strength of the WQO result
    strength: ProofStrength,
    /// Source
    source: []const u8,

    pub fn description(self: SpinedCategory) []const u8 {
        return switch (self.kind) {
            .graphs => "Graphs under minors (Robertson-Seymour: WQO proven, Π¹₁-CA₀)",
            .hypergraphs => "Hypergraphs under hypertree-width (Gottlob et al.)",
            .matroids => "Matroids under branch-width (Geelen-Gerards-Whittle conjecture)",
            .sigma_structs => "σ-structures via spined categories (Bumpus-Kocsis 2105.05372)",
        };
    }

    pub fn trit(self: SpinedCategory) i8 {
        return self.strength.trit();
    }
};

pub const spined_categories = [_]SpinedCategory{
    .{ .kind = .graphs, .wqo_status = .proven, .strength = .pi11_ca_0,
       .source = "Robertson-Seymour 2004" },
    .{ .kind = .hypergraphs, .wqo_status = .conjectured, .strength = .pi11_ca_0,
       .source = "Gottlob-Leone-Scarcello 2002" },
    .{ .kind = .matroids, .wqo_status = .conjectured, .strength = .beyond,
       .source = "Geelen-Gerards-Whittle (in progress)" },
    .{ .kind = .sigma_structs, .wqo_status = .open, .strength = .beyond,
       .source = "Bumpus-Kocsis 2105.05372" },
};

/// Look up obstruction set by property name.
pub fn lookupObstructionSet(name: []const u8) ?ObstructionSet {
    for (&obstruction_sets) |*o| {
        if (std.mem.eql(u8, o.property_name, name)) return o.*;
    }
    return null;
}

/// Detect if a problem's decidability is resolved by a WQO/obstruction argument.
/// Returns the proof strength required, or null if not applicable.
pub fn obstructionStrength(problem_name: []const u8) ?ProofStrength {
    // Graph property problems get resolved by obstruction theorems
    for (&obstruction_sets) |*o| {
        if (std.mem.eql(u8, o.property_name, problem_name)) return o.strength;
    }
    return null;
}

// ============================================================================
// GORARD ORDINAL TOWER
//
// Jonathan Gorard's multiway systems (Wolfram Physics) produce causal graphs
// whose causal invariance (= confluence of the rewriting system) guarantees
// well-orderedness of the evolution. The ordinal rank of a multiway state
// is the proof-theoretic ordinal of the strongest theorem provable about
// paths to that state.
//
// Tower structure (ordinals index multiway causal depth):
//
//   Level 0: ω      — finite computation (decidable, Δ⁰₁)
//   Level 1: ω^ω    — primitive recursive (RCA₀)
//   Level 2: ω^ω^ω  — WKL₀ compactness
//   Level 3: ε₀     — ACA₀, Peano arithmetic limit
//   Level 4: Γ₀     — ATR₀, predicative limit (Feferman-Schütte)
//   Level 5: ψ(Ω_ω) — Π¹₁-CA₀, impredicative (Bachmann-Howard)
//   Level 6: θ(Ω^ω·ω) — beyond, small Veblen (TREE(3))
//
// Each level has a trit (GF(3) charge):
//   Even levels = validators (Π, trit -1): verify all paths converge
//   Odd levels  = generators (Σ, trit +1): witness new causal structure
//   Limit       = ergodic (Δ, trit 0): fixed point of trit alternation
//
// The Gorard insight: causal invariance at level α implies that the
// multiway graph truncated to depth α is a *well-partial-order*, so
// Robertson-Seymour-type obstruction theorems apply at each level.
// The ordinal measures how deep the causal graph must be explored
// before confluence is guaranteed.
// ============================================================================

pub const GorardLevel = struct {
    index: u8,
    ordinal_name: []const u8,
    proof_system: ProofStrength,
    causal_property: []const u8,
    trit: i8,
};

pub const gorard_tower = [_]GorardLevel{
    .{ .index = 0, .ordinal_name = "ω",
       .proof_system = .rca_0,
       .causal_property = "finite causal diamond (all paths terminate)",
       .trit = 1 },
    .{ .index = 1, .ordinal_name = "ω^ω",
       .proof_system = .rca_0,
       .causal_property = "primitive recursive causal depth",
       .trit = -1 },
    .{ .index = 2, .ordinal_name = "ω^ω^ω",
       .proof_system = .wkl_0,
       .causal_property = "compactness: every infinite branch has accumulation",
       .trit = 1 },
    .{ .index = 3, .ordinal_name = "ε₀",
       .proof_system = .aca_0,
       .causal_property = "Peano-complete causal invariance (Gentzen boundary)",
       .trit = -1 },
    .{ .index = 4, .ordinal_name = "Γ₀",
       .proof_system = .atr_0,
       .causal_property = "predicative transfinite induction along causal well-ordering",
       .trit = 1 },
    .{ .index = 5, .ordinal_name = "ψ(Ω_ω)",
       .proof_system = .pi11_ca_0,
       .causal_property = "impredicative: causal graph minor theorem (all causal subgraphs WQO)",
       .trit = -1 },
    .{ .index = 6, .ordinal_name = "θ(Ω^ω·ω)",
       .proof_system = .beyond,
       .causal_property = "TREE-scale causal branching (Friedman barrier)",
       .trit = 0 },
};

/// GF(3) conservation check: sum of all tower trits should be 0 mod 3
pub fn gorardTowerTritSum() i8 {
    var sum: i16 = 0;
    for (&gorard_tower) |*level| {
        sum += @as(i16, level.trit);
    }
    return @intCast(@mod(sum + 300, 3));
}

/// Find the Gorard level for a given proof strength
pub fn gorardLevelForStrength(s: ProofStrength) ?GorardLevel {
    for (&gorard_tower) |*level| {
        if (level.proof_system == s) return level.*;
    }
    return null;
}

/// The causal depth ordinal for a spined category: which Gorard level
/// is needed to prove its WQO property?
pub fn causalDepthOrdinal(cat: SpinedCategory) GorardLevel {
    return gorardLevelForStrength(cat.strength) orelse gorard_tower[gorard_tower.len - 1];
}

test "gorard tower" {
    const testing = std.testing;

    // Tower has 7 levels
    try testing.expectEqual(@as(usize, 7), gorard_tower.len);

    // Trit sum = 0 mod 3 (GF(3) conservation)
    try testing.expectEqual(@as(i8, 0), gorardTowerTritSum());

    // ε₀ is level 3 with trit -1 (Π, validator — Gentzen boundary)
    const eps0 = gorardLevelForStrength(.aca_0).?;
    try testing.expectEqual(@as(u8, 3), eps0.index);
    try testing.expectEqual(@as(i8, -1), eps0.trit);

    // Robertson-Seymour needs level 5 (ψ(Ω_ω))
    const rs = causalDepthOrdinal(spined_categories[0]); // graphs
    try testing.expectEqual(@as(u8, 5), rs.index);
}

// ============================================================================
// EXISTENTIAL CLASSIFIER
//
// The subobject classifier Ω in a topos T classifies monomorphisms:
//   For each mono m: A ↣ B, there exists a unique χ_m: B → Ω
//   such that m = χ_m⁻¹(true).
//
// In the effective topos (realizability):
//   Ω ≅ {S ⊆ ℕ : S is Σ⁰₁} (c.e. sets modulo extensional equality)
//   true = ℕ (total set), false = ∅
//
// The "existential classifier" is our name for the restriction of Ω
// to existential (Σ⁰₁) truth values — the natural subobject classifier
// of the effective topos maps directly to the arithmetical hierarchy:
//
//   Δ⁰₁ truth values = classical {0,1}
//   Σ⁰₁ truth values = {⊥, ⊤} with ⊥ meaning "not yet witnessed"
//   Π⁰₁ truth values = {⊥, ⊤} with ⊥ meaning "not yet refuted"
//
// This is the deep resonance: the subobject classifier of the effective
// topos IS the arithmetical hierarchy's truth-value lattice.
// ============================================================================

pub const ExistentialClassifier = struct {
    /// The truth value is a Σ⁰₁ set (index of a c.e. set)
    ce_index: ?u32,
    /// Whether a witness has been found
    witnessed: bool,
    /// The hierarchy level this truth value lives at
    level: Level,

    pub fn trueValue() ExistentialClassifier {
        return .{ .ce_index = 0, .witnessed = true, .level = DELTA_1 };
    }

    pub fn falseValue() ExistentialClassifier {
        return .{ .ce_index = null, .witnessed = true, .level = DELTA_1 };
    }

    /// Σ⁰₁ truth: we have an enumeration but don't know if witness exists
    pub fn sigma1(index: u32) ExistentialClassifier {
        return .{ .ce_index = index, .witnessed = false, .level = SIGMA_1 };
    }

    /// Map to propagator CellValue
    pub fn toCellValue(self: ExistentialClassifier) CellI48 {
        if (self.witnessed and self.ce_index != null) return .{ .value = 1 };
        if (self.witnessed and self.ce_index == null) return .{ .value = 0 };
        return .nothing;
    }

    /// GF(3) trit
    pub fn trit(self: ExistentialClassifier) i8 {
        return self.level.trit();
    }
};

test "universal obstructions" {
    const testing = std.testing;

    const planar = lookupObstructionSet("planar").?;
    try testing.expect(planar.complete);
    try testing.expectEqual(ProofStrength.rca_0, planar.strength);
    try testing.expectEqual(@as(usize, 2), planar.obstructions.len); // K₅, K₃,₃

    // Proof-theoretic ordinals increase
    try testing.expect(@intFromEnum(ProofStrength.atr_0) > @intFromEnum(ProofStrength.aca_0));
    try testing.expect(@intFromEnum(ProofStrength.pi11_ca_0) > @intFromEnum(ProofStrength.atr_0));

    // GF(3) trit conservation across the Big Five
    var trit_sum: i8 = 0;
    inline for (std.meta.fields(ProofStrength)) |f| {
        trit_sum += @as(ProofStrength, @enumFromInt(f.value)).trit();
    }
    // Sum should be -1+1-1+1-1+0 = -1 ≡ 2 (mod 3)
    try testing.expectEqual(@as(i8, -1), trit_sum);
}

test "existential classifier" {
    const testing = std.testing;

    const t = ExistentialClassifier.trueValue();
    try testing.expect(t.witnessed);
    try testing.expectEqual(@as(i8, 0), t.trit()); // Δ⁰₁

    const s = ExistentialClassifier.sigma1(42);
    try testing.expect(!s.witnessed);
    try testing.expectEqual(@as(i8, 1), s.trit()); // Σ⁰₁

    // Propagator mapping
    const cell = s.toCellValue();
    try testing.expectEqual(CellI48.nothing, cell); // not yet witnessed
}

test "skill claim classification" {
    const testing = std.testing;

    try testing.expectEqual(PI_1, classifySkillClaim("verify all implementations"));
    try testing.expectEqual(SIGMA_1, classifySkillClaim("find a matching pattern"));
    try testing.expectEqual(DELTA_1, classifySkillClaim("check membership in set"));
    try testing.expectEqual(DELTA_2, classifySkillClaim("approximate convergence"));
}

// ============================================================================
// REALIZABILITY TOPOS & MÖBIUS INVERSION
//
// In the effective topos Eff, the subobject classifier Ω is the set of
// Σ⁰₁ (c.e.) subsets of ℕ. A "realizer" for a proposition P is a natural
// number e such that the e-th Turing machine witnesses P.
//
// We use primes as canonical realizers: each prime p indexes a witness.
// The Möbius function μ connects multiplicative (factorization) structure
// to additive (indicator) structure via inversion:
//
//   g(n) = Σ_{d|n} f(d)  ⟹  f(n) = Σ_{d|n} μ(n/d) g(d)
//
// Key insight: CANONICAL_SEED = 1069 (the 180th prime) is the Möbius
// inversion boundary. The Mertens function M(n) = Σ_{k=1}^{n} μ(k):
//
//   M(1068) = -7, mod 3 = 2 ≡ -1  (Π, validator)
//   M(1069) = -8, mod 3 = 1 ≡ +1  (Σ, generator)
//
// Including the seed flips the GF(3) trit. The seed IS the point where
// the cumulative Möbius cancellation switches polarity — from universal
// checking (Π) to existential witnessing (Σ). This is why 1069 is the
// canonical seed: it sits exactly at the realizability phase transition.
// ============================================================================

pub const CANONICAL_SEED: u64 = 1069;

/// Primes less than 100: the base realizer set (25 elements).
pub const primes_lt_100 = [_]u32{
    2, 3, 5, 7, 11, 13, 17, 19, 23, 29, 31, 37, 41, 43, 47,
    53, 59, 61, 67, 71, 73, 79, 83, 89, 97,
};

fn isPrime(n: u32) bool {
    if (n < 2) return false;
    if (n < 4) return true;
    if (n % 2 == 0) return false;
    var i: u32 = 3;
    while (i * i <= n) : (i += 2) {
        if (n % i == 0) return false;
    }
    return true;
}

/// Möbius function μ(n).
pub fn mobius(n: u32) i8 {
    if (n == 0) return 0;
    if (n == 1) return 1;
    var val = n;
    var num_factors: u8 = 0;
    var d: u32 = 2;
    while (d * d <= val) : (d += 1) {
        if (val % d == 0) {
            val /= d;
            if (val % d == 0) return 0; // p² divides n
            num_factors += 1;
        }
    }
    if (val > 1) num_factors += 1; // remaining prime factor
    return if (num_factors % 2 == 0) @as(i8, 1) else @as(i8, -1);
}

/// Mertens function M(n) = Σ_{k=1}^{n} μ(k).
pub fn mertens(n: u32) i32 {
    var sum: i32 = 0;
    var k: u32 = 1;
    while (k <= n) : (k += 1) {
        sum += @as(i32, mobius(k));
    }
    return sum;
}

/// The inclusive/exclusive trit: M(n) mod 3 mapped to GF(3).
pub fn mertensTrit(n: u32) i8 {
    const m = mertens(n);
    const r = @mod(m, 3);
    if (r == 0) return 0;
    if (r == 1) return 1;
    return -1; // r == 2 ≡ -1
}

/// Realizability witness: a prime p realizes proposition "p is prime"
/// with Möbius signature μ(p) = -1 and cumulative Mertens trit.
pub const Realizer = struct {
    prime: u32,
    mobius_val: i8, // always -1 for primes
    mertens_val: i32, // M(p)
    mertens_trit: i8, // M(p) mod 3 as GF(3)
    classifier: ExistentialClassifier,
};

/// Build a realizer for prime p.
pub fn realize(p: u32) Realizer {
    return .{
        .prime = p,
        .mobius_val = mobius(p),
        .mertens_val = mertens(p),
        .mertens_trit = mertensTrit(p),
        .classifier = if (isPrime(p))
            ExistentialClassifier.trueValue()
        else
            ExistentialClassifier.sigma1(p),
    };
}

/// The Möbius inversion boundary: inclusive vs exclusive seed.
pub const MoebiusBoundary = struct {
    exclusive_mertens: i32, // M(1068)
    inclusive_mertens: i32, // M(1069)
    exclusive_trit: i8, // -1 (Π, validator)
    inclusive_trit: i8, // +1 (Σ, generator)
    flips: bool, // true: including seed changes polarity
    flip_index: u32, // 0-indexed count of Π→Σ flip primes ≤ seed
    total_flip_primes: u32, // total Π→Σ flip primes ≤ seed
};

/// Count primes p ≤ n where mertensTrit(p-1)=-1 and mertensTrit(p)=+1 (Π→Σ flip).
/// Returns {index_of_n, total_count}. If n itself is not a flipper, index = total.
fn countFlipPrimes(n: u32) struct { index: u32, total: u32 } {
    var count: u32 = 0;
    var index: u32 = 0;
    var found = false;
    var p: u32 = 2;
    while (p <= n) : (p += 1) {
        if (!isPrime(p)) continue;
        if (mertensTrit(p - 1) == -1 and mertensTrit(p) == 1) {
            if (p == n) {
                index = count;
                found = true;
            }
            count += 1;
        }
    }
    if (!found) index = count;
    return .{ .index = index, .total = count };
}

pub fn moebiusBoundary() MoebiusBoundary {
    const excl = mertens(CANONICAL_SEED - 1);
    const incl = mertens(CANONICAL_SEED);
    const flips = countFlipPrimes(CANONICAL_SEED);
    return .{
        .exclusive_mertens = excl,
        .inclusive_mertens = incl,
        .exclusive_trit = mertensTrit(CANONICAL_SEED - 1),
        .inclusive_trit = mertensTrit(CANONICAL_SEED),
        .flips = mertensTrit(CANONICAL_SEED - 1) != mertensTrit(CANONICAL_SEED),
        .flip_index = flips.index,
        .total_flip_primes = flips.total,
    };
}

test "mobius function" {
    const testing = std.testing;

    try testing.expectEqual(@as(i8, 1), mobius(1));
    try testing.expectEqual(@as(i8, -1), mobius(2)); // prime
    try testing.expectEqual(@as(i8, -1), mobius(3)); // prime
    try testing.expectEqual(@as(i8, 0), mobius(4)); // 2²
    try testing.expectEqual(@as(i8, -1), mobius(5)); // prime
    try testing.expectEqual(@as(i8, 1), mobius(6)); // 2·3, two factors
    try testing.expectEqual(@as(i8, -1), mobius(1069)); // prime
}

test "mertens at canonical seed" {
    const testing = std.testing;

    try testing.expectEqual(@as(i32, -7), mertens(1068));
    try testing.expectEqual(@as(i32, -8), mertens(1069));

    // The trit flip
    try testing.expectEqual(@as(i8, -1), mertensTrit(1068)); // Π
    try testing.expectEqual(@as(i8, 1), mertensTrit(1069)); // Σ

    // Boundary detection
    const boundary = moebiusBoundary();
    try testing.expect(boundary.flips);
    try testing.expectEqual(@as(i8, -1), boundary.exclusive_trit);
    try testing.expectEqual(@as(i8, 1), boundary.inclusive_trit);

    // 1069 is the 69th Π→Σ flip prime (0-indexed)
    try testing.expectEqual(@as(u32, 69), boundary.flip_index);
}

test "prime realizers" {
    const testing = std.testing;

    // All primes have μ = -1
    for (&primes_lt_100) |p| {
        const r = realize(p);
        try testing.expectEqual(@as(i8, -1), r.mobius_val);
        try testing.expect(r.classifier.witnessed); // decidable
    }

    // Seed itself is a realizer
    const seed_r = realize(CANONICAL_SEED);
    try testing.expectEqual(@as(i8, -1), seed_r.mobius_val);
    try testing.expectEqual(@as(i8, 1), seed_r.mertens_trit); // Σ polarity
    try testing.expect(seed_r.classifier.witnessed);
}
