//! promise_bridge.zig — runtime ↔ wire promise lifecycle adapter.
//!
//! Connects two parallel promise tables that previously had no contact:
//!
//!   - **Runtime side** (`vat.zig`): `vat.PromiseId` from `sendQ`, resolved
//!     by handlers via `Resolver.fulfillValue` / `break_`. In-process.
//!   - **Wire side** (`ocapn_session.zig`): `AnswerPos` from
//!     `AnswerTable.newPromise`, resolved by remote peer's `op:answer` /
//!     `op:answer-error` messages. Cross-vat.
//!
//! A `PromiseBridge` is per-CapTP-session. It owns a bidirectional map
//! between `PromiseId` and `AnswerPos`, plus the direction of each binding:
//!
//!   - **Outbound**: local code called `sendQ` against a far-ref to the
//!     remote vat; we registered a wire `AnswerPos` to receive the eventual
//!     `op:answer`. On `onWireAnswer` / `onWireBreak`, the runtime promise
//!     is resolved/broken from wire data.
//!
//!   - **Inbound**: remote sent `op:deliver` with an `AnswerPos`; we
//!     allocated a fresh runtime `PromiseId` so the local handler can
//!     resolve it via the standard `Resolver` API. On
//!     `flushRuntimeResolution`, the bridge reads the runtime promise's
//!     state and writes it through to the wire `AnswerTable`, ready for the
//!     session driver to emit `op:answer` to the peer.
//!
//! The bridge does NOT speak transport. It only translates between two
//! lifecycle representations. The session driver (e.g. `ocapn_vat.zig`)
//! handles wire I/O and calls into the bridge at the right moments.
//!
//! Lifetime / ownership:
//!   - The runtime `Vat` and the wire `AnswerTable` are caller-owned and
//!     must outlive the bridge.
//!   - Bindings persist across resolution; they are removed only by
//!     explicit `release(answer_pos)` (mirroring `op:gc-answers`).

const std = @import("std");
const cap = @import("cap.zig");
const vat = @import("vat.zig");
const ocapn_session = @import("ocapn_session.zig");

pub const Direction = enum { outbound, inbound };

pub const Binding = struct {
    runtime_id: vat.PromiseId,
    answer_pos: ocapn_session.AnswerPos,
    direction: Direction,
};

pub const BridgeError = error{
    UnknownAnswerPos,
    UnknownPromise,
    NotAnOutboundPromise,
    NotAnInboundPromise,
    NotResolved,
    UnsupportedResolutionKind,
} || std.mem.Allocator.Error || error{ AlreadyResolved, PromiseAlreadyResolved };

