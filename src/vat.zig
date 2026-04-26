//! vat.zig — in-process actor runtime closing the gaps from the OCapN audit.
//!
//! What this gives you that ocapn_vat.zig (the network-side vat) does not:
//!
//!   - Mailbox + turn loop with ordered FIFO drain        (concept 27)
//!   - Eventual send `<-`, fire-and-forget                  (concept 20)
//!   - Vat quiescence: bounded drain → abort fallback      (concept 19)
//!   - Vat hierarchy: parent gets terminal-turn signal     (concept 28)
//!   - Backpressure: Lagged markers when mailbox overflows  (concept 26)
//!   - Distributed-GC weak refs via cap.ExportTable         (concept 24)
//!
//! Comptime advantages (the "nanoclj-zig in comptime" angle):
//!
//!   - `spawn(comptime B, init)` derives a typed vtable from `B.handle` at
//!     compile time, so dispatch is a single indirect call with no runtime
//!     registration table. Behavior types are checked at compile time.
//!   - `SelectorTable` is built from `B.SELECTORS` at comptime, mapping
//!     symbol → u6 index for facet masks. Unknown selectors are a comptime
//!     error when the source statically picks them.
//!   - GF(3) trit conservation: if `B` declares `pub const TRIT: i8`, the
//!     vat enforces sum ≡ 0 mod 3 across spawned siblings at quiescence.
//!
//! Lokke/Guile/Goblins reach: see goblins_ffi.zig — the C ABI exposes
//! `vat_spawn` / `vat_send` / `vat_quiesce` so a Lokke (Clojure-on-Guile)
//! script and a Spritely Goblins actor address the same Vat handle.

const std = @import("std");
const cap = @import("cap.zig");

const Allocator = std.mem.Allocator;

pub const Selector = u6;
pub const Become = enum { same, terminate };

pub const Message = struct {
    sender: cap.CapId,
    target: cap.ActorId,
    selector: Selector,
    payload: []const u8, // borrowed; caller owns until handler returns
};

/// Erased behavior — single indirect call, derived at comptime.
pub const Behavior = struct {
    state: *anyopaque,
    vtable: *const VTable,
    trit: i8,
    selectors: cap.SelectorMask,

    pub const VTable = struct {
        handle: *const fn (self: *anyopaque, v: *Vat, msg: Message) anyerror!Become,
        deinit: *const fn (self: *anyopaque, alloc: Allocator) void,
    };

    /// Build a Behavior from a comptime impl `B`. `B` must declare:
    ///   pub fn handle(*B, *Vat, Message) !Become
    ///   pub fn deinit(*B, Allocator) void   (optional; no-op if absent)
    /// Optionally:
    ///   pub const TRIT: i8           (default 0)
    ///   pub const SELECTORS: SelectorMask (default FACET_EMPTY — POLA: a
    ///     behavior that does not declare its accepted selectors receives no
    ///     authority by default. Spawning code must opt into selectors
    ///     explicitly via SELECTORS or by widening the returned cap.)
    pub fn make(comptime B: type, state: *B) Behavior {
        const Wrapped = struct {
            fn handle(self: *anyopaque, v: *Vat, msg: Message) anyerror!Become {
                const s: *B = @ptrCast(@alignCast(self));
                return @call(.auto, B.handle, .{ s, v, msg });
            }
            fn deinit(self: *anyopaque, alloc: Allocator) void {
                const s: *B = @ptrCast(@alignCast(self));
                if (@hasDecl(B, "deinit")) {
                    @call(.auto, B.deinit, .{ s, alloc });
                }
                alloc.destroy(s);
            }
        };
        const vt = comptime &Behavior.VTable{
            .handle = Wrapped.handle,
            .deinit = Wrapped.deinit,
        };
        const trit: i8 = if (@hasDecl(B, "TRIT")) B.TRIT else 0;
        const sels: cap.SelectorMask = if (@hasDecl(B, "SELECTORS"))
            B.SELECTORS
        else
            cap.FACET_EMPTY;
        return .{ .state = state, .vtable = vt, .trit = trit, .selectors = sels };
    }
};

/// Bounded ring buffer. Overflow returns `error.Backpressure` so the caller
/// can decide: drop, block, or emit a Lagged event into the rollout log.
pub const Mailbox = struct {
    pub const CAPACITY: usize = 256;
    buf: [CAPACITY]MsgOwned = undefined,
    head: usize = 0,
    tail: usize = 0,
    len: usize = 0,
    lagged: u32 = 0,

    pub const MsgOwned = struct {
        sender: cap.CapId,
        target: cap.ActorId,
        selector: Selector,
        payload: []u8, // owned, freed after handle()
        /// Set by `sendQ` — promise the handler should resolve. Read out by
        /// `turn()` into `vat.current_resolver` so the running handler can
        /// access it without a Message-shape change.
        promise_id: ?PromiseId = null,
    };

    pub fn push(self: *Mailbox, m: MsgOwned) error{Backpressure}!void {
        if (self.len == CAPACITY) {
            self.lagged += 1;
            return error.Backpressure;
        }
        self.buf[self.tail] = m;
        self.tail = (self.tail + 1) % CAPACITY;
        self.len += 1;
    }

    pub fn pop(self: *Mailbox) ?MsgOwned {
        if (self.len == 0) return null;
        const m = self.buf[self.head];
        self.head = (self.head + 1) % CAPACITY;
        self.len -= 1;
        return m;
    }

    pub fn isEmpty(self: *const Mailbox) bool {
        return self.len == 0;
    }
};

