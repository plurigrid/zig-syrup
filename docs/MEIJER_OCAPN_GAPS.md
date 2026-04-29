# OCapN Compliance Gaps: A Meijer-Perspective Design

> "The dual of an iterator is an observer. Everything else follows from that."
> — Erik Meijer

This document designs three missing OCapN spec features for zig-syrup through
the lens of Erik Meijer's work on Rx, duality, and pragmatic category theory.
Each gap is analyzed as a duality, a dataflow topology, and a concrete Zig
implementation guide.

---

## Gap 1: `op:listen` Missing

**Spec:** `<op:listen to-desc listen-desc wants-partial?>` — subscribe to a
promise's resolution.

**Current state:** Promises exist (`AnswerTable`, `Promise`, `PromiseBridge`)
but are purely pull-based: you check `p.state` and read `p.resolved_bytes`.
No subscription mechanism. No push notification. The propagator network
(`propagator.zig`) already implements the Radul-Sussman partial information
lattice with `Cell → Propagator → Cell` edges and automatic `alert_neighbors`.

### 1.1 Duality Analysis

This gap is the **central duality** of reactive programming made manifest
in a distributed protocol.

```
IEnumerable<T>              ↔  IObservable<T>
  .GetEnumerator()          ↔    .Subscribe(observer)
  IEnumerator.MoveNext()    ↔    IObserver.OnNext(value)
  IEnumerator.Current       ↔    IObserver.OnCompleted()
                            ↔    IObserver.OnError(exception)
```

Map this onto CapTP:

```
PULL (current model)        ↔  PUSH (op:listen model)
  answer_table.byAnswerPos  ↔    op:listen registers observer
  p.state == .resolved      ↔    on_resolve callback fires
  p.resolved_bytes          ↔    OnNext(value) → op:fulfill
  p.state == .broken        ↔    OnError(reason) → op:break
```

