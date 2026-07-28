//! cap.zig — capabilities, facets, rights amplification, Horton provenance.
//!
//! A `Capability` is an unforgeable `(vat_id, actor_id)` pair plus a comptime-
//! checkable facet mask and a sender designation (Horton "who says what").
//!
//! - Facets:  `narrow(cap, allowed)` keeps only selectors in `allowed`.
//! - Amplify: `union_(a, b)` widens authority iff both name the same target;
//!            `intersect(a, b)` narrows.
//! - Horton:  every Message carries `sender: CapId`, and the receiver can
//!            verify it without a side-channel because caps are unforgeable
//!            within the vat (table indices, not pointers).

const std = @import("std");

pub const VatId = u32;
pub const ActorId = u32;
pub const SelectorMask = u64;

/// Convert a `[]const Selector` (slice of u6 indices) into a mask at comptime.
pub fn maskOf(comptime sels: []const u6) SelectorMask {
    var m: SelectorMask = 0;
    inline for (sels) |s| m |= (@as(SelectorMask, 1) << s);
    return m;
}

/// Universal facet — every selector permitted.
pub const FACET_FULL: SelectorMask = ~@as(SelectorMask, 0);
pub const FACET_EMPTY: SelectorMask = 0;

pub const CapId = u64; // packed (vat_id<<32 | actor_id), opaque to caller.

pub fn pack(vat: VatId, actor: ActorId) CapId {
    return (@as(CapId, vat) << 32) | @as(CapId, actor);
}
pub fn vatOf(c: CapId) VatId {
    return @intCast(c >> 32);
}
pub fn actorOf(c: CapId) ActorId {
    return @intCast(c & 0xFFFF_FFFF);
}

/// Forwarder-style revoker. Caller owns the Revoker; every Capability that
/// holds a pointer to it becomes unusable the moment `revoke()` is called.
/// Lifetime rule: the Revoker must outlive every wrapped cap, otherwise the
/// `?*Revoker` field dangles. Caps re-derived via `narrow`/`unionWith`/etc.
/// inherit the same revoker pointer, so revocation is transitive across
/// attenuation.
pub const Revoker = struct {
    revoked: bool = false,

    pub fn wrap(self: *Revoker, c: Capability) Capability {
        var out = c;
        out.revoker = self;
        return out;
    }

    pub fn revoke(self: *Revoker) void {
        self.revoked = true;
    }

    pub fn isAlive(self: *const Revoker) bool {
        return !self.revoked;
    }
};

/// Pick the earlier deadline of two optional millis-since-epoch stamps.
/// `null` means "no deadline"; null + x = x; null + null = null.
fn earliest(a: ?i64, b: ?i64) ?i64 {
    if (a == null) return b;
    if (b == null) return a;
    return @min(a.?, b.?);
}

