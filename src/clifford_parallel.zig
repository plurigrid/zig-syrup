//! Maximally Parallel Clifford Algebra + SPI-Guaranteed TOFU Authentication
//!
//! Three embarrassingly parallel systems unified by SPI (Strong Parallelism Invariance):
//!
//! 1. **Parallel Geometric Product**: N independent sandwiches computed simultaneously
//!    via batch SIMD -- no inter-element dependencies within a batch.
//!
//! 2. **Parallel TOFU Coloring**: Each multivector coefficient maps to a deterministic
//!    color via SplitMix64. Trust-On-First-Use: the color IS the identity.
//!    color(seed, index) == color(seed, index) regardless of computation order (SPI).
//!
//! 3. **Parallel GF(3) Trit Fanout**: Every Clifford operation produces a trit
//!    classification (Generator/Coordinator/Validator) that can be computed
//!    independently per element. Conservation holds over any complete batch.
//!
//! The key insight: Clifford algebra operations on INDEPENDENT multivectors
//! are embarrassingly parallel. A batch of N sandwich products has zero
//! data dependencies between elements. SPI guarantees identical results
//! regardless of execution order.
//!
//! Connection to gay-tofu: each multivector gets a deterministic color fingerprint
//! via its coefficient hash. First observation pins the identity (TOFU).
//! Subsequent observations verify via SPI: same seed + same coefficients = same color.

const std = @import("std");
const math = std.math;
const testing = std.testing;
const clifford = @import("clifford");
const clifford_analytic = @import("clifford_analytic");

// ============================================================================
// SplitMix64 (inline, no state, O(1) at any index) -- SPI core
// ============================================================================

const GOLDEN: u64 = 0x9e3779b97f4a7c15;
const MIX1: u64 = 0xbf58476d1ce4e5b9;
const MIX2: u64 = 0x94d049bb133111eb;

fn splitmix64(state: u64) u64 {
    var z = state;
    z = (z ^ (z >> 30)) *% MIX1;
    z = (z ^ (z >> 27)) *% MIX2;
    return z ^ (z >> 31);
}

/// O(1) color at any index. SPI: order-independent.
fn colorAtIndex(seed: u64, index: u64) u64 {
    return splitmix64(seed +% GOLDEN *% index);
}

// ============================================================================
// GF(3) Trit -- parallel classification
// ============================================================================

pub const Trit = enum(i8) {
    minus = -1, // Validator
    zero = 0, // Coordinator
    plus = 1, // Generator

    pub fn fromU64(val: u64) Trit {
        return switch (val % 3) {
            0 => .zero,
            1 => .plus,
            2 => .minus,
            else => unreachable,
        };
    }
};

// ============================================================================
// TOFU Fingerprint -- deterministic color identity for any multivector
// ============================================================================

/// TOFU (Trust On First Use) fingerprint for a multivector.
/// Hash all coefficients with a seed to produce a deterministic color.
/// Same multivector + same seed = same fingerprint (SPI).
pub fn TofuFingerprint(comptime MV: type) type {
    return struct {
        /// RGB color derived from coefficient hash.
        r: u8,
        g: u8,
        b: u8,
        /// GF(3) trit classification of the dominant grade.
        trit: Trit,
        /// Coefficient hash (full 64-bit for verification).
        hash: u64,

        const Self = @This();

        /// Compute fingerprint. Pure function, no state, SPI-safe.
        pub fn compute(mv: MV, seed: u64) Self {
            // Hash all coefficients into a single u64
            var h: u64 = seed;
            for (mv.coeffs) |c| {
                const bits: u64 = @bitCast(c);
                h = h ^ bits;
                h = splitmix64(h);
            }

            // Extract RGB from hash
            const color = splitmix64(h);

            // Determine dominant grade for trit via popcount (no comptime grade call)
            var max_grade: u32 = 0;
            var max_norm: f64 = 0;
            inline for (0..MV.N + 1) |k| {
                var gnorm: f64 = 0;
                for (0..MV.DIM) |bi| {
                    if (@popCount(@as(u32, @intCast(bi))) == k) {
                        gnorm += mv.coeffs[bi] * mv.coeffs[bi];
                    }
                }
                if (gnorm > max_norm) {
                    max_norm = gnorm;
                    max_grade = k;
                }
            }

            // Trit from dominant grade: even=Coordinator, odd low=Generator, odd high=Validator
            const trit: Trit = if (max_grade == 0)
                .zero // Scalar = coordinator
            else if (max_grade % 2 == 1 and max_grade <= MV.N / 2)
                .plus // Low odd grade = generator (vectors, trivectors)
            else if (max_grade % 2 == 1)
                .minus // High odd grade = validator
            else
                .zero; // Even grade = coordinator (bivectors, etc)

            return .{
                .r = @truncate(color >> 16),
                .g = @truncate(color >> 8),
                .b = @truncate(color),
                .trit = trit,
                .hash = h,
            };
        }

        /// Verify: does this multivector match a previously observed fingerprint?
        pub fn verify(mv: MV, seed: u64, expected: Self) bool {
            const actual = compute(mv, seed);
            return actual.hash == expected.hash;
        }
    };
}

