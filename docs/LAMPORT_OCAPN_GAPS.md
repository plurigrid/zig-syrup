# OCapN Compliance Gaps: A Lamport-Perspective Design

*Specification as design. The protocol must be specified precisely before any code is written.*

> "A specification is an abstraction that specifies the allowed behaviors of a system.
> Writing code without a specification is like building a bridge without an engineering drawing."
> — L. Lamport

This document specifies three OCapN CapTP compliance gaps in zig-syrup as state machines
with safety invariants, liveness properties, and ordering constraints.

---

## Gap 1: `op:listen` — Promise Observation

### 1.1 The Problem

The OCapN spec requires:
```
<op:listen to-desc listen-desc wants-partial?>
```
A peer registers a *listener* on a promise. When the promise resolves (fulfills or breaks),
the vat holding the promise notifies the listener. `wants-partial?` controls whether
resolution to *another promise* (a forwarding promise) triggers notification.

**Current state**: `syrup.zig` defines the label string `op_listen = "9'op:listen"` at line 2443,
but `ocapn_vat.zig`'s `recvAndDispatch` has no handler arm for it. The `IncomingOp` union
lacks a `listen` variant. Promises can be created (via `op:deliver`'s answer-pos) but
never observed remotely.

**Impact**: Session-fatal with Goblins. Every remote promise observation uses `op:listen`.

### 1.2 State Machine Specification

#### State Variables

```
VARIABLES
  promises,       \* Map: AnswerPos → PromiseRecord
  listeners,      \* Map: AnswerPos → Set of ListenerRecord
  notifications   \* Sequence of pending notifications (outbound queue)

PromiseRecord == [
  state    : {"pending", "fulfilled", "broken"},
  value    : SyrupBytes ∪ {⊥},
  resolved_to_promise : Bool     \* true when fulfilled to another promise
]

ListenerRecord == [
  listen_desc    : Descriptor,   \* where to send notification
  wants_partial  : Bool          \* notify on promise→promise resolution?
]
```

#### Initial State

```
Init ==
  /\ promises = { pos ↦ [state: "pending", value: ⊥, resolved_to_promise: FALSE]
                  : pos ∈ AllocatedAnswerPositions }
  /\ listeners = { pos ↦ {} : pos ∈ dom(promises) }
  /\ notifications = ⟨⟩
```

#### Transitions

**T1: RegisterListener(answer_pos, listen_desc, wants_partial)**
```
Pre:  answer_pos ∈ dom(promises)
Post:
  IF promises[answer_pos].state = "pending"
  THEN
    \* Promise still pending: register listener for future notification
    listeners' = [listeners EXCEPT ![answer_pos] =
                    @ ∪ {[listen_desc: listen_desc, wants_partial: wants_partial]}]
  ELSE IF promises[answer_pos].state = "fulfilled"
       /\ (¬promises[answer_pos].resolved_to_promise \/ wants_partial)
  THEN
    \* Promise already resolved and listener wants this kind of notification:
    \* enqueue immediate notification
    notifications' = Append(notifications,
      [type: "fulfill", target: listen_desc, value: promises[answer_pos].value])
  ELSE IF promises[answer_pos].state = "broken"
  THEN
    \* Already broken: immediate notification regardless of wants_partial
    notifications' = Append(notifications,
      [type: "break", target: listen_desc, reason: promises[answer_pos].value])
  ELSE
    \* Fulfilled to a promise, listener does NOT want partial: no-op (wait for final)
    \* This case requires tracking the forwarding chain — see §1.5.
    listeners' = [listeners EXCEPT ![answer_pos] =
                    @ ∪ {[listen_desc: listen_desc, wants_partial: FALSE]}]
```

**T2: FulfillPromise(answer_pos, value, is_promise_value)**
```
Pre:  promises[answer_pos].state = "pending"
Post:
  promises' = [promises EXCEPT ![answer_pos] =
    [state: "fulfilled", value: value, resolved_to_promise: is_promise_value]]
  \* Notify all registered listeners according to their wants_partial setting
  LET eligible == {l ∈ listeners[answer_pos] :
                     ¬is_promise_value \/ l.wants_partial}
  IN notifications' = notifications ◦
    ⟨[type: "fulfill", target: l.listen_desc, value: value] : l ∈ eligible⟩
  \* Non-eligible listeners with wants_partial=FALSE remain registered
  \* (they wait for the forwarded promise to resolve to a non-promise)
  listeners' = [listeners EXCEPT ![answer_pos] =
    listeners[answer_pos] \ eligible]
```

**T3: BreakPromise(answer_pos, reason)**
```
Pre:  promises[answer_pos].state = "pending"
Post:
  promises' = [promises EXCEPT ![answer_pos] =
    [state: "broken", value: reason, resolved_to_promise: FALSE]]
  \* ALL listeners get notified on break, regardless of wants_partial
  notifications' = notifications ◦
    ⟨[type: "break", target: l.listen_desc, reason: reason]
     : l ∈ listeners[answer_pos]⟩
  listeners' = [listeners EXCEPT ![answer_pos] = {}]
```

### 1.3 Safety Properties

**S1 (No phantom notifications)**: A listener is notified at most once per registration.
```
∀ l ∈ ListenerRecord, pos ∈ AnswerPos:
  |{n ∈ notifications : n.target = l.listen_desc ∧ n originated from pos}| ≤ 1
```

**S2 (No notification before resolution)**: If `promises[pos].state = "pending"`,
then no notification for `pos` exists in `notifications`.

**S3 (Monotone promise state)**: Once `promises[pos].state ≠ "pending"`, it never
changes again. (`pending → fulfilled` and `pending → broken` are terminal; the
existing `PromiseAlreadyResolved` error in `AnswerTable` enforces this.)

**S4 (Consistent notification content)**: If the notification says "fulfill", the
value matches `promises[pos].value` at the moment of resolution.

### 1.4 Liveness Properties

**L1 (Eventually notified)**: If a listener is registered on a promise that
eventually resolves, and the listener's `wants_partial` setting permits notification,
then a notification is eventually enqueued and sent.

**L2 (Late listener serviced)**: If `op:listen` arrives after resolution, the
listener is notified immediately (within the same dispatch turn). No listener
is silently dropped due to timing.

### 1.5 Ordering Concerns and Happens-Before

**Message ordering within a session is FIFO** (TCP + length-prefix framing guarantees
this). Therefore:

- If a peer sends `op:deliver` (creating answer A) then `op:listen(A, ...)`, the
  listen always arrives after the deliver. No race within a single session.

- **Cross-session race**: If vat B sends `op:listen` on a promise held by vat A, and
  independently vat A resolves that promise, the `op:listen` and the internal
  resolution event have no happens-before relation. The handler must check promise
  state atomically:
  ```
  lock(promise_pos) {
    if (promise.state == .pending) {
      add_listener(...)
    } else {
      enqueue_immediate_notification(...)
    }
  }
  ```
  In zig-syrup's single-threaded vat, this is naturally atomic (the dispatch loop
  processes one message at a time). **No lock needed** — but the check-and-act
  must be in a single code path, not split across turns.

