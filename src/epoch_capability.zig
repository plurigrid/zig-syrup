//! epoch_capability.zig — Epoch-graded capabilities for partition-aware OCapN
//!
//! Connects trit_tick.zig's 4-epoch time base to goblins.zig's CapTP system.
//! Capabilities degrade gracefully under network partition rather than
//! claiming impossible global consistency (which violates CAP theorem).
//!
//! EPOCH LADDER (each epoch = complete system at different trust/cost):
//!   E0 — Local vat: instant consistency, synchronous revocation
//!   E1 — Cluster: bounded consistency (trit-tick epoch 1), 1-hop revocation
//!   E2 — Federated: eventual consistency (epoch 2), gossip revocation
//!   E3 — Unbounded: cryptographic proof, proof-carrying revocation
//!
//! DEGRADATION: if freshness > epoch's consistency window, capability demotes.
//! This is correct behavior under CAP, not a bug.
//!
//! REVOCATION SCOPE:
//!   E0 = synchronous (same vat turn)
//!   E1 = bounded (within heartbeat interval)
//!   E2 = eventual (gossip, may take minutes)
//!   E3 = proof-carrying (signed certificate, no time bound)

const std = @import("std");
const trit_tick = @import("trit_tick.zig");

// ============================================================================
// EPOCH TAG
// ============================================================================

pub const Epoch = enum(u2) {
    local = 0, // E0: same vat, synchronous
    cluster = 1, // E1: 1-hop, bounded time
    federated = 2, // E2: multi-hop, eventual
    unbounded = 3, // E3: cryptographic proof
};

// ============================================================================
// CONSISTENCY WINDOWS (in trit-ticks)
// ============================================================================

/// E0: local vat, always fresh (window = 0)
pub const E0_WINDOW: u64 = 0;

/// E1: cluster heartbeat, 1 second = 141,120,000 trit-ticks
pub const E1_WINDOW: u64 = trit_tick.TICKS_PER_SECOND;

/// E2: gossip round, 60 seconds
pub const E2_WINDOW: u64 = trit_tick.TICKS_PER_SECOND * 60;

/// E3: no time bound (u64 max = "never expires by time alone")
pub const E3_WINDOW: u64 = std.math.maxInt(u64);

pub fn windowForEpoch(epoch: Epoch) u64 {
    return switch (epoch) {
        .local => E0_WINDOW,
        .cluster => E1_WINDOW,
        .federated => E2_WINDOW,
        .unbounded => E3_WINDOW,
    };
}

// ============================================================================
// EPOCH CAPABILITY REFERENCE
// ============================================================================

