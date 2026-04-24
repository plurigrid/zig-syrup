// worlds.zig: Kripke worlds (possible worlds semantics) and compositional worlds
// Zig translation of Gay.jl's kripke_worlds.jl and compositional_world.jl
// Modal operators box/diamond, sheaf semantics, dynamical doctrines

const std = @import("std");
const splitmix = @import("splitmix.zig");
const splitmix64 = splitmix.splitmix64;
const GAY_SEED: u64 = splitmix.GAY_SEED;

// BoundedArray was removed from std in Zig 0.15; local drop-in replacement.
fn BoundedArray(comptime T: type, comptime buffer_capacity: usize) type {
    return struct {
        const Self = @This();
        buffer: [buffer_capacity]T = undefined,
        len: usize = 0,

        pub fn slice(self: anytype) switch (@TypeOf(&self.buffer)) {
            *[buffer_capacity]T => []T,
            *const [buffer_capacity]T => []const T,
            else => unreachable,
        } {
            return self.buffer[0..self.len];
        }

        pub fn append(self: *Self, item: T) error{Overflow}!void {
            if (self.len >= buffer_capacity) return error.Overflow;
            self.buffer[self.len] = item;
            self.len += 1;
        }
    };
}

// ============================================================================
// World
// ============================================================================

pub const World = struct {
    id: u64,
    seed: u64,
    attestation: u32,

    pub fn init(seed: u64) World {
        const id = splitmix64(seed);
        const att = splitmix64(id);
        return .{ .id = id, .seed = seed, .attestation = @truncate(att) };
    }
};

// ============================================================================
// Kripke Frame
// ============================================================================

pub const KripkeFrame = struct {
    const MAX_WORLDS = 64;

    worlds: BoundedArray(World, MAX_WORLDS),
    reflexive: bool,
    symmetric: bool,
    transitive: bool,
    accessibility_mask: u64,

    pub fn init(n_worlds: u32, seed: u64, reflexive: bool, symmetric: bool, transitive: bool) KripkeFrame {
        var frame: KripkeFrame = .{
            .worlds = .{},
            .reflexive = reflexive,
            .symmetric = symmetric,
            .transitive = transitive,
            .accessibility_mask = splitmix64(seed ^ @as(u64, n_worlds)),
        };
        var s = seed;
        for (0..n_worlds) |_| {
            s = splitmix64(s);
            frame.worlds.append(World.init(s)) catch break;
        }
        return frame;
    }

    pub fn accessible(self: *const KripkeFrame, w1: World, w2: World) bool {
        if (w1.id == w2.id) return self.reflexive;
        const xor_val = w1.id ^ w2.id;
        const pattern_match = (xor_val & self.accessibility_mask) != 0;
        if (self.symmetric) return pattern_match;
        return pattern_match and (w1.id < w2.id or self.reflexive);
    }

    /// Count accessible worlds from w.
    pub fn accessibleCount(self: *const KripkeFrame, w: World) u32 {
        var count: u32 = 0;
        for (self.worlds.slice()) |w2| {
            if (self.accessible(w, w2)) count += 1;
        }
        return count;
    }
};

// ============================================================================
// Modal Proposition
// ============================================================================

