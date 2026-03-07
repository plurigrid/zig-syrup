//! Clifford Algebra: comptime-safe geometric algebra for Zig.
//!
//! Given signature Algebra(p, q, r):
//!   - p basis vectors square to +1
//!   - q basis vectors square to -1
//!   - r basis vectors square to  0 (degenerate/null)
//!
//! The algebra has dimension 2^N where N = p + q + r.
//! Basis blades are indexed by bitmasks: e.g. e₁₂ = 0b011.
//!
//! Key insight: the entire Cayley multiplication table is computed
//! at comptime, so geometric product is a single array multiply
//! at runtime with zero table lookups.
//!
//! HyperReal(T) IS Algebra(0,0,1) -- dual numbers as degenerate GA.

const std = @import("std");
const math = std.math;
const testing = std.testing;

/// Compute (-1)^count: sign from swap count.
fn paritySign(swaps: u32) bool {
    return (swaps & 1) == 1;
}

/// Count the number of 1-bits in a u32 (popcount).
fn popcount(x: u32) u32 {
    return @popCount(x);
}

/// Count swaps needed to move basis vectors of blade `a` past those of `b`
/// into canonical order. This determines the sign of the geometric product.
fn swapSign(a: u32, b: u32) bool {
    var n: u32 = 0;
    var x = a >> 1;
    while (x != 0) : (x >>= 1) {
        n += popcount(x & b);
    }
    return paritySign(n);
}

/// Metric signature: what each basis vector squares to.
/// Index i: +1 if i < p, -1 if p <= i < p+q, 0 if i >= p+q.
fn metricSign(comptime p: u32, comptime q: u32, index: u32) i2 {
    if (index < p) return 1;
    if (index < p + q) return -1;
    return 0;
}

/// Compute the metric factor when contracting shared basis vectors.
/// For blade bits that appear in both a and b, each shared basis vector
/// contributes its metric sign. Returns (result_blade, metric_factor).
fn contractMetric(comptime p: u32, comptime q: u32, comptime n: u32, a: u32, b: u32) struct { blade: u32, factor: i8 } {
    _ = n;
    const shared = a & b;
    const result_blade = a ^ b; // XOR: shared cancel, unique survive
    var factor: i8 = 1;

    var bit: u32 = 0;
    var mask = shared;
    while (mask != 0) {
        const lowest = @ctz(mask);
        bit = lowest;
        const m = metricSign(p, q, bit);
        if (m == 0) return .{ .blade = result_blade, .factor = 0 };
        factor *= m;
        mask &= mask - 1; // clear lowest bit
    }
    return .{ .blade = result_blade, .factor = factor };
}

/// Cayley table entry: product of basis blades i and j.
/// Returns (result_blade_index, sign as i8).
fn cayleyEntry(comptime p: u32, comptime q: u32, comptime n: u32, i: u32, j: u32) struct { blade: u32, sign: i8 } {
    const swap_neg = swapSign(i, j);
    const metric = contractMetric(p, q, n, i, j);
    var sign: i8 = metric.factor;
    if (swap_neg) sign = -sign;
    return .{ .blade = metric.blade, .sign = sign };
}

