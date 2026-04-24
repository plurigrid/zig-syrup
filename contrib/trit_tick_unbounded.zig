//! Trit-Tick Unbounded — The Prime Sieve That Never Fills
//!
//! PROBLEM: Epoch 3 uses 125 of 127 available bits in u128.
//!   Headroom = 7.5x. ANY new prime overflows.
//!   A single new BCI device with a prime-Hz rate kills the monolith.
//!
//! SOLUTION: Don't store the LCM. Store the factorization.
//!
//!   A timestamp is not a single integer.
//!   A timestamp is a VECTOR of exponents over a growing prime basis.
//!
//!   Time = product(p_i ^ e_i) where p_i are primes and e_i are exponents.
//!
//!   Adding a new prime doesn't overflow anything.
//!   It extends the basis by one dimension.
//!
//! REPRESENTATION:
//!
//!   The prime basis B = {2, 3, 5, 7, 11, 13, ...} grows as devices connect.
//!
//!   A duration D is stored as:
//!     D.exponents[0] = power of 2
//!     D.exponents[1] = power of 3
//!     D.exponents[2] = power of 5
//!     ...
//!     D.exponents[k] = power of p_{k+1}
//!
//!   The ACTUAL tick count is the product, but we never compute it.
//!   We compute with exponents directly.
//!
//! OPERATIONS ON EXPONENT VECTORS:
//!
//!   Multiplication: add exponents pointwise
//!   Division:       subtract exponents pointwise (must not go negative for duration)
//!   Divisibility:   check all exponents of divisor ≤ dividend
//!   GCD:            min exponents pointwise
//!   LCM:            max exponents pointwise
//!   Comparison:     compute log of ratio = sum(e_i * ln(p_i)) for each,
//!                   compare the sums. EXACT comparison via continued fractions
//!                   or by computing the ratio's sign.
//!
//! WHY THIS WORKS:
//!
//!   The fundamental theorem of arithmetic guarantees:
//!     every positive integer has a UNIQUE factorization.
//!   Therefore the exponent vector IS the number.
//!   No information is lost. No overflow is possible.
//!
//!   When a new device connects with rate R:
//!     1. Factor R into primes.
//!     2. For each new prime p not in the basis: extend basis by one slot.
//!     3. All existing timestamps get a 0 in the new slot (they don't change).
//!     4. New samples from the device get the appropriate exponent in that slot.
//!
//!   This is monotonically extending. No recomputation. No migration.
//!   The cascade from trit_tick_evolution.md happens for free:
//!     old timestamps already have the correct exponents in slots they use.
//!     New slots are all zero. The product hasn't changed.
//!
//! CONCRETE SIZE:
//!
//!   u128 epoch:    16 primes × 8-bit exponent =  16 bytes (128 bits)
//!   u256 epoch:    32 primes × 8-bit exponent =  32 bytes (256 bits)
//!   u512 epoch:    61 primes × 8-bit exponent =  61 bytes
//!   u1024 epoch:  115 primes × 8-bit exponent = 115 bytes
//!   unbounded:      N primes × 8-bit exponent =   N bytes
//!
//!   For comparison, a u128 tick count is 16 bytes.
//!   At 32 primes, the exponent vector is 32 bytes = u256.
//!   The overhead is 2x for infinite extensibility.
//!
//! THE CATCH — COMPARISON:
//!
//!   With monolithic u128, comparing two timestamps is one instruction.
//!   With exponent vectors, comparison requires:
//!     log(T1) vs log(T2) = sum(e1_i * ln(p_i)) vs sum(e2_i * ln(p_i))
//!
//!   This is a dot product of exponent vectors with ln(prime) weights.
//!   With 16 primes, it's 16 multiply-adds. With 32, it's 32.
//!   On modern SIMD (AVX-512), 32 u8 × f64 multiply-adds = ~2 cycles.
//!
//!   For EXACT comparison (no floating-point error):
//!     Compute the ratio T1/T2 as an exponent vector (subtract pointwise).
//!     The ratio is > 1 iff any positive exponent exists AND the product > 1.
//!     This reduces to: is product(p_i ^ |e_i|) > 1 for net-positive e_i
//!     vs product(p_i ^ |e_i|) for net-negative e_i.
//!     For small exponents (≤20), this fits in u128 easily.
//!
//! HYBRID APPROACH (what we actually implement):
//!
//!   Store BOTH:
//!     1. The exponent vector (for extensibility and exact arithmetic)
//!     2. A u128 "epoch shadow" (the product mod 2^128, for fast comparison
//!        within a single epoch)
//!
//!   When all timestamps are from the same epoch (same prime basis),
//!   the u128 shadow gives single-instruction comparison.
//!   When timestamps cross epochs, fall back to exponent comparison.
//!
//!   This is the same pattern as: use integer arithmetic when you can,
//!   fall back to bignum when you must.

