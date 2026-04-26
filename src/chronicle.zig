//! chronicle.zig — passive capability event sidecar.
//!
//! A Chronicle aggregates capability-layer events from multiple sources
//! into a single append-only timeline:
//!
//!   - **Vat turns** (from `vat.TurnRecord` via `vat_replay` callback)
//!   - **Cap minting** (`spawn` returned a fresh cap with a given facet)
//!   - **Revocation flips** (a `Revoker` transitioned to revoked)
//!   - **Sealer operations** (a sealed envelope was issued or opened)
//!   - **Device-key signatures** (sign/verify events with seq + vat_id)
//!   - **Membrane lifecycle** (wrap, kill, in-flight drop counts)
//!
//! Passive: Chronicle does NOT alter the protocol; it only observes. A
//! Chronicle that crashes does not break the vat. Sources push events via
//! `record(...)`; Chronicle never calls back into the runtime.
//!
//! Use cases:
//!   1. **Forensics**: after an incident, replay the chronicle to see who
//!      held what authority when. The events are causally ordered by
//!      `(monotonic_index, source_kind)`.
//!   2. **Audit**: regulators / governance need a tamper-evident record of
//!      capability flow. The chronicle's `Blake3` running hash chains
//!      events so any post-hoc tampering invalidates downstream entries.
//!   3. **Verification cross-checks**: replay the chronicle through a
//!      fresh `Verifier`/vat and confirm the same outcomes — divergence
//!      indicates a bug or a compromised execution.
//!
//! Storage: in-memory `std.ArrayList(Event)`. For durable storage, a wire-
//! side serializer can stream events out as Syrup records (matching the
//! `vat_turn` encoding from `vat_replay.zig`).

const std = @import("std");
const cap = @import("cap.zig");

const Allocator = std.mem.Allocator;
const Blake3 = std.crypto.hash.Blake3;
pub const HASH_LEN: usize = 32;

pub const EventKind = enum(u8) {
    vat_turn = 1,
    cap_mint = 2,
    cap_narrow = 3,
    revoker_flip = 4,
    cap_expired = 5,
    sealer_seal = 6,
    sealer_unseal = 7,
    device_sign = 8,
    device_verify = 9,
    membrane_wrap = 10,
    membrane_kill = 11,
    membrane_drop = 12,
};

pub const Event = struct {
    /// Monotonic index assigned by Chronicle on receive. Together with
    /// `prev_hash`, gives total ordering even when sources push concurrently
    /// (caller serializes pushes; Chronicle does not).
    index: u64,
    /// Wall-clock (or virtual clock) millis at the moment of recording.
    /// Sources pass their own clock; Chronicle does not impose one.
    now_ms: i64,
    kind: EventKind,
    /// Vat associated with the event. For events that span vats (e.g.
    /// cross-vat membrane), the source-side vat is recorded here.
    vat_id: cap.VatId,
    /// Subject identifier — actor index, revoker pointer hash, signature seq,
    /// etc. Interpretation depends on `kind`. For caps it is the `CapId`.
    subject: u64,
    /// Free-form numeric metadata (selector mask, payload length, signature
    /// seq, etc). Up to 4 slots, kind-dependent semantics.
    meta: [4]u64,
    /// BLAKE3 hash of `(prev_hash || index || now_ms || kind || vat_id ||
    /// subject || meta)` — chains events so post-hoc tampering invalidates
    /// the entire suffix.
    chain_hash: [HASH_LEN]u8,
};