/// Clifford Algebra type parameterized by signature (p, q, r).
///
/// Algebra(3,0,0) = 3D Euclidean (VGA)
/// Algebra(3,0,1) = 3D Projective (PGA)
/// Algebra(4,1,0) = 3D Conformal (CGA)
/// Algebra(0,0,1) = Dual numbers (HyperReal)
/// Algebra(0,1,0) = Complex numbers
/// Algebra(0,2,0) = Quaternions
pub fn Algebra(comptime p: u32, comptime q: u32, comptime r: u32) type {
    const n = p + q + r;
    const dim: u32 = 1 << n; // 2^n

    // --- PRIMITIVE 1: Sparse Cayley table (ganja.js codegen insight) ---
    // Instead of dim x dim dense table, store only non-zero products per row.
    // For PGA(3,0,1): 200 non-zero out of 256 total entries.
    // For sparse multivectors this eliminates scanning zero columns entirely.
    const SparseEntry = struct { j: u16, blade: u16, sign: i8 };
    const max_per_row = dim; // upper bound
    const sparse_table: [dim][]const SparseEntry = comptime blk: {
        @setEvalBranchQuota(dim * dim * 80 + 2000);
        var table: [dim][]const SparseEntry = undefined;
        for (0..dim) |i| {
            var entries: [max_per_row]SparseEntry = undefined;
            var count: usize = 0;
            for (0..dim) |j| {
                const e = cayleyEntry(p, q, n, @intCast(i), @intCast(j));
                if (e.sign != 0) {
                    entries[count] = .{
                        .j = @intCast(j),
                        .blade = @intCast(e.blade),
                        .sign = e.sign,
                    };
                    count += 1;
                }
            }
            // Slice to actual count
            const final_entries: [count]SparseEntry = entries[0..count].*;
            table[i] = &final_entries;
        }
        break :blk table;
    };

    // Dense table kept for wedge/leftContract which need (i & j) checks.
    const cayley_blade: [dim][dim]u32 = comptime blk: {
        @setEvalBranchQuota(dim * dim * 50 + 1000);
        var table: [dim][dim]u32 = undefined;
        for (0..dim) |i| {
            for (0..dim) |j| {
                const e = cayleyEntry(p, q, n, @intCast(i), @intCast(j));
                table[i][j] = e.blade;
            }
        }
        break :blk table;
    };
    const cayley_sign: [dim][dim]i8 = comptime blk: {
        @setEvalBranchQuota(dim * dim * 50 + 1000);
        var table: [dim][dim]i8 = undefined;
        for (0..dim) |i| {
            for (0..dim) |j| {
                const e = cayleyEntry(p, q, n, @intCast(i), @intCast(j));
                table[i][j] = e.sign;
            }
        }
        break :blk table;
    };

    // --- PRIMITIVE 2: Comptime grade bitmasks ---
    // Pre-computed masks for which slots belong to each grade.
    // grade_masks[k] is a bitmask where bit i is set iff blade i has grade k.
    // Used for branchless grade extraction and reverse sign computation.
    const grade_masks: [n + 1]u64 = comptime blk: {
        @setEvalBranchQuota(dim * 10 + 1000);
        var masks: [n + 1]u64 = [_]u64{0} ** (n + 1);
        for (0..dim) |i| {
            const g = popcount(@as(u32, @intCast(i)));
            masks[g] |= @as(u64, 1) << @intCast(i);
        }
        break :blk masks;
    };

    // --- PRIMITIVE 3: Comptime reverse sign array ---
    // Pre-computed sign for reverse: (-1)^(k(k-1)/2) per slot.
    // Eliminates per-element grade computation at runtime.
    const reverse_sign: [dim]f64 = comptime blk: {
        @setEvalBranchQuota(dim * 10 + 1000);
        var signs: [dim]f64 = undefined;
        for (0..dim) |i| {
            const k: i32 = @intCast(popcount(@as(u32, @intCast(i))));
            const half = @divTrunc(k * (k - 1), 2);
            signs[i] = if (@mod(half, 2) == 0) 1.0 else -1.0;
        }
        break :blk signs;
    };

    // Pre-computed sign for involute: (-1)^k per slot.
    const involute_sign: [dim]f64 = comptime blk: {
        @setEvalBranchQuota(dim * 10 + 1000);
        var signs: [dim]f64 = undefined;
        for (0..dim) |i| {
            const k = popcount(@as(u32, @intCast(i)));
            signs[i] = if (k & 1 == 0) 1.0 else -1.0;
        }
        break :blk signs;
    };

    // Pre-computed sign for conjugate: (-1)^(k(k+1)/2) per slot.
    const conjugate_sign: [dim]f64 = comptime blk: {
        @setEvalBranchQuota(dim * 10 + 1000);
        var signs: [dim]f64 = undefined;
        for (0..dim) |i| {
            const k: i32 = @intCast(popcount(@as(u32, @intCast(i))));
            const half = @divTrunc(k * (k + 1), 2);
            signs[i] = if (@mod(half, 2) == 0) 1.0 else -1.0;
        }
        break :blk signs;
    };

    return struct {
        const Self = @This();
        pub const N = n;
        pub const DIM = dim;
        pub const P = p;
        pub const Q = q;
        pub const R = r;

        coeffs: [dim]f64,

        /// Zero multivector.
        pub fn zero() Self {
            return .{ .coeffs = [_]f64{0.0} ** dim };
        }

        /// Scalar multivector.
        pub fn scalar(s: f64) Self {
            var mv = zero();
            mv.coeffs[0] = s;
            return mv;
        }

        /// Single basis blade e_i (0-indexed).
        pub fn basis(comptime i: u32) Self {
            comptime {
                if (i >= n) @compileError("basis index out of range for this algebra");
            }
            var mv = zero();
            mv.coeffs[1 << i] = 1.0;
            return mv;
        }

        /// Arbitrary basis blade by bitmask (e.g. 0b101 = e₀₂).
        pub fn blade(comptime mask: u32) Self {
            comptime {
                if (mask >= dim) @compileError("blade mask out of range for this algebra");
            }
            var mv = zero();
            mv.coeffs[mask] = 1.0;
            return mv;
        }

        /// Grade of a basis blade (number of set bits).
        pub fn gradeOf(comptime mask: u32) u32 {
            return popcount(mask);
        }

        /// Extract the grade-k part of a multivector.
        /// Uses precomputed grade bitmask -- branchless via mask test.
        pub fn grade(self: Self, comptime k: u32) Self {
            comptime {
                if (k > n) @compileError("grade exceeds algebra dimension");
            }
            const mask = grade_masks[k];
            var result = zero();
            for (0..dim) |i| {
                if ((mask >> @intCast(i)) & 1 == 1) {
                    result.coeffs[i] = self.coeffs[i];
                }
            }
            return result;
        }

        /// Scalar part (grade 0).
        pub fn scalarPart(self: Self) f64 {
            return self.coeffs[0];
        }

        // --- Geometric Product (the fundamental operation) ---

        /// Geometric product: the full Clifford product.
        /// Uses sparse Cayley table -- only iterates non-zero entries per row.
        pub fn mul(self: Self, other: Self) Self {
            var result = zero();
            for (0..dim) |i| {
                const ai = self.coeffs[i];
                if (ai == 0.0) continue;
                for (sparse_table[i]) |entry| {
                    const val = ai * other.coeffs[entry.j];
                    if (entry.sign == 1) {
                        result.coeffs[entry.blade] += val;
                    } else {
                        result.coeffs[entry.blade] -= val;
                    }
                }
            }
            return result;
        }

        // --- Exterior (Wedge) Product ---

        /// Wedge product: antisymmetric part of geometric product.
        /// a ^ b = sum over pairs where blades don't share any vectors.
        pub fn wedge(self: Self, other: Self) Self {
            var result = zero();
            for (0..dim) |i| {
                if (self.coeffs[i] == 0.0) continue;
                for (0..dim) |j| {
                    if (other.coeffs[j] == 0.0) continue;
                    if ((i & j) != 0) continue;
                    const s = cayley_sign[i][j];
                    if (s == 0) continue;
                    const val = self.coeffs[i] * other.coeffs[j];
                    const b = cayley_blade[i][j];
                    if (s == 1) {
                        result.coeffs[b] += val;
                    } else {
                        result.coeffs[b] -= val;
                    }
                }
            }
            return result;
        }

        // --- Left Contraction ---

        /// Left contraction: a << b. Grade-lowering inner product.
        pub fn leftContract(self: Self, other: Self) Self {
            var result = zero();
            for (0..dim) |i| {
                if (self.coeffs[i] == 0.0) continue;
                for (0..dim) |j| {
                    if (other.coeffs[j] == 0.0) continue;
                    const gi = popcount(@intCast(i));
                    const gj = popcount(@intCast(j));
                    const s = cayley_sign[i][j];
                    if (s == 0) continue;
                    const b = cayley_blade[i][j];
                    const gr = popcount(b);
                    if (gj >= gi and gr == gj - gi) {
                        const val = self.coeffs[i] * other.coeffs[j];
                        if (s == 1) {
                            result.coeffs[b] += val;
                        } else {
                            result.coeffs[b] -= val;
                        }
                    }
                }
            }
            return result;
        }

        // --- Automorphisms (Conjugation / Undo operations) ---

        /// Reverse: SIMD multiply by precomputed sign vector.
        pub fn reverse(self: Self) Self {
            const V = @Vector(dim, f64);
            const a: V = self.coeffs;
            const s: V = reverse_sign;
            return .{ .coeffs = a * s };
        }

        /// Grade involution: SIMD multiply by precomputed sign vector.
        pub fn involute(self: Self) Self {
            const V = @Vector(dim, f64);
            const a: V = self.coeffs;
            const s: V = involute_sign;
            return .{ .coeffs = a * s };
        }

        /// Clifford conjugate: SIMD multiply by precomputed sign vector.
        pub fn conjugate(self: Self) Self {
            const V = @Vector(dim, f64);
            const a: V = self.coeffs;
            const s: V = conjugate_sign;
            return .{ .coeffs = a * s };
        }

        // --- Arithmetic ---

        /// SIMD-friendly add: @Vector when dim is power of 2 (always true).
        pub fn add(self: Self, other: Self) Self {
            const V = @Vector(dim, f64);
            const a: V = self.coeffs;
            const b: V = other.coeffs;
            return .{ .coeffs = a + b };
        }

        pub fn sub(self: Self, other: Self) Self {
            const V = @Vector(dim, f64);
            const a: V = self.coeffs;
            const b: V = other.coeffs;
            return .{ .coeffs = a - b };
        }

        pub fn scale(self: Self, s: f64) Self {
            const V = @Vector(dim, f64);
            const a: V = self.coeffs;
            const sv: V = @splat(s);
            return .{ .coeffs = a * sv };
        }

        /// Squared norm: x * reverse(x), scalar part.
        pub fn normSq(self: Self) f64 {
            return self.mul(self.reverse()).scalarPart();
        }

        /// Norm: sqrt(|normSq|).
        pub fn norm(self: Self) f64 {
            return @sqrt(@abs(self.normSq()));
        }

        /// Sandwich product: a >>> b = a * b * reverse(a).
        /// The fundamental conjugation/transformation operation.
        pub fn sandwich(self: Self, other: Self) Self {
            return self.mul(other).mul(self.reverse());
        }

        /// Inverse (for invertible elements): x^-1 = reverse(x) / normSq(x).
        /// Returns null if the element is not invertible (normSq ~ 0).
        pub fn inverse(self: Self) ?Self {
            const ns = self.normSq();
            if (@abs(ns) < 1e-12) return null;
            return self.reverse().scale(1.0 / ns);
        }

        /// Approximate equality within tolerance.
        pub fn approxEql(self: Self, other: Self, tolerance: f64) bool {
            for (0..dim) |i| {
                if (@abs(self.coeffs[i] - other.coeffs[i]) > tolerance) return false;
            }
            return true;
        }
    };
}

