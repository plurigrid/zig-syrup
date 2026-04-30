# C/C++ Library Zig Replaceability Triage

Analysis of 120 C/C++ repos starred by bmorphism on GitHub, classified by
whether Zig can replace them, must use them as-is, or the question resists
resolution after multiple deep reads.

---

## TIER 1: REPLACEABLE BY ZIG

These are pure C/C++ with minimal deps where Zig's comptime, safety,
cross-compile, and SIMD support yield concrete wins.

| Repo | Stars | Why replaceable |
|------|-------|-----------------|
| **karpathy/llama2.c** | 19.5k | Single-file pure C inference. Already exists as a pedagogical exercise. Zig port gains safety + comptime quantization tables. |
| **trholding/llama2.c** | 1.5k | Fork of above with extensions. Same reasoning. |
| **antimatter15/alpaca.cpp** | 10k | Thin wrapper around llama.cpp inference. Replaceable subset. |
| **ashvardanian/StringZilla** | 3.4k | SIMD string ops. Zig has first-class `@Vector` with identical ISA coverage. Comptime dispatch > runtime dispatch. |
| **davidesantangelo/krep** | 451 | SIMD text search (Boyer-Moore, KMP, Aho-Corasick). Pure C, zero deps. Direct Zig SIMD port. |
| **clausecker/rabinkarp** | 10 | SIMD-accelerated rolling hash. Tiny, self-contained. Zig `@Vector` is a better substrate. |
| **uber/h3** | 6.2k | Pure computational geometry in C, only depends on `math.h`. Zig comptime could precompute icosahedron lookup tables. ~30 source files. |
| **nmslib/hnswlib** | 5.2k | Header-only C++11, zero deps. HNSW graph + SIMD distance funcs. Zig port gains safety + `@Vector` + comptime parameter specialization. |
| **unum-cloud/USearch** | 4k | Similar to hnswlib but with more backends. Core algorithm is replaceable; CUDA backend is not. Partial replacement. |
| **janet-lang/janet** | 4.2k | Self-contained bytecode VM in C99, single-file amalgamation. Zig gains safety for GC, comptime for opcode dispatch, and keeps embeddability. |
| **jart/sectorlisp** | 1.5k | 512-byte meta-circular Lisp in x86 asm/C. Zig can target bare metal with same binary size via `@export` + custom linker scripts. Pedagogical port is valuable. |
| **cnlohr/sfhip** | 26 | Single-file TCP/IP stack for embedded. Pure C, zero deps. Zig is strictly better here (safety + comptime config). |
| **rdentato/gerku** | 10 | Concatenative combinator interpreter. Tiny pure C. Trivial port. |
| **andrewbuss/crisp** | 9 | Functional language interpreter with Boehm GC. Zig allocator model replaces GC cleanly. |
| **QuantumVillage/micro-quantum** | 21 | Embedded quantum sim for RP2040. Pure C + Pico SDK. Zig has first-class ARM/RP2040 support. |
| **hannorein/rebound** | 1k | N-body simulator. Pure C with optional OpenGL viz. Core integrator is pure math, ideal for Zig. |
| **JuliaMath/openlibm** | 606 | Portable math library (libm replacement). Pure C, platform-specific asm. Zig could provide comptime-specialized math. |
| **google/pebble** | 5k | Pebble OS. Historical interest. The embedded C firmware patterns are exactly Zig's sweet spot. |
| **Munawwar/launcher** | 34 | Cross-platform binary launcher. Tiny C. Zig cross-compile makes this obsolete. |

**Count: 19 repos**

---

## TIER 2: USE AS-IS (practical FFI / ecosystem lock-in)

These depend on irreplaceable ecosystems (CUDA, LLVM, kernel ABIs, massive
C++ template codebases) or are specifications, not implementations.

### GPU/CUDA locked

| Repo | Stars | Why use as-is |
|------|-------|---------------|
| **ggml-org/llama.cpp** | 107k | 500+ contributors, Metal/CUDA/Vulkan/SYCL backends. The optimization surface is too large and too fast-moving. Use via C API. |
| **ggml-org/whisper.cpp** | 49k | Same GGML ecosystem. Use C API. |
| **nomic-ai/gpt4all** | 77k | Wraps llama.cpp. Use the wrapper. |
| **ml-explore/mlx** | 25.8k | Apple's ML framework. Metal compute shaders + Objective-C++ runtime. Cannot be separated from Apple ecosystem. |
| **ml-explore/mlx-c** | 199 | C API for MLX. This IS the FFI surface you'd call from Zig. |
| **ml-explore/mlx-data** | 472 | Data loading for MLX. Same ecosystem lock. |
| **NVIDIA/open-gpu-kernel-modules** | 17k | Literal GPU kernel modules. Cannot exist outside NVIDIA's driver ABI. |
| **NVIDIA/FasterTransformer** | 6.4k | CUDA transformer kernels. |
| **NVIDIA/cuda-quantum** | 1k | CUDA quantum computing. |
| **chrxh/alien** | 5.4k | Artificial life sim. 100% CUDA compute core. Simulation model cannot be separated from GPU backend. |
| **ProjectPhysX/FluidX3D** | 5k | Lattice Boltzmann CFD. OpenCL/CUDA compute. |
| **lattice/quda** | 349 | Lattice QCD. CUDA + MPI. |
| **pytorch/xla** | 2.8k | PyTorch XLA bridge. |
| **shacklettbp/madrona** | 490 | GPU-accelerated game engine for RL. |