/// Per-actor record inside a vat.
pub const Slot = struct {
    behavior: ?Behavior,
    mailbox: Mailbox = .{},
    parent: ?cap.CapId = null, // for vat-hierarchy notify
    terminated: bool = false,
};

/// Reason a turn is being recorded — exposed for replay log writers.
///
/// `turn_seq` is a vat-local monotonic counter (0, 1, 2, …) incremented on
/// every dispatched turn. `now_ms` is the vat clock at the moment dispatch
/// began. Together they let a replayer verify two invariants without
/// re-running handlers: turn ordering is dense and matches, and any expiry
/// decision the original vat made can be reproduced from the recorded clock.
pub const TurnRecord = struct {
    turn_seq: u64,
    now_ms: i64,
    sender: cap.CapId,
    target: cap.ActorId,
    selector: Selector,
    payload_len: u32,
    became: Become,
    lagged_before: u32,
};

/// Default wall-clock millisecond reader. Replace `Vat.now_ms_fn` with a
/// virtual clock for deterministic replay or test-controlled expiry.
fn defaultNowMs() i64 {
    return std.time.milliTimestamp();
}

// ---- Promise pipelining -----------------------------------------------------
//
// Closes the structural gap against Goblins: `vat.send` is fire-and-forget,
// but Goblins-style `<-` returns a promise that itself can be sent to before
// it resolves. When the promise resolves to a cap, queued sends flush there
// in arrival order; if it resolves to a value, queued sends are dropped (and
// the value is read terminally); if it breaks, queued sends are dropped and
// the reason is recorded.
//
// The handler invoked for a `sendQ` request reads the resolver from
// `vat.current_resolver` (so `Message` stays unchanged — existing handlers
// keep working). Calling `resolver.fulfillCap(target)`, `fulfillValue(bytes)`,
// or `break_(reason)` flips the promise state and triggers queue flush.
//
// This is the runtime side. The wire side (`ocapn_session.AnswerTable`) holds
// the parallel structure; bridging is a `register-promise-resolution-callback`
// hook that fires `answers.resolvePromise` when a runtime promise resolves
// across a session boundary. That bridge is left to the caller — keeping this
// module independent of the syrup module dependency.

pub const PromiseId = u32;

pub const PromiseState = enum {
    pending,
    resolved_cap,
    resolved_value,
    broken,
};

pub const QueuedSend = struct {
    sender: cap.Capability,
    selector: Selector,
    payload: []u8, // owned by the promise table; freed on flush or break
};

pub const Promise = struct {
    state: PromiseState = .pending,
    /// `resolved_cap` populated when state == .resolved_cap. Pipelined sends
    /// queued before resolution flush here on resolve, and any subsequent
    /// `sendToPromise` short-circuits straight to this cap.
    resolved_cap: ?cap.Capability = null,
    /// `resolved_value` populated when state == .resolved_value. Owned bytes.
    resolved_value: ?[]u8 = null,
    /// `broken_reason` populated when state == .broken. Owned bytes.
    broken_reason: ?[]u8 = null,
    /// Queue of pipelined sends accumulated while pending.
    queued: std.ArrayList(QueuedSend) = .{},
};

/// Capability-like handle the receiver of a `sendQ` request uses to resolve
/// the request's promise. Held by value; copy freely.
pub const Resolver = struct {
    vat: *Vat,
    promise_id: PromiseId,

    pub fn fulfillCap(self: Resolver, target: cap.Capability) !void {
        return self.vat.resolvePromiseToCap(self.promise_id, target);
    }

    pub fn fulfillValue(self: Resolver, bytes: []const u8) !void {
        return self.vat.resolvePromiseToValue(self.promise_id, bytes);
    }

    pub fn break_(self: Resolver, reason: []const u8) !void {
        return self.vat.breakPromise(self.promise_id, reason);
    }
};

