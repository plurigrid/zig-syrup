# zig-syrup/.topos — CatColab Exported Objects

Tree diffusion on hierarchical byte streams, formalized as categorical models.

**Fundamental principle**: No direct agent-to-agent morphisms. All interaction is mediated by a **shared world** (span). `Agent → World ← Agent`, never `Agent → Agent`.

## Models (theory instances)

| File | Theory | Objects | Morphisms | Span Structure |
|------|--------|---------|-----------|----------------|
| `vat-triad.json` | causal-loop | 9 | 8 | Human → World ← Human (Mitsein as span) |
| `reel-diffusion-flow.json` | primitive-stock-flow | 8 | 6 | focused(+1) / unfocused(0) / border(-1) |
| `color-gf3-tiling.json` | causal-loop | 10 | 7 | Gromov hyperbolicity chain |
| `syrup-tree-schema.json` | simple-schema | 10 | 8 | Value type as diffusion target |
| `ocapn-topos.json` | causal-loop | 7 | 7 | Vat → CapTPSession ← Vat (OCapN as span) |

## Diagrams (instances of models)

| File | In Model | Key Insight |
|------|----------|-------------|
| `gromov-collapse.json` | color-gf3-tiling | S^1 x_f T ~QI T: cylinder vanishes under quasi-isometry |
| `focal-kan-extension.json` | reel-diffusion-flow | ncreel layout = Lan_focus(F\|_focused), the Riehl universal property |

## Analyses (property verification)

| File | Of Model | Result |
|------|----------|--------|
| `spectral-mixing-bounds.json` | color-gf3-tiling | O(log m) tree content, O(n^2) reel order, Apollonian gap ~0.908 |
| `gf3-conservation.json` | reel-diffusion-flow | All triads sum to 0 mod 3 across all framework levels |

## Archive strata

`.topos/` also serves as the preservation layer for repository material that should not disappear but no longer belongs in the first-class Zig package layout.

| Path | Purpose |
|------|---------|
| `artifacts/bin/` | built executables and empty launcher remnants kept for provenance |
| `artifacts/build/` | object files, archives, dylibs, and other build byproducts |
| `artifacts/data/` | preserved databases and non-package data blobs |
| `artifacts/html/` | standalone HTML outputs and visual captures |
| `artifacts/test/` | captured stdout, text outputs, and ad hoc verification traces |
| `scratch/zig/` | one-off Zig investigations that are worth keeping but not promoting |

## The Span Principle

```
Mitsein (vat-triad):       Human → World ← Human
OCapN (ocapn-topos):       Vat → CapTPSession ← Vat
Reel (reel-diffusion):     Tablet → ReelPlane ← Tablet
Tree (syrup-tree-schema):  Tree → EditPath ← Tree
Color (color-gf3-tiling):  Coloring → TilingGraph ← Coloring

Composition via pullback:
  A → W₁ ← B → W₂ ← C  ==>  A → W₁ ×_B W₂ ← C
  (B co-constitutes the composed world)
```

## The Mathematical Thread

```
Riehl: Colored tiling = functor F: T -> C. Layout = Lan_focus(F|_focused).
Tao:   Pre-rigorous (compute) -> Rigorous (prove gap) -> Post-rigorous (why hyperbolic).
Kontorovich: Apollonian spectral gap via Bourgain-Gamburd. Mixing O(log N).
Gromov: M = S^1 x_f T ~QI T. The cylinder doesn't matter. Everything is the tree.
```

## GF(3) of Every Span

```
Left projection:  +1 (Generator — the one who initiates/opens)
World/Session:     0 (Coordinator — the shared meeting place)
Right projection: -1 (Validator — the one who responds/accepts)
Sum: (+1) + 0 + (-1) = 0 ✓

Roles are symmetric (Mitsein is equiprimordial).
```

## zig-syrup Module Mapping

| CatColab Object | zig-syrup Module | Role |
|----------------|------------------|------|
| Value (schema) | `syrup.zig` | Core serialization target |
| ReelState (stock) | `cell_dispatch.zig` | Transducer-based rendering |
| GF3Trit (object) | `gf3_palette.zig`, `splitmix_trit.zig` | Triadic coloring |
| SpectralGap (object) | `color_simd.zig` | SIMD-accelerated mixing |
| HyperbolicGeometry | `spatial_propagator.zig` | SplitTree = 0-hyperbolic |
| CapTPSession (world) | `message_frame.zig` | OCapN framing (shared session) |
| CapTPSession (world) | `tcp_transport.zig` | CapTP transport (shared pipe) |
| FocusedTablet (stock) | `damage.zig` | Dirty-cell tracking = focus |
| TreeDiffEditPath | `quantize.zig` | O(1) LUT = pre-computed edit |
| World (326 worlds) | `worlds/world.zig` | 326 span vertices (meeting points) |
| WorldConfig | `worlds/world_enum.zig` | Combinatorial world enumeration |