// ============================================================
// Tests: Milestone 1 - Cayley table, geometric product, identities
// ============================================================

test "scalar algebra Algebra(0,0,0)" {
    const S = Algebra(0, 0, 0);
    comptime {
        std.debug.assert(S.DIM == 1);
        std.debug.assert(S.N == 0);
    }
    const a = S.scalar(3.0);
    const b = S.scalar(5.0);
    const c = a.mul(b);
    try testing.expectApproxEqAbs(c.scalarPart(), 15.0, 1e-10);
}

test "complex numbers Algebra(0,1,0)" {
    const C = Algebra(0, 1, 0);
    comptime {
        std.debug.assert(C.DIM == 2);
    }
    const one = C.scalar(1.0);
    const i_unit = C.basis(0); // e₀ squares to -1

    // i * i = -1
    const ii = i_unit.mul(i_unit);
    try testing.expectApproxEqAbs(ii.scalarPart(), -1.0, 1e-10);
    try testing.expectApproxEqAbs(ii.coeffs[1], 0.0, 1e-10);

    // (1 + i)(1 - i) = 1 - i² = 1 + 1 = 2
    const z1 = one.add(i_unit);
    const z2 = one.sub(i_unit);
    const product = z1.mul(z2);
    try testing.expectApproxEqAbs(product.scalarPart(), 2.0, 1e-10);
}

