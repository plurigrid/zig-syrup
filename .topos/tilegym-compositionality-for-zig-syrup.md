# TileGym Compositionality Lessons for zig-syrup

## Source: NVIDIA/TileGym (709 stars, cuTile-based kernel library)

## Core Pattern: Monkey-Patch Dispatch

TileGym replaces HuggingFace model operations with optimized cuTile kernels
via model-specific dispatch functions:

```
apply_tilegym_kernel_to_llama(model)
apply_tilegym_kernel_to_deepseek_v2(model)
```

Each call walks the model graph, identifies eligible operations, and swaps them
for cuTile implementations. Non-covered ops fall back to PyTorch/SDPA.

### Zig-syrup analog

Our `color_policy.zig` already has this pattern embryonically:
- `PolicyTable` is the "model"
- `ColorAction.fromIndex(idx)` is the operation interface
- `blendedReinforceUpdate` dispatches to either LLM or hardcoded reward

**Concrete lesson**: Define a `KernelInterface` trait (Zig interface via vtable)
for each composable operation (trit scoring, palette harmony, GF(3) conservation).
Then a dispatch table replaces implementations per backend:
- `HardcodedBackend`: current `RewardComponents.total()`
- `LlmBackend`: llamafile HTTP scoring
- `CuTileBackend`: future GPU-accelerated scoring (loads .cubin via cuModuleLoad)

## Core Pattern: Operator Granularity

TileGym's 40+ operators are individually composable:

| Category      | Operators                                    |
|---------------|----------------------------------------------|
| Attention     | FMHA (prefill), MLA, FlashDecode, SWA        |
| Normalization | RMSNorm, LayerNorm                           |
| Activation    | SwiGLU, GeGLU                                |
| Positional    | RoPE (real, complex)                         |
| Linear        | GEMM, GEMV, FP8/INT4 quantized variants      |
| MoE           | TopK routing, fused expert dispatch           |

Each is a self-contained unit with a stable interface:
`fmha_interface(q, k, v, ...) -> output`

### Zig-syrup analog

Our `RewardComponents` struct already decomposes reward into granular signals:
```zig
harmony: f32,        // CIEDE2000-like perceptual distance
semantic: f32,       // similar ops -> similar colors
conservation: f32,   // GF(3) trit-sum bonus
distinguishability: f32, // adjacent depths are perceptually distinct
```

**Concrete lesson**: Each reward component should be a replaceable operator:
```zig
const RewardOp = *const fn(rollout: *const Rollout, ctx: *anyopaque) f32;

const RewardPipeline = struct {
    ops: [8]struct { compute: RewardOp, weight: f32 },
    count: usize,
};
```

This matches TileGym's `KernelFilter` pattern for measuring coverage.

## Core Pattern: Prefill/Decode Split

TileGym attention dispatches differently based on phase:
- **Prefill** (long context, batch=1): cuTile FlashAttention (compute-bound)
- **Decode** (short query, KV cache): FlashDecode or SDPA fallback (memory-bound)

### Zig-syrup analog

Our REINFORCE loop has two analogous phases:
- **Exploration** (episode generation): sample actions, compute rewards
- **Exploitation** (policy update): gradient step on accumulated transitions

**Concrete lesson**: Different backends can serve different phases:
- Exploration: fast, lightweight hardcoded reward (no HTTP latency)
- Exploitation: LLM-blended reward for high-quality gradient signal
- This matches `blendedReinforceUpdate`'s existing fallback behavior

## Core Pattern: Coverage Measurement

TileGym uses nsys profiling + KernelFilter to measure what % of GPU time is
covered by optimized kernels. LLaMA 3.1 example: 18.3% GPU time covered.

### Zig-syrup analog

We should track what % of reward signal comes from each source:
```zig
const CoverageStats = struct {
    hardcoded_episodes: u64,
    llm_episodes: u64,
    llm_failures: u64, // fallback count

    fn llmCoverage(self: CoverageStats) f32 {
        const total = self.hardcoded_episodes + self.llm_episodes;
        if (total == 0) return 0;
        return @as(f32, @floatFromInt(self.llm_episodes)) /
               @as(f32, @floatFromInt(total));
    }
};
```

## Core Pattern: cuTile Immutable Tiles

cuTile's key abstraction: **immutable tiles** with compile-time constant,
power-of-2 dimensions. Data moves tile-at-a-time via `ct.load()`/`ct.store()`.

### Zig-syrup analog

Our `CellSlab` in `tileable.zig` already uses power-of-2 slab sizes:
```zig
pub const SLAB_SIZE: usize = 1 << 16;
```

**Concrete lesson**: The tile abstraction maps directly to our slab:
- CellSlab = immutable tile (fixed geometry)
- `members_inline[8]` = tile-local storage (8-element inline, overflow to heap)
- The slab's SoA layout (ranks, trits, tags as separate arrays) already matches
  cuTile's coalesced-memory-access pattern

## Integration Path: TileLang Kernels in Zig

For future NVIDIA GPU work:

1. Write kernel in TileLang Python DSL
2. Compile to `.so` / `.cubin` via TVM
3. Load from Zig:
```zig
// Via CUDA driver API (c import or @import("c") for 0.16)
const module = cuModuleLoad("kernel.cubin");
const func = cuModuleGetFunction(module, "flash_attention_fwd");
cuLaunchKernel(func, grid, block, args, shared_mem, stream);
```

4. TileLang supports NVIDIA targets:
   - H100 (TMA + WGMMA), A100, V100
   - RTX 4090/3090/A6000
   - MI250, MI300X (AMD)

## Summary: What to Build Next

1. **RewardOp interface** — vtable-based reward component replacement
2. **CoverageStats** — track LLM vs hardcoded reward source mix
3. **Phase-aware dispatch** — fast exploration, accurate exploitation
4. **KernelFilter equivalent** — measure time spent in each reward backend
5. **cubin loader skeleton** — prepare for GPU reward acceleration path