pub const Vat = struct {
    allocator: Allocator,
    id: cap.VatId,
    slots: std.ArrayList(Slot),
    children: std.ArrayList(*Vat) = .{},
    parent_vat: ?*Vat = null,
    parent_cap: ?cap.CapId = null,
    closed: bool = false,
    on_record: ?*const fn (ctx: *anyopaque, rec: TurnRecord) void = null,
    record_ctx: ?*anyopaque = null,
    /// Clock used for capability expiry checks. Defaults to wall clock;
    /// replay drivers and tests should override with a virtual clock.
    now_ms_fn: *const fn () i64 = defaultNowMs,
    /// Monotonic dispatch counter. Increments on every completed turn,
    /// recorded in `TurnRecord.turn_seq` for replay verification. Also bumped
    /// for the `spawnFork` barrier marker so child barriers stay ordered
    /// against surrounding turns.
    turn_seq: u64 = 0,
    /// Promise table for pipelining. Indexed by `PromiseId` (which is the
    /// slot index). Slots are append-only; promises live for the vat's
    /// lifetime so resolved caps remain reachable for late `sendToPromise`
    /// short-circuits.
    promises: std.ArrayList(Promise) = .{},
    /// Set by `turn()` when dispatching a `sendQ`-originated message; read
    /// by handlers via `currentResolver()`. Cleared after the turn.
    current_resolver: ?Resolver = null,

    pub fn init(allocator: Allocator, id: cap.VatId) Vat {
        return .{ .allocator = allocator, .id = id, .slots = .{} };
    }

    pub fn nowMs(self: *const Vat) i64 {
        return self.now_ms_fn();
    }

    pub fn deinit(self: *Vat) void {
        for (self.slots.items) |*s| {
            if (s.behavior) |b| b.vtable.deinit(b.state, self.allocator);
            while (s.mailbox.pop()) |m| self.allocator.free(m.payload);
        }
        self.slots.deinit(self.allocator);
        self.children.deinit(self.allocator);
        for (self.promises.items) |*p| {
            for (p.queued.items) |q| self.allocator.free(q.payload);
            p.queued.deinit(self.allocator);
            if (p.resolved_value) |v| self.allocator.free(v);
            if (p.broken_reason) |r| self.allocator.free(r);
        }
        self.promises.deinit(self.allocator);
    }

    pub fn currentResolver(self: *const Vat) ?Resolver {
        return self.current_resolver;
    }

    /// Allocate a fresh pending promise; returns its id. Used internally by
    /// `sendQ`, but exposed in case callers want to construct promises
    /// independently (e.g. to bridge from `ocapn_session.AnswerTable`).
    pub fn newPromise(self: *Vat) !PromiseId {
        const id: PromiseId = @intCast(self.promises.items.len);
        try self.promises.append(self.allocator, .{});
        return id;
    }

    /// Eventual send that returns a promise id. The handler resolving the
    /// request reads `vat.currentResolver()` and calls `fulfillCap`,
    /// `fulfillValue`, or `break_` on it.
    pub fn sendQ(
        self: *Vat,
        sender_cap: cap.Capability,
        to: cap.Capability,
        sel: Selector,
        payload: []const u8,
    ) !PromiseId {
        if (self.closed) return error.VatClosed;
        if (cap.vatOf(to.target) != self.id) return error.WrongVat;
        if (!to.isLive()) return error.Revoked;
        if (!to.isFresh(self.nowMs())) return error.Expired;
        if (!to.permits(sel)) return error.FacetDenies;
        const aid = cap.actorOf(to.target);
        if (aid >= self.slots.items.len) return error.UnknownActor;
        var s = &self.slots.items[aid];
        if (s.terminated or s.behavior == null) return error.Terminated;

        const promise_id = try self.newPromise();
        const owned = try self.allocator.dupe(u8, payload);
        errdefer self.allocator.free(owned);
        try s.mailbox.push(.{
            .sender = sender_cap.target,
            .target = aid,
            .selector = sel,
            .payload = owned,
            .promise_id = promise_id,
        });
        return promise_id;
    }

    /// Pipelined send — target is a not-yet-resolved promise. If the promise
    /// has already resolved to a cap, the message is forwarded immediately
    /// (short-circuit); if still pending, the message is queued and flushed
    /// on resolve; if resolved to a value or broken, returns an error.
    pub fn sendToPromise(
        self: *Vat,
        sender_cap: cap.Capability,
        promise_id: PromiseId,
        sel: Selector,
        payload: []const u8,
    ) !void {
        if (self.closed) return error.VatClosed;
        if (promise_id >= self.promises.items.len) return error.UnknownPromise;
        var p = &self.promises.items[promise_id];
        switch (p.state) {
            .resolved_cap => {
                const target_cap = p.resolved_cap.?;
                return self.send(sender_cap, target_cap, sel, payload);
            },
            .resolved_value => return error.ResolvedToValue,
            .broken => return error.PromiseBroken,
            .pending => {
                const owned = try self.allocator.dupe(u8, payload);
                errdefer self.allocator.free(owned);
                try p.queued.append(self.allocator, .{
                    .sender = sender_cap,
                    .selector = sel,
                    .payload = owned,
                });
            },
        }
    }

    /// Resolve a promise to a downstream cap. Flushes any queued pipelined
    /// sends to that cap in arrival order.
    pub fn resolvePromiseToCap(self: *Vat, promise_id: PromiseId, target: cap.Capability) !void {
        if (promise_id >= self.promises.items.len) return error.UnknownPromise;
        var p = &self.promises.items[promise_id];
        if (p.state != .pending) return error.AlreadyResolved;
        p.state = .resolved_cap;
        p.resolved_cap = target;
        // Flush queued sends. We iterate-and-free; on send failure we still
        // free the payload (errdefer pattern is awkward across loops, so we
        // use explicit cleanup).
        for (p.queued.items) |q| {
            self.send(q.sender, target, q.selector, q.payload) catch {};
            self.allocator.free(q.payload);
        }
        p.queued.clearRetainingCapacity();
    }

    /// Resolve a promise to a terminal byte value. Queued pipelined sends are
    /// dropped (cannot pipeline through a value); caller can read the bytes
    /// via `promiseValue`.
    pub fn resolvePromiseToValue(self: *Vat, promise_id: PromiseId, bytes: []const u8) !void {
        if (promise_id >= self.promises.items.len) return error.UnknownPromise;
        var p = &self.promises.items[promise_id];
        if (p.state != .pending) return error.AlreadyResolved;
        const owned = try self.allocator.dupe(u8, bytes);
        p.state = .resolved_value;
        p.resolved_value = owned;
        for (p.queued.items) |q| self.allocator.free(q.payload);
        p.queued.clearRetainingCapacity();
    }

    /// Break a promise with a reason. Queued sends are dropped.
    pub fn breakPromise(self: *Vat, promise_id: PromiseId, reason: []const u8) !void {
        if (promise_id >= self.promises.items.len) return error.UnknownPromise;
        var p = &self.promises.items[promise_id];
        if (p.state != .pending) return error.AlreadyResolved;
        const owned = try self.allocator.dupe(u8, reason);
        p.state = .broken;
        p.broken_reason = owned;
        for (p.queued.items) |q| self.allocator.free(q.payload);
        p.queued.clearRetainingCapacity();
    }

    pub fn promiseState(self: *const Vat, promise_id: PromiseId) ?PromiseState {
        if (promise_id >= self.promises.items.len) return null;
        return self.promises.items[promise_id].state;
    }

    pub fn promiseValue(self: *const Vat, promise_id: PromiseId) ?[]const u8 {
        if (promise_id >= self.promises.items.len) return null;
        const p = self.promises.items[promise_id];
        if (p.state != .resolved_value) return null;
        return p.resolved_value;
    }

    pub fn promiseResolvedCap(self: *const Vat, promise_id: PromiseId) ?cap.Capability {
        if (promise_id >= self.promises.items.len) return null;
        const p = self.promises.items[promise_id];
        if (p.state != .resolved_cap) return null;
        return p.resolved_cap;
    }

    /// Spawn a fresh actor. Comptime selects `B`; runtime allocates state.
    /// Returns a full-facet Capability bound to the vat root.
    pub fn spawn(self: *Vat, comptime B: type, init_state: B) !cap.Capability {
        const state = try self.allocator.create(B);
        state.* = init_state;
        const beh = Behavior.make(B, state);
        try self.slots.append(self.allocator, .{ .behavior = beh });
        const aid: cap.ActorId = @intCast(self.slots.items.len - 1);
        return .{
            .target = cap.pack(self.id, aid),
            .facet = beh.selectors,
            .sender = 0,
        };
    }

    /// Spawn into a child vat with this vat as parent. The child can notify
    /// the parent at terminal turn via `notifyParentTerminal`.
    pub fn spawnFork(self: *Vat, child: *Vat, comptime B: type, init_state: B) !cap.Capability {
        child.parent_vat = self;
        try self.children.append(self.allocator, child);
        // Parent rollout flush point — replay log consumers should treat the
        // current `on_record` callback's last write as the fork barrier.
        if (self.on_record) |cb| cb(self.record_ctx.?, .{
            .turn_seq = self.turn_seq,
            .now_ms = self.nowMs(),
            .sender = 0,
            .target = 0,
            .selector = 0,
            .payload_len = 0,
            .became = .same,
            .lagged_before = 0,
        });
        self.turn_seq += 1;
        const c = try child.spawn(B, init_state);
        child.parent_cap = c.target;
        return c;
    }

    /// Eventual send — Goblins `<-`. Fire-and-forget, ordered per-target.
    /// Returns `error.Backpressure` if mailbox is full (caller policy).
    pub fn send(self: *Vat, sender_cap: cap.Capability, to: cap.Capability, sel: Selector, payload: []const u8) !void {
        if (self.closed) return error.VatClosed;
        if (cap.vatOf(to.target) != self.id) return error.WrongVat;
        if (!to.isLive()) return error.Revoked;
        if (!to.isFresh(self.nowMs())) return error.Expired;
        if (!to.permits(sel)) return error.FacetDenies;
        const aid = cap.actorOf(to.target);
        if (aid >= self.slots.items.len) return error.UnknownActor;
        var s = &self.slots.items[aid];
        if (s.terminated or s.behavior == null) return error.Terminated;
        const owned = try self.allocator.dupe(u8, payload);
        errdefer self.allocator.free(owned);
        try s.mailbox.push(.{
            .sender = sender_cap.target,
            .target = aid,
            .selector = sel,
            .payload = owned,
        });
    }

    /// Process one queued message from any actor with non-empty mailbox.
    /// Returns true if a turn ran. Called repeatedly by quiesce / driver.
    pub fn turn(self: *Vat) !bool {
        if (self.closed) return false;
        for (self.slots.items, 0..) |*s, i| {
            if (s.terminated or s.behavior == null) continue;
            const m = s.mailbox.pop() orelse continue;
            defer self.allocator.free(m.payload);
            const beh = s.behavior.?;
            const lagged_before = s.mailbox.lagged;
            const turn_seq = self.turn_seq;
            const now_ms = self.nowMs();
            const msg = Message{
                .sender = m.sender,
                .target = m.target,
                .selector = m.selector,
                .payload = m.payload,
            };
            // Expose a Resolver to the handler if this turn was triggered by
            // a `sendQ`. Cleared after the handler returns regardless of
            // whether it actually called fulfill/break_.
            self.current_resolver = if (m.promise_id) |pid| .{ .vat = self, .promise_id = pid } else null;
            defer self.current_resolver = null;
            const became = beh.vtable.handle(beh.state, self, msg) catch |e| {
                // Handler error: break the associated promise (if any) so
                // pipelined senders observe the failure rather than waiting
                // forever, then terminate the actor.
                if (m.promise_id) |pid| {
                    self.breakPromise(pid, "handler error") catch {};
                }
                s.terminated = true;
                self.turn_seq += 1;
                self.notifyParentTerminal(@intCast(i));
                return e;
            };
            if (self.on_record) |cb| cb(self.record_ctx.?, .{
                .turn_seq = turn_seq,
                .now_ms = now_ms,
                .sender = m.sender,
                .target = m.target,
                .selector = m.selector,
                .payload_len = @intCast(m.payload.len),
                .became = became,
                .lagged_before = lagged_before,
            });
            self.turn_seq += 1;
            switch (became) {
                .same => {},
                .terminate => {
                    s.terminated = true;
                    beh.vtable.deinit(beh.state, self.allocator);
                    s.behavior = null;
                    self.notifyParentTerminal(@intCast(i));
                },
            }
            return true;
        }
        return false;
    }

    /// Vat quiescence — drain pending mailboxes until empty or budget hits 0.
    /// On budget exhaustion sets `closed` (abort fallback). Returns # turns.
    pub fn quiesce(self: *Vat, max_turns: usize) !usize {
        var n: usize = 0;
        while (n < max_turns) : (n += 1) {
            const ran = try self.turn();
            if (!ran) return n;
        }
        // Budget exhausted — abort.
        self.closed = true;
        return n;
    }

    /// Send the parent (if any) a terminal-turn ping. The parent receives
    /// a 0-byte payload on selector 63 — the implicit "child-terminated" wire.
    fn notifyParentTerminal(self: *Vat, child_aid: cap.ActorId) void {
        if (self.parent_vat) |p| if (self.parent_cap) |pc| {
            const sender_cap = cap.Capability{
                .target = cap.pack(self.id, child_aid),
                .sender = 0,
                .facet = cap.FACET_FULL,
            };
            const target_cap = cap.Capability{ .target = pc, .sender = 0, .facet = cap.FACET_FULL };
            p.send(sender_cap, target_cap, 63, &.{}) catch {};
        };
    }

    /// Hierarchical cancellation — close this vat and recursively cancel all
    /// child vats spawned via `spawnFork`. Each child's actors are terminated,
    /// their mailboxes drained, and the cascade continues to grandchildren.
    /// Returns the total number of vats cancelled (including self).
    pub fn cancelChildren(self: *Vat) usize {
        var cancelled: usize = 0;
        for (self.children.items) |child| {
            cancelled += child.cancelChildren();
        }
        if (!self.closed) {
            self.closed = true;
            for (self.slots.items) |*s| {
                if (s.terminated or s.behavior == null) continue;
                s.terminated = true;
                if (s.behavior) |b| {
                    b.vtable.deinit(b.state, self.allocator);
                    s.behavior = null;
                }
                while (s.mailbox.pop()) |m| self.allocator.free(m.payload);
            }
            cancelled += 1;
        }
        return cancelled;
    }

    /// GF(3) sibling check — sum of trits across live actors must be 0 mod 3.
    /// Returns true if conserved. Useful at quiescence to validate the spawn
    /// graph is balanced.
    pub fn checkTritConservation(self: *const Vat) bool {
        var sum: i32 = 0;
        for (self.slots.items) |s| {
            if (s.terminated or s.behavior == null) continue;
            sum += s.behavior.?.trit;
        }
        return @mod(sum + 3000, 3) == 0;
    }
};

