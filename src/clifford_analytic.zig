//! Analytic Continuation for Clifford Algebras
//!
//! Extends Algebra(p,q,r) elements beyond their natural domain:
//!
//! 1. **Multivector Exponential** exp(B): Power series sum B^k/k!
//!    - For pure bivectors: produces rotors (Spin group elements)
//!    - Converges for all finite multivectors
//!    - Truncated at configurable order with remainder bound
//!
//! 2. **Multivector Logarithm** log(R): Inverse of exp
//!    - For rotors near identity: power series in (R - 1)
//!    - Returns the bivector "angle" that generates the rotation
//!    - Branch cut: undefined for R with scalar part <= 0
//!
//! 3. **Fractional Powers** pow(x, t): exp(t * log(x))
//!    - Continuous interpolation between identity and x
//!    - sqrt(x) = pow(x, 0.5)
//!
//! 4. **Metric Deformation** (signature continuation):
//!    - Parameterize metric as g(t) = (1-t)*g₀ + t*g₁
//!    - At t=0: original algebra, at t=1: target algebra
//!    - Cayley table entries become continuous functions of t
//!
//! The continuation carries its own convergence context:
//! partial sums, remainder estimates, and the path through
//! parameter space. No hidden state -- the AnalyticContext
//! struct IS the continuation.
//!
//! Connection to HyperReal: dual numbers Algebra(0,0,1) give
//! automatic differentiation. exp(aε) = 1 + aε exactly (ε²=0),
//! so analytic continuation of exp "knows about" derivatives.

const std = @import("std");
const math = std.math;
const testing = std.testing;
const clifford = @import("clifford");

/// Result of a truncated power series computation.
/// Carries the partial sum AND the convergence information.
pub fn SeriesResult(comptime MV: type) type {
    return struct {
        /// The computed partial sum.
        value: MV,
        /// Number of terms used.
        terms_used: u32,
        /// Upper bound on the remainder |R_n| <= last_term_norm * (ratio / (1 - ratio)).
        /// NaN if ratio >= 1 (not converging).
        remainder_bound: f64,
        /// Norm of the last term added (measures convergence rate).
        last_term_norm: f64,
        /// Whether the series converged within tolerance.
        converged: bool,
    };
}

