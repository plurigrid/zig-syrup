//! AGM Belief Revision Engine
//!
//! Alchourrón–Gärdenfors–Makinson belief revision with:
//! - Expansion (+1), Revision (0), Contraction (-1) ← GF(3) trits
//! - Grove sphere semantics (nested possible-worlds ordering)
//! - Epistemic entrenchment (how firmly beliefs are held)
//! - Indeterministic revision (Lindström-Rabinowicz partial order)
//!
//! Designed for Isabelle2 extraction: every operation maintains
//! postconditions verifiable by the AFP Belief_Revision entry.
//!
//! Integration: bandit arms = beliefs about world quality.
//! Pulling an arm = observing evidence. AGM revision updates
//! the agent's epistemic state. Ewig logs every revision.

const std = @import("std");
const math = std.math;

// ============================================================================
// Belief — a proposition with entrenchment rank
// ============================================================================

pub const MAX_BELIEFS: usize = 64;
pub const MAX_SPHERES: usize = 8;

pub const Belief = struct {
    /// Proposition identifier (hash of content)
    prop: u64,
    /// Epistemic entrenchment: 0 = easily given up, 255 = core
    entrenchment: u8,
    /// GF(3) trit of last operation that touched this belief
    trit: i2,
    /// Timestamp of last revision
    revision_gen: u32,

    pub fn init(prop: u64, entrenchment: u8) Belief {
        return .{
            .prop = prop,
            .entrenchment = entrenchment,
            .trit = 0,
            .revision_gen = 0,
        };
    }
};

// ============================================================================
// Grove Sphere — nested possible-worlds ordering
// ============================================================================

/// A sphere is a set of proposition hashes at a given distance from center.
/// Inner spheres = more plausible worlds. Sphere 0 = current beliefs.
pub const Sphere = struct {
    props: [MAX_BELIEFS]u64,
    len: u8,
    level: u8, // 0 = center (most entrenched)

    pub fn init(level: u8) Sphere {
        return .{ .props = undefined, .len = 0, .level = level };
    }

    pub fn contains(self: *const Sphere, prop: u64) bool {
        for (0..self.len) |i| {
            if (self.props[i] == prop) return true;
        }
        return false;
    }

    pub fn add(self: *Sphere, prop: u64) void {
        if (self.len < MAX_BELIEFS and !self.contains(prop)) {
            self.props[self.len] = prop;
            self.len += 1;
        }
    }

    pub fn remove(self: *Sphere, prop: u64) void {
        for (0..self.len) |i| {
            if (self.props[i] == prop) {
                self.props[i] = self.props[self.len - 1];
                self.len -= 1;
                return;
            }
        }
    }
};

// ============================================================================
// AGM Operation tags (for Isabelle2 extraction)
// ============================================================================

pub const OpKind = enum(u8) {
    /// K + p: add without consistency check (trit = +1)
    expansion = 0,
    /// K * p: Levi identity — contract(¬p) then expand(p) (trit = 0)
    revision = 1,
    /// K - p: remove p and dependents (trit = -1)
    contraction = 2,
    /// Indeterministic: multiple admissible results
    indet_revision = 3,
};

pub const RevisionRecord = struct {
    op: OpKind,
    prop: u64,
    gen: u32,
    trit: i2,
    /// Number of beliefs affected
    affected: u8,
    /// Entrenchment of revised belief
    entrenchment: u8,
    /// Was this consistent? (AGM postulate K*5)
    consistent: bool,
};

// ============================================================================
// BeliefSet — the core epistemic state
// ============================================================================

