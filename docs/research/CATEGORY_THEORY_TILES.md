# Category Theory of Tiled Architectures (Nvidia & OLC)

## 1. The Category `Tile`

Objects: `Tile_i` (Memory regions / Screen tiles / OLC Cells)
Morphisms: `Transfer: Tile_i -> Tile_j` (Data movement, adjacency)

This connects two seemingly disparate domains via **Tiled Decompositions**:

### A. Nvidia GPU Architecture (Compute Tiling)
*   **Tiles:** Thread Blocks / Warps mapped to SMs (Streaming Multiprocessors).
*   **Hierarchy:** Grid -> Block -> Warp -> Thread.
*   **Implicit Challenge:** "Occupancy" (Optimizing the tiling to hide latency).
*   **Vibesnipe:** Coding a kernel that hits 100% SM utilization without bank conflicts.
*   **Functor:** `Kernel: InputTensor -> OutputTensor` decomposed into local tile operations.

### B. Open Location Code (Spatial Tiling)
*   **Tiles:** Grid cells defined by lat/lng resolution (e.g., 20° blocks).
*   **Hierarchy:** 20° -> 1° -> 0.05° ...
*   **Implicit Challenge:** "Precision" (Encoding location minimizing bit-width).
*   **Vibesnipe:** The `geo.zig` bug (incorrect resolution formula) was a failure in the **presheaf restriction map** (zooming in failed).

## 2. The Isomorphism

The "Vibesnipe" against the `geo.zig` bug is an **Adjoint Functor** problem.

*   **Left Adjoint (Free):** `encodeOlc` (Coordinate -> Tile Path). Generates the path.
*   **Right Adjoint (Forgetful):** `decodeOlc` (Tile Path -> Coordinate Area). Recovers the spatial bound.

**The Bug:**
The `pairResolution` function was calculating the size of the "universe" instead of the "local tile".
*   Current: $20^{(4 - i/2)}$ (Too big! World sized tiles at step 0)
*   Required: $20^{(1 - i/2)}$ (Degree sized tiles at step 0)

This is a **Scale Transformation Error**. In Category Theory terms, we applied the wrong **Natural Transformation** between the index category and the spatial category.

## 3. Nvidia Translation (Implicit)

If this were a CUDA kernel:
*   We calculated the `stride` (resolution) as `gridDim.x` instead of `blockDim.x`.
*   Result: All threads tried to write to index 0 (Collision / '22222' output).

## 4. The Fix (Category Alignment)

We must align the **resolution scale** of the OLC encoder to the actual **grid hierarchy** of the earth.

**Fix Plan:**
1.  Correct `pairResolution` formula to $20^{(1 - i/2)}$.
2.  Verify `encodeOlc` produces valid "849..." codes instead of "222...".
