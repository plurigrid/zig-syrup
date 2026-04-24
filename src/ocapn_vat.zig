//! OCapN Vat — minimal interleave point for Guile/Racket Goblins interop.
//!
//! Composition:
//!   OcapnConnection (streaming Syrup transport)
//! + KeyPair + Location (handshake identity)
//! + SwissRegistry (bootstrap/fetch)
//! + AnswerTable (promise pipelining)
//! + ExportTable (wire-delta distributed GC)

const std = @import("std");
const syrup = @import("syrup");
const transport = @import("ocapn_transport");
const handshake = @import("ocapn_handshake");
const location_mod = @import("ocapn_location");
const bootstrap = @import("ocapn_bootstrap");
const session = @import("ocapn_session");
const compat = @import("compat");
const Allocator = std.mem.Allocator;
const ByteList = std.array_list.Managed(u8);

pub const SessionPhase = enum {
    fresh,
    handshake_sent,
    established,
    closed,
};

pub const Vat = struct {
    allocator: Allocator,
    conn: transport.OcapnConnection,
    keypair: handshake.KeyPair,
    my_location: location_mod.Location,
    registry: bootstrap.SwissRegistry,
    answers: session.AnswerTable,
    exports: session.ExportTable,
    phase: SessionPhase = .fresh,

    // Peer state populated during handshake.
    peer_pubkey: ?[32]u8 = null,
    peer_location: ?location_mod.Location = null,

    pub fn init(
        allocator: Allocator,
        conn: transport.OcapnConnection,
        keypair: handshake.KeyPair,
        my_location: location_mod.Location,
    ) Vat {
        return .{
            .allocator = allocator,
            .conn = conn,
            .keypair = keypair,
            .my_location = my_location,
            .registry = bootstrap.SwissRegistry.init(),
            .answers = session.AnswerTable.init(),
            .exports = session.ExportTable.init(),
        };
    }

    pub fn deinit(self: *Vat) void {
        self.answers.deinit(self.allocator);
        self.exports.deinit(self.allocator);
        self.registry.deinit(self.allocator);
        self.conn.deinit();
    }

    /// Send our op:start-session. Transitions fresh → handshake_sent.
    pub fn sendHandshake(self: *Vat) !void {
        if (self.phase != .fresh) return error.BadPhase;
        const sig = try handshake.signLocation(self.keypair, self.my_location, self.allocator);
        const bytes = try handshake.encodeStartSession(
            self.allocator,
            self.keypair.pub_key,
            self.my_location,
            sig,
        );
        defer self.allocator.free(bytes);
        try self.conn.sendBytes(bytes);
        self.phase = .handshake_sent;
    }

    /// Receive the peer's op:start-session, verify the signature, and finalize.
    /// Transitions handshake_sent → established.
    pub fn receiveHandshake(self: *Vat) !void {
        var v = try self.conn.recvValue();
        defer v.deinitAll(self.allocator);
        if (v != .record) return error.InvalidHandshake;
        const r = v.record;
        if (r.label.* != .symbol) return error.InvalidHandshake;
        if (!std.mem.eql(u8, r.label.symbol, "op:start-session")) return error.InvalidHandshake;
        if (r.fields.len < 4) return error.InvalidHandshake;

        // captp-version — currently require 1.0.
        if (r.fields[0] != .string) return error.InvalidHandshake;
        if (!std.mem.eql(u8, r.fields[0].string, handshake.CAPTP_VERSION))
            return error.UnsupportedCaptpVersion;

        // session-pubkey
        if (r.fields[1] != .bytes) return error.InvalidHandshake;
        if (r.fields[1].bytes.len != 32) return error.InvalidHandshake;
        var pk: [32]u8 = undefined;
        @memcpy(&pk, r.fields[1].bytes);

        // acceptable-location
        const peer_loc = try location_mod.Location.fromValue(r.fields[2]);

        // signature envelope
        if (r.fields[3] != .record) return error.InvalidHandshake;
        const sig_r = r.fields[3].record;
        if (sig_r.label.* != .symbol) return error.InvalidHandshake;
        if (!std.mem.eql(u8, sig_r.label.symbol, "sig-envelope")) return error.InvalidHandshake;
        if (sig_r.fields.len < 2) return error.InvalidHandshake;
        if (sig_r.fields[1] != .bytes) return error.InvalidHandshake;
        if (sig_r.fields[1].bytes.len != 64) return error.InvalidSignature;
        var sig_bytes: [64]u8 = undefined;
        @memcpy(&sig_bytes, sig_r.fields[1].bytes);
        const sig = handshake.Signature{ .bytes = sig_bytes };

        const ok = try handshake.verifyLocation(pk, peer_loc, sig, self.allocator);
        if (!ok) return error.BadSignature;

        self.peer_pubkey = pk;
        self.peer_location = peer_loc;
        self.phase = .established;
    }

    /// Register a local sturdy (swiss → export-position). Returns position.
    pub fn exportSturdy(self: *Vat, swiss: [bootstrap.SWISS_LEN]u8) !u32 {
        return self.registry.register(self.allocator, swiss);
    }

    /// Send `op:deliver-only <desc:import-object pos> <symbol method> <args-list>`.
    /// Requires `.established` phase.
    pub fn deliverOnly(
        self: *Vat,
        to_position: u32,
        method: []const u8,
        args: []const syrup.Value,
    ) !void {
        if (self.phase != .established) return error.BadPhase;
        var out = ByteList.init(self.allocator);
        defer out.deinit();
        try out.appendSlice("<15'op:deliver-only");

        // target: desc:import-object <pos>
        try out.writer().print("<18'desc:import-object{d}+>", .{to_position});

        // method as symbol
        try out.writer().print("{d}'", .{method.len});
        try out.appendSlice(method);

        // args as list — encode each Value
        try out.append('[');
        for (args) |a| {
            const b = try a.encodeAlloc(self.allocator);
            defer self.allocator.free(b);
            try out.appendSlice(b);
        }
        try out.append(']');

        try out.append('>');
        try self.conn.sendBytes(out.items);
    }

    /// Send `op:deliver <target> <method> <args> <desc:answer pos> <desc:import-object resolver>`.
    /// Allocates a fresh answer position + local Promise so the peer can send
    /// `op:fulfill`/`op:break` back at us. Returns the answer position the
    /// peer must echo. Requires `.established` phase.
    pub fn deliver(
        self: *Vat,
        to_position: u32,
        method: []const u8,
        args: []const syrup.Value,
    ) !session.AnswerPos {
        if (self.phase != .established) return error.BadPhase;
        const p = try self.answers.newPromise(self.allocator);
        const answer_pos = p.answer_pos;

        var out = ByteList.init(self.allocator);
        defer out.deinit();
        try out.appendSlice("<10'op:deliver");

        try out.writer().print("<18'desc:import-object{d}+>", .{to_position});

        try out.writer().print("{d}'", .{method.len});
        try out.appendSlice(method);

        try out.append('[');
        for (args) |a| {
            const b = try a.encodeAlloc(self.allocator);
            defer self.allocator.free(b);
            try out.appendSlice(b);
        }
        try out.append(']');

        try out.writer().print("<11'desc:answer{d}+>", .{answer_pos});
        try out.writer().print("<18'desc:import-object{d}+>", .{answer_pos});

        try out.append('>');
        try self.conn.sendBytes(out.items);
        return answer_pos;
    }

    /// Send `op:gc-exports <position> <delta>` — informs the peer we dropped
    /// `delta` wire references to their export `position`.
    pub fn gcExports(self: *Vat, position: u32, delta: u32) !void {
        if (self.phase != .established) return error.BadPhase;
        var out = ByteList.init(self.allocator);
        defer out.deinit();
        try out.appendSlice("<13'op:gc-exports");
        try out.writer().print("{d}+", .{position});
        try out.writer().print("{d}+", .{delta});
        try out.append('>');
        try self.conn.sendBytes(out.items);
    }

    /// Send `op:gc-answers <position>` — peer no longer needs this answer.
    pub fn gcAnswers(self: *Vat, position: u32) !void {
        if (self.phase != .established) return error.BadPhase;
        var out = ByteList.init(self.allocator);
        defer out.deinit();
        try out.appendSlice("<13'op:gc-answers");
        try out.writer().print("{d}+", .{position});
        try out.append('>');
        try self.conn.sendBytes(out.items);
    }

    /// Handle incoming `op:gc-exports` from the peer: apply the wire-delta
    /// drop. Returns true when the export is orphaned (wire_count == 0).
    pub fn handleGcExports(self: *Vat, position: u32, delta: u32) bool {
        return self.exports.decref(position, delta);
    }

    /// Send `op:fulfill <desc:answer N> value-bytes` — resolve one of the
    /// peer's outstanding answers positively. `value_syrup` is a pre-encoded
    /// Syrup value (one top-level item).
    pub fn sendFulfill(self: *Vat, answer_pos: u32, value_syrup: []const u8) !void {
        if (self.phase != .established) return error.BadPhase;
        var out = ByteList.init(self.allocator);
        defer out.deinit();
        try out.appendSlice("<10'op:fulfill");
        try out.appendSlice("<11'desc:answer");
        try out.writer().print("{d}+", .{answer_pos});
        try out.append('>');
        try out.appendSlice(value_syrup);
        try out.append('>');
        try self.conn.sendBytes(out.items);
    }

    /// Send `op:break <desc:answer N> reason-bytes` — resolve an answer
    /// negatively with the given reason (any Syrup value).
    pub fn sendBreak(self: *Vat, answer_pos: u32, reason_syrup: []const u8) !void {
        if (self.phase != .established) return error.BadPhase;
        var out = ByteList.init(self.allocator);
        defer out.deinit();
        try out.appendSlice("<8'op:break");
        try out.appendSlice("<11'desc:answer");
        try out.writer().print("{d}+", .{answer_pos});
        try out.append('>');
        try out.appendSlice(reason_syrup);
        try out.append('>');
        try self.conn.sendBytes(out.items);
    }

    /// Common case: resolve an answer with a `<desc:import-object pos>`. The
    /// typical shape of a successful bootstrap `fetch` reply, or any deliver
    /// whose result is a local object reference.
    pub fn sendFulfillImport(self: *Vat, answer_pos: u32, import_pos: u32) !void {
        const payload = try bootstrap.encodeImportObjectAlloc(self.allocator, import_pos);
        defer self.allocator.free(payload);
        try self.sendFulfill(answer_pos, payload);
    }

    /// Server-side helper for a bootstrap `fetch(swiss)` deliver. Looks the
    /// swiss up in `self.registry` and either:
    ///   - fulfills `op.answer_pos` with `<desc:import-object pos>`, or
    ///   - breaks it with the symbol reason `'unknown-swiss`.
    /// Returns true if fulfilled, false if broken. Caller passes the deliver
    /// op (not deliver-only) — fetch always wants a reply.
    pub fn serveBootstrapFetch(
        self: *Vat,
        op: anytype, // IncomingOp.deliver payload (struct with .args, .answer_pos, .method, .target)
    ) !bool {
        if (op.target != bootstrap.BOOTSTRAP_POS) return error.NotBootstrapTarget;
        if (!std.mem.eql(u8, op.method, "fetch")) return error.NotFetchMethod;
        if (op.args.len < 1) return error.MissingSwissArg;
        const swiss = bootstrap.readFetchSwiss(op.args[0]) catch {
            // Reason record: <desc:error 'invalid-swiss>
            //   "desc:error"   = 10 chars
            //   "invalid-swiss" = 13 chars
            try self.sendBreak(op.answer_pos, "<10'desc:error13'invalid-swiss>");
            return false;
        };
        if (self.registry.fetch(swiss)) |pos| {
            try self.sendFulfillImport(op.answer_pos, pos);
            self.exports.incref(pos);
            return true;
        }
        // Reason symbol: 'unknown-swiss (13 chars)
        try self.sendBreak(op.answer_pos, "13'unknown-swiss");
        return false;
    }

    /// Send `op:abort <reason-string>` — terminate the session. Per Racket
    /// reference impl (`captp.rkt`), a conforming peer closes the transport
    /// after sending/receiving this. Callers should close `self.conn` next.
    pub fn sendAbort(self: *Vat, reason: []const u8) !void {
        if (self.phase == .closed) return error.BadPhase;
        var out = ByteList.init(self.allocator);
        defer out.deinit();
        try out.appendSlice("<8'op:abort");
        try out.writer().print("{d}\"", .{reason.len});
        try out.appendSlice(reason);
        try out.append('>');
        try self.conn.sendBytes(out.items);
        self.phase = .closed;
    }

    /// Block for the next incoming top-level Syrup value. Caller inspects it.
    pub fn recvNext(self: *Vat) !syrup.Value {
        return self.conn.recvValue();
    }

    pub const IncomingOp = union(enum) {
        deliver_only: struct { target: u32, method: []const u8, args: []const syrup.Value },
        deliver: struct {
            target: u32,
            method: []const u8,
            args: []const syrup.Value,
            answer_pos: u32,
            resolver_pos: u32,
        },
        fulfill: struct { answer_pos: u32, value: syrup.Value },
        @"break": struct { answer_pos: u32, reason: syrup.Value },
        gc_exports: struct { position: u32, delta: u32 },
        gc_answers: struct { position: u32 },
        abort: struct { reason: []const u8 },
        unknown: syrup.Value,
    };

    /// Block for one incoming op and classify it. The returned IncomingOp
    /// borrows from the underlying `syrup.Value` — caller must `deinitAll`
    /// the wrapping value after handling. For `fulfill` the promise has
    /// already been moved into the `AnswerTable` by `handleFulfill`, so the
    /// caller only needs to free the outer Value.
    pub fn recvAndDispatch(self: *Vat) !struct { op: IncomingOp, value: syrup.Value } {
        var v = try self.conn.recvValue();
        errdefer v.deinitAll(self.allocator);
        if (v != .record) return .{ .op = .{ .unknown = v }, .value = v };
        const r = v.record;
        if (r.label.* != .symbol) return .{ .op = .{ .unknown = v }, .value = v };
        const tag = r.label.symbol;

        if (std.mem.eql(u8, tag, "op:deliver-only") and r.fields.len >= 3) {
            const target = try readImportObjectPos(r.fields[0]);
            if (r.fields[1] != .symbol) return error.InvalidMessage;
            if (r.fields[2] != .list) return error.InvalidMessage;
            return .{ .op = .{ .deliver_only = .{
                .target = target,
                .method = r.fields[1].symbol,
                .args = r.fields[2].list,
            } }, .value = v };
        }
        if (std.mem.eql(u8, tag, "op:deliver") and r.fields.len >= 5) {
            const target = try readImportObjectPos(r.fields[0]);
            if (r.fields[1] != .symbol) return error.InvalidMessage;
            if (r.fields[2] != .list) return error.InvalidMessage;
            const answer_pos = try readAnswerPos(r.fields[3]);
            const resolver_pos = try readImportObjectPos(r.fields[4]);
            return .{ .op = .{ .deliver = .{
                .target = target,
                .method = r.fields[1].symbol,
                .args = r.fields[2].list,
                .answer_pos = answer_pos,
                .resolver_pos = resolver_pos,
            } }, .value = v };
        }
        if (std.mem.eql(u8, tag, "op:fulfill") and r.fields.len >= 2) {
            const answer_pos = try readAnswerPos(r.fields[0]);
            // Serialize the payload back to canonical bytes and store in
            // the promise — matches session.AnswerTable.resolvePromise.
            const payload_bytes = try r.fields[1].encodeAlloc(self.allocator);
            defer self.allocator.free(payload_bytes);
            try self.answers.resolvePromise(self.allocator, answer_pos, payload_bytes);
            return .{ .op = .{ .fulfill = .{
                .answer_pos = answer_pos,
                .value = r.fields[1],
            } }, .value = v };
        }
        if (std.mem.eql(u8, tag, "op:break") and r.fields.len >= 2) {
            const answer_pos = try readAnswerPos(r.fields[0]);
            try self.answers.breakPromise(answer_pos);
            return .{ .op = .{ .@"break" = .{
                .answer_pos = answer_pos,
                .reason = r.fields[1],
            } }, .value = v };
        }
        if (std.mem.eql(u8, tag, "op:gc-exports") and r.fields.len >= 2) {
            const position = try readInt(u32, r.fields[0]);
            const delta = try readInt(u32, r.fields[1]);
            const orphaned = self.exports.decref(position, delta);
            if (orphaned) self.exports.release(position);
            return .{ .op = .{ .gc_exports = .{ .position = position, .delta = delta } }, .value = v };
        }
        if (std.mem.eql(u8, tag, "op:gc-answers") and r.fields.len >= 1) {
            const position = try readInt(u32, r.fields[0]);
            // Best-effort drop; an unknown pos may legitimately mean we
            // already released locally and the peer's gc raced us.
            self.answers.releasePromise(self.allocator, position) catch |e| switch (e) {
                error.UnknownAnswerPos => {},
                else => return e,
            };
            return .{ .op = .{ .gc_answers = .{ .position = position } }, .value = v };
        }
        if (std.mem.eql(u8, tag, "op:abort") and r.fields.len >= 1) {
            // reason is a Syrup string; accept symbol too for leniency.
            const reason = switch (r.fields[0]) {
                .string => |s| s,
                .symbol => |s| s,
                else => return error.InvalidMessage,
            };
            self.phase = .closed;
            return .{ .op = .{ .abort = .{ .reason = reason } }, .value = v };
        }
        return .{ .op = .{ .unknown = v }, .value = v };
    }
};

