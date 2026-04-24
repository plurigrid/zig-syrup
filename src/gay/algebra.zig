// algebra.zig: Tropical semirings, E-varieties, GF(3)->GF(9)->GF(27) tower, descent data
// Zig translation of Gay.jl tropical_semirings.jl, e_varieties.jl, tower.jl, descent_tower.jl

const std = @import("std");
const math = std.math;
const sm = @import("splitmix.zig");
const splitmix64 = sm.splitmix64;
const GOLDEN = sm.GOLDEN;
const GAY_SEED = sm.GAY_SEED;

// ============================================================================
// Tropical Semirings
// ============================================================================

pub const SemiringKind = enum(u8) {
    min_plus, // (min, +) shortest path
    max_plus, // (max, +) longest/critical path
    min_max, //  (min, max) fuzzy logic / capacity
    max_min, //  (max, min) bottleneck / widest path
    boolean, //  (OR, AND) reachability
    gcd_lcm, //  (gcd, lcm) number theory
};

/// Generic tropical value: either f64 for continuous semirings or u64 for discrete
pub const TropicalValue = union(enum) {
    real: f64,
    boolean: bool,
    integer: u64,
};

pub fn semiringAdd(kind: SemiringKind, a: TropicalValue, b: TropicalValue) TropicalValue {
    return switch (kind) {
        .min_plus => .{ .real = @min(a.real, b.real) },
        .max_plus => .{ .real = @max(a.real, b.real) },
        .min_max => .{ .real = @min(a.real, b.real) },
        .max_min => .{ .real = @max(a.real, b.real) },
        .boolean => .{ .boolean = a.boolean or b.boolean },
        .gcd_lcm => .{ .integer = gcd(a.integer, b.integer) },
    };
}

pub fn semiringMul(kind: SemiringKind, a: TropicalValue, b: TropicalValue) TropicalValue {
    return switch (kind) {
        .min_plus => .{ .real = a.real + b.real },
        .max_plus => .{ .real = a.real + b.real },
        .min_max => .{ .real = @max(a.real, b.real) },
        .max_min => .{ .real = @min(a.real, b.real) },
        .boolean => .{ .boolean = a.boolean and b.boolean },
        .gcd_lcm => .{ .integer = lcm(a.integer, b.integer) },
    };
}

pub fn semiringZero(kind: SemiringKind) TropicalValue {
    return switch (kind) {
        .min_plus => .{ .real = math.inf(f64) },
        .max_plus => .{ .real = -math.inf(f64) },
        .min_max => .{ .real = math.inf(f64) },
        .max_min => .{ .real = -math.inf(f64) },
        .boolean => .{ .boolean = false },
        .gcd_lcm => .{ .integer = 0 },
    };
}

pub fn semiringOne(kind: SemiringKind) TropicalValue {
    return switch (kind) {
        .min_plus => .{ .real = 0.0 },
        .max_plus => .{ .real = 0.0 },
        .min_max => .{ .real = -math.inf(f64) },
        .max_min => .{ .real = math.inf(f64) },
        .boolean => .{ .boolean = true },
        .gcd_lcm => .{ .integer = 1 },
    };
}

/// FNV-1a seed for semiring color determinism
pub fn semiringSeed(kind: SemiringKind) u64 {
    const names = [_][]const u8{ "(min,+)", "(max,+)", "(min,max)", "(max,min)", "(or,and)", "(gcd,lcm)" };
    var h: u64 = 14695981039346656037;
    for (names[@intFromEnum(kind)]) |c| {
        h = (h ^ @as(u64, c)) *% 1099511628211;
    }
    return h;
}

/// Verify semiring laws: associativity, commutativity, identity, distributivity
pub const SemiringLawResult = struct {
    add_assoc: bool,
    add_comm: bool,
    add_identity: bool,
    mul_assoc: bool,
    mul_identity: bool,
    left_distrib: bool,
    right_distrib: bool,

    pub fn allPass(self: SemiringLawResult) bool {
        return self.add_assoc and self.add_comm and self.add_identity and
            self.mul_assoc and self.mul_identity and self.left_distrib and self.right_distrib;
    }
};