pub const PromiseBridge = struct {
    allocator: std.mem.Allocator,
    runtime_vat: *vat.Vat,
    by_runtime: std.AutoHashMapUnmanaged(vat.PromiseId, Binding) = .{},
    by_answer: std.AutoHashMapUnmanaged(ocapn_session.AnswerPos, Binding) = .{},

    pub fn init(allocator: std.mem.Allocator, runtime_vat: *vat.Vat) PromiseBridge {
        return .{ .allocator = allocator, .runtime_vat = runtime_vat };
    }

    pub fn deinit(self: *PromiseBridge) void {
        self.by_runtime.deinit(self.allocator);
        self.by_answer.deinit(self.allocator);
    }

    /// Outbound: caller already allocated a runtime promise (typically via
    /// `vat.sendQ` against a far-ref to the remote). Allocate a wire
    /// `AnswerPos` in `answers` and bind. Returns the AnswerPos to embed in
    /// the outgoing `op:deliver` message.
    pub fn registerOutbound(
        self: *PromiseBridge,
        runtime_id: vat.PromiseId,
        answers: *ocapn_session.AnswerTable,
    ) !ocapn_session.AnswerPos {
        const wire_promise = try answers.newPromise(self.allocator);
        const binding = Binding{
            .runtime_id = runtime_id,
            .answer_pos = wire_promise.answer_pos,
            .direction = .outbound,
        };
        try self.by_runtime.put(self.allocator, runtime_id, binding);
        try self.by_answer.put(self.allocator, wire_promise.answer_pos, binding);
        return wire_promise.answer_pos;
    }

    /// Inbound: the session received `op:deliver` with `answer_pos`.
    /// Allocate a fresh runtime promise so the local handler can resolve it
    /// via the standard `Resolver` API. Returns the runtime PromiseId; the
    /// session driver then dispatches the inbound message into the vat and
    /// must arrange for the resolver to be visible to the handler.
    pub fn registerInbound(
        self: *PromiseBridge,
        answer_pos: ocapn_session.AnswerPos,
    ) !vat.PromiseId {
        const runtime_id = try self.runtime_vat.newPromise();
        const binding = Binding{
            .runtime_id = runtime_id,
            .answer_pos = answer_pos,
            .direction = .inbound,
        };
        try self.by_runtime.put(self.allocator, runtime_id, binding);
        try self.by_answer.put(self.allocator, answer_pos, binding);
        return runtime_id;
    }

    /// Wire received `op:answer` for an outbound binding. Forward to the
    /// runtime: resolve the runtime promise to the byte payload.
    pub fn onWireAnswer(self: *PromiseBridge, answer_pos: ocapn_session.AnswerPos, bytes: []const u8) BridgeError!void {
        const binding = self.by_answer.get(answer_pos) orelse return error.UnknownAnswerPos;
        if (binding.direction != .outbound) return error.NotAnOutboundPromise;
        try self.runtime_vat.resolvePromiseToValue(binding.runtime_id, bytes);
    }

    /// Wire received `op:answer-error` (or transport-level break) for an
    /// outbound binding. Mirror to the runtime as a broken promise.
    pub fn onWireBreak(self: *PromiseBridge, answer_pos: ocapn_session.AnswerPos, reason: []const u8) BridgeError!void {
        const binding = self.by_answer.get(answer_pos) orelse return error.UnknownAnswerPos;
        if (binding.direction != .outbound) return error.NotAnOutboundPromise;
        try self.runtime_vat.breakPromise(binding.runtime_id, reason);
    }

    /// Local handler resolved a runtime promise associated with an inbound
    /// binding. Read the runtime state and write through to `answers` so
    /// the session driver can emit `op:answer` (or `op:answer-error`) to
    /// the remote peer.
    ///
    /// Returns the resolved/broken state for the caller to inspect when
    /// deciding which wire message to send.
    pub fn flushRuntimeResolution(
        self: *PromiseBridge,
        runtime_id: vat.PromiseId,
        answers: *ocapn_session.AnswerTable,
    ) BridgeError!vat.PromiseState {
        const binding = self.by_runtime.get(runtime_id) orelse return error.UnknownPromise;
        if (binding.direction != .inbound) return error.NotAnInboundPromise;
        const state = self.runtime_vat.promiseState(runtime_id) orelse return error.UnknownPromise;
        switch (state) {
            .resolved_value => {
                const bytes = self.runtime_vat.promiseValue(runtime_id).?;
                try answers.resolvePromise(self.allocator, binding.answer_pos, bytes);
            },
            .broken => {
                try answers.breakPromise(binding.answer_pos);
            },
            .pending => return error.NotResolved,
            // resolved_cap means the handler returned a far-ref. CapTP
            // represents this as `op:answer` with a cap descriptor; the
            // serialization is wire-side work that this bridge doesn't do.
            .resolved_cap => return error.UnsupportedResolutionKind,
        }
        return state;
    }

    /// Mirror `ocapn_session.AnswerTable.releasePromise` (peer sent
    /// `op:gc-answers`). Drops the binding and the wire slot. Runtime
    /// promise stays in `vat.promises` (append-only).
    pub fn release(
        self: *PromiseBridge,
        answer_pos: ocapn_session.AnswerPos,
        answers: *ocapn_session.AnswerTable,
    ) !void {
        const binding = self.by_answer.fetchRemove(answer_pos) orelse return error.UnknownAnswerPos;
        _ = self.by_runtime.remove(binding.value.runtime_id);
        try answers.releasePromise(self.allocator, answer_pos);
    }

    pub fn lookupByRuntime(self: *const PromiseBridge, runtime_id: vat.PromiseId) ?Binding {
        return self.by_runtime.get(runtime_id);
    }

    pub fn lookupByAnswer(self: *const PromiseBridge, answer_pos: ocapn_session.AnswerPos) ?Binding {
        return self.by_answer.get(answer_pos);
    }

    pub fn count(self: *const PromiseBridge) usize {
        return self.by_runtime.count();
    }
};