// Helpers used by recvAndDispatch — keep them file-scoped.
fn readImportObjectPos(v: syrup.Value) !u32 {
    if (v != .record) return error.InvalidMessage;
    if (v.record.label.* != .symbol) return error.InvalidMessage;
    if (!std.mem.eql(u8, v.record.label.symbol, "desc:import-object")) return error.InvalidMessage;
    if (v.record.fields.len < 1) return error.InvalidMessage;
    return readInt(u32, v.record.fields[0]);
}

fn readAnswerPos(v: syrup.Value) !u32 {
    if (v != .record) return error.InvalidMessage;
    if (v.record.label.* != .symbol) return error.InvalidMessage;
    if (!std.mem.eql(u8, v.record.label.symbol, "desc:answer")) return error.InvalidMessage;
    if (v.record.fields.len < 1) return error.InvalidMessage;
    return readInt(u32, v.record.fields[0]);
}

fn readInt(comptime T: type, v: syrup.Value) !T {
    return switch (v) {
        .integer => |i| std.math.cast(T, i) orelse error.IntOutOfRange,
        else => error.InvalidMessage,
    };
}

// ---- Tests ------------------------------------------------------------------

test "two Vats: full handshake round-trip over localhost" {
    const allocator = std.testing.allocator;

    const addr = try compat.Address.parseIp4("127.0.0.1", 0);
    var server = try addr.listen(.{ .reuse_address = true });
    defer server.deinit();
    const bound = server.listen_address;

    const kp_a = try handshake.KeyPair.generate();
    var b32_a = ByteList.init(allocator);
    defer b32_a.deinit();
    try location_mod.base32LowerEncode(&b32_a, &kp_a.pub_key);
    const loc_a = location_mod.Location{ .netlayer = .tcp, .designator = b32_a.items };

    const ctx = struct {
        bound: compat.Address,
        err: ?anyerror = null,
        pub fn run(ptr: *@This()) void {
            const stream = compat.tcpConnectToAddress(ptr.bound) catch |e| {
                ptr.err = e;
                return;
            };
            const conn_b = transport.OcapnConnection.init(std.testing.allocator, stream);
            const kp_b = handshake.KeyPair.generate() catch |e| {
                ptr.err = e;
                return;
            };
            var b32_b = ByteList.init(std.testing.allocator);
            defer b32_b.deinit();
            location_mod.base32LowerEncode(&b32_b, &kp_b.pub_key) catch |e| {
                ptr.err = e;
                return;
            };
            const loc_b = location_mod.Location{ .netlayer = .tcp, .designator = b32_b.items };
            var vat_b = Vat.init(std.testing.allocator, conn_b, kp_b, loc_b);
            defer vat_b.deinit();
            vat_b.sendHandshake() catch |e| {
                ptr.err = e;
                return;
            };
            vat_b.receiveHandshake() catch |e| {
                ptr.err = e;
                return;
            };
        }
    };
    var peer_ctx = ctx{ .bound = bound };
    const th = try std.Thread.spawn(.{}, ctx.run, .{&peer_ctx});

    const accepted = try server.accept();
    var vat_a = Vat.init(
        allocator,
        transport.OcapnConnection.init(allocator, accepted.stream),
        kp_a,
        loc_a,
    );
    defer vat_a.deinit();

    // A sends, then receives B's handshake.
    try vat_a.sendHandshake();
    try vat_a.receiveHandshake();

    th.join();
    try std.testing.expectEqual(@as(?anyerror, null), peer_ctx.err);
    try std.testing.expectEqual(SessionPhase.established, vat_a.phase);
    try std.testing.expect(vat_a.peer_pubkey != null);
}