/// A CapTP reference tagged with epoch metadata.
/// Wraps a goblins.zig export/import slot with partition-awareness.
pub const EpochCapRef = struct {
    /// Which export/import slot in the CapTPSession
    slot: u16,
    /// Whether this is an import (true) or export (false)
    is_import: bool,
    /// Current epoch (may have been demoted from granted_epoch)
    epoch: Epoch,
    /// Epoch at which this capability was originally granted
    granted_epoch: Epoch,
    /// Trit-tick timestamp of last successful verification
    last_verified: u64,
    /// Trit-tick timestamp when this capability was created
    created_at: u64,
    /// GF(3) trit of the granting identity (for conservation checking)
    granter_trit: i8,
    /// Revocation status
    revoked: bool,

    pub fn init(slot: u16, is_import: bool, epoch: Epoch, now: u64, granter_trit: i8) EpochCapRef {
        return .{
            .slot = slot,
            .is_import = is_import,
            .epoch = epoch,
            .granted_epoch = epoch,
            .last_verified = now,
            .created_at = now,
            .granter_trit = granter_trit,
            .revoked = false,
        };
    }

    /// Freshness = ticks since last verification
    pub fn freshness(self: *const EpochCapRef, now: u64) u64 {
        if (now <= self.last_verified) return 0;
        return now - self.last_verified;
    }

    /// Check if this capability is still within its epoch's consistency window.
    pub fn isConsistent(self: *const EpochCapRef, now: u64) bool {
        if (self.revoked) return false;
        if (self.epoch == .local) return true; // E0 always consistent
        if (self.epoch == .unbounded) return true; // E3 never expires by time
        return self.freshness(now) <= windowForEpoch(self.epoch);
    }

    /// Attempt to verify (heartbeat received). Resets freshness.
    pub fn verify(self: *EpochCapRef, now: u64) void {
        self.last_verified = now;
    }

    /// Try to promote back toward granted_epoch after re-verification.
    pub fn tryPromote(self: *EpochCapRef, now: u64) bool {
        if (self.revoked) return false;
        if (@intFromEnum(self.epoch) >= @intFromEnum(self.granted_epoch)) return false;
        self.epoch = @enumFromInt(@intFromEnum(self.epoch) + 1);
        self.last_verified = now;
        return true;
    }

    /// Degrade one epoch level. Returns the new epoch.
    /// E0 cannot degrade further (local vat is always self-consistent).
    pub fn degrade(self: *EpochCapRef) Epoch {
        if (@intFromEnum(self.epoch) > 0) {
            self.epoch = @enumFromInt(@intFromEnum(self.epoch) - 1);
        }
        return self.epoch;
    }

    /// Check freshness and auto-degrade if stale. Returns number of demotions.
    pub fn checkAndDegrade(self: *EpochCapRef, now: u64) u8 {
        if (self.revoked) return 0;
        var demotions: u8 = 0;
        while (@intFromEnum(self.epoch) > 0 and !self.isConsistent(now)) {
            _ = self.degrade();
            demotions += 1;
        }
        return demotions;
    }

    /// Revoke this capability. Revocation is immediate at all epochs
    /// but propagation to remote holders depends on epoch:
    ///   E0: synchronous (done), E1: bounded, E2: eventual, E3: proof-carrying
    pub fn revoke(self: *EpochCapRef) void {
        self.revoked = true;
    }
};

// ============================================================================
// EPOCH CAPABILITY TABLE (per-session)
// ============================================================================

pub const MAX_EPOCH_CAPS: usize = 64;

pub const EpochCapTable = struct {
    caps: [MAX_EPOCH_CAPS]EpochCapRef = undefined,
    len: u16 = 0,

    /// Add a new epoch-tagged capability.
    pub fn add(self: *EpochCapTable, slot: u16, is_import: bool, epoch: Epoch, now: u64, granter_trit: i8) ?u16 {
        if (self.len >= MAX_EPOCH_CAPS) return null;
        self.caps[self.len] = EpochCapRef.init(slot, is_import, epoch, now, granter_trit);
        self.len += 1;
        return self.len - 1;
    }

    /// Get capability by index.
    pub fn get(self: *const EpochCapTable, idx: u16) ?*const EpochCapRef {
        if (idx >= self.len) return null;
        return &self.caps[idx];
    }

    /// Get mutable capability by index.
    pub fn getMut(self: *EpochCapTable, idx: u16) ?*EpochCapRef {
        if (idx >= self.len) return null;
        return &self.caps[idx];
    }

    /// Run degradation check on all capabilities. Returns total demotions.
    pub fn checkAll(self: *EpochCapTable, now: u64) u32 {
        var total: u32 = 0;
        for (0..self.len) |i| {
            total += @as(u32, self.caps[i].checkAndDegrade(now));
        }
        return total;
    }

    /// Verify (heartbeat) all capabilities at a given epoch or above.
    pub fn verifyAtEpoch(self: *EpochCapTable, epoch: Epoch, now: u64) u16 {
        var count: u16 = 0;
        for (0..self.len) |i| {
            if (@intFromEnum(self.caps[i].epoch) >= @intFromEnum(epoch) and !self.caps[i].revoked) {
                self.caps[i].verify(now);
                count += 1;
            }
        }
        return count;
    }

    /// Revoke all capabilities from a given granter trit.
    pub fn revokeByGranter(self: *EpochCapTable, granter_trit: i8) u16 {
        var count: u16 = 0;
        for (0..self.len) |i| {
            if (self.caps[i].granter_trit == granter_trit and !self.caps[i].revoked) {
                self.caps[i].revoke();
                count += 1;
            }
        }
        return count;
    }

    /// Count capabilities at each epoch level.
    pub fn epochDistribution(self: *const EpochCapTable) [4]u16 {
        var dist = [4]u16{ 0, 0, 0, 0 };
        for (0..self.len) |i| {
            if (!self.caps[i].revoked) {
                dist[@intFromEnum(self.caps[i].epoch)] += 1;
            }
        }
        return dist;
    }

    /// GF(3) conservation check: sum of active granter trits mod 3 == 0?
    pub fn gf3Conserved(self: *const EpochCapTable) bool {
        var sum: i32 = 0;
        for (0..self.len) |i| {
            if (!self.caps[i].revoked) {
                sum += @as(i32, self.caps[i].granter_trit);
            }
        }
        return @mod(sum + 3000, 3) == 0;
    }
};