### LLVM locked

| Repo | Stars | Why use as-is |
|------|-------|---------------|
| **jank-lang/jank** | 3.2k | Clojure on LLVM. Uses `llvm::IRBuilder` directly + `clang::Interpreter` for JIT. The entire compilation backend IS LLVM. |
| **llvm/circt** | 2.1k | Circuit IR on LLVM/MLIR. |
| **seahorn/clam** | 287 | LLVM bitcode static analyzer. |
| **GaloisInc/yapall** | 69 | LLVM pointer analysis (actually Rust+LLVM). |
| **leaningtech/cheerp-compiler** | 356 | C++ to WebAssembly via LLVM. |
| **lean-dojo/LeanCopilot** | 1.3k | LLM for Lean theorem prover. Lean's C++ runtime. |
| **bloomberg/crane** | 139 | Rocq extraction to functional code. |

### Kernel/OS ABI locked

| Repo | Stars | Why use as-is |
|------|-------|---------------|
| **ExistentialAudio/BlackHole** | 18.9k | macOS kernel audio driver (IOKit). Must be Objective-C/C for kext/DriverKit. |
| **containers/crun** | 3.9k | OCI container runtime. Linux cgroup/namespace syscalls. Could technically be Zig but no one would trust it. |
| **henrypp/simplewall** | 8.4k | Windows Filtering Platform. Win32 API locked. |
| **KnightChaser/ebpftracer** | 21 | eBPF programs MUST be clang-compiled for BPF target. |
| **nilfs-dev/nilfs2-module** | 16 | Linux kernel module. Must be C for kernel ABI. |
| **contiki-ng/contiki-ng** | 1.5k | IoT OS with its own build system and toolchain. |
| **au-ts/sddf** | 52 | seL4 device driver framework. Microkernel ABI locked. |
| **svanderburg/disnix** | 301 | Nix-based deployment. Nix ecosystem. |

### Massive ecosystem / specification

| Repo | Stars | Why use as-is |
|------|-------|---------------|
| **simdjson/simdjson** | 23.7k | 8 SIMD backends, runtime dispatch, 2-stage parse, UTF-8 validation. The *algorithmic* innovations (on-demand parsing, free padding) are inseparable from the C++ template dispatch. Use via C API. |
| **simdutf/simdutf** | 1.8k | Unicode transcoding with SIMD. Same architecture as simdjson. Use as-is. |
| **wolfpld/tracy** | 15.7k | Frame profiler. C++ instrumentation macros + native GUI. Use C API. |
| **FreeCAD/FreeCAD** | 30.7k | Full CAD system. OpenCASCADE dependency. |
| **WasmEdge/WasmEdge** | 10.6k | Wasm runtime. Massive C++ codebase with LLVM AOT. |
| **bytecodealliance/wasm-micro-runtime** | 5.9k | Lighter Wasm runtime but still large. AOT compiler depends on LLVM. Interpreter-only mode COULD be Zig'd. |
| **kuzudb/kuzu** | 3.9k | Graph database. 200k+ LOC C++. |
| **duckdb/duckdb-wasm** | 2k | DuckDB compiled to Wasm. Use DuckDB's C API. |
| **duckdb/duckdb-spatial** | 676 | DuckDB extension. DuckDB extension API is C++. |
| **duckdb/duckdb-vss** | 252 | DuckDB vector search extension. |
| **opencog/atomspace** | 966 | Hypergraph DB. 36k commits, Guile Scheme embedded. |
| **risc0/risc0** | 2.1k | ZK proofs on RISC-V. Rust + CUDA. |
| **data61/MP-SPDZ** | 1.1k | Multi-party computation framework. |
| **microsoft/CCF** | 857 | Confidential computing framework. SGX/TDX locked. |
| **contour-terminal/contour** | 2.9k | Terminal emulator. Qt/vtpty C++ GUI framework. |
| **vectorgraphics/asymptote** | 667 | TeX vector graphics language. TeX ecosystem. |
| **modelica/fmi-standard** | 338 | FMI *specification* (C headers). Standard, not code. |
| **sogaiu/tree-sitter-clojure** | 184 | Auto-generated by tree-sitter. Replacing generated C makes no sense. |
| **google/silifuzz** | 414 | Google internal (Bazel + Abseil). |
| **google-deepmind/gemini_icpc2025** | 172 | Contest solutions. No reuse value. |
| **magenta/ddsp-vst** | 816 | Archived. JUCE + TFLite. |
| **hgarrereyn/GraphFuzz** | 274 | libFuzzer + protobuf codegen. |
| **google/s2geometry** | 2.6k | S2 spherical geometry. 100k+ LOC C++, Abseil dependency. |
| **marella/ctransformers** | 1.9k | Python bindings for llama.cpp. Just use llama.cpp directly. |
| **nomic-ai/pygpt4all** | 1k | Python bindings. Same reasoning. |
| **BogdanTheGeek/semihost-ip** | 944 | SWD protocol. ARM debug hardware specific. |

