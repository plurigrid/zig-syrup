//! OCapN bootstrap object + swiss-number registry.
//!
//! Every OCapN vat exposes an implicit bootstrap object at export position 0.
//! Remote peers invoke `fetch(swiss-number)` on it to resolve a sturdy-ref
//! into a concrete import position for future op:deliver calls.
//!
//! The registry is a map: swiss [32]u8 → local export position (u32).
//! `register` adds an entry (and allocates a fresh export position in the
//! caller's session). `fetch` looks up a swiss and returns the position or
//! `null` if unknown.

const std = @import("std");
const syrup = @import("syrup");
const Allocator = std.mem.Allocator;
const ByteList = std.array_list.Managed(u8);

pub const SWISS_LEN: usize = 32;
pub const BOOTSTRAP_POS: u32 = 0;

/// Swiss-number → export-position map. Ownership of the key bytes is by-value
/// (stored inline in the struct), so callers can free their source buffers
/// after registering.
pub const SwissRegistry = struct {
    const Entry = struct {
        swiss: [SWISS_LEN]u8,
        position: u32,
    };

    entries: std.ArrayListUnmanaged(Entry),
    next_position: u32 = 1, // 0 reserved for bootstrap itself

    pub fn init() SwissRegistry {
        return .{ .entries = .empty };
    }

    pub fn deinit(self: *SwissRegistry, allocator: Allocator) void {
        self.entries.deinit(allocator);
    }

    /// Register a fresh sturdy: returns the allocated export position.
    pub fn register(
        self: *SwissRegistry,
        allocator: Allocator,
        swiss: [SWISS_LEN]u8,
    ) !u32 {
        if (self.lookup(swiss)) |pos| return pos;
        const pos = self.next_position;
        self.next_position += 1;
        try self.entries.append(allocator, .{ .swiss = swiss, .position = pos });
        return pos;
    }

    /// Look up an existing swiss. Returns null if not registered.
    pub fn lookup(self: *const SwissRegistry, swiss: [SWISS_LEN]u8) ?u32 {
        for (self.entries.items) |e| {
            if (std.mem.eql(u8, &e.swiss, &swiss)) return e.position;
        }
        return null;
    }

    /// Serve a fetch request. Returns the export position for this swiss,
    /// or null if unknown (caller should reply with a desc:error).
    pub fn fetch(self: *const SwissRegistry, swiss: [SWISS_LEN]u8) ?u32 {
        return self.lookup(swiss);
    }

    /// Current count of registered sturdies (excluding bootstrap itself).
    pub fn size(self: *const SwissRegistry) usize {
        return self.entries.items.len;
    }
};

/// Bootstrap method dispatch — the type-level encoding of the bootstrap
/// object's method space. No more stringly-typed `"fetch"` matching.
pub const BootstrapMethod = enum {
    fetch,
    deposit_gift,
    withdraw_gift,

    pub fn fromSymbol(s: []const u8) ?BootstrapMethod {
        if (std.mem.eql(u8, s, "fetch")) return .fetch;
        if (std.mem.eql(u8, s, "deposit-gift")) return .deposit_gift;
        if (std.mem.eql(u8, s, "withdraw-gift")) return .withdraw_gift;
        return null;
    }
};

pub const GIFT_ID_LEN: usize = 32;

/// Key for the gift table: (session_id, gift_id). Session identity comes
/// from the CapTP session-id derivation (SHA256^2 of sorted pubkey-ids).
pub const GiftKey = struct {
    session_id: [32]u8,
    gift_id: [GIFT_ID_LEN]u8,

    pub fn eql(a: GiftKey, b: GiftKey) bool {
        return std.mem.eql(u8, &a.session_id, &b.session_id) and
            std.mem.eql(u8, &a.gift_id, &b.gift_id);
    }
};

/// Result of a deposit or withdrawal — encodes the two-input join state.
pub const GiftResult = enum {
    /// Gift stored, no withdrawal yet. Caller need not act.
    held,
    /// Both sides present — gift delivered. Caller should fulfill.
    delivered,
    /// Duplicate operation rejected.
    duplicate,
};

