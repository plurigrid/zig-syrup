//! vat_replay.zig — deterministic rollout log for vat.zig.
//!
//! Each TurnRecord is appended as a Syrup record so the log is parseable by
//! any OCapN-compatible reader. This is dispatch metadata: payload lengths
//! do not reconstruct payloads, actor state, grants or external effects.
//!
//! This is distinct from tape_recorder.zig (which logs terminal damage frames):
//! A recovery engine must supply those missing inputs and its own admission.

const std = @import("std");
const vat = @import("vat.zig");
const cap = @import("cap.zig");

const Allocator = std.mem.Allocator;

pub const Log = struct {
    allocator: Allocator,
    bytes: std.ArrayListUnmanaged(u8),
    recording_failed: bool = false,

    pub fn init(allocator: Allocator) Log {
        return .{ .allocator = allocator, .bytes = .empty };
    }

    pub fn deinit(self: *Log) void {
        self.bytes.deinit(self.allocator);
    }

    /// Syrup encoding: <vat-turn turn_seq:int now_ms:int sender:int target:int
    ///                           sel:int paylen:int became:sym lagged:int>
    /// `became` is the symbol "same" or "terminate". `lagged` is the
    /// mailbox lag count *before* this turn (Lagged-marker semantics).
    /// `turn_seq` is a vat-local monotonic counter; `now_ms` captures the
    /// vat clock at dispatch start. Rechecking expiry additionally requires
    /// the original grant; restoring state requires the original payload.
    pub fn record(self: *Log, rec: vat.TurnRecord) !void {
        try self.requireComplete();
        errdefer self.recording_failed = true;
        var tmp: [192]u8 = undefined;
        const became_sym = switch (rec.became) {
            .same => "4'same",
            .terminate => "9'terminate",
        };
        const s = try std.fmt.bufPrint(&tmp, "<8'vat-turn{d}+{d}{c}{d}+{d}+{d}+{d}+{s}{d}+>", .{
            rec.turn_seq,    @abs(rec.now_ms), if (rec.now_ms < 0) @as(u8, '-') else @as(u8, '+'),
            rec.sender,      rec.target,       rec.selector,
            rec.payload_len, became_sym,       rec.lagged_before,
        });
        try self.bytes.appendSlice(self.allocator, s);
    }

    /// Check completeness before consuming this diagnostic as evidence.
    /// A later successful allocation cannot repair an omitted turn.
    pub fn requireComplete(self: *const Log) error{IncompleteLog}!void {
        if (self.recording_failed) return error.IncompleteLog;
    }

    /// C-callback adapter — pass the address of `record_callback` and a `*Log`
    /// to `vat.on_record`/`vat.record_ctx`.
    pub fn callback(ctx: *anyopaque, rec: vat.TurnRecord) void {
        const self: *Log = @ptrCast(@alignCast(ctx));
        self.record(rec) catch {
            self.recording_failed = true;
        };
    }

    /// Total recorded turns (counts top-level `<vat-turn ...>` opens).
    pub fn turnCount(self: *const Log) usize {
        var n: usize = 0;
        for (self.bytes.items) |b| if (b == '<') {
            n += 1;
        };
        return n;
    }
};

// ---- Tests ------------------------------------------------------------------

const testing = std.testing;

test "negative virtual time uses the Syrup integer sign suffix" {
    var log = Log.init(testing.allocator);
    defer log.deinit();
    try log.record(.{ .turn_seq = 0, .now_ms = -1, .sender = 0, .target = 0, .selector = 0, .payload_len = 0, .became = .same, .lagged_before = 0 });
    try testing.expectEqualStrings("<8'vat-turn0+1-0+0+0+0+4'same0+>", log.bytes.items);
    try log.requireComplete();
}

test "recording failure leaves no partial receipt and remains observable" {
    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    var log = Log.init(failing.allocator());
    defer log.deinit();
    const rec = vat.TurnRecord{ .turn_seq = 0, .now_ms = 1, .sender = 1, .target = 0, .selector = 0, .payload_len = 0, .became = .same, .lagged_before = 0 };
    Log.callback(&log, rec);
    try testing.expectEqual(@as(usize, 0), log.bytes.items.len);
    try testing.expectEqual(@as(usize, 0), log.turnCount());
    try testing.expectError(error.IncompleteLog, log.requireComplete());
    try testing.expectError(error.IncompleteLog, log.record(rec));
}