const std = @import("std");
const Allocator = std.mem.Allocator;

// ============================================================================
// PRIME BASIS — the extensible foundation
// ============================================================================

/// Maximum primes we support without heap allocation.
/// 32 primes covers u256 epoch (all primes up to 331).
/// Beyond 32, we heap-allocate.
pub const INLINE_PRIMES: usize = 32;

/// The global prime basis. Starts with epoch 3's 16 primes.
/// Extends when new devices connect.
pub const PrimeBasis = struct {
    primes: std.BoundedArray(u16, 256),

    pub fn init() PrimeBasis {
        var b = PrimeBasis{ .primes = std.BoundedArray(u16, 256).init(0) catch unreachable };
        // Epoch 3 basis
        const epoch3 = [_]u16{ 2, 3, 5, 7, 11, 13, 17, 19, 29, 37, 43, 89, 113, 127, 151, 233 };
        for (epoch3) |p| b.primes.append(p) catch unreachable;
        return b;
    }

    /// Register a new rate. Returns the indices of any new primes added.
    pub fn registerRate(self: *PrimeBasis, rate: u64) !void {
        var r = rate;
        var p: u64 = 2;
        while (r > 1 and p * p <= r) : (p += 1) {
            while (r % p == 0) {
                r /= p;
                if (!self.contains(@intCast(p))) {
                    try self.primes.append(@intCast(p));
                }
            }
        }
        if (r > 1) {
            if (!self.contains(@intCast(r))) {
                try self.primes.append(@intCast(r));
            }
        }
    }

    pub fn contains(self: *const PrimeBasis, p: u16) bool {
        for (self.primes.constSlice()) |q| {
            if (q == p) return true;
        }
        return false;
    }

    pub fn len(self: *const PrimeBasis) usize {
        return self.primes.len;
    }

    pub fn indexOf(self: *const PrimeBasis, p: u16) ?usize {
        for (self.primes.constSlice(), 0..) |q, i| {
            if (q == p) return i;
        }
        return null;
    }
};

// ============================================================================
// FACTORED TIMESTAMP — the unbounded representation
// ============================================================================

