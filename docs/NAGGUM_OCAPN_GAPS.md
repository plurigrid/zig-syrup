# OCapN Spec Compliance: Three Gaps, No Excuses

*Design guidance in the voice of Erik Naggum — protocol purist, type discipline absolutist, and sworn enemy of the half-measure.*

---

## Preamble: The Existing Sins

Before we discuss what's missing, let us discuss what's *wrong*.

The dispatch loop in `ocapn_vat.zig:recvAndDispatch` is a chain of `std.mem.eql(u8, tag, "op:deliver-only")` comparisons. This is stringly-typed dispatch. You have taken a language with comptime, tagged unions, and zero-cost abstractions, and you have written Python. Every incoming message is a runtime string comparison against a pile of byte literals. The `IncomingOp` tagged union is the *correct* idea — but the path from wire bytes to that union is a hand-rolled chain of `if (std.mem.eql(...))` with duplicated field extraction logic. The parser knows the label is `"op:deliver"` — it should produce a typed variant *once*, and the rest of the system should never see a raw string again.

Similarly, `readImportObjectPos` hardcodes `"desc:import-object"` as the *only* legal descriptor. The spec defines `desc:import-object` AND `desc:import-promise`. They are distinct descriptor types with distinct semantics. By writing a function that only matches one, you have encoded an assumption into the type system's *absence* — the most dangerous place for an assumption to live, because no compiler will ever warn you about it.

The bootstrap object at position 0 accepts `fetch` and *only* `fetch` — but the spec says it must also handle `deposit-gift` and `withdraw-gift`. The `serveBootstrapFetch` method hardcodes `"fetch"` and returns `error.NotFetchMethod` for everything else. This isn't a TODO — it's a type error. The bootstrap object's method space is `{fetch, deposit-gift, withdraw-gift}`, and you've narrowed it to `{fetch}` without the type system recording that narrowing.

The AnswerTable stores `resolved_bytes: std.ArrayListUnmanaged(u8)` — a dynamically-resizable byte buffer for the resolved value — but has no concept of *listeners*. A promise without listeners is a write-only log. The spec requires that remote parties can register interest in a promise's resolution. Without `op:listen`, your promises are tombs that only the local vat can excavate.

These are not features to add. They are **type-level lies** to correct.

---

## Gap 1: `op:listen` — Promise Observation

### What the Spec Demands

```
<op:listen to-desc listen-desc wants-partial?>
```

- `to-desc`: a promise descriptor (`desc:answer` or `desc:import-promise`) identifying which promise to observe.
- `listen-desc`: a resolver descriptor (the remote endpoint that receives the resolution).
- `wants-partial?`: boolean — does the listener want partial/progressive results? (Conforming impls may ignore this and send full resolution only.)

When the promise resolves (via `op:fulfill` or `op:break`), all registered listeners must be notified with the resolved value or break reason.

### 1. Type-Level Design

The AnswerTable's `Promise` struct must grow a listener list. But first — what IS a listener?

A listener is a *remote resolver descriptor*. It is the address to which we forward the resolution. It is NOT a callback. It is NOT a function pointer. It is a wire-level descriptor that we serialize into an `op:fulfill` or `op:break` message *directed at the listener* when the promise resolves.

```zig
/// A remote party's interest in a promise resolution.
/// Immutable after creation; freed when the promise is released.
pub const Listener = struct {
    /// The descriptor the remote sent as `listen-desc`. This is a
    /// desc:import-object or similar — it tells us WHERE to send the
    /// resolution. We store the raw Syrup-encoded bytes because
    /// re-encoding from a parsed Value is error-prone and wasteful.
    resolver_desc_bytes: []const u8,  // owned, allocator-freed
    wants_partial: bool,
};
```

The `Promise` struct gains:

```zig
pub const Promise = struct {
    id: PromiseId,
    answer_pos: AnswerPos,
    state: PromiseState = .pending,
    resolved_bytes: std.ArrayListUnmanaged(u8) = .empty,
    /// Listeners registered via op:listen. Appended while .pending;
    /// drained on resolution; freed on release.
    listeners: std.ArrayListUnmanaged(Listener) = .empty,

    pub fn deinit(self: *Promise, allocator: Allocator) void {
        self.resolved_bytes.deinit(allocator);
        for (self.listeners.items) |l| allocator.free(l.resolver_desc_bytes);
        self.listeners.deinit(allocator);
    }
};
```