// ---- Tests ------------------------------------------------------------------

const testing = std.testing;

const Echo = struct {
    log: *std.ArrayList(u8),
    alloc: Allocator,
    pub const TRIT: i8 = 0;
    pub const SELECTORS: cap.SelectorMask = cap.maskOf(&.{ 0, 1 });
    pub fn handle(self: *Echo, _: *Vat, m: Message) !Become {
        try self.log.appendSlice(self.alloc, m.payload);
        return .same;
    }
};

test "mailbox drains in delivery order" {
    const alloc = testing.allocator;
    var v = Vat.init(alloc, 1);
    defer v.deinit();

    var log: std.ArrayList(u8) = .{};
    defer log.deinit(alloc);
    const c = try v.spawn(Echo, .{ .log = &log, .alloc = alloc });

    const sender = cap.Capability{ .target = cap.pack(1, 0), .sender = 0 };
    try v.send(sender, c, 0, "a");
    try v.send(sender, c, 0, "b");
    try v.send(sender, c, 0, "c");

    _ = try v.quiesce(100);
    try testing.expectEqualStrings("abc", log.items);
}

test "eventual send is fire-and-forget — sender returns before handle" {
    const alloc = testing.allocator;
    var v = Vat.init(alloc, 1);
    defer v.deinit();

    var log: std.ArrayList(u8) = .{};
    defer log.deinit(alloc);
    const c = try v.spawn(Echo, .{ .log = &log, .alloc = alloc });

    const sender = cap.Capability{ .target = cap.pack(1, 0) };
    try v.send(sender, c, 0, "x");
    // Without quiesce, handler hasn't run.
    try testing.expectEqual(@as(usize, 0), log.items.len);
    _ = try v.turn();
    try testing.expectEqualStrings("x", log.items);
}