// ---- Tests ------------------------------------------------------------------

const testing = std.testing;

test "outbound: registerOutbound binds, onWireAnswer resolves runtime promise" {
    const alloc = testing.allocator;
    var v = vat.Vat.init(alloc, 1);
    defer v.deinit();

    var answers = ocapn_session.AnswerTable.init();
    defer answers.deinit(alloc);

    var bridge = PromiseBridge.init(alloc, &v);
    defer bridge.deinit();

    // Caller would normally call `vat.sendQ` against a far-ref; we simulate
    // that by allocating a runtime promise directly. (The bridge doesn't
    // care how the runtime promise was minted.)
    const runtime_id = try v.newPromise();
    const answer_pos = try bridge.registerOutbound(runtime_id, &answers);

    try testing.expectEqual(@as(usize, 1), bridge.count());
    try testing.expectEqual(vat.PromiseState.pending, v.promiseState(runtime_id).?);

    // Remote sends op:answer over the wire — bridge translates.
    try bridge.onWireAnswer(answer_pos, "remote-result");
    try testing.expectEqual(vat.PromiseState.resolved_value, v.promiseState(runtime_id).?);
    try testing.expectEqualStrings("remote-result", v.promiseValue(runtime_id).?);
}

test "outbound: onWireBreak breaks the runtime promise" {
    const alloc = testing.allocator;
    var v = vat.Vat.init(alloc, 1);
    defer v.deinit();
    var answers = ocapn_session.AnswerTable.init();
    defer answers.deinit(alloc);
    var bridge = PromiseBridge.init(alloc, &v);
    defer bridge.deinit();

    const runtime_id = try v.newPromise();
    const answer_pos = try bridge.registerOutbound(runtime_id, &answers);

    try bridge.onWireBreak(answer_pos, "peer-error");
    try testing.expectEqual(vat.PromiseState.broken, v.promiseState(runtime_id).?);
}

test "inbound: registerInbound + flushRuntimeResolution forwards to wire" {
    const alloc = testing.allocator;
    var v = vat.Vat.init(alloc, 1);
    defer v.deinit();
    var answers = ocapn_session.AnswerTable.init();
    defer answers.deinit(alloc);
    var bridge = PromiseBridge.init(alloc, &v);
    defer bridge.deinit();

    // Simulate remote allocating its half: call answers.newPromise to get
    // an answer_pos as the wire side would.
    const wire_promise = try answers.newPromise(alloc);
    const answer_pos = wire_promise.answer_pos;

    // Bridge registers the inbound binding.
    const runtime_id = try bridge.registerInbound(answer_pos);
    try testing.expectEqual(vat.PromiseState.pending, v.promiseState(runtime_id).?);

    // Local handler resolves the runtime promise (via standard Resolver path).
    try v.resolvePromiseToValue(runtime_id, "local-reply");

    // Bridge mirrors to wire.
    const state = try bridge.flushRuntimeResolution(runtime_id, &answers);
    try testing.expectEqual(vat.PromiseState.resolved_value, state);
    const wire_p = answers.byAnswerPos(answer_pos).?;
    try testing.expectEqual(ocapn_session.PromiseState.resolved, wire_p.state);
    try testing.expectEqualStrings("local-reply", wire_p.resolved_bytes.items);
}

test "inbound: flushRuntimeResolution propagates a broken promise" {
    const alloc = testing.allocator;
    var v = vat.Vat.init(alloc, 1);
    defer v.deinit();
    var answers = ocapn_session.AnswerTable.init();
    defer answers.deinit(alloc);
    var bridge = PromiseBridge.init(alloc, &v);
    defer bridge.deinit();

    const wp = try answers.newPromise(alloc);
    const runtime_id = try bridge.registerInbound(wp.answer_pos);
    try v.breakPromise(runtime_id, "handler-failed");

    const state = try bridge.flushRuntimeResolution(runtime_id, &answers);
    try testing.expectEqual(vat.PromiseState.broken, state);
    try testing.expectEqual(ocapn_session.PromiseState.broken, answers.byAnswerPos(wp.answer_pos).?.state);
}

