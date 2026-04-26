//! epoch_bridge.zig — adapt wire-side EpochCapRef to runtime cap.Revoker.
//!
//! `cap.Capability` carries an optional `*Revoker` that gates `isLive()`.
//! `epoch_capability.EpochCapRef` carries its own freshness/consistency
//! lifecycle in glimpse-tick units, including auto-degradation under
//! partition. This module bridges the two: an `EpochRevoker` is a
//! `cap.Revoker` whose `revoked` flag is driven by an `EpochCapRef`'s
//! `isConsistent(now)` check.
//!
//! Usage:
//!   1. Allocate an `EpochCapRef` in your wire-side `EpochCapTable`.
//!   2. Wrap it in an `EpochRevoker` (caller manages lifetime).
//!   3. Build a `cap.Capability` via `epochBackedCap()` — its target/facet
//!      come from the runtime side, its liveness from the wire side.
//!   4. On every heartbeat / before every send, call `revoker.refresh(now)`
//!      to re-evaluate the underlying epoch state. If `EpochCapRef` is
//!      revoked, partition-demoted past visibility, or stale beyond its
//!      consistency window, the bridged `cap.Revoker` flips to revoked
//!      and the runtime `vat.send` will return `error.Revoked`.
//!
//! One-way semantics: this is a runtime ← wire bridge. Once an
//! `EpochCapRef` revokes, the runtime cap goes dead permanently — there is
//! no path back. If the wire-side `EpochCapRef` later promotes (e.g. via
//! `tryPromote` after partition heals), the bridged runtime cap stays
//! revoked. Callers that want re-promotability should not bridge through
//! this module; they should query the `EpochCapRef` at each send-site.

const std = @import("std");
const cap = @import("cap.zig");
const epoch_capability = @import("epoch_capability.zig");

pub const EpochCapRef = epoch_capability.EpochCapRef;
pub const Epoch = epoch_capability.Epoch;

/// A `cap.Revoker` whose liveness mirrors an `EpochCapRef` consistency check.
/// Caller drives the bridge by calling `refresh(now)` whenever the underlying
/// epoch state may have changed (heartbeat tick, before send, on partition
/// detector callback, etc).
pub const EpochRevoker = struct {
    revoker: cap.Revoker = .{},
    ecr: *EpochCapRef,

    pub fn init(ecr: *EpochCapRef) EpochRevoker {
        return .{ .ecr = ecr };
    }

    /// Re-evaluate the underlying epoch ref. Once flipped to revoked, stays
    /// revoked even if the underlying `EpochCapRef` later promotes — runtime
    /// caps cannot be un-revoked.
    pub fn refresh(self: *EpochRevoker, now: u64) void {
        if (self.revoker.revoked) return; // already terminal
        if (self.ecr.revoked or !self.ecr.isConsistent(now)) {
            self.revoker.revoke();
        }
    }
};

/// Build a runtime cap pointing at `target` with `facet` authority, gated on
/// the lifetime of `revoker`'s underlying `EpochCapRef`.
pub fn epochBackedCap(
    revoker: *EpochRevoker,
    target: cap.CapId,
    facet: cap.SelectorMask,
) cap.Capability {
    return revoker.revoker.wrap(.{
        .target = target,
        .facet = facet,
    });
}

// ---- Tests ------------------------------------------------------------------

const testing = std.testing;

test "fresh ecr at E0: bridged cap is live" {
    var ecr = EpochCapRef.init(7, false, .local, 0, 0);
    var rev = EpochRevoker.init(&ecr);
    rev.refresh(0);

    const c = epochBackedCap(&rev, cap.pack(1, 7), cap.FACET_FULL);
    try testing.expect(c.isLive());
}

test "explicitly-revoked ecr → bridged cap dies on next refresh" {
    var ecr = EpochCapRef.init(7, false, .local, 0, 0);
    var rev = EpochRevoker.init(&ecr);
    const c = epochBackedCap(&rev, cap.pack(1, 7), cap.FACET_FULL);
    try testing.expect(c.isLive());

    ecr.revoke();
    rev.refresh(0);
    try testing.expect(!c.isLive());
}

test "stale E1 ecr past consistency window → bridged cap revokes after refresh" {
    // E1 window = TICKS_PER_SECOND. Verify by passing in a tick "now" past
    // last_verified by more than the window.
    var ecr = EpochCapRef.init(7, false, .cluster, 1000, 0);
    var rev = EpochRevoker.init(&ecr);
    const c = epochBackedCap(&rev, cap.pack(1, 7), cap.FACET_FULL);

    // Within window — still alive.
    rev.refresh(1000 + epoch_capability.E1_WINDOW - 1);
    try testing.expect(c.isLive());

    // Past window: degrade, isConsistent false at original epoch.
    _ = ecr.checkAndDegrade(1000 + epoch_capability.E1_WINDOW + 1);
    rev.refresh(1000 + epoch_capability.E1_WINDOW + 1);
    // After degrade to .local, isConsistent becomes true again — but if the
    // ecr was revoked or fully degraded out, the bridge would catch it.
    // For this test we explicitly force the situation by re-setting epoch.
    // The real failure path is: ecr stays at .cluster (no checkAndDegrade
    // call) and refresh sees isConsistent == false.
    ecr.epoch = .cluster;
    ecr.last_verified = 0;
    rev.refresh(epoch_capability.E1_WINDOW + 1);
    try testing.expect(!c.isLive());
}

test "refresh is monotonic: once revoked, never re-lives" {
    var ecr = EpochCapRef.init(7, false, .local, 0, 0);
    var rev = EpochRevoker.init(&ecr);
    const c = epochBackedCap(&rev, cap.pack(1, 7), cap.FACET_FULL);

    ecr.revoke();
    rev.refresh(0);
    try testing.expect(!c.isLive());

    // Pretend the wire side somehow un-revoked (it can't, but humor the test).
    ecr.revoked = false;
    rev.refresh(0);
    try testing.expect(!c.isLive()); // runtime cap stays dead
}