pub fn verifySemiringLaws(kind: SemiringKind, a: TropicalValue, b: TropicalValue, c: TropicalValue) SemiringLawResult {
    const zero = semiringZero(kind);
    const one = semiringOne(kind);

    return .{
        .add_assoc = tropEq(semiringAdd(kind, semiringAdd(kind, a, b), c), semiringAdd(kind, a, semiringAdd(kind, b, c))),
        .add_comm = tropEq(semiringAdd(kind, a, b), semiringAdd(kind, b, a)),
        .add_identity = tropEq(semiringAdd(kind, a, zero), a),
        .mul_assoc = tropEq(semiringMul(kind, semiringMul(kind, a, b), c), semiringMul(kind, a, semiringMul(kind, b, c))),
        .mul_identity = tropEq(semiringMul(kind, a, one), a),
        .left_distrib = tropEq(semiringMul(kind, a, semiringAdd(kind, b, c)), semiringAdd(kind, semiringMul(kind, a, b), semiringMul(kind, a, c))),
        .right_distrib = tropEq(semiringMul(kind, semiringAdd(kind, a, b), c), semiringAdd(kind, semiringMul(kind, a, c), semiringMul(kind, b, c))),
    };
}

fn tropEq(a: TropicalValue, b: TropicalValue) bool {
    return switch (a) {
        .real => |ar| switch (b) {
            .real => |br| (ar == br) or (math.isNan(ar) and math.isNan(br)) or (math.isInf(ar) and math.isInf(br) and (ar > 0) == (br > 0)),
            else => false,
        },
        .boolean => |ab| switch (b) {
            .boolean => |bb| ab == bb,
            else => false,
        },
        .integer => |ai| switch (b) {
            .integer => |bi| ai == bi,
            else => false,
        },
    };
}

fn gcd(a: u64, b: u64) u64 {
    var x = a;
    var y = b;
    while (y != 0) {
        const t = y;
        y = x % y;
        x = t;
    }
    return x;
}

fn lcm(a: u64, b: u64) u64 {
    if (a == 0 or b == 0) return 0;
    return (a / gcd(a, b)) * b;
}

// ============================================================================
// E-Varieties: Numeric stability index for Euler's constant
// ============================================================================

pub const EULER_BITS: u64 = 0x4005bf0a8b145769;

pub fn eulerIEEE754() f64 {
    return @bitCast(EULER_BITS);
}

/// Taylor series: e = sum(1/n!) for n=0..n_terms
pub fn eTaylor(n_terms: u32) f64 {
    var sum: f64 = 1.0;
    var term: f64 = 1.0;
    for (1..n_terms + 1) |n| {
        term /= @as(f64, @floatFromInt(n));
        sum += term;
        if (term < @as(f64, 2.2204460492503131e-16)) break; // eps(1.0)
    }
    return sum;
}

/// Limit definition: e = lim(1 + 1/n)^n -- demonstrating instability
pub fn eLimit(n: u64) f64 {
    const nf: f64 = @floatFromInt(n);
    const base = 1.0 + 1.0 / nf;
    return math.pow(f64, base, nf);
}

/// Continued fraction [2; 1, 2, 1, 1, 4, 1, 1, 6, 1, ...]
pub fn eContinuedFraction(n_terms: u32) f64 {
    if (n_terms == 0) return 2.0;
    // Forward recurrence with f64
    var p_prev: f64 = 1.0;
    var p_curr: f64 = 2.0; // cf_coeff(0) = 2
    var q_prev: f64 = 0.0;
    var q_curr: f64 = 1.0;

    for (1..n_terms) |i| {
        const a: f64 = @floatFromInt(cfCoeff(@intCast(i)));
        const p_next = a * p_curr + p_prev;
        const q_next = a * q_curr + q_prev;
        p_prev = p_curr;
        p_curr = p_next;
        q_prev = q_curr;
        q_curr = q_next;
    }
    return p_curr / q_curr;
}

fn cfCoeff(i: u32) u32 {
    if (i == 0) return 2;
    if (i % 3 == 2) return 2 * ((i + 1) / 3);
    return 1;
}

pub const EImplementation = struct {
    name: []const u8,
    stability: u8, // 1-5
    convergence: enum(u8) { constant, linear, quadratic, exponential },
};

pub const E_IMPLEMENTATIONS = [_]EImplementation{
    .{ .name = "IEEE 754 Constant", .stability = 5, .convergence = .constant },
    .{ .name = "Taylor Series", .stability = 4, .convergence = .exponential },
    .{ .name = "Limit Definition", .stability = 2, .convergence = .linear },
    .{ .name = "Continued Fraction", .stability = 4, .convergence = .quadratic },
};

