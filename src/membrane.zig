//! membrane.zig — translation barrier between capability domains.
//!
//! A `Membrane` is a one-way wrapper that turns an *inner* capability
//! (the real authority you don't want to hand over directly) into an
//! *outer* capability (a freshly-spawned forwarder actor that the other
//! domain receives instead). The forwarder relays messages to the inner
//! cap; the recipient never learns the inner CapId.
//!
//! Properties:
//!   - **Pseudonymous identity.** Outer side sees the forwarder's `(vat, actor)`,
//!     not the inner target's. Identity comparison across the membrane fails
//!     — wrappers are not the same as their referents.
//!   - **Bulk revocation.** A single `Revoker` is shared by every cap that
//!     crossed the membrane. `kill()` revokes them all in one flip.
//!   - **Policy attenuation.** `policy_facet` narrows authority on every
//!     crossing — e.g., a read-only membrane: `policy_facet = maskOf(&.{READ})`.
//!   - **Defense in depth.** Kill also poisons the forwarders themselves —
//!     a holder of the raw forwarder CapId (bypassing the outer revoker)
//!     gets `.terminate` on the next message instead of a successful relay.
//!
//! What this *does not* do:
//!   - Cross-vat translation. Forwarders live in the host vat. For cross-
//!     vat boundaries you also need the wire-side `ocapn_session` to translate
//!     export/answer positions; that's a separate piece of work.
//!   - Bidirectional symmetry. This is one-way: caps flowing inner → outer
//!     get wrapped. Caps flowing the other direction (e.g., a callback the
//!     outer side hands inward) need their own membrane in the reverse
//!     direction. Pair two `Membrane`s for full bidirectional confinement.
//!
//! Lifetime: the `Revoker` pointer must outlive every cap the membrane has
//! wrapped (or transitively narrowed/restamped). Keep the Revoker on the
//! heap or in a stable stack frame for the membrane's full duration.

const std = @import("std");
const cap = @import("cap.zig");
const vat = @import("vat.zig");

pub const Membrane = struct {
    host: *vat.Vat,
    revoker: *cap.Revoker,
    /// Mask AND-ed into every wrapped cap's facet. Default: full authority,
    /// meaning "preserve whatever the inner cap permits". Override to
    /// attenuate at the membrane boundary (e.g. read-only crossing).
    policy_facet: cap.SelectorMask = cap.FACET_FULL,

    pub fn init(host: *vat.Vat, revoker: *cap.Revoker) Membrane {
        return .{ .host = host, .revoker = revoker };
    }

    /// Wrap `inner` as a forwarder actor in `host`. Returns an outer cap
    /// pointing at the forwarder, narrowed by `policy_facet` and bound to
    /// the membrane's revoker.
    pub fn wrap(self: *Membrane, inner: cap.Capability) !cap.Capability {
        const fwd = try self.host.spawn(Forwarder, .{
            .inner = inner,
            .rev = self.revoker,
        });
        return self.revoker.wrap(fwd.narrow(self.policy_facet));
    }

    /// Revoke the entire membrane. All previously-wrapped caps fail their
    /// next `isLive()` check; forwarders themselves self-terminate when
    /// reached via any other path.
    pub fn kill(self: *Membrane) void {
        self.revoker.revoke();
    }
};

/// Forwarder behavior — relays each message to its inner cap, terminates
/// itself when the membrane is killed. SELECTORS = FACET_FULL because the
/// authority gate lives at the *outer* cap (`policy_facet` narrowed it);
/// the inner cap re-enforces its own facet during the relay.
const Forwarder = struct {
    inner: cap.Capability,
    rev: *const cap.Revoker,

    pub const SELECTORS: cap.SelectorMask = cap.FACET_FULL;

    pub fn handle(self: *Forwarder, host: *vat.Vat, msg: vat.Message) !vat.Become {
        if (!self.rev.isAlive()) return .terminate;
        const sender = cap.Capability{ .target = msg.sender };
        host.send(sender, self.inner, msg.selector, msg.payload) catch |e| switch (e) {
            // Inner-side backpressure shouldn't kill the forwarder; the
            // mailbox-level lagged counter is the durable signal.
            error.Backpressure => return .same,
            // Inner cap revoked or expired — forwarder has nothing left to
            // forward, terminate.
            error.Revoked, error.Expired => return .terminate,
            else => return e,
        };
        return .same;
    }
};

// ---- Tests ------------------------------------------------------------------

const testing = std.testing;

const Recorder = struct {
    log: *std.ArrayListUnmanaged(u8),
    alloc: std.mem.Allocator,
    pub const SELECTORS: cap.SelectorMask = cap.maskOf(&.{ 0, 1 });
    pub fn handle(self: *Recorder, _: *vat.Vat, m: vat.Message) !vat.Become {
        try self.log.appendSlice(self.alloc, m.payload);
        return .same;
    }
};

test "membrane: outer send relays to inner" {
    const alloc = testing.allocator;
    var v = vat.Vat.init(alloc, 1);
    defer v.deinit();

    var log: std.ArrayListUnmanaged(u8) = .empty;
    defer log.deinit(alloc);
    const inner = try v.spawn(Recorder, .{ .log = &log, .alloc = alloc });

    var rev = cap.Revoker{};
    var memb = Membrane.init(&v, &rev);
    const outer = try memb.wrap(inner);

    // The outer cap targets the forwarder, NOT the inner Recorder.
    try testing.expect(outer.target != inner.target);

    const sender = cap.Capability{ .target = cap.pack(1, 0) };
    try v.send(sender, outer, 0, "hello");
    _ = try v.quiesce(10);
    try testing.expectEqualStrings("hello", log.items);
}