// The following are encoder round-trip tests. Each op that the Vat emits
// must parse cleanly via `syrup.Parser.parse` — otherwise a length-prefix
// typo can sit undetected (as several did before 2026-04-18).

fn encodeDeliverOnlyForTest(allocator: std.mem.Allocator, to_position: u32, method: []const u8) ![]u8 {
    var out = ByteList.init(allocator);
    errdefer out.deinit();
    try out.appendSlice("<15'op:deliver-only");
    try out.writer().print("<18'desc:import-object{d}+>", .{to_position});
    try out.writer().print("{d}'", .{method.len});
    try out.appendSlice(method);
    try out.append('[');
    try out.append(']');
    try out.append('>');
    return out.toOwnedSlice();
}

test "emitter round-trip: op:deliver-only parses as op:deliver-only record" {
    const allocator = std.testing.allocator;
    const bytes = try encodeDeliverOnlyForTest(allocator, 3, "hello");
    defer allocator.free(bytes);
    var parser = syrup.Parser.init(bytes, allocator);
    var v = try parser.parse();
    defer v.deinitAll(allocator);
    try std.testing.expect(v == .record);
    try std.testing.expect(v.record.label.* == .symbol);
    try std.testing.expectEqualStrings("op:deliver-only", v.record.label.symbol);
    try std.testing.expectEqual(@as(usize, 3), v.record.fields.len);
}