test "facet narrow: send with denied selector is rejected" {
    const alloc = testing.allocator;
    var v = Vat.init(alloc, 1);
    defer v.deinit();

    var log: std.ArrayList(u8) = .{};
    defer log.deinit(alloc);
    const c = try v.spawn(Echo, .{ .log = &log, .alloc = alloc });
    const ro = c.narrow(cap.maskOf(&.{0})); // permit only selector 0

    const sender = cap.Capability{ .target = cap.pack(1, 0) };
    try v.send(sender, ro, 0, "ok"); // permitted
    try testing.expectError(error.FacetDenies, v.send(sender, ro, 1, "no"));
}

const Quitter = struct {
    pub const SELECTORS: cap.SelectorMask = cap.maskOf(&.{0});
    pub fn handle(_: *Quitter, _: *Vat, _: Message) !Become {
        return .terminate;
    }
};

test "vat hierarchy: parent receives terminal turn ping on child terminate" {
    const alloc = testing.allocator;
    var parent = Vat.init(alloc, 1);
    defer parent.deinit();
    var child = Vat.init(alloc, 2);
    defer child.deinit();

    const Counter = struct {
        n: *u32,
        pub fn handle(self: *@This(), _: *Vat, _: Message) !Become {
            self.n.* += 1;
            return .same;
        }
    };
    var n: u32 = 0;
    const parent_cap = try parent.spawn(Counter, .{ .n = &n });

    // child.spawnFork would normally be parent.spawnFork(child, ...) — but we
    // need parent_cap to be the parent_cap target, so wire manually:
    child.parent_vat = &parent;
    child.parent_cap = parent_cap.target;
    _ = try child.spawn(Quitter, .{});

    const sender = cap.Capability{ .target = cap.pack(2, 0) };
    const child_cap = cap.Capability{ .target = cap.pack(2, 0), .facet = cap.FACET_FULL };
    try child.send(sender, child_cap, 0, "die");
    _ = try child.quiesce(10);

    // Parent now has the notification queued.
    _ = try parent.quiesce(10);
    try testing.expectEqual(@as(u32, 1), n);
}

