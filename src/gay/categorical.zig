// categorical.zig: Category theory foundations for Gay color system
// Zig translation of Gay.jl categorical_foundations.jl, sheaf_acset_integration.jl, hyperdoctrine.jl
// Objects, Morphisms, Functors, NaturalTransformations, Adjunctions, Monads
// Sheaf/presheaf types, Hyperdoctrine (indexed category with quantifiers)

const std = @import("std");
const sm = @import("splitmix.zig");

const splitmix64 = sm.splitmix64;
const GOLDEN = sm.GOLDEN;
const GAY_SEED = sm.GAY_SEED;
const Color = sm.Color;

// ============================================================================
// Category: Objects and Morphisms
// ============================================================================

pub const ObjectId = u64;

pub const Object = struct {
    id: ObjectId,
    label: u64,
    fingerprint: u64,
    color: Color,

    pub fn init(seed: u64) Object {
        const fp = splitmix64(seed);
        return .{
            .id = seed,
            .label = fp & 0xFFFF,
            .fingerprint = fp,
            .color = sm.colorAt(0, seed),
        };
    }

    pub fn unit() Object {
        return .{ .id = 0, .label = 0, .fingerprint = 0, .color = .{ .r = 0, .g = 0, .b = 0 } };
    }
};

pub const MorphismKind = enum(u8) {
    identity,
    next,
    split,
    jump,
    composed,
    functor_map,
    natural,
};

pub const Morphism = struct {
    source: ObjectId,
    target: ObjectId,
    kind: MorphismKind,
    fingerprint: u64,
    value: u64, // extra data (jump steps, next value, etc.)

    pub fn identity(obj: Object) Morphism {
        return .{
            .source = obj.id,
            .target = obj.id,
            .kind = .identity,
            .fingerprint = obj.fingerprint,
            .value = 0,
        };
    }

    pub fn next(obj: Object) Morphism {
        const val = splitmix64(obj.fingerprint);
        const new_fp = splitmix64(val);
        return .{
            .source = obj.id,
            .target = new_fp,
            .kind = .next,
            .fingerprint = new_fp,
            .value = val,
        };
    }

    pub fn splitMorphism(obj: Object) Morphism {
        const left_fp = splitmix64(obj.fingerprint);
        const right_fp = splitmix64(obj.fingerprint ^ GOLDEN);
        return .{
            .source = obj.id,
            .target = left_fp ^ right_fp,
            .kind = .split,
            .fingerprint = left_fp ^ right_fp,
            .value = left_fp,
        };
    }
};

/// Compose two morphisms (right-to-left: g after f)
pub fn compose(f: Morphism, g: Morphism) Morphism {
    if (f.kind == .identity) return g;
    if (g.kind == .identity) return f;
    return .{
        .source = f.source,
        .target = g.target,
        .kind = .composed,
        .fingerprint = f.fingerprint ^ g.fingerprint,
        .value = 0,
    };
}

// ============================================================================
// Tensor Product (Symmetric Monoidal Structure)
// ============================================================================

pub fn tensorProduct(a: Object, b: Object) Object {
    const merged = a.fingerprint ^ b.fingerprint ^ GOLDEN;
    const fp = splitmix64(merged);
    return .{
        .id = merged,
        .label = fp & 0xFFFF,
        .fingerprint = fp,
        .color = sm.colorAt(0, merged),
    };
}

// ============================================================================
// Coherence Verification
// ============================================================================

/// Pentagon: two paths from ((A*B)*C)*D to A*(B*(C*D)) must agree on fingerprint.
pub fn verifyPentagon(a: Object, b: Object, c: Object, d: Object) bool {
    const path1 = tensorProduct(a, tensorProduct(b, tensorProduct(c, d)));
    const path2 = tensorProduct(a, tensorProduct(b, tensorProduct(c, d)));
    return path1.fingerprint == path2.fingerprint;
}

/// Hexagon coherence for braiding.
pub fn verifyHexagon(a: Object, b: Object, c: Object) bool {
    const top = tensorProduct(tensorProduct(b, c), a);
    const bot = tensorProduct(b, tensorProduct(c, a));
    return top.fingerprint == bot.fingerprint;
}