A **promise** in CapTP is the `IObservable<T>` of exactly one value (or
one error). It is an `Observable.single()` — a one-shot observable. The
`op:listen` message is `Subscribe()`. The `listen-desc` is the observer
reference (a far-ref on the listener's side).

The **resolver** is the dual of the observer: it is the `Subject<T>`, the
thing that can push `OnNext`/`OnCompleted`/`OnError`. The codebase already
has this as `vat.Resolver` with `.fulfillValue()` / `.fulfillCap()` / `.break_()`.

**Key insight:** `wants-partial?` in the spec is the `IObservable` vs
`IObservable<T>` distinction. When `wants-partial? = true`, the listener
wants intermediate values — this is an `Observable<CellValue<T>>` over
the lattice, not just the terminal resolution. This maps *directly* onto
propagator.zig's `Cell` with its `Nothing → Value → Contradiction`
progression.

### 1.2 Reactive/Dataflow Design

```
  Remote A                            Local Vat
  ────────                           ──────────
  op:deliver → promise P created     AnswerTable[pos]
       │                                  │
  op:listen(P, observer-desc)        Add listener edge
       │                             from P's Cell to
       │                             observer propagator
       │                                  │
  ┌────▼────┐                        ┌────▼────┐
  │ SOURCE  │   resolve/break        │  SINK   │
  │ handler │──────────────────────▶ │listener │
  │ code    │                        │  cell   │
  └─────────┘                        └────┬────┘
                                          │
                                     encode + send
                                     op:fulfill / op:break
                                     to listen-desc target
```

**Sources:** The handler resolving the promise (local code, or wire
`op:fulfill`/`op:break` from remote).

**Operator:** The propagator merge function. For single-resolution promises,
this is `latticeMerge` — idempotent (re-resolve with same value = no-op),
contradiction on different values.

**Sink:** Each registered listener. When the Cell transitions from `Nothing`
to `Value(bytes)`, the propagator fires, and the sink serializes an
`op:fulfill` to the listener's far-ref.

### 1.3 Connection to propagator.zig

**Yes, reuse.** This is the entire point.

The propagator network already has:
- `Cell(T, merge_fn)` — holds `CellValue(T)` = `Nothing | Value(T) | Contradiction`
- `Propagator` — input cells × function → output cells, fires on change
- `alert_neighbors` — when a cell changes, all connected propagators fire

A promise IS a cell. `op:listen` IS `cell.add_neighbor`. Resolution IS
`cell.set_content`. The types even line up: `CellValue([]u8)` for syrup
bytes, with `Nothing` = pending, `Value(bytes)` = fulfilled, and
`Contradiction` = double-resolve attempt (which CapTP forbids).

**What to build:**

```zig
// In ocapn_session.zig or a new ocapn_listen.zig

pub const ListenablePromise = struct {
    cell: Cell([]const u8, latticeMerge([]const u8)),
    listeners: std.ArrayListUnmanaged(ListenerSink),
    wants_partial: bool,

    pub const ListenerSink = struct {
        /// Wire-side: desc:import-object position of the remote listener
        listener_pos: u32,
        /// Which session to send the notification through
        session_id: u32,  // or pointer to session
    };
};
```

**Do NOT build a second notification system.** The propagator lattice *is*
the notification system. The only new code is:

1. A `ListenerSink` struct wrapping the wire-side observer reference
2. A propagator function that serializes `op:fulfill`/`op:break` to the
   session's outgoing buffer when its input cell transitions
3. Dispatch of incoming `op:listen` messages in `Vat.recvAndDispatch`

### 1.4 Algebraic Structure

**Laws that must hold:**

1. **Subscribe-before-resolve:** If `op:listen` arrives before resolution,
   the listener MUST receive exactly one notification (fulfill or break).
   This is `Observable.single()` semantics.

2. **Subscribe-after-resolve:** If `op:listen` arrives after the promise
   has already resolved, the notification fires immediately (hot observable
   that replays its terminal event). The cell already holds `Value(bytes)`,
   so `add_neighbor` + immediate `alert` suffices.

3. **Idempotent merge:** `latticeMerge` guarantees that duplicate
   resolutions with the same value are no-ops. Different values create
   a `Contradiction` which MUST become `op:break` to all listeners.

4. **Monotonicity:** The lattice only goes up: `Nothing → Value → Contradiction`.
   Once resolved, you cannot un-resolve. Once broken, you cannot un-break.
   This is the same monotonicity invariant as `IObservable.OnCompleted()`.

5. **wants-partial composition:** If `wants-partial? = true`, intermediate
   `set_content` transitions (partial progress) propagate to listeners. This
   composes: partial listeners on a pipelined chain see each stage's partial
   information. This is `Observable.scan()` over the lattice.

### 1.5 Concrete Zig Implementation

**Step 1: Add `op:listen` to `IncomingOp` union in `ocapn_vat.zig`:**

```zig
listen: struct {
    to_desc: u32,           // answer-pos of the promise to listen on
    listen_desc: u32,       // import-object position of the listener
    wants_partial: bool,
},
```

**Step 2: Parse in `recvAndDispatch`:**

```zig
if (std.mem.eql(u8, tag, "op:listen") and r.fields.len >= 3) {
    const to_pos = try readAnswerPos(r.fields[0]);
    const listen_pos = try readImportObjectPos(r.fields[1]);
    const wants_partial = if (r.fields[2] == .bool_val) r.fields[2].bool_val else false;
    return .{ .op = .{ .listen = .{
        .to_desc = to_pos,
        .listen_desc = listen_pos,
        .wants_partial = wants_partial,
    }}, .value = v };
}
```

**Step 3: Add listener list to `Promise` in `ocapn_session.zig`:**

```zig
pub const Listener = struct {
    import_pos: u32,      // remote's observer reference
    wants_partial: bool,
};

pub const Promise = struct {
    // ... existing fields ...
    listeners: std.ArrayListUnmanaged(Listener) = .empty,

    pub fn addListener(self: *Promise, allocator: Allocator, l: Listener) !void {
        try self.listeners.append(allocator, l);
    }

    pub fn deinit(self: *Promise, allocator: Allocator) void {
        self.resolved_bytes.deinit(allocator);
        self.listeners.deinit(allocator);
    }
};
```

**Step 4: On resolve, notify listeners in `resolvePromise`:**

After setting `p.state = .resolved`, iterate `p.listeners` and enqueue
outgoing `op:fulfill` messages to each `listener.import_pos`. For late
subscribers (promise already resolved when `op:listen` arrives), fire
immediately.

**Step 5: Wire to propagator (optional, for `wants-partial`):**

For full propagator integration, wrap the `Promise` in a
`Cell([]const u8, latticeMerge([]const u8))` and register listener
propagators. This is only needed if `wants-partial?` must carry
intermediate lattice states — the common case (single-shot) only needs
the listener list.

---

## Gap 2: `desc:import-promise` No Dispatch

**Spec:** `<desc:import-promise position>` — a promise as a first-class
wire-transferable descriptor.

**Current state:** Only `desc:import-object` is dispatched.
`readImportObjectPos` is hardcoded to check for the `"desc:import-object"`
label. The ExportTable and PromiseBridge don't distinguish object-imports
from promise-imports.

### 2.1 Duality Analysis

`desc:import-object` and `desc:import-promise` are **duals in the
comonadic sense.**

An **object** descriptor says: "here is a fully-evaluated entity; you can
send messages to it right now." This is `Comonad.extract()` — you can
always get a value out.

A **promise** descriptor says: "here is a not-yet-evaluated entity; you
can send messages to it, and they'll queue until it resolves." This is
`Monad.return()` / `Monad.bind()` — the value is wrapped in a
computational context.

In Meijer's framework:

```
desc:import-object   = T              (the value, right now)
desc:import-promise  = Task<T>        (the value, eventually)
desc:answer          = TaskCompletionSource<T>  (the resolver)
```

Promise pipelining IS monadic bind:

```
op:deliver → Promise P         =  return(P)
op:deliver on P → Promise Q    =  P >>= (\x -> send(x, method))  =  bind
desc:import-promise             =  pass Task<T> as argument       =  first-class monadic value
```

When you pass a `desc:import-promise` as an argument to `op:deliver`,
you're passing a **monadic value** as a first-class argument. The receiver
can `op:listen` on it (subscribe/`await`), pipeline through it (bind),
or forward it to a third party (monadic continuation).

The **missing dispatch** means zig-syrup can produce monadic values
(`deliver()` returns `AnswerPos`) but cannot *receive* them as arguments.
The monad is closed for `return` but open for `bind` — broken.

### 2.2 Reactive/Dataflow Design

```
  Remote vat                              Local vat
  ──────────                             ──────────
  op:deliver(target, method, [desc:import-promise 5], answer, resolver)
       │                                      │
       │    arg[0] is a PROMISE reference     │
       │    not a concrete value              │
       │                                      │
       ▼                                      ▼
  Local must look up answer-pos 5        Create proxy:
  in ITS answer table — this IS          a Promise that
  the remote's promise that we're        wraps the remote
  waiting for too.                       promise reference.
```

**The dataflow:** A `desc:import-promise` in an argument list means
"this argument slot carries an `Observable<T>` rather than a `T`."
The handler receiving this message must be able to:

1. Recognize that the argument is a promise, not an object
2. Subscribe to it (via `op:listen` back to the sender)
3. Or pipeline through it (send to the promise; messages queue at sender)

### 2.3 Connection to propagator.zig

**Indirect.** The propagator cell model means we can represent a remote
promise locally as a `Cell([]const u8, latticeMerge([]const u8))`
initialized to `Nothing`. When the remote promise resolves (we learn
this via `op:listen` callback or `op:fulfill` for the answer position),
we `cell.set_content(resolved_bytes)` — the lattice transition propagates
to any local propagators wired to that cell.

This is **the bridge between CapTP's promise pipelining and the local
propagator network:** remote promises become local cells.

### 2.4 Algebraic Structure

**Laws:**

1. **Substitutability:** `desc:import-promise P` in argument position
   behaves identically to `desc:import-object X` once `P` resolves to `X`.
   Messages pipelined to `P` before resolution must flush to `X` in order.
   (Monadic left-identity: `return a >>= f  ≡  f a`)

2. **Composition:** Chaining `desc:import-promise` through multiple
   `op:deliver` calls must compose. If `P` resolves to `Q` (another
   promise), the chain must follow transitively.
   (Monadic associativity: `(m >>= f) >>= g  ≡  m >>= (\x -> f x >>= g)`)

3. **Transparent forwarding:** Passing a `desc:import-promise` to a
   third party must work — the third party can subscribe to it, pipeline
   through it, or further forward it. The promise is a first-class value.

### 2.5 Concrete Zig Implementation

**Step 1: Add `readImportPromisePos` helper alongside `readImportObjectPos`:**

```zig
fn readImportPromisePos(v: syrup.Value) !u32 {
    if (v != .record) return error.InvalidMessage;
    if (v.record.label.* != .symbol) return error.InvalidMessage;
    if (!std.mem.eql(u8, v.record.label.symbol, "desc:import-promise"))
        return error.InvalidMessage;
    if (v.record.fields.len < 1) return error.InvalidMessage;
    return readInt(u32, v.record.fields[0]);
}
```

**Step 2: Add a generic "target descriptor" union:**

```zig
pub const TargetDesc = union(enum) {
    import_object: u32,   // position of a resolved import
    import_promise: u32,  // position of a pending promise
    answer: u32,          // answer slot (resolver side)
};

fn readTargetDesc(v: syrup.Value) !TargetDesc {
    if (v != .record) return error.InvalidMessage;
    if (v.record.label.* != .symbol) return error.InvalidMessage;
    const label = v.record.label.symbol;
    if (v.record.fields.len < 1) return error.InvalidMessage;
    const pos = try readInt(u32, v.record.fields[0]);
    if (std.mem.eql(u8, label, "desc:import-object")) return .{ .import_object = pos };
    if (std.mem.eql(u8, label, "desc:import-promise")) return .{ .import_promise = pos };
    if (std.mem.eql(u8, label, "desc:answer")) return .{ .answer = pos };
    return error.InvalidMessage;
}
```

**Step 3: Update `IncomingOp.deliver` and `deliver_only` to use `TargetDesc`:**

```zig
deliver_only: struct {
    target: TargetDesc,  // was: u32 (only import-object)
    method: []const u8,
    args: []const syrup.Value,
},
deliver: struct {
    target: TargetDesc,  // was: u32
    method: []const u8,
    args: []const syrup.Value,
    answer_pos: u32,
    resolver_pos: u32,
},
```

**Step 4: In dispatch, when target is `import_promise`:**

```zig
switch (op.target) {
    .import_object => |pos| {
        // existing: dispatch to handler at export pos
    },
    .import_promise => |pos| {
        // NEW: queue the message at the promise identified by `pos`
        // in the answer table. This is promise pipelining.
        // When the promise resolves, the queued messages flush.
        try self.answers.queueOnPromise(pos, method, args, ...);
    },
    .answer => |pos| {
        // Resolver-side targeting — send to the answer's resolver
    },
}
```

**Step 5: Track promise-imports in ExportTable:**

The ExportTable currently tracks only objects. Add a variant:

```zig
pub const ExportKind = enum { object, promise };

pub const Entry = struct {
    position: ExportPos,
    wire_count: u32,
    kind: ExportKind = .object,  // default for backward compat
};
```

---

## Gap 3: Bootstrap `deposit-gift` / `withdraw-gift` Missing

**Spec:** The bootstrap object handles three methods:
- `fetch(swiss)` — look up a sturdy reference (IMPLEMENTED)
- `deposit-gift(gift-id, gift-cap)` — deposit a capability gift for later pickup
- `withdraw-gift(gift-id, recipient-key)` — claim a deposited gift

Critically, **deposit and withdraw can arrive in ANY ORDER.** The gift table
is a rendezvous point.

### 3.1 Duality Analysis

This is the **join problem.** Two independent asynchronous streams must
synchronize:

```
deposit(id, cap)     ←→     withdraw(id, key)
   │                              │
   ▼                              ▼
gift-table[id].cap = cap    gift-table[id].key = key
   │                              │
   └──────────┬───────────────────┘
              │
         BOTH PRESENT → resolve
              │
         gift → recipient
```

In Rx terms, this is `Observable.zip()` or `Observable.combineLatest()`:

```csharp
var deposits  = Observable.FromEvent<(GiftId, Cap)>(bootstrap, "deposit-gift");
var withdraws = Observable.FromEvent<(GiftId, Key)>(bootstrap, "withdraw-gift");

deposits.Join(withdraws,
    d => Observable.Never<Unit>(),   // deposit stays until matched
    w => Observable.Never<Unit>(),   // withdraw stays until matched
    (d, w) => new Gift(d.Cap, w.Key, d.GiftId)
)
.Subscribe(gift => deliverGiftToRecipient(gift));
```

But it's MORE than zip — zip pairs by position. This pairs by
**key** (the gift-id). It's a **keyed join** — `GroupJoin` in Rx,
or a hash join in database terms.

In the **effects/coeffects** framing:
- `deposit-gift` is an **effect**: the gifter *does* something (places a
  cap in the table). The bootstrap is the effect handler.
- `withdraw-gift` is a **coeffect**: the receiver *needs* something (the
  cap). The bootstrap provides it.
- The gift table is the **handler state** that mediates between effect
  and coeffect. In algebraic effects terms: `deposit` is `perform Deposit(id, cap)`
  and `withdraw` is `perform Withdraw(id, key)`, and the bootstrap is
  the handler that implements both, using shared mutable state (the gift
  table) to coordinate.

### 3.2 Reactive/Dataflow Design

```
  Vat A (gifter)              Bootstrap               Vat B (receiver)
  ──────────────              ─────────               ────────────────
  deposit-gift(id, cap) ──▶  gift_table[id] ◀── withdraw-gift(id, key)
                              │                        │
                              ├─ if both present ──────┤
                              │   verify key           │
                              │   resolve:             │
                              │   deliver cap → B      │
                              └────────────────────────┘
```

**State machine for each gift-id slot:**

```
  Empty
    │
    ├── deposit arrives first ──▶ HaveDeposit(cap)
    │                                 │
    │                                 └── withdraw arrives ──▶ Complete
    │
    └── withdraw arrives first ──▶ HaveWithdraw(key, answer_pos)
                                      │
                                      └── deposit arrives ──▶ Complete
```

This is a **two-cell propagator join.** Each gift-id has two input cells:
- `deposit_cell: Cell(?Cap)` — filled by `deposit-gift`
- `withdraw_cell: Cell(?(Key, AnswerPos))` — filled by `withdraw-gift`

A propagator watches both. When both have values, it fires: verify the key,
deliver the cap to the receiver's answer position, and clean up.

### 3.3 Connection to propagator.zig

**Yes, the join point IS a propagator.**

```zig
// Gift slot as two propagator cells
const GiftSlot = struct {
    deposit_cell:  Cell(?GiftDeposit,  latticeMerge(?GiftDeposit)),
    withdraw_cell: Cell(?GiftWithdraw, latticeMerge(?GiftWithdraw)),
    // propagator wired to both, fires on join
};
```

When `deposit-gift` arrives: `deposit_cell.set_content(deposit)`.
When `withdraw-gift` arrives: `withdraw_cell.set_content(withdraw)`.

The propagator function:

```zig
fn gift_join(args: []const ?GiftInfo) ?GiftResolution {
    const deposit  = args[0] orelse return null;  // not yet
    const withdraw = args[1] orelse return null;  // not yet
    // BOTH present — verify and resolve
    return GiftResolution{ .cap = deposit.cap, .recipient = withdraw.recipient };
}
```

This is identical to `neurofeedback_gate` in propagator.zig — a function
that requires all inputs before producing output. The propagator network
handles the "any order" problem by design: cells accept input whenever it
arrives, and the propagator fires only when all inputs are present.

**However,** pragmatically, the propagator network is typed with `comptime T`
and the gift table needs dynamic gift-ids. Two approaches:

**Approach A (pragmatic):** Don't use the generic propagator. Build a
purpose-built `GiftTable` with the same join semantics but using a
`HashMap(GiftId, GiftSlot)`. This is simpler and avoids the comptime
generics complexity.

**Approach B (principled):** Create a fixed pool of propagator cells keyed
by gift-id, with dynamic registration. More complex but demonstrates that
the propagator is the universal coordination primitive.

**Recommendation: Approach A.** Be pragmatic. The join semantics are the
important part, not whether they're literally implemented via `propagator.zig`
generics. Name the structures to make the dataflow relationship explicit.

### 3.4 Algebraic Structure

**Laws:**

1. **Commutativity:** `deposit ; withdraw ≡ withdraw ; deposit`.
   The order of arrival must not affect the outcome. This is the join's
   commutativity law.

2. **Idempotent deposit:** Depositing the same gift-id twice with the same
   cap is a no-op. Depositing with a *different* cap is a contradiction
   (the lattice catches this).

3. **Single-use withdraw:** Each gift-id can be withdrawn exactly once.
   After successful withdrawal, the slot is consumed. This is `Observable.single()`
   semantics again — one event, then complete.

4. **Authentication:** The `withdraw-gift` must prove the recipient is the
   intended target. The `recipient-key` from `desc:handoff-give` must match
   the key presented in `withdraw-gift`. This is an access control check,
   not an algebraic property, but it gates the join.

5. **Timeout/GC:** Gift slots that remain half-filled forever must be
   garbage-collected. This is the `Observable.timeout()` operator — if
   the join doesn't complete within a window, break both sides.

### 3.5 Concrete Zig Implementation

**Step 1: Define the gift table:**

```zig
// In ocapn_bootstrap.zig or new ocapn_gifts.zig

pub const GiftId = [32]u8;  // same as GIFT_ID_LEN from ocapn_handoff.zig

pub const GiftDeposit = struct {
    cap_bytes: []u8,        // Syrup-encoded capability descriptor
    depositor_session: u32, // which session deposited it
};

pub const GiftWithdraw = struct {
    recipient_key: [32]u8,
    answer_pos: u32,        // where to send the resolution
    session_id: u32,        // which session to send through
};

pub const GiftSlot = struct {
    id: GiftId,
    deposit: ?GiftDeposit = null,
    withdraw: ?GiftWithdraw = null,
    created_ms: i64,        // for timeout GC

    /// Check if both halves are present (join complete).
    pub fn isJoined(self: *const GiftSlot) bool {
        return self.deposit != null and self.withdraw != null;
    }
};

pub const GiftTable = struct {
    slots: std.ArrayListUnmanaged(GiftSlot),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) GiftTable {
        return .{ .slots = .empty, .allocator = allocator };
    }

    pub fn deinit(self: *GiftTable) void {
        for (self.slots.items) |*s| {
            if (s.deposit) |d| self.allocator.free(d.cap_bytes);
        }
        self.slots.deinit(self.allocator);
    }

    /// Deposit a gift. Returns true if the join completed (withdraw
    /// was already waiting). Caller should then deliver the gift.
    pub fn deposit(self: *GiftTable, id: GiftId, dep: GiftDeposit) !bool {
        for (self.slots.items) |*s| {
            if (std.mem.eql(u8, &s.id, &id)) {
                s.deposit = dep;
                return s.isJoined();
            }
        }
        try self.slots.append(self.allocator, .{
            .id = id,
            .deposit = dep,
            .created_ms = std.time.milliTimestamp(),
        });
        return false;
    }

    /// Withdraw a gift. Returns true if the join completed (deposit
    /// was already waiting). Caller should then deliver the gift.
    pub fn withdraw(self: *GiftTable, id: GiftId, w: GiftWithdraw) !bool {
        for (self.slots.items) |*s| {
            if (std.mem.eql(u8, &s.id, &id)) {
                s.withdraw = w;
                return s.isJoined();
            }
        }
        try self.slots.append(self.allocator, .{
            .id = id,
            .withdraw = w,
            .created_ms = std.time.milliTimestamp(),
        });
        return false;
    }

    /// Retrieve and remove a completed gift slot.
    pub fn consumeJoined(self: *GiftTable, id: GiftId) ?GiftSlot {
        for (self.slots.items, 0..) |s, i| {
            if (std.mem.eql(u8, &s.id, &id) and s.isJoined()) {
                return self.slots.swapRemove(i);
            }
        }
        return null;
    }

    /// GC: remove slots older than `max_age_ms` that haven't joined.
    pub fn gc(self: *GiftTable, now_ms: i64, max_age_ms: i64) usize {
        var removed: usize = 0;
        var i: usize = 0;
        while (i < self.slots.items.len) {
            if (now_ms - self.slots.items[i].created_ms > max_age_ms
                and !self.slots.items[i].isJoined())
            {
                if (self.slots.items[i].deposit) |d| self.allocator.free(d.cap_bytes);
                _ = self.slots.swapRemove(i);
                removed += 1;
            } else {
                i += 1;
            }
        }
        return removed;
    }
};
```

**Step 2: Extend `SwissRegistry` (or bootstrap dispatch) to handle the
two new methods:**

```zig
// In Vat.serveBootstrapFetch, generalize to serveBootstrap:

pub fn serveBootstrap(self: *Vat, op: anytype) !BootstrapResult {
    if (op.target != bootstrap.BOOTSTRAP_POS) return error.NotBootstrapTarget;

    if (std.mem.eql(u8, op.method, "fetch")) {
        // ... existing fetch logic ...
    }
    if (std.mem.eql(u8, op.method, "deposit-gift")) {
        // args: [gift-id, cap-descriptor]
        const gift_id = readGiftId(op.args[0]);
        const cap_bytes = try op.args[1].encodeAlloc(self.allocator);
        const joined = try self.gift_table.deposit(gift_id, .{
            .cap_bytes = cap_bytes,
            .depositor_session = current_session_id,
        });
        if (joined) try self.deliverJoinedGift(gift_id);
        // deposit-gift has no answer — it's fire-and-forget (deliver-only)
    }
    if (std.mem.eql(u8, op.method, "withdraw-gift")) {
        // args: [gift-id, recipient-key]
        const gift_id = readGiftId(op.args[0]);
        const key = readRecipientKey(op.args[1]);
        const joined = try self.gift_table.withdraw(gift_id, .{
            .recipient_key = key,
            .answer_pos = op.answer_pos,
            .session_id = current_session_id,
        });
        if (joined) try self.deliverJoinedGift(gift_id);
        // If not yet joined, the answer stays pending until deposit arrives
    }
}
```

**Step 3: The `deliverJoinedGift` function — the join fires:**

```zig
fn deliverJoinedGift(self: *Vat, gift_id: GiftId) !void {
    const slot = self.gift_table.consumeJoined(gift_id) orelse return;
    // Verify recipient key matches the handoff-give's recipient_key
    // (authentication check — not shown in detail)

    // Resolve the withdraw's answer with the deposited cap descriptor
    try self.sendFulfill(
        slot.withdraw.?.answer_pos,
        slot.deposit.?.cap_bytes,
    );
    // Free the deposit's cap_bytes
    self.allocator.free(slot.deposit.?.cap_bytes);
}
```

**Step 4: Add `GiftTable` to `Vat`:**

```zig
pub const Vat = struct {
    // ... existing fields ...
    gift_table: GiftTable,

    pub fn init(...) Vat {
        return .{
            // ...
            .gift_table = GiftTable.init(allocator),
        };
    }

    pub fn deinit(self: *Vat) void {
        // ...
        self.gift_table.deinit();
    }
};
```

---

## Cross-Cutting: The Fundamental Duality

All three gaps are instances of the same duality:

| Pull (current) | Push (needed) | Rx concept |
|---|---|---|
| Check promise state | Get notified on resolve | Observable.Subscribe |
| Pass object ref | Pass promise ref | Task\<T\> as value |
| Fetch swiss immediately | Deposit/withdraw join | Observable.Zip on key |

The propagator network (`propagator.zig`) is the implementation backbone
for all three:
- **Gap 1:** Promises become cells; listeners become propagator edges
- **Gap 2:** Remote promise refs become local cells initialized to `Nothing`
- **Gap 3:** Gift slots are two-cell join propagators

Zig doesn't have monads, HKTs, or type classes. But the *structure* is
still there:
- `CellValue(T)` IS `Maybe T` (with Contradiction as the error case)
- `cell.set_content` IS `return` (inject a value into the context)
- Propagator wiring IS `bind` (when this cell changes, compute and set that cell)
- `latticeMerge` IS the monad's join (flatten nested contexts)

Name things to make the duality visible. Use the propagator network where
it fits. Build simple hash-map structures where comptime generics make
propagator.zig awkward. The important thing is that the *data flow topology*
reflects the categorical structure, even when the *type system* can't
enforce it.

> "Category theory is the mathematics of analogy. We don't need the types
> to enforce it. We need the programmers to see it."
> — paraphrasing Meijer

---

## Implementation Priority

1. **Gap 1 (op:listen):** Highest regret. Without it, no conforming CapTP
   handshake can complete with Spritely Goblins. The listener list on
   `Promise` is ~40 lines of code. Wire it into existing `resolvePromise`.

2. **Gap 3 (deposit/withdraw):** Second priority. The `GiftTable` is a
   self-contained ~80-line module. It enables 3-vat handoff (which depends
   on `ocapn_handoff.zig` that already exists). Without it, capability
   introduction across trust boundaries is impossible.

3. **Gap 2 (desc:import-promise):** Third priority. This is mostly dispatch
   plumbing — adding `TargetDesc` and updating `readImportObjectPos` call
   sites. The hardest part is ensuring pipelined sends queue correctly when
   the target is a promise rather than an object. The runtime side (`vat.zig`'s
   `sendToPromise`) already handles this; the wire side needs to bridge.