- **happens-before for `wants_partial = false`**: When a promise P resolves to
  another promise Q, listeners on P with `wants_partial = false` must be forwarded
  to Q's listener set. This creates a *transitive dependency*:
  ```
  listen(P) →hb resolve(P→Q) →hb resolve(Q→value) →hb notify(listener)
  ```
  The implementation must track this chain. Simplest approach: when P resolves to Q,
  move P's `wants_partial=false` listeners into Q's listener set.

### 1.6 Fault Tolerance

- **Session drop before notification sent**: Notifications in the outbound queue are
  lost. This is correct: CapTP is session-scoped. The remote side's promise becomes
  broken with a transport-level error.

- **Session drop between listen and resolution**: The listener descriptor becomes
  invalid. On session teardown, all pending listeners should be discarded (they
  reference descriptors in the now-dead session).

- **Double listen on same promise**: Spec-legal. Each registration is independent.
  The listener set is a *multiset* conceptually (same descriptor can appear twice;
  each gets its own notification).

### 1.7 Implementation Guidance

**Files to modify**:

1. **`src/ocapn_session.zig`** — Add a `ListenerTable`:
   ```zig
   pub const Listener = struct {
       answer_pos: AnswerPos,
       listen_desc_bytes: []const u8,  // pre-encoded Syrup descriptor
       wants_partial: bool,
   };

   pub const ListenerTable = struct {
       entries: std.ArrayListUnmanaged(Listener),
       // Methods: addListener, notifyAll(answer_pos), removeByPos
   };
   ```

