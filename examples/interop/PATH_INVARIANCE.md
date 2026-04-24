# PATH-INVARIANCE

69 commutative diagrams for sending the **Color of Greatest Trickery** (CGT, mid-grey `0.5/0.5/0.5`) from Zig ⇄ Guile / Racket / itself / void.

## Current Environment Status (2026-04-18)

- **Square D**: passing in the current Flox environment.
  - `flox activate -d /Users/bob/i/zig-syrup -- bb examples/interop/run_path_invariance.bb local`
- **Square A**: passing in the current Flox environment.
  - the runner now discovers candidate Guile site directories from the active Flox environment instead of pinning a single Nix store hash
  - in the current environment, the discovered site is `/Users/bob/i/.flox/run/aarch64-darwin.i.dev/share/guile/site/3.0`
  - that site exposes both `(goblins)` and Goblins' bundled `(goblins contrib syrup)` module
  - `flox activate -d /Users/bob/i/zig-syrup -- bb examples/interop/run_path_invariance.bb guile`
- **Square B**: environment-gated.
  - `racket` is not installed in the current Flox environment
- **Harness / OCapN surface**:
  - `flox activate -d /Users/bob/i/zig-syrup -- zig build path-invariance` passes
  - `flox activate -d /Users/bob/i/zig-syrup -- zig build ocapn-server` passes

The Babashka runner now reports these environment boundaries explicitly and discovers Guile site directories dynamically instead of failing with opaque module errors or stale store paths.

## Legend (morphism alphabet, maximally disentangled)

| sym | name | type |
|-----|------|------|
| `e` | encodeColor | RGB → Value |
| `d` | decodeColor | Value → RGB |
| `↦` | toBytes / encode | Value → Bytes (canonical) |
| `↤` | fromBytes / decode | Bytes → Value |
| `σ` | Syrup parser | any runtime, label `gay:color` |
| `Z` | zig vat | the `path_invariance` binary |
| `G` | guile peer | `guile_echo.scm` |
| `R` | racket peer | `racket_echo.rkt` |
| `H` | handoff vat | 3-vat hop, exporter C |
| `W` | witnessing | RGB → Wyhash → splitmix → RGB′ |
| `φ` | ed25519 sig | sender, signed bytes |
| `ψ` | ed25519 verify | receiver |
| `⊗` | parallel pipe |  |
| `⊕` | GF(3) trit add | effability accumulator |
| `↻` | identity loop | zero-copy, same vat |
| `∅` | void / abort |  |

## Square D — local oracle (in-process; Square A/B mimic this)

```
1.   RGB ─e→ Value ↦ Bytes ↤ Value ─d→ RGB        identity ↻
     └─────────────────────W─────────────────────┘

2.   CGT ─e→ V ↦ B ─σ→ V′ ─d→ CGT′                CGT = CGT′  ✓
           ↺                ↻
     canonical(B) = canonical(toBytes(e(d(σ(B)))))

3.   ┌── e ──┐        ┌── d ──┐
     │       ↓        ↓       │
     RGB   Value ↦ Bytes ↤ Value   RGB
                                 \──↻──/
```

## Square A — Zig ⇄ Guile  (canonical-form path invariance, no CapTP)

```
4.   Z[CGT] ─e ↦→ B ──pipe──▶ G[σ] ─d, e, ↦→ B′ ──pipe──▶ Z[verify]
     require: B == B′   (byte identity)

5.       ┌────── B ──────┐
     Z   │               │   G
         ▼               ▲
         σ_zig ──────── σ_guile        commute: σ_zig ∘ ↤ = σ_guile ∘ ↤

6.   B(CGT) ──G─→ B′       commute square ⟹ canonical Syrup is unique
     ↑           ↓
     ↤           ↤
     V          V′         d ∘ V = d ∘ V′ = CGT

7.   {CGT,e₁,…,e₈,w₁..w₆₀}  ↦ ⊗ ↦ G[echo] ↦  same multiset
```

## Square B — Zig ⇄ Racket  (Racket goblins/syrup is the σ_R)

```
8.   Z[CGT] ─↦→ B ──▶ R[σ_R, e_R, ↦] ──▶ B′ ──▶ Z[verify]   B == B′

9.        e_Z ─── ↦_Z ─── B ─── ↤_R ─── e_R     ╲
           ╲      pentagon coherence            ╲   commute
            ╲    of canonical Syrup            ╲ ⟹ ↦_Z = ↦_R
             ↘ ──────────  σ  ──────────── ↘

10.  draft-spec(ocapn-peer) ≠ live-Racket(ocapn-node)
     live > draft ⟹ Z encoder uses 'ocapn-node' (resolved 2026-04-18)
```