fn encodeDeliverForTest(allocator: std.mem.Allocator, to_position: u32, method: []const u8, answer_pos: u32) ![]u8 {
    var out = ByteList.init(allocator);
    errdefer out.deinit();
    try out.appendSlice("<10'op:deliver");
    try out.writer().print("<18'desc:import-object{d}+>", .{to_position});
    try out.writer().print("{d}'", .{method.len});
    try out.appendSlice(method);
    try out.append('[');
    try out.append(']');
    try out.writer().print("<11'desc:answer{d}+>", .{answer_pos});
    try out.writer().print("<18'desc:import-object{d}+>", .{answer_pos});
    try out.append('>');
    return out.toOwnedSlice();
}

test "emitter round-trip: op:deliver parses with 5 fields" {
    const allocator = std.testing.allocator;
    const bytes = try encodeDeliverForTest(allocator, 7, "fetch", 4);
    defer allocator.free(bytes);
    var parser = syrup.Parser.init(bytes, allocator);
    var v = try parser.parse();
    defer v.deinitAll(allocator);
    try std.testing.expect(v == .record);
    try std.testing.expectEqualStrings("op:deliver", v.record.label.symbol);
    try std.testing.expectEqual(@as(usize, 5), v.record.fields.len);
    // Field 3 is desc:answer.
    try std.testing.expect(v.record.fields[3] == .record);
    try std.testing.expectEqualStrings("desc:answer", v.record.fields[3].record.label.symbol);
}