2. **`src/ocapn_vat.zig`** — Add to `Vat`:
   - New field: `listeners: session.ListenerTable`
   - New `IncomingOp` variant:
     ```zig
     listen: struct { to_pos: u32, listen_desc: syrup.Value, wants_partial: bool },
     ```
   - In `recvAndDispatch`, add arm for `"op:listen"` with 3 fields:
     - `r.fields[0]`: target descriptor (read position from `desc:answer` or `desc:import-promise`)
     - `r.fields[1]`: listen-desc (a descriptor — keep as raw `syrup.Value`)
     - `r.fields[2]`: `wants-partial?` (Syrup bool → `r.fields[2] == .bool`)
   - **Critical check**: On listen arrival, if promise already resolved/broken,
     emit notification immediately. Else register in `ListenerTable`.

3. **`src/ocapn_vat.zig`** — Modify `sendFulfill` / `sendBreak` paths:
   After resolving a promise in the `AnswerTable`, sweep the `ListenerTable` for
   matching `answer_pos` entries and emit `op:deliver-only` (or `op:deliver`) to
   each `listen_desc`.

4. **Wire encoding for notifications**: The notification to a listener is an
   `op:deliver-only` to the `listen_desc` with method `fulfill` or `break` and
   the resolved value/reason as argument.

---

## Gap 2: `desc:import-promise` — Promise Descriptor Dispatch

### 2.1 The Problem

The OCapN spec defines:
```
<desc:import-promise position>
```
This is used in `op:deliver`'s `resolve-me-desc` field (field index 4) when the
caller wants the result delivered to a *promise* position rather than an *object*
position. It means "I'm giving you a promise reference at this position; resolve
it when you have the answer."

**Current state**: `syrup.zig` defines `desc_promise = "16'desc:import-promise"` at
line 2448, but `ocapn_vat.zig`'s `readImportObjectPos` (line 436) only accepts
`desc:import-object`. The `recvAndDispatch` handler for `op:deliver` calls
`readImportObjectPos` for field 4 (the resolver), which will error on
`desc:import-promise`.

**Impact**: Message-fatal. Goblins sends `desc:import-promise` for `resolve-me-desc`.

### 2.2 State Machine Specification

#### State Variables (extending §1)

```
VARIABLES
  import_table    \* Map: Position → ImportKind
  
ImportKind == {"object", "promise"}
```

The key insight is that **an import position can refer to either an object or a
promise**. The current code conflates these. The state machine must distinguish them.

#### Transitions

**T4: ReceiveDeliver(target_desc, method, args, answer_desc, resolve_me_desc)**
```
Pre:  phase = "established"
Post:
  LET target_pos = extractPosition(target_desc)
      answer_pos = extractPosition(answer_desc)
      resolve_kind = CASE resolve_me_desc.label OF
                       "desc:import-object"  → "object"
                       "desc:import-promise" → "promise"
      resolve_pos = extractPosition(resolve_me_desc)
  IN
    \* Dispatch message to local handler at target_pos
    \* Record that answer_pos will be resolved via resolve_pos of kind resolve_kind
    answers' = [answers EXCEPT ![answer_pos] =
      [state: "pending", resolve_kind: resolve_kind, resolve_pos: resolve_pos]]
```

**T5: ResolveAnswer(answer_pos, value)**
```
Pre:  answers[answer_pos].state = "pending"
Post:
  IF answers[answer_pos].resolve_kind = "object"
  THEN
    \* Send op:fulfill targeting desc:import-object at resolve_pos
    send(op:fulfill, <desc:import-object resolve_pos>, value)
  ELSE  \* resolve_kind = "promise"
    \* Resolve the remote promise: the semantics are the same wire message,
    \* but the remote will interpret it as resolving a promise, not delivering
    \* to an object. The wire encoding is identical:
    send(op:fulfill, <desc:answer answer_pos>, value)
```