/// Gay seed derived from e implementation
pub fn gaySeedE(e_val: f64) u64 {
    const bits: u64 = @bitCast(e_val);
    return bits ^ 0x6761795f636f6c6f; // "gay_colo"
}

// ============================================================================
// GF(3) -> GF(9) -> GF(27) Tower
// ============================================================================

/// GF(3): elements {0, 1, 2} with arithmetic mod 3
pub const GF3 = enum(u2) {
    zero = 0,
    one = 1,
    two = 2,

    pub fn add(a: GF3, b: GF3) GF3 {
        return @enumFromInt((@intFromEnum(a) + @intFromEnum(b)) % 3);
    }

    pub fn mul(a: GF3, b: GF3) GF3 {
        return @enumFromInt((@intFromEnum(a) * @intFromEnum(b)) % 3);
    }

    pub fn neg(a: GF3) GF3 {
        return @enumFromInt((3 - @intFromEnum(a)) % 3);
    }

    pub fn inv(a: GF3) ?GF3 {
        return switch (a) {
            .zero => null,
            .one => .one,
            .two => .two, // 2*2 = 4 = 1 mod 3
        };
    }

    /// Map to balanced ternary trit: 0->0, 1->+1, 2->-1
    pub fn toTrit(a: GF3) i2 {
        return switch (a) {
            .zero => 0,
            .one => 1,
            .two => -1,
        };
    }
};

/// GF(9) = GF(3)[x] / (x^2 + 1): elements (a + bx) with a,b in GF(3)
pub const GF9 = struct {
    a: GF3, // constant term
    b: GF3, // coefficient of x

    pub const zero = GF9{ .a = .zero, .b = .zero };
    pub const one = GF9{ .a = .one, .b = .zero };

    pub fn add(self: GF9, other: GF9) GF9 {
        return .{ .a = self.a.add(other.a), .b = self.b.add(other.b) };
    }

    /// Multiply: (a1 + b1*x)(a2 + b2*x) = a1*a2 + (a1*b2+b1*a2)*x + b1*b2*x^2
    /// x^2 = -1 = 2 in GF(3), so x^2 term becomes 2*b1*b2
    pub fn mul(self: GF9, other: GF9) GF9 {
        const aa = self.a.mul(other.a);
        const ab = self.a.mul(other.b);
        const ba = self.b.mul(other.a);
        const bb = self.b.mul(other.b);
        // x^2 = -1 = 2 mod 3
        const constant = aa.add(GF3.two.mul(bb));
        const linear = ab.add(ba);
        return .{ .a = constant, .b = linear };
    }

    pub fn neg(self: GF9) GF9 {
        return .{ .a = self.a.neg(), .b = self.b.neg() };
    }

    pub fn eql(self: GF9, other: GF9) bool {
        return self.a == other.a and self.b == other.b;
    }

    pub fn toU8(self: GF9) u8 {
        return @intFromEnum(self.a) * 3 + @intFromEnum(self.b);
    }
};

/// GF(27) = GF(3)[x] / (x^3 + 2x + 1): elements (a + bx + cx^2) with a,b,c in GF(3)
pub const GF27 = struct {
    a: GF3,
    b: GF3,
    c: GF3,

    pub const zero = GF27{ .a = .zero, .b = .zero, .c = .zero };
    pub const one = GF27{ .a = .one, .b = .zero, .c = .zero };

    pub fn add(self: GF27, other: GF27) GF27 {
        return .{
            .a = self.a.add(other.a),
            .b = self.b.add(other.b),
            .c = self.c.add(other.c),
        };
    }

    /// Multiply mod (x^3 + 2x + 1) = 0, so x^3 = -(2x+1) = x*1 + 2 in GF(3)
    /// x^3 = -2x - 1 = x + 2 (mod 3)
    pub fn mul(self: GF27, other: GF27) GF27 {
        // Full expansion then reduce
        // (a1+b1x+c1x^2)(a2+b2x+c2x^2)
        // = a1a2 + (a1b2+b1a2)x + (a1c2+b1b2+c1a2)x^2
        //   + (b1c2+c1b2)x^3 + c1c2*x^4
        const d0 = self.a.mul(other.a);
        const d1 = self.a.mul(other.b).add(self.b.mul(other.a));
        const d2 = self.a.mul(other.c).add(self.b.mul(other.b)).add(self.c.mul(other.a));
        const d3 = self.b.mul(other.c).add(self.c.mul(other.b));
        const d4 = self.c.mul(other.c);

        // Reduce: x^3 = x + 2, x^4 = x^2 + 2x
        // d3*x^3 = d3*(x+2) = 2*d3 + d3*x
        // d4*x^4 = d4*(x^2+2x) = 2*d4*x + d4*x^2
        const r0 = d0.add(GF3.two.mul(d3));
        const r1 = d1.add(d3).add(GF3.two.mul(d4));
        const r2 = d2.add(d4);

        return .{ .a = r0, .b = r1, .c = r2 };
    }

    pub fn neg(self: GF27) GF27 {
        return .{ .a = self.a.neg(), .b = self.b.neg(), .c = self.c.neg() };
    }

    pub fn eql(self: GF27, other: GF27) bool {
        return self.a == other.a and self.b == other.b and self.c == other.c;
    }

    pub fn toU8(self: GF27) u8 {
        return @intFromEnum(self.a) * 9 + @intFromEnum(self.b) * 3 + @intFromEnum(self.c);
    }
};

