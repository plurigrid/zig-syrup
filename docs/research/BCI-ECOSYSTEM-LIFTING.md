# BCI Ecosystem Lifting: From Mechanical Cortex to Universal Receiver

## The Landscape (Feb 2026)

### Meta's "Mechanical Cortex" — Reading the Cortex's Mechanical Output

Meta doesn't call it "Mechanical Cortex" — but that's exactly what it is. **CTRL-labs at Reality Labs** (acquired 2019) built the most advanced non-invasive neuromotor interface to date:

- **Nature paper (Jul 2025)**: "A generic non-invasive neuromotor interface for human-computer interaction" — Kaifosh & Reardon
- **Neural Band (Sep 2025)**: Consumer wristband shipping with Ray-Ban smart glasses
- **brain2qwerty (Feb 2025)**: MEG/EEG brain-to-text decoding (81% accuracy, FAIR Paris lab) — stuck in the lab (MEG scanner weighs 500kg, costs $2M)
- **NeurIPS 2025 demo**: Live Neural Band demo at Foundation Models for Brain and Body workshop

The architecture is literally a "mechanical cortex" pipeline:
```
Motor cortex → Spinal cord → Peripheral nerves → Muscles → sEMG at wrist → AI decoder → Computer input
```

Key insight: Meta proved **generic models** work across users without per-person calibration. Trained on thousands of participants, the sEMG decoder works for new users out of the box.

**What this means for BCI Factory**: Our nRF5340 universal receiver's EMG/ENG channels (SPI2) should support the same sEMG modality. The open-standard version of what Meta's Neural Band does proprietary.

### Science Corp — Invasive, Clinical, Proprietary

- **PRIMA implant**: 65,536 electrodes, 1,024 channels (Nature Electronics, Dec 2025)
- **Vision restoration**: Blind patients seeing again (NEJM, Oct 2025)
- **$100M+ from Khosla Ventures**, founded by Max Hodak (ex-Neuralink president)
- **Vertically integrated**: chips, electrodes, surgical tools, software — all closed

### Nudge — Non-invasive Focused Ultrasound

- **$100M Series A** (Thrive Capital, Greenoaks, Feb 2026)
- **Fred Ehrsam** (Coinbase co-founder)
- **"Nudge Zero"**: Non-invasive focused ultrasound BCI
- **"Whole-brain interfaces for everyday life"**
- Guillermo building transducer hardware

---

## BCI Data Interchange Formats

### The Big Five

| Format | Type | Status | Use Case | zig-syrup Integration |
|--------|------|--------|----------|----------------------|
| **NWB 2.9.0** | HDF5-based schema | Standard, BUT funding cliff Mar 2026 | Neurophysiology archival (DANDI has 300+ datasets) | Read via HDF5 C API → Zig `@cImport` |
| **BIDS 1.10.1** | Folder structure | W3C-style governance | Multi-modal brain imaging organization | Directory layout + JSON sidecars |
| **LSL** | Network streaming | Reference paper 2025 (Kothe et al.) | Real-time multi-device synchronization | TCP/UDP multicast → `tcp_transport.zig` |
| **XDF** | Binary recording | LSL's native format | Offline analysis of LSL streams | Binary parser in Zig |
| **EDF/BDF** | Legacy binary | Still widely used | Clinical EEG recording | Simple header + data blocks |

### NWB: The Critical Standard (Under Threat)

**Neurodata Without Borders** is THE neurophysiology data standard:
- HDF5-based, extensible via `neurodata_type` system
- Stores: intracellular/extracellular electrophysiology, optical physiology, behavioral data
- **DANDI Archive**: 300+ public datasets (Allen Institute, MICrONS, IBL Brain Wide Map)
- **MNE-Python, MNE-BIDS**: Primary analysis toolchain
- **Compatible with BIDS**: NWB files can live inside BIDS folder structure

**Funding crisis**: Primary NWB grant ends March 2026. The entire neurophysiology data-sharing infrastructure may become unmaintained.

**Opportunity**: zig-syrup can implement a lightweight NWB reader/writer that doesn't depend on the Python/HDF5 stack. Our Syrup serialization can serve as a real-time streaming complement to NWB's archival format.

### LSL: The Real-Time Standard

**Lab Streaming Layer** is the de facto real-time BCI middleware:
- Networked streaming + time synchronization
- Language bindings: C, C++, Python, MATLAB, Java, C#
- XDF recording format for offline analysis
- Got its reference paper in 2025 (Imaging Neuroscience, Kothe et al.)