### 2.3 Safety Properties

**S5 (Descriptor kind preservation)**: If a peer sends `desc:import-promise` in the
`resolve-me-desc` slot, the resolver position must be tracked as a promise position.
Any reply that references this position must use the promise semantics.

**S6 (No silent rejection)**: An incoming `desc:import-promise` must never cause
`error.InvalidMessage`. If unsupported, the correct behavior is `op:abort` with a
reason, not a parse failure that kills the connection silently.

### 2.4 Liveness Properties

**L3 (Message not dropped)**: Every well-formed `op:deliver` with `desc:import-promise`
in the resolver slot must be dispatched to the local handler, not rejected.

### 2.5 Ordering Concerns

The `desc:import-promise` position number is allocated by the **sender** (the remote
peer). It represents a position in *their* answer table. When we fulfill, we send
`op:fulfill <desc:answer N>` where N is this position. The peer interprets it as
resolving their promise at position N.

**Critical ordering**: If the peer sends multiple `op:deliver` messages referencing
the same `desc:import-promise` position, they are all pipelining through the same
promise. The *first* fulfillment wins; subsequent ones are protocol errors (the
promise is already resolved). The `PromiseAlreadyResolved` guard in `AnswerTable`
already handles this.

### 2.6 Fault Tolerance

- If the resolver position is garbage (not a valid position in the peer's table),
  the peer will receive an `op:fulfill` targeting a nonexistent answer. The peer
  should handle this gracefully (Goblins does; zig-syrup's `gc-answers` path
  already tolerates unknown positions).

### 2.7 Implementation Guidance

**Files to modify**:

1. **`src/ocapn_vat.zig`** — Add `readImportPromisePos`:
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

2. **`src/ocapn_vat.zig`** — Add `readResolverDesc` that accepts either kind:
   ```zig
   pub const ResolverKind = enum { object, promise };
   pub const ResolverDesc = struct { position: u32, kind: ResolverKind };

   fn readResolverDesc(v: syrup.Value) !ResolverDesc {
       if (v != .record) return error.InvalidMessage;
       if (v.record.label.* != .symbol) return error.InvalidMessage;
       if (std.mem.eql(u8, v.record.label.symbol, "desc:import-object")) {
           return .{ .position = try readInt(u32, v.record.fields[0]), .kind = .object };
       }
       if (std.mem.eql(u8, v.record.label.symbol, "desc:import-promise")) {
           return .{ .position = try readInt(u32, v.record.fields[0]), .kind = .promise };
       }
       return error.InvalidMessage;
   }
   ```

3. **`src/ocapn_vat.zig`** — Modify `IncomingOp.deliver`:
   ```zig
   deliver: struct {
       target: u32,
       method: []const u8,
       args: []const syrup.Value,
       answer_pos: u32,
       resolver_pos: u32,
       resolver_kind: ResolverKind,  // NEW FIELD
   },
   ```

4. **`src/ocapn_vat.zig`** — In `recvAndDispatch`'s `op:deliver` arm, replace:
   ```zig
   // OLD:
   const resolver_pos = try readImportObjectPos(r.fields[4]);
   // NEW:
   const resolver = try readResolverDesc(r.fields[4]);
   ```
   And populate the new field in the returned struct.

5. **`src/ocapn_vat.zig`** — Modify `deliver()` (the *sender* method):
   Add parameter `resolver_kind: ResolverKind` and emit either
   `<desc:import-object N>` or `<desc:import-promise N>` for field 4
   based on the kind.

6. **`src/ocapn_session.zig`** — Optionally extend `Promise` to record
   `resolver_kind` so that fulfillment paths can distinguish. In practice,
   the wire-level `op:fulfill` message is identical either way — the
   distinction matters only for the remote peer's internal dispatch.

---

## Gap 3: Bootstrap `deposit-gift` / `withdraw-gift`

### 3.1 The Problem

The OCapN spec requires the bootstrap object (position 0) to handle three methods:

| Method | Arguments | Purpose |
|--------|-----------|---------|
| `fetch` | `(swiss-number)` | Resolve sturdy-ref → import (EXISTS) |
| `deposit-gift` | `(gift-id, gift-cap)` | Gifter deposits a reference + gift-id |
| `withdraw-gift` | `(gift-id, recipient-key-signed-nonce)` | Receiver redeems via `desc:handoff-receive` |

**Current state**: `ocapn_bootstrap.zig` only implements `SwissRegistry` for `fetch`.
There is no gift table, no session-aware deposit/withdraw dispatch. The handoff
*descriptor encoding* exists in `ocapn_handoff.zig` (sign/verify), but the
*bootstrap-level operations* that use them do not.

**Impact**: All 3-vat handoffs fail when zig-syrup is the exporter (vat C).

### 3.2 State Machine Specification

The 3-vat handoff involves three parties: A (gifter), B (receiver), C (exporter).
C is the vat that holds the actual capability. The handoff works as:

```
1. A has a reference to cap X at C.
2. A wants to give cap X to B.
3. A→C: deposit-gift(gift-id, cap X)           [via bootstrap at C]
4. A→B: desc:handoff-give(...)                   [descriptor in a message to B]
5. B→C: withdraw-gift(gift-id, signed-proof)     [via bootstrap at C, in B↔C session]
6. C→B: the cap X (as desc:import-object)
```

#### State Variables

```
VARIABLES
  gift_table,     \* Map: (GiftId, DepositorSession) → GiftRecord
  sessions        \* Map: SessionId → SessionRecord (with pubkeys)

GiftRecord == [
  cap_position : ExportPos,       \* position of the deposited capability
  depositor_session : SessionId,  \* which session deposited it
  recipient_key : [32]u8,         \* expected recipient's session pubkey
  state : {"deposited", "withdrawn", "expired"}
]
```

#### Initial State

```
Init ==
  /\ gift_table = {}
  /\ sessions = { ... }   \* populated by handshake
```

#### Transitions

**T6: DepositGift(session_id, gift_id, recipient_key, cap_position)**
```
Pre:  sessions[session_id].phase = "established"
      /\ (gift_id, session_id) ∉ dom(gift_table)
Post:
  gift_table' = gift_table ∪
    { (gift_id, session_id) ↦
        [cap_position: cap_position, depositor_session: session_id,
         recipient_key: recipient_key, state: "deposited"] }
```

**T7: WithdrawGift(claiming_session_id, gift_id, depositor_session_id, signed_proof)**
```
Pre:  (gift_id, depositor_session_id) ∈ dom(gift_table)
      /\ gift_table[(gift_id, depositor_session_id)].state = "deposited"
      /\ sessions[claiming_session_id].phase = "established"
      /\ verify_signature(signed_proof,
           sessions[claiming_session_id].peer_pubkey,
           gift_table[(gift_id, depositor_session_id)].recipient_key)
Post:
  \* Mark gift as withdrawn
  gift_table' = [gift_table EXCEPT
    ![(gift_id, depositor_session_id)].state = "withdrawn"]
  \* Return the capability to the claiming session
  \* (send op:fulfill with desc:import-object of cap_position)
```

**T8: SessionClose(session_id)**
```
Post:
  \* Expire all gifts deposited by this session
  \* (the depositor's references are no longer valid)
  ∀ (gid, sid) ∈ dom(gift_table) where sid = session_id:
    gift_table' = [gift_table EXCEPT ![(gid, sid)].state = "expired"]
  \* Also expire gifts whose recipient_key matches this session's peer pubkey
  \* if the receiver's session drops before withdrawal — debatable, see §3.6
```

### 3.3 Safety Properties

**S7 (Gift uniqueness)**: No two deposits with the same `(gift_id, session_id)`.
If a gifter tries to deposit twice with the same gift-id in the same session,
reject with an error.

**S8 (Single withdrawal)**: A gift can be withdrawn exactly once. After withdrawal,
the gift entry transitions to "withdrawn" and further withdrawal attempts fail.
```
∀ g ∈ GiftRecord: g.state transitions are:
  deposited → withdrawn    (exactly once)
  deposited → expired      (session cleanup)
  withdrawn → (terminal)
  expired → (terminal)
```

**S9 (Recipient authentication)**: Withdrawal succeeds only if the claiming
session's peer pubkey matches the `recipient_key` in the gift record, verified
via the signed proof in `desc:handoff-receive`. This prevents unauthorized
third parties from stealing gifts.

**S10 (No capability leak on failed withdrawal)**: If signature verification
fails or the gift is expired, no `desc:import-object` is sent.

### 3.4 Liveness Properties

**L4 (Deposited gift eventually redeemable)**: If A deposits a gift for B, and
B connects to C and presents valid credentials, B eventually receives the
capability. (Assuming the A↔C session stays alive long enough — see §3.6.)

**L5 (Gift table bounded)**: Gifts that are expired (depositor session closed)
must be cleaned up. The gift table must not grow unboundedly.

### 3.5 Ordering Concerns and Happens-Before

The critical ordering constraint is:

```
deposit(gift, A↔C) →hb withdraw(gift, B↔C)
```

This is **not guaranteed by message ordering** because the deposit and withdrawal
happen on *different sessions* (A↔C and B↔C). The ordering is ensured by the
*application-level protocol*:

1. A deposits the gift on A↔C (message m1).
2. A sends `desc:handoff-give` to B on A↔B (message m2).
3. B receives m2, connects to C, sends `desc:handoff-receive` (message m3).

The happens-before chain is: m1 →hb m2 (A sends m1 before m2, and FIFO on A↔C
means C processes m1 before anything triggered by m2). But m3 is on a different
session (B↔C). The guarantee relies on:

- A sends m1 (deposit) before m2 (give descriptor to B).
- B cannot send m3 before receiving m2.
- Therefore m1 is sent before m3.
- But **C might not have processed m1 when m3 arrives** if sessions A↔C and B↔C
  are processed concurrently.

**In single-threaded zig-syrup**: Messages from different sessions are interleaved
in the event loop. If C's event loop processes B↔C's withdraw before A↔C's deposit,
the withdrawal will fail (gift not found).

**Mitigation**: The implementation should return a "gift not yet deposited" error
that allows B to retry. Or, implement a **waiting withdraw** that queues the
withdrawal request and completes it when the deposit arrives.

**Lamport's recommendation**: The simplest correct approach is to **fail fast and
let the application retry**. Building a waiting mechanism introduces complexity
and subtle liveness bugs (what if the deposit never arrives?). The retry approach
makes the happens-before explicit in the application protocol.

### 3.6 Fault Tolerance

- **Depositor session (A↔C) drops before withdrawal**: The gift's deposited capability
  may no longer be valid (A's references are GC'd). Options:
  1. **Expire the gift immediately**: Simple, correct, but B's withdrawal fails.
     B would need to re-initiate the handoff (which it can't, since A introduced them).
  2. **Keep the gift alive with a strong reference**: The gift table holds a strong
     reference to the cap, preventing GC. This is the Goblins approach.
  
  **Recommendation**: Option 2 — the gift table `incref`s the export position on
  deposit, and `decref`s on withdrawal or expiry. This matches Goblins.

- **Receiver session (B↔C) drops before withdrawal**: No action needed. The gift
  remains deposited. B can reconnect and retry.

- **Exporter (C) restarts**: All gifts are lost (in-memory table). This is acceptable
  for a non-persistent vat. Persistent vats would need to serialize the gift table.

- **Gift-id collision**: Gift-ids are 32-byte random. Collision probability is
  negligible (2^{-128} for birthday). The `(gift_id, session_id)` key makes
  cross-session collision impossible.

### 3.7 Implementation Guidance

**Files to modify**:

1. **`src/ocapn_bootstrap.zig`** — Add `GiftTable`:
   ```zig
   pub const GiftEntry = struct {
       gift_id: [GIFT_ID_LEN]u8,
       depositor_session: [32]u8,  // depositor's session pubkey (session identity)
       recipient_key: [32]u8,       // expected recipient's session pubkey
       cap_position: ExportPos,     // position of the deposited capability
       state: enum { deposited, withdrawn, expired },
   };

   pub const GiftTable = struct {
       entries: std.ArrayListUnmanaged(GiftEntry),

       pub fn init() GiftTable { ... }
       pub fn deinit(self: *GiftTable, allocator: Allocator) void { ... }

       pub fn deposit(self: *GiftTable, allocator: Allocator,
                      gift_id: [GIFT_ID_LEN]u8, depositor_session: [32]u8,
                      recipient_key: [32]u8, cap_position: ExportPos) !void { ... }

       pub fn withdraw(self: *GiftTable, gift_id: [GIFT_ID_LEN]u8,
                       depositor_session: [32]u8) ?*GiftEntry { ... }

       pub fn expireBySession(self: *GiftTable, session_pubkey: [32]u8) void { ... }
   };
   ```

2. **`src/ocapn_vat.zig`** — Add `gift_table: bootstrap.GiftTable` field to `Vat`.

3. **`src/ocapn_vat.zig`** — Extend `serveBootstrapFetch` → `serveBootstrapMethod`:
   ```zig
   pub fn serveBootstrap(self: *Vat, op: anytype) !BootstrapResult {
       if (op.target != bootstrap.BOOTSTRAP_POS) return error.NotBootstrapTarget;
       if (std.mem.eql(u8, op.method, "fetch")) {
           return self.serveBootstrapFetch(op);
       } else if (std.mem.eql(u8, op.method, "deposit-gift")) {
           return self.serveDepositGift(op);
       } else if (std.mem.eql(u8, op.method, "withdraw-gift")) {
           return self.serveWithdrawGift(op);
       }
       return error.UnknownBootstrapMethod;
   }
   ```

4. **`src/ocapn_vat.zig`** — Implement `serveDepositGift`:
   - Extract `gift_id` (bytestring), `recipient_key` (bytestring), and
     the capability position from `op.args`.
   - Call `self.gift_table.deposit(...)`.
   - `self.exports.incref(cap_position)` — strong reference prevents GC.
   - Fulfill the answer with a success indicator.

5. **`src/ocapn_vat.zig`** — Implement `serveWithdrawGift`:
   - Extract `gift_id` and `depositor_session` identifier from `op.args`.
   - Verify the withdrawal is authorized: the claiming session's `peer_pubkey`
     must match the `recipient_key` in the gift entry.
   - The `desc:handoff-receive` from B contains the signed envelope. Verify it
     using `ocapn_handoff.verifyGive`.
   - On success: mark gift as withdrawn, fulfill the answer with
     `<desc:import-object cap_position>`.
   - On failure: break the answer with reason.

6. **`src/ocapn_vat.zig`** — In `deinit` / session-close path:
   Call `self.gift_table.expireBySession(peer_pubkey)` and
   `self.exports.decref(...)` for each expired gift's `cap_position`.

---

## Summary: Implementation Order

From Lamport's perspective, the implementation order is dictated by the **dependency
graph of safety properties**:

1. **Gap 2 first** (`desc:import-promise`): Smallest change, largest unblock. It's
   a pure parsing extension — add `readResolverDesc`, widen the `IncomingOp.deliver`
   struct, and the existing fulfillment path works. Zero new state, zero new
   invariants. **Estimated: ~30 lines changed.**

2. **Gap 1 second** (`op:listen`): Requires new state (`ListenerTable`) and new
   notification logic, but the state machine is self-contained within a single
   session. The safety invariants (S1-S4) are local. **Estimated: ~150 lines new.**

3. **Gap 3 last** (`deposit-gift`/`withdraw-gift`): Requires cross-session state
   (the gift table is shared), new crypto verification paths, and the most complex
   fault tolerance considerations. However, it builds on Gap 2's descriptor handling
   and Gap 1's notification infrastructure. **Estimated: ~250 lines new.**

Each gap should be implemented, tested, and verified against its safety properties
before moving to the next. Write the test *first* — it is the specification made
executable.

> "If you're thinking without writing, you only think you're thinking."
> — L. Lamport