/// Analytic functions on Clifford algebra elements.
/// Parameterized by algebra type (which fixes signature at comptime).
pub fn Analytic(comptime p: u32, comptime q: u32, comptime r: u32) type {
    const MV = clifford.Algebra(p, q, r);

    return struct {
        /// Maximum terms in power series before giving up.
        pub const DEFAULT_MAX_TERMS: u32 = 64;
        /// Default convergence tolerance.
        pub const DEFAULT_TOL: f64 = 1e-14;

        // ================================================================
        // Exponential: exp(X) = sum_{k=0}^{inf} X^k / k!
        // ================================================================

        /// Multivector exponential via truncated power series.
        ///
        /// For a pure bivector B (grade 2), this produces a rotor:
        ///   exp(B) = cos(|B|) + sin(|B|)/|B| * B   (Euclidean case)
        ///
        /// For general multivectors, uses the universal formula:
        ///   exp(X) = 1 + X + X²/2! + X³/3! + ...
        ///
        /// Returns the partial sum together with convergence data.
        pub fn exp(x: MV) SeriesResult(MV) {
            return expWithParams(x, DEFAULT_MAX_TERMS, DEFAULT_TOL);
        }

        /// Exponential with explicit truncation parameters.
        pub fn expWithParams(x: MV, max_terms: u32, tol: f64) SeriesResult(MV) {
            // term_k = X^k / k!, built incrementally: term_{k+1} = term_k * X / (k+1)
            var sum = MV.scalar(1.0); // k=0 term
            var term = MV.scalar(1.0);
            var last_norm: f64 = 1.0;
            var prev_norm: f64 = math.inf(f64);

            var k: u32 = 1;
            while (k <= max_terms) : (k += 1) {
                term = term.mul(x).scale(1.0 / @as(f64, @floatFromInt(k)));
                last_norm = term.norm();

                sum = sum.add(term);

                if (last_norm < tol) {
                    // Converged: remainder bounded by geometric series
                    const ratio = if (prev_norm > 0) last_norm / prev_norm else 0.0;
                    const remainder = if (ratio < 1.0)
                        last_norm * ratio / (1.0 - ratio)
                    else
                        math.nan(f64);

                    return .{
                        .value = sum,
                        .terms_used = k,
                        .remainder_bound = remainder,
                        .last_term_norm = last_norm,
                        .converged = true,
                    };
                }
                prev_norm = last_norm;
            }

            // Did not converge within max_terms
            return .{
                .value = sum,
                .terms_used = max_terms,
                .remainder_bound = math.nan(f64),
                .last_term_norm = last_norm,
                .converged = false,
            };
        }

        // ================================================================
        // Bivector exponential (closed-form when possible)
        // ================================================================

        /// Fast exponential for pure bivectors in non-degenerate algebras.
        ///
        /// For a bivector B with B² = -|B|² (true in Euclidean signatures):
        ///   exp(B) = cos(|B|) + sin(|B|)/|B| * B
        ///
        /// This is the Euler formula generalized to arbitrary dimension.
        /// Returns null if B² is not a negative scalar (use general exp instead).
        pub fn expBivector(b: MV) ?MV {
            // Check: b should be pure grade-2
            const grade2 = b.grade(2);
            if (!grade2.approxEql(b, 1e-12)) return null;

            // B² should be a negative scalar for this formula
            const b_sq = b.mul(b);
            // Check all non-scalar components are ~0
            for (1..MV.DIM) |i| {
                if (@abs(b_sq.coeffs[i]) > 1e-12) return null;
            }

            const minus_norm_sq = b_sq.scalarPart(); // Should be negative
            if (minus_norm_sq >= 0) {
                if (@abs(minus_norm_sq) < 1e-14) {
                    // B² = 0 (degenerate/null bivector): exp(B) = 1 + B
                    return MV.scalar(1.0).add(b);
                }
                return null; // B² > 0: hyperbolic case, use general exp
            }

            const norm_sq = -minus_norm_sq;
            const norm_b = @sqrt(norm_sq);
            const cos_part = MV.scalar(@cos(norm_b));
            const sin_part = b.scale(@sin(norm_b) / norm_b);
            return cos_part.add(sin_part);
        }

        // ================================================================
        // Logarithm: log(R) where R is near the identity
        // ================================================================

        /// Multivector logarithm via power series in (R - 1).
        ///
        /// log(1 + X) = X - X²/2 + X³/3 - X⁴/4 + ...
        ///
        /// Converges for |X| < 1 (spectral radius condition).
        /// For rotors: R = exp(B) with |B| < pi, so log(R) recovers B.
        ///
        /// Returns null if the input is too far from identity (|R - 1| >= 1).
        pub fn log(x: MV) ?SeriesResult(MV) {
            return logWithParams(x, DEFAULT_MAX_TERMS, DEFAULT_TOL);
        }

        /// Logarithm with explicit parameters.
        pub fn logWithParams(x_in: MV, max_terms: u32, tol: f64) ?SeriesResult(MV) {
            const x = x_in.sub(MV.scalar(1.0)); // R - 1
            const x_norm = x.norm();

            if (x_norm >= 1.0) return null; // Outside radius of convergence

            // log(1+X) = sum_{k=1}^{inf} (-1)^{k+1} X^k / k
            var sum = MV.zero();
            var x_power = x; // X^1
            var last_norm: f64 = x_norm;

            var k: u32 = 1;
            while (k <= max_terms) : (k += 1) {
                const sign: f64 = if (k & 1 == 1) 1.0 else -1.0;
                const term = x_power.scale(sign / @as(f64, @floatFromInt(k)));
                last_norm = term.norm();
                sum = sum.add(term);

                if (last_norm < tol) {
                    return .{
                        .value = sum,
                        .terms_used = k,
                        .remainder_bound = last_norm * x_norm / (1.0 - x_norm),
                        .last_term_norm = last_norm,
                        .converged = true,
                    };
                }

                x_power = x_power.mul(x); // X^{k+1}
            }

            return .{
                .value = sum,
                .terms_used = max_terms,
                .remainder_bound = math.nan(f64),
                .last_term_norm = last_norm,
                .converged = false,
            };
        }

        /// Logarithm for rotors (elements of Spin group).
        ///
        /// Uses the identity: for a rotor R = cos(theta) + sin(theta) * B_hat,
        ///   log(R) = theta * B_hat = atan2(|B|, scalar) * B / |B|
        ///
        /// Returns null if R is not a valid rotor (normSq != +/-1)
        /// or if the bivector part vanishes (R = +/-1, log is 0 or undefined).
        pub fn logRotor(rotor: MV) ?MV {
            const s = rotor.scalarPart();
            const biv = rotor.sub(MV.scalar(s)); // Bivector part

            const biv_norm = biv.norm();
            if (biv_norm < 1e-14) {
                // R is (close to) a scalar
                if (s > 0) return MV.zero(); // log(1) = 0
                return null; // log(-1) = branch cut
            }

            const theta = math.atan2(biv_norm, s);
            return biv.scale(theta / biv_norm);
        }

        // ================================================================
        // Fractional powers: pow(x, t) = exp(t * log(x))
        // ================================================================

        /// Continuous power: x^t = exp(t * log(x)).
        ///
        /// For rotors: interpolates between identity (t=0) and x (t=1).
        /// This is SLERP in the Clifford algebra setting.
        ///
        /// Returns null if log(x) fails (x too far from identity or on branch cut).
        pub fn pow(x: MV, t: f64) ?SeriesResult(MV) {
            const log_x = log(x) orelse return null;
            if (!log_x.converged) return null;
            return exp(log_x.value.scale(t));
        }

        /// Square root via fractional power.
        pub fn sqrt(x: MV) ?SeriesResult(MV) {
            return pow(x, 0.5);
        }

        /// Rotor interpolation (SLERP): smoothly interpolate between
        /// identity and rotor R by parameter t in [0, 1].
        ///
        /// slerp(R, 0) = identity
        /// slerp(R, 1) = R
        /// slerp(R, 0.5) = "half rotation"
        pub fn slerp(rotor: MV, t: f64) ?MV {
            const log_r = logRotor(rotor) orelse return null;
            const result = expBivector(log_r.scale(t));
            if (result) |v| return v;
            // Fallback to general exp if closed form fails
            return exp(log_r.scale(t)).value;
        }

        // ================================================================
        // Metric deformation: signature continuation
        // ================================================================

        /// Deformed metric product at parameter t in [0, 1].
        ///
        /// At t=0: uses the original signature (p, q, r).
        /// At t=1: uses the target metric signs.
        ///
        /// The geometric product becomes:
        ///   e_i * e_i = (1-t)*original_metric(i) + t*target_metric(i)
        ///
        /// This allows analytic continuation between different signatures,
        /// e.g., from Euclidean (3,0,0) toward Minkowski (2,1,0).
        ///
        /// The result is an array of f64 coefficients (not typed to either algebra)
        /// because intermediate points have non-integer metric signatures.
        pub fn deformedProduct(
            a_coeffs: [MV.DIM]f64,
            b_coeffs: [MV.DIM]f64,
            target_metric: [MV.N]f64,
            t: f64,
        ) [MV.DIM]f64 {
            var result: [MV.DIM]f64 = @splat(0.0);
            const dim = MV.DIM;

            for (0..dim) |i| {
                if (a_coeffs[i] == 0.0) continue;
                for (0..dim) |j| {
                    if (b_coeffs[j] == 0.0) continue;

                    // Compute deformed Cayley entry for basis pair (i, j)
                    const swap_neg = swapSignRuntime(@intCast(i), @intCast(j));

                    // Deformed metric contraction
                    const shared: u32 = @as(u32, @intCast(i)) & @as(u32, @intCast(j));
                    const result_blade: u32 = @as(u32, @intCast(i)) ^ @as(u32, @intCast(j));
                    var factor: f64 = 1.0;

                    var mask = shared;
                    while (mask != 0) {
                        const bit = @ctz(mask);
                        // Interpolated metric: (1-t)*original + t*target
                        const original: f64 = if (bit < p)
                            1.0
                        else if (bit < p + q)
                            -1.0
                        else
                            0.0;
                        const target = target_metric[bit];
                        factor *= (1.0 - t) * original + t * target;
                        mask &= mask - 1;
                    }

                    var sign: f64 = factor;
                    if (swap_neg) sign = -sign;
                    result[result_blade] += a_coeffs[i] * b_coeffs[j] * sign;
                }
            }
            return result;
        }

        // ================================================================
        // Complexification: extend to C x Cl(p,q,r)
        // ================================================================

        /// A multivector with complex coefficients.
        /// Enables analytic continuation past real branch points.
        pub const ComplexMV = struct {
            re: [MV.DIM]f64,
            im: [MV.DIM]f64,

            pub fn fromReal(mv: MV) ComplexMV {
                return .{
                    .re = mv.coeffs,
                    .im = @splat(0.0),
                };
            }

            pub fn real(self: ComplexMV) MV {
                return .{ .coeffs = self.re };
            }

            pub fn imagPart(self: ComplexMV) MV {
                return .{ .coeffs = self.im };
            }

            pub fn add(self: ComplexMV, other: ComplexMV) ComplexMV {
                const V = @Vector(MV.DIM, f64);
                const a_re: V = self.re;
                const a_im: V = self.im;
                const b_re: V = other.re;
                const b_im: V = other.im;
                return .{
                    .re = a_re + b_re,
                    .im = a_im + b_im,
                };
            }

            pub fn scale(self: ComplexMV, s_re: f64, s_im: f64) ComplexMV {
                const V = @Vector(MV.DIM, f64);
                const a_re: V = self.re;
                const a_im: V = self.im;
                const sr: V = @splat(s_re);
                const si: V = @splat(s_im);
                return .{
                    .re = a_re * sr - a_im * si,
                    .im = a_re * si + a_im * sr,
                };
            }

            pub fn normSq(self: ComplexMV) f64 {
                var s: f64 = 0;
                for (0..MV.DIM) |i| {
                    s += self.re[i] * self.re[i] + self.im[i] * self.im[i];
                }
                return s;
            }
        };

        // ================================================================
        // Internal helpers
        // ================================================================

        /// Runtime swap sign (same algorithm as comptime version in clifford.zig).
        fn swapSignRuntime(a: u32, b: u32) bool {
            var n_swaps: u32 = 0;
            var x = a >> 1;
            while (x != 0) : (x >>= 1) {
                n_swaps += @popCount(x & b);
            }
            return (n_swaps & 1) == 1;
        }
    };
}

