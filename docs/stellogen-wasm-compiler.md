# Stellogen → Verified WASM Compiler

## Overview

A verifiable compiler from Stellogen (stellar resolution / transcendental syntax) to WebAssembly, with machine-checked correctness proofs in Coq.

```
┌─────────────────────────────────────────────────────────────────┐
│                    Stellogen Source                             │
│  constellation demo = { [+hello(-X)] [+world(-Y)] [@-hello(z)] }│
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                    Stage 1: Parse → Stellar IR                  │
│  OCaml AST → Interaction Net Graph Representation               │
│  (Rays become ports, Stars become agents, Fusion = reduction)   │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                    Stage 2: Stellar IR → ANF                    │
│  Graph reduction → Administrative Normal Form                   │
│  (Lamping-style optimal reduction preserving)                   │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                    Stage 3: ANF → WASM                          │
│  CertiCoq-Wasm verified backend                                 │
│  (Mechanized in Coq against WasmCert-Coq)                       │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                    Verified WASM Binary                         │
│  .wasm file with correctness certificate                        │
└─────────────────────────────────────────────────────────────────┘
```

## Key Insight: Star Fusion = Interaction Nets

Stellogen's execution model maps directly to Lafont's interaction combinators:

| Stellogen         | Interaction Nets        | WASM                    |
|-------------------|-------------------------|-------------------------|
| Ray (polarized term) | Port (with polarity) | Memory cell pointer     |
| Star (block of rays) | Agent (node)         | Closure / data block    |
| Star Fusion       | Interaction rule        | Function call / reduce  |
| Constellation     | Net (graph of agents)   | Module                  |
| `exec` (reuse)    | Duplicator agent        | Loop / recursion        |
| `fire` (linear)   | One-shot interaction    | Single execution        |

### Why This Matters

