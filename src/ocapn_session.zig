//! CapTP session state: answer-position table, export ref counts, promise
//! handles. Consumed by Vat to support:
//!
//!   - `op:deliver`: allocate an answer position, record a local promise for
//!     later resolution by the peer.
//!   - `op:gc-exports`: wire-delta ref counting over exported positions; when
//!     a position's count reaches zero we send a gc-exports message.
//!   - `op:gc-answers`: release answer positions no longer referenced.
//!
//! Minimal, single-threaded. Multi-vat concurrency is the caller's job.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const PromiseId = u32;
pub const ExportPos = u32;
pub const AnswerPos = u32;

pub const PromiseState = enum {
    pending,
    resolved,
    broken,
};

pub const Promise = struct {
    id: PromiseId,
    answer_pos: AnswerPos,
    state: PromiseState = .pending,
    // Value storage: use a bounded envelope. The Vat writes the resolved
    // Syrup bytes here and flips state on arrival.
    resolved_bytes: std.ArrayListUnmanaged(u8) = .empty,

    pub fn deinit(self: *Promise, allocator: Allocator) void {
        self.resolved_bytes.deinit(allocator);
    }
};

pub const AnswerTable = struct {
    promises: std.ArrayListUnmanaged(Promise),
    next_answer_pos: AnswerPos = 0,
    next_promise_id: PromiseId = 1,

    pub fn init() AnswerTable {
        return .{ .promises = .empty };
    }

    pub fn deinit(self: *AnswerTable, allocator: Allocator) void {
        for (self.promises.items) |*p| p.deinit(allocator);
        self.promises.deinit(allocator);
    }

    /// Allocate a fresh answer position + promise.
    pub fn newPromise(self: *AnswerTable, allocator: Allocator) !*Promise {
        const pos = self.next_answer_pos;
        self.next_answer_pos += 1;
        const id = self.next_promise_id;
        self.next_promise_id += 1;
        try self.promises.append(allocator, .{
            .id = id,
            .answer_pos = pos,
        });
        return &self.promises.items[self.promises.items.len - 1];
    }

    pub fn byAnswerPos(self: *AnswerTable, pos: AnswerPos) ?*Promise {
        for (self.promises.items) |*p| {
            if (p.answer_pos == pos) return p;
        }
        return null;
    }

    pub fn resolvePromise(
        self: *AnswerTable,
        allocator: Allocator,
        pos: AnswerPos,
        bytes: []const u8,
    ) !void {
        const p = self.byAnswerPos(pos) orelse return error.UnknownAnswerPos;
        if (p.state != .pending) return error.PromiseAlreadyResolved;
        try p.resolved_bytes.appendSlice(allocator, bytes);
        p.state = .resolved;
    }

    pub fn breakPromise(self: *AnswerTable, pos: AnswerPos) !void {
        const p = self.byAnswerPos(pos) orelse return error.UnknownAnswerPos;
        if (p.state != .pending) return error.PromiseAlreadyResolved;
        p.state = .broken;
    }

    /// Drop the slot for `pos` — used when the peer sends `op:gc-answers`
    /// telling us they no longer need this answer. Frees `resolved_bytes`.
    /// Returns `error.UnknownAnswerPos` for an unknown pos so a buggy peer
    /// surfaces immediately rather than silently mutating nothing.
    pub fn releasePromise(self: *AnswerTable, allocator: Allocator, pos: AnswerPos) !void {
        var i: usize = 0;
        while (i < self.promises.items.len) : (i += 1) {
            if (self.promises.items[i].answer_pos == pos) {
                self.promises.items[i].deinit(allocator);
                _ = self.promises.swapRemove(i);
                return;
            }
        }
        return error.UnknownAnswerPos;
    }
};

/// Per-session export ref-count map. `register` hands out fresh positions;
/// `incref` / `decref` match what `op:gc-exports` sends on the wire.
pub const ExportTable = struct {
    pub const Entry = struct {
        position: ExportPos,
        wire_count: u32, // How many copies the peer thinks it has.
    };

    entries: std.ArrayListUnmanaged(Entry),
    next_position: ExportPos = 1, // 0 reserved for bootstrap.

    pub fn init() ExportTable {
        return .{ .entries = .empty };
    }

    pub fn deinit(self: *ExportTable, allocator: Allocator) void {
        self.entries.deinit(allocator);
    }

    /// Register a new export, returning its position.
    pub fn allocate(self: *ExportTable, allocator: Allocator) !ExportPos {
        const pos = self.next_position;
        self.next_position += 1;
        try self.entries.append(allocator, .{ .position = pos, .wire_count = 0 });
        return pos;
    }

    pub fn get(self: *ExportTable, pos: ExportPos) ?*Entry {
        for (self.entries.items) |*e| {
            if (e.position == pos) return e;
        }
        return null;
    }

    /// Peer received +1 copy of this export.
    pub fn incref(self: *ExportTable, pos: ExportPos) void {
        if (self.get(pos)) |e| e.wire_count +|= 1;
    }

    /// Peer dropped `delta` references. Returns true if the export is now
    /// orphaned (caller may reclaim).
    pub fn decref(self: *ExportTable, pos: ExportPos, delta: u32) bool {
        const e = self.get(pos) orelse return false;
        if (e.wire_count <= delta) {
            e.wire_count = 0;
            return true;
        }
        e.wire_count -= delta;
        return false;
    }

    /// Drop the entry for `pos`. Caller's responsibility to call this
    /// after `decref` returns true if they want the slot reclaimed —
    /// keeping it separate lets a caller replace orphaned exports with
    /// fresh objects under the same position if their semantics demand it.
    pub fn release(self: *ExportTable, pos: ExportPos) void {
        var i: usize = 0;
        while (i < self.entries.items.len) : (i += 1) {
            if (self.entries.items[i].position == pos) {
                _ = self.entries.swapRemove(i);
                return;
            }
        }
    }
};