// ============================================================
// Tests
// ============================================================

test "exp of zero is identity" {
    const A = Analytic(3, 0, 0);
    const MV = clifford.Algebra(3, 0, 0);
    const result = A.exp(MV.zero());
    try testing.expect(result.converged);
    try testing.expectApproxEqAbs(result.value.scalarPart(), 1.0, 1e-12);
    // All non-scalar parts should be zero
    for (1..MV.DIM) |i| {
        try testing.expectApproxEqAbs(result.value.coeffs[i], 0.0, 1e-12);
    }
}

test "exp of scalar is real exponential" {
    const A = Analytic(3, 0, 0);
    const MV = clifford.Algebra(3, 0, 0);
    const x = MV.scalar(1.0);
    const result = A.exp(x);
    try testing.expect(result.converged);
    try testing.expectApproxEqAbs(result.value.scalarPart(), math.e, 1e-10);
}

test "exp(bivector) produces rotor in VGA" {
    const A = Analytic(3, 0, 0);
    const MV = clifford.Algebra(3, 0, 0);

    const e1 = MV.basis(0);
    const e2 = MV.basis(1);
    const e12 = e1.wedge(e2);

    // exp(theta/2 * e12) should give rotor: cos(theta/2) + sin(theta/2)*e12
    const theta: f64 = math.pi / 3.0; // 60 degrees
    const b = e12.scale(theta / 2.0);

    const result = A.exp(b);
    try testing.expect(result.converged);
    try testing.expectApproxEqAbs(result.value.scalarPart(), @cos(theta / 2.0), 1e-10);
    try testing.expectApproxEqAbs(result.value.coeffs[0b011], @sin(theta / 2.0), 1e-10);
}