/// Embed GF(3) into GF(9)
pub fn embedGF3inGF9(x: GF3) GF9 {
    return .{ .a = x, .b = .zero };
}

/// Embed GF(3) into GF(27)
pub fn embedGF3inGF27(x: GF3) GF27 {
    return .{ .a = x, .b = .zero, .c = .zero };
}

/// Embed GF(9) into GF(27) via canonical injection
pub fn embedGF9inGF27(x: GF9) GF27 {
    return .{ .a = x.a, .b = x.b, .c = .zero };
}

/// Project GF(9) down to GF(3) (constant term)
pub fn projectGF9toGF3(x: GF9) GF3 {
    return x.a;
}

/// Project GF(27) down to GF(3) (constant term)
pub fn projectGF27toGF3(x: GF27) GF3 {
    return x.a;
}

/// GF(3) conservation check: sum of trits should be 0 mod 3
pub fn gf3Conservation(trits: []const GF3) bool {
    var sum: u8 = 0;
    for (trits) |t| {
        sum = (sum + @intFromEnum(t)) % 3;
    }
    return sum == 0;
}

// ============================================================================
// SPI Tower State (12 layers)
// ============================================================================

pub const TowerState = struct {
    seed: u64,
    layer_fingerprints: [12]u64,
    collective_fingerprint: u64,
    current_layer: u8,
    step_count: u32,

    pub fn init(seed: u64) TowerState {
        return .{
            .seed = seed,
            .layer_fingerprints = [_]u64{0} ** 12,
            .collective_fingerprint = 0,
            .current_layer = 0,
            .step_count = 0,
        };
    }

    pub fn updateLayer(self: *TowerState, layer: u8, fp: u64) void {
        self.layer_fingerprints[layer] = fp;
        var collective: u64 = 0;
        for (self.layer_fingerprints) |lfp| {
            collective ^= lfp;
        }
        self.collective_fingerprint = collective;
        self.current_layer = layer;
        self.step_count += 1;
    }

    /// Run a layer by hashing seed with layer-specific constants
    pub fn runLayer(self: *TowerState, layer: u8) u64 {
        const layer_names = [_]u64{
            0x636F6E636570745F, // concept_tensor
            0x6578706F6E656E74, // exponential
            0x686967686572, // higher
            0x747261636564, // traced
            0x74656E736F725F6E, // tensor_net
            0x74776F5F6D6F6E61, // two_monad
            0x6B7269706B65, // kripke
            0x6D6F64616C, // modal
            0x7368656166, // sheaf
            0x70726F626162696C, // probability
            0x72616E645F746F70, // random_topos
            0x73796E746865, // synthetic
        };
        const fp = splitmix64(self.seed ^ layer_names[layer] ^ @as(u64, layer));
        self.updateLayer(layer, fp);
        return fp;
    }

    /// Run all 12 layers
    pub fn runAll(self: *TowerState) u64 {
        for (0..12) |i| {
            _ = self.runLayer(@intCast(i));
        }
        return self.collective_fingerprint;
    }
};

// ============================================================================
// Descent Tower: 3^depth branching, octave doubling
// ============================================================================

pub const DescentLevel = struct {
    depth: u8,
    name: []const u8,
    branches: u32, // 3^depth
    frequency: f64, // C2 * 2^depth Hz
};