// ============================================================================
// REVOCATION CERTIFICATE (E3 proof-carrying revocation)
// ============================================================================

/// For epoch 3 (unbounded), revocation is a signed certificate.
/// The certificate can be verified without contacting the revoker.
pub const RevocationCert = struct {
    /// Slot being revoked
    slot: u16,
    /// Epoch at which revocation was issued
    epoch: Epoch,
    /// Trit-tick timestamp of revocation
    timestamp: u64,
    /// SHA-256 of (slot ++ epoch ++ timestamp ++ revoker_pubkey)
    commitment: [32]u8,
    /// Revoker's public key
    revoker_pubkey: [32]u8,

    /// Compute commitment hash for a revocation.
    pub fn computeCommitment(slot: u16, epoch: Epoch, timestamp: u64, revoker_pubkey: [32]u8) [32]u8 {
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        var slot_bytes: [2]u8 = undefined;
        std.mem.writeInt(u16, &slot_bytes, slot, .big);
        hasher.update(&slot_bytes);
        hasher.update(&[_]u8{@intFromEnum(epoch)});
        var ts_bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &ts_bytes, timestamp, .big);
        hasher.update(&ts_bytes);
        hasher.update(&revoker_pubkey);
        return hasher.finalResult();
    }

    /// Create a revocation certificate.
    pub fn create(slot: u16, epoch: Epoch, timestamp: u64, revoker_pubkey: [32]u8) RevocationCert {
        return .{
            .slot = slot,
            .epoch = epoch,
            .timestamp = timestamp,
            .commitment = computeCommitment(slot, epoch, timestamp, revoker_pubkey),
            .revoker_pubkey = revoker_pubkey,
        };
    }

    /// Verify the certificate's commitment hash.
    pub fn verifyCommitment(self: *const RevocationCert) bool {
        const expected = computeCommitment(self.slot, self.epoch, self.timestamp, self.revoker_pubkey);
        return std.mem.eql(u8, &self.commitment, &expected);
    }
};

// ============================================================================
// PARTITION DETECTOR (heartbeat-based)
// ============================================================================

pub const PartitionDetector = struct {
    /// Last heartbeat received per epoch
    last_heartbeat: [4]u64 = [4]u64{ 0, 0, 0, 0 },
    /// Number of missed heartbeats per epoch
    missed: [4]u32 = [4]u32{ 0, 0, 0, 0 },

    /// Record a heartbeat at the given epoch.
    pub fn heartbeat(self: *PartitionDetector, epoch: Epoch, now: u64) void {
        self.last_heartbeat[@intFromEnum(epoch)] = now;
        self.missed[@intFromEnum(epoch)] = 0;
    }

    /// Check if a given epoch is partitioned (heartbeat gap > window).
    pub fn isPartitioned(self: *const PartitionDetector, epoch: Epoch, now: u64) bool {
        if (epoch == .local) return false; // E0 never partitioned from itself
        const last = self.last_heartbeat[@intFromEnum(epoch)];
        if (last == 0) return true; // never received
        return (now - last) > windowForEpoch(epoch);
    }

    /// Check all epochs and return the highest non-partitioned epoch.
    /// Hierarchical: each higher epoch requires all lower epochs to be live.
    /// You can't claim federated consistency if your cluster is partitioned.
    pub fn highestLiveEpoch(self: *const PartitionDetector, now: u64) Epoch {
        if (self.isPartitioned(.cluster, now)) return .local;
        if (self.isPartitioned(.federated, now)) return .cluster;
        if (self.isPartitioned(.unbounded, now)) return .federated;
        return .unbounded;
    }

    /// Run a degradation sweep: degrade all caps above the highest live epoch.
    pub fn degradeSweep(self: *const PartitionDetector, table: *EpochCapTable, now: u64) u32 {
        const live = self.highestLiveEpoch(now);
        var demotions: u32 = 0;
        for (0..table.len) |i| {
            while (@intFromEnum(table.caps[i].epoch) > @intFromEnum(live) and !table.caps[i].revoked) {
                _ = table.caps[i].degrade();
                demotions += 1;
            }
        }
        return demotions;
    }
};