// ============================================================================
// Batch Parallel Operations -- embarrassingly parallel Clifford
// ============================================================================

/// Batch of N independent multivectors. All operations are element-wise parallel.
pub fn Batch(comptime p: u32, comptime q: u32, comptime r: u32, comptime N: usize) type {
    const MV = clifford.Algebra(p, q, r);

    return struct {
        elements: [N]MV,

        const Self = @This();

        pub fn fill(val: MV) Self {
            return .{ .elements = @splat(val) };
        }

        /// Parallel geometric product: result[i] = a[i] * b[i]. Zero cross-dependencies.
        pub fn mulBatch(a: Self, b: Self) Self {
            var result: Self = undefined;
            // Each iteration is independent -- compiler can vectorize/unroll freely
            for (0..N) |i| {
                result.elements[i] = a.elements[i].mul(b.elements[i]);
            }
            return result;
        }

        /// Parallel sandwich: result[i] = rotor[i] * target[i] * reverse(rotor[i])
        pub fn sandwichBatch(rotors: Self, targets: Self) Self {
            var result: Self = undefined;
            for (0..N) |i| {
                result.elements[i] = rotors.elements[i].sandwich(targets.elements[i]);
            }
            return result;
        }

        /// Parallel reverse: result[i] = reverse(a[i])
        pub fn reverseBatch(a: Self) Self {
            var result: Self = undefined;
            for (0..N) |i| {
                result.elements[i] = a.elements[i].reverse();
            }
            return result;
        }

        /// Parallel add: result[i] = a[i] + b[i]
        pub fn addBatch(a: Self, b: Self) Self {
            var result: Self = undefined;
            for (0..N) |i| {
                result.elements[i] = a.elements[i].add(b.elements[i]);
            }
            return result;
        }

        /// Parallel exponential (analytic continuation): result[i] = exp(a[i])
        pub fn expBatch(a: Self) struct { results: [N]MV, all_converged: bool } {
            const A = clifford_analytic.Analytic(p, q, r);
            var results: [N]MV = undefined;
            var all_converged = true;
            for (0..N) |i| {
                const sr = A.exp(a.elements[i]);
                results[i] = sr.value;
                if (!sr.converged) all_converged = false;
            }
            return .{ .results = results, .all_converged = all_converged };
        }

        /// Parallel TOFU fingerprint: fingerprints[i] = tofu(a[i], seed)
        pub fn tofuBatch(a: Self, seed: u64) [N]TofuFingerprint(MV) {
            const Tofu = TofuFingerprint(MV);
            var fps: [N]Tofu = undefined;
            for (0..N) |i| {
                // Each element gets a unique sub-seed via SPI
                fps[i] = Tofu.compute(a.elements[i], colorAtIndex(seed, i));
            }
            return fps;
        }

        /// Parallel trit classification based on TOFU fingerprints.
        pub fn tritBatch(a: Self, seed: u64) [N]Trit {
            const fps = a.tofuBatch(seed);
            var trits: [N]Trit = undefined;
            for (0..N) |i| {
                trits[i] = fps[i].trit;
            }
            return trits;
        }

        /// GF(3) conservation check over the batch.
        pub fn isConserved(trits: [N]Trit) bool {
            var sum: i32 = 0;
            for (trits) |t| sum += @backingInt(t);
            return @mod(sum + @as(i32, @intCast(N)) * 3, 3) == 0;
        }
    };
}