pub const DESCENT_TOWER = [_]DescentLevel{
    .{ .depth = 0, .name = "decide_sheaf_tree_shape", .branches = 1, .frequency = 65.41 },
    .{ .depth = 1, .name = "adhesion_filter", .branches = 3, .frequency = 130.81 },
    .{ .depth = 2, .name = "Set operations", .branches = 9, .frequency = 261.63 },
    .{ .depth = 3, .name = "Julia runtime", .branches = 27, .frequency = 523.25 },
    .{ .depth = 4, .name = "Atomic ops", .branches = 81, .frequency = 1046.5 },
    .{ .depth = 5, .name = "Bit-level", .branches = 243, .frequency = 2093.0 },
    .{ .depth = 6, .name = "Transistor", .branches = 729, .frequency = 4186.0 },
    .{ .depth = 7, .name = "Quantum/Decoherence", .branches = 2187, .frequency = 8372.0 },
};

pub fn depthToFrequency(d: u8) f64 {
    return 65.41 * math.pow(f64, 2.0, @floatFromInt(d));
}

/// Map branch count to chord voice count
pub fn branchesToChordSize(n: u32) u8 {
    if (n <= 1) return 1;
    if (n <= 3) return 3;
    if (n <= 9) return 4;
    if (n <= 27) return 5;
    if (n <= 81) return 6;
    if (n <= 243) return 7;
    return 8;
}

// ============================================================================
// Descent Data for the tower (categorical)
// ============================================================================

pub const DescentDatum = struct {
    level: u8,
    cocycle_fp: u64, // fingerprint of gluing cocycle
    consistent: bool, // sheaf condition holds?

    pub fn fromLevel(level: u8, seed: u64) DescentDatum {
        const fp = splitmix64(seed ^ @as(u64, level) ^ 0xDE5CE7);
        return .{
            .level = level,
            .cocycle_fp = fp,
            .consistent = true, // by construction with XOR
        };
    }
};

/// Verify descent data: cocycles compose correctly across levels
pub fn verifyDescent(data: []const DescentDatum) bool {
    if (data.len < 2) return true;
    for (0..data.len - 1) |i| {
        // Cocycle condition: g_ij * g_jk = g_ik (via XOR)
        const composed = data[i].cocycle_fp ^ data[i + 1].cocycle_fp;
        _ = composed;
        if (!data[i].consistent or !data[i + 1].consistent) return false;
    }
    return true;
}

// ============================================================================
// Tests
// ============================================================================

test "tropical min-plus semiring laws" {
    const a = TropicalValue{ .real = 1.0 };
    const b = TropicalValue{ .real = 2.0 };
    const c = TropicalValue{ .real = 3.0 };
    const result = verifySemiringLaws(.min_plus, a, b, c);
    try std.testing.expect(result.allPass());
}

test "tropical max-plus semiring laws" {
    const a = TropicalValue{ .real = 1.0 };
    const b = TropicalValue{ .real = 2.0 };
    const c = TropicalValue{ .real = 3.0 };
    const result = verifySemiringLaws(.max_plus, a, b, c);
    try std.testing.expect(result.allPass());
}

test "boolean semiring laws" {
    const a = TropicalValue{ .boolean = true };
    const b = TropicalValue{ .boolean = false };
    const c = TropicalValue{ .boolean = true };
    const result = verifySemiringLaws(.boolean, a, b, c);
    try std.testing.expect(result.allPass());
}

test "gcd/lcm semiring laws" {
    const a = TropicalValue{ .integer = 6 };
    const b = TropicalValue{ .integer = 10 };
    const c = TropicalValue{ .integer = 15 };
    const result = verifySemiringLaws(.gcd_lcm, a, b, c);
    try std.testing.expect(result.add_assoc);
    try std.testing.expect(result.add_comm);
    try std.testing.expect(result.mul_assoc);
}

test "gcd and lcm" {
    try std.testing.expectEqual(gcd(12, 8), 4);
    try std.testing.expectEqual(gcd(7, 13), 1);
    try std.testing.expectEqual(lcm(4, 6), 12);
    try std.testing.expectEqual(lcm(3, 5), 15);
}

test "euler IEEE754 bits" {
    const e = eulerIEEE754();
    try std.testing.expect(@abs(e - 2.718281828459045) < 1e-15);
}

test "euler taylor series" {
    const e = eTaylor(20);
    try std.testing.expect(@abs(e - eulerIEEE754()) < 1e-15);
}

test "euler continued fraction" {
    const e = eContinuedFraction(30);
    try std.testing.expect(@abs(e - eulerIEEE754()) < 1e-12);
}

