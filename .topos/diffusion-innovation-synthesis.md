# Diffusion & Inference Innovation Synthesis for zig-syrup

## Date: 2026-04-29
## Purpose: Actionable distillation from ecosystem-wide innovation survey

---

## Tier 1: Directly Applicable to zig-syrup Architecture

### 1. Mercury dLLMs — Parallel Token Generation via Denoising
- **Source**: Inception Labs (commercial), Mercury 2 = first reasoning dLLM
- **Key insight**: Generate multiple tokens simultaneously by iterative denoising, not left-to-right autoregression
- **zig-syrup relevance**: Our `blendedReinforceUpdate` currently scores one palette at a time. dLLM-style parallel generation could score N palettes in a single forward pass, then denoise to the best. Maps directly to: `rolloutToPalette()` generates N candidates → critic scores all at once → select
- **Implementation path**: Batch the `/v1/chat/completions` calls to Gemma 4 (already running on port 8090). Use `n` parameter or parallel HTTP requests from `llamafile_reward.zig`

### 2. REFUSION — Slot-Level Parallel Decoding
- **Source**: arXiv 2025, 32% perf gains + 10x speedup over prior MDMs
- **Key insight**: Plan-and-infill at slot granularity (not token-level). Each "slot" is an independent generation unit with full KV cache reuse
- **zig-syrup relevance**: Our color palette has 3 independent slots (trit positions). Each trit can be generated/scored independently then composed. This IS slot-level decoding for GF(3) palettes
- **Implementation path**: Decompose `rolloutToPalette` into per-trit generation with independent scoring, then compose with GF(3) conservation check

### 3. Coupled-GRPO (DiffuCoder) — RL for Diffusion Models
- **Source**: Apple, +4.4% EvalPlus
- **Key insight**: Antithetic variate trick for dLLM RL — generate paired samples (x, x̃) where x̃ is x with one denoising step reversed. Reduces variance of policy gradient by 2x
- **zig-syrup relevance**: Direct upgrade to `blendedReinforceUpdate`. Currently uses single-sample REINFORCE. Coupled-GRPO's antithetic pairs = generate palette P and P̃ (P with one trit flipped), score both, use difference as baseline
- **Implementation path**: In `color_policy.zig`, modify rollout to produce (palette, anti-palette) pairs. Anti-palette = flip one trit per step. Variance reduction is free

### 4. rvLLM — Rust+Zig SIMD Backend
- **Source**: rvLLM project, 76K lines Rust, 54 CUDA kernels, Zig SIMD backend
- **Key insight**: Zig's SIMD intrinsics used as the compute backend for a full inference engine. 13,943 tok/s on TPU, 7,943 tok/s on H100
- **zig-syrup relevance**: Validates that Zig SIMD is production-viable for inference. The rvllm-zig component is a reference for our eventual GPU/SIMD scoring backend
- **Implementation path**: Study rvllm-zig SIMD patterns for potential `RewardOp` acceleration

---

## Tier 2: Architectural Inspiration

### 5. DiffuMamba — Linear-Time Sequence Modeling
- **Mamba backbone for diffusion LMs, 8.2x higher throughput than Transformer**
- **Relevance**: If we ever move from HTTP-based LLM scoring to embedded inference, Mamba's linear-time property means scoring cost scales O(n) not O(n²) with palette size. Relevant for scaling beyond 3-trit palettes

### 6. SANA-Sprint — 1-Step Image Diffusion
- **64.7x faster than FLUX-Schnell, 0.1s for 1024x1024 on H100**
- **Relevance**: Demonstrates extreme distillation. Our hardcoded reward (`RewardComponents.total()`) is already a "1-step" scorer. The LLM critic is multi-step. Can we distill the LLM critic into a single-step NN? Future work

### 7. DC-DiT — Dynamic Chunking
- **Adaptive token compression, 8x fewer training steps**
- **Relevance**: For palette generation, not all trits are equally uncertain. Dynamic chunking = allocate more compute to uncertain trit positions, less to confident ones. Maps to adaptive temperature in our softmax policy

### 8. InfSA — Infinite Self-Attention (Spectral Reformulation)
- **Linear-time attention, 13x throughput/energy, 9216x9216 inference**
- **Relevance**: If scoring palettes at scale (thousands per training step), spectral attention could score all pairs simultaneously. Theoretical for now

---

## Tier 3: Ecosystem Tools to Watch

### 9. ZINC (Zig Inference Engine)
- **303 stars, hand-tuned Vulkan/Metal shaders, 37.95 tok/s on RDNA4**
- **Status**: LLM-only, no diffusion. But demonstrates Zig can drive GPU inference natively
- **Watch for**: Vulkan/Metal compute shader patterns reusable for custom scoring kernels

### 10. Dynamo (NVIDIA) — Datacenter Distributed Inference
- **Rust+Python, 7x throughput per GPU, dLLM support (LLaDA2.0)**
- **Watch for**: Their dLLM integration patterns if we scale beyond single-machine

### 11. stable-diffusion.cpp (17K+ stars)
- **ggml-based, widest model coverage (SD/FLUX/Wan/Z-Image)**
- **Watch for**: C API bindable from Zig via `@import("c")` for image generation if needed

### 12. Compiler Innovations
- **REASONING COMPILER**: MCTS+LLM, 5x speedup/5.8x fewer samples — potential for auto-optimizing our reward function
- **Magellan**: Autonomous compiler optimization agent — relevant if we want to auto-tune Zig SIMD kernels
- **CompilerDream**: World-model-based compiler optimization — speculative

---

## Concrete Next Actions

1. **Implement antithetic-variate REINFORCE** (from coupled-GRPO): Modify `blendedReinforceUpdate` to generate (palette, anti-palette) pairs. Estimated: 30 LOC change in `color_policy.zig`

2. **Batch palette scoring** (from Mercury/dLLM parallel generation): Send N palettes in a single prompt to Gemma 4, parse N scores back. Modify `llamafile_reward.zig` `scorePalette()` to accept `[]Palette` → `[]f32`

3. **Per-trit independent scoring** (from REFUSION slot-level): Decompose `RewardComponents` to score each trit position independently, then compose. Enables parallel trit generation

4. **Study rvllm-zig SIMD patterns** for potential embedded scoring acceleration

5. **Distillation roadmap**: Plan how to distill Gemma 4 critic into a small NN that runs as a Zig SIMD kernel (SANA-Sprint inspiration)

---

## Diffusion Ecosystem Summary Table

| Project | Language | GPU | Models | Stars | Status |
|---------|----------|-----|--------|-------|--------|
| ZML | Zig | MLIR/XLA | LLM | 4.4K | Active |
| ZINC | Zig | Vulkan/Metal | LLM | 303 | Active |
| rvLLM | Rust+Zig | CUDA/TPU | LLM | new | Active |
| diffusion-rs (Eric) | Rust | CUDA/Metal | FLUX DDUF | new | Active |
| mold | Rust | candle | 8 families | new | Active |
| stable-diffusion.cpp | C++ | ggml | SD/FLUX/Wan | 17K+ | Active |
| iris.c | C | CPU | FLUX.2 Klein | new | Proof-of-concept |
| Mercury | Proprietary | H100 | dLLM | N/A | Commercial |
| Dynamo | Rust+Python | multi-GPU | LLM+dLLM | new | NVIDIA |