/// Append-only capability event log with running BLAKE3 chain hash.
pub const Chronicle = struct {
    events: std.ArrayList(Event),
    /// Hash of the previous event (or zero for genesis). Updated on every
    /// `record`. Verifiers re-compute and compare to detect tampering.
    head_hash: [HASH_LEN]u8 = std.mem.zeroes([HASH_LEN]u8),
    next_index: u64 = 0,

    pub fn init() Chronicle {
        return .{ .events = .{} };
    }

    pub fn deinit(self: *Chronicle, allocator: Allocator) void {
        self.events.deinit(allocator);
    }

    /// Record an event. The Chronicle assigns the index, computes the chain
    /// hash, and updates `head_hash`. Returns the assigned index.
    pub fn record(
        self: *Chronicle,
        allocator: Allocator,
        now_ms: i64,
        kind: EventKind,
        vat_id: cap.VatId,
        subject: u64,
        meta: [4]u64,
    ) !u64 {
        const index = self.next_index;
        self.next_index += 1;
        const chain_hash = computeHash(self.head_hash, index, now_ms, kind, vat_id, subject, meta);
        try self.events.append(allocator, .{
            .index = index,
            .now_ms = now_ms,
            .kind = kind,
            .vat_id = vat_id,
            .subject = subject,
            .meta = meta,
            .chain_hash = chain_hash,
        });
        self.head_hash = chain_hash;
        return index;
    }

    /// Verify the entire chronicle by recomputing every chain hash from
    /// genesis. Returns the index of the first mismatch, or null if the
    /// chronicle is intact.
    pub fn verifyChain(self: *const Chronicle) ?u64 {
        var prev: [HASH_LEN]u8 = std.mem.zeroes([HASH_LEN]u8);
        for (self.events.items) |e| {
            const expected = computeHash(prev, e.index, e.now_ms, e.kind, e.vat_id, e.subject, e.meta);
            if (!std.mem.eql(u8, &expected, &e.chain_hash)) return e.index;
            prev = e.chain_hash;
        }
        return null;
    }

    pub fn len(self: *const Chronicle) usize {
        return self.events.items.len;
    }

    /// Filter by kind — useful for audits that only care about, e.g.,
    /// every revoker_flip across the timeline.
    pub fn countByKind(self: *const Chronicle, kind: EventKind) usize {
        var n: usize = 0;
        for (self.events.items) |e| {
            if (e.kind == kind) n += 1;
        }
        return n;
    }

    // ---- Convenience recorders for each event kind --------------------------

    pub fn recordVatTurn(
        self: *Chronicle,
        allocator: Allocator,
        now_ms: i64,
        vat_id: cap.VatId,
        target_actor: cap.ActorId,
        turn_seq: u64,
        selector: u64,
        payload_len: u64,
    ) !u64 {
        return self.record(allocator, now_ms, .vat_turn, vat_id, @as(u64, target_actor), .{ turn_seq, selector, payload_len, 0 });
    }

    pub fn recordRevokerFlip(
        self: *Chronicle,
        allocator: Allocator,
        now_ms: i64,
        vat_id: cap.VatId,
        revoker_id: u64,
    ) !u64 {
        return self.record(allocator, now_ms, .revoker_flip, vat_id, revoker_id, .{ 0, 0, 0, 0 });
    }

    pub fn recordCapMint(
        self: *Chronicle,
        allocator: Allocator,
        now_ms: i64,
        vat_id: cap.VatId,
        cap_id: cap.CapId,
        facet: cap.SelectorMask,
    ) !u64 {
        return self.record(allocator, now_ms, .cap_mint, vat_id, cap_id, .{ facet, 0, 0, 0 });
    }

    pub fn recordDeviceSign(
        self: *Chronicle,
        allocator: Allocator,
        now_ms: i64,
        vat_id: cap.VatId,
        pubkey_fingerprint: u64,
        seq: u64,
        msg_len: u64,
    ) !u64 {
        return self.record(allocator, now_ms, .device_sign, vat_id, pubkey_fingerprint, .{ seq, msg_len, 0, 0 });
    }

    pub fn recordSealerOp(
        self: *Chronicle,
        allocator: Allocator,
        now_ms: i64,
        vat_id: cap.VatId,
        kind: EventKind, // .sealer_seal or .sealer_unseal
        envelope_hash: u64,
        plaintext_len: u64,
    ) !u64 {
        std.debug.assert(kind == .sealer_seal or kind == .sealer_unseal);
        return self.record(allocator, now_ms, kind, vat_id, envelope_hash, .{ plaintext_len, 0, 0, 0 });
    }

    pub fn recordMembraneEvent(
        self: *Chronicle,
        allocator: Allocator,
        now_ms: i64,
        vat_id: cap.VatId,
        kind: EventKind, // .membrane_wrap, .membrane_kill, .membrane_drop
        membrane_id: u64,
        meta_value: u64,
    ) !u64 {
        std.debug.assert(kind == .membrane_wrap or kind == .membrane_kill or kind == .membrane_drop);
        return self.record(allocator, now_ms, kind, vat_id, membrane_id, .{ meta_value, 0, 0, 0 });
    }
};

fn computeHash(
    prev_hash: [HASH_LEN]u8,
    index: u64,
    now_ms: i64,
    kind: EventKind,
    vat_id: cap.VatId,
    subject: u64,
    meta: [4]u64,
) [HASH_LEN]u8 {
    var hasher = Blake3.init(.{});
    hasher.update(&prev_hash);
    var buf8: [8]u8 = undefined;
    std.mem.writeInt(u64, &buf8, index, .big);
    hasher.update(&buf8);
    std.mem.writeInt(i64, &buf8, now_ms, .big);
    hasher.update(&buf8);
    hasher.update(&[_]u8{@intFromEnum(kind)});
    var buf4: [4]u8 = undefined;
    std.mem.writeInt(u32, &buf4, vat_id, .big);
    hasher.update(&buf4);
    std.mem.writeInt(u64, &buf8, subject, .big);
    hasher.update(&buf8);
    for (meta) |m| {
        std.mem.writeInt(u64, &buf8, m, .big);
        hasher.update(&buf8);
    }
    var out: [HASH_LEN]u8 = undefined;
    hasher.final(&out);
    return out;
}

// ---- Tests ------------------------------------------------------------------

const testing = std.testing;

test "chronicle: empty chain verifies" {
    var c = Chronicle.init();
    defer c.deinit(testing.allocator);
    try testing.expectEqual(@as(?u64, null), c.verifyChain());
    try testing.expectEqual(@as(usize, 0), c.len());
}