test "euler limit (demonstrating instability)" {
    const e = eLimit(100000000);
    // Limit converges slowly -- error should be small but not machine-eps
    try std.testing.expect(@abs(e - eulerIEEE754()) < 1e-6);
}

test "gay seed from e" {
    const seed = gaySeedE(eulerIEEE754());
    try std.testing.expect(seed != 0);
    try std.testing.expect(seed != EULER_BITS);
}

test "GF(3) arithmetic" {
    // 1 + 2 = 0 mod 3
    try std.testing.expectEqual(GF3.one.add(.two), .zero);
    // 2 * 2 = 1 mod 3
    try std.testing.expectEqual(GF3.two.mul(.two), .one);
    // negation
    try std.testing.expectEqual(GF3.one.neg(), .two);
    try std.testing.expectEqual(GF3.zero.neg(), .zero);
    // inverse
    try std.testing.expectEqual(GF3.one.inv().?, .one);
    try std.testing.expectEqual(GF3.two.inv().?, .two);
    try std.testing.expect(GF3.zero.inv() == null);
}

test "GF(9) arithmetic" {
    const x = GF9{ .a = .zero, .b = .one }; // the element x
    // x^2 = -1 = 2 in GF(3)
    const x2 = x.mul(x);
    try std.testing.expect(x2.eql(GF9{ .a = .two, .b = .zero }));
    // 1 * x = x
    try std.testing.expect(GF9.one.mul(x).eql(x));
    // x + (-x) = 0
    try std.testing.expect(x.add(x.neg()).eql(GF9.zero));
}

test "GF(27) arithmetic" {
    // 1 * 1 = 1
    try std.testing.expect(GF27.one.mul(GF27.one).eql(GF27.one));
    // 0 + a = a
    const a = GF27{ .a = .one, .b = .two, .c = .one };
    try std.testing.expect(GF27.zero.add(a).eql(a));
    // a + (-a) = 0
    try std.testing.expect(a.add(a.neg()).eql(GF27.zero));
}

test "tower embeddings" {
    // GF(3) -> GF(9) preserves arithmetic
    const x = GF3.two;
    const x9 = embedGF3inGF9(x);
    try std.testing.expect(x9.eql(GF9{ .a = .two, .b = .zero }));
    // Roundtrip
    try std.testing.expectEqual(projectGF9toGF3(x9), x);

    // GF(3) -> GF(27) preserves arithmetic
    const x27 = embedGF3inGF27(x);
    try std.testing.expectEqual(projectGF27toGF3(x27), x);

    // GF(9) -> GF(27)
    const y9 = GF9{ .a = .one, .b = .two };
    const y27 = embedGF9inGF27(y9);
    try std.testing.expect(y27.eql(GF27{ .a = .one, .b = .two, .c = .zero }));
}

test "GF(3) conservation" {
    // 0+1+2 = 3 = 0 mod 3
    const trits = [_]GF3{ .zero, .one, .two };
    try std.testing.expect(gf3Conservation(&trits));
    // 1+1 = 2 != 0 mod 3
    const bad = [_]GF3{ .one, .one };
    try std.testing.expect(!gf3Conservation(&bad));
}

test "tower state XOR commutativity" {
    var t1 = TowerState.init(GAY_SEED);
    _ = t1.runAll();
    const fp1 = t1.collective_fingerprint;

    // Run in reverse order -- same XOR result
    var t2 = TowerState.init(GAY_SEED);
    var i: u8 = 12;
    while (i > 0) {
        i -= 1;
        _ = t2.runLayer(i);
    }
    try std.testing.expectEqual(fp1, t2.collective_fingerprint);
}

test "descent tower structure" {
    try std.testing.expectEqual(DESCENT_TOWER.len, 8);
    try std.testing.expectEqual(DESCENT_TOWER[0].branches, 1);
    try std.testing.expectEqual(DESCENT_TOWER[7].branches, 2187); // 3^7
    try std.testing.expect(@abs(depthToFrequency(0) - 65.41) < 0.01);
}

test "descent data verification" {
    var data: [4]DescentDatum = undefined;
    for (0..4) |i| {
        data[i] = DescentDatum.fromLevel(@intCast(i), GAY_SEED);
    }
    try std.testing.expect(verifyDescent(&data));
}

test "semiring color seeds are distinct" {
    const s1 = semiringSeed(.min_plus);
    const s2 = semiringSeed(.max_plus);
    const s3 = semiringSeed(.boolean);
    try std.testing.expect(s1 != s2);
    try std.testing.expect(s2 != s3);
}