test "emitter round-trip: op:gc-exports parses as two-int record" {
    const allocator = std.testing.allocator;
    var out = ByteList.init(allocator);
    defer out.deinit();
    try out.appendSlice("<13'op:gc-exports");
    try out.writer().print("{d}+", .{@as(u32, 1)});
    try out.writer().print("{d}+", .{@as(u32, 2)});
    try out.append('>');

    var parser = syrup.Parser.init(out.items, allocator);
    var v = try parser.parse();
    defer v.deinitAll(allocator);
    try std.testing.expect(v == .record);
    try std.testing.expectEqualStrings("op:gc-exports", v.record.label.symbol);
    try std.testing.expectEqual(@as(usize, 2), v.record.fields.len);
}

test "emitter round-trip: op:gc-answers parses" {
    const allocator = std.testing.allocator;
    var out = ByteList.init(allocator);
    defer out.deinit();
    try out.appendSlice("<13'op:gc-answers");
    try out.writer().print("{d}+", .{@as(u32, 5)});
    try out.append('>');

    var parser = syrup.Parser.init(out.items, allocator);
    var v = try parser.parse();
    defer v.deinitAll(allocator);
    try std.testing.expect(v == .record);
    try std.testing.expectEqualStrings("op:gc-answers", v.record.label.symbol);
}