test "chronicle: records assign monotonic indices and chain hashes" {
    var c = Chronicle.init();
    defer c.deinit(testing.allocator);

    const idx0 = try c.recordCapMint(testing.allocator, 1000, 1, cap.pack(1, 0), cap.FACET_FULL);
    const idx1 = try c.recordVatTurn(testing.allocator, 1100, 1, 0, 0, 0, 5);
    const idx2 = try c.recordRevokerFlip(testing.allocator, 1200, 1, 0xDEADBEEF);

    try testing.expectEqual(@as(u64, 0), idx0);
    try testing.expectEqual(@as(u64, 1), idx1);
    try testing.expectEqual(@as(u64, 2), idx2);
    try testing.expectEqual(@as(usize, 3), c.len());

    // Each event's chain_hash is non-zero and distinct.
    const e0 = c.events.items[0];
    const e1 = c.events.items[1];
    const e2 = c.events.items[2];
    try testing.expect(!std.mem.eql(u8, &e0.chain_hash, &e1.chain_hash));
    try testing.expect(!std.mem.eql(u8, &e1.chain_hash, &e2.chain_hash));
    try testing.expectEqual(@as(?u64, null), c.verifyChain());
}

test "chronicle: tampering with an event invalidates the chain at that index" {
    var c = Chronicle.init();
    defer c.deinit(testing.allocator);

    _ = try c.recordCapMint(testing.allocator, 1000, 1, cap.pack(1, 0), cap.FACET_FULL);
    _ = try c.recordVatTurn(testing.allocator, 1100, 1, 0, 0, 0, 5);
    _ = try c.recordRevokerFlip(testing.allocator, 1200, 1, 0xDEAD);

    // Verify clean.
    try testing.expectEqual(@as(?u64, null), c.verifyChain());

    // Tamper with event at index 1: modify subject.
    c.events.items[1].subject = 999;
    // Chain breaks at index 1.
    try testing.expectEqual(@as(?u64, 1), c.verifyChain());
}

test "chronicle: countByKind filters correctly" {
    var c = Chronicle.init();
    defer c.deinit(testing.allocator);

    _ = try c.recordCapMint(testing.allocator, 1000, 1, cap.pack(1, 0), cap.FACET_FULL);
    _ = try c.recordCapMint(testing.allocator, 1100, 1, cap.pack(1, 1), cap.FACET_FULL);
    _ = try c.recordRevokerFlip(testing.allocator, 1200, 1, 0xA);
    _ = try c.recordRevokerFlip(testing.allocator, 1300, 1, 0xB);
    _ = try c.recordRevokerFlip(testing.allocator, 1400, 1, 0xC);

    try testing.expectEqual(@as(usize, 2), c.countByKind(.cap_mint));
    try testing.expectEqual(@as(usize, 3), c.countByKind(.revoker_flip));
    try testing.expectEqual(@as(usize, 0), c.countByKind(.device_sign));
}

test "chronicle: chain hash binds index — reordering events invalidates" {
    var c = Chronicle.init();
    defer c.deinit(testing.allocator);

    _ = try c.recordCapMint(testing.allocator, 1000, 1, cap.pack(1, 0), cap.FACET_FULL);
    _ = try c.recordRevokerFlip(testing.allocator, 1100, 1, 0xA);
    _ = try c.recordVatTurn(testing.allocator, 1200, 1, 0, 0, 0, 5);

    // Swap events 1 and 2 (preserve original chain_hashes — pure reorder).
    const tmp = c.events.items[1];
    c.events.items[1] = c.events.items[2];
    c.events.items[2] = tmp;

    // Indices in the events still say 0, 2, 1 — hashes don't match.
    const broken_at = c.verifyChain();
    try testing.expect(broken_at != null);
}

test "chronicle: device-sign event preserves seq + msg_len" {
    var c = Chronicle.init();
    defer c.deinit(testing.allocator);

    _ = try c.recordDeviceSign(testing.allocator, 5000, 7, 0xCAFE, 42, 256);
    const e = c.events.items[0];
    try testing.expectEqual(EventKind.device_sign, e.kind);
    try testing.expectEqual(@as(cap.VatId, 7), e.vat_id);
    try testing.expectEqual(@as(u64, 0xCAFE), e.subject);
    try testing.expectEqual(@as(u64, 42), e.meta[0]); // seq
    try testing.expectEqual(@as(u64, 256), e.meta[1]); // msg_len
    try testing.expectEqual(@as(?u64, null), c.verifyChain());
}

test "chronicle: head_hash advances with each record" {
    var c = Chronicle.init();
    defer c.deinit(testing.allocator);

    const zero = std.mem.zeroes([HASH_LEN]u8);
    try testing.expect(std.mem.eql(u8, &c.head_hash, &zero));

    _ = try c.recordCapMint(testing.allocator, 1, 1, cap.pack(1, 0), cap.FACET_FULL);
    try testing.expect(!std.mem.eql(u8, &c.head_hash, &zero));
    const after_first = c.head_hash;

    _ = try c.recordCapMint(testing.allocator, 2, 1, cap.pack(1, 1), cap.FACET_FULL);
    try testing.expect(!std.mem.eql(u8, &c.head_hash, &after_first));
}