/// Two-input join table for the 3-vat handoff gift ceremony.
///
/// Deposit and withdraw can arrive in either order. The table holds
/// whichever arrives first and completes the join when both are present.
///
/// Invariants (Lamport safety):
///   S1: No gift is delivered more than once.
///   S2: A gift is delivered only when both deposit and withdraw exist.
///   S3: Session isolation — gifts are keyed by session_id.
pub const GiftTable = struct {
    const Slot = struct {
        key: GiftKey,
        /// Pre-encoded Syrup bytes of the deposited gift descriptor.
        /// Null until deposit arrives. Owned, allocator-freed.
        gift_desc_bytes: ?[]const u8 = null,
        /// The answer_pos from the withdraw-gift deliver, so the Vat
        /// can fulfill it when the deposit arrives (or immediately).
        withdraw_answer_pos: ?u32 = null,
        /// True once the gift has been delivered (join complete).
        delivered: bool = false,
    };

    slots: std.ArrayListUnmanaged(Slot),

    pub fn init() GiftTable {
        return .{ .slots = .empty };
    }

    pub fn deinit(self: *GiftTable, allocator: Allocator) void {
        for (self.slots.items) |*s| {
            if (s.gift_desc_bytes) |b| allocator.free(b);
        }
        self.slots.deinit(allocator);
    }

    fn findSlot(self: *GiftTable, key: GiftKey) ?*Slot {
        for (self.slots.items) |*s| {
            if (s.key.eql(key)) return s;
        }
        return null;
    }

    /// Gifter deposits a reference. Returns:
    ///   .delivered — withdrawal was already waiting; caller should fulfill.
    ///   .held      — stored, waiting for withdrawal.
    ///   .duplicate — gift_id already deposited for this session.
    pub fn deposit(
        self: *GiftTable,
        allocator: Allocator,
        key: GiftKey,
        gift_desc_bytes: []const u8,
    ) !GiftResult {
        if (self.findSlot(key)) |slot| {
            if (slot.gift_desc_bytes != null) return .duplicate;
            // Withdrawal arrived first — complete the join.
            const owned = try allocator.alloc(u8, gift_desc_bytes.len);
            @memcpy(owned, gift_desc_bytes);
            slot.gift_desc_bytes = owned;
            slot.delivered = true;
            return .delivered;
        }
        // First arrival — store deposit, wait for withdrawal.
        const owned = try allocator.alloc(u8, gift_desc_bytes.len);
        @memcpy(owned, gift_desc_bytes);
        try self.slots.append(allocator, .{
            .key = key,
            .gift_desc_bytes = owned,
        });
        return .held;
    }

    /// Receiver withdraws a gift. Returns:
    ///   .delivered — deposit was already present; caller should fulfill.
    ///   .held      — stored, waiting for deposit.
    ///   .duplicate — gift_id already withdrawn for this session.
    pub fn withdraw(
        self: *GiftTable,
        allocator: Allocator,
        key: GiftKey,
        answer_pos: u32,
    ) !GiftResult {
        if (self.findSlot(key)) |slot| {
            if (slot.withdraw_answer_pos != null) return .duplicate;
            slot.withdraw_answer_pos = answer_pos;
            if (slot.gift_desc_bytes != null) {
                slot.delivered = true;
                return .delivered;
            }
            return .held;
        }
        // First arrival — store withdrawal, wait for deposit.
        try self.slots.append(allocator, .{
            .key = key,
            .withdraw_answer_pos = answer_pos,
        });
        return .held;
    }

    /// Retrieve the gift descriptor bytes for a completed slot.
    /// Returns null if the gift hasn't been delivered yet.
    pub fn getDeliveredGift(self: *GiftTable, key: GiftKey) ?[]const u8 {
        const slot = self.findSlot(key) orelse return null;
        if (!slot.delivered) return null;
        return slot.gift_desc_bytes;
    }

    /// Retrieve the answer_pos for a completed slot's withdrawal side.
    pub fn getWithdrawAnswerPos(self: *GiftTable, key: GiftKey) ?u32 {
        const slot = self.findSlot(key) orelse return null;
        return slot.withdraw_answer_pos;
    }

    /// Release a delivered gift slot. Called after the Vat has fulfilled
    /// the withdrawal promise.
    pub fn release(self: *GiftTable, allocator: Allocator, key: GiftKey) void {
        var i: usize = 0;
        while (i < self.slots.items.len) : (i += 1) {
            if (self.slots.items[i].key.eql(key)) {
                if (self.slots.items[i].gift_desc_bytes) |b| allocator.free(b);
                _ = self.slots.swapRemove(i);
                return;
            }
        }
    }
};