**Integration path**: LSL uses TCP/UDP multicast. Our `tcp_transport.zig` + `message_frame.zig` can bridge LSL streams into OCapN/Syrup with GF(3) classification.

---

## Existing ASI BCI Skills Inventory

### Direct BCI Skills

| Skill | Trit | Capability | Languages |
|-------|------|-----------|-----------|
| **sheaf-cohomology-bci** | -1 | Cellular sheaves for multi-channel EEG consistency | Julia, Python |
| **reafference-corollary-discharge** | 0 | Von Holst behavioral verification, color prediction | Ruby, Python, Scheme |
| **qri-valence** | 0 | QRI Symmetry Theory of Valence, phenomenal fields | Julia, Python, Ruby |
| **cognitive-superposition** | 0 | Quantum measurement collapse for ASI reasoning | Rzk, Lean4, MLX, JAX, Julia |

### Capability & Transport Skills

| Skill | Trit | Capability | Languages |
|-------|------|-----------|-----------|
| **captp** | 0 | Capability Transfer Protocol, unforgeable references | Scheme, Ruby, JS |
| **guile-goblins-hoot** | +1 | Goblins actors + Hoot Scheme→WASM compiler | Scheme, WASM, JS |
| **hoot** | 0 | Scheme→WASM compiler, first-class continuations | Scheme→WASM, JS |
| **kos-firmware** | +1 | K-Scale robot OS, gRPC services, HAL abstraction | Rust, Python, C ABI |

### zig-syrup Existing Cross-Language Infrastructure

| Module | Type | What it does |
|--------|------|-------------|
| **goblins_ffi.zig** (320 LOC) | C ABI shared lib | 9 exported functions for Guile interop (SplitMix64, GF(3), did:gay, homotopy) |
| **spatial_propagator.zig** (28K) | C ABI shared lib | Terminal color assignment from macOS window topology |
| **stellogen/wasm_runtime.zig** | wasm32-freestanding | Stellogen star-fusion in browser/embedded |
| **terminal_wasm.zig** (172 LOC) | wasm32-freestanding | Terminal grid + Syrup framing in browser |
| **bim.zig** (12K) | Bytecode VM | 15 opcodes including `extern` for FFI escape |
| **bci_receiver.zig** (870 LOC) | Native module | Universal BCI receiver (nRF5340 firmware design) |
| **tapo_energy.zig** (680 LOC) | Native module | Energy monitor with GF(3) + KLAP v2 |
| **passport.zig** | Native module | Proof-of-brain identity (BandPowers, PhenomenalState, Fisher-Rao) |

---

## The Lifting Strategy: Don't Build a Hypervisor, Compose One

### Core Insight

Instead of writing firmware or a hypervisor from scratch, **use the WASM Component Model as the universal lifting layer**:

```
┌─────────────────────────────────────────────────────────────────┐
│                    zig-syrup ORCHESTRATOR                        │
│  (native Zig: GF(3), Syrup, propagators, ring buffers, SIMD)   │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────────────┐  │
│  │ Rust → WASM  │  │ JVM → WASM   │  │ Unison (network IO)  │  │
│  │              │  │              │  │                      │  │
│  │ • wasmtime   │  │ • GraalVM 25 │  │ • Abilities/effects  │  │
│  │ • wgpu       │  │ • Native Img │  │ • Content-addressed  │  │
│  │ • kos-fw     │  │ • FFM API    │  │ • Hash-based deps    │  │
│  │ • egui       │  │ • Kotlin/WAS │  │ • TCP socket bridge  │  │
│  └──────┬───────┘  └──────┬───────┘  └──────────┬───────────┘  │
│         │                 │                      │              │
│         ▼                 ▼                      ▼              │
│  ┌────────────────────────────────────────────────────────────┐ │
│  │           WASM Component Model (WIT interfaces)            │ │
│  │                                                            │ │
│  │  world bci-component {                                     │ │
│  │    import bci-reading: func() -> bci-reading               │ │
│  │    import gf3-classify: func(bands: band-powers) -> trit   │ │
│  │    export process-epoch: func(raw: list<f32>) -> reading   │ │
│  │  }                                                         │ │
│  └────────────────────────────────────────────────────────────┘ │
│         │                 │                      │              │
│         ▼                 ▼                      ▼              │
│  ┌────────────────────────────────────────────────────────────┐ │
│  │              OCapN/Syrup Transport Layer                    │ │
│  │  (capability-secure, auditable, GF(3)-conserved)           │ │
│  └────────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────┘
```