**Count: ~55 repos**

---

## TIER 3: WORLD-GENERATINGLY TOO HARD TO TELL

These resist classification after multiple deep reads. The ambiguity is
fundamental, not due to lack of information.

### 1. `jart/cosmopolitan` (20.8k stars)

**The paradox:** Cosmopolitan IS a C library whose purpose is to make C
portable. Zig already cross-compiles to every target Cosmopolitan supports.
So you'd think: "replace it."

But the APE (Actually Portable Executable) binary format is a polyglot
trick — a single file that is simultaneously a valid ELF, PE, Mach-O, and
shell script. Zig's cross-compilation produces *separate* binaries per
target. Cosmopolitan produces *one binary* that runs everywhere.

**Why it resists:** The value is not in the C code quality but in the
binary format hack. Zig could theoretically emit APE binaries via a custom
linker script, but no one has done it, and the `ape.S` bootloader is
inherently x86 assembly. The `zig-cosmo` project (using cosmocc as Zig's
CC) shows they're complementary, not replaceable.

**Verdict:** Neither replaceable nor use-as-is. They occupy different
dimensions of "portability."

---

### 2. `mozilla-ai/llamafile` (24.3k stars)

**The paradox:** llamafile = llama.cpp + cosmopolitan. The LLM inference
is clearly USE_AS_IS (llama.cpp). But llamafile's *packaging innovation*
— a single file that IS the model AND the server AND the runtime — is
a systems-level achievement that Zig could theoretically replicate.

A Zig-native llamafile would mean: Zig compiles the inference engine,
embeds the model weights, and produces a single static binary. Zig CAN
do this (static linking + `@embedFile`). But the inference engine itself
(GGML) is 100k+ LOC of hand-optimized SIMD/Metal/CUDA code.

**Why it resists:** The packaging layer is replaceable. The compute layer
is not. They're fused in llamafile. You can't replace half.

---

### 3. `arximboldi/ewig` (550 stars)

**The paradox:** ewig is a "Didactic Ersatz Emacs" built on immer
(immutable data structures) and lager (Elm architecture in C++). The
*architecture* (unidirectional data flow, immutable state, pure update
functions) is beautiful and maps perfectly to Zig's comptime + tagged
unions. Our own `emerge.zig` in zig-syrup is essentially this.

But the *implementation* uses C++ template metaprogramming for variant
dispatch (`scelta::match`), persistent data structures (immer's RRB
trees with structural sharing), and the lager store's type-level state
machine. These are not just "C++ features" — they're the research
contributions of the immer/lager author (Juan Puente).

**Why it resists:** The architecture screams "rewrite in Zig." The
data structures (RRB trees with reference-counted structural sharing)
are a PhD-level implementation challenge in any language. Zig lacks
the template metaprogramming needed for the type-safe variant dispatch
that makes the architecture elegant. You'd need a different elegance.

---

### 4. `simdjson/simdjson` (23.7k stars)

**Placed in USE_AS_IS above, but the truth is more nuanced.**

simdjson's *algorithmic innovations* (two-stage parsing, on-demand API,
free padding exploitation, UTF-8 validation in <1 instruction/byte) are
language-independent ideas. Zig's `@Vector` provides the same SIMD
coverage. In theory, a Zig port gains comptime-specialized parsers per
schema.

But simdjson has **8 architecture backends** with runtime dispatch, years
of micro-benchmarking, and a community that files bugs for 0.1%
regressions. The performance engineering effort is irreplaceable.

**Why it resists:** The *algorithm* is replaceable. The *engineering
culture* is not. A Zig simdjson that's 5% slower would be a failure.
A Zig simdjson that's 5% faster would be a miracle requiring the same
multi-year effort.

---

### 5. `pizlonator/yosh` (40 stars)