pub const ModalProposition = struct {
    const MAX_WORLDS = 64;

    /// Truth values indexed by position in frame's world array.
    truth: [MAX_WORLDS]bool,
    len: u32,
    color: u32,

    pub fn init(frame: *const KripkeFrame, seed: u64) ModalProposition {
        var prop: ModalProposition = .{
            .truth = [_]bool{false} ** MAX_WORLDS,
            .len = @intCast(frame.worlds.len),
            .color = 0,
        };
        var s = seed;
        for (frame.worlds.slice(), 0..) |w, i| {
            s = splitmix64(s);
            const t = (s & 1) == 1;
            prop.truth[i] = t;
            if (t) prop.color ^= w.attestation;
        }
        return prop;
    }

    pub fn truthAt(self: *const ModalProposition, idx: u32) bool {
        return self.truth[idx];
    }

    /// Box (necessity): true at w iff true at all accessible worlds.
    pub fn box(self: *const ModalProposition, frame: *const KripkeFrame) ModalProposition {
        var result: ModalProposition = .{
            .truth = [_]bool{false} ** MAX_WORLDS,
            .len = self.len,
            .color = 0,
        };
        for (frame.worlds.slice(), 0..) |w, i| {
            var necessary = true;
            for (frame.worlds.slice(), 0..) |w2, j| {
                if (frame.accessible(w, w2) and !self.truth[j]) {
                    necessary = false;
                    break;
                }
            }
            result.truth[i] = necessary;
            if (necessary) result.color ^= w.attestation;
        }
        return result;
    }

    /// Diamond (possibility): true at w iff true at some accessible world.
    pub fn diamond(self: *const ModalProposition, frame: *const KripkeFrame) ModalProposition {
        var result: ModalProposition = .{
            .truth = [_]bool{false} ** MAX_WORLDS,
            .len = self.len,
            .color = 0,
        };
        for (frame.worlds.slice(), 0..) |w, i| {
            var possible = false;
            for (frame.worlds.slice(), 0..) |w2, j| {
                if (frame.accessible(w, w2) and self.truth[j]) {
                    possible = true;
                    break;
                }
            }
            result.truth[i] = possible;
            if (possible) result.color ^= w.attestation;
        }
        return result;
    }

    /// Negation.
    pub fn negate(self: *const ModalProposition) ModalProposition {
        var result: ModalProposition = .{
            .truth = [_]bool{false} ** MAX_WORLDS,
            .len = self.len,
            .color = self.color,
        };
        for (0..self.len) |i| {
            result.truth[i] = !self.truth[i];
        }
        return result;
    }

    /// Conjunction.
    pub fn conjunction(self: *const ModalProposition, other: *const ModalProposition) ModalProposition {
        var result: ModalProposition = .{
            .truth = [_]bool{false} ** MAX_WORLDS,
            .len = self.len,
            .color = self.color ^ other.color,
        };
        for (0..self.len) |i| {
            result.truth[i] = self.truth[i] and other.truth[i];
        }
        return result;
    }

    /// Implication p -> q  (= !p or q).
    pub fn implies(self: *const ModalProposition, other: *const ModalProposition) ModalProposition {
        var result: ModalProposition = .{
            .truth = [_]bool{false} ** MAX_WORLDS,
            .len = self.len,
            .color = self.color ^ other.color,
        };
        for (0..self.len) |i| {
            result.truth[i] = !self.truth[i] or other.truth[i];
        }
        return result;
    }

    /// Count worlds where true.
    pub fn trueCount(self: *const ModalProposition) u32 {
        var c: u32 = 0;
        for (0..self.len) |i| {
            if (self.truth[i]) c += 1;
        }
        return c;
    }
};

// ============================================================================
// Modal Law Verification
// ============================================================================

pub const ModalLaws = struct {
    k_axiom: bool,
    t_axiom: bool,
    dual_law: bool,
};

/// Verify K, T, and duality laws on a frame.
pub fn verifyModalLaws(frame: *const KripkeFrame, seed: u64) ModalLaws {
    const p = ModalProposition.init(frame, seed);
    const q = ModalProposition.init(frame, splitmix64(seed));

    // K axiom: box(p->q) -> (box(p) -> box(q)) is valid
    const impl_pq = p.implies(&q);
    const box_impl = impl_pq.box(frame);
    const box_p = p.box(frame);
    const box_q = q.box(frame);
    const rhs = box_p.implies(&box_q);
    const k_impl = box_impl.implies(&rhs);
    var k_valid = true;
    for (0..frame.worlds.len) |i| {
        if (!k_impl.truth[i]) {
            k_valid = false;
            break;
        }
    }

    // T axiom: box(p) -> p  (valid iff reflexive)
    const t_impl = box_p.implies(&p);
    var t_valid = true;
    for (0..frame.worlds.len) |i| {
        if (!t_impl.truth[i]) {
            t_valid = false;
            break;
        }
    }

    // Dual: diamond(p) == not(box(not(p)))
    const diamond_p = p.diamond(frame);
    const not_p = p.negate();
    const box_not_p = not_p.box(frame);
    const not_box_not_p = box_not_p.negate();
    var dual_valid = true;
    for (0..frame.worlds.len) |i| {
        if (diamond_p.truth[i] != not_box_not_p.truth[i]) {
            dual_valid = false;
            break;
        }
    }

    return .{ .k_axiom = k_valid, .t_axiom = t_valid, .dual_law = dual_valid };
}

// ============================================================================
// Sheaf Semantics
// ============================================================================