test "quiesce: bounded drain returns budget on empty" {
    const alloc = testing.allocator;
    var v = Vat.init(alloc, 1);
    defer v.deinit();
    var log: std.ArrayList(u8) = .{};
    defer log.deinit(alloc);
    const c = try v.spawn(Echo, .{ .log = &log, .alloc = alloc });
    const sender = cap.Capability{ .target = cap.pack(1, 0) };
    try v.send(sender, c, 0, "a");
    try v.send(sender, c, 0, "b");
    const turns = try v.quiesce(100);
    try testing.expectEqual(@as(usize, 2), turns);
    try testing.expect(!v.closed);
}

test "backpressure: 257th send returns error.Backpressure, lagged increments" {
    const alloc = testing.allocator;
    var v = Vat.init(alloc, 1);
    defer v.deinit();
    var log: std.ArrayList(u8) = .{};
    defer log.deinit(alloc);
    const c = try v.spawn(Echo, .{ .log = &log, .alloc = alloc });
    const sender = cap.Capability{ .target = cap.pack(1, 0) };

    var i: usize = 0;
    while (i < Mailbox.CAPACITY) : (i += 1) try v.send(sender, c, 0, "x");
    try testing.expectError(error.Backpressure, v.send(sender, c, 0, "x"));
    try testing.expectEqual(@as(u32, 1), v.slots.items[0].mailbox.lagged);
}

test "POLA: spawn without SELECTORS produces empty-facet cap; sends rejected" {
    const alloc = testing.allocator;
    var v = Vat.init(alloc, 1);
    defer v.deinit();

    const Bare = struct {
        pub fn handle(_: *@This(), _: *Vat, _: Message) !Become {
            return .same;
        }
    };
    const c = try v.spawn(Bare, .{});
    try testing.expectEqual(cap.FACET_EMPTY, c.facet);
    const sender = cap.Capability{ .target = cap.pack(1, 0) };
    try testing.expectError(error.FacetDenies, v.send(sender, c, 0, ""));
}

test "expires_at_ms: send after deadline returns error.Expired" {
    const VirtualClock = struct {
        var now: i64 = 1000;
        fn read() i64 {
            return now;
        }
    };
    VirtualClock.now = 1000;

    const alloc = testing.allocator;
    var v = Vat.init(alloc, 1);
    defer v.deinit();
    v.now_ms_fn = VirtualClock.read;

    var log: std.ArrayList(u8) = .{};
    defer log.deinit(alloc);
    const c = try v.spawn(Echo, .{ .log = &log, .alloc = alloc });

    var ttl_cap = c;
    ttl_cap.expires_at_ms = 2000;

    const sender = cap.Capability{ .target = cap.pack(1, 0) };
    try v.send(sender, ttl_cap, 0, "before");

    VirtualClock.now = 2000; // deadline reached — strict < expiry
    try testing.expectError(error.Expired, v.send(sender, ttl_cap, 0, "at"));
    VirtualClock.now = 9999;
    try testing.expectError(error.Expired, v.send(sender, ttl_cap, 0, "after"));

    _ = try v.quiesce(10);
    try testing.expectEqualStrings("before", log.items);
}