// ---- Tests ------------------------------------------------------------------

test "AnswerTable pending → resolved" {
    const allocator = std.testing.allocator;
    var at = AnswerTable.init();
    defer at.deinit(allocator);

    const p = try at.newPromise(allocator);
    const pos = p.answer_pos;
    try std.testing.expectEqual(PromiseState.pending, at.byAnswerPos(pos).?.state);

    try at.resolvePromise(allocator, pos, "42+");
    try std.testing.expectEqual(PromiseState.resolved, at.byAnswerPos(pos).?.state);
    try std.testing.expectEqualSlices(u8, "42+", at.byAnswerPos(pos).?.resolved_bytes.items);
}

test "AnswerTable: unknown pos errors" {
    const allocator = std.testing.allocator;
    var at = AnswerTable.init();
    defer at.deinit(allocator);
    try std.testing.expectError(error.UnknownAnswerPos, at.resolvePromise(allocator, 99, "x"));
    try std.testing.expectError(error.UnknownAnswerPos, at.breakPromise(99));
}

test "AnswerTable: releasePromise drops slot and frees resolved bytes" {
    const allocator = std.testing.allocator;
    var at = AnswerTable.init();
    defer at.deinit(allocator);

    const p1 = try at.newPromise(allocator);
    const p2 = try at.newPromise(allocator);
    try at.resolvePromise(allocator, p1.answer_pos, "a-resolved-payload");
    try std.testing.expect(at.byAnswerPos(p1.answer_pos) != null);

    try at.releasePromise(allocator, p1.answer_pos);
    try std.testing.expectEqual(@as(?*Promise, null), at.byAnswerPos(p1.answer_pos));
    // p2 still present, unaffected.
    try std.testing.expect(at.byAnswerPos(p2.answer_pos) != null);

    try std.testing.expectError(error.UnknownAnswerPos, at.releasePromise(allocator, p1.answer_pos));
}

test "AnswerTable: pending → broken, double-resolve rejected" {
    const allocator = std.testing.allocator;
    var at = AnswerTable.init();
    defer at.deinit(allocator);

    const p = try at.newPromise(allocator);
    const pos = p.answer_pos;
    try at.breakPromise(pos);
    try std.testing.expectEqual(PromiseState.broken, at.byAnswerPos(pos).?.state);

    // Once broken, further resolve/break attempts must fail loudly — the
    // dispatcher relies on this to avoid silent state corruption when a
    // misbehaving peer sends both fulfill and break for one answer.
    try std.testing.expectError(error.PromiseAlreadyResolved, at.resolvePromise(allocator, pos, "x"));
    try std.testing.expectError(error.PromiseAlreadyResolved, at.breakPromise(pos));
}

test "ExportTable: alloc + incref + decref" {
    const allocator = std.testing.allocator;
    var et = ExportTable.init();
    defer et.deinit(allocator);

    const p = try et.allocate(allocator);
    try std.testing.expect(p >= 1);
    et.incref(p);
    et.incref(p);
    try std.testing.expect(!et.decref(p, 1));
    try std.testing.expect(et.decref(p, 1)); // hit zero
}

test "ExportTable: release drops orphaned entry; lookup returns null after" {
    const allocator = std.testing.allocator;
    var et = ExportTable.init();
    defer et.deinit(allocator);

    const p1 = try et.allocate(allocator);
    const p2 = try et.allocate(allocator);
    et.incref(p1);
    try std.testing.expect(et.decref(p1, 1)); // orphaned
    et.release(p1);
    try std.testing.expectEqual(@as(?*ExportTable.Entry, null), et.get(p1));
    try std.testing.expect(et.get(p2) != null);

    // Releasing an unknown pos is a no-op (matches Vat's race-tolerance).
    et.release(9999);
}
