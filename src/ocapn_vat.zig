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
const wire_desc = @import("wire_desc");
const Allocator = std.mem.Allocator;
const ByteList = std.array_list.Managed(u8);

// 0.16 compat: Managed ArrayList lost its .writer() method. This helper formats
// to a stack buffer and appends, preserving the one-call ergonomics at call sites.
fn fmtAppend(list: *ByteList, comptime fmt: []const u8, args: anytype) !void {
    var tmp: [128]u8 = undefined;
    try list.appendSlice(try std.fmt.bufPrint(&tmp, fmt, args));
}

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
    /// Derived session ID: SHA256^2("prot0" || sort(my_public_id, peer_public_id)).
    /// Computed after handshake completes. Used for gift table keying.
    session_id: ?[32]u8 = null,

    gifts: bootstrap.GiftTable,

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
            .gifts = bootstrap.GiftTable.init(),
        };
    }

    pub fn deinit(self: *Vat) void {
        self.answers.deinit(self.allocator);
        self.exports.deinit(self.allocator);
        self.registry.deinit(self.allocator);
        self.gifts.deinit(self.allocator);
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
        defer v.deinitContainers(self.allocator);
        if (v != .record) return error.InvalidHandshake;
        const r = v.record;
        if (r.label.* != .symbol) return error.InvalidHandshake;
        if (!std.mem.eql(u8, r.label.symbol, "op:start-session")) return error.InvalidHandshake;
        if (r.fields.len < 4) return error.InvalidHandshake;

        // captp-version — currently require 1.0.
        if (r.fields[0] != .string) return error.InvalidHandshake;
        if (!std.mem.eql(u8, r.fields[0].string, handshake.CAPTP_VERSION))
            return error.UnsupportedCaptpVersion;

        // session-pubkey (gcrypt s-expression format)
        const pk = handshake.decodeGcryptPubkey(r.fields[1]) catch return error.InvalidHandshake;

        // acceptable-location
        const peer_loc = try location_mod.Location.fromValue(r.fields[2]);

        // signature envelope: <desc:sig-envelope scheme sig-val-sexp>
        if (r.fields[3] != .record) return error.InvalidHandshake;
        const sig_r = r.fields[3].record;
        if (sig_r.label.* != .symbol) return error.InvalidHandshake;
        if (!std.mem.eql(u8, sig_r.label.symbol, "desc:sig-envelope")) return error.InvalidHandshake;
        if (sig_r.fields.len < 2) return error.InvalidHandshake;
        // fields[1] is the gcrypt sig-val s-expression (a Syrup list)
        const sig_raw = handshake.decodeGcryptSignature(sig_r.fields[1]) catch return error.InvalidSignature;
        const sig = handshake.Signature{ .bytes = sig_raw };

        const ok = try handshake.verifyLocation(pk, peer_loc, sig, self.allocator);
        if (!ok) return error.BadSignature;

        self.peer_pubkey = pk;
        self.peer_location = peer_loc;

        // Derive session ID from both public identifiers.
        const my_id = try handshake.derivePublicId(self.allocator, self.keypair.pub_key);
        const peer_id = try handshake.derivePublicId(self.allocator, pk);
        self.session_id = handshake.deriveSessionId(my_id, peer_id);

        self.phase = .established;
    }

    /// Register a local sturdy (swiss → export-position). Returns position.
    pub fn exportSturdy(self: *Vat, swiss: [bootstrap.SWISS_LEN]u8) !u32 {
        return self.registry.register(self.allocator, swiss);
    }

    /// Send `op:deliver-only <desc:export pos> [method-sym args...]>`.
    /// Spec: 2 fields (to-desc, args). Method is the first element of args
    /// by convention. Requires `.established` phase.
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

        // to-desc: desc:export
        try fmtAppend(&out, "<11'desc:export{d}+>", .{to_position});

        // args: [method-symbol, ...extra-args]
        try out.append('[');
        try fmtAppend(&out, "{d}'", .{method.len});
        try out.appendSlice(method);
        for (args) |a| {
            const b = try a.encodeAlloc(self.allocator);
            defer self.allocator.free(b);
            try out.appendSlice(b);
        }
        try out.append(']');

        try out.append('>');
        try self.conn.sendBytes(out.items);
    }

    /// Send `op:deliver <desc:export pos> [method-sym args...] answer-pos resolve-me-desc>`.
    /// Spec: 4 fields (to-desc, args, answer-pos, resolve-me-desc). Method
    /// is the first element of args by convention. Allocates a fresh answer
    /// position + local Promise. Returns the answer position. Requires
    /// `.established` phase.
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

        // to-desc: desc:export
        try fmtAppend(&out, "<11'desc:export{d}+>", .{to_position});

        // args: [method-symbol, ...extra-args]
        try out.append('[');
        try fmtAppend(&out, "{d}'", .{method.len});
        try out.appendSlice(method);
        for (args) |a| {
            const b = try a.encodeAlloc(self.allocator);
            defer self.allocator.free(b);
            try out.appendSlice(b);
        }
        try out.append(']');

        // answer-pos (integer or false)
        try fmtAppend(&out, "{d}+", .{answer_pos});

        // resolve-me-desc
        try fmtAppend(&out, "<18'desc:import-object{d}+>", .{answer_pos});

        try out.append('>');
        try self.conn.sendBytes(out.items);
        return answer_pos;
    }

    /// GC export entry for batch gc-exports messages.
    pub const GcExportEntry = struct { position: u32, delta: u32 };

    /// Send `op:gc-exports [positions] [wire-deltas]` — spec-conformant list
    /// form. Informs the peer we dropped references to their exports.
    pub fn gcExports(self: *Vat, position: u32, delta: u32) !void {
        return self.gcExportsBatch(&.{GcExportEntry{ .position = position, .delta = delta }});
    }

    /// Batch variant: send multiple gc-exports entries in one message.
    pub fn gcExportsBatch(self: *Vat, entries: []const GcExportEntry) !void {
        if (self.phase != .established) return error.BadPhase;
        var out = ByteList.init(self.allocator);
        defer out.deinit();
        try out.appendSlice("<13'op:gc-exports");
        // positions list
        try out.append('[');
        for (entries) |e| try fmtAppend(&out, "{d}+", .{e.position});
        try out.append(']');
        // wire-deltas list
        try out.append('[');
        for (entries) |e| try fmtAppend(&out, "{d}+", .{e.delta});
        try out.append(']');
        try out.append('>');
        try self.conn.sendBytes(out.items);
    }

    /// Send `op:gc-answers [answer-positions]` — spec-conformant list form.
    /// Peer no longer needs these answers.
    pub fn gcAnswers(self: *Vat, position: u32) !void {
        return self.gcAnswersBatch(&.{position});
    }

    /// Batch variant: release multiple answer positions in one message.
    pub fn gcAnswersBatch(self: *Vat, positions: []const u32) !void {
        if (self.phase != .established) return error.BadPhase;
        var out = ByteList.init(self.allocator);
        defer out.deinit();
        try out.appendSlice("<13'op:gc-answers");
        try out.append('[');
        for (positions) |p| try fmtAppend(&out, "{d}+", .{p});
        try out.append(']');
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
        try fmtAppend(&out, "{d}+", .{answer_pos});
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
        try fmtAppend(&out, "{d}+", .{answer_pos});
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

    /// Handle an incoming op:listen. Registers the listener on the promise;
    /// if already resolved/broken, sends immediate notification. Returns true
    /// if notification was sent immediately, false if deferred.
    pub fn handleListen(self: *Vat, op: IncomingOp.listen) !bool {
        if (self.phase != .established) return error.BadPhase;
        const answer_pos = op.to_desc.position();
        const p = self.answers.byAnswerPos(answer_pos) orelse return error.UnknownAnswerPos;

        const resolver_ref = session.ResolverRef{
            .position = op.listen_desc.position(),
            .is_promise = op.listen_desc.isPromise(),
        };

        const immediate = try p.addListener(self.allocator, resolver_ref, op.wants_partial);
        if (immediate) |listener| {
            if (p.state == .resolved) {
                try self.sendNotifyFulfill(listener.resolver, p.resolved_bytes.items);
            } else if (p.state == .broken) {
                try self.sendNotifyBreak(listener.resolver, p.resolved_bytes.items);
            }
            return true;
        }
        return false;
    }

    /// Notify all eligible listeners after a promise resolution. Batches
    /// all notifications into a single write to reduce syscall overhead.
    pub fn notifyListeners(self: *Vat, answer_pos: u32) !void {
        const p = self.answers.byAnswerPos(answer_pos) orelse return;
        const listeners = try p.drainListeners(self.allocator);
        defer self.allocator.free(listeners);
        if (listeners.len == 0) return;

        // Batch: collect all notification bytes into one buffer, send once.
        var batch = ByteList.init(self.allocator);
        defer batch.deinit();
        for (listeners) |listener| {
            if (p.state == .resolved) {
                try appendNotifyFulfill(&batch, listener.resolver, p.resolved_bytes.items);
            } else if (p.state == .broken) {
                try appendNotifyBreak(&batch, listener.resolver, p.resolved_bytes.items);
            }
        }
        if (batch.items.len > 0) {
            try self.conn.sendBytes(batch.items);
        }
    }

    /// Encode a resolver descriptor inline into a ByteList. Avoids a
    /// separate heap allocation per notification.
    fn appendResolverDesc(out: *ByteList, resolver: session.ResolverRef) !void {
        if (resolver.is_promise) {
            try out.appendSlice("<19'desc:import-promise");
        } else {
            try out.appendSlice("<18'desc:import-object");
        }
        try fmtAppend(out, "{d}+>", .{resolver.position});
    }

    fn appendNotifyFulfill(out: *ByteList, resolver: session.ResolverRef, value_bytes: []const u8) !void {
        try out.appendSlice("<15'op:deliver-only");
        try appendResolverDesc(out, resolver);
        try out.appendSlice("7'fulfill[");
        try out.appendSlice(value_bytes);
        try out.appendSlice("]>");
    }

    fn appendNotifyBreak(out: *ByteList, resolver: session.ResolverRef, reason_bytes: []const u8) !void {
        try out.appendSlice("<15'op:deliver-only");
        try appendResolverDesc(out, resolver);
        try out.appendSlice("5'break[");
        try out.appendSlice(reason_bytes);
        try out.appendSlice("]>");
    }

    fn sendNotifyFulfill(self: *Vat, resolver: session.ResolverRef, value_bytes: []const u8) !void {
        var out = ByteList.init(self.allocator);
        defer out.deinit();
        try appendNotifyFulfill(&out, resolver, value_bytes);
        try self.conn.sendBytes(out.items);
    }

    fn sendNotifyBreak(self: *Vat, resolver: session.ResolverRef, reason_bytes: []const u8) !void {
        var out = ByteList.init(self.allocator);
        defer out.deinit();
        try appendNotifyBreak(&out, resolver, reason_bytes);
        try self.conn.sendBytes(out.items);
    }

    /// Server-side helper for a bootstrap `fetch(swiss)` deliver. Looks the
    /// swiss up in `self.registry` and either:
    ///   - fulfills `op.answer_pos` with `<desc:import-object pos>`, or
    ///   - breaks it with the symbol reason `'unknown-swiss`.
    /// Returns true if fulfilled, false if broken.
    pub fn serveBootstrapFetch(
        self: *Vat,
        op: anytype,
    ) !bool {
        if (op.target.position() != bootstrap.BOOTSTRAP_POS) return error.NotBootstrapTarget;
        if (!std.mem.eql(u8, op.method, "fetch")) return error.NotFetchMethod;
        if (op.args.len < 1) return error.MissingSwissArg;
        const swiss = bootstrap.readFetchSwiss(op.args[0]) catch {
            try self.sendBreak(op.answer_pos, "<10'desc:error13'invalid-swiss>");
            return false;
        };
        if (self.registry.fetch(swiss)) |pos| {
            try self.sendFulfillImport(op.answer_pos, pos);
            self.exports.incref(pos);
            return true;
        }
        try self.sendBreak(op.answer_pos, "13'unknown-swiss");
        return false;
    }

    /// Server-side bootstrap dispatch: route to fetch, deposit-gift, or
    /// withdraw-gift based on the method symbol. Replaces the old
    /// fetch-only pattern.
    pub fn serveBootstrap(
        self: *Vat,
        op: anytype,
        peer_session_id: [32]u8,
    ) !bool {
        if (op.target.position() != bootstrap.BOOTSTRAP_POS) return error.NotBootstrapTarget;
        const method = bootstrap.BootstrapMethod.fromSymbol(op.method) orelse {
            try self.sendBreak(op.answer_pos, "14'unknown-method");
            return false;
        };
        switch (method) {
            .fetch => return self.serveBootstrapFetch(op),
            .deposit_gift => {
                // args: [gift-id-bytes, gift-desc]
                if (op.args.len < 2) {
                    try self.sendBreak(op.answer_pos, "<10'desc:error12'missing-args>");
                    return false;
                }
                if (op.args[0] != .bytes or op.args[0].bytes.len != bootstrap.GIFT_ID_LEN) {
                    try self.sendBreak(op.answer_pos, "<10'desc:error14'invalid-gift-id>");
                    return false;
                }
                var gift_id: [bootstrap.GIFT_ID_LEN]u8 = undefined;
                @memcpy(&gift_id, op.args[0].bytes);
                const key = bootstrap.GiftKey{ .session_id = peer_session_id, .gift_id = gift_id };
                // Encode the gift descriptor to owned bytes.
                const desc_bytes = try op.args[1].encodeAlloc(self.allocator);
                defer self.allocator.free(desc_bytes);
                const result = try self.gifts.deposit(self.allocator, key, desc_bytes);
                switch (result) {
                    .delivered => {
                        // Withdrawal was waiting — fulfill it now.
                        if (self.gifts.getWithdrawAnswerPos(key)) |w_pos| {
                            try self.sendFulfill(w_pos, desc_bytes);
                        }
                        // Acknowledge the deposit.
                        try self.sendFulfill(op.answer_pos, "1't");
                        self.gifts.release(self.allocator, key);
                    },
                    .held => try self.sendFulfill(op.answer_pos, "1't"),
                    .duplicate => {
                        try self.sendBreak(op.answer_pos, "14'duplicate-gift");
                        return false;
                    },
                }
                return true;
            },
            .withdraw_gift => {
                // args: [desc:handoff-receive]
                if (op.args.len < 1) {
                    try self.sendBreak(op.answer_pos, "<10'desc:error12'missing-args>");
                    return false;
                }
                // Extract gift-id from the handoff-receive's inner handoff-give.
                // For now: accept a raw gift-id bytestring as arg[0] for
                // bootstrapping the flow. Full desc:handoff-receive verification
                // is in ocapn_handoff.zig and will be wired when the signature
                // verification path is integrated.
                if (op.args[0] != .bytes or op.args[0].bytes.len != bootstrap.GIFT_ID_LEN) {
                    try self.sendBreak(op.answer_pos, "<10'desc:error14'invalid-gift-id>");
                    return false;
                }
                var gift_id: [bootstrap.GIFT_ID_LEN]u8 = undefined;
                @memcpy(&gift_id, op.args[0].bytes);
                const key = bootstrap.GiftKey{ .session_id = peer_session_id, .gift_id = gift_id };
                const result = try self.gifts.withdraw(self.allocator, key, op.answer_pos);
                switch (result) {
                    .delivered => {
                        if (self.gifts.getDeliveredGift(key)) |gift_bytes| {
                            try self.sendFulfill(op.answer_pos, gift_bytes);
                        }
                        self.gifts.release(self.allocator, key);
                    },
                    .held => {}, // Waiting for deposit; will fulfill on arrival.
                    .duplicate => {
                        try self.sendBreak(op.answer_pos, "19'duplicate-withdrawal");
                        return false;
                    },
                }
                return true;
            },
        }
    }

    /// Send `op:abort <reason-string>` — terminate the session. Per Racket
    /// reference impl (`captp.rkt`), a conforming peer closes the transport
    /// after sending/receiving this. Callers should close `self.conn` next.
    pub fn sendAbort(self: *Vat, reason: []const u8) !void {
        if (self.phase == .closed) return error.BadPhase;
        var out = ByteList.init(self.allocator);
        defer out.deinit();
        try out.appendSlice("<8'op:abort");
        try fmtAppend(&out, "{d}\"", .{reason.len});
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
        deliver_only: struct {
            target: wire_desc.TargetDesc,
            method: []const u8,
            args: []const syrup.Value,
        },
        deliver: struct {
            target: wire_desc.TargetDesc,
            method: []const u8,
            args: []const syrup.Value,
            answer_pos: u32,
            resolver: wire_desc.ResolverDesc,
        },
        listen: struct {
            to_desc: wire_desc.ListenTargetDesc,
            listen_desc: wire_desc.ResolverDesc,
            wants_partial: bool,
        },
        fulfill: struct { answer_pos: u32, value: syrup.Value },
        @"break": struct { answer_pos: u32, reason: syrup.Value },
        gc_exports: struct { positions: []const u32, deltas: []const u32 },
        gc_answers: struct { positions: []const u32 },
        abort: struct { reason: []const u8 },
        unknown: syrup.Value,
    };

    /// Block for one incoming op and classify it. The returned IncomingOp
    /// borrows from the underlying `syrup.Value` — caller must `deinitContainers`
    /// the wrapping value after handling. For `fulfill` the promise has
    /// already been moved into the `AnswerTable` by `handleFulfill`, so the
    /// caller only needs to free the outer Value.
    pub fn recvAndDispatch(self: *Vat) !struct { op: IncomingOp, value: syrup.Value } {
        var v = try self.conn.recvValue();
        errdefer v.deinitContainers(self.allocator);
        if (v != .record) return .{ .op = .{ .unknown = v }, .value = v };
        const r = v.record;
        if (r.label.* != .symbol) return .{ .op = .{ .unknown = v }, .value = v };
        const tag = r.label.symbol;

        if (std.mem.eql(u8, tag, "op:deliver-only") and r.fields.len >= 2) {
            // Spec: 2 fields — to-desc, args. Method is args[0] by convention.
            const wd = wire_desc.WireDesc.fromValue(r.fields[0]) catch return error.InvalidMessage;
            const target = wire_desc.TargetDesc.fromWireDesc(wd) catch return error.InvalidMessage;
            if (r.fields[1] != .list) return error.InvalidMessage;
            const args_list = r.fields[1].list;
            if (args_list.len < 1 or args_list[0] != .symbol) return error.InvalidMessage;
            return .{ .op = .{ .deliver_only = .{
                .target = target,
                .method = args_list[0].symbol,
                .args = if (args_list.len > 1) args_list[1..] else &.{},
            } }, .value = v };
        }
        if (std.mem.eql(u8, tag, "op:deliver") and r.fields.len >= 4) {
            // Spec: 4 fields — to-desc, args, answer-pos, resolve-me-desc.
            const wd_target = wire_desc.WireDesc.fromValue(r.fields[0]) catch return error.InvalidMessage;
            const target = wire_desc.TargetDesc.fromWireDesc(wd_target) catch return error.InvalidMessage;
            if (r.fields[1] != .list) return error.InvalidMessage;
            const args_list = r.fields[1].list;
            if (args_list.len < 1 or args_list[0] != .symbol) return error.InvalidMessage;
            // answer-pos: integer or false.
            const answer_pos = blk: {
                if (r.fields[2] == .bool and !r.fields[2].bool) break :blk @as(u32, 0);
                break :blk readInt(u32, r.fields[2]) catch return error.InvalidMessage;
            };
            // resolve-me-desc: desc:import-object OR desc:import-promise OR false.
            const resolver = blk: {
                if (r.fields[3] == .bool and !r.fields[3].bool) {
                    break :blk wire_desc.ResolverDesc{ .import_object = 0 };
                }
                const wd_res = wire_desc.WireDesc.fromValue(r.fields[3]) catch return error.InvalidMessage;
                break :blk wire_desc.ResolverDesc.fromWireDesc(wd_res) catch return error.InvalidMessage;
            };
            return .{ .op = .{ .deliver = .{
                .target = target,
                .method = args_list[0].symbol,
                .args = if (args_list.len > 1) args_list[1..] else &.{},
                .answer_pos = answer_pos,
                .resolver = resolver,
            } }, .value = v };
        }
        // Gap 1: op:listen — promise observation.
        if (std.mem.eql(u8, tag, "op:listen") and r.fields.len >= 3) {
            const wd_to = wire_desc.WireDesc.fromValue(r.fields[0]) catch return error.InvalidMessage;
            const to_desc = wire_desc.ListenTargetDesc.fromWireDesc(wd_to) catch return error.InvalidMessage;
            const wd_listen = wire_desc.WireDesc.fromValue(r.fields[1]) catch return error.InvalidMessage;
            const listen_desc = wire_desc.ResolverDesc.fromWireDesc(wd_listen) catch return error.InvalidMessage;
            const wants_partial: bool = if (r.fields[2] == .bool) r.fields[2].bool else false;
            return .{ .op = .{ .listen = .{
                .to_desc = to_desc,
                .listen_desc = listen_desc,
                .wants_partial = wants_partial,
            } }, .value = v };
        }
        if (std.mem.eql(u8, tag, "op:fulfill") and r.fields.len >= 2) {
            const wd = wire_desc.WireDesc.fromValue(r.fields[0]) catch return error.InvalidMessage;
            if (wd != .answer) return error.InvalidMessage;
            const answer_pos = wd.position();
            const payload_bytes = try r.fields[1].encodeAlloc(self.allocator);
            defer self.allocator.free(payload_bytes);
            // Detect promise-to-promise forwarding for wants-partial.
            const is_promise = blk: {
                if (r.fields[1] == .record) {
                    const inner = wire_desc.WireDesc.fromValue(r.fields[1]) catch break :blk false;
                    break :blk inner.isPromise();
                }
                break :blk false;
            };
            try self.answers.resolvePromiseEx(self.allocator, answer_pos, payload_bytes, is_promise);
            return .{ .op = .{ .fulfill = .{
                .answer_pos = answer_pos,
                .value = r.fields[1],
            } }, .value = v };
        }
        if (std.mem.eql(u8, tag, "op:break") and r.fields.len >= 2) {
            const wd = wire_desc.WireDesc.fromValue(r.fields[0]) catch return error.InvalidMessage;
            if (wd != .answer) return error.InvalidMessage;
            const answer_pos = wd.position();
            try self.answers.breakPromise(answer_pos);
            return .{ .op = .{ .@"break" = .{
                .answer_pos = answer_pos,
                .reason = r.fields[1],
            } }, .value = v };
        }
        if (std.mem.eql(u8, tag, "op:gc-exports") and r.fields.len >= 2) {
            // Spec: fields are [positions-list] [wire-deltas-list].
            const positions = try readIntList(u32, r.fields[0], self.allocator);
            const deltas = try readIntList(u32, r.fields[1], self.allocator);
            const n = @min(positions.len, deltas.len);
            for (0..n) |idx| {
                const orphaned = self.exports.decref(positions[idx], deltas[idx]);
                if (orphaned) self.exports.release(positions[idx]);
            }
            return .{ .op = .{ .gc_exports = .{ .positions = positions, .deltas = deltas } }, .value = v };
        }
        if (std.mem.eql(u8, tag, "op:gc-answers") and r.fields.len >= 1) {
            // Spec: field is [answer-positions-list].
            const positions = try readIntList(u32, r.fields[0], self.allocator);
            for (positions) |pos| {
                self.answers.releasePromise(self.allocator, pos) catch |e| switch (e) {
                    error.UnknownAnswerPos => {},
                    else => return e,
                };
            }
            return .{ .op = .{ .gc_answers = .{ .positions = positions } }, .value = v };
        }
        if (std.mem.eql(u8, tag, "op:abort") and r.fields.len >= 1) {
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

/// Read a Syrup list of integers into a caller-owned slice. Also accepts
/// a bare integer (wraps as single-element slice) for backward compat with
/// the pre-list-form protocol.
fn readIntList(comptime T: type, v: syrup.Value, allocator: Allocator) ![]const T {
    switch (v) {
        .list => |items| {
            const out = try allocator.alloc(T, items.len);
            for (items, 0..) |item, i| {
                out[i] = try readInt(T, item);
            }
            return out;
        },
        .integer => {
            const out = try allocator.alloc(T, 1);
            out[0] = try readInt(T, v);
            return out;
        },
        else => return error.InvalidMessage,
    }
}

// ---- Tests ------------------------------------------------------------------

test "two Vats: full handshake round-trip over localhost" {
    const allocator = std.testing.allocator;

    const addr = try std.net.Address.parseIp4("127.0.0.1", 0);
    var server = try addr.listen(.{ .reuse_address = true });
    defer server.deinit();
    const bound = server.listen_address;

    const kp_a = try handshake.KeyPair.generate();
    var b32_a = ByteList.init(allocator);
    defer b32_a.deinit();
    try location_mod.base32LowerEncode(&b32_a, &kp_a.pub_key);
    const loc_a = location_mod.Location{ .netlayer = .tcp, .designator = b32_a.items };

    const ctx = struct {
        bound: std.net.Address,
        err: ?anyerror = null,
        pub fn run(ptr: *@This()) void {
            const stream = std.net.tcpConnectToAddress(ptr.bound) catch |e| {
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
    // Spec: <op:deliver-only <desc:export pos> [method-sym]>
    var out = ByteList.init(allocator);
    errdefer out.deinit();
    try out.appendSlice("<15'op:deliver-only");
    try fmtAppend(&out, "<11'desc:export{d}+>", .{to_position});
    try out.append('[');
    try fmtAppend(&out, "{d}'", .{method.len});
    try out.appendSlice(method);
    try out.append(']');
    try out.append('>');
    return out.toOwnedSlice();
}

test "emitter round-trip: op:deliver-only parses as 2-field record" {
    const allocator = std.testing.allocator;
    const bytes = try encodeDeliverOnlyForTest(allocator, 3, "hello");
    defer allocator.free(bytes);
    var parser = syrup.Parser.init(bytes, allocator);
    var v = try parser.parse();
    defer v.deinitContainers(allocator);
    try std.testing.expect(v == .record);
    try std.testing.expect(v.record.label.* == .symbol);
    try std.testing.expectEqualStrings("op:deliver-only", v.record.label.symbol);
    try std.testing.expectEqual(@as(usize, 2), v.record.fields.len);
    // Field 1 is a list with method symbol as first element.
    try std.testing.expect(v.record.fields[1] == .list);
    try std.testing.expect(v.record.fields[1].list[0] == .symbol);
    try std.testing.expectEqualStrings("hello", v.record.fields[1].list[0].symbol);
}

fn encodeDeliverForTest(allocator: std.mem.Allocator, to_position: u32, method: []const u8, answer_pos: u32) ![]u8 {
    // Spec: <op:deliver <desc:export pos> [method-sym] answer-pos <desc:import-object pos>>
    var out = ByteList.init(allocator);
    errdefer out.deinit();
    try out.appendSlice("<10'op:deliver");
    try fmtAppend(&out, "<11'desc:export{d}+>", .{to_position});
    try out.append('[');
    try fmtAppend(&out, "{d}'", .{method.len});
    try out.appendSlice(method);
    try out.append(']');
    try fmtAppend(&out, "{d}+", .{answer_pos});
    try fmtAppend(&out, "<18'desc:import-object{d}+>", .{answer_pos});
    try out.append('>');
    return out.toOwnedSlice();
}

test "emitter round-trip: op:deliver parses with 4 fields (spec-conformant)" {
    const allocator = std.testing.allocator;
    const bytes = try encodeDeliverForTest(allocator, 7, "fetch", 4);
    defer allocator.free(bytes);
    var parser = syrup.Parser.init(bytes, allocator);
    var v = try parser.parse();
    defer v.deinitContainers(allocator);
    try std.testing.expect(v == .record);
    try std.testing.expectEqualStrings("op:deliver", v.record.label.symbol);
    try std.testing.expectEqual(@as(usize, 4), v.record.fields.len);
    // Field 1 is args list with method as first element.
    try std.testing.expect(v.record.fields[1] == .list);
    try std.testing.expectEqualStrings("fetch", v.record.fields[1].list[0].symbol);
    // Field 2 is answer-pos integer.
    try std.testing.expect(v.record.fields[2] == .integer);
    // Field 3 is resolve-me-desc.
    try std.testing.expect(v.record.fields[3] == .record);
    try std.testing.expectEqualStrings("desc:import-object", v.record.fields[3].record.label.symbol);
}

test "emitter round-trip: op:gc-exports list form parses" {
    const allocator = std.testing.allocator;
    var out = ByteList.init(allocator);
    defer out.deinit();
    // List form: <op:gc-exports [positions] [deltas]>
    try out.appendSlice("<13'op:gc-exports[1+3+][2+4+]>");

    var parser = syrup.Parser.init(out.items, allocator);
    var v = try parser.parse();
    defer v.deinitContainers(allocator);
    try std.testing.expect(v == .record);
    try std.testing.expectEqualStrings("op:gc-exports", v.record.label.symbol);
    try std.testing.expectEqual(@as(usize, 2), v.record.fields.len);
    // Both fields should be lists.
    try std.testing.expect(v.record.fields[0] == .list);
    try std.testing.expect(v.record.fields[1] == .list);
    try std.testing.expectEqual(@as(usize, 2), v.record.fields[0].list.len);
    try std.testing.expectEqual(@as(usize, 2), v.record.fields[1].list.len);
}

test "emitter round-trip: op:gc-answers list form parses" {
    const allocator = std.testing.allocator;
    var out = ByteList.init(allocator);
    defer out.deinit();
    // List form: <op:gc-answers [positions]>
    try out.appendSlice("<13'op:gc-answers[5+9+]>");

    var parser = syrup.Parser.init(out.items, allocator);
    var v = try parser.parse();
    defer v.deinitContainers(allocator);
    try std.testing.expect(v == .record);
    try std.testing.expectEqualStrings("op:gc-answers", v.record.label.symbol);
    try std.testing.expectEqual(@as(usize, 1), v.record.fields.len);
    try std.testing.expect(v.record.fields[0] == .list);
    try std.testing.expectEqual(@as(usize, 2), v.record.fields[0].list.len);
}

test "emitter shape: op:fulfill with desc:answer + inline value parses" {
    const allocator = std.testing.allocator;
    // Build the exact bytes sendFulfill would write, then roundtrip.
    var out = ByteList.init(allocator);
    defer out.deinit();
    try out.appendSlice("<10'op:fulfill");
    try out.appendSlice("<11'desc:answer");
    try fmtAppend(&out, "{d}+", .{@as(u32, 42)});
    try out.append('>');
    // value = integer 7
    try fmtAppend(&out, "{d}+", .{@as(u32, 7)});
    try out.append('>');

    var parser = syrup.Parser.init(out.items, allocator);
    var v = try parser.parse();
    defer v.deinitContainers(allocator);
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
        defer v.deinitContainers(allocator);
        try std.testing.expect(v == .record);
        try std.testing.expectEqualStrings("desc:error", v.record.label.symbol);
        try std.testing.expectEqual(@as(usize, 1), v.record.fields.len);
        try std.testing.expectEqualStrings("invalid-swiss", v.record.fields[0].symbol);
    }
    // 'unknown-swiss — bare symbol.
    {
        var parser = syrup.Parser.init("13'unknown-swiss", allocator);
        var v = try parser.parse();
        defer v.deinitContainers(allocator);
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
    try fmtAppend(&out, "{d}\"", .{reason.len});
    try out.appendSlice(reason);
    try out.append('>');

    var parser = syrup.Parser.init(out.items, allocator);
    var v = try parser.parse();
    defer v.deinitContainers(allocator);
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
    try fmtAppend(&out, "{d}+", .{@as(u32, 9)});
    try out.append('>');
    // reason = symbol 'oops
    try out.appendSlice("4'oops");
    try out.append('>');

    var parser = syrup.Parser.init(out.items, allocator);
    var v = try parser.parse();
    defer v.deinitContainers(allocator);
    try std.testing.expect(v == .record);
    try std.testing.expectEqualStrings("op:break", v.record.label.symbol);
    try std.testing.expectEqual(@as(usize, 2), v.record.fields.len);
}