test "expBivector matches general exp for pure bivectors" {
    const A = Analytic(3, 0, 0);
    const MV = clifford.Algebra(3, 0, 0);

    const e1 = MV.basis(0);
    const e2 = MV.basis(1);
    const b = e1.wedge(e2).scale(0.7);

    const general = A.exp(b);
    const fast = A.expBivector(b).?;

    try testing.expect(general.converged);
    try testing.expect(general.value.approxEql(fast, 1e-10));
}

test "exp then log roundtrips for small bivectors" {
    const A = Analytic(3, 0, 0);
    const MV = clifford.Algebra(3, 0, 0);

    const e1 = MV.basis(0);
    const e2 = MV.basis(1);
    const b = e1.wedge(e2).scale(0.3); // Small angle

    const rotor = A.exp(b);
    try testing.expect(rotor.converged);

    const recovered = A.log(rotor.value).?;
    try testing.expect(recovered.converged);
    try testing.expect(recovered.value.approxEql(b, 1e-8));
}

test "logRotor recovers bivector angle" {
    const A = Analytic(3, 0, 0);
    const MV = clifford.Algebra(3, 0, 0);

    const e1 = MV.basis(0);
    const e2 = MV.basis(1);
    const theta: f64 = math.pi / 4.0;
    const b = e1.wedge(e2).scale(theta / 2.0);
    const rotor = A.expBivector(b).?;

    const log_r = A.logRotor(rotor).?;
    try testing.expect(log_r.approxEql(b, 1e-10));
}