test "direction guards: outbound op cannot flush; inbound op cannot receive wire answer" {
    const alloc = testing.allocator;
    var v = vat.Vat.init(alloc, 1);
    defer v.deinit();
    var answers = ocapn_session.AnswerTable.init();
    defer answers.deinit(alloc);
    var bridge = PromiseBridge.init(alloc, &v);
    defer bridge.deinit();

    // Outbound binding: attempt to flush should fail.
    const runtime_id_out = try v.newPromise();
    _ = try bridge.registerOutbound(runtime_id_out, &answers);
    try v.resolvePromiseToValue(runtime_id_out, "x"); // local, but bound outbound
    try testing.expectError(error.NotAnInboundPromise, bridge.flushRuntimeResolution(runtime_id_out, &answers));

    // Inbound binding: attempt to receive wire answer should fail.
    const wp = try answers.newPromise(alloc);
    _ = try bridge.registerInbound(wp.answer_pos);
    try testing.expectError(error.NotAnOutboundPromise, bridge.onWireAnswer(wp.answer_pos, "y"));
}

test "release drops both halves of the binding" {
    const alloc = testing.allocator;
    var v = vat.Vat.init(alloc, 1);
    defer v.deinit();
    var answers = ocapn_session.AnswerTable.init();
    defer answers.deinit(alloc);
    var bridge = PromiseBridge.init(alloc, &v);
    defer bridge.deinit();

    const runtime_id = try v.newPromise();
    const answer_pos = try bridge.registerOutbound(runtime_id, &answers);
    try testing.expectEqual(@as(usize, 1), bridge.count());

    try bridge.release(answer_pos, &answers);
    try testing.expectEqual(@as(usize, 0), bridge.count());
    try testing.expect(bridge.lookupByAnswer(answer_pos) == null);
    try testing.expect(bridge.lookupByRuntime(runtime_id) == null);
}

test "unknown answer_pos / runtime_id return errors instead of panicking" {
    const alloc = testing.allocator;
    var v = vat.Vat.init(alloc, 1);
    defer v.deinit();
    var answers = ocapn_session.AnswerTable.init();
    defer answers.deinit(alloc);
    var bridge = PromiseBridge.init(alloc, &v);
    defer bridge.deinit();

    try testing.expectError(error.UnknownAnswerPos, bridge.onWireAnswer(999, "x"));
    try testing.expectError(error.UnknownAnswerPos, bridge.onWireBreak(999, "x"));
    try testing.expectError(error.UnknownPromise, bridge.flushRuntimeResolution(999, &answers));
    try testing.expectError(error.UnknownAnswerPos, bridge.release(999, &answers));
}

test "flush rejects pending and resolved-to-cap states" {
    const alloc = testing.allocator;
    var v = vat.Vat.init(alloc, 1);
    defer v.deinit();
    var answers = ocapn_session.AnswerTable.init();
    defer answers.deinit(alloc);
    var bridge = PromiseBridge.init(alloc, &v);
    defer bridge.deinit();

    // Pending → NotResolved.
    const wp1 = try answers.newPromise(alloc);
    const rid1 = try bridge.registerInbound(wp1.answer_pos);
    try testing.expectError(error.NotResolved, bridge.flushRuntimeResolution(rid1, &answers));

    // resolved_cap → UnsupportedResolutionKind (would need wire-side cap descriptor serialization).
    const wp2 = try answers.newPromise(alloc);
    const rid2 = try bridge.registerInbound(wp2.answer_pos);
    const dummy_cap = cap.Capability{ .target = cap.pack(1, 0), .facet = cap.FACET_FULL };
    try v.resolvePromiseToCap(rid2, dummy_cap);
    try testing.expectError(error.UnsupportedResolutionKind, bridge.flushRuntimeResolution(rid2, &answers));
}