### Path 1: Rust Ecosystem Lifting (via WASM + C ABI)

**What we get**: wasmtime, wgpu, KOS firmware, egui, tungstenite, tokio

**How**:
1. Rust crates compile to `wasm32-wasip2` (Component Model target)
2. zig-syrup hosts via wasmtime C API (`libwasmtime.a`, 100% Cranelift)
3. WIT interfaces define the BCI contract
4. OR: Rust compiles to C ABI (`extern "C"`) and Zig links directly (already proven with goblins_ffi pattern)

**Key Rust BCI crates to lift**:
- `brainflow` — Universal BCI data acquisition (OpenBCI, Muse, Neurosity, etc.)
- `ndarray` — N-dimensional array processing
- `rustfft` — FFT for band power extraction
- `hdf5-rust` — NWB file I/O
- `rumqttc` — MQTT client (for Sparkplug B)
- `btleplug` — Cross-platform BLE (for Neural Band-style devices)

### Path 2: JVM Ecosystem Lifting (via GraalVM Native Image)

**What we get**: Entire Java/Kotlin/Scala ecosystem as native binaries

**How**:
1. GraalVM 25 (Jan 2026) compiles Java AOT to native executables
2. FFM API (Foreign Function & Memory, JEP 454) bridges Java ↔ native seamlessly
3. Java code calls zig-syrup's C ABI exports (goblins_ffi pattern)
4. OR: Java compiles to WASM via TeaVM/CheerpJ and runs in our WASM host
5. Mozilla.ai proved "Polyglot AI Agents: WASM Meets JVM" (Dec 2025)

**Key JVM assets to lift**:
- Apache Kafka clients (event streaming for BCI data)
- DL4J/DeepLearning4J (neural network inference on JVM)
- Clojure ecosystem (already connected via babashka skills)
- Kotlin Multiplatform (shared BCI logic across platforms)

### Path 3: Unison Lifting (via Network IO + Future FFI)

**What we get**: Content-addressed distributed computation with effect system