test "dual numbers Algebra(0,0,1) matches HyperReal" {
    const D = Algebra(0, 0, 1);
    comptime {
        std.debug.assert(D.DIM == 2);
    }
    const eps = D.basis(0); // e₀ squares to 0 (degenerate)

    // ε * ε = 0
    const ee = eps.mul(eps);
    try testing.expectApproxEqAbs(ee.scalarPart(), 0.0, 1e-10);
    try testing.expectApproxEqAbs(ee.coeffs[1], 0.0, 1e-10);

    // (a + bε)(c + dε) = ac + (ad+bc)ε
    var x = D.scalar(3.0);
    x.coeffs[1] = 2.0; // 3 + 2ε
    var y = D.scalar(5.0);
    y.coeffs[1] = 7.0; // 5 + 7ε
    const z = x.mul(y);
    try testing.expectApproxEqAbs(z.scalarPart(), 15.0, 1e-10); // 3*5
    try testing.expectApproxEqAbs(z.coeffs[1], 31.0, 1e-10); // 3*7 + 2*5
}

test "quaternions Algebra(0,2,0)" {
    const H = Algebra(0, 2, 0);
    comptime {
        std.debug.assert(H.DIM == 4);
        std.debug.assert(H.N == 2);
    }
    const i_q = H.basis(0); // e₀
    const j_q = H.basis(1); // e₁
    const k_q = H.blade(0b11); // e₀₁

    // i² = j² = k² = -1
    try testing.expectApproxEqAbs(i_q.mul(i_q).scalarPart(), -1.0, 1e-10);
    try testing.expectApproxEqAbs(j_q.mul(j_q).scalarPart(), -1.0, 1e-10);
    try testing.expectApproxEqAbs(k_q.mul(k_q).scalarPart(), -1.0, 1e-10);

    // ij = k
    const ij = i_q.mul(j_q);
    try testing.expect(ij.approxEql(k_q, 1e-10));

    // ji = -k
    const ji = j_q.mul(i_q);
    try testing.expect(ji.approxEql(k_q.scale(-1.0), 1e-10));

    // ijk = -1
    const ijk = i_q.mul(j_q).mul(k_q);
    try testing.expectApproxEqAbs(ijk.scalarPart(), -1.0, 1e-10);
}

