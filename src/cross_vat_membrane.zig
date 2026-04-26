//! cross_vat_membrane.zig — membrane that spans two vats.
//!
//! `membrane.zig` confines caps within a single vat: the forwarder lives in
//! the same vat as the inner target, and the membrane just rebrands the
//! identity. `CrossVatMembrane` differs in one structural way — the
//! forwarder lives in a *different* vat (`dest_vat`) than the inner target
//! (which lives in `source_vat`). Sends to the outer cap therefore traverse
//! a vat boundary on every relay.
//!
//! Design:
//!   - The outer cap targets a freshly-spawned `CrossForwarder` in `dest_vat`.
//!   - On message arrival in `dest_vat`'s turn loop, the forwarder calls
//!     `source_vat.send(...)` to relay into `source_vat`'s mailbox.
//!   - Because `Vat.send` only mutates the target's mailbox (not its handler
//!     state), and Zig vats are single-threaded by design, this is safe even
//!     when `source_vat` is mid-quiesce — the relay just enqueues.
//!
//! Same security posture as `membrane.zig`:
//!   - Identity hiding: outer cap's `(vat, actor)` ≠ inner cap's.
//!   - Bulk revocation: shared `Revoker` kills every cross-vat cap in one flip.
//!   - Policy attenuation: `policy_facet` narrows authority at the boundary.
//!   - In-flight drop: messages already queued in the forwarder when the
//!     membrane is killed are not relayed. No late delivery with rescinded
//!     authority.
//!
//! Wire-side extension: this module relays via direct `Vat.send`, so it only
//! works for vats in the same process. A network-spanning version would swap
//! the relay for `ocapn_session.send` — the `CrossForwarder` shape is the
//! same, only its `handle` body changes. That is left for a future module
//! once `ocapn_session` exposes a stable per-vat send entry point.

const std = @import("std");
const cap = @import("cap.zig");
const vat = @import("vat.zig");

pub const CrossVatMembrane = struct {
    /// Vat where the inner cap lives. The forwarder relays into this vat.
    source_vat: *vat.Vat,
    /// Vat where the forwarder is spawned. The outer cap targets this vat.
    dest_vat: *vat.Vat,
    /// Shared revoker for bulk kill across every wrapped cap.
    revoker: *cap.Revoker,
    /// Policy attenuation applied at the boundary.
    policy_facet: cap.SelectorMask = cap.FACET_FULL,

    pub fn init(source: *vat.Vat, dest: *vat.Vat, revoker: *cap.Revoker) CrossVatMembrane {
        return .{ .source_vat = source, .dest_vat = dest, .revoker = revoker };
    }

    /// Wrap an inner cap (must target `source_vat`) as a forwarder in
    /// `dest_vat`. Returns the outer cap pointing at the forwarder, narrowed
    /// by `policy_facet` and bound to the membrane's revoker.
    pub fn wrap(self: *CrossVatMembrane, inner: cap.Capability) !cap.Capability {
        if (cap.vatOf(inner.target) != self.source_vat.id) return error.InnerNotInSourceVat;
        const fwd = try self.dest_vat.spawn(CrossForwarder, .{
            .source = self.source_vat,
            .inner = inner,
            .rev = self.revoker,
        });
        return self.revoker.wrap(fwd.narrow(self.policy_facet));
    }

    pub fn kill(self: *CrossVatMembrane) void {
        self.revoker.revoke();
    }
};

const CrossForwarder = struct {
    source: *vat.Vat,
    inner: cap.Capability,
    rev: *const cap.Revoker,

    pub const SELECTORS: cap.SelectorMask = cap.FACET_FULL;

    pub fn handle(self: *CrossForwarder, _: *vat.Vat, msg: vat.Message) !vat.Become {
        if (!self.rev.isAlive()) return .terminate;
        const sender = cap.Capability{ .target = msg.sender };
        self.source.send(sender, self.inner, msg.selector, msg.payload) catch |e| switch (e) {
            error.Backpressure => return .same, // mailbox-level lag signal carries it
            error.Revoked, error.Expired => return .terminate,
            else => return e,
        };
        return .same;
    }
};

// ---- Tests ------------------------------------------------------------------

const testing = std.testing;

const Recorder = struct {
    log: *std.ArrayList(u8),
    alloc: std.mem.Allocator,
    pub const SELECTORS: cap.SelectorMask = cap.maskOf(&.{ 0, 1 });
    pub fn handle(self: *Recorder, _: *vat.Vat, m: vat.Message) !vat.Become {
        try self.log.appendSlice(self.alloc, m.payload);
        return .same;
    }
};