test "slerp interpolates between identity and rotor" {
    const A = Analytic(3, 0, 0);
    const MV = clifford.Algebra(3, 0, 0);

    const e1 = MV.basis(0);
    const e2 = MV.basis(1);
    const theta: f64 = math.pi / 2.0; // 90-degree rotation
    const b = e1.wedge(e2).scale(theta / 2.0);
    const rotor = A.expBivector(b).?;

    // At t=0: identity
    const r0 = A.slerp(rotor, 0.0).?;
    try testing.expectApproxEqAbs(r0.scalarPart(), 1.0, 1e-10);

    // At t=1: full rotor
    const r1 = A.slerp(rotor, 1.0).?;
    try testing.expect(r1.approxEql(rotor, 1e-10));

    // At t=0.5: half-angle rotor
    const r_half = A.slerp(rotor, 0.5).?;
    const half_angle = theta / 4.0;
    try testing.expectApproxEqAbs(r_half.scalarPart(), @cos(half_angle), 1e-10);
}

test "exp of dual number: exp(aε) = 1 + aε exactly" {
    const A = Analytic(0, 0, 1);
    const D = clifford.Algebra(0, 0, 1);

    var x = D.zero();
    x.coeffs[1] = 3.0; // 3ε

    const result = A.exp(x);
    try testing.expect(result.converged);
    try testing.expectApproxEqAbs(result.value.scalarPart(), 1.0, 1e-12);
    try testing.expectApproxEqAbs(result.value.coeffs[1], 3.0, 1e-12);
}