The `IncomingOp` union in `ocapn_vat.zig` gains a new variant:

```zig
pub const IncomingOp = union(enum) {
    deliver_only: struct { ... },
    deliver: struct { ... },
    fulfill: struct { ... },
    @"break": struct { ... },
    gc_exports: struct { ... },
    gc_answers: struct { ... },
    abort: struct { ... },
    listen: struct {
        to_desc: ToDesc,       // tagged union: answer or import-promise
        listen_desc_bytes: []const u8, // raw syrup of the resolver desc
        wants_partial: bool,
    },
    unknown: syrup.Value,
};
```

And `ToDesc` is:

```zig
/// What you can listen TO. The spec allows desc:answer and
/// desc:import-promise. Not desc:import-object. Not a bare integer.
/// The type system enforces this; the dispatcher rejects anything else.
pub const ToDesc = union(enum) {
    answer: AnswerPos,
    import_promise: u32,  // position in the remote's promise table
};
```

This is the critical type-level decision: **`to-desc` is not a generic descriptor. It is specifically a promise-shaped descriptor.** Encode that in the union. If someone sends `op:listen` with `desc:import-object` as the `to-desc`, that is `error.InvalidListenTarget`, not silent misrouting.

### 2. Ownership and Lifetime

- **Listener.resolver_desc_bytes**: Allocated by `recvAndDispatch` when parsing `op:listen`. Ownership transfers to the `Promise.listeners` list. Freed by `Promise.deinit` (which is called by `AnswerTable.releasePromise` or `AnswerTable.deinit`).
- **Listener lifetime**: A listener lives as long as the promise it's attached to. There is no `op:unlisten`. The spec doesn't define one. Listeners die when the promise is released via `op:gc-answers`.
- **Resolution fan-out**: When `resolvePromise` is called and flips state to `.resolved`, the Vat must *immediately* iterate `listeners` and emit `op:fulfill` (or `op:break`) to each listener descriptor. This is a synchronous drain — after resolution, the listener list is consumed and can be freed.

The Vat method:

```zig
/// Resolve a promise AND fan out to all registered listeners.
/// This is the ONLY correct resolve path once listeners exist.
pub fn resolveAndNotify(
    self: *Vat,
    pos: AnswerPos,
    payload_bytes: []const u8,
) !void {
    try self.answers.resolvePromise(self.allocator, pos, payload_bytes);
    const p = self.answers.byAnswerPos(pos) orelse unreachable;
    for (p.listeners.items) |listener| {
        // Send op:fulfill <listener.resolver_desc_bytes> <payload_bytes>
        try self.sendFulfillToDesc(listener.resolver_desc_bytes, payload_bytes);
    }
    // Listeners are now spent. Free them eagerly — don't wait for gc-answers.
    for (p.listeners.items) |l| self.allocator.free(l.resolver_desc_bytes);
    p.listeners.clearRetainingCapacity();
}
```

**Late listeners** (listener arrives after resolution): The promise is already resolved. Send the resolution *immediately* to the new listener. Do not store it. This is specified behavior — `op:listen` on a resolved promise must reply promptly.

```zig
pub fn addListener(self: *AnswerTable, allocator: Allocator, pos: AnswerPos, listener: Listener) !enum { queued, already_resolved } {
    const p = self.byAnswerPos(pos) orelse return error.UnknownAnswerPos;
    switch (p.state) {
        .pending => {
            try p.listeners.append(allocator, listener);
            return .queued;
        },
        .resolved, .broken => return .already_resolved,
    }
}
```

When `.already_resolved` is returned, the Vat reads `p.resolved_bytes` / `p.state` and immediately sends the resolution. The caller frees the listener's descriptor bytes since it was never stored.

### 3. Error Taxonomy

