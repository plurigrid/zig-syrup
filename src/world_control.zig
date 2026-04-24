//! World Control System: Pijul-style content-addressed patches over propagator networks
//!
//! This module bridges:
//! - Unison's content-addressed definitions (hash = identity)
//! - Pijul's commutative patch algebra (patches commute by default)
//! - Narya's bridge types (patches as directed paths between worlds)
//! - zig-syrup's CellValue lattice (patch application = lattice merge)
//!
//! Wire format: Syrup-encoded patches over JSON-RPC 2.0 (Nashator protocol)
//!
//! Biological activity routing:
//!   Eukaryotic (+1) → CockroachDB (OLTP, compartmentalized writes)
//!   Shared (0)      → Wire (zig-syrup transport, coordination)
//!   Prokaryotic (-1) → DuckDB (OLAP, horizontal reads)

const std = @import("std");
const propagator = @import("propagator.zig");

// =============================================================================
// GF(3) Trit
// =============================================================================

pub const Trit = enum(i2) {
    minus = -1,
    ergodic = 0,
    plus = 1,

    pub fn add(a: Trit, b: Trit) Trit {
        const sum = @as(i8, @intFromEnum(a)) + @as(i8, @intFromEnum(b));
        // Normalize to [-1, 0, 1] via mod 3
        const m = @mod(sum + 3, 3);
        return switch (m) {
            0 => .ergodic,
            1 => .plus,
            2 => .minus,
            else => unreachable,
        };
    }

    pub fn neg(t: Trit) Trit {
        return switch (t) {
            .minus => .plus,
            .ergodic => .ergodic,
            .plus => .minus,
        };
    }

    pub fn mul(a: Trit, b: Trit) Trit {
        return switch (a) {
            .minus => neg(b),
            .ergodic => .ergodic,
            .plus => b,
        };
    }
};

// =============================================================================
// World: a section of the triadic sheaf, identified by content hash
// =============================================================================

pub const WorldId = u64; // SplitMix64 hash

pub const World = struct {
    id: WorldId,
    trajectory: [64]Trit, // fixed-size trit trajectory (ring buffer)
    traj_len: u8,
    generation: u32,
    cell: propagator.CellValue(Trit),

    pub fn init(seed: u64) World {
        var w = World{
            .id = splitmix64(seed),
            .trajectory = undefined,
            .traj_len = 3,
            .generation = 0,
            .cell = .nothing,
        };
        // Initial trajectory: 3 trits from seed
        var s = seed;
        for (0..3) |i| {
            s = splitmix64(s);
            w.trajectory[i] = switch (@as(u2, @truncate(s % 3))) {
                0 => .minus,
                1 => .ergodic,
                2 => .plus,
                else => unreachable,
            };
        }
        return w;
    }

    pub fn trit(self: *const World) Trit {
        var sum: i8 = 0;
        for (0..self.traj_len) |i| {
            sum += @intFromEnum(self.trajectory[i]);
        }
        const m = @mod(sum + 300, 3); // +300 to avoid negative mod
        return switch (@as(u2, @intCast(m))) {
            0 => .ergodic,
            1 => .plus,
            2 => .minus,
            else => unreachable,
        };
    }

    pub fn contentHash(self: *const World) u64 {
        var h: u64 = self.id;
        for (0..self.traj_len) |i| {
            h ^= splitmix64(@as(u64, @intCast(@as(i8, @intFromEnum(self.trajectory[i])) + 2)) +% @as(u64, @intCast(i)));
        }
        return h;
    }
};

// =============================================================================
// Patch: a morphism between worlds (Pijul-style, content-addressed)
// =============================================================================

pub const PatchId = u64;