**The paradox:** yosh is an LLM-enabled fork of bash by Filip Pizlo
(WebKit JIT compiler architect). It's "just a shell" — but it's a shell
that integrates LLM inference into the command loop itself.

The C code is bash (100k+ LOC, 30+ years of POSIX edge cases). Clearly
not replaceable. But the *LLM integration pattern* — treating the shell
as an agent with tool-use — is a new primitive that could be built from
scratch in Zig with a different shell (or no shell at all).

**Why it resists:** The interesting part isn't the C code. It's the
*concept* of shell-as-agent. Whether that concept needs bash's exact
POSIX compliance or could work with a simpler shell is an open question.

---

### 6. `dankamongmen/notcurses` (4.5k stars)

**We already have this partially migrated in zig-syrup** (translate-C
header, `@import("c")`). But the question of full replacement is deep.

notcurses provides: sixel/kitty graphics protocol, TUI widgets, video
playback in terminal, pixel-perfect rendering, ffmpeg integration. The
*terminal protocol handling* could be Zig. The *ffmpeg/media pipeline*
cannot. The *TUI widget library* is in the gray zone — ewig-style Zig
is possible but would be a multi-year effort to reach feature parity.

**Why it resists:** notcurses is simultaneously a thin terminal protocol
layer (replaceable) and a full media framework (not replaceable). The
two are architecturally entangled. Our `notcurses_backend.zig` already
lives in the right place: using notcurses via FFI while building higher
abstractions in Zig.

---

### 7. `greatscottgadgets/hackrf` (7.8k stars)

**The paradox:** hackrf is an SDR (software-defined radio) platform. The
firmware is C for the LPC4320 microcontroller. The host library
(`libhackrf`) is pure C with libusb dependency.

Zig has first-class ARM embedded support. The firmware COULD be Zig'd.
But libusb is the universal USB abstraction, and every SDR tool (GNU
Radio, SDR#, etc.) links against `libhackrf.so`. Replacing the library
breaks the ecosystem. Replacing the firmware is possible but the
existing firmware is battle-tested on specific RF timing constraints.

**Why it resists:** Firmware → possible but risky (RF timing). Host
library → breaks ecosystem. The right answer depends on whether you're
building a new SDR stack or extending the existing one.

---

### 8. `google/werm` (59 stars)

**Archived but conceptually alive.** A terminal multiplexer that renders
via Chrome/WebSocket. The concept of "terminal as web view" is being
realized by Ghostty (Zig!) and rio (Rust). But werm's specific approach
— using Chrome's rendering engine — can't be replicated without Chrome.

**Why it resists:** The concept migrated to other implementations. The
specific Chrome coupling is dead. It's a ghost that already reincarnated.

---

## SUMMARY STATISTICS

| Classification | Count |
|----------------|-------|
| **Replaceable by Zig** | 19 |
| **Use as-is (FFI)** | ~55 |
| **Too hard to tell** | 8 |
| **Remaining (low signal)** | ~38 (contest solutions, archived, bindings-only, etc.) |

## KEY INSIGHT

The "too hard to tell" category has a signature: **the interesting
contribution is at a different level of abstraction than the code.**

- Cosmopolitan's contribution is a *binary format*, not a C library.
- llamafile's contribution is *packaging*, not inference.
- ewig's contribution is an *architecture*, not a C++ program.
- simdjson's contribution is *years of benchmarking culture*, not SIMD code.
- yosh's contribution is a *concept* (shell-as-agent), not bash modifications.
- notcurses straddles *thin protocol* and *thick framework*.
- hackrf straddles *firmware timing* and *ecosystem compatibility*.

In every case, the Zig question isn't "can this C code be rewritten?" but
"does the rewrite preserve the thing that actually matters?" And that
question can't be answered by reading code — only by understanding what
the code *means* in its ecosystem.

## MAKE EXAMPLES (use-as-is integration patterns)

For the USE_AS_IS libraries most relevant to zig-syrup:

```zig
// 1. llama.cpp via C API (already done in llamafile_reward.zig via HTTP)
//    For tighter integration: link against libllama.so
const llama = @cImport({ @cInclude("llama.h"); });
// or in 0.16+:
const llama = @import("llama_c"); // via addTranslateC

// 2. notcurses (already done)
const c = @import("c"); // translate-C from build.zig

// 3. simdjson — use the C API (simdjson provides ondemand C API)
const simdjson = @import("simdjson_c");
const doc = simdjson.simdjson_parse(json_ptr, json_len);

// 4. tracy profiler — include tracy header, call macros from Zig
const tracy = @import("tracy_c");
tracy.___tracy_emit_zone_begin(...);

// 5. BlackHole — no code integration, it's a kernel driver.
//    Use Core Audio API to route audio through BlackHole device.
```