| Error | Recoverable? | Action |
|-------|-------------|--------|
| `error.UnknownAnswerPos` | Yes — peer is confused or racing gc | Send `op:break` back to the listen-desc with reason `'unknown-promise` |
| `error.InvalidListenTarget` | Yes — malformed to-desc | Log + ignore (do NOT abort session for one bad op) |
| `error.InvalidMessage` | Yes — parse failure | Log + ignore |
| `error.OutOfMemory` | No | `op:abort` + close session |

### 4. Critique of Current Code

- `recvAndDispatch` has no `"op:listen"` branch. The label exists in `syrup.zig` constants but is dead code.
- `resolvePromise` in `AnswerTable` writes bytes into the promise and flips state. It has no concept of notification. Resolution is a *write*, not a *publish*. This is architecturally wrong for a protocol where promises are shared objects.
- The `sendFulfill` method takes an `answer_pos: u32` and sends to a `desc:answer` descriptor. But listener notification sends to an *arbitrary resolver descriptor*. You need a `sendFulfillToDesc(desc_bytes: []const u8, payload: []const u8)` that takes pre-encoded descriptor bytes.

### 5. Implementation Guidance

**Step 1**: Add `Listener` and `listeners` to `Promise` in `ocapn_session.zig`. Add `addListener` method. Add `deinit` cleanup. Run `zig build test` — existing tests must still pass because `listeners` defaults to `.empty`.

**Step 2**: Add `listen` variant to `IncomingOp`. Add the `ToDesc` tagged union. Add the `"op:listen"` branch in `recvAndDispatch`. Use a `readToDesc` helper:

```zig
fn readToDesc(v: syrup.Value) !ToDesc {
    if (v != .record) return error.InvalidMessage;
    if (v.record.label.* != .symbol) return error.InvalidMessage;
    const label = v.record.label.symbol;
    if (std.mem.eql(u8, label, "desc:answer")) {
        if (v.record.fields.len < 1) return error.InvalidMessage;
        return .{ .answer = try readInt(u32, v.record.fields[0]) };
    }
    if (std.mem.eql(u8, label, "desc:import-promise")) {
        if (v.record.fields.len < 1) return error.InvalidMessage;
        return .{ .import_promise = try readInt(u32, v.record.fields[0]) };
    }
    return error.InvalidListenTarget;
}
```

**Step 3**: Add `resolveAndNotify` to `Vat`. Refactor `recvAndDispatch`'s fulfill/break handlers to call it. Add `sendFulfillToDesc` and `sendBreakToDesc` that take raw descriptor bytes.

**Step 4**: Test: two-vat scenario where A sends `op:deliver` to B, then sends `op:listen` on the answer. B resolves. Assert A receives the resolution forwarded to its listen-desc.

---

## Gap 2: `desc:import-promise` — Promises as First-Class Imports

### What the Spec Demands

`desc:import-promise` is a descriptor type. When it appears in a message field where a target descriptor is expected, it refers to a promise in the remote's AnswerTable by position. It means: "this argument is the promise at position N in your table."

This enables promise pipelining. A sends `op:deliver` to B and gets back answer position 5. Then A can immediately send *another* `op:deliver` with `desc:import-promise 5` as an argument, saying "use the result of that first call as the argument to this second call" — before the first call has resolved.

### 1. Type-Level Design

The fundamental problem: `readImportObjectPos` is the ONLY descriptor reader. It rejects everything that isn't `desc:import-object`. This is a type error at the protocol level.

Define a proper descriptor union:

```zig
/// Wire descriptor for a target or argument in CapTP messages.
/// The spec defines these; the type system enumerates them exhaustively.
pub const WireDesc = union(enum) {
    /// desc:import-object — a concrete remote object at a position.
    import_object: u32,
    /// desc:import-promise — a promise (possibly unresolved) at a position.
    import_promise: u32,
    /// desc:answer — identifies a promise slot (used in op:fulfill/break target).
    answer: u32,
    /// desc:handoff-give — 3rd party introduction (handled separately).
    handoff_give: syrup.Value,  // full record, parsed downstream
    /// desc:handoff-receive — 3rd party introduction receipt.
    handoff_receive: syrup.Value,
};
```

Replace `readImportObjectPos` with a general descriptor reader:

```zig
fn readWireDesc(v: syrup.Value) !WireDesc {
    if (v != .record) return error.InvalidDescriptor;
    if (v.record.label.* != .symbol) return error.InvalidDescriptor;
    const label = v.record.label.symbol;
    if (v.record.fields.len < 1) return error.InvalidDescriptor;

    if (std.mem.eql(u8, label, "desc:import-object"))
        return .{ .import_object = try readInt(u32, v.record.fields[0]) };
    if (std.mem.eql(u8, label, "desc:import-promise"))
        return .{ .import_promise = try readInt(u32, v.record.fields[0]) };
    if (std.mem.eql(u8, label, "desc:answer"))
        return .{ .answer = try readInt(u32, v.record.fields[0]) };
    if (std.mem.eql(u8, label, "desc:handoff-give"))
        return .{ .handoff_give = v };
    if (std.mem.eql(u8, label, "desc:handoff-receive"))
        return .{ .handoff_receive = v };

    return error.UnknownDescriptorType;
}
```

Now `recvAndDispatch` changes. For `op:deliver` and `op:deliver-only`, the target field becomes a `WireDesc`, not a bare `u32`:

```zig
deliver_only: struct {
    target: WireDesc,    // was: u32
    method: []const u8,
    args: []const syrup.Value,
},
deliver: struct {
    target: WireDesc,    // was: u32
    method: []const u8,
    args: []const syrup.Value,
    answer_pos: u32,
    resolver_pos: u32,
},
```

And the `resolve-me-desc` (field index 4 in `op:deliver`) should ALSO be a `WireDesc`, not a `readImportObjectPos` call. The spec says it's a "resolve-me-desc" — the descriptor for where the answer should go. Usually it's a `desc:import-object` pointing to a resolver, but the type system should not assume that.

### 2. Ownership and Lifetime

No ownership changes here — `WireDesc` is by-value for the position-based variants and borrows from the parsed `syrup.Value` for handoff variants (which borrow from the input buffer, freed when the caller `deinitAll`s the value).

The critical lifetime question is: **when a `desc:import-promise` is the target of `op:deliver`, what happens?**

Two cases:
1. **Promise already resolved**: Look up the answer pos → get resolved_bytes → re-parse to find the actual object descriptor → deliver to that object. This is *local promise pipelining resolution*.
2. **Promise still pending**: Queue the deliver. The `Promise` struct needs a queue of pending delivers that flush when resolution arrives. This is the `QueuedSend` pattern already in `vat.zig`'s `Promise` — mirror it in `ocapn_session.zig`.

Add to `ocapn_session.Promise`:

```zig
/// Messages pipelined to this promise while it was pending.
/// On resolution, the session driver must re-dispatch each
/// against the resolved target.
pipelined_ops: std.ArrayListUnmanaged(PipelinedOp) = .empty,

pub const PipelinedOp = struct {
    /// The full op:deliver or op:deliver-only, re-encoded as Syrup bytes.
    /// Stored because we can't hold borrows into the original recv buffer
    /// past the current dispatch cycle.
    op_bytes: []const u8,  // owned
};
```

### 3. Error Taxonomy

| Error | Recoverable? | Action |
|-------|-------------|--------|
| `error.UnknownDescriptorType` | Yes | `op:break` the answer with reason `'unknown-desc-type` |
| `error.InvalidDescriptor` | Yes | `op:break` the answer with reason `'malformed-descriptor` |
| `error.PromiseNotFound` | Yes | `op:break` — the promise pos doesn't exist |
| `error.PromiseBroken` | Yes | If delivering to a broken promise, break the caller's answer too |

### 4. Critique of Current Code

- `readImportObjectPos` hardcodes `"desc:import-object"`. This is the root cause of Gap 2. The function must die and be replaced by `readWireDesc`.
- The `deliver` handler in `recvAndDispatch` calls `readImportObjectPos(r.fields[0])` for the target. If Goblins sends `desc:import-promise` as the target (which it does for promise-pipelined calls), this returns `error.InvalidMessage` and the entire message is dropped. Silently. Your interop partner sends a valid CapTP message and you throw it on the floor.
- The `deliver` handler calls `readImportObjectPos(r.fields[4])` for the resolve-me-desc. Same problem. If the resolver is anything other than `desc:import-object`, you die.
- `promise_bridge.zig` is aware of the problem in passing — its `registerInbound` creates a runtime-side promise for inbound delivers — but it doesn't handle the case where the inbound deliver's *target* is itself a promise. The bridge only bridges *answers*, not *arguments that are promises*.