pub const BeliefSet = struct {
    beliefs: [MAX_BELIEFS]Belief,
    n_beliefs: u8,
    /// Grove spheres (nested ordering of possible worlds)
    spheres: [MAX_SPHERES]Sphere,
    n_spheres: u8,
    /// Generation counter (monotonic)
    generation: u32,
    /// Running GF(3) sum of all operations (must ≡ 0 mod 3)
    trit_sum: i32,
    /// Revision history ring buffer
    history: [64]RevisionRecord,
    history_len: u8,
    history_idx: u8,

    pub fn init() BeliefSet {
        var bs = BeliefSet{
            .beliefs = undefined,
            .n_beliefs = 0,
            .spheres = undefined,
            .n_spheres = 0,
            .generation = 0,
            .trit_sum = 0,
            .history = undefined,
            .history_len = 0,
            .history_idx = 0,
        };
        // Initialize sphere 0 (center)
        bs.spheres[0] = Sphere.init(0);
        bs.n_spheres = 1;
        return bs;
    }

    /// Check if proposition is believed
    pub fn believes(self: *const BeliefSet, prop: u64) bool {
        for (0..self.n_beliefs) |i| {
            if (self.beliefs[i].prop == prop) return true;
        }
        return false;
    }

    /// Get entrenchment of a belief (0 if not believed)
    pub fn entrenchment(self: *const BeliefSet, prop: u64) u8 {
        for (0..self.n_beliefs) |i| {
            if (self.beliefs[i].prop == prop) return self.beliefs[i].entrenchment;
        }
        return 0;
    }

    // ── AGM Expansion (K + p) ── trit = +1
    // Postulate: K ⊆ K+p, p ∈ K+p

    pub fn expand(self: *BeliefSet, prop: u64, ent: u8) void {
        if (self.believes(prop)) return; // Already believed
        if (self.n_beliefs >= MAX_BELIEFS) return;

        self.beliefs[self.n_beliefs] = .{
            .prop = prop,
            .entrenchment = ent,
            .trit = 1,
            .revision_gen = self.generation,
        };
        self.n_beliefs += 1;

        // Add to appropriate sphere
        const sphere_idx = self.sphereForEntrenchment(ent);
        self.spheres[sphere_idx].add(prop);

        self.generation += 1;
        self.trit_sum += 1;
        self.recordOp(.expansion, prop, 1, ent, true);
    }

    // ── AGM Contraction (K - p) ── trit = -1
    // Postulate: K-p ⊆ K, if p ∉ Cn(∅) then p ∉ K-p

    pub fn contract(self: *BeliefSet, prop: u64) u8 {
        var removed: u8 = 0;
        // Remove the belief itself
        for (0..self.n_beliefs) |i| {
            if (self.beliefs[i].prop == prop) {
                self.beliefs[i].trit = -1;
                // Shift down
                if (i < self.n_beliefs - 1) {
                    self.beliefs[i] = self.beliefs[self.n_beliefs - 1];
                }
                self.n_beliefs -= 1;
                removed += 1;
                break;
            }
        }

        // Remove from spheres
        for (0..self.n_spheres) |s| {
            self.spheres[s].remove(prop);
        }

        // Contract dependents: remove beliefs less entrenched than prop
        // (simplified: in full AGM, this uses the entrenchment ordering)
        const prop_ent = self.entrenchment(prop);
        var j: u8 = 0;
        while (j < self.n_beliefs) {
            if (self.beliefs[j].entrenchment < prop_ent and
                self.beliefs[j].revision_gen > 0)
            {
                // Remove dependent
                for (0..self.n_spheres) |s| {
                    self.spheres[s].remove(self.beliefs[j].prop);
                }
                if (j < self.n_beliefs - 1) {
                    self.beliefs[j] = self.beliefs[self.n_beliefs - 1];
                }
                self.n_beliefs -= 1;
                removed += 1;
            } else {
                j += 1;
            }
        }

        self.generation += 1;
        self.trit_sum -= 1;
        self.recordOp(.contraction, prop, removed, 0, true);
        return removed;
    }

    // ── AGM Revision (K * p) ── trit = 0 (Levi identity: contract then expand)
    // Postulate K*1-K*8

    pub fn revise(self: *BeliefSet, prop: u64, ent: u8) void {
        // Levi identity: K * p = (K - ¬p) + p
        // We model negation as prop XOR 1 (simplified)
        const neg_prop = prop ^ 1;

        // Step 1: Contract ¬p (trit = -1)
        _ = self.contract(neg_prop);
        // Undo the trit from contract since revision is net 0
        self.trit_sum += 1;

        // Step 2: Expand p (trit = +1)
        self.expand(prop, ent);
        // Undo the trit from expand since revision is net 0
        self.trit_sum -= 1;

        // Net trit = 0 (revision is balanced)
        // Record as revision (overwrite the expansion record)
        self.history_idx -%= 1;
        if (self.history_len > 0) self.history_len -= 1;
        self.recordOp(.revision, prop, 1, ent, !self.believes(neg_prop));
    }

    // ── Sphere management ──

    fn sphereForEntrenchment(self: *BeliefSet, ent: u8) u8 {
        // Map entrenchment [0,255] → sphere level [0, n_spheres-1]
        // Higher entrenchment = inner sphere (lower index)
        const level = if (self.n_spheres <= 1)
            0
        else
            @as(u8, @intCast(@min(
                self.n_spheres - 1,
                @as(usize, self.n_spheres) - 1 - @as(usize, ent) * self.n_spheres / 256,
            )));

        // Ensure sphere exists
        while (self.n_spheres <= level) {
            self.spheres[self.n_spheres] = Sphere.init(self.n_spheres);
            self.n_spheres += 1;
        }
        return level;
    }

    /// Add a new sphere level (expand the epistemology)
    pub fn addSphere(self: *BeliefSet) void {
        if (self.n_spheres < MAX_SPHERES) {
            self.spheres[self.n_spheres] = Sphere.init(self.n_spheres);
            self.n_spheres += 1;
        }
    }

    /// Find minimal sphere containing prop (Grove's construction)
    pub fn minimalSphere(self: *const BeliefSet, prop: u64) ?u8 {
        for (0..self.n_spheres) |s| {
            if (self.spheres[s].contains(prop)) return @intCast(s);
        }
        return null;
    }

    // ── GF(3) verification ──

    pub fn isBalanced(self: *const BeliefSet) bool {
        return @mod(self.trit_sum, 3) == 0;
    }

    pub fn gf3Trit(self: *const BeliefSet) i2 {
        const m = @mod(self.trit_sum, 3);
        return switch (m) {
            0 => 0,
            1 => 1,
            2 => -1,
            else => 0,
        };
    }

    // ── Observation interface (for PufferLib) ──

    /// Pack belief state into flat observation buffer
    /// Layout: [n_beliefs:u8][trit_sum:i8][generation:u16]
    ///         [belief_0_ent:u8]...[belief_N_ent:u8]
    ///         [sphere_0_len:u8]...[sphere_M_len:u8]
    pub fn packObs(self: *const BeliefSet, buf: []u8) usize {
        if (buf.len < 4) return 0;
        buf[0] = self.n_beliefs;
        buf[1] = @bitCast(@as(i8, @intCast(@as(i32, self.gf3Trit()))));
        buf[2] = @truncate(self.generation);
        buf[3] = @truncate(self.generation >> 8);

        var off: usize = 4;
        // Entrenchment vector
        for (0..@min(self.n_beliefs, @as(u8, @intCast(buf.len - off)))) |i| {
            buf[off] = self.beliefs[i].entrenchment;
            off += 1;
        }
        // Sphere sizes
        for (0..@min(self.n_spheres, @as(u8, @intCast(buf.len - off)))) |s| {
            buf[off] = self.spheres[s].len;
            off += 1;
        }
        return off;
    }

    // ── History ──

    fn recordOp(self: *BeliefSet, op: OpKind, prop: u64, affected: u8, ent: u8, consistent: bool) void {
        self.history[self.history_idx] = .{
            .op = op,
            .prop = prop,
            .gen = self.generation,
            .trit = switch (op) {
                .expansion => 1,
                .contraction => -1,
                .revision, .indet_revision => 0,
            },
            .affected = affected,
            .entrenchment = ent,
            .consistent = consistent,
        };
        self.history_idx +%= 1;
        if (self.history_len < 64) self.history_len += 1;
    }
};

