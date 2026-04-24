# Φ_{p,q} : Poly × Poly → Poly — landing sketch

Entry #65 on the 69-constructions list. Lifts the propagator cell in `src/propagator.zig`
from a "state + merge" into an explicit `Poly`-coalgebra so Φ can act.

## Where this lands

| Piece                     | Proposed file                          | Notes                                                       |
|---------------------------|----------------------------------------|-------------------------------------------------------------|
| `Poly` type               | `src/poly.zig` (new)                   | comptime `positions: type`, `directions: fn(p) -> type`     |
| Composition `◁`           | `src/poly.zig`                         | `Compose(P, Q)` = Σ_{p : P.pos} Π_{d : P.dir(p)} Q          |
| Φ(p, q) = p ◁ (y + q)     | `src/poly.zig`                         | first candidate; verify unit + associator                   |
| Coalgebra side c_q        | `src/propagator.zig` (extend)          | `fn readout(cell: *Cell(T,m)) Directions(CellValue(T))`     |
| Example propagator-cell-  | `src/phi_poly_example.zig` (new)       | SDF `adder` + `multiplier` as c_q-algebras for small p      |
|   as-algebra              |                                        |                                                             |

## Composition recap

`Poly` is the category of polynomial functors on `Set` / comptime `type`:
- object: `{ pos : Type, dir : pos -> Type }`
- morphism `p → q`: `{ onPos : p.pos -> q.pos, onDir : forall pp, q.dir(onPos pp) -> p.dir(pp) }` (dir is contravariant)
- identity (`y`): `{ pos = unit; dir _ = unit }` — coyoneda
- `◁` associative with `y` as unit

## Φ(p, q) = p ◁ (y + q), candidate

```
pos(Φ)   = Σ_{pp : p.pos} ( (p.dir pp) -> (unit ⊎ q.pos) )
dir(pp, f)(pp, d) = case f d of
  Inl _   => unit            -- "stay at p"
  Inr qp  => q.dir qp        -- "step into q"
```

Check:
- Φ(p, y) ≅ p? If q ≡ y then unit ⊎ q.pos ≡ unit ⊎ unit; collapse the Inr branch to y's direction (unit). Up to iso, pos(Φ) = Σ_{pp} (p.dir pp -> 2), and dir picks either unit or unit — isomorphic to p.dir pp only when the map is constant Inl, so the iso is **not** automatic. **→ needs a stricter candidate, e.g. Φ(p, q) = p ◁ (y × q) or p ◁ q directly.**
- Likely correct form: **Φ(p, q) = p ◁ (y × q)** — "at every p-hole, add a q-output alongside the y-continuation." Verify this instead.

## Coalgebra side in zig-syrup terms

```zig
// Landed in src/propagator.zig on Cell(T, merge_fn):
//   readout() -> CellValue(T)                       -- the position
//   inject(direction) -> !CellValue(T)              -- advance by direction
//   Direction = union(enum) { read, write: T, contradict: {a,b} }
//
// Cell is a coalgebra c : Cell → q(Cell) where
//   q.positions  = CellValue(T)
//   q.directions = Direction
// i.e. each neighbor can read, write, or cause a contradiction.
```

`Cell(T, merge_fn)` in `src/propagator.zig:84` already exposes
- a `content: CellValue(T)` — the position
- neighbor-alert on change — the direction family

so it is a Coalg in disguise. Lifting it just means naming `positions/directions`
explicitly and threading them through a `Poly` value.

## Why

Turns SDF propagator cells into first-class `Poly`-coalgebras, which means any
Φ-generated composite is a well-typed network for free — including
Radul-Sussman's `adder`/`multiplier` propagators and the BCI `fnirs_processor`
→ `bci_receiver` chain.

## Lineage to originals