test "emitter shape: op:fulfill with desc:answer + inline value parses" {
    const allocator = std.testing.allocator;
    // Build the exact bytes sendFulfill would write, then roundtrip.
    var out = ByteList.init(allocator);
    defer out.deinit();
    try out.appendSlice("<10'op:fulfill");
    try out.appendSlice("<11'desc:answer");
    try out.writer().print("{d}+", .{@as(u32, 42)});
    try out.append('>');
    // value = integer 7
    try out.writer().print("{d}+", .{@as(u32, 7)});
    try out.append('>');

    var parser = syrup.Parser.init(out.items, allocator);
    var v = try parser.parse();
    defer v.deinitAll(allocator);
    try std.testing.expect(v == .record);
    try std.testing.expectEqualStrings("op:fulfill", v.record.label.symbol);
    try std.testing.expectEqual(@as(usize, 2), v.record.fields.len);
    try std.testing.expectEqualStrings("desc:answer", v.record.fields[0].record.label.symbol);
}

test "serveBootstrapFetch reason payloads parse as Syrup" {
    const allocator = std.testing.allocator;

    // <desc:error 'invalid-swiss> — record with one symbol field.
    {
        var parser = syrup.Parser.init("<10'desc:error13'invalid-swiss>", allocator);
        var v = try parser.parse();
        defer v.deinitAll(allocator);
        try std.testing.expect(v == .record);
        try std.testing.expectEqualStrings("desc:error", v.record.label.symbol);
        try std.testing.expectEqual(@as(usize, 1), v.record.fields.len);
        try std.testing.expectEqualStrings("invalid-swiss", v.record.fields[0].symbol);
    }
    // 'unknown-swiss — bare symbol.
    {
        var parser = syrup.Parser.init("13'unknown-swiss", allocator);
        var v = try parser.parse();
        defer v.deinitAll(allocator);
        try std.testing.expect(v == .symbol);
        try std.testing.expectEqualStrings("unknown-swiss", v.symbol);
    }
}