test "Revoker: send before revoke succeeds; after revoke returns error.Revoked" {
    const alloc = testing.allocator;
    var v = Vat.init(alloc, 1);
    defer v.deinit();
    var log: std.ArrayList(u8) = .{};
    defer log.deinit(alloc);
    const c = try v.spawn(Echo, .{ .log = &log, .alloc = alloc });
    var rev = cap.Revoker{};
    const wrapped = rev.wrap(c);
    const sender = cap.Capability{ .target = cap.pack(1, 0) };

    try v.send(sender, wrapped, 0, "before");
    rev.revoke();
    try testing.expectError(error.Revoked, v.send(sender, wrapped, 0, "after"));

    _ = try v.quiesce(10);
    try testing.expectEqualStrings("before", log.items);
}

test "GF(3) trit conservation across siblings" {
    const alloc = testing.allocator;
    var v = Vat.init(alloc, 1);
    defer v.deinit();

    const Minus = struct {
        pub const TRIT: i8 = -1;
        pub fn handle(_: *@This(), _: *Vat, _: Message) !Become {
            return .same;
        }
    };
    const Zero = struct {
        pub const TRIT: i8 = 0;
        pub fn handle(_: *@This(), _: *Vat, _: Message) !Become {
            return .same;
        }
    };
    const Plus = struct {
        pub const TRIT: i8 = 1;
        pub fn handle(_: *@This(), _: *Vat, _: Message) !Become {
            return .same;
        }
    };
    _ = try v.spawn(Minus, .{});
    _ = try v.spawn(Zero, .{});
    _ = try v.spawn(Plus, .{});
    try testing.expect(v.checkTritConservation());
}

test "cancelChildren: parent cascades termination to child and grandchild vats" {
    const alloc = testing.allocator;
    var parent = Vat.init(alloc, 1);
    defer parent.deinit();
    var child = Vat.init(alloc, 2);
    defer child.deinit();
    var grandchild = Vat.init(alloc, 3);
    defer grandchild.deinit();

    // Build hierarchy: parent -> child -> grandchild
    _ = try parent.spawnFork(&child, Echo, .{ .log = undefined, .alloc = alloc });
    _ = try child.spawnFork(&grandchild, Echo, .{ .log = undefined, .alloc = alloc });

    // All vats are alive.
    try testing.expect(!parent.closed);
    try testing.expect(!child.closed);
    try testing.expect(!grandchild.closed);

    // Cancel from parent — should cascade to child and grandchild.
    const cancelled = parent.cancelChildren();
    try testing.expectEqual(@as(usize, 3), cancelled);
    try testing.expect(parent.closed);
    try testing.expect(child.closed);
    try testing.expect(grandchild.closed);

    // All actors terminated — sends fail.
    const sender = cap.Capability{ .target = cap.pack(1, 0) };
    const target = cap.Capability{ .target = cap.pack(2, 0), .facet = cap.FACET_FULL };
    try testing.expectError(error.VatClosed, child.send(sender, target, 0, "denied"));
}

test "cancelChildren: cancelling leaf vat returns 1" {
    const alloc = testing.allocator;
    var leaf = Vat.init(alloc, 1);
    defer leaf.deinit();
    _ = try leaf.spawn(Echo, .{ .log = undefined, .alloc = alloc });
    const cancelled = leaf.cancelChildren();
    try testing.expectEqual(@as(usize, 1), cancelled);
    try testing.expect(leaf.closed);
}

// ---- Promise pipelining tests -----------------------------------------------

const ValueResponder = struct {
    reply: []const u8,
    pub const SELECTORS: cap.SelectorMask = cap.maskOf(&.{0});
    pub fn handle(self: *ValueResponder, v: *Vat, _: Message) !Become {
        if (v.currentResolver()) |r| try r.fulfillValue(self.reply);
        return .same;
    }
};

test "sendQ: handler fulfills promise with value; caller reads it back" {
    const alloc = testing.allocator;
    var v = Vat.init(alloc, 1);
    defer v.deinit();

    const c = try v.spawn(ValueResponder, .{ .reply = "pong" });
    const sender = cap.Capability{ .target = cap.pack(1, 0) };
    const pid = try v.sendQ(sender, c, 0, "ping");

    try testing.expectEqual(PromiseState.pending, v.promiseState(pid).?);
    _ = try v.quiesce(10);
    try testing.expectEqual(PromiseState.resolved_value, v.promiseState(pid).?);
    try testing.expectEqualStrings("pong", v.promiseValue(pid).?);
}

test "sendQ: handler error breaks the promise" {
    const alloc = testing.allocator;
    var v = Vat.init(alloc, 1);
    defer v.deinit();

    const Eruptor = struct {
        pub const SELECTORS: cap.SelectorMask = cap.maskOf(&.{0});
        pub fn handle(_: *@This(), _: *Vat, _: Message) !Become {
            return error.Boom;
        }
    };
    const c = try v.spawn(Eruptor, .{});
    const sender = cap.Capability{ .target = cap.pack(1, 0) };
    const pid = try v.sendQ(sender, c, 0, "x");

    // turn() returns the handler error; promise gets broken before it does.
    try testing.expectError(error.Boom, v.turn());
    try testing.expectEqual(PromiseState.broken, v.promiseState(pid).?);
}