| Original source | How it appears in this implementation thread |
|-----------------|----------------------------------------------|
| `topos-polynomial-functors` | Supplies the categorical target (`Poly`, `◁`, `y`, representables) now reflected by `PolynomialShape`, `phi_p_q`, `representable_y`, and `triangleleft` in `src/propagator.zig`. |
| `sdf` | Supplies cell/propagator semantics and partial-information merge logic, already embodied by `CellValue`, lattice merge, and alert-based propagation in `src/propagator.zig`. |
| `zig-syrup-propagator-interleave` | Supplies the integration bridge layer that maps these structures into the ASI skill graph and cross-module wiring. |
| `2-monad` | Supplies the monad/comonad framing. Here it is made operational as the `η`/`ε` extraction+embedding cycle with explicit roundtrip tests. |
| `69-constructions` (#65) | This document is the running notebook for that construction slot and records the concrete landing path. |
| `worlding` / `world-memory-worlding` | Supplies world-state perspective: carrier cells are treated as positions with directional updates, and Φ witnesses quantify direction flow (`q_total - p_total`) and GF(3) residual. |
| `active-interleave` | Supplies operational exercise context: run-time lifting and residual checks can be replayed in active thread loops to validate behavior under live interaction. |

## Trail of Bits style hardening applied

- Arithmetic safety added to Φ witness computation:
  - checked `usize` accumulation for `p_total_directions` and `q_total_directions`
  - explicit `usize -> i64` boundary checks in `toI64Exact`
  - dedicated `error.ArithmeticOverflow` path
- Witness integrity gate:
  - `PhiWitness.isConsistent()` validates GF(3) residual coherence and carrier-count bounds before downstream use
- API hardening for equilibrium embedding:
  - narrowed `embed_equilibrium` / `extract_strategies` to `f32` cells so polymorphic misuse is rejected at compile-time by signature, not at call-site surprise
- Test hardening:
  - overflow on `p` direction sum
  - overflow on `q` accumulation
  - overflow on `usize -> i64` conversion boundary
  - all targeted tests pass via `zig test src/propagator.zig`

## Skill use landed

Test `"open-games: prisoner's dilemma Nash embeds via ε and Φ witnesses the fiber"`
(propagator.zig) exercises the **open-games** skill (ERGODIC 0) against this infra:
- `prisonersDilemma.play () = (Defect, Defect)` from the skill card, instantiated on
  two `Cell(f32, latticeMerge(f32))` carriers as strategies {0.0 = C, 1.0 = D}.
- ε (`embed_equilibrium`) commits the Nash vector; Φ_{p,q} reports direction_delta = −2
  against p = `{2,2}` (players × choices) and q = `{1,1,1,1}` (payoff readouts);
  balancedTrit(−2) = **+1** gf3_residual — the fiber is "q-underweight" vs the choice
  polynomial, matching intuition (single payoff readout vs two strategy directions).
- η (`extract_strategies`) roundtrips the Nash back out, committing the Γ-cycle
  η ∘ ε = id on committed cells.

This is the first end-to-end open-games-as-Poly-coalgebra witness in the repo.

## Candidate check: which Φ gives Φ(p, y) ≅ p?

Setting `q = y` (so `y.pos = unit`, `y.dir _ = unit`) and unfolding each candidate:

**A. Φ(p, q) = p ◁ q**
- `(p ◁ y).pos = Σ_{pp} (p.dir pp → y.pos) = Σ_{pp} (p.dir pp → unit) = p.pos`
- `(p ◁ y).dir(pp, _) = Σ_{d : p.dir pp} y.dir(*) = p.dir pp`
- **Φ(p, y) ≅ p. ✓**

**B. Φ(p, q) = p ◁ (y × q)**
- `(y × y).pos = unit`, `(y × y).dir(*) = unit ⊎ unit = 2`
- `(p ◁ (y×y)).dir(pp, _) = 2 · p.dir pp` — directions doubled. ✗

**C. Φ(p, q) = p ◁ (y + q)**
- `(y + y).pos = 2`; positions blow up to `(p.dir pp → 2)^{p.pos}`. ✗

**D. Φ(p, q) = p ⊗ q = Σ_{pp} q(p.dir pp)** (Dirichlet-tensor / parallel composition)
- `(p ⊗ y).pos = Σ_{pp} y.pos = p.pos`
- `(p ⊗ y).dir(pp, *) = p.dir pp × unit = p.dir pp`
- **Φ(p, y) ≅ p. ✓**

**Result:** only **A (`◁`)** and **D (`⊗`)** pass the unit check. `◁` is Poly's
self-composition (substitution); `⊗` is the Dirichlet parallel-tensor. Naming Φ := ◁
collapses to composition — no new operation — so the useful distinction only arises
if we need parallel composition (independent players that don't share directions).

**Which to adopt for the propagator lift?** The current `phi_p_q` in propagator.zig
is neither ◁ nor ⊗ as an explicit `Poly` value; it is a **direction-budget witness**
over a carrier — closer to the comonadic `extend` of a q-structure on X than either
categorical operation. So the real choice here is:

| Option | Commitment |
|--------|-----------|
| keep `phi_p_q` as a witness | pragmatic; no Poly object constructed; GF(3) residual is the signal |
| expose ◁ in `src/poly.zig`  | canonical Φ = ◁; aligns with Spivak's module framing; substitution-based composition |
| expose ⊗ in `src/poly.zig`  | parallel composition; better fit when carriers for p and q should not share direction budget |

Recommendation: **both** ◁ and ⊗ in `src/poly.zig`, keep `phi_p_q` as the carrier-witness layer. Any SDF-style composite is then either ◁-composite (pipeline) or ⊗-composite (parallel), and `phi_p_q` reports the residual regardless.

## Next (if picked up)

1. ~~Write `src/poly.zig` with `Poly`, `◁` (substitution), `⊗` (Dirichlet-tensor),
   and unit tests verifying `p ◁ y ≅ p` and `p ⊗ y ≅ p` at the shape level.~~
   **Landed:** `src/poly.zig` exposes `Poly`, `OwnedPoly`, `y`, `compose`/`triangleleft`
   (◁), and `tensor` (⊗). Unit tests: `y ◁ p ≅ p`, `p ◁ y ≅ p`, `y ⊗ p ≅ p`,
   `p ⊗ y ≅ p`, plus concrete expansion checks for both operations.
2. ~~Wire `triangleleft` in `src/propagator.zig` to import `poly.zig`'s `compose`
   so the existing witness aligns with the canonical form (currently duplicated).~~
   **Landed:** `propagator.zig` now imports `poly.zig` as `pub const poly`, and
   `PolynomialShape.toPoly()` returns a borrowed `poly.Poly` view. New test
   `"PolynomialShape.toPoly bridges shape-level compose and tensor"` exercises
   both ◁ and ⊗ through the bridge and checks `p ⊗ y ≅ p` at the shape level.
3. ~~Add `readout` / `inject` to `Cell` that name the `positions`/`directions` split.~~
   **Landed:** `Cell(T, merge_fn)` now exposes `readout() -> CellValue(T)` and
   `inject(direction) -> !CellValue(T)` with `Direction = { read | write: T |
   contradict: {a,b} }`. Test `"Cell coalgebra: readout + inject name
   positions/directions"` exercises all three directions against the lattice.
   Follow-up `"Cell inject drives propagator network via neighbor alert"`
   wires an adder via `add_neighbor` and drives it end-to-end with `inject(.write)`
   calls, confirming the coalgebra direction fires the full propagator graph.
4. ~~Port one SDF example (`adder-propagator`) as a ⊗-composite and show `phi_p_q`
   reports a consistent residual across the composite vs the components.~~
   **Landed:** Test `"adder propagator as p_a (x) p_b (x) p_c: shape total =
   product of component totals"` builds three single-position/single-direction
   component shapes, ⊗-composes them via `poly.tensor`, fires the adder
   propagator (2.0 + 3.0 = 5.0), and checks the Dirichlet distribution law
   `total_dir(p ⊗ q) = total_dir(p) · total_dir(q)`. `phi_p_q` over the
   composite reports `p_total=1`, `q_total=3`, `delta=2`, `gf3_residual=-1`;
   over a component (a alone) reports `delta=0`, `gf3_residual=0`. Both
   witnesses pass `isConsistent()`.

## Play is compositional, coplay is emergent

Design rule for the open-games face of this infra:

- `play()` is the **forward** half of an open-game, and **composes via ⊗ / ◁**.
  Give it to `p : PolynomialShape` and compose with `poly.compose` /
  `poly.tensor` — this is where the categorical machinery actually pays off.
- `coplay()` is the **backward** half. It is **emergent** from the equilibrium
  fixed-point, not independently declared. The `q` polynomial's arities should
  be *derived* from the forward output (strategy values, lattice positions,
  residuals) — declaring `q` statically in Zig code leaks the structure that
  the equilibrium is meant to discover.

Where current tests stand under this rule:
- PD Nash test: `p = {2,2}` (play) ✓, `q = {1,1,1,1}` (coplay) **static** —
  fine as an integrity-gate pin, not as a general composition primitive.
- Adder ⊗-composite: `p_a ⊗ p_b ⊗ p_c` (play) ✓, `q = {1}` (coplay) **static**
  — same caveat.

Next principled extension: a Φ variant where `q.direction_count_per_position[i]`
is computed from `cells[i].readout()`, closing the adjunction so coplay arity
is a function of play state.

### Surprisal-satisficing update (KL-trit)

`PhiWitness.klTritUpdate(prior, posterior) -> PhiError!i8` compresses the
direction_delta change across an inject into a GF(3)-balanced trit in
`{-1, 0, +1}`. Interpretation (Hedges passive/active inference, FEP-adjacent):
rather than carry a full posterior distribution, the propagator observes a
three-valued residual **in parallel with acting on its next prediction**. The
trit is algorithmically realizable — one subtraction + `@mod(_, 3)` — and
composes with the existing static `gf3_residual` field (which satisfices one
witness into a trit; `klTritUpdate` satisfices a *pair* of witnesses into a
trit).

Anti-symmetry under GF(3): `klTritUpdate(b, a) == balancedTrit(-klTritUpdate(a, b))`,
so a forward/backward pair across the same inject sums to 0 (mod 3). Tested
in `"PhiWitness.klTritUpdate: surprisal-satisficing trit between prior and
posterior"`.

## Cross-refs

- `~/.claude/projects/-Users-bob-i/memory/phi-poly-triad.md` — GF(3) skill triad for this thread.
- `src/propagator.zig` — current cell / merge / lattice.
- `src/gay/propagator.zig` — sibling propagator, **lifted**: imports
  `../poly.zig`, exposes `Cell.readout()` + `Cell.inject(Direction, *Scheduler)`
  with `Direction = { read | write: Value | contradict: []const u8 }`; tests
  `"gay Cell coalgebra"` and `"gay shapes compose via poly.tensor"`.
  (`src/spatial_propagator.zig`, `src/fountain_propagator.zig` do not exist.)
- Spivak 2023 blog on Poly + ordered-locale — source for the `c_p(1)` topology note.
