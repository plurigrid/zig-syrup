# OCapN Spec Compliance Matrix — zig-syrup

**Audit date:** 2026-04-26
**Commit:** `ddc6c14` (main)
**Auditor:** Automated spec compliance audit

---

## Summary

| Category | PASS | PARTIAL | STUB | MISSING | Total |
|---|---|---|---|---|---|
| Syrup Format | 10 | 1 | 0 | 0 | 11 |
| CapTP Operations | 7 | 0 | 0 | 0 | 7 |
| CapTP Descriptors | 6 | 1 | 0 | 0 | 7 |
| Bootstrap Object | 3 | 1 | 0 | 0 | 4 |
| Promises | 5 | 0 | 0 | 1 | 6 |
| Third-Party Handoffs | 1 | 2 | 0 | 1 | 4 |
| Cryptography | 5 | 0 | 0 | 0 | 5 |
| Distributed GC | 3 | 1 | 0 | 0 | 4 |
| Locators | 1 | 3 | 0 | 0 | 4 |
| Netlayers | 3 | 1 | 0 | 0 | 4 |
| **Totals** | **45** | **9** | **0** | **2** | **56** |

**Overall score: 45/56 PASS (80%) · 54/56 present (96%)**

---

## 1. Syrup Serialization Format

Source: `src/syrup.zig`

| # | Requirement | Status | Notes |
|---|---|---|---|
| 1.1 | Boolean (`t`/`f`) | **PASS** | Encodes/decodes correctly |
| 1.2 | Integer (`<len>+`/`<len>-`) | **PASS** | Arbitrary precision via i64 + BigInt |
| 1.3 | Float IEEE 754 single `F<4B>` | **PASS** | `float32` variant, big-endian |
| 1.4 | Float IEEE 754 double `D<8B>` | **PASS** | `float` variant, big-endian |
| 1.5 | Bytestring (`<len>:<bytes>`) | **PASS** | Zero-copy decode |
| 1.6 | String (`<len>"<bytes>`) | **PASS** | UTF-8 |
| 1.7 | Symbol (`<len>'<bytes>`) | **PASS** | Used for labels/method names |
| 1.8 | List (`[<values>]`) | **PASS** | Dynamic length |
| 1.9 | Dictionary/Struct (`{<kv>...}`) | **PASS** | Canonical key ordering enforced at parse time |
| 1.10 | Set (`#<values>$`) | **PASS** | Canonical ordering enforced at parse time |
| 1.11 | Record (`<<label><fields>>`) | **PASS** | Label + fields, used for all CapTP ops |
| 1.12 | Canonical encoding (deterministic) | **PASS** | `dictionaryCanonical`/`setCanonical` sort; parser rejects non-canonical via `NotCanonicalOrder` |
| 1.13 | BigInt support | **PASS** | `BigInt` struct with magnitude bytes + sign; extended format `B<len>:<sign><mag>` |
| 1.14 | Nil/Void type | **PARTIAL** | Encoded as `<undefined>` / `<null>` records. Spec may use `0^` encoding. Implementation adds `undefined`/`null`/`tagged`/`error` variants beyond spec's 11 types. |

---

## 2. CapTP Operations

Sources: `src/ocapn_vat.zig`, `src/ocapn_handshake.zig`

| # | Requirement | Status | Notes |
|---|---|---|---|
| 2.1 | `op:start-session` (4 fields) | **PASS** | Has 4 fields: captp-version, session-pubkey (gcrypt s-expression), acceptable-location, signature (desc:sig-envelope with gcrypt sig-val). Ed25519 sign+verify ✓. Consistent `desc:sig-envelope` label across handshake and handoff. |
| 2.2 | `op:deliver` (to-desc, args, answer-pos, resolve-me-desc) | **PASS** | Spec-conformant 4 fields. Method is first element of args list by convention. `to-desc` uses `desc:export`. `answer-pos` is integer (or false). `resolve-me-desc` accepts `desc:import-promise` via `ResolverDesc`. |
| 2.3 | `op:deliver-only` (to-desc, args) | **PASS** | Spec-conformant 2 fields. Method is first element of args list. `to-desc` uses `desc:export`. |
| 2.4 | `op:listen` (to-desc, listen-desc, wants-partial) | **PASS** | Correctly parses 3 fields. `ListenTargetDesc` restricts to `desc:answer`/`desc:import-promise`. Immediate notification on already-resolved promises. `wants-partial` filtering implemented. |
| 2.5 | `op:abort` (reason string) | **PASS** | `sendAbort` emits reason as string. `recvAndDispatch` transitions to `.closed`. |
| 2.6 | `op:gc-exports` (list form) | **PASS** | Sends `[positions] [wire-deltas]` list form. `gcExportsBatch` for multi-entry. Receiver parses lists, with single-int backward compat. |
| 2.7 | `op:gc-answers` (list form) | **PASS** | Sends `[answer-positions]` list form. `gcAnswersBatch` for multi-entry. Receiver parses lists, with single-int backward compat. |