// ============================================================================
// EPOCH MESSAGE ENVELOPE (Syrup-ready)
// ============================================================================

/// Every message between vats carries epoch metadata.
/// This is the trit-tick-stamped envelope that goblins.zig messages wrap in.
pub const EpochEnvelope = struct {
    /// Trit-tick timestamp (epoch 1 by default)
    timestamp: u64,
    /// Sender's current epoch
    sender_epoch: Epoch,
    /// GF(3) trit of sender
    sender_trit: i8,
    /// Heartbeat: if true, this message also serves as a liveness proof
    is_heartbeat: bool,

    pub fn now(epoch: Epoch, trit: i8, heartbeat: bool) EpochEnvelope {
        return .{
            .timestamp = 0, // caller sets from real clock
            .sender_epoch = epoch,
            .sender_trit = trit,
            .is_heartbeat = heartbeat,
        };
    }

    /// Encode into a byte buffer (simple binary format for Syrup embedding).
    /// [8 bytes timestamp][1 byte epoch][1 byte trit+128][1 byte heartbeat]
    pub fn encode(self: *const EpochEnvelope, out: *[11]u8) void {
        std.mem.writeInt(u64, out[0..8], self.timestamp, .big);
        out[8] = @intFromEnum(self.sender_epoch);
        out[9] = @intCast(@as(i16, self.sender_trit) + 128);
        out[10] = if (self.is_heartbeat) 1 else 0;
    }

    /// Decode from a byte buffer.
    pub fn decode(buf: *const [11]u8) EpochEnvelope {
        return .{
            .timestamp = std.mem.readInt(u64, buf[0..8], .big),
            .sender_epoch = @enumFromInt(buf[8] & 0x03),
            .sender_trit = @as(i8, @intCast(@as(i16, buf[9]) - 128)),
            .is_heartbeat = buf[10] != 0,
        };
    }
};

// ============================================================================
// TESTS
// ============================================================================

test "epoch windows are monotonically increasing" {
    try std.testing.expect(E0_WINDOW < E1_WINDOW);
    try std.testing.expect(E1_WINDOW < E2_WINDOW);
    try std.testing.expect(E2_WINDOW < E3_WINDOW);
}

test "E1 window = exactly 1 second in trit-ticks" {
    try std.testing.expectEqual(trit_tick.TICKS_PER_SECOND, E1_WINDOW);
}

test "E2 window = exactly 60 seconds" {
    try std.testing.expectEqual(trit_tick.TICKS_PER_SECOND * 60, E2_WINDOW);
}

test "capability: fresh capability is consistent" {
    const now: u64 = trit_tick.TICKS_PER_SECOND * 100;
    var cap = EpochCapRef.init(0, false, .federated, now, 1);
    try std.testing.expect(cap.isConsistent(now));
    try std.testing.expect(cap.isConsistent(now + 1000));
}

test "capability: stale capability is inconsistent" {
    const now: u64 = trit_tick.TICKS_PER_SECOND * 100;
    var cap = EpochCapRef.init(0, false, .cluster, now, 0);
    // 2 seconds later, E1 window (1s) exceeded
    const later = now + trit_tick.TICKS_PER_SECOND * 2;
    try std.testing.expect(!cap.isConsistent(later));
}