/// Capability: target + facet + sender designation + optional revoker + optional expiry.
pub const Capability = struct {
    target: CapId,
    facet: SelectorMask = FACET_FULL,
    sender: CapId = 0, // 0 = "vat root" / external caller
    revoker: ?*Revoker = null,
    /// Wall-clock millis-since-Unix-epoch deadline. `null` = never expires
    /// by time alone. Vat reads this against its `now_ms_fn`.
    expires_at_ms: ?i64 = null,

    /// Narrow to a subset of selectors. Resulting cap is strictly weaker.
    pub fn narrow(self: Capability, allowed: SelectorMask) Capability {
        return .{ .target = self.target, .facet = self.facet & allowed, .sender = self.sender, .revoker = self.revoker, .expires_at_ms = self.expires_at_ms };
    }

    /// Rights amplification — combine two caps for the *same* target.
    /// Union widens, intersect narrows. Different targets is an error.
    /// Revoker preference: self's, falling back to other's. Combining caps
    /// from two distinct revokers is not supported — wrap the result in a
    /// fresh Revoker if you want "alive iff both alive" semantics.
    /// Expiry: result expires at the earliest of the two deadlines (the
    /// validity window of the combined cap is the intersection of source
    /// windows, regardless of whether facets are widened or narrowed).
    pub fn unionWith(self: Capability, other: Capability) error{DifferentTarget}!Capability {
        if (self.target != other.target) return error.DifferentTarget;
        return .{ .target = self.target, .facet = self.facet | other.facet, .sender = self.sender, .revoker = self.revoker orelse other.revoker, .expires_at_ms = earliest(self.expires_at_ms, other.expires_at_ms) };
    }
    pub fn intersectWith(self: Capability, other: Capability) error{DifferentTarget}!Capability {
        if (self.target != other.target) return error.DifferentTarget;
        return .{ .target = self.target, .facet = self.facet & other.facet, .sender = self.sender, .revoker = self.revoker orelse other.revoker, .expires_at_ms = earliest(self.expires_at_ms, other.expires_at_ms) };
    }

    /// True iff this cap permits selector index `s`.
    pub fn permits(self: Capability, s: u6) bool {
        return (self.facet & (@as(SelectorMask, 1) << s)) != 0;
    }

    /// True iff the cap is unrevoked (or has no revoker attached).
    pub fn isLive(self: Capability) bool {
        if (self.revoker) |r| return r.isAlive();
        return true;
    }

    /// True iff the cap has not passed its expiry deadline.
    /// Caps with `expires_at_ms = null` are always fresh.
    pub fn isFresh(self: Capability, now_ms: i64) bool {
        if (self.expires_at_ms) |t| return now_ms < t;
        return true;
    }

    /// Re-stamp the sender (used by the Vat at deliver time so the receiver
    /// always sees the *invoker's* designation, never the source's).
    pub fn withSender(self: Capability, sender: CapId) Capability {
        return .{ .target = self.target, .facet = self.facet, .sender = sender, .revoker = self.revoker, .expires_at_ms = self.expires_at_ms };
    }
};

/// Weak-ref table for distributed GC. Each export has a strong refcount and
/// a generation counter — when the holding session disconnects, the table
/// bumps the generation so any stale CapId from that session fails lookup.
pub const ExportTable = struct {
    const Slot = struct { strong: u32 = 0, generation: u32 = 0, alive: bool = false };
    slots: std.ArrayListUnmanaged(Slot) = .empty,

    pub fn init() ExportTable {
        return .{ .slots = .empty };
    }
    pub fn deinit(self: *ExportTable, allocator: std.mem.Allocator) void {
        self.slots.deinit(allocator);
    }

    /// Allocate a slot or revive a dead one. Returns ActorId.
    pub fn alloc(self: *ExportTable, allocator: std.mem.Allocator) !ActorId {
        for (self.slots.items, 0..) |*s, i| {
            if (!s.alive) {
                s.alive = true;
                s.strong = 1;
                s.generation +%= 1;
                return @intCast(i);
            }
        }
        try self.slots.append(allocator, .{ .strong = 1, .alive = true });
        return @intCast(self.slots.items.len - 1);
    }

    pub fn incref(self: *ExportTable, id: ActorId) void {
        if (id < self.slots.items.len and self.slots.items[id].alive) {
            self.slots.items[id].strong += 1;
        }
    }

    /// Returns true when the actor is now orphaned (strong==0).
    pub fn decref(self: *ExportTable, id: ActorId, n: u32) bool {
        if (id >= self.slots.items.len) return false;
        var slot = &self.slots.items[id];
        if (!slot.alive) return false;
        slot.strong -|= n;
        if (slot.strong == 0) {
            slot.alive = false;
            return true;
        }
        return false;
    }

    /// Disconnect drain — drop every slot held only by `session_gen`.
    /// Caller passes a predicate matching its own session bookkeeping.
    pub fn drainIf(self: *ExportTable, ctx: anytype, pred: fn (@TypeOf(ctx), ActorId) bool) usize {
        var dropped: usize = 0;
        for (self.slots.items, 0..) |*s, i| {
            if (s.alive and pred(ctx, @intCast(i))) {
                s.alive = false;
                s.strong = 0;
                dropped += 1;
            }
        }
        return dropped;
    }

    pub fn isAlive(self: *const ExportTable, id: ActorId) bool {
        return id < self.slots.items.len and self.slots.items[id].alive;
    }
};

// ---- Tests ------------------------------------------------------------------

test "facet narrow then invoke denied" {
    const READ: u6 = 0;
    const WRITE: u6 = 1;
    const cap = Capability{ .target = pack(1, 7), .facet = FACET_FULL };
    const ro = cap.narrow(maskOf(&.{READ}));
    try std.testing.expect(ro.permits(READ));
    try std.testing.expect(!ro.permits(WRITE));
}