pub const Patch = struct {
    id: PatchId,
    source: WorldId,
    target: WorldId,
    delta: Trit,
    context: [8]Trit, // dependency context (for commutation check)
    ctx_len: u8,

    /// Content-addressed identity: hash of (source, target, delta)
    pub fn contentId(source: WorldId, target: WorldId, delta: Trit) PatchId {
        var h = splitmix64(source);
        h ^= splitmix64(target);
        h ^= splitmix64(@as(u64, @intCast(@as(i8, @intFromEnum(delta)) + 2)));
        return h;
    }

    /// Identity patch (delta = ergodic, no context)
    pub fn identity(world_id: WorldId) Patch {
        return .{
            .id = contentId(world_id, world_id, .ergodic),
            .source = world_id,
            .target = world_id,
            .delta = .ergodic,
            .context = undefined,
            .ctx_len = 0,
        };
    }

    /// Inverse patch (Pijul: every patch is invertible)
    pub fn inverse(self: *const Patch) Patch {
        var inv = Patch{
            .id = contentId(self.target, self.source, Trit.neg(self.delta)),
            .source = self.target,
            .target = self.source,
            .delta = Trit.neg(self.delta),
            .context = self.context,
            .ctx_len = self.ctx_len,
        };
        _ = &inv;
        return inv;
    }

    /// Compose two patches (if target of first = source of second)
    pub fn compose(self: *const Patch, other: *const Patch) ?Patch {
        if (self.target != other.source) return null;
        const composed_delta = Trit.add(self.delta, other.delta);
        return .{
            .id = contentId(self.source, other.target, composed_delta),
            .source = self.source,
            .target = other.target,
            .delta = composed_delta,
            .context = self.context, // simplified: take first context
            .ctx_len = self.ctx_len,
        };
    }

    /// Two patches commute iff applying in either order yields same result.
    /// In GF(3), trit_add is always commutative, so the only source of
    /// non-commutation is overlapping context (shared write set).
    pub fn commutes(self: *const Patch, other: *const Patch) bool {
        // GF(3) addition is commutative: add(a,b) = add(b,a)
        // Conflict only if contexts overlap AND both modify same position
        if (self.ctx_len == 0 or other.ctx_len == 0) return true;

        // Check for bisimilar contexts (approximation)
        const min_len = @min(self.ctx_len, other.ctx_len);
        var conflict = false;
        for (0..min_len) |i| {
            if (@intFromEnum(self.context[i]) != @intFromEnum(other.context[i])) {
                // Different contexts = independent writes = commute
                return true;
            }
            if (self.context[i] != .ergodic and other.context[i] != .ergodic) {
                conflict = true;
            }
        }
        return !conflict;
    }
};

// =============================================================================
// PatchCell: propagator cell that tracks patch history
// =============================================================================

pub const PatchCell = struct {
    value: propagator.CellValue(Trit),
    history_len: u16,
    cell_id: u32,

    pub fn init(cell_id: u32) PatchCell {
        return .{
            .value = .nothing,
            .history_len = 0,
            .cell_id = cell_id,
        };
    }

    /// Apply a patch using lattice merge
    pub fn applyPatch(self: *PatchCell, patch: *const Patch) void {
        const incoming = propagator.CellValue(Trit){ .value = patch.delta };
        self.value = propagator.latticeMerge(Trit)(self.value, incoming);
        self.history_len += 1;
    }

    pub fn hasConflict(self: *const PatchCell) bool {
        return self.value.isContradiction();
    }
};

// =============================================================================
// Storage routing: biological activity → DuckDB/CockroachDB/Wire
// =============================================================================

pub const StorageTarget = enum {
    oltp, // CockroachDB (writes, eukaryotic, +1)
    olap, // DuckDB (reads, prokaryotic, -1)
    wire, // zig-syrup transport (coordination, 0)

    pub fn trit(self: StorageTarget) Trit {
        return switch (self) {
            .oltp => .plus,
            .olap => .minus,
            .wire => .ergodic,
        };
    }

    /// Route a patch by its delta
    pub fn fromDelta(delta: Trit) StorageTarget {
        return switch (delta) {
            .plus => .oltp,
            .minus => .olap,
            .ergodic => .wire,
        };
    }
};

pub const CellType = enum {
    prokaryote, // -1
    eukaryote, // +1
    both, // 0

    pub fn trit(self: CellType) Trit {
        return switch (self) {
            .prokaryote => .minus,
            .eukaryote => .plus,
            .both => .ergodic,
        };
    }

    pub fn route(self: CellType) StorageTarget {
        return StorageTarget.fromDelta(self.trit());
    }
};

// =============================================================================
// SplitMix64 (same as Gay.jl / nanoclj-zig)
// =============================================================================

fn splitmix64(seed: u64) u64 {
    var z = seed +% 0x9e3779b97f4a7c15;
    z = (z ^ (z >> 30)) *% 0xbf58476d1ce4e5b9;
    z = (z ^ (z >> 27)) *% 0x94d049bb133111eb;
    return z ^ (z >> 31);
}