pub const SheafSemantics = struct {
    const MAX_PROPS = 8;
    frame: KripkeFrame,
    propositions: [MAX_PROPS]ModalProposition,
    n_props: u32,
    global_fingerprint: u32,

    pub fn init(frame: KripkeFrame, seed: u64, n_props: u32) SheafSemantics {
        var sheaf: SheafSemantics = .{
            .frame = frame,
            .propositions = undefined,
            .n_props = @min(n_props, MAX_PROPS),
            .global_fingerprint = 0,
        };
        for (0..sheaf.n_props) |i| {
            sheaf.propositions[i] = ModalProposition.init(&frame, splitmix64(seed ^ @as(u64, i)));
            sheaf.global_fingerprint ^= sheaf.propositions[i].color;
        }
        return sheaf;
    }

    /// Count propositions true at all worlds (global sections).
    pub fn globalSectionCount(self: *const SheafSemantics) u32 {
        var count: u32 = 0;
        for (0..self.n_props) |pi| {
            var all_true = true;
            for (0..self.frame.worlds.len) |wi| {
                if (!self.propositions[pi].truth[wi]) {
                    all_true = false;
                    break;
                }
            }
            if (all_true) count += 1;
        }
        return count;
    }

    /// Count locally necessary propositions at world index.
    pub fn localNecessityCount(self: *const SheafSemantics, world_idx: u32) u32 {
        var count: u32 = 0;
        const w = self.frame.worlds.slice()[world_idx];
        for (0..self.n_props) |pi| {
            var all_acc_true = true;
            for (self.frame.worlds.slice(), 0..) |w2, j| {
                if (self.frame.accessible(w, w2) and !self.propositions[pi].truth[j]) {
                    all_acc_true = false;
                    break;
                }
            }
            if (all_acc_true) count += 1;
        }
        return count;
    }
};

// ============================================================================
// Compositional World (Dynamical Doctrines)
// ============================================================================

pub const SystemProperty = enum {
    multidisciplinarity,
    openness,
    time_continuity,
    space_continuity,
    stochasticity,
    nondeterminism,
    partiality,
    hybridness,
};

pub const DynamicalDoctrine = struct {
    name: [24]u8,
    name_len: u8,
    tower_layer: u8,
    fingerprint: u64,
};

pub const DOCTRINES = [_]DynamicalDoctrine{
    makeDoctrine("concept_tensor", 0, 0x636f6e6365707473),
    makeDoctrine("exponential", 1, 0x6578706f6e656e74),
    makeDoctrine("traced_monoidal", 3, 0x7472616365640000),
    makeDoctrine("tensor_network", 4, 0x6e6574776f726b00),
    makeDoctrine("kripke", 6, 0x6b7269706b650000),
    makeDoctrine("behavioral", 7, 0x6265686176696f72),
    makeDoctrine("probability_sheaf", 9, 0x70726f6261626c65),
    makeDoctrine("random_topos", 10, 0x72616e646f6d0000),
};

fn makeDoctrine(comptime name: []const u8, layer: u8, fp: u64) DynamicalDoctrine {
    var d: DynamicalDoctrine = .{
        .name = [_]u8{0} ** 24,
        .name_len = @intCast(name.len),
        .tower_layer = layer,
        .fingerprint = fp,
    };
    @memcpy(d.name[0..name.len], name);
    return d;
}

pub const CompositionalBridge = struct {
    source_layer: u8,
    target_layer: u8,
    fingerprint: u64,

    pub fn init(src: u8, tgt: u8) CompositionalBridge {
        var src_fp: u64 = @as(u64, src);
        var tgt_fp: u64 = @as(u64, tgt);
        for (DOCTRINES) |d| {
            if (d.tower_layer == src) src_fp = d.fingerprint;
            if (d.tower_layer == tgt) tgt_fp = d.fingerprint;
        }
        return .{ .source_layer = src, .target_layer = tgt, .fingerprint = src_fp ^ tgt_fp };
    }
};

/// Compose bridges via XOR of fingerprints.
pub fn composeSystems(bridges: []const CompositionalBridge) u64 {
    var fp: u64 = 0;
    for (bridges) |b| fp ^= b.fingerprint;
    return fp;
}

/// Behavioral intersection via XOR (order-independent).
pub fn behavioralIntersection(behaviors: []const u64) u64 {
    var fp: u64 = 0;
    for (behaviors) |b| fp ^= b;
    return fp;
}

/// All-doctrine fingerprint.
pub fn allDoctrineFingerprint() u64 {
    var fp: u64 = 0;
    for (DOCTRINES) |d| fp ^= d.fingerprint;
    return fp;
}

// ============================================================================
// World Attestation
// ============================================================================

