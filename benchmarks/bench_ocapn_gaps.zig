const std = @import("std");
const syrup = @import("syrup");
const wire_desc = @import("wire_desc");
const ocapn_session = @import("ocapn_session");
const ocapn_bootstrap = @import("ocapn_bootstrap");

// OCapN Gap Implementation Benchmarks
//
// Measures hot-path performance for the three spec-compliance additions:
//   Gap 2: WireDesc parse + encode (descriptor dispatch foundation)
//   Gap 1: Listener add + drain (promise observation)
//   Gap 3: GiftTable deposit/withdraw join (3-vat handoff)

const ITERS = 100_000;
const LISTENER_ITERS = 50_000;
const GIFT_ITERS = 50_000;

fn timestamp() i128 {
    return std.time.nanoTimestamp();
}

const OutBuf = struct {
    buf: [16384]u8 = undefined,
    pos: usize = 0,

    pub fn print(self: *OutBuf, comptime fmt: []const u8, args: anytype) !void {
        const slice = self.buf[self.pos..];
        const written = std.fmt.bufPrint(slice, fmt, args) catch return error.BufferFull;
        self.pos += written.len;
    }

    pub fn flush(self: *OutBuf) void {
        if (self.pos > 0) {
            _ = std.c.write(std.c.STDOUT_FILENO, &self.buf, self.pos);
            self.pos = 0;
        }
    }
};