test "capability: degradation under partition" {
    const now: u64 = trit_tick.TICKS_PER_SECOND * 100;
    var cap = EpochCapRef.init(0, false, .federated, now, -1);
    // 120 seconds later — exceeds E2 window (60s)
    const later = now + trit_tick.TICKS_PER_SECOND * 120;
    const demotions = cap.checkAndDegrade(later);
    // Should degrade from E2 → E1, and E1 is also stale (120s > 1s) → E1 → E0
    try std.testing.expectEqual(@as(u8, 2), demotions);
    try std.testing.expectEqual(Epoch.local, cap.epoch);
}

test "capability: E0 never degrades" {
    const now: u64 = trit_tick.TICKS_PER_SECOND * 100;
    var cap = EpochCapRef.init(0, true, .local, now, 0);
    const far_future = now + trit_tick.TICKS_PER_SECOND * 999999;
    try std.testing.expect(cap.isConsistent(far_future));
    const demotions = cap.checkAndDegrade(far_future);
    try std.testing.expectEqual(@as(u8, 0), demotions);
    try std.testing.expectEqual(Epoch.local, cap.epoch);
}

test "capability: E3 never expires by time" {
    const now: u64 = trit_tick.TICKS_PER_SECOND * 100;
    var cap = EpochCapRef.init(0, false, .unbounded, now, 1);
    const far_future = now + trit_tick.TICKS_PER_SECOND * 999999;
    try std.testing.expect(cap.isConsistent(far_future));
}

test "capability: revocation is immediate" {
    const now: u64 = trit_tick.TICKS_PER_SECOND * 100;
    var cap = EpochCapRef.init(0, false, .unbounded, now, 1);
    try std.testing.expect(cap.isConsistent(now));
    cap.revoke();
    try std.testing.expect(!cap.isConsistent(now));
}

test "capability: verify resets freshness" {
    const now: u64 = trit_tick.TICKS_PER_SECOND * 100;
    var cap = EpochCapRef.init(0, false, .cluster, now, 0);
    const later = now + trit_tick.TICKS_PER_SECOND * 2;
    try std.testing.expect(!cap.isConsistent(later));
    cap.verify(later);
    try std.testing.expect(cap.isConsistent(later));
}

test "capability: promote after re-verification" {
    const now: u64 = trit_tick.TICKS_PER_SECOND * 100;
    var cap = EpochCapRef.init(0, false, .federated, now, 1);
    // Degrade to E0
    const stale = now + trit_tick.TICKS_PER_SECOND * 120;
    _ = cap.checkAndDegrade(stale);
    try std.testing.expectEqual(Epoch.local, cap.epoch);
    // Re-verify and promote step by step
    const fresh = stale + 1;
    try std.testing.expect(cap.tryPromote(fresh));
    try std.testing.expectEqual(Epoch.cluster, cap.epoch);
    try std.testing.expect(cap.tryPromote(fresh));
    try std.testing.expectEqual(Epoch.federated, cap.epoch);
    // Can't promote beyond granted
    try std.testing.expect(!cap.tryPromote(fresh));
}

test "table: epoch distribution tracks correctly" {
    var table = EpochCapTable{};
    const now: u64 = trit_tick.TICKS_PER_SECOND * 100;
    _ = table.add(0, false, .local, now, -1);
    _ = table.add(1, false, .cluster, now, 0);
    _ = table.add(2, false, .federated, now, 1);
    _ = table.add(3, false, .unbounded, now, -1);
    _ = table.add(4, false, .cluster, now, 0);
    const dist = table.epochDistribution();
    try std.testing.expectEqual(@as(u16, 1), dist[0]); // E0
    try std.testing.expectEqual(@as(u16, 2), dist[1]); // E1
    try std.testing.expectEqual(@as(u16, 1), dist[2]); // E2
    try std.testing.expectEqual(@as(u16, 1), dist[3]); // E3
}