/// Generate a fresh 32-byte swiss using a cryptographic RNG.
pub fn freshSwiss() [SWISS_LEN]u8 {
    var out: [SWISS_LEN]u8 = undefined;
    std.crypto.random.bytes(&out);
    return out;
}

/// Build a caller-owned `<desc:import-object N>` Syrup record. Common
/// payload for `Vat.sendFulfill` when replying to a bootstrap `fetch`.
pub fn encodeImportObjectAlloc(allocator: Allocator, position: u32) ![]u8 {
    var out = ByteList.init(allocator);
    errdefer out.deinit();
    try out.appendSlice("<18'desc:import-object");
    try std.fmt.format(out.writer(), "{d}+", .{position});
    try out.append('>');
    return out.toOwnedSlice();
}

/// Extract a 32-byte swiss from the first argument of a `fetch` call.
/// Racket/Guile Goblins emit swiss as a bytestring.
pub fn readFetchSwiss(arg: syrup.Value) ![SWISS_LEN]u8 {
    switch (arg) {
        .bytes => |b| {
            if (b.len != SWISS_LEN) return error.InvalidSwiss;
            var out: [SWISS_LEN]u8 = undefined;
            @memcpy(&out, b);
            return out;
        },
        else => return error.InvalidSwiss,
    }
}

// ---- Tests ------------------------------------------------------------------

test "register → lookup → fetch" {
    const allocator = std.testing.allocator;
    var reg = SwissRegistry.init();
    defer reg.deinit(allocator);

    var s1: [SWISS_LEN]u8 = undefined;
    var s2: [SWISS_LEN]u8 = undefined;
    for (&s1, 0..) |*b, i| b.* = @intCast(i);
    for (&s2, 0..) |*b, i| b.* = @intCast(0xFF - i);

    const p1 = try reg.register(allocator, s1);
    const p2 = try reg.register(allocator, s2);
    try std.testing.expect(p1 != BOOTSTRAP_POS);
    try std.testing.expect(p2 != BOOTSTRAP_POS);
    try std.testing.expect(p1 != p2);

    try std.testing.expectEqual(@as(?u32, p1), reg.fetch(s1));
    try std.testing.expectEqual(@as(?u32, p2), reg.fetch(s2));

    // Unknown swiss returns null.
    const s3: [SWISS_LEN]u8 = [_]u8{0} ** SWISS_LEN;
    try std.testing.expectEqual(@as(?u32, null), reg.fetch(s3));

    // Re-registering the same swiss returns the same position.
    const p1_again = try reg.register(allocator, s1);
    try std.testing.expectEqual(p1, p1_again);
    try std.testing.expectEqual(@as(usize, 2), reg.size());
}

test "freshSwiss yields nonzero bytes with overwhelming probability" {
    const s = freshSwiss();
    var zero_count: usize = 0;
    for (s) |b| if (b == 0) {
        zero_count += 1;
    };
    try std.testing.expect(zero_count < SWISS_LEN);
}

test "encodeImportObjectAlloc produces parseable desc:import-object" {
    const allocator = std.testing.allocator;
    const bytes = try encodeImportObjectAlloc(allocator, 42);
    defer allocator.free(bytes);

    var parser = syrup.Parser.init(bytes, allocator);
    var v = try parser.parse();
    defer v.deinitAll(allocator);
    try std.testing.expect(v == .record);
    try std.testing.expectEqualStrings("desc:import-object", v.record.label.symbol);
    try std.testing.expectEqual(@as(usize, 1), v.record.fields.len);
    try std.testing.expectEqual(@as(i64, 42), v.record.fields[0].integer);
}

test "readFetchSwiss: 32-byte bytes OK, wrong length rejected" {
    var full: [SWISS_LEN]u8 = undefined;
    for (&full, 0..) |*b, i| b.* = @intCast(i);
    const ok = try readFetchSwiss(.{ .bytes = &full });
    try std.testing.expectEqualSlices(u8, &full, &ok);

    const short = &[_]u8{ 1, 2, 3 };
    try std.testing.expectError(error.InvalidSwiss, readFetchSwiss(.{ .bytes = short }));
    try std.testing.expectError(error.InvalidSwiss, readFetchSwiss(.{ .integer = 5 }));
}

