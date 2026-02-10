# zig-syrup

[![CI](https://github.com/plurigrid/zig-syrup/actions/workflows/ci.yml/badge.svg)](https://github.com/plurigrid/zig-syrup/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

OCapN Syrup serialization + capability-secure transport + identity + BCI + terminal visualization in Zig. Zero dependencies, zero allocation in hot paths, wasm32-freestanding compatible.

## Architecture

```
                        ┌─────────────────────────────────────────────┐
                        │            Applications                      │
                        │                                              │
                        │  passport.zig     ghostty_ix.zig   eeg.zig  │
                        │  (identity)       (terminal IX)    (BCI)    │
                        └──────┬──────────────┬──────────────┬────────┘
                               │              │              │
                        ┌──────▼──────────────▼──────────────▼────────┐
                        │          Domain Modules                      │
                        │                                              │
                        │  propagator    spatial_propagator    acp     │
                        │  homotopy      continuation          bim     │
                        │  ripser        spectral_tensor       fem     │
                        │  worlds/*      color_simd       prigogine   │
                        └──────┬──────────────┬──────────────┬────────┘
                               │              │              │
                        ┌──────▼──────────────▼──────────────▼────────┐
                        │            Transport Layer                   │
                        │                                              │
                        │  tcp_transport    websocket_framing          │
                        │  message_frame    websocket_compression      │
                        │  ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─  │
                        │  fountain.zig     qrtp_frame.zig    (NEXT)  │
                        │  qrtp_transport.zig                 (NEXT)  │
                        └──────┬──────────────┬──────────────┬────────┘
                               │              │              │
                        ┌──────▼──────────────▼──────────────▼────────┐
                        │          Core Serialization                  │
                        │                                              │
                        │  syrup.zig  — 11 value types, zero-copy     │
                        │  CapTP descriptors, CID, canonical encode    │
                        └─────────────────────────────────────────────┘
```

## Modules (52)

### Core Serialization

| Module | LOC | Description |
|--------|-----|-------------|
| `syrup.zig` | 102K | OCapN Syrup canonical binary serialization. 11 value types, zero-copy decode, BigInt, SIMD-ready parsing, CapTP descriptor helpers, CID computation |
| `message_frame.zig` | 232 | Length-prefix framing `[u32 BE length][payload]`. FrameAccumulator ring buffer for partial frame reassembly. 4MB DoS limit |
| `tcp_transport.zig` | 205 | TCP transport for OCapN CapTP. Connection send/recv with framed I/O, TcpTransport listen/accept/connect |

### Terminal & Visualization

| Module | LOC | Description |
|--------|-----|-------------|
| `terminal.zig` | 33K | Native terminal renderer. ANSI sequences, damage-aware repainting |
| `terminal_wasm.zig` | 6K | WASM terminal target for browser embedding |
| `rainbow.zig` | 32K | Golden/plastic/silver angle color spirals, CRT phosphor, colored S-expression parsing |
| `damage.zig` | 37K | Dirty-cell tracking, AABB coalescing, bitset masks, ring buffer |
| `cell_dispatch.zig` | 52K | Transducer-based parallel cell dispatch. GPU-friendly 16-byte cells, thread pool, cache-aligned batches |
| `cell_sync.zig` | 35K | Distributed terminal cell synchronization |
| `quantize.zig` | 10K | xterm-256 color quantization via O(1) LUT |
| `color_simd.zig` | 13K | SIMD-vectorized color space conversions (RGB↔HSL↔Okhsl) |
| `qasm.zig` | 6K | Quantum circuit ASCII art renderer (OpenQASM) |

### Ghostty Integration

| Module | LOC | Description |
|--------|-----|-------------|
| `ghostty_ix.zig` | 13K | Ghostty IX protocol: interaction extensions for terminal multiplexing |
| `ghostty_ix_bim.zig` | 11K | BIM bytecode VM (20 opcodes) for Ghostty |
| `ghostty_ix_continuation.zig` | 13K | OCapN continuations for Ghostty session state |
| `ghostty_ix_http.zig` | 16K | HTTP transport for Ghostty IX |
| `ghostty_ix_shell.zig` | 8K | Shell integration for Ghostty IX |
| `ghostty_ix_spatial.zig` | 9K | Cross-window spatial navigation for Ghostty |
| `ghostty_web_server.zig` | 16K | WebSocket :7070 server for browser-based Ghostty |

### WebSocket Stack

| Module | LOC | Description |
|--------|-----|-------------|
| `websocket_framing.zig` | 14K | RFC 6455 frame parsing, masking, fragmentation |
| `websocket_compression.zig` | 10K | Per-message deflate (RFC 7692) |
| `websocket_backpressure.zig` | 12K | Flow control with write buffering |
| `websocket_metrics.zig` | 10K | Connection statistics and health monitoring |

### Identity & Proof-of-Brain

| Module | LOC | Description |
|--------|-----|-------------|
| `passport.zig` | 39K | **passport.gay** proof-of-brain identity protocol. EEG → FFT bands → Shannon entropy → GF(3) trit trajectory → session commitment → `did:gay` binding. Challenge-response verification, homotopy continuity, liveness detection. wasm32-freestanding compatible |

### BCI & Neuroscience

| Module | LOC | Description |
|--------|-----|-------------|
| `cyton_parser.zig` | 9K | OpenBCI Cyton 8-channel EEG packet parser |
| `fft_bands.zig` | 10K | FFT → 5 frequency bands (δ/θ/α/β/γ) |
| `eeg.zig` | 11K | EEG processing pipeline (Cyton → FFT → bands) |
| `bci_homotopy.zig` | 7K | BCI phenomenal state as homotopy path |
| `spectral_tensor.zig` | 50K | Thalamocortical spectral integration |
| `ur_robot_adapter.zig` | 16K | UR5 robot Modbus TCP driver, 8D↔6D EEG→robot mapping |

### Propagators (Radul-Sussman + Orion Reed)

| Module | LOC | Description |
|--------|-----|-------------|
| `propagator.zig` | 13K | Partial information lattice `Nothing < Value < Contradiction`. Bidirectional constraint propagation. BCI neurofeedback gate, adjacency gate, focus brightness |
| `spatial_propagator.zig` | 28K | SplitTree topology → propagator network. Golden-spiral node coloring, focus state propagation, C ABI export |

### Topology & Algebra

| Module | LOC | Description |
|--------|-----|-------------|
| `homotopy.zig` | 44K | Polynomial homotopy continuation, ACSet export, GF(3) path classification |
| `continuation.zig` | 20K | AGM belief revision, GF(3) trit arithmetic, resumable pipelines |
| `ripser.zig` | 32K | Vietoris-Rips persistent homology barcodes (Zig port of Ripser) |
| `linalg.zig` | 8K | Matrix operations for topology computations |
| `prigogine.zig` | 32K | Dissipative structures, non-equilibrium thermodynamics |
| `fem.zig` | 37K | Finite element method solver |
| `scs_wrapper.zig` | 21K | Splitting Conic Solver wrapper (convex optimization) |
| `spectrum.zig` | 39K | GF(3) triadic color bridge |

### Protocol & Agent

| Module | LOC | Description |
|--------|-----|-------------|
| `acp.zig` | 33K | Agent Client Protocol over Syrup (replaces JSON-RPC) |
| `acp_mnxfi.zig` | 22K | ACP extensions for mnx.fi market coordination |
| `jsonrpc_bridge.zig` | 35K | Bidirectional JSON-RPC 2.0 ↔ Syrup translation |
| `liveness.zig` | 14K | Terminal/ACP health probes |
| `bim.zig` | 12K | BIM bytecode interpreter (Stellogen) |

### Geographic & Location

| Module | LOC | Description |
|--------|-----|-------------|
| `geo.zig` | 42K | Open Location Code (Plus Codes) with Syrup serialization |
| `czernowitz.zig` | 36K | Extended location codes |

### Utility

| Module | LOC | Description |
|--------|-----|-------------|
| `bristol.zig` | 7K | Bristol Fashion MPC circuit parser (AND, XOR, INV, EQ) |
| `csv_simd.zig` | 9K | SIMD-accelerated CSV parser (Bridge 9 optimization) |
| `xev_io.zig` | 10K | Completion-based async I/O for Syrup (libxev) |

### Worlds Subsystem (`src/worlds/`)

| Module | Description |
|--------|-------------|
| `world.zig` | Core world state container |
| `ab_test.zig` | A/B testing framework |
| `syrup_adapter.zig` | World ↔ Syrup serialization bridge |
| `persistent.zig` | Immer/ewig-style persistent data structures |
| `circuit_world.zig` | Bristol circuit integration for ZK |
| `openbci_bridge.zig` | OpenBCI neurofeedback bridge |
| `bci_aptos.zig` | BCI → Aptos on-chain commitment |
| `benchmark_adapter.zig` | Performance benchmarking |

## QRTP: Air-Gapped Transport (Next)

Inspired by [Orion Reed's QR Transfer Protocols](https://www.orionreed.com/posts/qrtp/) — three new modules extend the transport layer with fountain-coded QR streaming for air-gapped identity verification:

```
Existing:  syrup.zig → message_frame.zig → tcp_transport.zig   (network)
Next:      syrup.zig → qrtp_frame.zig   → qrtp_transport.zig  (screen↔camera)
                              ↑
                        fountain.zig  (Luby Transform rateless erasure codes)
```

| Module | Purpose |
|--------|---------|
| `fountain.zig` | Luby Transform encoder/decoder. Zero-allocation, SplitMix64 PRNG, SIMD XOR block combining. Any ~1.1K of infinite encoded blocks reconstruct K source blocks |
| `qrtp_frame.zig` | QRTP framing as Syrup records. Session seed, block index, degree, source indices, payload. Same message format over TCP or QR |
| `qrtp_transport.zig` | Screen↔camera transport via C ABI callbacks. Platform renders QR, platform scans camera. Zig handles fountain coding + Syrup framing |

**Key insight**: Every Syrup message that travels over TCP today can travel over fountain-coded QR tomorrow with zero application changes.

**passport.gay integration**: Proof-of-brain identity proofs (~2KB) fountain-encoded into ~20 QR frames. Air-gapped verification — no internet required, no centralized Orb hardware (unlike WorldID).

**Propagator connection**: Fountain decoder state maps to `propagator.zig`'s `CellValue` lattice — each source block is a cell, each encoded block is a propagator. Contradiction = transmission error. This is [scoped propagators](https://www.orionreed.com/posts/scoped-propagators/) applied to erasure decoding.

## DeepWiki vs Reality

[DeepWiki](https://deepwiki.com/plurigrid/zig-syrup) indexes the GitHub-pushed state. The repo has evolved significantly beyond what DeepWiki currently reflects:

| Aspect | DeepWiki View (12 modules) | Current Reality (52 modules) |
|--------|---------------------------|------------------------------|
| **Serialization** | syrup.zig core + CapTP optimizations | Same, plus message_frame + tcp_transport |
| **Transport** | xev_io async I/O only | TCP, WebSocket (4 modules), NATS, QRTP (planned) |
| **Terminal** | rainbow.zig + damage.zig | + terminal, terminal_wasm, cell_dispatch, cell_sync, quantize, qasm |
| **Ghostty** | Not indexed | 6 modules: ix, bim, continuation, http, shell, spatial |
| **Identity** | Not indexed | passport.zig (39K LOC proof-of-brain protocol) |
| **BCI/EEG** | Not indexed | cyton_parser, fft_bands, eeg, bci_homotopy, spectral_tensor, ur_robot_adapter |
| **Propagators** | Not indexed | propagator.zig (Radul-Sussman lattice), spatial_propagator.zig |
| **Topology** | homotopy.zig mentioned | + ripser, linalg, prigogine, fem, scs_wrapper, spectrum |
| **Markets** | Not indexed | acp_mnxfi.zig (mnx.fi market coordination) |
| **Worlds** | Not indexed | 8 modules: world, A/B test, persistent, circuit, OpenBCI, BCI-Aptos |
| **QRTP** | Not indexed | Planned: fountain, qrtp_frame, qrtp_transport |

DeepWiki's wiki structure shows 12 pages covering: Overview, Core Syrup Library (5 subsections), Build System, Async I/O, Geographic Integration, JSON-RPC Bridge, Bristol Circuit, Rainbow, Testing (4 subsections), Rust Reference, External Integrations, Development Guide. This reflects the pre-expansion codebase (~12 modules, ~600 tests). The current codebase has 52 modules with 1000+ tests across 7 architectural layers.

## Build

```bash
zig build              # default build
zig build test         # all module tests
zig build bench        # ReleaseFast benchmarks
zig build bench-cell-sync  # cell sync flamegraph benchmarks
zig build shader       # terminal fragment shader visualization
zig build test-viz     # visual test runner (ANSI 24-bit color)
zig build vibesnipe    # vibesnipe generator
zig build bristol      # Bristol circuit converter
zig build world-demo   # world A/B testing demo
zig build bci-demo     # BCI-Aptos bridge demo
```

### Executables

| Binary | Purpose |
|--------|---------|
| `syrup-verify` | CID verification tool |
| `syrup` | JSON ↔ Syrup CLI converter |
| `eeg` | EEG processing pipeline (Cyton → FFT → bands) |
| `bench-zig` | Core serialization benchmarks |
| `bench-cell-sync` | Cell sync + flamegraph benchmarks |
| `bristol-syrup` | Bristol MPC circuit converter |
| `vibesnipe` | Vibesnipe generator |
| `world-demo` | World A/B testing demo |
| `bci-demo` | BCI → Aptos bridge demo |

## GF(3) Conservation

Every layer maintains balanced ternary invariant `(-1) + (0) + (+1) ≡ 0 (mod 3)`:

| Layer | MINUS (-1) | ERGODIC (0) | PLUS (+1) |
|-------|-----------|-------------|-----------|
| **Serialization** | decode (verify) | syrup (bridge) | encode (generate) |
| **Transport** | tcp_transport (verify delivery) | message_frame (coordinate) | fountain (generate blocks) |
| **Propagator** | contradiction (detect) | lattice merge (coordinate) | value propagation (generate) |
| **Identity** | liveness check (-1) | homotopy continuity (0) | proof generation (+1) |
| **BCI** | spectral analysis (-1) | phenomenal state (0) | trit classification (+1) |

## Docs

- `BENCHMARK-RESULTS.md` — encode/decode/CID performance
- `CAPTP-OPTIMIZATIONS.md` — CapTP descriptor fast paths
- `ZIG-SYRUP-FULL-PARITY.md` — spec alignment with reference implementations
- `INTERCHANGE-COMPARISON.md` — format comparison (CBOR, MessagePack, Protobuf)
- `CATEGORY_THEORY_TILES.md` — category theory tile patterns

## Related

- [ocapn/syrup](https://github.com/ocapn/syrup) — Syrup specification
- [ocapn/ocapn](https://github.com/ocapn/ocapn) — OCapN protocol specification
- [Orion Reed — QR Transfer Protocols](https://www.orionreed.com/posts/qrtp/) — Fountain-coded QR streaming
- [Orion Reed — Scoped Propagators](https://www.orionreed.com/posts/scoped-propagators/) — Edge-scoped computation model
- [folkjs](https://folkjs.org) — Malleable computing experiments
- [passport.gay](https://passport.gay) — Proof-of-brain identity (uses passport.zig)

## Status

Active development. 52 modules, 1000+ tests, 7 architectural layers. Visualization tools operational. Persistent homology implemented. QRTP fountain transport next.