**Current state**: Unison 1.0 (Nov 2025) has NO FFI (GitHub #1404). Interop is via:
- TCP/UDP sockets (Unison's IO ability)
- HTTP services
- Future: WASM compilation target (discussed but not implemented)

**Integration strategy**:
1. zig-syrup runs OCapN/Syrup TCP listener (already have `tcp_transport.zig`)
2. Unison connects via TCP socket, sends/receives Syrup-encoded messages
3. Unison's ability system maps naturally to OCapN capabilities:
   - `Remote` ability → OCapN `deliver-only`
   - `Exception` ability → OCapN `abort`
   - `Stream` ability → OCapN trit stream
4. Content-addressed code hashes align with did:gay identity scheme

**Why Unison matters for BCI**:
- Effect system prevents accidental side effects in signal processing
- Content-addressed definitions = reproducible BCI pipelines
- Distributed runtime = multi-device BCI coordination without shared state
- Hash-based deps = no version conflicts in scientific software

### Path 4: Hoot/Goblins (Already Connected)

**What we get**: Capability-secure distributed actors with WASM portability

**Already exists in zig-syrup**:
- `goblins_ffi.zig` exports 9 C ABI functions Goblins can call
- Hoot compiles Scheme → WASM (zig-syrup can host the output)
- Promise pipelining reduces round-trips for distributed BCI

### Path 5: cWAMR — Hardware-Enforced Capability WASM (Future)

**CWAMR paper (Jul 2025)**: CHERI-based WebAssembly runtime with hardware-enforced capabilities.
- Runs on Arm Morello CHERI platform
- WASM modules get hardware pointer provenance and bounds
- Capability-sealed memory allocator, cWASI system interface
- **This is the endgame**: WASM components with hardware capability security

---

## Enrichment Plan for zig-syrup

### Phase 1: BCI Data Format Bridge (~800 LOC)

**File: `src/nwb_bridge.zig`**

```
NWB/HDF5 ←→ Syrup bridge:
  - Read NWB TimeSeries → BCIReading stream
  - Write BCIReading ring buffer → NWB export
  - Channel metadata mapping (electrode locations, impedances)

LSL bridge:
  - LSL inlet → tcp_transport.zig → GF(3) classifier → ring buffer
  - LSL outlet ← ring buffer → Syrup-framed trit stream
  - XDF file parser (offline analysis)

EDF/BDF parser:
  - Header parsing (patient info, recording info, signal specs)
  - Data block extraction → BandPowers per channel
  - GF(3) classification at read time
```

### Phase 2: WASM Component Host (~1,200 LOC)

**File: `src/wasm_host.zig`**

```
Embed wasmtime via C API (libwasmtime.a):
  - Component instantiation with WIT interfaces
  - Memory management: Zig allocator backs WASM linear memory
  - Capability attenuation: only expose OCapN-blessed imports
  - GF(3) conservation check on all WASM ↔ host boundary crossings

WIT interface: bci-component.wit
  - import: get-reading, classify-trit, get-baseline, fisher-rao-distance
  - export: process-epoch, configure-sensor, get-device-info
```

### Phase 3: Rust Crate Lifting (~600 LOC glue)

**File: `src/rust_bridge.zig`**

```
Link brainflow (C API) for universal BCI acquisition:
  - BoardShim → SensorConfig mapping
  - Real-time data → BandPowers extraction
  - Supports: OpenBCI, Muse, Neurosity Crown, BrainBit, etc.

Link btleplug (C API) for BLE scanning:
  - Discover Meta Neural Band, Nudge Zero, any GATT BCI device
  - Connect and stream characteristic notifications
  - Map vendor-specific GATT → standardized BCIReading
```

### Phase 4: Unison TCP Bridge (~400 LOC)

**File: `src/unison_bridge.zig`**

```
OCapN/Syrup TCP server specifically for Unison clients:
  - Handshake: exchange capability references
  - Stream: trit readings at configurable rate
  - RPC: configure sensors, start/stop calibration
  - Ability mapping: Remote → deliver-only, Exception → abort
```

### Phase 5: Meta sEMG Compatibility (~500 LOC)

**File: `src/semg_decoder.zig`**

```
sEMG signal processing matching Meta's CTRL-labs approach:
  - 16-channel sEMG at wrist (SPI2 on nRF5340)
  - Motor unit action potential (MUAP) extraction
  - Gesture classification → GF(3) trit mapping:
    +1 (GENERATOR): Active gesture (tap, swipe, pinch)
     0 (ERGODIC):   Resting hand position
    -1 (VALIDATOR): Intentional release/inhibition
  - Generic model support (no per-user calibration, a la Meta)
  - BLE GATT output compatible with both our UUID scheme and standard HID
```

---

## GF(3) Conservation Across All Lifted Ecosystems

The conservation law Σ trit = 0 must hold at every boundary crossing:

```
Rust WASM component: trit_in + trit_process + trit_out = 0
JVM native call:     trit_request + trit_compute + trit_response = 0
Unison TCP message:  trit_send + trit_transform + trit_receive = 0
Goblins actor:       trit_promise + trit_resolve + trit_fulfill = 0
```

Every cross-ecosystem message is Syrup-encoded with a trit field. The orchestrator verifies conservation before forwarding. Violations trigger recalibration (same as `ReadingRing.needsRecalibration()` in `bci_receiver.zig`).

---

## Summary: What We Don't Build

| Don't Build | Instead Use | Why |
|-------------|-------------|-----|
| Custom hypervisor | wasmtime + WASM Component Model | Bytecode Alliance maintains it, Cranelift JIT, capability-secure |
| Custom BLE stack | btleplug (Rust) → C ABI or WASM | Cross-platform, maintained, supports all major OSes |
| Custom BCI acquisition | brainflow (C API) | Supports 20+ BCI devices out of the box |
| Custom ML inference | ONNX Runtime or DL4J via WASM | Industry-standard, GPU-capable |
| Custom data format | NWB + BIDS + LSL (bridge to Syrup) | Community standard, 300+ public datasets |
| Custom distributed runtime | Goblins/Hoot or Unison | Capability-secure actors with WASM portability |
| Custom firmware RTOS | Zephyr RTOS (nRF5340 supported) | Nordic maintains it, BLE stack included |

## What We DO Build (in zig-syrup)

1. **The GF(3) conservation layer** — every signal, every boundary, every epoch
2. **The Syrup serialization** — canonical OCapN encoding for all data
3. **The WASM host** — embed wasmtime, expose capability-attenuated imports
4. **The data format bridges** — NWB/LSL/EDF ↔ Syrup ↔ BCIReading
5. **The nRF5340 firmware** — universal receiver with open BLE GATT
6. **The ring buffers** — zero-allocation hot paths for real-time processing
7. **The Fisher-Rao metric** — phenomenal state distance, already in passport.zig

Everything else gets lifted from existing ecosystems through WASM components, C ABI, or TCP/Syrup bridges. **18 eyes audit the boundaries, not the internals.**