test "BootstrapMethod: fromSymbol routes correctly" {
    try std.testing.expectEqual(BootstrapMethod.fetch, BootstrapMethod.fromSymbol("fetch").?);
    try std.testing.expectEqual(BootstrapMethod.deposit_gift, BootstrapMethod.fromSymbol("deposit-gift").?);
    try std.testing.expectEqual(BootstrapMethod.withdraw_gift, BootstrapMethod.fromSymbol("withdraw-gift").?);
    try std.testing.expectEqual(@as(?BootstrapMethod, null), BootstrapMethod.fromSymbol("nope"));
}

test "GiftTable: deposit then withdraw = delivered" {
    const allocator = std.testing.allocator;
    var gt = GiftTable.init();
    defer gt.deinit(allocator);

    const key = GiftKey{
        .session_id = [_]u8{0xAA} ** 32,
        .gift_id = [_]u8{0xBB} ** GIFT_ID_LEN,
    };
    const r1 = try gt.deposit(allocator, key, "gift-payload");
    try std.testing.expectEqual(GiftResult.held, r1);
    const r2 = try gt.withdraw(allocator, key, 42);
    try std.testing.expectEqual(GiftResult.delivered, r2);
    try std.testing.expectEqualStrings("gift-payload", gt.getDeliveredGift(key).?);
    try std.testing.expectEqual(@as(?u32, 42), gt.getWithdrawAnswerPos(key));
}

test "GiftTable: withdraw then deposit = delivered (reverse order)" {
    const allocator = std.testing.allocator;
    var gt = GiftTable.init();
    defer gt.deinit(allocator);

    const key = GiftKey{
        .session_id = [_]u8{0xCC} ** 32,
        .gift_id = [_]u8{0xDD} ** GIFT_ID_LEN,
    };
    const r1 = try gt.withdraw(allocator, key, 7);
    try std.testing.expectEqual(GiftResult.held, r1);
    const r2 = try gt.deposit(allocator, key, "reverse-gift");
    try std.testing.expectEqual(GiftResult.delivered, r2);
    try std.testing.expectEqualStrings("reverse-gift", gt.getDeliveredGift(key).?);
}

test "GiftTable: duplicate deposit rejected" {
    const allocator = std.testing.allocator;
    var gt = GiftTable.init();
    defer gt.deinit(allocator);

    const key = GiftKey{
        .session_id = [_]u8{0x11} ** 32,
        .gift_id = [_]u8{0x22} ** GIFT_ID_LEN,
    };
    _ = try gt.deposit(allocator, key, "first");
    const r2 = try gt.deposit(allocator, key, "second");
    try std.testing.expectEqual(GiftResult.duplicate, r2);
}

test "GiftTable: duplicate withdrawal rejected" {
    const allocator = std.testing.allocator;
    var gt = GiftTable.init();
    defer gt.deinit(allocator);

    const key = GiftKey{
        .session_id = [_]u8{0x33} ** 32,
        .gift_id = [_]u8{0x44} ** GIFT_ID_LEN,
    };
    _ = try gt.withdraw(allocator, key, 1);
    const r2 = try gt.withdraw(allocator, key, 2);
    try std.testing.expectEqual(GiftResult.duplicate, r2);
}

test "GiftTable: release removes slot" {
    const allocator = std.testing.allocator;
    var gt = GiftTable.init();
    defer gt.deinit(allocator);

    const key = GiftKey{
        .session_id = [_]u8{0x55} ** 32,
        .gift_id = [_]u8{0x66} ** GIFT_ID_LEN,
    };
    _ = try gt.deposit(allocator, key, "d");
    _ = try gt.withdraw(allocator, key, 5);
    gt.release(allocator, key);
    try std.testing.expectEqual(@as(?[]const u8, null), gt.getDeliveredGift(key));
}

test "GiftTable: session isolation" {
    const allocator = std.testing.allocator;
    var gt = GiftTable.init();
    defer gt.deinit(allocator);

    const gift_id = [_]u8{0x77} ** GIFT_ID_LEN;
    const key_a = GiftKey{ .session_id = [_]u8{0xAA} ** 32, .gift_id = gift_id };
    const key_b = GiftKey{ .session_id = [_]u8{0xBB} ** 32, .gift_id = gift_id };
    _ = try gt.deposit(allocator, key_a, "gift-a");
    // Same gift_id, different session — should be independent.
    const r = try gt.withdraw(allocator, key_b, 1);
    try std.testing.expectEqual(GiftResult.held, r);
}