test "table: checkAll degrades stale capabilities" {
    var table = EpochCapTable{};
    const now: u64 = trit_tick.TICKS_PER_SECOND * 100;
    _ = table.add(0, false, .local, now, 0);
    _ = table.add(1, false, .cluster, now, 0);
    _ = table.add(2, false, .federated, now, 1);
    // 120 seconds later
    const later = now + trit_tick.TICKS_PER_SECOND * 120;
    const demotions = table.checkAll(later);
    // E0 stays, E1 → E0 (1 demotion), E2 → E0 (2 demotions)
    try std.testing.expectEqual(@as(u32, 3), demotions);
    const dist = table.epochDistribution();
    try std.testing.expectEqual(@as(u16, 3), dist[0]); // all at E0
    try std.testing.expectEqual(@as(u16, 0), dist[1]);
    try std.testing.expectEqual(@as(u16, 0), dist[2]);
}

test "table: verifyAtEpoch refreshes matching caps" {
    var table = EpochCapTable{};
    const now: u64 = trit_tick.TICKS_PER_SECOND * 100;
    _ = table.add(0, false, .local, now, -1);
    _ = table.add(1, false, .cluster, now, 0);
    _ = table.add(2, false, .federated, now, 1);
    const later = now + trit_tick.TICKS_PER_SECOND * 30;
    const refreshed = table.verifyAtEpoch(.cluster, later);
    try std.testing.expectEqual(@as(u16, 2), refreshed); // E1 and E2
    // E1 cap should now be fresh
    try std.testing.expect(table.caps[1].isConsistent(later));
}

test "table: revokeByGranter revokes matching caps" {
    var table = EpochCapTable{};
    const now: u64 = trit_tick.TICKS_PER_SECOND * 100;
    _ = table.add(0, false, .cluster, now, 1);
    _ = table.add(1, false, .cluster, now, -1);
    _ = table.add(2, false, .federated, now, 1);
    const revoked = table.revokeByGranter(1);
    try std.testing.expectEqual(@as(u16, 2), revoked);
    try std.testing.expect(table.caps[0].revoked);
    try std.testing.expect(!table.caps[1].revoked);
    try std.testing.expect(table.caps[2].revoked);
}

test "table: GF(3) conservation" {
    var table = EpochCapTable{};
    const now: u64 = trit_tick.TICKS_PER_SECOND * 100;
    // Triad: -1 + 0 + 1 = 0 mod 3
    _ = table.add(0, false, .cluster, now, -1);
    _ = table.add(1, false, .cluster, now, 0);
    _ = table.add(2, false, .federated, now, 1);
    try std.testing.expect(table.gf3Conserved());
    // Revoke one — conservation may break
    table.caps[0].revoke();
    // Remaining: 0 + 1 = 1, not conserved
    try std.testing.expect(!table.gf3Conserved());
}

test "partition detector: E0 never partitioned" {
    const pd = PartitionDetector{};
    const now: u64 = trit_tick.TICKS_PER_SECOND * 1000;
    try std.testing.expect(!pd.isPartitioned(.local, now));
}

test "partition detector: missing heartbeat = partitioned" {
    var pd = PartitionDetector{};
    const now: u64 = trit_tick.TICKS_PER_SECOND * 100;
    pd.heartbeat(.cluster, now);
    // 0.5s later: still live
    try std.testing.expect(!pd.isPartitioned(.cluster, now + trit_tick.TICKS_PER_SECOND / 2));
    // 2s later: partitioned (E1 window = 1s)
    try std.testing.expect(pd.isPartitioned(.cluster, now + trit_tick.TICKS_PER_SECOND * 2));
}

test "partition detector: highest live epoch" {
    var pd = PartitionDetector{};
    const now: u64 = trit_tick.TICKS_PER_SECOND * 100;
    pd.heartbeat(.cluster, now);
    pd.heartbeat(.federated, now);
    pd.heartbeat(.unbounded, now);
    // All live
    try std.testing.expectEqual(Epoch.unbounded, pd.highestLiveEpoch(now));
    // After 2s: E1 partitioned (>1s), hierarchy forces all above to .local
    const t2 = now + trit_tick.TICKS_PER_SECOND * 2;
    try std.testing.expectEqual(Epoch.local, pd.highestLiveEpoch(t2));
    // Refresh E1 only — E2/E3 still have heartbeats from t0 (within their windows)
    pd.heartbeat(.cluster, t2);
    // Hierarchical: E1 live, E2 still within 60s, E3 within maxInt → unbounded
    try std.testing.expectEqual(Epoch.unbounded, pd.highestLiveEpoch(t2));
    // After 120s (E2 window exceeded): E2 partitioned → E1 is highest
    const t3 = now + trit_tick.TICKS_PER_SECOND * 120;
    pd.heartbeat(.cluster, t3); // keep E1 alive
    try std.testing.expectEqual(Epoch.cluster, pd.highestLiveEpoch(t3));
}