test "cross-vat membrane: send to outer in dest vat reaches inner in source vat" {
    const alloc = testing.allocator;
    var source = vat.Vat.init(alloc, 1);
    defer source.deinit();
    var dest = vat.Vat.init(alloc, 2);
    defer dest.deinit();

    var log: std.ArrayList(u8) = .{};
    defer log.deinit(alloc);
    const inner = try source.spawn(Recorder, .{ .log = &log, .alloc = alloc });

    var rev = cap.Revoker{};
    var memb = CrossVatMembrane.init(&source, &dest, &rev);
    const outer = try memb.wrap(inner);

    // Outer is in dest (vat 2); inner is in source (vat 1).
    try testing.expectEqual(@as(cap.VatId, 2), cap.vatOf(outer.target));
    try testing.expectEqual(@as(cap.VatId, 1), cap.vatOf(inner.target));

    const sender = cap.Capability{ .target = cap.pack(2, 0) };
    try dest.send(sender, outer, 0, "across");
    _ = try dest.quiesce(10); // forwarder runs, relays into source
    _ = try source.quiesce(10); // recorder runs
    try testing.expectEqualStrings("across", log.items);
}

test "cross-vat membrane: kill revokes outer caps and stops relay" {
    const alloc = testing.allocator;
    var source = vat.Vat.init(alloc, 1);
    defer source.deinit();
    var dest = vat.Vat.init(alloc, 2);
    defer dest.deinit();

    var log: std.ArrayList(u8) = .{};
    defer log.deinit(alloc);
    const inner = try source.spawn(Recorder, .{ .log = &log, .alloc = alloc });

    var rev = cap.Revoker{};
    var memb = CrossVatMembrane.init(&source, &dest, &rev);
    const outer = try memb.wrap(inner);

    const sender = cap.Capability{ .target = cap.pack(2, 0) };
    try dest.send(sender, outer, 0, "before");
    _ = try dest.quiesce(10);
    _ = try source.quiesce(10);
    try testing.expectEqualStrings("before", log.items);

    memb.kill();
    try testing.expectError(error.Revoked, dest.send(sender, outer, 0, "after"));
}

test "cross-vat membrane: rejects inner that doesn't target source_vat" {
    const alloc = testing.allocator;
    var source = vat.Vat.init(alloc, 1);
    defer source.deinit();
    var dest = vat.Vat.init(alloc, 2);
    defer dest.deinit();
    var other = vat.Vat.init(alloc, 3);
    defer other.deinit();

    var log: std.ArrayList(u8) = .{};
    defer log.deinit(alloc);
    const wrong_vat_inner = try other.spawn(Recorder, .{ .log = &log, .alloc = alloc });

    var rev = cap.Revoker{};
    var memb = CrossVatMembrane.init(&source, &dest, &rev);
    try testing.expectError(error.InnerNotInSourceVat, memb.wrap(wrong_vat_inner));
}

test "cross-vat membrane: in-flight drop on kill (forwarder self-terminates)" {
    const alloc = testing.allocator;
    var source = vat.Vat.init(alloc, 1);
    defer source.deinit();
    var dest = vat.Vat.init(alloc, 2);
    defer dest.deinit();

    var log: std.ArrayList(u8) = .{};
    defer log.deinit(alloc);
    const inner = try source.spawn(Recorder, .{ .log = &log, .alloc = alloc });

    var rev = cap.Revoker{};
    var memb = CrossVatMembrane.init(&source, &dest, &rev);
    const outer = try memb.wrap(inner);

    const sender = cap.Capability{ .target = cap.pack(2, 0) };
    try dest.send(sender, outer, 0, "queued");
    memb.kill(); // before dest quiesce: forwarder sees rev.isAlive()=false → terminate
    _ = try dest.quiesce(10);
    _ = try source.quiesce(10);
    try testing.expectEqual(@as(usize, 0), log.items.len);
}

test "cross-vat membrane: policy_facet narrows authority at boundary" {
    const alloc = testing.allocator;
    var source = vat.Vat.init(alloc, 1);
    defer source.deinit();
    var dest = vat.Vat.init(alloc, 2);
    defer dest.deinit();

    var log: std.ArrayList(u8) = .{};
    defer log.deinit(alloc);
    const inner = try source.spawn(Recorder, .{ .log = &log, .alloc = alloc });

    var rev = cap.Revoker{};
    var memb = CrossVatMembrane.init(&source, &dest, &rev);
    memb.policy_facet = cap.maskOf(&.{0});
    const outer = try memb.wrap(inner);

    const sender = cap.Capability{ .target = cap.pack(2, 0) };
    try dest.send(sender, outer, 0, "ok");
    try testing.expectError(error.FacetDenies, dest.send(sender, outer, 1, "no"));
    _ = try dest.quiesce(10);
    _ = try source.quiesce(10);
    try testing.expectEqualStrings("ok", log.items);
}