1. **Optimal reduction**: Interaction nets achieve theoretically optimal sharing (Lamping's algorithm)
2. **Parallelism**: Interaction is local — enables WASM threading
3. **Verified**: Asperti-Laneve theory provides proof foundation
4. **Memory-safe**: Graph representation naturally bounds allocation

## Stage 1: Stellogen → Stellar IR

### Current Stellogen AST (OCaml)

From `src/core/syntax.ml`:
```ocaml
type term = Var of string | Fun of string * term list
type ray = Pos of term | Neg of term | Neutral of term
type star = { content: ray list; bans: constraint list }
type constellation = star list
```

### Stellar IR (Interaction Net Graph)

```ocaml
(* New IR in src/ir/stellar_ir.ml *)

type port_id = int
type agent_id = int

type polarity = Plus | Minus | Zero

type port = {
  id: port_id;
  polarity: polarity;
  term: term;  (* for unification *)
}

type agent = {
  id: agent_id;
  principal: port;      (* main interaction port *)
  auxiliary: port list; (* other ports *)
  is_state: bool;       (* @-marked = data, unmarked = rule *)
}

type wire = port_id * port_id  (* connected ports *)

type net = {
  agents: agent list;
  wires: wire list;
  free_ports: port list;  (* external interface *)
}
```

### Translation Rules

1. **Star → Agent**: Each star becomes an agent node
2. **Ray → Port**: Each ray becomes a port with polarity
3. **Shared variables → Wires**: Variables appearing in multiple rays create wires
4. **Fusion → Interaction**: Opposite-polarity ports with unifiable terms interact

```
Stellogen:  [+f(X) -g(X) +h(Y)]
     ↓
Stellar IR: Agent {
              principal: Port(+, f(X)),
              auxiliary: [Port(-, g(X)), Port(+, h(Y))],
              wires: [(port_of(X in f), port_of(X in g))]
            }
```

## Stage 2: Stellar IR → ANF

### Interaction Net Reduction

The key reduction rules (Lafont's combinators + unification):

```
INTERACTION RULE:
  Agent A with Port(+, t1) ←wire→ Port(-, t2) in Agent B
  WHERE unify(t1, t2) = Some σ
  ──────────────────────────────────────────────────────
  Merge A and B, apply σ to all terms, remove matched ports
```

### ANF Output

Administrative Normal Form for WASM targeting:

```ocaml
type anf_expr =
  | Let of var * anf_value * anf_expr
  | Return of var
  | Call of var * var list * anf_expr
  | Switch of var * (pattern * anf_expr) list
  | Halt

type anf_value =
  | Const of int
  | Closure of var list * anf_expr
  | Project of var * int
  | Alloc of anf_value list
```

### Translation Strategy

1. **Linear constellations** (`fire`): Direct reduction to ANF
2. **Reusable constellations** (`exec`):
   - Introduce duplication nodes (Lafont's δ/ε)
   - Lower to recursive ANF with explicit copying
3. **Unification**:
   - Compile pattern matching for each polarity combination
   - Generate WASM `br_table` for efficient dispatch

## Stage 3: ANF → WASM (CertiCoq-Wasm)

Leverage the existing verified pipeline:

```
CertiCoq-Wasm architecture:
  ANF → closure conversion → hoisting → WASM codegen

All stages verified in Coq against WasmCert-Coq semantics.
```

### WASM Memory Layout

```
┌──────────────────────────────────────────────────────────┐
│  WASM Linear Memory                                      │
├──────────────────────────────────────────────────────────┤
│  0x0000: Agent pool (fixed-size agent structs)           │
│  0x1000: Port pool (port descriptors with term refs)     │
│  0x2000: Term heap (unification terms, GC'd)             │
│  0x3000: Wire table (port_id → port_id mappings)         │
│  0x4000: Free list heads                                 │
└──────────────────────────────────────────────────────────┘
```

### Core WASM Functions

```wat
(module
  ;; Agent allocation
  (func $alloc_agent (param $n_ports i32) (result i32) ...)

  ;; Port connection
  (func $connect (param $p1 i32) (param $p2 i32) ...)

  ;; Unification (returns 0 on failure, 1 on success + applies subst)
  (func $unify (param $t1 i32) (param $t2 i32) (result i32) ...)

  ;; Star fusion (the core interaction step)
  (func $fuse (param $agent1 i32) (param $agent2 i32) (result i32) ...)

  ;; Main reduction loop
  (func $reduce (result i32)
    (loop $step
      (if (call $find_redex)
        (then
          (call $fuse (global.get $redex_a) (global.get $redex_b))
          (br $step)))
      (return (i32.const 1))))
)
```

## Coq Formalization

### Required Developments

1. **Stellar Resolution Semantics** (`StellarSemantics.v`)
   - Formalize terms, rays, stars, constellations
   - Define star fusion as a relation
   - Prove confluence (Church-Rosser)

2. **Interaction Net Correspondence** (`StellarToINet.v`)
   - Formalize translation from Stellar IR to interaction nets
   - Prove simulation: Stellogen reduction ⟺ net reduction
   - Use Asperti-Laneve framework

3. **ANF Semantics** (`StellarANF.v`)
   - Define ANF syntax and semantics
   - Prove net reduction → ANF evaluation correspondence

4. **WASM Correctness** (`StellarWasm.v`)
   - Import WasmCert-Coq
   - Prove ANF → WASM preserves semantics
   - Compose with CertiCoq-Wasm backend proofs

### Main Theorem

```coq
Theorem stellogen_wasm_correct :
  forall (prog : constellation) (result : term),
    stellogen_eval prog = Some result ->
    exists wasm_result,
      wasm_eval (compile prog) = Some wasm_result /\
      stellogen_term_equiv result wasm_result.
```

## Implementation Plan

### Phase 1: Stellar IR (OCaml, 2 weeks)
- [ ] Define `stellar_ir.ml` types
- [ ] Implement `ast_to_ir.ml` translation
- [ ] Add IR pretty-printer and validator
- [ ] Port existing evaluator to use IR

### Phase 2: IR Reduction (OCaml, 3 weeks)
- [ ] Implement interaction net reduction engine
- [ ] Add duplication/erasure for `exec` mode
- [ ] Optimize: hash-consing for terms
- [ ] Benchmark against current evaluator

### Phase 3: ANF Backend (OCaml, 2 weeks)
- [ ] Define ANF types
- [ ] Implement IR → ANF lowering
- [ ] Generate readable ANF output
- [ ] Test with simple constellations

### Phase 4: WASM Codegen (OCaml + Coq, 4 weeks)
- [ ] Direct WASM output for testing
- [ ] Integrate CertiCoq-Wasm backend
- [ ] Memory layout and GC strategy
- [ ] Validate with spec tests

### Phase 5: Coq Formalization (Coq, 6 weeks)
- [ ] Stellar resolution semantics
- [ ] Translation correctness to IR
- [ ] IR to ANF correspondence
- [ ] Full pipeline theorem

## Integration with Existing Stellogen

Modify `src/eval/evaluator.ml`:

```ocaml
let eval_constellation ~verified ~target constellation =
  match target with
  | `Interpret ->
      (* Current direct evaluation *)
      star_fusion constellation
  | `IR ->
      (* New: lower to Stellar IR *)
      let ir = Ast_to_ir.translate constellation in
      Ir_eval.reduce ir
  | `Wasm verified ->
      (* New: compile to WASM *)
      let ir = Ast_to_ir.translate constellation in
      let anf = Ir_to_anf.lower ir in
      let wasm = if verified
        then Certicoq_wasm.compile anf  (* verified *)
        else Direct_wasm.emit anf       (* fast, unverified *)
      in
      wasm
```

## References

- **CertiCoq-Wasm**: github.com/womeier/certicoqwasm (CPP 2025)
- **WasmCert-Coq**: github.com/WasmCert/WasmCert-Coq
- **Iris-Wasm**: github.com/logsem/iriswasm (PLDI 2023)
- **Lafont Interaction Combinators**: "Interaction Combinators" (1997)
- **Stellar Resolution**: Boris Eng, Thomas Seiller papers (LIPN)
- **Lamping's Optimal Reduction**: "An algorithm for optimal lambda calculus reduction" (1990)

## Open Questions

1. **GC Strategy**: Reference counting vs tracing for term heap?
2. **Unification Complexity**: Worst-case exponential — add occurs check timeout?
3. **Parallel Reduction**: WASM threads for independent redexes?
4. **Effect Handlers**: Map Stellogen's assert/phasing to WasmFX?
5. **Incremental Compilation**: Compile constellations independently?