## Square C — 3-vat handoff  (gifter A → receiver B → exporter C)

```
11.  A[CGT] ──φ→ B ──ψ→ B[CGT'] ──φ→ H ──ψ→ H[CGT'']   require all =CGT

12.  handoff-give(A→B) ≜ {giver=A_loc, receiver_key, gift_id, exporter=H_loc}
     handoff-receive(B→H) ≜ {receiving_session, receiver_key, gift_id,
                             signed_give_envelope}

13.       A ──── give ────▶ B
          │                  │
        export             receive
          ▼                  ▼
          H ◀──── deliver ── H'      witness: A_kp == ψ(envelope, A_loc)

14.  3 distinct sessions  ⟹ 3 sig-envelopes  ⟹ 3 ed25519 verifications
     require: ⊕ trits over {-1,0,+1} for {give,receive,deliver} = 0 (GF3)
```

## Diagrams 15..69 — tiled collage (one per line, maximally disentangled)

```
15.  CGT ─e→ ●─↦→ ▣ ─σ_Z→ ●─d→ CGT                     same vat, ↻
16.  CGT ─e→ ●─↦→ ▣ ─σ_G→ ●─d→ CGT                     Square A leg
17.  CGT ─e→ ●─↦→ ▣ ─σ_R→ ●─d→ CGT                     Square B leg
18.  CGT ─e→ ●─↦→ ▣ ─σ_Z→ ●─e→ ▣′                       require ▣==▣′
19.  CGT ─e→ ●─↦→ ▣ ─σ_G→ ●─e→ ▣′                       require ▣==▣′
20.  CGT ─e→ ●─↦→ ▣ ─σ_R→ ●─e→ ▣′                       require ▣==▣′
21.  ▣ ─G→ ▣′ ─R→ ▣″ ─Z→ ▣‴                             require ▣==▣‴ (3-hop)
22.  ▣ ─R→ ▣′ ─G→ ▣″ ─Z→ ▣‴                             require ▣==▣‴ (commute)
23.  ▣ ─G→ ▣′ ; ▣ ─R→ ▣″ ⟹ ▣′ == ▣″                     parallel-meet
24.  ▣(CGT) → ▣′(CGT) ⊗ ▣″(CGT)  zero-copy if mmap      parallel-broadcast
25.  Bᵢ for i∈[0..69] : ⨂ᵢ Bᵢ ─↦→ shared-buf ↦ G ↦ Z   bulk corpus
26.  Bᵢ ↤ B_i+1 (chain): ⊕ᵢ trit(Bᵢ) ≡ 0 mod 3         GF(3) closure
27.  φ(B) → φ̂ → ψ(φ̂)=B                                 sig-envelope round-trip
28.   φ_A(B_CGT) ──┐
                   ▼
                 ψ_B  ✓ ⟹ B_CGT continues
29.  φ_A ⊗ φ_C    ψ_B  → handoff cosigner pattern (3-of-3)
30.  Z[B] →∅      ⟹ no transmission, vacuously commutes
31.  Z[B] ─W→ B′ ─W→ B″ … 7 iters; trit-sum ∈ {0,1,2}  witnessing
32.  Z[CGT] ─W→ ?    starting point: trit(CGT)=0       trickster fixpoint
33.  Z[(0,0,0)] ─W→ … always trit=−1                   absolute black sink
34.  Z[(1,1,1)] ─W→ … always trit=+1                   absolute white source
35.  e_Z(CGT) = e_G(CGT) = e_R(CGT)  bytewise          ⟹ canonical agreement
36.  e(c)≠e(c′) for c≠c′                               injective on RGB
37.   <11'gay:color>  3 floats, IEEE754                Syrup wire shape
38.  Z ─↦ ▣ ─pipe→ G ─↦ ▣′ ─pipe→ Z ⟹ ▣ == ▣′         A round-trip
39.  Z ─↦ ▣ ─pipe→ R ─↦ ▣′ ─pipe→ Z ⟹ ▣ == ▣′         B round-trip
40.  G ─↦ ▣ ─pipe→ R ─↦ ▣′ ─pipe→ G ⟹ ▣ == ▣′         peer-to-peer
41.  R ─↦ ▣ ─pipe→ G ─↦ ▣′ ─pipe→ R ⟹ ▣ == ▣′         peer-to-peer (rev)
42.  Z ─↦ ▣ ─pipe→ G ─↦ ▣′ ─pipe→ R ─↦ ▣″ ─pipe→ Z   triangle
43.  Z ─↦ ▣ ─pipe→ R ─↦ ▣′ ─pipe→ G ─↦ ▣″ ─pipe→ Z   triangle (rev)
44.  Square A + Square B + Square D ⟹ 9-cell pasted square
45.  zero-copy: writev(B) on Z, readv(B) on G ⟹ no memcpy
46.  ↻ identity: loop CGT in-vat 1B times, ⟹ no drift  determinism
47.  Float bit-pattern preserved across e/↦/↤/d (no normalisation)
48.  ┌───────┐    ┌───────┐    ┌───────┐
     │ Z[B]  │ ─▶ │ G[B'] │ ─▶ │ R[B"] │ ─▶ Z[B]   require B == B'==B"
     └───────┘    └───────┘    └───────┘
49.   B ⊗ B = B (idempotent broadcast under canonical Syrup)
50.  ┌─B─┐  ┌─B─┐  ┌─B─┐
     │ Z │═▶│ G │═▶│ R │  bidirectional: ⟸⟹⟸⟹  CGT survives
     └───┘  └───┘  └───┘
51.  ⨁ trits over corpus = 0 mod 3 ⟺ corpus is balanced
52.  Σ trits over witnessing chain on CGT  ≡ 0 mod 3   conjecture
53.  Z(CGT) ──┐
              ▼  if all peers commute, we have a sheaf
            G⊕R   over {Z,G,R} with stalk = CGT
54.  cocycle:  σ_Z⁻¹∘σ_G  =  σ_Z⁻¹∘σ_R  (same up to canonical normalisation)
55.  H¹(peer-network, canonical-form) = 0   ⟺   path-invariance holds
56.  ⟦CGT⟧ = ⟦CGT⟧ in every peer's parser semantics    universal
57.  CGT  ─┬─ Z  ─┐
            ├─ G  ├─→  same B   (sheafification)
            └─ R  ─┘
58.  Square D fails ⟹ Square A and B cannot succeed   (necessity)
59.  Square D succeeds ∧ peer round-trip equal ⟹ Square A, B   (sufficiency)
60.  ed25519 envelope:  φ(B) = sig(seed_kp, "session-key|" ++ B)
61.  re-encode commutes with ed25519:  φ(↦(d(↤(B)))) = φ(B)   ⟺   determinism
62.  3-vat:  φ_A(B_give) ⟹ ψ_C(B_give) ✓   ed25519 transitive
63.  swiss-arg ≜ {handle-id, swiss-num}  shape  (TBD: Racket form)
64.  if swiss-arg matches Racket: full handoff invariance achievable
65.  if not: Square C remains pending (gap row)
66.  Witness corpus: 70 colors  ⊃ {CGT} ∪ {0,1}³ ∪ splitmix(69420)[0..60)
67.  Bulk:  Z ↦ ⨂ corpus ─pipe→ G ↦ ⨂ corpus' ⟹ multiset equality
68.  Order-preserving:  list-fold equality   (not just multiset)
69.  ∅ ──→ CGT  ←──  ∅      universe-from-void via canonical Syrup-of-grey
```

## Properties asserted by the harness

| id  | property | formula | square |
|-----|----------|---------|--------|
| P1  | Determinism        | `e ∘ d ∘ ↤ ∘ ↦ ∘ e  ≡  e`            | D′ |
| P2  | Round-trip         | `d ∘ ↤ ∘ ↦ ∘ e      ≡  id_RGB`       | D  |
| P3  | Cross-σ agreement  | `↦ ∘ e` commutes across {Z, G, R}    | A, B |
| P4  | Bulk preservation  | multiset(corpus) preserved any pipe  | A, B |
| P5  | Order preservation | list(corpus) preserved any pipe      | A, B |
| P6  | GF(3) closure      | `⊕ trit(c)` over corpus ≡ 0 mod 3   | effability |
| P7  | Identity on void   | `∅ ⨯ Z = Z`                          | vacuous |

- **LOCAL** — P1, P2, P5, P6, P7 — `zig build test` (Square D, D′)
- **PEER**  — P3, P4 — `bb examples/interop/run_path_invariance.bb {racket|guile}`