### 5. Implementation Guidance

**Step 1**: Define `WireDesc` in `ocapn_session.zig` (or a new `ocapn_desc.zig` — descriptors are cross-cutting). Define `readWireDesc` as a file-scoped helper in `ocapn_vat.zig`.

**Step 2**: Change `IncomingOp.deliver.target` and `IncomingOp.deliver_only.target` from `u32` to `WireDesc`. Change `IncomingOp.deliver.resolver_pos` from `u32` to `WireDesc`. Update `recvAndDispatch` to use `readWireDesc`.

**Step 3**: Every call site that currently reads `op.target` as a `u32` must now switch on the `WireDesc`:

```zig
switch (op.target) {
    .import_object => |pos| {
        // Existing path — deliver to a concrete exported object.
        try self.dispatchToObject(pos, op.method, op.args);
    },
    .import_promise => |pos| {
        const promise = self.answers.byAnswerPos(pos);
        if (promise == null) return error.PromiseNotFound;
        switch (promise.?.state) {
            .resolved => {
                // Re-parse resolved_bytes to get the actual object desc,
                // then deliver to it. This is the pipelining resolution path.
                try self.dispatchPipelined(promise.?, op);
            },
            .pending => {
                // Queue the op for later dispatch.
                const op_bytes = try self.reencodeOp(op);
                try promise.?.pipelined_ops.append(self.allocator, .{ .op_bytes = op_bytes });
            },
            .broken => {
                // Promise is broken; break the caller's answer too.
                if (op.answer_pos) |ans| {
                    try self.sendBreak(ans, "6'broken-pipeline-target");
                }
            },
        }
    },
    .answer, .handoff_give, .handoff_receive => return error.InvalidDeliverTarget,
}
```

**Step 4**: When a promise resolves (in the `fulfill` handler), drain `pipelined_ops`:

```zig
// After resolvePromise:
for (p.pipelined_ops.items) |pipelined| {
    defer self.allocator.free(pipelined.op_bytes);
    // Re-parse and re-dispatch the pipelined op against the now-known target.
    try self.redispatchPipelined(pipelined.op_bytes, p.resolved_bytes.items);
}
p.pipelined_ops.clearRetainingCapacity();
```

**Step 5**: Extend `sendDeliver` to accept `WireDesc` for `to_desc` so the outbound path can also emit `desc:import-promise`:

```zig
fn encodeWireDesc(out: *ByteList, desc: WireDesc) !void {
    switch (desc) {
        .import_object => |pos| try fmtAppend(out, "<18'desc:import-object{d}+>", .{pos}),
        .import_promise => |pos| try fmtAppend(out, "<19'desc:import-promise{d}+>", .{pos}),
        .answer => |pos| try fmtAppend(out, "<11'desc:answer{d}+>", .{pos}),
        .handoff_give => |v| {
            const b = try v.encodeAlloc(self.allocator);
            defer self.allocator.free(b);
            try out.appendSlice(b);
        },
        .handoff_receive => |v| {
            const b = try v.encodeAlloc(self.allocator);
            defer self.allocator.free(b);
            try out.appendSlice(b);
        },
    }
}
```

---

## Gap 3: Bootstrap `deposit-gift` / `withdraw-gift`

### What the Spec Demands

The bootstrap object at position 0 handles three methods:

1. **`fetch(swiss-number)`** — already implemented. Resolves a sturdyref swiss to an import position.
2. **`deposit-gift(gift-id, gift-desc)`** — A is giving B a capability via C (the exporter). A deposits the gift at C's bootstrap, keyed by `(session-of-B-to-C, gift-id)`. The gift-desc is a descriptor that C can resolve locally.
3. **`withdraw-gift(gift-id)`** — B connects to C, presents the gift-id that A told it about (via `desc:handoff-give`), and C returns the deposited capability.