fn report(writer: anytype, label: []const u8, total_ns: i128, iters: usize) !void {
    const avg_ns = @divFloor(total_ns, iters);
    const ops_sec = if (avg_ns > 0) @divFloor(@as(i128, 1_000_000_000), avg_ns) else 0;
    try writer.print("  {s:<45} {d:>6} ns/op  ({d:>12} ops/sec)\n", .{ label, avg_ns, ops_sec });
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var out = OutBuf{};
    const stdout = &out;
    defer out.flush();
    try stdout.print("\n=== OCapN Gap Implementation Benchmarks ===\n", .{});
    try stdout.print("    (ReleaseFast, {d} core iterations)\n\n", .{ITERS});
    out.flush();

    // =====================================================================
    // GAP 2: WireDesc — parse + encode
    // =====================================================================
    try stdout.print("--- Gap 2: WireDesc (typed descriptor parsing) ---\n", .{});

    // Pre-encode four descriptor variants for parse benchmarks.
    const desc_import_obj = "<18'desc:import-object42+>";
    const desc_import_promise = "<19'desc:import-promise7+>";
    const desc_answer = "<11'desc:answer99+>";
    const desc_export = "<11'desc:export5+>";

    // 2a. Parse desc:import-object
    {
        const t0 = timestamp();
        var i: usize = 0;
        while (i < ITERS) : (i += 1) {
            var parser = syrup.Parser.init(desc_import_obj, allocator);
            var v = parser.parse() catch unreachable;
            const wd = wire_desc.WireDesc.fromValue(v) catch unreachable;
            std.mem.doNotOptimizeAway(wd);
            v.deinitAll(allocator);
        }
        try report(stdout, "WireDesc.fromValue(desc:import-object)", timestamp() - t0, ITERS);
    }

    // 2b. Parse desc:import-promise
    {
        const t0 = timestamp();
        var i: usize = 0;
        while (i < ITERS) : (i += 1) {
            var parser = syrup.Parser.init(desc_import_promise, allocator);
            var v = parser.parse() catch unreachable;
            const wd = wire_desc.WireDesc.fromValue(v) catch unreachable;
            std.mem.doNotOptimizeAway(wd);
            v.deinitAll(allocator);
        }
        try report(stdout, "WireDesc.fromValue(desc:import-promise)", timestamp() - t0, ITERS);
    }

    // 2c. Parse desc:answer
    {
        const t0 = timestamp();
        var i: usize = 0;
        while (i < ITERS) : (i += 1) {
            var parser = syrup.Parser.init(desc_answer, allocator);
            var v = parser.parse() catch unreachable;
            const wd = wire_desc.WireDesc.fromValue(v) catch unreachable;
            std.mem.doNotOptimizeAway(wd);
            v.deinitAll(allocator);
        }
        try report(stdout, "WireDesc.fromValue(desc:answer)", timestamp() - t0, ITERS);
    }

    // 2d. Parse desc:export
    {
        const t0 = timestamp();
        var i: usize = 0;
        while (i < ITERS) : (i += 1) {
            var parser = syrup.Parser.init(desc_export, allocator);
            var v = parser.parse() catch unreachable;
            const wd = wire_desc.WireDesc.fromValue(v) catch unreachable;
            std.mem.doNotOptimizeAway(wd);
            v.deinitAll(allocator);
        }
        try report(stdout, "WireDesc.fromValue(desc:export)", timestamp() - t0, ITERS);
    }

    // 2e. TargetDesc narrowing from WireDesc (no parse, pure type dispatch)
    {
        const t0 = timestamp();
        var i: usize = 0;
        while (i < ITERS) : (i += 1) {
            const wd = wire_desc.WireDesc{ .import_object = @as(u32, @intCast(i % 1000)) };
            const td = wire_desc.TargetDesc.fromWireDesc(wd) catch unreachable;
            std.mem.doNotOptimizeAway(td);
        }
        try report(stdout, "TargetDesc.fromWireDesc (type narrowing only)", timestamp() - t0, ITERS);
    }

    // 2f. WireDesc.encodeAlloc round-trip
    {
        const t0 = timestamp();
        var i: usize = 0;
        while (i < ITERS) : (i += 1) {
            const wd = wire_desc.WireDesc{ .import_promise = @as(u32, @intCast(i % 1000)) };
            const bytes = wd.encodeAlloc(allocator) catch unreachable;
            std.mem.doNotOptimizeAway(bytes.ptr);
            allocator.free(bytes);
        }
        try report(stdout, "WireDesc.encodeAlloc (alloc+format+free)", timestamp() - t0, ITERS);
    }

    // =====================================================================
    // GAP 1: Listener model on Promise
    // =====================================================================
    try stdout.print("\n--- Gap 1: Listener (promise observation) ---\n", .{});

    // 1a. addListener on pending promise (store path) — zero-alloc with ResolverRef
    {
        var at = ocapn_session.AnswerTable.init();
        defer at.deinit(allocator);
        const p = try at.newPromise(allocator);

        const t0 = timestamp();
        var i: usize = 0;
        while (i < LISTENER_ITERS) : (i += 1) {
            const resolver = ocapn_session.ResolverRef{ .position = @intCast(i % 1000), .is_promise = false };
            const result = try p.addListener(allocator, resolver, false);
            std.mem.doNotOptimizeAway(result);
        }
        try report(stdout, "addListener (pending, store path, zero-alloc)", timestamp() - t0, LISTENER_ITERS);
        try stdout.print("    -> {d} listeners stored\n", .{p.listeners.items.len});
    }

    // 1b. addListener on already-resolved promise (immediate path)
    {
        var at = ocapn_session.AnswerTable.init();
        defer at.deinit(allocator);
        const p = try at.newPromise(allocator);
        const pos = p.answer_pos;
        try at.resolvePromise(allocator, pos, "42+");

        const t0 = timestamp();
        var i: usize = 0;
        while (i < LISTENER_ITERS) : (i += 1) {
            const resolver = ocapn_session.ResolverRef{ .position = @intCast(i % 1000), .is_promise = false };
            const result = try at.byAnswerPos(pos).?.addListener(allocator, resolver, false);
            std.mem.doNotOptimizeAway(result);
        }
        try report(stdout, "addListener (resolved, immediate, zero-alloc)", timestamp() - t0, LISTENER_ITERS);
    }

    // 1c. drainListeners — add N listeners, resolve, drain all (zero-alloc listeners)
    {
        const listener_counts = [_]usize{ 1, 10, 100, 1000 };
        for (listener_counts) |n| {
            var at = ocapn_session.AnswerTable.init();
            defer at.deinit(allocator);
            const drain_iters: usize = LISTENER_ITERS / n;

            const t0 = timestamp();
            var iter: usize = 0;
            while (iter < drain_iters) : (iter += 1) {
                const p = try at.newPromise(allocator);
                const pos = p.answer_pos;
                var j: usize = 0;
                while (j < n) : (j += 1) {
                    const resolver = ocapn_session.ResolverRef{ .position = @intCast(j), .is_promise = false };
                    _ = try p.addListener(allocator, resolver, false);
                }
                try at.resolvePromise(allocator, pos, "val");
                const listeners = try at.byAnswerPos(pos).?.drainListeners(allocator);
                allocator.free(listeners);
                try at.releasePromise(allocator, pos);
            }
            var label_buf: [80]u8 = undefined;
            const label = std.fmt.bufPrint(&label_buf, "add {d} + resolve + drain cycle (zero-alloc)", .{n}) catch "?";
            try report(stdout, label, timestamp() - t0, drain_iters);
        }
    }

    // 1d. wants-partial filtering (promise-to-promise resolution)
    {
        const t0 = timestamp();
        const filter_iters: usize = LISTENER_ITERS / 10;
        var iter: usize = 0;
        while (iter < filter_iters) : (iter += 1) {
            var at = ocapn_session.AnswerTable.init();
            const p = try at.newPromise(allocator);
            const pos = p.answer_pos;
            var j: usize = 0;
            while (j < 10) : (j += 1) {
                const resolver = ocapn_session.ResolverRef{ .position = @intCast(j), .is_promise = j < 5 };
                _ = try p.addListener(allocator, resolver, j < 5);
            }
            try at.resolvePromiseEx(allocator, pos, "<11'desc:answer1+>", true);
            const listeners = try at.byAnswerPos(pos).?.drainListeners(allocator);
            allocator.free(listeners);
            at.deinit(allocator);
        }
        try report(stdout, "wants-partial filter (10 listeners, 50/50)", timestamp() - t0, filter_iters);
    }

    // =====================================================================
    // GAP 3: GiftTable — deposit/withdraw join
    // =====================================================================
    try stdout.print("\n--- Gap 3: GiftTable (3-vat handoff join) ---\n", .{});

    // 3a. Deposit-first ordering
    {
        const t0 = timestamp();
        var gt = ocapn_bootstrap.GiftTable.init();
        defer gt.deinit(allocator);
        var i: usize = 0;
        while (i < GIFT_ITERS) : (i += 1) {
            var gift_id: [ocapn_bootstrap.GIFT_ID_LEN]u8 = undefined;
            std.mem.writeInt(u32, gift_id[0..4], @intCast(i), .little);
            @memset(gift_id[4..], 0xAA);
            const key = ocapn_bootstrap.GiftKey{
                .session_id = [_]u8{0x11} ** 32,
                .gift_id = gift_id,
            };
            const r1 = gt.deposit(allocator, key, "gift-payload") catch unreachable;
            std.mem.doNotOptimizeAway(r1);
            const r2 = gt.withdraw(allocator, key, @intCast(i)) catch unreachable;
            std.mem.doNotOptimizeAway(r2);
            gt.release(allocator, key);
        }
        try report(stdout, "deposit → withdraw → release cycle", timestamp() - t0, GIFT_ITERS);
    }

    // 3b. Withdraw-first ordering (reverse)
    {
        const t0 = timestamp();
        var gt = ocapn_bootstrap.GiftTable.init();
        defer gt.deinit(allocator);
        var i: usize = 0;
        while (i < GIFT_ITERS) : (i += 1) {
            var gift_id: [ocapn_bootstrap.GIFT_ID_LEN]u8 = undefined;
            std.mem.writeInt(u32, gift_id[0..4], @intCast(i), .little);
            @memset(gift_id[4..], 0xBB);
            const key = ocapn_bootstrap.GiftKey{
                .session_id = [_]u8{0x22} ** 32,
                .gift_id = gift_id,
            };
            const r1 = gt.withdraw(allocator, key, @intCast(i)) catch unreachable;
            std.mem.doNotOptimizeAway(r1);
            const r2 = gt.deposit(allocator, key, "reverse-gift") catch unreachable;
            std.mem.doNotOptimizeAway(r2);
            gt.release(allocator, key);
        }
        try report(stdout, "withdraw → deposit → release cycle", timestamp() - t0, GIFT_ITERS);
    }

    // 3c. Lookup in growing table (worst case: linear scan)
    {
        var gt = ocapn_bootstrap.GiftTable.init();
        defer gt.deinit(allocator);
        // Pre-fill table with N pending deposits.
        const table_sizes = [_]usize{ 10, 100, 1000 };
        for (table_sizes) |n| {
            // Reset.
            gt.deinit(allocator);
            gt = ocapn_bootstrap.GiftTable.init();
            var j: usize = 0;
            while (j < n) : (j += 1) {
                var gid: [ocapn_bootstrap.GIFT_ID_LEN]u8 = undefined;
                std.mem.writeInt(u32, gid[0..4], @intCast(j), .little);
                @memset(gid[4..], 0xCC);
                const k = ocapn_bootstrap.GiftKey{
                    .session_id = [_]u8{0x33} ** 32,
                    .gift_id = gid,
                };
                _ = try gt.deposit(allocator, k, "pre-fill");
            }
            // Now withdraw the last entry (worst-case linear scan).
            var last_gid: [ocapn_bootstrap.GIFT_ID_LEN]u8 = undefined;
            std.mem.writeInt(u32, last_gid[0..4], @intCast(n - 1), .little);
            @memset(last_gid[4..], 0xCC);
            const last_key = ocapn_bootstrap.GiftKey{
                .session_id = [_]u8{0x33} ** 32,
                .gift_id = last_gid,
            };
            const lookup_iters: usize = 10_000;
            const t0 = timestamp();
            var i: usize = 0;
            while (i < lookup_iters) : (i += 1) {
                const g = gt.getDeliveredGift(last_key);
                std.mem.doNotOptimizeAway(g);
            }
            var label_buf: [80]u8 = undefined;
            const label = std.fmt.bufPrint(&label_buf, "findSlot worst-case (table size {d})", .{n}) catch "?";
            try report(stdout, label, timestamp() - t0, lookup_iters);
        }
    }

    // 3d. BootstrapMethod.fromSymbol dispatch
    {
        const methods = [_][]const u8{ "fetch", "deposit-gift", "withdraw-gift", "unknown" };
        const t0 = timestamp();
        var i: usize = 0;
        while (i < ITERS) : (i += 1) {
            const m = ocapn_bootstrap.BootstrapMethod.fromSymbol(methods[i % methods.len]);
            std.mem.doNotOptimizeAway(m);
        }
        try report(stdout, "BootstrapMethod.fromSymbol dispatch", timestamp() - t0, ITERS);
    }

    // =====================================================================
    // COMBINED: Full descriptor parse → listener registration cycle
    // =====================================================================
    try stdout.print("\n--- Combined: parse + listen registration ---\n", .{});
    {
        // Simulate: parse op:listen wire bytes → extract descriptors → register listener
        const listen_wire = "<9'op:listen<11'desc:answer3+><18'desc:import-object17+>1't>";
        const combined_iters: usize = 50_000;

        var at = ocapn_session.AnswerTable.init();
        defer at.deinit(allocator);
        _ = try at.newPromise(allocator); // pos 0
        _ = try at.newPromise(allocator); // pos 1
        _ = try at.newPromise(allocator); // pos 2
        _ = try at.newPromise(allocator); // pos 3

        const t0 = timestamp();
        var i: usize = 0;
        while (i < combined_iters) : (i += 1) {
            // Parse
            var parser = syrup.Parser.init(listen_wire, allocator);
            var v = parser.parse() catch unreachable;
            defer v.deinitAll(allocator);
            const r = v.record;

            // Descriptor extraction (typed)
            const wd_to = wire_desc.WireDesc.fromValue(r.fields[0]) catch unreachable;
            const to_desc = wire_desc.ListenTargetDesc.fromWireDesc(wd_to) catch unreachable;
            const wd_listen = wire_desc.WireDesc.fromValue(r.fields[1]) catch unreachable;
            const listen_desc = wire_desc.ResolverDesc.fromWireDesc(wd_listen) catch unreachable;
            _ = to_desc;

            // Zero-alloc listener registration via ResolverRef
            const resolver_ref = ocapn_session.ResolverRef{
                .position = listen_desc.position(),
                .is_promise = listen_desc.isPromise(),
            };
            const p = at.byAnswerPos(3).?;
            const result = p.addListener(allocator, resolver_ref, true) catch unreachable;
            std.mem.doNotOptimizeAway(result);
        }
        try report(stdout, "parse op:listen + extract + addListener", timestamp() - t0, combined_iters);
        try stdout.print("    -> {d} listeners accumulated on promise 3\n", .{
            at.byAnswerPos(3).?.listeners.items.len,
        });
    }

    try stdout.print("\n=== Benchmark complete ===\n\n", .{});
}