// =============================================================================
// Tests
// =============================================================================

test "world init deterministic" {
    const w1 = World.init(907);
    const w2 = World.init(907);
    try std.testing.expectEqual(w1.id, w2.id);
    try std.testing.expectEqual(w1.trajectory[0], w2.trajectory[0]);
    try std.testing.expectEqual(w1.trajectory[1], w2.trajectory[1]);
    try std.testing.expectEqual(w1.trajectory[2], w2.trajectory[2]);
}

test "patch identity" {
    const w = World.init(907);
    const id_patch = Patch.identity(w.id);
    try std.testing.expectEqual(id_patch.delta, .ergodic);
    try std.testing.expectEqual(id_patch.source, id_patch.target);
}

test "patch inverse" {
    const p = Patch{
        .id = Patch.contentId(0, 1, .plus),
        .source = 0,
        .target = 1,
        .delta = .plus,
        .context = undefined,
        .ctx_len = 0,
    };
    const inv = p.inverse();
    try std.testing.expectEqual(inv.delta, .minus);
    try std.testing.expectEqual(inv.source, p.target);
    try std.testing.expectEqual(inv.target, p.source);
}

test "patch compose" {
    const p = Patch{
        .id = Patch.contentId(0, 1, .plus),
        .source = 0,
        .target = 1,
        .delta = .plus,
        .context = undefined,
        .ctx_len = 0,
    };
    const q = Patch{
        .id = Patch.contentId(1, 2, .minus),
        .source = 1,
        .target = 2,
        .delta = .minus,
        .context = undefined,
        .ctx_len = 0,
    };
    const composed = p.compose(&q).?;
    try std.testing.expectEqual(composed.delta, .ergodic); // +1 + -1 = 0
    try std.testing.expectEqual(composed.source, @as(u64, 0));
    try std.testing.expectEqual(composed.target, @as(u64, 2));
}

test "patch commutation" {
    const p = Patch{
        .id = Patch.contentId(0, 1, .plus),
        .source = 0,
        .target = 1,
        .delta = .plus,
        .context = undefined,
        .ctx_len = 0,
    };
    const q = Patch{
        .id = Patch.contentId(0, 2, .minus),
        .source = 0,
        .target = 2,
        .delta = .minus,
        .context = undefined,
        .ctx_len = 0,
    };
    try std.testing.expect(p.commutes(&q));
}

test "GF(3) conservation" {
    try std.testing.expectEqual(Trit.add(.plus, Trit.neg(.plus)), .ergodic);
    try std.testing.expectEqual(Trit.add(.minus, Trit.neg(.minus)), .ergodic);
    try std.testing.expectEqual(Trit.add(.ergodic, Trit.neg(.ergodic)), .ergodic);
    // Commutativity
    try std.testing.expectEqual(Trit.add(.plus, .minus), Trit.add(.minus, .plus));
    // Associativity
    try std.testing.expectEqual(
        Trit.add(Trit.add(.plus, .minus), .plus),
        Trit.add(.plus, Trit.add(.minus, .plus)),
    );
}

test "storage routing conservation" {
    // OLTP(+1) + OLAP(-1) + Wire(0) = 0
    const sum = Trit.add(Trit.add(StorageTarget.oltp.trit(), StorageTarget.olap.trit()), StorageTarget.wire.trit());
    try std.testing.expectEqual(sum, .ergodic);
}

test "cell type routing" {
    try std.testing.expectEqual(CellType.eukaryote.route(), .oltp);
    try std.testing.expectEqual(CellType.prokaryote.route(), .olap);
    try std.testing.expectEqual(CellType.both.route(), .wire);
}

test "patch cell lattice" {
    var cell = PatchCell.init(0);
    const p1 = Patch{
        .id = 1,
        .source = 0,
        .target = 1,
        .delta = .plus,
        .context = undefined,
        .ctx_len = 0,
    };
    cell.applyPatch(&p1);
    try std.testing.expect(!cell.hasConflict());

    // Apply conflicting patch
    const p2 = Patch{
        .id = 2,
        .source = 1,
        .target = 2,
        .delta = .minus,
        .context = undefined,
        .ctx_len = 0,
    };
    cell.applyPatch(&p2);
    // lattice merge: plus != minus → contradiction
    try std.testing.expect(cell.hasConflict());
}