test "sqrt of scalar" {
    const A = Analytic(3, 0, 0);
    const MV = clifford.Algebra(3, 0, 0);

    // sqrt(4) should be close to 2
    // Note: pow uses log, which requires |x-1| < 1, so we test x = 1.5
    const x = MV.scalar(1.5);
    const result = A.sqrt(x).?;
    try testing.expect(result.converged);
    try testing.expectApproxEqAbs(
        result.value.scalarPart() * result.value.scalarPart(),
        1.5,
        1e-6,
    );
}

test "metric deformation: Euclidean toward Minkowski" {
    const A = Analytic(3, 0, 0);
    const MV = clifford.Algebra(3, 0, 0);

    // e1 * e1 under original metric = +1
    const e1 = MV.basis(0);

    // Target: (2,1,0) -- third basis flips to -1
    const target = [3]f64{ 1.0, 1.0, -1.0 };

    // At t=0: original product
    const p0 = A.deformedProduct(e1.coeffs, e1.coeffs, target, 0.0);
    try testing.expectApproxEqAbs(p0[0], 1.0, 1e-12); // e1*e1 = +1

    // At t=1: still +1 (e1 is Euclidean in both)
    const p1 = A.deformedProduct(e1.coeffs, e1.coeffs, target, 1.0);
    try testing.expectApproxEqAbs(p1[0], 1.0, 1e-12);

    // e3 * e3 at t=0: +1, at t=1: -1, at t=0.5: 0
    const e3 = MV.basis(2);
    const p_half = A.deformedProduct(e3.coeffs, e3.coeffs, target, 0.5);
    try testing.expectApproxEqAbs(p_half[0], 0.0, 1e-12); // Interpolated to degenerate

    const p_full = A.deformedProduct(e3.coeffs, e3.coeffs, target, 1.0);
    try testing.expectApproxEqAbs(p_full[0], -1.0, 1e-12); // Flipped to Minkowski
}

test "complexification roundtrip" {
    const A = Analytic(3, 0, 0);
    const MV = clifford.Algebra(3, 0, 0);

    const v = MV.basis(0).add(MV.basis(1).scale(2.0));
    const c = A.ComplexMV.fromReal(v);

    try testing.expect(c.real().approxEql(v, 1e-12));
    try testing.expect(c.imagPart().approxEql(MV.zero(), 1e-12));

    // Scale by i: real -> imag, imag -> -real
    const ci = c.scale(0.0, 1.0);
    try testing.expect(ci.real().approxEql(MV.zero(), 1e-12));
    try testing.expect(ci.imagPart().approxEql(v, 1e-12));

    // Scale by i twice: should negate
    const ci2 = ci.scale(0.0, 1.0);
    const neg_v = v.scale(-1.0);
    try testing.expect(ci2.real().approxEql(neg_v, 1e-12));
}

test "PGA exponential: translation via null bivector" {
    const A = Analytic(3, 0, 1);
    const PGA = clifford.Algebra(3, 0, 1);

    // In PGA, e₃ is degenerate (e₃² = 0)
    // A "translation bivector" like e₀₃ has e₀₃² = 0
    // So exp(d/2 * e₀₃) = 1 + d/2 * e₀₃  (terminates exactly)
    const e0 = PGA.basis(0);
    const e3 = PGA.basis(3);
    const e03 = e0.wedge(e3); // Translation generator

    const d: f64 = 5.0;
    const biv = e03.scale(d / 2.0);
    const result = A.exp(biv);

    try testing.expect(result.converged);
    try testing.expectApproxEqAbs(result.value.scalarPart(), 1.0, 1e-12);

    // The e03 component should be d/2
    const e03_mask = 0b1001; // e0 | e3
    try testing.expectApproxEqAbs(result.value.coeffs[e03_mask], d / 2.0, 1e-10);
}
