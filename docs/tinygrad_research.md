# tinygrad Research Summary for Basin GPU Compute

## 1. Architecture & Design Philosophy

### Core Philosophy
tinygrad occupies a deliberate middle ground between micrograd (100-line toy) and PyTorch/JAX (millions of lines). As of Dec 2025, the **entire codebase is ~18,935 lines** (excluding tests), compared to:
- PyTorch: ~3,300k lines
- MLIR: ~950k lines  
- JAX: ~400k lines

George Hotz's thesis: **"98% of lines of software are workarounds for issues in other parts of the codebase."** tinygrad aims to express the fundamental compute problem with minimal abstraction layers.

### Four-Piece Architecture
1. **Frontend** — PyTorch-like Tensor API. Everything in `Tensor` is syntactic sugar around constructing a graph of `UOps`.
2. **Scheduler** — Breaks the compute graph into kernels. Converts UOp graph → list of `ExecItem` (one ExecItem = one GPU kernel). Handles kernel fusion.
3. **Lowering Engine** — Converts ASTs into code that runs on the accelerator. UOps IR → backend-specific code (CUDA PTX, Metal shaders, OpenCL, etc.)
4. **Execution Engine** — Runs that code on hardware. Manages buffers, dispatches kernels.

### UOps IR — The Key Abstraction
Everything reduces to just **3 OpTypes**:
- **ElementwiseOps** — Unary, Binary, Ternary (SQRT, LOG2, ADD, MUL, WHERE)
- **ReduceOps** — SUM, MAX (return smaller tensor)
- **MovementOps** — RESHAPE, PERMUTE, EXPAND (virtual, zero-copy via ShapeTracker)

There are no explicit CONV or MATMUL ops. Matrix multiply = reshape + broadcast + elementwise multiply + reduce. The compiler is responsible for fusing these into efficient kernels.

UOps form a DAG. Tensors are lazy — no computation until `.realize()` is called. The UOp graph captures the full computation lazily, then the scheduler breaks it into kernels.

### Lazy Evaluation & Buffer Management
- Tensors are thin wrappers over UOps
- `Buffer` objects represent allocated GPU memory
- Deduplication: if two tensors compute the same thing, they share the same UOp and realized buffer
- `BUFFER_VIEW` enables zero-copy views into existing buffers
- Memory allocation happens only at `.realize()` time

---

## 2. Current Capabilities (as of early 2026)

### Runtime Backends
tinygrad has an impressive array of backends:

| Runtime | Target | Notes |
|---------|--------|-------|
| **NV** | NVIDIA GPUs (Ampere/Ada/Blackwell) | nvrtc or PTX codegen. Has PCI direct interface. |
| **AMD** | AMD GPUs (RDNA2+) | LLVM or HIP/COMGR. Has KFD/PCI/USB interfaces. |
| **QCOM** | Qualcomm 6xx GPUs | Mobile inference |
| **METAL** | Apple M1+ | Metal 3.0+ for bfloat |
| **CUDA** | NVIDIA (via CUDA toolkit) | nvrtc or PTX |
| **CL** | OpenCL 2.0 devices | Generic fallback |
| **CPU** | x86/ARM | Clang JIT or LLVM IR |
| **WEBGPU** | Dawn engine | Browser/portable GPU |
| **NIR** (new Oct 2025) | Mesa NIR → NVK, LLVMpipe | Open-source NVIDIA via Vulkan |

### "Sovereign Stack" Milestone
As of Jan 2025, tinygrad is nearing a **completely sovereign stack for AMD GPUs**:
- Own driver (~12,000 lines)
- Own runtime
- Own libraries
- Own emulator
- Working to remove LLVM dependency entirely (RDNA3 assembler)
- Goal: 0 dependencies (except pure Python) to drive AMD GPUs

They also maintain a fork of **open-gpu-kernel-modules** for NVIDIA with P2P support.

### Production Deployments
- **comma.ai openpilot** — Self-driving car software. tinygrad powers production neural networks.
- **LLaMA 65B** — Can run Meta's LLaMA model
- **Stable Diffusion** — Full text-to-image pipeline
- **MLPerf Training** — tinybox appeared on MLPerf Training 4.0
- **AMD Contract** — Contract with AMD to train LLaMA 405B as fast as NVIDIA (MI350X on MLPerf)

### tinybox Hardware
| Spec | Red (AMD) | Green (NVIDIA) | Green v2 |
|------|-----------|----------------|----------|
| GPUs | 6× RX 7900 XTX | 6× RTX 4090 | 4× RTX 5090 |
| TFLOPS | 738 FP16 | 991 FP16 | — |
| GPU RAM | 144 GB | 144 GB | — |
| GPU BW | 5760 GB/s | 6050 GB/s | — |
| Revenue | ~$2M/year from hardware sales |