**Critical**: `deposit-gift` and `withdraw-gift` can arrive in ANY ORDER. B might connect to C and call `withdraw-gift` before A has called `deposit-gift`. The gift table must handle both orderings.

### 1. Type-Level Design

First, the bootstrap method dispatch. The current `serveBootstrapFetch` method is wrong because it hardcodes `"fetch"`. The bootstrap is an *object with a method table*. Model it as one:

```zig
/// The three methods a bootstrap object must support per spec.
/// Comptime enum — no string comparisons at dispatch time.
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
```

Now the gift table. A gift has a composite key: `(session_id, gift_id)`. A gift has a state: either the deposit has arrived, the withdrawal has arrived, or both.

```zig
pub const GiftKey = struct {
    /// Session identifier — the session between the withdrawer and this vat.
    /// This is opaque bytes from the perspective of the gift table.
    session_id: []const u8,
    /// Gift identifier — unique within the session.
    gift_id: []const u8,
};

pub const GiftState = union(enum) {
    /// deposit-gift arrived first. We hold the gift descriptor bytes,
    /// waiting for withdraw-gift.
    deposited: struct {
        gift_desc_bytes: []const u8,  // owned
    },
    /// withdraw-gift arrived first. We hold the answer position to
    /// fulfill when deposit-gift arrives.
    awaiting_deposit: struct {
        withdraw_answer_pos: AnswerPos,
    },
    /// Both arrived, gift delivered. Tombstone — kept briefly to
    /// reject duplicate withdrawals, then GC'd.
    completed: void,
};

pub const GiftEntry = struct {
    key: GiftKey,
    state: GiftState,
    /// Owned copies of the key bytes (since the original message buffer
    /// will be freed after dispatch).
    owned_session_id: []const u8,
    owned_gift_id: []const u8,

    pub fn deinit(self: *GiftEntry, allocator: Allocator) void {
        switch (self.state) {
            .deposited => |d| allocator.free(d.gift_desc_bytes),
            .awaiting_deposit, .completed => {},
        }
        allocator.free(self.owned_session_id);
        allocator.free(self.owned_gift_id);
    }
};
```

The `GiftTable`:

```zig
pub const GiftTable = struct {
    entries: std.ArrayListUnmanaged(GiftEntry) = .empty,

    pub fn deinit(self: *GiftTable, allocator: Allocator) void {
        for (self.entries.items) |*e| e.deinit(allocator);
        self.entries.deinit(allocator);
    }

    /// deposit-gift: A tells us to hold a gift for B.
    /// If B already called withdraw-gift, fulfill B's pending answer.
    /// Returns .held if stored, .delivered if immediately matched.
    pub fn deposit(
        self: *GiftTable,
        allocator: Allocator,
        session_id: []const u8,
        gift_id: []const u8,
        gift_desc_bytes: []const u8,
    ) !enum { held, delivered } {
        // Check if withdraw already waiting.
        for (self.entries.items) |*e| {
            if (std.mem.eql(u8, e.key.session_id, session_id) and
                std.mem.eql(u8, e.key.gift_id, gift_id))
            {
                switch (e.state) {
                    .awaiting_deposit => {
                        // Match! Fulfill the waiting withdrawal.
                        e.state = .completed;
                        return .delivered;
                    },
                    .deposited => return error.DuplicateDeposit,
                    .completed => return error.GiftAlreadyDelivered,
                }
            }
        }
        // No match — store the deposit.
        const owned_sid = try allocator.dupe(u8, session_id);
        errdefer allocator.free(owned_sid);
        const owned_gid = try allocator.dupe(u8, gift_id);
        errdefer allocator.free(owned_gid);
        const owned_desc = try allocator.dupe(u8, gift_desc_bytes);
        errdefer allocator.free(owned_desc);
        try self.entries.append(allocator, .{
            .key = .{ .session_id = owned_sid, .gift_id = owned_gid },
            .state = .{ .deposited = .{ .gift_desc_bytes = owned_desc } },
            .owned_session_id = owned_sid,
            .owned_gift_id = owned_gid,
        });
        return .held;
    }

    /// withdraw-gift: B asks for the gift A deposited.
    /// If A already deposited, return the descriptor bytes.
    /// If not, record B's answer_pos for later fulfillment.
    pub fn withdraw(
        self: *GiftTable,
        allocator: Allocator,
        session_id: []const u8,
        gift_id: []const u8,
        answer_pos: AnswerPos,
    ) !?[]const u8 {
        for (self.entries.items) |*e| {
            if (std.mem.eql(u8, e.key.session_id, session_id) and
                std.mem.eql(u8, e.key.gift_id, gift_id))
            {
                switch (e.state) {
                    .deposited => |d| {
                        const desc = d.gift_desc_bytes;
                        e.state = .completed;
                        return desc; // caller sends op:fulfill
                    },
                    .awaiting_deposit => return error.DuplicateWithdraw,
                    .completed => return error.GiftAlreadyDelivered,
                }
            }
        }
        // No deposit yet — record the pending withdrawal.
        const owned_sid = try allocator.dupe(u8, session_id);
        errdefer allocator.free(owned_sid);
        const owned_gid = try allocator.dupe(u8, gift_id);
        errdefer allocator.free(owned_gid);
        try self.entries.append(allocator, .{
            .key = .{ .session_id = owned_sid, .gift_id = owned_gid },
            .state = .{ .awaiting_deposit = .{ .withdraw_answer_pos = answer_pos } },
            .owned_session_id = owned_sid,
            .owned_gift_id = owned_gid,
        });
        return null; // caller knows to wait
    }
};
```

