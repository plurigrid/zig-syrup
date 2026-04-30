# Zig-Native GGUF Inference Gap Assessment

Date: 2026-04-29

## Existing Zig LLM/GGUF Projects

### Tier 1: Production-Grade (can run gemma4 Q4_K_M today)

| Project | URL | Stars | Maturity | Notes |
|---------|-----|-------|----------|-------|
| **ZINC** | https://github.com/zolotukhin/zinc | 355 | **Production** | Full Zig inference engine with Vulkan (RDNA3/4) + Metal backends. **Explicitly supports Gemma 4 31B Q4_K_M** and Gemma 4 26B-A4B Q4_K_M. 1,161 commits, 3 contributors, actively developed (commits today). Zig 0.15.2. ~35 tok/s decode on M4 Max for Qwen 35B. |
| **igllama** | https://github.com/bkataru/igllama | — | **Functional** | Zig CLI wrapping llama.cpp via llama.cpp.zig bindings. Runs Q4_K_M GGUFs. Not Zig-native — uses llama.cpp as submodule. |
| **ziggy-llm** | https://github.com/Alex188dot/ziggy-llm | — | **Early** | Mac-first Zig GGUF engine with Metal. Claims "fastest Zig GGUF inference on Apple Silicon." April 2026 project. Narrow model support. |

### Tier 2: Educational / Partial

| Project | URL | Stars | Maturity | Notes |
|---------|-----|-------|----------|-------|
| **cgbur/llama2.zig** | https://github.com/cgbur/llama2.zig | 211 | **Archived** | Port of llama2.c. Pure Zig, SIMD matmul. Only runs llama2 .bin format, NOT GGUF. Last commit Nov 2024. |
| **clebert/llama2.zig** | https://github.com/clebert/llama2.zig | 48 | **Archived** | Another llama2.c port. Multi-file, clean code. NOT GGUF. |
| **zigformer** | https://github.com/forKernels/zigformer | — | **Educational** | Pure Zig transformer with training + inference. Custom format, NOT GGUF. |
| **zig_gpt2** | https://github.com/EugenHotaj/zig_gpt2 | — | **Archived** | GPT-2 inference in Zig. Uses BLAS (Accelerate/OpenBLAS). Custom format. |
| **purai** | https://github.com/waterblower/purai | 1 | **Embryonic** | Solo dev attacking quantization first. Has Q8_0 in Zig but pulled in ggml C/C++ for Q5_0+. |

### Tier 3: Supporting Libraries

| Project | URL | Purpose |
|---------|-----|---------|
| **zenmap** | https://github.com/bkataru/zenmap | Zig mmap + GGUF header parser. Single-file, zero deps. |
| **hf-hub-zig** | https://github.com/bkataru/hf-hub-zig | HuggingFace Hub client for GGUF discovery/download. Pure Zig. |
| **ggufy** | https://github.com/qskousen/ggufy | Safetensors→GGUF converter. Started pure Zig, pulled in ggml C for quantization. |
| **llama.cpp.zig** | https://github.com/Deins/llama.cpp.zig | Zig bindings for llama.cpp. @cImport wrapper. |
| **ligguf** (C) | https://github.com/matrixsmaster/ligguf | ~780-line C single-file GGUF inference. Reference for what a minimal impl looks like. |

---

## Component Breakdown: What Exists vs What's Missing

| Component | Exists in Zig? | Best Source | Gap |
|-----------|---------------|-------------|-----|
| **GGUF file parser** | ✅ YES | ZINC `gguf.zig`, zenmap | ZINC has full GGUFv3 parser with all 31 GGMLType formats, metadata access, tensor lookup. zenmap has basic header parsing. |
| **Tensor math / GEMM** | ✅ YES | ZINC, cgbur/llama2.zig | ZINC has GPU GEMM via GLSL/MSL shaders. cgbur has SIMD CPU matmul via `@Vector`. No pure-Zig CPU BLAS equivalent to OpenBLAS. |
| **Quantization decode (Q4_K, Q6_K)** | ✅ YES | ZINC | ZINC supports Q4_K, Q5_K, Q6_K, Q8_0, Q5_0, MXFP4, F16, F32. All in GPU shaders (GLSL + MSL). purai got Q8_0 in Zig CPU but gave up on Q5_0. |
| **Transformer attention / KV cache** | ✅ YES | ZINC | Full multi-head attention with GQA, flash attention (batched), KV cache, RoPE. Architecture builders for Llama, MoE, Mamba/SSM hybrids. |
| **Metal GPU backend** | ✅ YES | ZINC | Native MSL compute shaders. simdgroup ops, zero-copy mmap. Active optimization (46 tok/s decode on M4 Max). |
| **Vulkan GPU backend** | ✅ YES | ZINC | 16 hand-tuned GLSL compute shaders. Wave64, cooperative matrix. 82+ tok/s decode on RDNA4. |
| **Tokenizer (BPE/SentencePiece)** | ✅ YES | ZINC | Native BPE tokenizer that reads vocabulary from GGUF metadata. Chat template support. |
| **Model loading (mmap)** | ✅ YES | ZINC, zenmap | ZINC: mmap + DMA to VRAM (Vulkan), mmap + zero-copy (Metal). zenmap: cross-platform mmap. |
| **OpenAI-compatible HTTP server** | ✅ YES | ZINC, zig-syrup | ZINC has full `/v1` API + chat UI. zig-syrup has `llamafile_reward.zig` HTTP client. |
| **CPU-only fallback** | ⚠️ PARTIAL | zigformer, llama2.zig ports | No production-quality CPU-only GGUF inference in Zig. The llama2.zig ports only handle .bin format. |