test "pipelining: sendToPromise queues, then flushes on resolveToCap in order" {
    const alloc = testing.allocator;
    var v = Vat.init(alloc, 1);
    defer v.deinit();

    var log: std.ArrayList(u8) = .{};
    defer log.deinit(alloc);

    // The eventual resolver: an Echo actor that records what it receives.
    const target_cap = try v.spawn(Echo, .{ .log = &log, .alloc = alloc });

    // A pending promise — pretend it represents a future cap to `target_cap`.
    const pid = try v.newPromise();

    const sender = cap.Capability{ .target = cap.pack(1, 0) };
    // Three pipelined sends queued at the promise before it resolves.
    try v.sendToPromise(sender, pid, 0, "a");
    try v.sendToPromise(sender, pid, 0, "b");
    try v.sendToPromise(sender, pid, 0, "c");

    // Echo hasn't run — promise still pending, queue holds the messages.
    try testing.expectEqual(PromiseState.pending, v.promiseState(pid).?);
    try testing.expectEqual(@as(usize, 3), v.promises.items[pid].queued.items.len);

    // Resolve to the Echo cap. Queue flushes to `target_cap` in arrival order.
    try v.resolvePromiseToCap(pid, target_cap);
    try testing.expectEqual(PromiseState.resolved_cap, v.promiseState(pid).?);
    try testing.expectEqual(@as(usize, 0), v.promises.items[pid].queued.items.len);

    _ = try v.quiesce(10);
    try testing.expectEqualStrings("abc", log.items);
}

test "pipelining: sendToPromise after resolveToCap short-circuits" {
    const alloc = testing.allocator;
    var v = Vat.init(alloc, 1);
    defer v.deinit();

    var log: std.ArrayList(u8) = .{};
    defer log.deinit(alloc);

    const target_cap = try v.spawn(Echo, .{ .log = &log, .alloc = alloc });
    const pid = try v.newPromise();
    try v.resolvePromiseToCap(pid, target_cap);

    // Send AFTER resolve — should short-circuit straight to target_cap.send.
    const sender = cap.Capability{ .target = cap.pack(1, 0) };
    try v.sendToPromise(sender, pid, 0, "post");

    _ = try v.quiesce(10);
    try testing.expectEqualStrings("post", log.items);
}

test "pipelining: sendToPromise on broken promise returns error.PromiseBroken" {
    const alloc = testing.allocator;
    var v = Vat.init(alloc, 1);
    defer v.deinit();

    const pid = try v.newPromise();
    try v.breakPromise(pid, "nope");
    const sender = cap.Capability{ .target = cap.pack(1, 0) };
    try testing.expectError(error.PromiseBroken, v.sendToPromise(sender, pid, 0, "x"));
}

test "pipelining: sendToPromise on value-resolved promise returns error.ResolvedToValue" {
    const alloc = testing.allocator;
    var v = Vat.init(alloc, 1);
    defer v.deinit();

    const pid = try v.newPromise();
    try v.resolvePromiseToValue(pid, "terminal");
    const sender = cap.Capability{ .target = cap.pack(1, 0) };
    try testing.expectError(error.ResolvedToValue, v.sendToPromise(sender, pid, 0, "x"));
}

test "pipelining: double-resolve is rejected with error.AlreadyResolved" {
    const alloc = testing.allocator;
    var v = Vat.init(alloc, 1);
    defer v.deinit();

    const pid = try v.newPromise();
    try v.resolvePromiseToValue(pid, "first");
    try testing.expectError(error.AlreadyResolved, v.resolvePromiseToValue(pid, "second"));
    try testing.expectError(error.AlreadyResolved, v.breakPromise(pid, "any"));
}

test "sendQ + pipelining: chained sends queue before resolution and arrive after" {
    // End-to-end: A's handler asks B for something via sendQ, then sends two
    // pipelined messages to the resulting promise. B fulfills with a cap to
    // C. The two messages flush to C in order.
    const alloc = testing.allocator;
    var v = Vat.init(alloc, 1);
    defer v.deinit();

    var log: std.ArrayList(u8) = .{};
    defer log.deinit(alloc);

    const c_cap = try v.spawn(Echo, .{ .log = &log, .alloc = alloc });

    // B: when called, fulfill the inbound promise with a cap to C.
    const Forwarder = struct {
        target: cap.Capability,
        pub const SELECTORS: cap.SelectorMask = cap.maskOf(&.{0});
        pub fn handle(self: *@This(), vat_: *Vat, _: Message) !Become {
            if (vat_.currentResolver()) |r| try r.fulfillCap(self.target);
            return .same;
        }
    };
    const b_cap = try v.spawn(Forwarder, .{ .target = c_cap });

    const sender = cap.Capability{ .target = cap.pack(1, 0) };
    const pid = try v.sendQ(sender, b_cap, 0, "introduce");
    // Pipeline two messages BEFORE B has run.
    try v.sendToPromise(sender, pid, 0, "x");
    try v.sendToPromise(sender, pid, 0, "y");

    _ = try v.quiesce(20);
    try testing.expectEqualStrings("xy", log.items);
    try testing.expectEqual(PromiseState.resolved_cap, v.promiseState(pid).?);
}