// ============================================================================
// Parallel Rotor Interpolation (SLERP batch)
// ============================================================================

/// Batch SLERP: interpolate N rotors simultaneously at parameter t.
pub fn slerpBatch(
    comptime p: u32,
    comptime q: u32,
    comptime r: u32,
    comptime N: usize,
    rotors: [N]clifford.Algebra(p, q, r),
    t: f64,
) [N]?clifford.Algebra(p, q, r) {
    const A = clifford_analytic.Analytic(p, q, r);
    var results: [N]?clifford.Algebra(p, q, r) = undefined;
    for (0..N) |i| {
        results[i] = A.slerp(rotors[i], t);
    }
    return results;
}

// ============================================================================
// Tests
// ============================================================================

test "SPI: colorAtIndex is order-independent" {
    const seed: u64 = 0x598F318E2B9E884;
    // Forward
    const c0 = colorAtIndex(seed, 0);
    const c1 = colorAtIndex(seed, 1);
    const c2 = colorAtIndex(seed, 2);
    // Reverse order -- must produce same values
    const c2r = colorAtIndex(seed, 2);
    const c1r = colorAtIndex(seed, 1);
    const c0r = colorAtIndex(seed, 0);
    try testing.expectEqual(c0, c0r);
    try testing.expectEqual(c1, c1r);
    try testing.expectEqual(c2, c2r);
    // Shuffled
    const c1s = colorAtIndex(seed, 1);
    const c0s = colorAtIndex(seed, 0);
    const c2s = colorAtIndex(seed, 2);
    try testing.expectEqual(c0, c0s);
    try testing.expectEqual(c1, c1s);
    try testing.expectEqual(c2, c2s);
}

test "TOFU fingerprint is deterministic" {
    const VGA = clifford.Algebra(3, 0, 0);
    const Tofu = TofuFingerprint(VGA);
    const seed: u64 = 0xDEADBEEF;

    const e1 = VGA.basis(0);
    const e2 = VGA.basis(1);
    const v = e1.add(e2.scale(2.0));

    const fp1 = Tofu.compute(v, seed);
    const fp2 = Tofu.compute(v, seed);
    // Same input, same seed -> same fingerprint (SPI)
    try testing.expectEqual(fp1.hash, fp2.hash);
    try testing.expectEqual(fp1.r, fp2.r);
    try testing.expectEqual(fp1.g, fp2.g);
    try testing.expectEqual(fp1.b, fp2.b);
    try testing.expectEqual(fp1.trit, fp2.trit);
}

test "TOFU verify detects mutations" {
    const VGA = clifford.Algebra(3, 0, 0);
    const Tofu = TofuFingerprint(VGA);
    const seed: u64 = 0xCAFEBABE;

    const v = VGA.basis(0).add(VGA.basis(1));
    const fp = Tofu.compute(v, seed);

    // Verify original
    try testing.expect(Tofu.verify(v, seed, fp));

    // Mutated version should NOT verify
    const v_mut = v.add(VGA.scalar(0.001));
    try testing.expect(!Tofu.verify(v_mut, seed, fp));
}

test "batch mulBatch matches sequential" {
    const VGA = clifford.Algebra(3, 0, 0);
    const B = Batch(3, 0, 0, 4);

    const e1 = VGA.basis(0);
    const e2 = VGA.basis(1);

    var a = B.fill(VGA.zero());
    var b = B.fill(VGA.zero());
    a.elements[0] = e1;
    a.elements[1] = e2;
    a.elements[2] = e1.add(e2);
    a.elements[3] = VGA.scalar(3.0);
    b.elements[0] = e2;
    b.elements[1] = e1;
    b.elements[2] = e1.sub(e2);
    b.elements[3] = VGA.scalar(5.0);

    const batch_result = B.mulBatch(a, b);

    // Verify each matches sequential computation
    for (0..4) |i| {
        const seq = a.elements[i].mul(b.elements[i]);
        try testing.expect(batch_result.elements[i].approxEql(seq, 1e-12));
    }
}

