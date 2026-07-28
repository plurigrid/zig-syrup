//! vat_replay.zig — deterministic rollout log for vat.zig.
//!
//! Each TurnRecord is appended as a Syrup record so the log is parseable by
//! any OCapN-compatible reader. Replay reconstructs vat state by re-feeding
//! the recorded sequence into a fresh Vat with the same Behavior types.
//!
//! This is distinct from tape_recorder.zig (which logs terminal damage frames):
//! vat_replay logs *actor turns*, the unit needed to rebuild vat semantics.

const std = @import("std");
const vat = @import("vat.zig");
const cap = @import("cap.zig");

const Allocator = std.mem.Allocator;

pub const Log = struct {
    allocator: Allocator,
    bytes: std.ArrayListUnmanaged(u8),

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
    /// vat clock at dispatch start so expiry decisions can be re-checked
    /// during replay without rerunning handlers.
    pub fn record(self: *Log, rec: vat.TurnRecord) !void {
        var tmp: [192]u8 = undefined;
        try self.bytes.appendSlice(self.allocator, "<8'vat-turn");
        const became_sym = switch (rec.became) {
            .same => "4'same",
            .terminate => "9'terminate",
        };
        const s = try std.fmt.bufPrint(&tmp, "{d}+{d}+{d}+{d}+{d}+{d}+{s}{d}+>", .{
            rec.turn_seq, rec.now_ms,
            rec.sender,   rec.target,
            rec.selector, rec.payload_len,
            became_sym,   rec.lagged_before,
        });
        try self.bytes.appendSlice(self.allocator, s);
    }

    /// C-callback adapter — pass the address of `record_callback` and a `*Log`
    /// to `vat.on_record`/`vat.record_ctx`.
    pub fn callback(ctx: *anyopaque, rec: vat.TurnRecord) void {
        const self: *Log = @ptrCast(@alignCast(ctx));
        self.record(rec) catch {};
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