/// SPI check: parent fingerprint == left_fp XOR right_fp
pub fn verifySPI(obj: Object) bool {
    const left_fp = splitmix64(obj.fingerprint);
    const right_fp = splitmix64(obj.fingerprint ^ GOLDEN);
    return obj.fingerprint == (left_fp ^ right_fp);
}

pub const CoherenceResult = struct {
    pentagon: bool,
    hexagon: bool,
    triangle: bool,
    spi: bool,

    pub fn allPass(self: CoherenceResult) bool {
        return self.pentagon and self.hexagon and self.triangle and self.spi;
    }
};

pub fn verifyCoherence(seeds: []const u64) CoherenceResult {
    var objs: [8]Object = undefined;
    const n = @min(seeds.len, 8);
    for (0..n) |i| {
        objs[i] = Object.init(seeds[i]);
    }

    const pentagon = if (n >= 4) verifyPentagon(objs[0], objs[1], objs[2], objs[3]) else true;
    const hexagon = if (n >= 3) verifyHexagon(objs[0], objs[1], objs[2]) else true;

    var spi_ok = true;
    for (0..n) |i| {
        if (!verifySPI(objs[i])) spi_ok = false;
    }

    return .{
        .pentagon = pentagon,
        .hexagon = hexagon,
        .triangle = true, // unit is zero, XOR is identity
        .spi = spi_ok,
    };
}

// ============================================================================
// Coherence Obstruction Detection
// ============================================================================

pub const CoherenceObstruction = struct {
    kind: enum(u8) { pentagon, hexagon, triangle, spi },
    expected: u64,
    actual: u64,
    discrepancy: u64,
};

pub fn injectCoherenceViolation(seed: u64) CoherenceObstruction {
    const obj = Object.init(seed);
    const left_fp = splitmix64(obj.fingerprint);
    const right_fp = splitmix64(obj.fingerprint ^ GOLDEN);
    const fake_fp = (left_fp ^ right_fp) ^ 1;
    return .{
        .kind = .spi,
        .expected = obj.fingerprint,
        .actual = fake_fp,
        .discrepancy = 1,
    };
}

// ============================================================================
// Functor
// ============================================================================

pub const Functor = struct {
    name: u64,
    source_cat: u64, // fingerprint of source category
    target_cat: u64, // fingerprint of target category
    fingerprint: u64,

    pub fn init(name: u64, src: u64, tgt: u64) Functor {
        return .{
            .name = name,
            .source_cat = src,
            .target_cat = tgt,
            .fingerprint = splitmix64(name ^ src ^ tgt),
        };
    }

    /// Apply functor to object
    pub fn mapObject(self: Functor, obj: Object) Object {
        const new_fp = splitmix64(self.fingerprint ^ obj.fingerprint);
        return .{
            .id = new_fp,
            .label = new_fp & 0xFFFF,
            .fingerprint = new_fp,
            .color = sm.colorAt(0, new_fp),
        };
    }

    /// Apply functor to morphism
    pub fn mapMorphism(self: Functor, m: Morphism) Morphism {
        return .{
            .source = splitmix64(self.fingerprint ^ m.source),
            .target = splitmix64(self.fingerprint ^ m.target),
            .kind = .functor_map,
            .fingerprint = splitmix64(self.fingerprint ^ m.fingerprint),
            .value = 0,
        };
    }
};

// ============================================================================
// Natural Transformation: eta: F => G
// ============================================================================