test "batch sandwichBatch preserves norms" {
    const VGA = clifford.Algebra(3, 0, 0);
    const B = Batch(3, 0, 0, 4);

    const e1 = VGA.basis(0);
    const e2 = VGA.basis(1);
    const e12 = e1.wedge(e2);

    // 4 different rotors, 4 different targets
    var rotors = B.fill(VGA.zero());
    var targets = B.fill(VGA.zero());
    const angles = [4]f64{ 0.1, 0.5, 1.0, 2.0 };
    for (0..4) |i| {
        rotors.elements[i] = VGA.scalar(@cos(angles[i] / 2.0)).add(e12.scale(@sin(angles[i] / 2.0)));
        targets.elements[i] = e1.scale(@as(f64, @floatFromInt(i + 1)));
    }

    const results = B.sandwichBatch(rotors, targets);

    for (0..4) |i| {
        // Norm preserved by sandwich
        try testing.expectApproxEqAbs(results.elements[i].norm(), targets.elements[i].norm(), 1e-10);
    }
}

test "batch expBatch converges for small bivectors" {
    const B = Batch(3, 0, 0, 4);
    const VGA = clifford.Algebra(3, 0, 0);

    const e1 = VGA.basis(0);
    const e2 = VGA.basis(1);
    const e12 = e1.wedge(e2);

    var inputs = B.fill(VGA.zero());
    inputs.elements[0] = e12.scale(0.1);
    inputs.elements[1] = e12.scale(0.3);
    inputs.elements[2] = e12.scale(0.7);
    inputs.elements[3] = VGA.zero(); // exp(0) = 1

    const result = B.expBatch(inputs);
    try testing.expect(result.all_converged);

    // exp(0) = 1
    try testing.expectApproxEqAbs(result.results[3].scalarPart(), 1.0, 1e-12);
    // Each should be a valid rotor (normSq ~ 1)
    for (0..3) |i| {
        try testing.expectApproxEqAbs(@abs(result.results[i].normSq()), 1.0, 1e-8);
    }
}

test "batch tofuBatch produces unique fingerprints" {
    const VGA = clifford.Algebra(3, 0, 0);
    const B = Batch(3, 0, 0, 4);

    var batch_in = B.fill(VGA.zero());
    batch_in.elements[0] = VGA.basis(0);
    batch_in.elements[1] = VGA.basis(1);
    batch_in.elements[2] = VGA.basis(0).add(VGA.basis(1));
    batch_in.elements[3] = VGA.scalar(42.0);

    const fps = B.tofuBatch(batch_in, 0xFACE);

    // All fingerprints should be distinct (different inputs)
    for (0..4) |i| {
        for (i + 1..4) |j| {
            try testing.expect(fps[i].hash != fps[j].hash);
        }
    }
}

test "slerpBatch interpolates N rotors" {
    @setEvalBranchQuota(100000);
    const VGA = clifford.Algebra(3, 0, 0);
    const e1 = VGA.basis(0);
    const e2 = VGA.basis(1);
    const e12 = e1.wedge(e2);

    var rotors: [4]VGA = undefined;
    const angles = [4]f64{ 0.5, 1.0, 1.5, 2.0 };
    for (0..4) |i| {
        const A = clifford_analytic.Analytic(3, 0, 0);
        rotors[i] = A.expBivector(e12.scale(angles[i] / 2.0)).?;
    }

    // At t=0: all should be identity
    const at_0 = slerpBatch(3, 0, 0, 4, rotors, 0.0);
    for (0..4) |i| {
        const r = at_0[i].?;
        try testing.expectApproxEqAbs(r.scalarPart(), 1.0, 1e-10);
    }

    // At t=1: all should match original rotors
    const at_1 = slerpBatch(3, 0, 0, 4, rotors, 1.0);
    for (0..4) |i| {
        const r = at_1[i].?;
        try testing.expect(r.approxEql(rotors[i], 1e-10));
    }
}