pub const WorldAttestation = struct {
    world_idx: u32,
    local_fingerprint: u32,
    accessible_count: u32,

    pub fn init(sheaf: *const SheafSemantics, world_idx: u32) WorldAttestation {
        var local_fp: u32 = 0;
        for (0..sheaf.n_props) |pi| {
            if (sheaf.propositions[pi].truth[world_idx]) {
                local_fp ^= sheaf.propositions[pi].color;
            }
        }
        const w = sheaf.frame.worlds.slice()[world_idx];
        return .{
            .world_idx = world_idx,
            .local_fingerprint = local_fp,
            .accessible_count = sheaf.frame.accessibleCount(w),
        };
    }
};

// ============================================================================
// Tests
// ============================================================================

test "kripke frame construction" {
    const frame = KripkeFrame.init(11, GAY_SEED, true, true, true);
    try std.testing.expectEqual(@as(usize, 11), frame.worlds.len);
    // Reflexive: each world accessible to itself
    for (frame.worlds.slice()) |w| {
        try std.testing.expect(frame.accessible(w, w));
    }
}

test "modal proposition truth" {
    const frame = KripkeFrame.init(7, GAY_SEED, true, false, false);
    const p = ModalProposition.init(&frame, GAY_SEED);
    // At least some true, some false (probabilistic but seed-deterministic)
    try std.testing.expect(p.trueCount() > 0);
    try std.testing.expect(p.trueCount() < p.len);
}

test "box reduces true count" {
    const frame = KripkeFrame.init(11, GAY_SEED, true, true, false);
    const p = ModalProposition.init(&frame, GAY_SEED);
    const box_p = p.box(&frame);
    // Box can only keep or reduce truth
    try std.testing.expect(box_p.trueCount() <= p.trueCount());
}

test "diamond increases true count" {
    const frame = KripkeFrame.init(11, GAY_SEED, true, true, false);
    const p = ModalProposition.init(&frame, GAY_SEED);
    const diamond_p = p.diamond(&frame);
    // Diamond can only keep or increase truth
    try std.testing.expect(diamond_p.trueCount() >= p.trueCount());
}

test "K axiom holds on all frames" {
    const frame = KripkeFrame.init(7, GAY_SEED, false, false, false);
    const laws = verifyModalLaws(&frame, GAY_SEED);
    try std.testing.expect(laws.k_axiom);
}

test "T axiom holds on reflexive frame" {
    const frame = KripkeFrame.init(7, GAY_SEED, true, false, false);
    const laws = verifyModalLaws(&frame, GAY_SEED);
    try std.testing.expect(laws.t_axiom);
}

test "dual law diamond = not box not" {
    const frame = KripkeFrame.init(11, GAY_SEED, true, true, true);
    const laws = verifyModalLaws(&frame, GAY_SEED);
    try std.testing.expect(laws.dual_law);
}

test "S5 modal laws" {
    const frame = KripkeFrame.init(11, GAY_SEED, true, true, true);
    const laws = verifyModalLaws(&frame, GAY_SEED);
    try std.testing.expect(laws.k_axiom);
    try std.testing.expect(laws.t_axiom);
    try std.testing.expect(laws.dual_law);
}

test "sheaf fingerprint determinism" {
    const frame1 = KripkeFrame.init(11, GAY_SEED, true, false, false);
    const frame2 = KripkeFrame.init(11, GAY_SEED, true, false, false);
    const sheaf1 = SheafSemantics.init(frame1, GAY_SEED, 5);
    const sheaf2 = SheafSemantics.init(frame2, GAY_SEED, 5);
    try std.testing.expectEqual(sheaf1.global_fingerprint, sheaf2.global_fingerprint);
}

test "compositional bridge XOR" {
    const b1 = CompositionalBridge.init(0, 3);
    const b2 = CompositionalBridge.init(3, 6);
    const bridges = [_]CompositionalBridge{ b1, b2 };
    const fp = composeSystems(&bridges);
    try std.testing.expectEqual(b1.fingerprint ^ b2.fingerprint, fp);
}

test "behavioral intersection order independent" {
    const a: u64 = 0xDEADBEEF;
    const b: u64 = 0xCAFEBABE;
    const c: u64 = 0x12345678;
    const abc = [_]u64{ a, b, c };
    const bca = [_]u64{ b, c, a };
    try std.testing.expectEqual(behavioralIntersection(&abc), behavioralIntersection(&bca));
}

test "all doctrine fingerprint" {
    const fp = allDoctrineFingerprint();
    try std.testing.expect(fp != 0);
}

test "world attestation" {
    const frame = KripkeFrame.init(5, GAY_SEED, true, false, false);
    const sheaf = SheafSemantics.init(frame, GAY_SEED, 3);
    const att = WorldAttestation.init(&sheaf, 0);
    try std.testing.expect(att.accessible_count > 0);
}