---

## 3. Performance Characteristics

### vs PyTorch/JAX
- George Hotz claims: **"outperforms PyTorch on many workloads"** (Dec 2025)
- The fundamental bet is that search-based optimization over a simple IR will beat hand-tuned kernels
- For common NN operations, tinygrad achieves competitive performance through aggressive kernel fusion
- The scheduler merges operations that can share kernels, reducing memory bandwidth overhead

### Key Performance Strategy
1. **Expose scheduling as a search problem** — Neural network execution is not data-dependent, making it amenable to search
2. **Burn compute on optimization** — Use LLMs, SAT solvers, RL to find optimal schedules
3. **Unified scheduling across scales** — Multi-machine, multi-GPU, multi-SM, multi-ALU all formulated as the same problem

### Current Limitations on Performance
- Not yet matching cuBLAS for all GEMM shapes
- Multi-GPU/multi-node scaling still behind NCCL
- Large model training (GPT-5 scale) not yet demonstrated
- Some kernel fusion heuristics still being improved

---

## 4. Interop Possibilities with Zig/Rust

### Current State: Python-First
tinygrad is fundamentally a **Python library**. It does NOT expose a C API. The runtime backends generate and execute GPU kernels (CUDA, Metal, OpenCL, etc.) but the orchestration layer is Python.

### Interop Options

#### Option A: Python → Zig/Rust via subprocess/IPC
- Run tinygrad as a Python process
- Communicate via stdin/stdout (JSON-RPC), shared memory, or sockets
- **Pro**: No modification to tinygrad needed
- **Con**: Python GIL overhead, IPC latency, extra process management

#### Option B: Extract tinygrad's codegen, rewrite runtime in Zig
- tinygrad's compiler outputs CUDA PTX, Metal shaders, OpenCL kernels
- These are strings of GPU code that any runtime can dispatch
- Basin could use tinygrad's scheduler+compiler as a build step, then dispatch kernels from Zig
- **Pro**: Zero Python at runtime. Kernel quality matches tinygrad.
- **Con**: Significant integration work. Must re-implement buffer management and dispatch.

#### Option C: Rust crate "tinygrad" (exists but limited)
- A Rust crate `tinygrad v0.1.0` exists on crates.io but it's a **community reimplementation** (ndarray-based), NOT a binding to the real tinygrad
- It's educational/toy quality, not production-grade
- **Not recommended** as a real integration path

#### Option D: Use tinygrad's generated kernels via CUDA/Metal/OpenCL drivers directly
- tinygrad can dump compiled kernels (DEBUG=4 shows full kernel code)
- Basin could pre-compile models with tinygrad, serialize the kernel schedule, and replay from Zig
- This is essentially "ahead-of-time compilation" using tinygrad as the compiler
- **Pro**: Clean separation. Zig runtime dispatches pre-compiled kernels.
- **Con**: Model changes require re-running tinygrad compiler.

#### Option E: Call Python from Zig via CPython embedding
- Zig can call C, and CPython has a C API
- Embed a Python interpreter in the Zig process
- **Pro**: Full access to tinygrad from Zig
- **Con**: Python runtime dependency, GIL, complexity

---

## 5. Concrete Benefits for Basin's GPU Compute Stack

### What tinygrad gets right that Basin could learn from:

1. **Minimal IR Design** — UOps prove that ~20 operations suffice to express all of deep learning. Basin's Magma effect system could adopt a similarly minimal IR for GPU kernels.

2. **ShapeTracker for Zero-Copy** — tinygrad's `ShapeTracker` tracks reshapes/permutes/expands without copying data. This is a powerful abstraction for Basin's plate system.

3. **Lazy Evaluation + Graph Scheduling** — Build a full compute graph, then optimize globally before execution. Basin could use lazy buffer patterns in its GPU compute.

4. **Multi-Backend from Day 1** — tinygrad's architecture makes adding new backends relatively easy. The same graph compiles to CUDA, Metal, OpenCL, Vulkan, WebGPU. Basin could adopt this approach.

5. **Kernel Fusion Strategy** — Automatic fusion of elementwise ops into single kernels reduces memory bandwidth pressure. Critical for inference performance.

6. **Sovereign Stack Philosophy** — Removing dependency on vendor SDKs (CUDA toolkit, ROCm). Basin's Zig philosophy aligns well with self-contained, minimal dependencies.

### What Basin could practically use:

| Approach | Effort | Benefit | Risk |
|----------|--------|---------|------|
| Use tinygrad as model compiler (pre-compile kernels, dispatch from Zig) | Medium | High kernel quality, no Python at runtime | Model compilation requires Python |
| Port UOps IR to Zig | High | Full sovereignty, no Python | Large engineering effort |
| Use tinygrad runtime backends as reference for Basin's own backends | Low | Learn from proven multi-backend patterns | Only informational |
| Embed Python+tinygrad for training, Zig for inference | Medium | Leverage tinygrad's training stack | Python dependency for training |

---

## 6. Risks and Tradeoffs vs JAX/PyTorch

### Advantages of tinygrad
- **Simplicity**: 18,935 lines vs millions. Entire stack is auditable.
- **No vendor lock-in**: Own drivers, runtimes, assemblers.
- **Speed of development**: 6-person team iterating fast.
- **Production proven**: Running in comma.ai openpilot vehicles.
- **Open source**: MIT license. Full transparency.

### Risks of adopting tinygrad
- **Small team/bus factor**: 6 people. What if George Hotz moves on?
- **Ecosystem**: PyTorch has HuggingFace, Lightning, TorchServe. tinygrad has minimal ecosystem.
- **Model zoo**: Most models are published as PyTorch checkpoints. tinygrad can load some but not all formats.
- **Distributed training**: NCCL/Gloo alternatives not yet mature in tinygrad.
- **Enterprise support**: No commercial support. Discord + GitHub is the support model.
- **Python-only**: No C API means FFI from Zig/Rust is non-trivial.
- **Maturity**: Some scheduler bugs still being fixed (e.g., issue #12617 on intermediate value corruption).

### JAX Advantages tinygrad Doesn't Match (Yet)
- XLA compiler for TPUs
- Proven at Google scale (PaLM, Gemini)
- JAX ecosystem (Flax, Haiku, Optax)
- Multi-host multi-GPU scaling via pjit
- Robust numerical stability infrastructure

### PyTorch Advantages tinygrad Doesn't Match (Yet)
- Massive model zoo and community
- torch.compile (Inductor) is closing the speed gap
- TorchScript/ExecuTorch for edge deployment
- Commercial support from Meta + ecosystem companies

---

## 7. Recommendation for Basin

### Best Path: "tinygrad-inspired" approach

Rather than directly depending on tinygrad (which is Python-only), Basin should:

1. **Study tinygrad's UOps IR** — Adopt a similarly minimal operation set for Basin's GPU compute DSL. The ~20 ops that cover all of deep learning are well-documented in tinygrad's source.

2. **Implement lazy graph + scheduler in Zig** — tinygrad proves this can be done in ~5,000 lines. Basin's Zig codebase is well-positioned to implement a similar lazy tensor + kernel fusion pipeline natively.

3. **Use tinygrad as a reference compiler** — When building Basin's GPU backends (CUDA, Metal, Vulkan), reference tinygrad's codegen for each backend. Their code is clean and well-documented.

4. **Pre-compile models with tinygrad, dispatch from Zig** — For immediate production use, run `tinygrad` offline to compile model graphs into GPU kernels. Serialize the kernel schedule + compiled GPU code. Load and dispatch from Basin's Zig runtime. Zero Python dependency at runtime.

5. **Contribute to tinygrad's C API** — If Basin wants direct integration, proposing a C API for tinygrad's runtime (buffer alloc, kernel dispatch, schedule execution) would benefit both projects.

---

## Sources
- George Hotz, "Five years of tinygrad" (Dec 29, 2025): https://geohot.github.io//blog/jekyll/update/2025/12/29/five-years-of-tinygrad.html
- George Hotz, "Can tinygrad win?" (Jul 6, 2025): https://geohot.github.io/blog/jekyll/update/2025/07/06/can-tinygrad-win.html
- tinygrad docs (developer intro): https://docs.tinygrad.org/developer/developer/
- tinygrad docs (runtimes): https://docs.tinygrad.org/runtime/
- tinygrad docs (tinybox): https://docs.tinygrad.org/tinybox/
- Phoronix, "Tiny Corp Nearing Sovereign Stack" (Jan 2025): https://www.phoronix.com/news/Tiny-Sovereign-Stack-AMD-Close
- Phoronix, "Tinygrad Mesa NIR Backend" (Oct 2025): https://www.phoronix.com/news/Tinygrad-Mesa-NIR-Backend
- BrightCoding, "tinygrad: Ultra-Minimal DL Library" (Sep 2025): https://blog.brightcoding.dev/2025/09/08/tinygrad-the-ultra-minimal-deep-learning-library-that-runs-llama-and-stable-diffusion
- tinygrad GitHub: https://github.com/tinygrad/tinygrad
- tinygrad.org: https://tinygrad.org/