### 2. Ownership and Lifetime

- **GiftEntry**: Owns copies of `session_id`, `gift_id`, and `gift_desc_bytes`. The original message buffer (from `recvAndDispatch`) is freed after dispatch; the gift table must outlive it.
- **GiftTable lifetime**: Same as the Vat. Gift entries are scoped to a session. When a session closes (`op:abort` or transport death), all pending gifts for that session should be broken (send `op:break` to any `awaiting_deposit` entries).
- **GC**: Completed gift entries are tombstones. They prevent replay attacks (duplicate withdraw-gift). They should be GC'd on `op:gc-answers` for the corresponding answer position, or on a session-close sweep. In practice, a `std.ArrayListUnmanaged` with linear scan is fine for the expected gift volume (tens, not millions).

The Vat struct gains:

```zig
pub const Vat = struct {
    // ... existing fields ...
    gifts: bootstrap.GiftTable = .{},

    pub fn deinit(self: *Vat) void {
        // ... existing cleanup ...
        self.gifts.deinit(self.allocator);
    }
};
```

### 3. Error Taxonomy

| Error | Recoverable? | Action |
|-------|-------------|--------|
| `error.DuplicateDeposit` | Yes | `op:break` the answer with `'duplicate-gift-deposit` |
| `error.DuplicateWithdraw` | Yes | `op:break` the answer with `'duplicate-gift-withdraw` |
| `error.GiftAlreadyDelivered` | Yes | `op:break` — gift was already consumed |
| `error.UnknownBootstrapMethod` | Yes | `op:break` with `'unknown-method` |
| `error.MissingGiftArgs` | Yes | `op:break` with `'invalid-args` |
| `error.OutOfMemory` | No | `op:abort` + close |

### 4. Critique of Current Code

- `SwissRegistry` is the entire bootstrap. It handles `fetch` and nothing else. The bootstrap object needs to be a proper dispatch point for three methods.
- `serveBootstrapFetch` in `ocapn_vat.zig` is a monolithic method that checks `op.method == "fetch"` and returns `error.NotFetchMethod` otherwise. This is the wrong factoring. The bootstrap should have a general `serveBootstrap` that dispatches on method, and `fetch`, `deposit-gift`, `withdraw-gift` are internal branches.
- The handoff protocol in `ocapn_handoff.zig` encodes `desc:handoff-give` with a `gift_id` field — but there is NO code anywhere that stores a gift on the exporter side. The handoff encoders exist in isolation; the bootstrap doesn't know gifts exist. This is a *protocol-level dead end*: you can encode a handoff-give descriptor that refers to a gift that no vat will ever accept.
- `SwissRegistry` and `GiftTable` serve different purposes but both live at the bootstrap. The bootstrap is the *only* object that exists before any sturdyref is resolved. Both swiss lookup and gift exchange are bootstrap operations. They should coexist under a unified `BootstrapObject` type:

```zig
pub const BootstrapObject = struct {
    swiss: SwissRegistry,
    gifts: GiftTable,

    pub fn init() BootstrapObject {
        return .{ .swiss = SwissRegistry.init(), .gifts = .{} };
    }

    pub fn deinit(self: *BootstrapObject, allocator: Allocator) void {
        self.swiss.deinit(allocator);
        self.gifts.deinit(allocator);
    }
};
```

### 5. Implementation Guidance

**Step 1**: Define `BootstrapMethod` enum with `fromSymbol`. Define `GiftTable`, `GiftEntry`, `GiftKey`, `GiftState` in `ocapn_bootstrap.zig`.

**Step 2**: Replace `SwissRegistry` in `Vat` with `BootstrapObject` (which contains `SwissRegistry` + `GiftTable`). Update all `self.registry.fetch(...)` call sites to `self.bootstrap.swiss.fetch(...)`.

**Step 3**: Replace `serveBootstrapFetch` with `serveBootstrap`:

```zig
pub fn serveBootstrap(self: *Vat, op: anytype) !void {
    if (op.target != .import_object or
        op.target.import_object != bootstrap.BOOTSTRAP_POS)
        return error.NotBootstrapTarget;

    const method = BootstrapMethod.fromSymbol(op.method) orelse {
        try self.sendBreak(op.answer_pos, "14'unknown-method");
        return;
    };

    switch (method) {
        .fetch => try self.serveFetch(op),
        .deposit_gift => try self.serveDepositGift(op),
        .withdraw_gift => try self.serveWithdrawGift(op),
    }
}
```

**Step 4**: Implement `serveDepositGift`:
- Extract `gift-id` (arg 0, bytestring) and `gift-desc` (arg 1, any descriptor) from `op.args`.
- Derive `session_id` from the current peer session (from handshake).
- Encode `gift-desc` to bytes via `encodeAlloc`.
- Call `self.bootstrap.gifts.deposit(...)`.
- If `.delivered`, look up the awaiting withdrawal's answer_pos and `sendFulfill` with the gift desc.
- If `.held`, `sendFulfill` with a simple acknowledgment (e.g., `true` / `t`).

**Step 5**: Implement `serveWithdrawGift`:
- Extract `gift-id` (arg 0, bytestring) from `op.args`.
- Derive `session_id` from the current peer session.
- Call `self.bootstrap.gifts.withdraw(...)`.
- If non-null (deposit already present), `sendFulfill(op.answer_pos, desc_bytes)`.
- If null (deposit not yet arrived), do nothing — the deposit handler will fulfill later.

**Step 6**: Test the ordering invariant: write a test that calls `withdraw_gift` before `deposit_gift` and asserts the withdrawal is fulfilled when the deposit arrives. Write the reverse order test too. Write a test for duplicate deposit and duplicate withdraw rejection.

---

## Epilogue: The Sequence Matters

Implement Gap 2 (`WireDesc`) first. It unblocks everything else — you cannot correctly parse `op:listen`'s `to-desc` without a general descriptor reader, and you cannot correctly parse `deposit-gift`'s arguments without one either.

Then Gap 3 (bootstrap gifts). It requires `WireDesc` for parsing `gift-desc` and unblocks the handoff protocol that is currently encoding dead descriptors.

Then Gap 1 (`op:listen`). It requires the listener model on promises and the descriptor reader from Gap 2. It is also the least likely to be exercised by current Goblins interop (Goblins sends `op:listen` mainly for distributed promise resolution chains, which require all three gaps to function).

The type-level corrections — `WireDesc` replacing `readImportObjectPos`, `BootstrapMethod` replacing string dispatch, `BootstrapObject` replacing bare `SwissRegistry` — are the foundation. Get the types right and the protocol gaps fill themselves. Get the types wrong and you're debugging byte-string mismatches at 2 AM while Goblins sends you perfectly valid messages that your dispatcher has never heard of.

The spec is the contract. The types are the contract's encoding. There is no gap between them — or there is a bug.