test "3D Euclidean Algebra(3,0,0) - VGA basics" {
    const VGA = Algebra(3, 0, 0);
    comptime {
        std.debug.assert(VGA.DIM == 8);
    }
    const e1 = VGA.basis(0);
    const e2 = VGA.basis(1);
    const e3 = VGA.basis(2);

    // eᵢ² = +1 for Euclidean
    try testing.expectApproxEqAbs(e1.mul(e1).scalarPart(), 1.0, 1e-10);
    try testing.expectApproxEqAbs(e2.mul(e2).scalarPart(), 1.0, 1e-10);
    try testing.expectApproxEqAbs(e3.mul(e3).scalarPart(), 1.0, 1e-10);

    // Anti-commutativity: e₁e₂ = -e₂e₁
    const e12 = e1.mul(e2);
    const e21 = e2.mul(e1);
    try testing.expect(e12.approxEql(e21.scale(-1.0), 1e-10));

    // Wedge product: e₁ ^ e₂ = e₁₂
    const w12 = e1.wedge(e2);
    try testing.expectApproxEqAbs(w12.coeffs[0b011], 1.0, 1e-10);

    // Wedge is antisymmetric: e₁ ^ e₁ = 0
    const w11 = e1.wedge(e1);
    try testing.expect(w11.approxEql(VGA.zero(), 1e-10));
}

test "reverse is involution" {
    const VGA = Algebra(3, 0, 0);
    const e1 = VGA.basis(0);
    const e2 = VGA.basis(1);
    const v = e1.add(e2.scale(2.0));

    // reverse(reverse(x)) = x
    try testing.expect(v.reverse().reverse().approxEql(v, 1e-10));

    // For vectors (grade 1): reverse is identity
    try testing.expect(e1.reverse().approxEql(e1, 1e-10));

    // For bivectors (grade 2): reverse negates
    const e12 = e1.mul(e2);
    try testing.expect(e12.reverse().approxEql(e12.scale(-1.0), 1e-10));
}

test "conjugate and involute" {
    const VGA = Algebra(3, 0, 0);
    const e1 = VGA.basis(0);
    const e2 = VGA.basis(1);

    // Involute negates odd grades
    try testing.expect(e1.involute().approxEql(e1.scale(-1.0), 1e-10));

    // Involute is identity on even grades
    const e12 = e1.wedge(e2);
    try testing.expect(e12.involute().approxEql(e12, 1e-10));

    // Conjugate = involute(reverse(x))
    const v = e1.add(e12);
    const conj = v.conjugate();
    const manual = v.reverse().involute();
    try testing.expect(conj.approxEql(manual, 1e-10));
}