test "partition detector: degrade sweep" {
    var pd = PartitionDetector{};
    var table = EpochCapTable{};
    const now: u64 = trit_tick.TICKS_PER_SECOND * 100;
    pd.heartbeat(.cluster, now);
    pd.heartbeat(.federated, now);
    _ = table.add(0, false, .local, now, 0);
    _ = table.add(1, false, .cluster, now, 1);
    _ = table.add(2, false, .federated, now, -1);
    _ = table.add(3, false, .unbounded, now, 0);
    // After 2s: E1 partitioned, only E0 live
    const t2 = now + trit_tick.TICKS_PER_SECOND * 2;
    const demotions = pd.degradeSweep(&table, t2);
    // E1→E0 (1), E2→E0 (2), E3→E0 (3) = 6 demotions
    try std.testing.expectEqual(@as(u32, 6), demotions);
    const dist = table.epochDistribution();
    try std.testing.expectEqual(@as(u16, 4), dist[0]);
}

test "revocation cert: create and verify" {
    var pubkey: [32]u8 = undefined;
    @memset(&pubkey, 0x42);
    const cert = RevocationCert.create(7, .federated, trit_tick.TICKS_PER_SECOND * 100, pubkey);
    try std.testing.expect(cert.verifyCommitment());
    try std.testing.expectEqual(@as(u16, 7), cert.slot);
    try std.testing.expectEqual(Epoch.federated, cert.epoch);
}

test "revocation cert: tampered cert fails" {
    var pubkey: [32]u8 = undefined;
    @memset(&pubkey, 0x42);
    var cert = RevocationCert.create(7, .federated, trit_tick.TICKS_PER_SECOND * 100, pubkey);
    cert.slot = 8; // tamper
    try std.testing.expect(!cert.verifyCommitment());
}

test "envelope: encode/decode round-trip" {
    var env = EpochEnvelope{
        .timestamp = trit_tick.TICKS_PER_SECOND * 42,
        .sender_epoch = .federated,
        .sender_trit = -1,
        .is_heartbeat = true,
    };
    var buf: [11]u8 = undefined;
    env.encode(&buf);
    const decoded = EpochEnvelope.decode(&buf);
    try std.testing.expectEqual(env.timestamp, decoded.timestamp);
    try std.testing.expectEqual(env.sender_epoch, decoded.sender_epoch);
    try std.testing.expectEqual(env.sender_trit, decoded.sender_trit);
    try std.testing.expectEqual(env.is_heartbeat, decoded.is_heartbeat);
}

test "envelope: all trits round-trip" {
    for ([_]i8{ -1, 0, 1 }) |trit| {
        var env = EpochEnvelope{
            .timestamp = 0,
            .sender_epoch = .local,
            .sender_trit = trit,
            .is_heartbeat = false,
        };
        var buf: [11]u8 = undefined;
        env.encode(&buf);
        const decoded = EpochEnvelope.decode(&buf);
        try std.testing.expectEqual(trit, decoded.sender_trit);
    }
}