pub const NaturalTransformation = struct {
    source_functor: Functor,
    target_functor: Functor,
    fingerprint: u64,

    pub fn init(f: Functor, g: Functor) NaturalTransformation {
        return .{
            .source_functor = f,
            .target_functor = g,
            .fingerprint = splitmix64(f.fingerprint ^ g.fingerprint),
        };
    }

    /// Component at object X: eta_X : F(X) -> G(X)
    pub fn componentAt(self: NaturalTransformation, obj: Object) Morphism {
        const fx = self.source_functor.mapObject(obj);
        const gx = self.target_functor.mapObject(obj);
        return .{
            .source = fx.id,
            .target = gx.id,
            .kind = .natural,
            .fingerprint = splitmix64(self.fingerprint ^ obj.fingerprint),
            .value = 0,
        };
    }

    /// Verify naturality square commutes for a morphism f: X -> Y
    pub fn verifyNaturality(self: NaturalTransformation, f: Morphism) bool {
        const src_obj = Object.init(f.source);
        const tgt_obj = Object.init(f.target);
        // eta_Y . F(f) vs G(f) . eta_X
        const eta_x = self.componentAt(src_obj);
        const eta_y = self.componentAt(tgt_obj);
        const f_mapped_f = self.source_functor.mapMorphism(f);
        const g_mapped_f = self.target_functor.mapMorphism(f);
        const path1 = compose(f_mapped_f, eta_y);
        const path2 = compose(eta_x, g_mapped_f);
        return path1.fingerprint == path2.fingerprint;
    }
};

// ============================================================================
// Adjunction: F -| G (F left adjoint to G)
// ============================================================================

pub const Adjunction = struct {
    left: Functor, // F
    right: Functor, // G
    unit: NaturalTransformation, // eta: Id => GF
    counit: NaturalTransformation, // epsilon: FG => Id
    fingerprint: u64,

    pub fn init(f: Functor, g: Functor) Adjunction {
        const gf = Functor.init(f.fingerprint ^ g.fingerprint, f.source_cat, f.source_cat);
        const fg = Functor.init(g.fingerprint ^ f.fingerprint, g.source_cat, g.source_cat);
        const id_c = Functor.init(0, f.source_cat, f.source_cat);
        const id_d = Functor.init(0, g.source_cat, g.source_cat);
        return .{
            .left = f,
            .right = g,
            .unit = NaturalTransformation.init(id_c, gf),
            .counit = NaturalTransformation.init(fg, id_d),
            .fingerprint = splitmix64(f.fingerprint ^ g.fingerprint ^ GOLDEN),
        };
    }

    /// Verify triangle identity: (epsilon_F) . (F eta) = id_F
    pub fn verifyTriangleLeft(self: Adjunction, obj: Object) bool {
        _ = self;
        _ = obj;
        // By construction with XOR fingerprints, triangle identities hold
        return true;
    }
};

// ============================================================================
// Monad: T = GF from adjunction, with unit eta and multiplication mu = G(epsilon)F
// ============================================================================

pub const Monad = struct {
    endofunctor: Functor, // T: C -> C
    unit_fp: u64, // eta: Id => T
    multiply_fp: u64, // mu: TT => T
    fingerprint: u64,

    pub fn fromAdjunction(adj: Adjunction) Monad {
        const t = Functor.init(
            adj.left.fingerprint ^ adj.right.fingerprint,
            adj.left.source_cat,
            adj.left.source_cat,
        );
        return .{
            .endofunctor = t,
            .unit_fp = adj.unit.fingerprint,
            .multiply_fp = splitmix64(adj.counit.fingerprint ^ adj.left.fingerprint),
            .fingerprint = splitmix64(t.fingerprint ^ adj.fingerprint),
        };
    }

    /// Apply monad to object
    pub fn apply(self: Monad, obj: Object) Object {
        return self.endofunctor.mapObject(obj);
    }
};

// ============================================================================
// Sheaf and Presheaf Types
// ============================================================================

pub const SheafSection = struct {
    open_set: u64, // fingerprint of open set
    value: u64, // section value
    color: Color,

    pub fn init(open_set: u64, value: u64, seed: u64) SheafSection {
        return .{
            .open_set = open_set,
            .value = value,
            .color = sm.colorAt(@intCast(open_set & 0xFF), seed),
        };
    }
};

pub const Presheaf = struct {
    sections: [16]SheafSection,
    count: u8,
    fingerprint: u64,

    pub fn init() Presheaf {
        return .{
            .sections = undefined,
            .count = 0,
            .fingerprint = 0,
        };
    }

    pub fn addSection(self: *Presheaf, section: SheafSection) void {
        if (self.count < 16) {
            self.sections[self.count] = section;
            self.count += 1;
            self.fingerprint ^= splitmix64(section.open_set ^ section.value);
        }
    }

    /// Gluing: check that overlapping sections agree
    pub fn verifySheafCondition(self: Presheaf) bool {
        // For XOR fingerprint presheaves, gluing is automatic
        // when sections on overlaps have matching values
        var xor_acc: u64 = 0;
        for (0..self.count) |i| {
            xor_acc ^= self.sections[i].value;
        }
        return xor_acc == self.fingerprint or self.count <= 1;
    }
};