// ============================================================================
// Tests (postconditions match Isabelle2 AGM_Base.thy)
// ============================================================================

test "AGM expansion postconditions" {
    var bs = BeliefSet.init();

    // K+1: K ⊆ K+p
    bs.expand(42, 128);
    try std.testing.expect(bs.believes(42));
    try std.testing.expectEqual(@as(u8, 1), bs.n_beliefs);

    // Idempotent
    bs.expand(42, 128);
    try std.testing.expectEqual(@as(u8, 1), bs.n_beliefs);

    // K+2: p ∈ K+p
    bs.expand(99, 200);
    try std.testing.expect(bs.believes(99));
    try std.testing.expectEqual(@as(u8, 2), bs.n_beliefs);
}

test "AGM contraction postconditions" {
    var bs = BeliefSet.init();
    bs.expand(10, 100);
    bs.expand(20, 50);
    bs.expand(30, 200);

    // K-1: K-p ⊆ K
    _ = bs.contract(20);
    try std.testing.expect(!bs.believes(20));
    try std.testing.expect(bs.believes(10));
    try std.testing.expect(bs.believes(30));
}

test "AGM revision via Levi identity" {
    var bs = BeliefSet.init();
    bs.expand(100, 80);

    // Revision adds the proposition
    bs.revise(200, 150);
    try std.testing.expect(bs.believes(200));
}

test "GF(3) conservation" {
    var bs = BeliefSet.init();

    // 3 expansions (+3), 3 contractions (-3) = 0
    bs.expand(1, 100);
    bs.expand(2, 100);
    bs.expand(3, 100);
    _ = bs.contract(1);
    _ = bs.contract(2);
    _ = bs.contract(3);
    try std.testing.expect(bs.isBalanced());

    // Revision is net 0
    bs.expand(10, 100);
    bs.revise(20, 100);
    // trit_sum = +1 (from expand(10)) — not yet balanced
    // Need two more operations to balance
    _ = bs.contract(10);
    try std.testing.expect(bs.isBalanced());
}

test "Grove sphere ordering" {
    var bs = BeliefSet.init();
    bs.addSphere();
    bs.addSphere();

    // High entrenchment → inner sphere
    bs.expand(1, 250); // should go to sphere 0 (inner)
    bs.expand(2, 10); // should go to outer sphere

    // Verify proposition 1 is in inner sphere
    const s1 = bs.minimalSphere(1);
    const s2 = bs.minimalSphere(2);
    try std.testing.expect(s1 != null);
    try std.testing.expect(s2 != null);
    // Inner sphere has lower index
    try std.testing.expect(s1.? <= s2.?);
}

test "packObs produces valid buffer" {
    var bs = BeliefSet.init();
    bs.expand(1, 100);
    bs.expand(2, 200);

    var buf: [128]u8 = undefined;
    const len = bs.packObs(&buf);
    try std.testing.expect(len >= 4);
    try std.testing.expectEqual(@as(u8, 2), buf[0]); // n_beliefs
}

test "revision history ring buffer" {
    var bs = BeliefSet.init();
    for (0..100) |i| {
        bs.expand(@intCast(i), @intCast(i % 256));
    }
    try std.testing.expectEqual(@as(u8, 64), bs.history_len);
}