test "amplify union widens, intersect narrows, different target errors" {
    const READ: u6 = 0;
    const WRITE: u6 = 1;
    const a = Capability{ .target = pack(1, 7), .facet = maskOf(&.{READ}) };
    const b = Capability{ .target = pack(1, 7), .facet = maskOf(&.{WRITE}) };
    const u = try a.unionWith(b);
    try std.testing.expect(u.permits(READ) and u.permits(WRITE));
    const i = try a.intersectWith(b);
    try std.testing.expect(!i.permits(READ) and !i.permits(WRITE));
    const c = Capability{ .target = pack(2, 7), .facet = FACET_FULL };
    try std.testing.expectError(error.DifferentTarget, a.unionWith(c));
}

test "ExportTable: alloc, incref/decref, drain" {
    const allocator = std.testing.allocator;
    var t = ExportTable.init();
    defer t.deinit(allocator);

    const id0 = try t.alloc(allocator);
    const id1 = try t.alloc(allocator);
    try std.testing.expect(t.isAlive(id0) and t.isAlive(id1));

    t.incref(id0);
    try std.testing.expect(!t.decref(id0, 1)); // 2 → 1, still alive
    try std.testing.expect(t.decref(id0, 1)); // 1 → 0, orphan
    try std.testing.expect(!t.isAlive(id0));

    // Drain id1 by session predicate.
    const Ctx = struct {
        target: ActorId,
        fn match(self: @This(), aid: ActorId) bool {
            return aid == self.target;
        }
    };
    const dropped = t.drainIf(Ctx{ .target = id1 }, Ctx.match);
    try std.testing.expectEqual(@as(usize, 1), dropped);
    try std.testing.expect(!t.isAlive(id1));
}

test "Horton withSender re-stamps designation" {
    const cap = Capability{ .target = pack(1, 7), .sender = pack(0, 0) };
    const stamped = cap.withSender(pack(2, 99));
    try std.testing.expectEqual(@as(CapId, pack(2, 99)), stamped.sender);
    try std.testing.expectEqual(cap.target, stamped.target);
}

test "Revoker: wrap preserves cap fields, revoke flips isLive, narrow inherits" {
    var rev = Revoker{};
    const c = Capability{ .target = pack(1, 7), .facet = FACET_FULL };
    const w = rev.wrap(c);
    try std.testing.expectEqual(c.target, w.target);
    try std.testing.expectEqual(c.facet, w.facet);
    try std.testing.expect(w.isLive());

    // narrow inherits the revoker — attenuation is transitive.
    const n = w.narrow(maskOf(&.{0}));
    try std.testing.expect(n.isLive());

    rev.revoke();
    try std.testing.expect(!w.isLive());
    try std.testing.expect(!n.isLive());
}

test "Revoker: cap with no revoker is always alive" {
    const c = Capability{ .target = pack(1, 7) };
    try std.testing.expect(c.isLive());
}

test "expires_at_ms: isFresh boundary, narrow inherits, intersect picks earliest" {
    const a = Capability{ .target = pack(1, 7), .expires_at_ms = 1000 };
    try std.testing.expect(a.isFresh(999));
    try std.testing.expect(!a.isFresh(1000)); // strict <, deadline-inclusive expiry
    try std.testing.expect(!a.isFresh(1001));

    const READ: u6 = 0;
    const n = a.narrow(maskOf(&.{READ}));
    try std.testing.expectEqual(@as(?i64, 1000), n.expires_at_ms);

    const b = Capability{ .target = pack(1, 7), .expires_at_ms = 500 };
    const inter = try a.intersectWith(b);
    try std.testing.expectEqual(@as(?i64, 500), inter.expires_at_ms);

    const c_no_expiry = Capability{ .target = pack(1, 7) };
    const u = try a.unionWith(c_no_expiry);
    try std.testing.expectEqual(@as(?i64, 1000), u.expires_at_ms); // null + 1000 = 1000
}

test "expires_at_ms: cap without deadline is always fresh" {
    const c = Capability{ .target = pack(1, 7) };
    try std.testing.expect(c.isFresh(0));
    try std.testing.expect(c.isFresh(std.math.maxInt(i64)));
}
