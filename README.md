# zig-syrup

[![CI](https://github.com/plurigrid/zig-syrup/actions/workflows/ci.yml/badge.svg)](https://github.com/plurigrid/zig-syrup/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

High-performance Zig implementation of the OCapN Syrup data format with CapTP-focused optimizations, terminal visualization, and computational topology foundations.

## Features

- Fast encode/decode for Syrup values (canonical binary serialization, 11 value types)
- CapTP descriptor helpers and arena sizing utilities
- OCapN model coverage: undefined, null, tagged, error
- Benchmarks for encode/decode/CID and CapTP-specific paths
- Terminal visualization: ANSI 24-bit color shaders, damage tracking, homoiconic colored S-expressions
- Homotopy continuation for polynomial systems with GF(3) trit classification
- Agent Client Protocol (ACP) for multi-agent coordination over Syrup
- Bristol Fashion MPC circuit parsing and serialization

## Modules

| Module | Description |
|--------|-------------|
| `syrup.zig` | Core serialization: all 11 Syrup value types, zero-copy decode, canonical encode |
| `acp.zig` | Agent Client Protocol using Syrup instead of JSON-RPC |
| `bristol.zig` | Bristol Fashion MPC circuit parser (AND, XOR, INV, EQ, EQW, MAND) |
| `geo.zig` | Open Location Code (Plus Codes) with Syrup serialization |
| `xev_io.zig` | Completion-based async I/O for Syrup values (libxev) |
| `jsonrpc_bridge.zig` | Bidirectional JSON-RPC 2.0 to Syrup translation |
| `liveness.zig` | Terminal/ACP health probes |
| `rainbow.zig` | Golden/plastic/silver angle color spirals, CRT phosphor, colored S-expression parsing |
| `damage.zig` | Dirty-cell tracking for terminal multiplexers, AABB coalescing |
| `homotopy.zig` | Polynomial homotopy continuation, ACSet export, GF(3) path status |
| `continuation.zig` | Belief revision (AGM), GF(3) trit arithmetic, resumable pipelines |

## Build

```bash
zig build              # default build
zig build test         # 379 tests across 12 modules
zig build bench        # ReleaseFast benchmarks
zig build shader       # terminal fragment shader visualization
zig build test-viz     # visual test runner (ANSI 24-bit color)
zig build vibesnipe    # vibesnipe generator
zig build bristol      # Bristol circuit converter
```

## Visualization Tools

**`zig build shader`** renders 5 terminal fragment shaders:
- Golden Spiral — Fibonacci spiral via golden angle hue rotation
- Homotopy Path — polynomial root positions on complex plane
- Damage Heat Map — dirty/clean region coloring
- GF(3) Trit Field — balanced ternary (-1/0/+1) as purple/gray/green
- CRT Phosphor — scanlines + bloom on color gradient

**`zig build test-viz`** exercises all visualization modules with labeled ANSI output:
rainbow palette strips, damage grids, homotopy root tracking, GF(3) trit balance, and Syrup encode verification.

## Roadmap: Persistent Homology & Topological Data Analysis

There is currently **no Zig implementation** of persistent homology or Vietoris-Rips persistence barcodes anywhere in the ecosystem. zig-syrup aims to be the first, building on the existing homotopy and GF(3) infrastructure.

### Target: Ripser in Zig

[Ripser](https://github.com/Ripser/ripser) by Ulrich Bauer is the state-of-the-art for computing Vietoris-Rips persistence barcodes — outperforming Dionysus, DIPHA, GUDHI, Perseus, and PHAT by 40x in time and 15x in memory. The [`simple` branch](https://github.com/Ripser/ripser/tree/simple) is ~1200 lines of C++11, MIT-licensed, zero dependencies.

Core algorithm components and their Zig mappings:

| Ripser concept | Zig equivalent |
|----------------|----------------|
| Combinatorial number system (implicit simplex indexing) | `comptime` binomial coefficient tables |
| Compressed sparse coboundary columns | Explicit allocator control, cache-friendly layout |
| Column reduction with clearing optimization | `std.ArrayListUnmanaged` for pivot columns |
| Apparent pairs shortcut | Branch-free trit classification (existing GF(3) module) |
| Distance matrix | SIMD-accelerated pairwise distances (`@Vector`) |
| Hash map for persistence pairs | `std.HashMap` with explicit allocator |
| Barcode output | Syrup-encoded persistence diagrams with CID |

### Planned modules

```
src/
  ripser.zig          — Vietoris-Rips persistence barcodes (port of Ripser simple branch)
  simplicial.zig      — Simplicial complex data structures, filtrations, boundary matrices
  persistence.zig     — Persistence diagram types, bottleneck/Wasserstein distances
```

### Integration with existing modules

- **homotopy.zig** already tracks polynomial roots along paths — persistence diagrams will capture birth/death of topological features along these paths
- **continuation.zig** GF(3) trit arithmetic maps to PathStatus (success/tracking/failed → plus/zero/minus), providing a balanced ternary classification layer over persistence pairs
- **rainbow.zig** color spirals will visualize persistence diagrams in the terminal using golden angle hue assignment per homology dimension
- **damage.zig** frame tracking enables incremental persistence computation display — only recompute visualization for changed regions
- **Syrup serialization** of persistence barcodes enables content-addressed storage (CID) and CapTP distribution of TDA results across agents

### Zig ecosystem dependencies to evaluate

Libraries that provide foundational support for TDA in Zig:

| Library | What it provides | Relevance |
|---------|-----------------|-----------|
| [yamafaktory/hypergraphz](https://github.com/yamafaktory/hypergraphz) | Hypergraph data structure | Simplicial complex representation via hyperedges |
| [Traxar/SPaDE](https://github.com/Traxar/SPaDE) | Sparse + dense tensor ops | Boundary matrix storage |
| [gitabaz/zigblas](https://github.com/gitabaz/zigblas) | BLAS bindings | Matrix reduction acceleration |
| [tatjam/zgsl](https://github.com/tatjam/zgsl) | GNU Scientific Library wrapper | Linear algebra, eigenvalue computation |
| [srmadrid/zml](https://zigistry.dev/packages/github/srmadrid/zml/) | Numerical math with LAPACK | Matrix decomposition (LU, Cholesky, QR) |
| [GhostKellz/zmath](https://github.com/GhostKellz/zmath) | Scientific computing library | BLAS/LAPACK/GSL replacement |
| [hmusgrave/sparsemat](https://github.com/hmusgrave/sparsemat) | Sparse matrix scheme | Compressed sparse representations |
| [pierrekraemer/zgp](https://github.com/pierrekraemer/zgp) | Geometry processing | Mesh-based filtrations |

### Reference implementations (other languages)

| Language | Project | Notes |
|----------|---------|-------|
| C++ | [Ripser/ripser](https://github.com/Ripser/ripser) | Original, ~1200 LOC simple branch, MIT |
| C++/CUDA | [Ripser++](https://github.com/simonzhang00/ripser-plusplus) | GPU-accelerated |
| Python | [scikit-tda/ripser.py](https://github.com/scikit-tda/ripser.py) | C++ engine with Python bindings |
| Python | [giotto-ai/giotto-ph](https://github.com/giotto-ai/giotto-ph) | Parallel lock-free Ripser |
| Julia | [Ripserer.jl](https://mtsch.github.io/Ripserer.jl/dev/) | Pure Julia reimplementation |
| R | [tdaverse/ripserr](https://github.com/tdaverse/ripserr) | Rcpp wrapper |
| C++ | [GUDHI](https://gudhi.inria.fr/) | Full TDA library (simplicial, cubical, alpha) |
| C++ | [PHAT](https://github.com/blazs/phat) | Persistent Homology Algorithm Toolbox |
| C++ | [CompTop/BATS](https://github.com/CompTop/BATS) | Matrix factorization approach to persistence |

## Docs

- `BENCHMARK-RESULTS.md` — encode/decode/CID performance numbers
- `CAPTP-OPTIMIZATIONS.md` — CapTP-specific optimizations
- `ZIG-SYRUP-FULL-PARITY.md` — spec alignment with reference implementations
- `INTERCHANGE-COMPARISON.md` — format comparison analysis
- `CATEGORY_THEORY_TILES.md` — category theory tile patterns

## Related OCapN/Syrup Repos

- [ocapn/syrup](https://github.com/ocapn/syrup) — specification
- [ocapn/ocapn](https://github.com/ocapn/ocapn) — protocol specification
- [ocapn/ocapn-test-suite](https://github.com/ocapn/ocapn-test-suite) — conformance tests
- [cmars/ocapn-syrup](https://github.com/cmars/ocapn-syrup) — Go implementation
- [costa-group/syrup-python](https://github.com/costa-group/syrup-python) — Python implementation

## Status

Active development. 379 tests passing across 12 modules. Visualization tools operational. Persistent homology port on the roadmap.