test "emitter shape: op:abort with reason string parses" {
    const allocator = std.testing.allocator;
    var out = ByteList.init(allocator);
    defer out.deinit();
    const reason = "peer-requested-shutdown";
    try out.appendSlice("<8'op:abort");
    try out.writer().print("{d}\"", .{reason.len});
    try out.appendSlice(reason);
    try out.append('>');

    var parser = syrup.Parser.init(out.items, allocator);
    var v = try parser.parse();
    defer v.deinitAll(allocator);
    try std.testing.expect(v == .record);
    try std.testing.expectEqualStrings("op:abort", v.record.label.symbol);
    try std.testing.expectEqual(@as(usize, 1), v.record.fields.len);
    try std.testing.expectEqualStrings(reason, v.record.fields[0].string);
}

test "emitter shape: op:break with desc:answer + reason parses" {
    const allocator = std.testing.allocator;
    var out = ByteList.init(allocator);
    defer out.deinit();
    try out.appendSlice("<8'op:break");
    try out.appendSlice("<11'desc:answer");
    try out.writer().print("{d}+", .{@as(u32, 9)});
    try out.append('>');
    // reason = symbol 'oops
    try out.appendSlice("4'oops");
    try out.append('>');

    var parser = syrup.Parser.init(out.items, allocator);
    var v = try parser.parse();
    defer v.deinitAll(allocator);
    try std.testing.expect(v == .record);
    try std.testing.expectEqualStrings("op:break", v.record.label.symbol);
    try std.testing.expectEqual(@as(usize, 2), v.record.fields.len);
}