test "sandwich product preserves norm" {
    const VGA = Algebra(3, 0, 0);
    const e1 = VGA.basis(0);
    const e2 = VGA.basis(1);

    // Rotor: R = cos(θ/2) + sin(θ/2)*e₁₂
    const angle = std.math.pi / 4.0; // 45 degrees
    const e12 = e1.wedge(e2);
    const rotor = VGA.scalar(@cos(angle / 2.0)).add(e12.scale(@sin(angle / 2.0)));

    // Sandwich: R * e₁ * R~
    const rotated = rotor.sandwich(e1);
    // Norm should be preserved
    try testing.expectApproxEqAbs(rotated.norm(), e1.norm(), 1e-10);
}

test "inverse exists for vectors in Euclidean" {
    const VGA = Algebra(3, 0, 0);
    const e1 = VGA.basis(0);

    // e₁ is invertible: e₁⁻¹ = e₁ (since e₁² = 1)
    const inv = e1.inverse().?;
    const identity = e1.mul(inv);
    try testing.expectApproxEqAbs(identity.scalarPart(), 1.0, 1e-10);
}

test "inverse null for degenerate" {
    const D = Algebra(0, 0, 1);
    const eps = D.basis(0);

    // ε has no inverse (ε² = 0)
    try testing.expect(eps.inverse() == null);
}

test "grade extraction" {
    const VGA = Algebra(3, 0, 0);
    const e1 = VGA.basis(0);
    const e2 = VGA.basis(1);
    const e12 = e1.wedge(e2);

    // Mixed: scalar + vector + bivector
    const mixed = VGA.scalar(5.0).add(e1.scale(3.0)).add(e12.scale(2.0));

    const g0 = mixed.grade(0);
    try testing.expectApproxEqAbs(g0.scalarPart(), 5.0, 1e-10);

    const g1 = mixed.grade(1);
    try testing.expectApproxEqAbs(g1.coeffs[0b001], 3.0, 1e-10);
    try testing.expectApproxEqAbs(g1.scalarPart(), 0.0, 1e-10);

    const g2 = mixed.grade(2);
    try testing.expectApproxEqAbs(g2.coeffs[0b011], 2.0, 1e-10);
    try testing.expectApproxEqAbs(g2.scalarPart(), 0.0, 1e-10);
}

test "PGA signature Algebra(3,0,1) compiles" {
    const PGA = Algebra(3, 0, 1);
    comptime {
        std.debug.assert(PGA.DIM == 16);
        std.debug.assert(PGA.N == 4);
    }
    // Basis 0,1,2 are Euclidean (square to +1), basis 3 is degenerate (square to 0)
    const e0 = PGA.basis(0);
    try testing.expectApproxEqAbs(e0.mul(e0).scalarPart(), 1.0, 1e-10);

    const e1 = PGA.basis(1);
    try testing.expectApproxEqAbs(e1.mul(e1).scalarPart(), 1.0, 1e-10);

    // e₃ is the degenerate basis: e₃² = 0
    const e3 = PGA.basis(3);
    try testing.expectApproxEqAbs(e3.mul(e3).scalarPart(), 0.0, 1e-10);
}

test "CGA signature Algebra(4,1,0) compiles" {
    const CGA = Algebra(4, 1, 0);
    comptime {
        std.debug.assert(CGA.DIM == 32);
        std.debug.assert(CGA.N == 5);
    }
    // Last basis vector squares to -1 (Minkowski)
    const e_minus = CGA.basis(4);
    try testing.expectApproxEqAbs(e_minus.mul(e_minus).scalarPart(), -1.0, 1e-10);
}

test "left contraction grade rule" {
    const VGA = Algebra(3, 0, 0);
    const e1 = VGA.basis(0);
    const e2 = VGA.basis(1);
    const e12 = e1.wedge(e2);

    // e₁ << e₁₂ should give e₂ (grade 2 - grade 1 = grade 1)
    const lc = e1.leftContract(e12);
    try testing.expectApproxEqAbs(lc.coeffs[0b010], 1.0, 1e-10);

    // e₁₂ << e₁ should give 0 (can't lower grade below 0)
    const lc2 = e12.leftContract(e1);
    try testing.expect(lc2.approxEql(VGA.zero(), 1e-10));
}