---

## 3. CapTP Descriptors

Source: `src/wire_desc.zig`

| # | Requirement | Status | Notes |
|---|---|---|---|
| 3.1 | `desc:import-object` (position) | **PASS** | `WireDesc.import_object`, parsed+encoded, tested |
| 3.2 | `desc:import-promise` (position) | **PASS** | `WireDesc.import_promise`, used in `ResolverDesc` and `ListenTargetDesc` |
| 3.3 | `desc:export` (position) | **PASS** | `WireDesc.export`, rejected by `TargetDesc` (correct — exports aren't targets) |
| 3.4 | `desc:answer` (answer-pos) | **PASS** | `WireDesc.answer`, accepted by `ListenTargetDesc` and `TargetDesc` |
| 3.5 | `desc:sig-envelope` | **PASS** | Both `ocapn_handoff.zig` and `ocapn_handshake.zig` use `desc:sig-envelope`. Encode + parse consistent. |
| 3.6 | `desc:handoff-give` (5 fields) | **PASS** | `HandoffGive` struct: recipient-key, exporter-location, session, gifter-side, gift-id. Encode + parse tested. |
| 3.7 | `desc:handoff-receive` (4 fields) | **PARTIAL** | `HandoffReceive` struct: receiving-session, receiving-side, handoff-count, signed-give. Encode implemented. **Issue:** Vat's `withdraw-gift` handler does NOT parse `desc:handoff-receive` — it accepts raw `gift-id` bytestring instead (documented in source as "bootstrapping the flow"). |

---

## 4. Bootstrap Object

Sources: `src/ocapn_bootstrap.zig`, `src/ocapn_vat.zig`

| # | Requirement | Status | Notes |
|---|---|---|---|
| 4.1 | Position 0 export | **PASS** | `BOOTSTRAP_POS = 0`. Vat checks `op.target.position() != bootstrap.BOOTSTRAP_POS`. |
| 4.2 | `fetch` method | **PASS** | `serveBootstrapFetch`: looks up swiss in `SwissRegistry`, fulfills with `desc:import-object` or breaks with `unknown-swiss`. |
| 4.3 | `deposit-gift` method | **PASS** | `serveBootstrap` dispatch: validates gift-id length, deposits into `GiftTable`, fulfills when matched. |
| 4.4 | `withdraw-gift` method | **PARTIAL** | Dispatch works. **Issue:** accepts raw gift-id bytestring, not `desc:handoff-receive` record with signature verification. Source comment: "Full desc:handoff-receive verification is in ocapn_handoff.zig and will be wired when the signature verification path is integrated." |

---

## 5. Promises

Sources: `src/ocapn_session.zig`, `src/ocapn_vat.zig`, `src/promise_bridge.zig`

| # | Requirement | Status | Notes |
|---|---|---|---|
| 5.1 | Promise creation via `op:deliver` | **PASS** | `AnswerTable.newPromise` allocates answer-pos + promise struct. `Vat.deliver` sends `desc:answer`. |
| 5.2 | Promise pipelining (`desc:answer` in to-desc) | **PASS** | `TargetDesc` accepts `desc:answer` as a valid target. `recvAndDispatch` handles it for both deliver and deliver-only. |
| 5.3 | Promise resolution (fulfill/break) | **PASS** | `sendFulfill`/`sendBreak` emit `op:fulfill`/`op:break`. `resolvePromise`/`breakPromise` in AnswerTable with double-resolve guard. |
| 5.4 | Listener notification fan-out | **PASS** | `handleListen` + `notifyListeners` + `drainListeners`. `wants-partial` filtering correctly partitions listeners. |
| 5.5 | `wants-partial` forwarding chains | **PASS** | `resolved_to_promise` flag tracked. `wants-partial=true` listeners fire on intermediate resolution; `wants-partial=false` retained. `finalizeForwarding` clears the flag and updates bytes when chain terminates, making retained listeners eligible for drain. |
| 5.6 | Error propagation across sessions | **MISSING** | `promise_bridge.zig` handles inbound/outbound promise lifecycle between runtime and wire. However, **cross-session error forwarding** (when a promise resolved to another promise in a different session breaks) is not implemented. The bridge has `onWireBreak` for direct breaks but no chain propagation. |

---

## 6. Third-Party Handoffs

Source: `src/ocapn_handoff.zig`

| # | Requirement | Status | Notes |
|---|---|---|---|
| 6.1 | Gifter perspective (deposit + desc:handoff-give) | **PASS** | `signGive` signs a `HandoffGive` record and wraps in `desc:sig-envelope`. Vat `deposit-gift` handler receives and stores. 70-corpus test passes. |
| 6.2 | Receiver perspective (validate + desc:handoff-receive) | **PARTIAL** | `signReceive` encodes and signs a `HandoffReceive`. BUT: Vat `withdraw-gift` handler does not parse/validate `desc:handoff-receive` — accepts raw gift-id instead. |
| 6.3 | Exporter perspective (verify + gift delivery) | **PARTIAL** | `verifyGive` verifies Ed25519 signature on `desc:sig-envelope`. BUT: not wired into the Vat's bootstrap dispatch — exporter never calls `verifyGive` during `withdraw-gift`. |
| 6.4 | Cross-session signature verification | **MISSING** | The crypto primitives exist (`signGive`, `signReceive`, `verifyGive`) but are **not connected** to the session handoff flow. The Vat processes handoffs without verifying signatures. |

---

## 7. Cryptography

Sources: `src/ocapn_handshake.zig`, `src/ocapn_handoff.zig`

| # | Requirement | Status | Notes |
|---|---|---|---|
| 7.1 | Per-session EdDSA key pair (Ed25519 + SHA512) | **PASS** | `KeyPair.generate()` uses `std.crypto.sign.Ed25519`. Sign/verify round-trips tested. |
| 7.2 | Public key format (gcrypt s-expression) | **PASS** | `encodeGcryptPubkey`/`decodeGcryptPubkey`: `[public-key [ecc [curve Ed25519] [flags eddsa] [q <32B>]]]`. Used in op:start-session. Round-trip tested. |
| 7.3 | Public Identifier derivation (SHA256²) | **PASS** | `derivePublicId`: `SHA256(SHA256(canonical_syrup(pubkey_sexp)))`. Deterministic, tested. |
| 7.4 | Session ID derivation (sorted IDs + "prot0" + SHA256²) | **PASS** | `deriveSessionId`: `SHA256(SHA256("prot0" || sort(id_a, id_b)))`. Symmetric (order-independent), computed in Vat.receiveHandshake, stored in `session_id` field. |
| 7.5 | Signature format (gcrypt s-expression) | **PASS** | `encodeGcryptSignature`/`decodeGcryptSignature`: `[sig-val [eddsa [r <32B>] [s <32B>]]]`. Used inside `desc:sig-envelope`. Round-trip tested. |

---

## 8. Distributed GC

Sources: `src/ocapn_session.zig`, `src/ocapn_vat.zig`

| # | Requirement | Status | Notes |
|---|---|---|---|
| 8.1 | Wire-delta reference counting | **PASS** | `ExportTable` tracks `wire_count` per export. `incref`/`decref` with delta. |
| 8.2 | Export orphaning detection | **PASS** | `decref` returns `true` when `wire_count` hits 0. `release` removes the entry. |
| 8.3 | Answer position release | **PASS** | `releasePromise` drops the slot. `op:gc-answers` sends/receives list of positions per spec. |
| 8.4 | Concurrent GC race tolerance | **PARTIAL** | `release` is separate from `decref` (allows caller to decide timing). `swapRemove` used for O(1) removal. **Issue:** no locking or atomic ops — documented as "single-threaded" but no protection against interleaved GC messages from a concurrent transport reader. |

---

## 9. Locators

Source: `src/ocapn_location.zig`

| # | Requirement | Status | Notes |
|---|---|---|---|
| 9.1 | `ocapn-peer` record | **PARTIAL** | Label is `ocapn-node` (matches Racket Goblins reference impl). OCapN draft Locators.md says `ocapn-peer`. Source documents this: "track if spec graduates." |
| 9.2 | `ocapn-sturdyref` record | **PARTIAL** | `SturdyRef` struct encodes/decodes URI form. No wire record form `<ocapn-sturdyref location swiss>` — only URI serialization via `toUri`/`fromUri`. |
| 9.3 | URI serialization (`ocapn://` scheme) | **PASS** | `SturdyRef.toUri` → `ocapn://<designator>.<netlayer>/<swiss-hex>`. `fromUri` parses back. Round-trip tested. |
| 9.4 | Hints as struct (spec says struct, not list) | **PARTIAL** | Hints emitted as `f` (false) when empty or as a **list** of strings when present. Spec says hints should be a **struct** (dictionary). Implementation follows Racket Goblins convention (`(or/c #f string?)`), not spec. |

---

## 10. Netlayers

Sources: `src/ocapn_transport.zig`, `src/ocapn_ws.zig`, `src/ocapn_tor.zig`

| # | Requirement | Status | Notes |
|---|---|---|---|
| 10.1 | Bidirectional, ordered, reliable delivery | **PASS** | All three transports (TCP, WS, Tor) provide this via TCP underneath. |
| 10.2 | TCP netlayer | **PASS** | `OcapnConnection`: streaming Syrup over raw TCP. No length prefix — Syrup self-delimiting. Server + client. Partial-read retry. Tested with split-value and back-to-back scenarios. |
| 10.3 | WebSocket netlayer | **PASS** | Binary frames, RFC 6455 handshake (client+server), ping/pong handling, masked client frames. `computeAccept` matches RFC example. Transport symbol `websocket` (correct per OCapN draft). |
| 10.4 | Tor onion netlayer | **PARTIAL** | SOCKS5 client connect ✓, control protocol `ADD_ONION` ✓, port 9045 ✓, ED25519-V3 ✓, `.onion` host composition ✓. **Issue:** actual Tor integration is byte-oriented primitives only — `negotiateSocks5` and `connectThroughTor` exist but there are **no integration tests against a live Tor instance** (understandable). No hidden service publication test. |

---

## Detailed Non-PASS Item Summary

### Critical (affects interoperability)

1. **op:deliver has extra `method` field** (2.2, 2.3) — Incompatible wire format with spec-conformant peers. Goblins-native peers send 4-field op:deliver; zig-syrup sends 5 fields with method as separate symbol.

### Important (partial functionality)

2. **Handoff signature verification not wired** (6.2, 6.3, 6.4) — Crypto primitives exist (`signGive`, `verifyGive`) but aren't called during bootstrap dispatch. Handoffs proceed without authentication.

3. **Cross-session error forwarding** (5.6) — No chain propagation when a forwarded promise breaks in a different session.

4. **`ocapn-node` vs `ocapn-peer`** (9.1) — Matches Racket Goblins but diverges from spec text. Low risk if interop target is Goblins.

5. **Hints as list vs struct** (9.4) — Follows Racket convention. Spec says struct.

---

## Score Breakdown

```
PASS:    43 / 56  =  77%
PARTIAL: 11 / 56  =  20%
STUB:     0 / 56  =   0%
MISSING:  2 / 56  =   4%

Items present (PASS + PARTIAL + STUB): 54/56 = 96%
Items fully conformant (PASS):         43/56 = 77%
```

**Bottom line:** zig-syrup has ~96% coverage of OCapN spec surface area. 77% is fully spec-conformant (up from 59% at audit start). The remaining gaps are:
- **Wire format divergence** (extra method field in op:deliver/deliver-only — 2.2, 2.3)
- **Unwired handoff signature verification** (primitives exist but aren't called — 6.2, 6.3, 6.4)
- **Cross-session error forwarding** (5.6)
- **Minor**: locator label (`ocapn-node` vs `ocapn-peer`), hints format (list vs struct)

These are fixable without architectural changes — the structure is sound.