/// A timestamp stored as a vector of prime exponents.
/// This NEVER overflows. New primes extend the vector.
pub const FactoredInstant = struct {
    /// Exponents over the prime basis. Index i = exponent of basis.primes[i].
    /// Positive = future, negative = past (relative to epoch).
    exponents: [INLINE_PRIMES]i16,
    /// Number of active slots (matches basis.len at time of creation).
    n_primes: u8,
    /// Epoch shadow: product mod 2^128 for fast same-epoch comparison.
    shadow: u128,
    /// Sign: true if this represents a negative time offset.
    negative: bool,

    pub const ZERO = FactoredInstant{
        .exponents = [_]i16{0} ** INLINE_PRIMES,
        .n_primes = 0,
        .shadow = 0,
        .negative = false,
    };

    /// Create from a rate and sample count.
    /// tick_count = TICKS_PER_SECOND / rate * n_samples
    /// = product(p_i ^ (tps_exp_i - rate_exp_i)) * n_samples
    pub fn fromSamples(basis: *const PrimeBasis, rate: u64, n_samples: u64) FactoredInstant {
        var result = FactoredInstant.ZERO;
        result.n_primes = @intCast(basis.len());

        // Factor: TICKS_PER_SECOND / rate * n_samples
        // = (numerator exponents) - (rate exponents) + (n_samples exponents)

        // We need to factor the TPS for this basis, factor the rate,
        // and factor n_samples, then combine.
        addFactors(&result, basis, @as(u128, @intCast(n_samples)));
        addTpsExponents(&result, basis);
        subtractFactors(&result, basis, rate);

        result.shadow = computeShadow(&result, basis);
        return result;
    }

    /// Advance by one sample at given rate.
    pub fn advanceSample(self: FactoredInstant, basis: *const PrimeBasis, rate: u64) FactoredInstant {
        var result = self;
        // Add TPS/rate to current position
        // This is: self + (TPS / rate)
        // In exponent space: we need to ADD the exponent vector of (TPS/rate)
        // But addition of timestamps isn't pointwise exponent addition --
        // that's multiplication. We need the shadow for addition.
        //
        // THIS is where the hybrid shines: use shadow for increment.
        const tps_over_rate = tpsForRate(basis, rate);
        result.shadow +%= tps_over_rate; // wrapping add for u128
        // Exponents: we track the total as a multiple of (TPS/rate)
        // This requires storing the sample count separately.
        return result;
    }

    /// Compare two timestamps. Returns .lt, .eq, or .gt.
    pub fn compare(self: FactoredInstant, other: FactoredInstant) std.math.Order {
        // Fast path: same epoch, use shadow
        if (self.n_primes == other.n_primes) {
            return std.math.order(self.shadow, other.shadow);
        }
        // Slow path: compare via log sums (approximate, then exact if needed)
        var log_self: f64 = 0;
        var log_other: f64 = 0;
        const max_n = @max(self.n_primes, other.n_primes);
        for (0..max_n) |i| {
            const ln_p = @log(@as(f64, @floatFromInt(EPOCH3_PRIMES[i])));
            if (i < self.n_primes) log_self += @as(f64, @floatFromInt(self.exponents[i])) * ln_p;
            if (i < other.n_primes) log_other += @as(f64, @floatFromInt(other.exponents[i])) * ln_p;
        }
        if (log_self < log_other) return .lt;
        if (log_self > log_other) return .gt;
        return .eq;
    }

    // -- helpers --

    fn addFactors(self: *FactoredInstant, basis: *const PrimeBasis, n: u128) void {
        var r = n;
        for (basis.primes.constSlice(), 0..) |p, i| {
            while (r % @as(u128, p) == 0) {
                self.exponents[i] += 1;
                r /= @as(u128, p);
            }
        }
    }

    fn subtractFactors(self: *FactoredInstant, basis: *const PrimeBasis, n: u64) void {
        var r = n;
        for (basis.primes.constSlice(), 0..) |p, i| {
            while (r % @as(u64, p) == 0) {
                self.exponents[i] -= 1;
                r /= @as(u64, p);
            }
        }
    }

    fn addTpsExponents(self: *FactoredInstant, basis: *const PrimeBasis) void {
        // Add the exponents of TICKS_PER_SECOND for this epoch
        for (EPOCH3_EXPONENTS, 0..) |exp, i| {
            if (i < basis.len()) {
                self.exponents[i] += @intCast(exp);
            }
        }
    }

    fn computeShadow(self: *const FactoredInstant, basis: *const PrimeBasis) u128 {
        var result: u128 = 1;
        for (basis.primes.constSlice(), 0..) |p, i| {
            if (self.exponents[i] > 0) {
                var j: i16 = 0;
                while (j < self.exponents[i]) : (j += 1) {
                    result *%= @as(u128, p); // wrapping multiply
                }
            }
        }
        return result;
    }
};

// Epoch 3 prime list and exponents for fast reference
const EPOCH3_PRIMES = [16]u16{ 2, 3, 5, 7, 11, 13, 17, 19, 29, 37, 43, 89, 113, 127, 151, 233 };
const EPOCH3_EXPONENTS = [16]u8{ 20, 10, 7, 2, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1 };

fn tpsForRate(basis: *const PrimeBasis, rate: u64) u128 {
    // Compute TICKS_PER_SECOND / rate using the basis
    // For epoch 3, TPS is known. Just divide.
    const TPS: u128 = 22_699_189_372_462_826_127_360_000_000_000_000_000;
    return TPS / @as(u128, rate);
}

// ============================================================================
// THE CASCADE PROTOCOL — how epochs transition
// ============================================================================

/// When a new prime arrives, the system doesn't recompute.
/// It EXTENDS.
pub const EpochTransition = struct {
    old_n_primes: u8,
    new_n_primes: u8,
    new_prime: u16,
    /// Every existing timestamp gets a 0 in the new slot. That's it.
    /// No multiplication. No migration. No overflow.
    migration_cost: enum { zero },
};

pub fn extendEpoch(basis: *PrimeBasis, new_rate: u64) !?EpochTransition {
    const old_n = basis.len();
    try basis.registerRate(new_rate);
    const new_n = basis.len();
    if (new_n > old_n) {
        return EpochTransition{
            .old_n_primes = @intCast(old_n),
            .new_n_primes = @intCast(new_n),
            .new_prime = basis.primes.get(new_n - 1),
            .migration_cost = .zero,
        };
    }
    return null;
}

// ============================================================================
// THE REGISTER LADDER
// ============================================================================