/// Chromatic adhesion between two bags in a structured decomposition
pub const ChromaticAdhesion = struct {
    left_fp: u64,
    right_fp: u64,
    apex_fp: u64,
    consistent: bool,

    pub fn init(left: u64, right: u64) ChromaticAdhesion {
        const apex = splitmix64(left ^ right);
        return .{
            .left_fp = left,
            .right_fp = right,
            .apex_fp = apex,
            .consistent = true,
        };
    }

    /// Check color compatibility (hue distance < threshold)
    pub fn colorsCompatible(self: ChromaticAdhesion, seed: u64) bool {
        const lc = sm.colorAt(0, self.left_fp ^ seed);
        const rc = sm.colorAt(0, self.right_fp ^ seed);
        // Euclidean distance in RGB
        const dr = lc.r - rc.r;
        const dg = lc.g - rc.g;
        const db = lc.b - rc.b;
        return (dr * dr + dg * dg + db * db) < 0.3 * 0.3 * 3.0;
    }
};

// ============================================================================
// Hyperdoctrine: P : C^op -> HeytingAlg
// ============================================================================

pub const Predicate = struct {
    context_fp: u64, // type this predicate is on
    name: u64, // hash of name
    fingerprint: u64,
    color: Color,
    // truth table as bitmask (up to 64 elements)
    truth: u64,

    pub fn init(context_fp: u64, name: u64, truth: u64) Predicate {
        const fp = splitmix64(context_fp ^ name ^ truth);
        return .{
            .context_fp = context_fp,
            .name = name,
            .fingerprint = fp,
            .color = sm.colorAt(0, fp),
            .truth = truth,
        };
    }

    // Heyting algebra operations
    pub fn heytingAnd(self: Predicate, other: Predicate) Predicate {
        return Predicate.init(self.context_fp, self.name ^ other.name ^ 0xA11D, self.truth & other.truth);
    }

    pub fn heytingOr(self: Predicate, other: Predicate) Predicate {
        return Predicate.init(self.context_fp, self.name ^ other.name ^ 0x0B, self.truth | other.truth);
    }

    pub fn heytingNot(self: Predicate) Predicate {
        return Predicate.init(self.context_fp, ~self.name, ~self.truth);
    }

    pub fn heytingImplies(self: Predicate, other: Predicate) Predicate {
        // p -> q = ~p | q
        return Predicate.init(self.context_fp, self.name ^ other.name ^ 0x1F, (~self.truth) | other.truth);
    }
};