test "membrane: kill revokes the outer cap" {
    const alloc = testing.allocator;
    var v = vat.Vat.init(alloc, 1);
    defer v.deinit();

    var log: std.ArrayListUnmanaged(u8) = .empty;
    defer log.deinit(alloc);
    const inner = try v.spawn(Recorder, .{ .log = &log, .alloc = alloc });

    var rev = cap.Revoker{};
    var memb = Membrane.init(&v, &rev);
    const outer = try memb.wrap(inner);

    const sender = cap.Capability{ .target = cap.pack(1, 0) };
    try v.send(sender, outer, 0, "before");
    // Drain BEFORE kill — kill drops anything still in the forwarder's mailbox.
    _ = try v.quiesce(10);
    memb.kill();
    try testing.expectError(error.Revoked, v.send(sender, outer, 0, "after"));
    try testing.expectEqualStrings("before", log.items);
}

test "membrane: forwarder self-terminates if reached via raw CapId after kill" {
    const alloc = testing.allocator;
    var v = vat.Vat.init(alloc, 1);
    defer v.deinit();

    var log: std.ArrayListUnmanaged(u8) = .empty;
    defer log.deinit(alloc);
    const inner = try v.spawn(Recorder, .{ .log = &log, .alloc = alloc });

    var rev = cap.Revoker{};
    var memb = Membrane.init(&v, &rev);
    const outer = try memb.wrap(inner);

    // Reconstruct a "raw" cap to the forwarder, bypassing the membrane revoker.
    // This simulates an attacker who learned the forwarder's CapId by other means.
    const raw_fwd = cap.Capability{ .target = outer.target, .facet = cap.FACET_FULL };
    const sender = cap.Capability{ .target = cap.pack(1, 0) };

    memb.kill();
    // First send is accepted (mailbox push) but the handler self-terminates.
    try v.send(sender, raw_fwd, 0, "ignored");
    _ = try v.quiesce(10);
    // Recorder never received the relay — forwarder terminated before forwarding.
    try testing.expectEqual(@as(usize, 0), log.items.len);
    // Second send fails because the forwarder is now terminated.
    try testing.expectError(error.Terminated, v.send(sender, raw_fwd, 0, "denied"));
}

test "membrane: policy_facet narrows authority at the boundary" {
    const alloc = testing.allocator;
    var v = vat.Vat.init(alloc, 1);
    defer v.deinit();

    var log: std.ArrayListUnmanaged(u8) = .empty;
    defer log.deinit(alloc);
    const inner = try v.spawn(Recorder, .{ .log = &log, .alloc = alloc });
    // Recorder accepts selectors {0, 1}.

    var rev = cap.Revoker{};
    var memb = Membrane.init(&v, &rev);
    memb.policy_facet = cap.maskOf(&.{0}); // only selector 0 crosses
    const outer = try memb.wrap(inner);

    const sender = cap.Capability{ .target = cap.pack(1, 0) };
    try v.send(sender, outer, 0, "ok"); // permitted by policy
    try testing.expectError(error.FacetDenies, v.send(sender, outer, 1, "no"));

    _ = try v.quiesce(10);
    try testing.expectEqualStrings("ok", log.items);
}

test "membrane: kill drops in-flight messages still in the forwarder's mailbox" {
    // Property: kill is *immediate* — any message queued in the forwarder
    // before kill but not yet relayed is dropped, not delivered. This is
    // the correct security posture: you don't want kill to leave a trickle
    // of late deliveries with authority you've already revoked.
    const alloc = testing.allocator;
    var v = vat.Vat.init(alloc, 1);
    defer v.deinit();

    var log: std.ArrayListUnmanaged(u8) = .empty;
    defer log.deinit(alloc);
    const inner = try v.spawn(Recorder, .{ .log = &log, .alloc = alloc });

    var rev = cap.Revoker{};
    var memb = Membrane.init(&v, &rev);
    const outer = try memb.wrap(inner);

    const sender = cap.Capability{ .target = cap.pack(1, 0) };
    try v.send(sender, outer, 0, "queued");
    memb.kill(); // before quiesce — message is still in forwarder's mailbox
    _ = try v.quiesce(10);
    try testing.expectEqual(@as(usize, 0), log.items.len);
}

test "membrane: nested wraps share the revoker (transitive kill)" {
    const alloc = testing.allocator;
    var v = vat.Vat.init(alloc, 1);
    defer v.deinit();

    var log: std.ArrayListUnmanaged(u8) = .empty;
    defer log.deinit(alloc);
    const inner = try v.spawn(Recorder, .{ .log = &log, .alloc = alloc });

    var rev = cap.Revoker{};
    var memb = Membrane.init(&v, &rev);
    const outer1 = try memb.wrap(inner);
    const outer2 = try memb.wrap(outer1); // double-wrapped

    const sender = cap.Capability{ .target = cap.pack(1, 0) };
    try v.send(sender, outer2, 0, "deep");
    _ = try v.quiesce(10); // let the relay chain complete before kill
    memb.kill();
    try testing.expectError(error.Revoked, v.send(sender, outer2, 0, "denied"));
    try testing.expectError(error.Revoked, v.send(sender, outer1, 0, "denied"));
    try testing.expectEqualStrings("deep", log.items);
}