---

## Realistic Assessment: Three Paths

### Path A: Pure Zig from scratch (~12-18 person-months)

Building every component natively in Zig without any C dependency.

**What's needed:**
- GGUF parser: ~1 week (zenmap exists, ZINC's is complete)
- Q4_K/Q6_K dequantization kernels (CPU): ~2-4 weeks (the hard part — K-quant block structures are complex)
- GEMM kernels with SIMD: ~2-4 weeks (Zig `@Vector` works but needs careful tuning)
- Transformer forward pass: ~2-3 weeks (attention, RMSNorm, RoPE, SwiGLU, KV cache)
- Metal compute shaders (MSL): ~4-8 weeks (the real performance bottleneck)
- BPE tokenizer: ~1 week
- Gemma4-specific architecture (MoE for 26B, dense for 31B): ~2-3 weeks
- Testing, correctness verification, optimization: ~4-8 weeks

**Verdict:** Massive effort. The quantization kernels and GPU shaders alone are months of work. ZINC took 1,161 commits over 5 weeks with heavy AI-assisted development and still has gaps vs llama.cpp.

### Path B: Wrap llama.cpp via @cImport (~1-2 days)

Use `Deins/llama.cpp.zig` bindings or `@cImport` the llama.cpp C API directly.

**What you get immediately:**
- Every model llama.cpp supports (including gemma4)
- Metal + CUDA + Vulkan backends
- All quantization formats
- Battle-tested correctness

**What you lose:**
- Zig-native purity (carries 300K+ LOC of C/C++)
- Build complexity (llama.cpp's build system is nontrivial)
- Zig's safety guarantees don't extend into the C code

**Verdict:** Fastest to production. The project already uses `@cImport` for some C libraries. `igllama` proves this works. But contradicts the Zig-native preference.

### Path C: Use ZINC as a Zig dependency or HTTP API (~0-1 days) ⭐ RECOMMENDED

ZINC is the answer. It IS a Zig-native GGUF inference engine with Metal + Vulkan, and it **already supports Gemma 4 31B Q4_K_M and Gemma 4 26B-A4B Q4_K_M**.

**Option C1: HTTP API (what zig-syrup already does)**
- `llamafile_reward.zig` already talks to an OpenAI-compatible API
- Point it at ZINC instead of llamafile — zero code change
- ZINC's `/v1` API is OpenAI-compatible
- **Latency:** ~1ms localhost overhead per request

**Option C2: Add ZINC as a Zig package dependency**
- ZINC is a Zig 0.15 project (zig-syrup targets 0.16, minor delta)
- Extract ZINC's core modules (gguf.zig, model loader, architecture builders) as a library
- Would require ZINC to publish a package interface (doesn't exist yet)
- **Effort:** ~1-2 weeks to extract + adapt

---

## Recommendation: Fastest Pragmatic Path

**For gemma4 Q4_K_M inference from zig-syrup today:**

1. **Immediate (0 effort):** Run ZINC as a sidecar process, point `llamafile_reward.zig` at `http://127.0.0.1:8080/v1/chat/completions`. ZINC already supports gemma4 Q4_K_M with Metal on Apple Silicon. This is identical to the current llamafile approach but with a Zig-native server.

2. **Near-term (days):** Add a `zinc_client.zig` that manages ZINC lifecycle (start/stop the binary, health check, model pull). Single-binary deployment via embedding ZINC or shipping it alongside.

3. **Medium-term (weeks):** Contribute to or fork ZINC to expose a library API. Extract `gguf.zig` + `loader.zig` + `architecture.zig` as a reusable Zig package. This gives zig-syrup in-process inference without C dependencies.

4. **Aspirational:** The Zig ecosystem already has a production-grade GGUF inference engine (ZINC). The gap is not "can Zig do this?" — ZINC proves it can. The gap is "can ZINC be used as a library rather than a standalone binary?" That's a packaging question, not a capability question.

**Bottom line:** The c-library-zig-triage.md correctly classifies llama.cpp as TIER 2 (use as-is via C API). But ZINC changes the calculus — it's a Zig-native alternative that already handles the gemma4 Q4_K_M use case with Metal support and ~25-35 tok/s on Apple Silicon. The fastest path is HTTP API to ZINC (matching the existing llamafile pattern), with library extraction as the Zig-native endgame.