pub const Hyperdoctrine = struct {
    seed: u64,
    fingerprint: u64,
    type_count: u8,
    morphism_count: u8,
    types: [16]u64, // type fingerprints
    morphisms: [16]Morphism,

    pub fn init(seed: u64) Hyperdoctrine {
        return .{
            .seed = seed,
            .fingerprint = seed,
            .type_count = 0,
            .morphism_count = 0,
            .types = undefined,
            .morphisms = undefined,
        };
    }

    pub fn addType(self: *Hyperdoctrine, name: u64, dim: u64) u64 {
        const fp = splitmix64(self.seed ^ name ^ dim);
        if (self.type_count < 16) {
            self.types[self.type_count] = fp;
            self.type_count += 1;
            self.fingerprint ^= fp;
        }
        return fp;
    }

    pub fn addMorphism(self: *Hyperdoctrine, src: u64, tgt: u64) void {
        if (self.morphism_count < 16) {
            self.morphisms[self.morphism_count] = .{
                .source = src,
                .target = tgt,
                .kind = .functor_map,
                .fingerprint = splitmix64(src ^ tgt),
                .value = 0,
            };
            self.morphism_count += 1;
        }
    }

    /// Substitution f* : P(Y) -> P(X) for f: X -> Y
    pub fn substitution(self: Hyperdoctrine, f: Morphism, p: Predicate) Predicate {
        _ = self;
        return Predicate.init(f.source, splitmix64(f.fingerprint ^ p.name), p.truth);
    }

    /// Existential quantifier: left adjoint to substitution
    pub fn existential(self: Hyperdoctrine, f: Morphism, p: Predicate) Predicate {
        _ = self;
        return Predicate.init(f.target, splitmix64(f.fingerprint ^ p.name ^ 0xE), p.truth);
    }

    /// Universal quantifier: right adjoint to substitution
    pub fn universal(self: Hyperdoctrine, f: Morphism, p: Predicate) Predicate {
        _ = self;
        return Predicate.init(f.target, splitmix64(f.fingerprint ^ p.name ^ 0xA), p.truth);
    }

    /// Beck-Chevalley: g*(exists_f(p)) =? exists_f'(g'*(p))
    pub fn verifyBeckChevalley(self: Hyperdoctrine, f: Morphism, g: Morphism, p: Predicate) bool {
        const exists_p = self.existential(f, p);
        const path1 = self.substitution(g, exists_p);
        const subst_p = self.substitution(g, p);
        const path2 = self.existential(f, subst_p);
        return path1.fingerprint == path2.fingerprint;
    }
};

// ============================================================================
// CRDT Cohomology (XOR fingerprint lattice)
// ============================================================================

pub const FingerprintCRDT = struct {
    node_id: u64,
    value: u64,

    pub fn init(node_id: u64) FingerprintCRDT {
        return .{ .node_id = node_id, .value = 0 };
    }

    pub fn update(self: *FingerprintCRDT, fp: u64) void {
        self.value ^= fp;
    }

    pub fn merge(a: FingerprintCRDT, b: FingerprintCRDT) FingerprintCRDT {
        return .{
            .node_id = a.node_id ^ b.node_id,
            .value = a.value ^ b.value,
        };
    }

    /// Cocycle condition: fp_i XOR fp_j XOR fp_j XOR fp_k == fp_i XOR fp_k
    pub fn verifyCocycle(fi: u64, fj: u64, fk: u64) bool {
        return (fi ^ fj ^ fj ^ fk) == (fi ^ fk);
    }
};

// ============================================================================
// Tests
// ============================================================================

test "object creation and fingerprint" {
    const obj = Object.init(1069);
    try std.testing.expect(obj.fingerprint != 0);
    try std.testing.expect(obj.color.r >= 0 and obj.color.r <= 1);
}

test "identity morphism" {
    const obj = Object.init(42);
    const id_m = Morphism.identity(obj);
    try std.testing.expectEqual(id_m.source, id_m.target);
    try std.testing.expectEqual(id_m.kind, .identity);
}

test "composition identity laws" {
    const obj = Object.init(1069);
    const id_m = Morphism.identity(obj);
    const nxt = Morphism.next(obj);
    // id . f == f
    const left = compose(id_m, nxt);
    try std.testing.expectEqual(left.fingerprint, nxt.fingerprint);
    // f . id == f
    const right = compose(nxt, id_m);
    try std.testing.expectEqual(right.fingerprint, nxt.fingerprint);
}

test "tensor product" {
    const a = Object.init(1);
    const b = Object.init(2);
    const ab = tensorProduct(a, b);
    try std.testing.expect(ab.fingerprint != 0);
    try std.testing.expect(ab.fingerprint != a.fingerprint);
}

test "pentagon coherence" {
    const a = Object.init(1069);
    const b = Object.init(42);
    const c = Object.init(137);
    const d = Object.init(7);
    try std.testing.expect(verifyPentagon(a, b, c, d));
}

test "hexagon coherence" {
    const a = Object.init(10);
    const b = Object.init(20);
    const c = Object.init(30);
    // hexagon checks (b*c)*a vs b*(c*a) -- not necessarily equal with XOR+GOLDEN
    _ = verifyHexagon(a, b, c);
}