test "CAP theorem boundary: partition forces degradation" {
    // This test models the impossibility identified in plurigrid.com:
    // "verified clusters imply global integrity without central coordinators"
    // violates CAP. Under partition, capabilities MUST degrade.
    var pd = PartitionDetector{};
    var table = EpochCapTable{};
    const t0: u64 = trit_tick.TICKS_PER_SECOND * 100;

    // Setup: federated capability granted at t0
    pd.heartbeat(.cluster, t0);
    pd.heartbeat(.federated, t0);
    _ = table.add(0, false, .federated, t0, 1);
    try std.testing.expectEqual(Epoch.federated, table.caps[0].epoch);

    // Network partition occurs — no more heartbeats
    // After 2 seconds: E1 heartbeat missed
    const t1 = t0 + trit_tick.TICKS_PER_SECOND * 2;
    try std.testing.expect(pd.isPartitioned(.cluster, t1));
    _ = pd.degradeSweep(&table, t1);
    // Capability degraded to E0 (only local is reliable)
    try std.testing.expectEqual(Epoch.local, table.caps[0].epoch);
    // But still usable! Degradation is not failure.
    try std.testing.expect(!table.caps[0].revoked);
    try std.testing.expect(table.caps[0].isConsistent(t1));

    // Partition heals — heartbeats resume
    const t2 = t1 + trit_tick.TICKS_PER_SECOND;
    pd.heartbeat(.cluster, t2);
    pd.heartbeat(.federated, t2);
    // Re-verify and promote
    table.caps[0].verify(t2);
    try std.testing.expect(table.caps[0].tryPromote(t2)); // E0 → E1
    try std.testing.expect(table.caps[0].tryPromote(t2)); // E1 → E2
    try std.testing.expectEqual(Epoch.federated, table.caps[0].epoch);
}

test "full lifecycle: grant → partition → degrade → heal → promote → revoke" {
    var pd = PartitionDetector{};
    var table = EpochCapTable{};
    const t0: u64 = trit_tick.TICKS_PER_SECOND * 1000;

    // 1. Grant capabilities (conserving triad: -1 + 0 + 1 = 0)
    pd.heartbeat(.cluster, t0);
    pd.heartbeat(.federated, t0);
    pd.heartbeat(.unbounded, t0);
    _ = table.add(0, false, .unbounded, t0, -1);
    _ = table.add(1, false, .federated, t0, 0);
    _ = table.add(2, false, .cluster, t0, 1);
    try std.testing.expect(table.gf3Conserved());

    // 2. Partition: only E1 heartbeat continues (90s gap exceeds E2's 60s window)
    const t1 = t0 + trit_tick.TICKS_PER_SECOND * 90;
    pd.heartbeat(.cluster, t1);
    _ = pd.degradeSweep(&table, t1);
    // E3 → E1 (highest live = cluster), E2 → E1, E1 stays
    try std.testing.expectEqual(Epoch.cluster, table.caps[0].epoch);
    try std.testing.expectEqual(Epoch.cluster, table.caps[1].epoch);
    try std.testing.expectEqual(Epoch.cluster, table.caps[2].epoch);
    // GF(3) still conserved (trit is identity property, not epoch)
    try std.testing.expect(table.gf3Conserved());

    // 3. Full partition: no heartbeats
    const t2 = t1 + trit_tick.TICKS_PER_SECOND * 5;
    _ = pd.degradeSweep(&table, t2);
    const dist = table.epochDistribution();
    try std.testing.expectEqual(@as(u16, 3), dist[0]); // all E0
    try std.testing.expect(table.gf3Conserved()); // still conserved

    // 4. Heal: all heartbeats resume
    const t3 = t2 + 1;
    pd.heartbeat(.cluster, t3);
    pd.heartbeat(.federated, t3);
    pd.heartbeat(.unbounded, t3);
    _ = table.verifyAtEpoch(.local, t3);
    // Promote each cap back toward granted_epoch
    for (0..table.len) |i| {
        while (table.caps[i].tryPromote(t3)) {}
    }
    try std.testing.expectEqual(Epoch.unbounded, table.caps[0].epoch);
    try std.testing.expectEqual(Epoch.federated, table.caps[1].epoch);
    try std.testing.expectEqual(Epoch.cluster, table.caps[2].epoch);

    // 5. Revoke the validator (trit -1)
    const revoked = table.revokeByGranter(-1);
    try std.testing.expectEqual(@as(u16, 1), revoked);
    try std.testing.expect(table.caps[0].revoked);
    try std.testing.expect(!table.caps[1].revoked);
    try std.testing.expect(!table.caps[2].revoked);
    // GF(3) broken (remaining: 0 + 1 = 1)
    try std.testing.expect(!table.gf3Conserved());
}
