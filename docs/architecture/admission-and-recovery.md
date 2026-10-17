# Admission and recovery boundaries

These changes apply lessons from Jolt's constrained-execution repairs and
Golem's migration, cancellation and structural-permission work to zig-syrup.
They harden the existing runtime rather than adopt either project's protocol.

## Executable contracts

| Boundary | Admission before publication | Regression evidence |
| --- | --- | --- |
| Actor delivery | Retain the target grant in the mailbox and check revocation, expiry and selector at dispatch | Revoke after enqueue; vary delivery time around expiry; preserve unrelated delivery and actor state |
| Capability derivation | `wrap`, union and intersection reject distinct revokers instead of discarding a gate | Both operand orders reject; a shared gate remains revocable |
| Promise bridge | Reject duplicate IDs, reserve both indexes, then publish the promise and bindings | Unknown/settled/duplicate registration; allocation failure; missing wire state during release |
| Promise listeners | Prepare eligible/retained lists before replacing the original; reserve forwarding storage before clearing it | Allocation failures preserve listener interests and the previous forwarding value |
| Cell frame | Validate record shape, typed fields, dimensions, cursor, every cell/run, complete consumption and expansion budget | Malformed suffix changes no cells or damage; fused and explicit folds agree |
| Turn diagnostics | Append a complete record once; latch allocation failure | An omitted receipt is observable through `requireComplete()` and cannot be repaired by later records |

For cell frames the concrete hylomorphism is:

`ana: inspect record and packed cells -> admit: shape, ranges and budget -> cata: update front/back buffers and damage`

Both `snapshotFromSyrup` and `applyFromSyrup` use the same admission pass.
The optimized fold preserves cells outside the admitted local patch. Invalid
frames fail before mutation. Admission caps a frame at 1,048,576 expanded
cells and at the advertised grid's cell count. Dimensions must match the
receiving grid on the fused application path. Valid wire encodings are unchanged.
Lower-level typed `applyRemote` and raw `applyPacked` remain trusted in-process
helpers; untrusted network frames must enter through the admitted Syrup APIs.

## Authority and compatibility

Queued delivery now requires authority at dispatch as well as enqueue. A
rejected question becomes a broken promise; a rejected notification is consumed
without running the actor or incrementing its successful turn sequence.
Already completed turns are unaffected. `turn()` returns true for consumed
rejections so drivers keep draining; quiescence budgets count consumed messages.
Revoker owners must outlive queued deliveries, including after revocation.

`Revoker.wrap`, `Capability.unionWith` and `intersectWith` can now return
`IncompatibleRevokers`. `epochBackedCap` also returns an error union; callers
must use `try`. One capability cannot encode a conjunction of distinct gates.
Forwarders retain inner authority separately, but arbitrary membrane chains
still need an explicit policy for authority propagation after each relay.
This change does not certify those chains as transitively confined.

Bridge answer positions currently occupy one shared index. An inbound/outbound
position collision is rejected instead of overwriting a binding. Supporting
overlapping directional namespaces requires a separate protocol integration.
Do not reclaim a producer merely because one consumer stops awaiting its result;
listener GC, promise settlement and capability revocation are separate events.
The unmerged OCapN listen-mode proposal is not installed by this patch.

The runtime is single-threaded and assumes trusted local code: public Zig
structs and numeric IDs do not themselves provide cryptographic authority.
Syrup validation authenticates neither node identity nor source/generation
metadata. Transport/session authority must be checked independently.
`vat_replay.Log` records dispatch metadata, not payloads or checkpoints, and
cannot alone restore an actor or guarantee external-effect idempotency.

## SemanticSolitonReceipt diagnostic

| Field | Contract and evidence |
| --- | --- |
| State region | One actor mailbox/reply binding or one admitted grid patch |
| Distributed dynamics | Delayed delivery, duplicate registration, retry after allocation failure and malformed remote updates |
| Invariant | Revoked/expired grants cause no actor effect; bindings remain bijective; rejected patches preserve cells and damage; untouched patches remain unchanged |
| Perturbation budget | Deterministic delays 0, 1, 9, 10, 11 and 100 around expiry 10; registration allocation-failure points 0–7; one malformed frame at a time. These are tested schedules, not cluster churn bounds |
| Recovery criterion | Existing bindings/interests remain usable after rejected transitions; an admitted frame matches the explicit fold; permanent revocation never becomes renewed authority |
| Persistence horizon | In-memory object/session lifetime only; durable recovery and dispute retention are not established |

Bounded timing heterogeneity is tested for authority invariance. No result
establishes that jitter improves resilience. Compare homogeneous and bounded
heterogeneous retry/resource schedules before making that claim, and measure
maximum queue/RSS excursions, recovery delay and revocation lag rather than
steady-state averages alone. Evidence remains:
`[?] NeedDisorderProbeEvidence`, `[?] NeedDisorderRangeEvidence`,
`[?] NeedTransientRobustnessEvidence`.

Topology, capability and proof-graph edits require fresh `ana -> admit -> cata`
evidence before persistence is reassessed. Dynamic stabilization and semantic
homeostasis remain downstream of consensus, proof verification, identity,
authority and deterministic execution.

## Validation

Run `zig build test-cap-layer test-cell-sync` with Zig 0.17. The cell suite has
its own build step because it was previously absent from the default tests.
The default `zig build test` remains a separate integration check.
On the validation Linux host it compiles the changed paths but still fails
to compile bootstrap/handoff entropy helpers which use the pre-existing
macOS-only `std.c.arc4random_buf` fallback. That platform port is separate.