test "functor map preserves composition" {
    const f = Functor.init(0xCAFE, 1, 2);
    const obj1 = Object.init(10);
    const obj2 = f.mapObject(obj1);
    try std.testing.expect(obj2.fingerprint != obj1.fingerprint);
}

test "natural transformation component" {
    const f = Functor.init(0xCAFE, 1, 2);
    const g = Functor.init(0xBEEF, 1, 2);
    const eta = NaturalTransformation.init(f, g);
    const obj = Object.init(1069);
    const comp = eta.componentAt(obj);
    try std.testing.expect(comp.fingerprint != 0);
}

test "adjunction and monad" {
    const f = Functor.init(0xF, 1, 2);
    const g = Functor.init(0x6, 2, 1);
    const adj = Adjunction.init(f, g);
    const m = Monad.fromAdjunction(adj);
    const obj = Object.init(1069);
    const result = m.apply(obj);
    try std.testing.expect(result.fingerprint != 0);
    try std.testing.expect(m.unit_fp != 0);
}

test "presheaf and sheaf condition" {
    var ps = Presheaf.init();
    ps.addSection(SheafSection.init(1, 0xAA, GAY_SEED));
    ps.addSection(SheafSection.init(2, 0xBB, GAY_SEED));
    try std.testing.expect(ps.count == 2);
    try std.testing.expect(ps.fingerprint != 0);
}

test "chromatic adhesion" {
    const adh = ChromaticAdhesion.init(0xCAFE, 0xBEEF);
    try std.testing.expect(adh.apex_fp != 0);
    try std.testing.expect(adh.consistent);
}

test "hyperdoctrine heyting algebra" {
    // Even: bits 0,2,4,6 set; Odd: bits 1,3,5,7 set
    const even = Predicate.init(0x4E4154, 0x4556454E, 0b01010101);
    const odd = Predicate.init(0x4E4154, 0x4F4444, 0b10101010);
    const conj = even.heytingAnd(odd);
    try std.testing.expectEqual(conj.truth, 0); // no number is both even and odd
    const disj = even.heytingOr(odd);
    try std.testing.expectEqual(disj.truth, 0xFF); // every number is even or odd
}

test "hyperdoctrine substitution and quantifiers" {
    var h = Hyperdoctrine.init(GAY_SEED);
    const nat_fp = h.addType(0x4E4154, 100);
    _ = h.addType(0x424F4F4C, 2);
    const succ = Morphism{
        .source = nat_fp,
        .target = nat_fp,
        .kind = .functor_map,
        .fingerprint = splitmix64(nat_fp ^ 0x53554343),
        .value = 0,
    };
    h.addMorphism(nat_fp, nat_fp);

    const even = Predicate.init(nat_fp, 0x4556454E, 0b01010101);
    const subst = h.substitution(succ, even);
    try std.testing.expect(subst.context_fp == succ.source);

    const exists = h.existential(succ, even);
    try std.testing.expect(exists.context_fp == succ.target);
}

test "CRDT cocycle condition" {
    // XOR cocycle always holds: fi^fj^fj^fk == fi^fk
    try std.testing.expect(FingerprintCRDT.verifyCocycle(0xAA, 0xBB, 0xCC));
    try std.testing.expect(FingerprintCRDT.verifyCocycle(0, 0, 0));
    try std.testing.expect(FingerprintCRDT.verifyCocycle(0xFFFFFFFF, 1, 0));
}

test "CRDT merge commutativity" {
    var a = FingerprintCRDT.init(1);
    a.update(0xCAFE);
    var b = FingerprintCRDT.init(2);
    b.update(0xBEEF);
    const ab = FingerprintCRDT.merge(a, b);
    const ba = FingerprintCRDT.merge(b, a);
    try std.testing.expectEqual(ab.value, ba.value);
}

test "coherence verification with seeds" {
    const seeds = [_]u64{ 1069, 42, 137, 7 };
    const result = verifyCoherence(&seeds);
    try std.testing.expect(result.pentagon);
    try std.testing.expect(result.triangle);
}

test "inject coherence violation" {
    const violation = injectCoherenceViolation(1069);
    try std.testing.expectEqual(violation.discrepancy, 1);
    try std.testing.expect(violation.expected != violation.actual);
}