test "replay log records each turn as a Syrup record" {
    const alloc = testing.allocator;
    var log = Log.init(alloc);
    defer log.deinit();

    var v = vat.Vat.init(alloc, 1);
    defer v.deinit();
    v.on_record = Log.callback;
    v.record_ctx = &log;

    const Counter = struct {
        n: *u32,
        pub const SELECTORS: cap.SelectorMask = cap.maskOf(&.{0});
        pub fn handle(self: *@This(), _: *vat.Vat, _: vat.Message) !vat.Become {
            self.n.* += 1;
            return .same;
        }
    };
    var n: u32 = 0;
    const c = try v.spawn(Counter, .{ .n = &n });
    const sender = cap.Capability{ .target = cap.pack(1, 0) };
    try v.send(sender, c, 0, "");
    try v.send(sender, c, 0, "");
    _ = try v.quiesce(10);

    try testing.expectEqual(@as(u32, 2), n);
    try testing.expectEqual(@as(usize, 2), log.turnCount());
    try testing.expect(std.mem.indexOf(u8, log.bytes.items, "vat-turn") != null);
    try testing.expect(std.mem.indexOf(u8, log.bytes.items, "4'same") != null);
}

test "replay log: turn_seq is dense and now_ms tracks vat clock" {
    const VirtualClock = struct {
        var now: i64 = 5_000;
        fn read() i64 {
            return now;
        }
    };
    VirtualClock.now = 5_000;

    const alloc = testing.allocator;
    var v = vat.Vat.init(alloc, 1);
    defer v.deinit();
    v.now_ms_fn = VirtualClock.read;

    // Capture every record into a flat slice for inspection.
    const Capture = struct {
        recs: std.ArrayListUnmanaged(vat.TurnRecord) = .empty,

        fn cb(ctx: *anyopaque, rec: vat.TurnRecord) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.recs.append(std.testing.allocator, rec) catch {};
        }
    };
    var cap_ctx: Capture = .{};
    defer cap_ctx.recs.deinit(alloc);
    v.on_record = Capture.cb;
    v.record_ctx = &cap_ctx;

    const Counter = struct {
        n: *u32,
        pub const SELECTORS: cap.SelectorMask = cap.maskOf(&.{0});
        pub fn handle(self: *@This(), _: *vat.Vat, _: vat.Message) !vat.Become {
            self.n.* += 1;
            return .same;
        }
    };
    var n: u32 = 0;
    const c = try v.spawn(Counter, .{ .n = &n });
    const sender = cap.Capability{ .target = cap.pack(1, 0) };
    try v.send(sender, c, 0, "");
    VirtualClock.now = 5_100;
    try v.send(sender, c, 0, "");
    VirtualClock.now = 5_200;
    _ = try v.quiesce(10);

    try testing.expectEqual(@as(usize, 2), cap_ctx.recs.items.len);
    // turn_seq is dense: 0, 1
    try testing.expectEqual(@as(u64, 0), cap_ctx.recs.items[0].turn_seq);
    try testing.expectEqual(@as(u64, 1), cap_ctx.recs.items[1].turn_seq);
    // now_ms reflects the clock at the moment each turn dispatched
    try testing.expectEqual(@as(i64, 5_200), cap_ctx.recs.items[0].now_ms);
    try testing.expectEqual(@as(i64, 5_200), cap_ctx.recs.items[1].now_ms);
}

test "replay log captures terminate transition" {
    const alloc = testing.allocator;
    var log = Log.init(alloc);
    defer log.deinit();
    var v = vat.Vat.init(alloc, 1);
    defer v.deinit();
    v.on_record = Log.callback;
    v.record_ctx = &log;

    const Quitter = struct {
        pub const SELECTORS: cap.SelectorMask = cap.maskOf(&.{0});
        pub fn handle(_: *@This(), _: *vat.Vat, _: vat.Message) !vat.Become {
            return .terminate;
        }
    };
    const c = try v.spawn(Quitter, .{});
    const sender = cap.Capability{ .target = cap.pack(1, 0) };
    try v.send(sender, c, 0, "");
    _ = try v.quiesce(10);
    try testing.expect(std.mem.indexOf(u8, log.bytes.items, "9'terminate") != null);
}