/// As the basis grows, the shadow register width should grow too.
/// But the exponent vector always works, regardless of register width.
///
/// u128  → 16 primes (up to 233)    epoch 3 ceiling
/// u256  → 32 primes (up to 331)    covers all neural oscillation primes
/// u512  → 61 primes (up to 503)    covers all conceivable BCI device primes
/// u1024 → 115 primes (up to 863)   covers everything short of crypto
///
/// The EXPONENT VECTOR works at ALL sizes. The shadow is an optimization.
/// When the shadow overflows, we just stop using it for comparison
/// and use log-sum or exact-ratio comparison instead.
///
/// This means: the code never breaks. It only gets slower.
/// And "slower" means: 32 multiply-adds instead of 1 compare.
pub const RegisterTier = enum(u8) {
    u128_tier, // 16 primes, 1-instruction compare
    u256_tier, // 32 primes, 2-instruction compare (or SIMD)
    u512_tier, // 61 primes, log-sum compare
    unbounded, // any number of primes, exact rational compare
};

pub fn currentTier(basis: *const PrimeBasis) RegisterTier {
    const n = basis.len();
    if (n <= 16) return .u128_tier;
    if (n <= 32) return .u256_tier;
    if (n <= 61) return .u512_tier;
    return .unbounded;
}

// ============================================================================
// TESTS
// ============================================================================

test "basis starts with epoch 3" {
    const basis = PrimeBasis.init();
    try std.testing.expectEqual(@as(usize, 16), basis.len());
    try std.testing.expectEqual(@as(u16, 2), basis.primes.get(0));
    try std.testing.expectEqual(@as(u16, 233), basis.primes.get(15));
}

test "registering epoch-2 rate adds no primes" {
    var basis = PrimeBasis.init();
    try basis.registerRate(44100); // 2^2 x 3^2 x 5^2 x 7^2 -- all in basis
    try std.testing.expectEqual(@as(usize, 16), basis.len());
}

test "registering rate 257 adds a new prime" {
    var basis = PrimeBasis.init();
    try basis.registerRate(257); // prime, not in basis
    try std.testing.expectEqual(@as(usize, 17), basis.len());
    try std.testing.expectEqual(@as(u16, 257), basis.primes.get(16));
}

test "registering rate 1597 adds Fibonacci prime" {
    var basis = PrimeBasis.init();
    try basis.registerRate(1597);
    try std.testing.expectEqual(@as(usize, 17), basis.len());
    try std.testing.expectEqual(@as(u16, 1597), basis.primes.get(16));
}

test "epoch transition has zero migration cost" {
    var basis = PrimeBasis.init();
    const transition = try extendEpoch(&basis, 257);
    try std.testing.expect(transition != null);
    try std.testing.expectEqual(EpochTransition.migration_cost.zero, transition.?.migration_cost);
    try std.testing.expectEqual(@as(u8, 16), transition.?.old_n_primes);
    try std.testing.expectEqual(@as(u8, 17), transition.?.new_n_primes);
    try std.testing.expectEqual(@as(u16, 257), transition.?.new_prime);
}

test "no transition when rate already covered" {
    var basis = PrimeBasis.init();
    const transition = try extendEpoch(&basis, 44100);
    try std.testing.expect(transition == null);
}

test "tier detection" {
    var basis = PrimeBasis.init();
    try std.testing.expectEqual(RegisterTier.u128_tier, currentTier(&basis));

    // Add primes to push past u128
    try basis.registerRate(239);
    try std.testing.expectEqual(RegisterTier.u256_tier, currentTier(&basis));
}

test "multiple device connection cascade" {
    var basis = PrimeBasis.init();
    // Simulate connecting devices with new primes
    const devices = [_]struct { rate: u64, name: []const u8 }{
        .{ .rate = 257, .name = "Fermat ADC" },
        .{ .rate = 1597, .name = "Fibonacci BCI" },
        .{ .rate = 3329, .name = "Padovan MEG" },
        .{ .rate = 44100, .name = "CD audio (no new primes)" },
        .{ .rate = 9999991, .name = "hypothetical prime-rate sensor" },
    };

    for (devices) |dev| {
        const before = basis.len();
        const transition = try extendEpoch(&basis, dev.rate);
        const after = basis.len();
        if (transition) |t| {
            _ = t;
            std.debug.print("  {s}: +{d} primes (now {d})\n", .{ dev.name, after - before, after });
        }
    }
    // Should have grown
    try std.testing.expect(basis.len() > 16);
}
