/**
 * Spatial Propagator C ABI
 *
 * Bridges SplitTree topology into the zig-syrup propagator pipeline.
 * Golden-spiral and BCI-entropy color assignment, focus propagation
 * with adjacency halo, Syrup topology ingestion.
 *
 * Build: zig build (produces libspatial_propagator.dylib)
 */

#ifndef SPATIAL_PROPAGATOR_H
#define SPATIAL_PROPAGATOR_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/** Opaque handle to the spatial propagator network. */
typedef struct PropagatorHandle PropagatorHandle;

// ---- Lifecycle ----

/** Initialize. Returns NULL on allocation failure. */
PropagatorHandle* propagator_init(void);

/** Cleanup and free all resources. */
void propagator_deinit(PropagatorHandle* handle);

// ---- Topology ----

/**
 * Add a spatial node.
 * @param window_id  Unique window/surface identifier
 * @param space_id   macOS CGS Space ID (for multi-desktop filtering)
 * @param depth      Split tree depth
 * @param x,y,w,h    Bounding rect in screen coordinates
 * @return Node index (>=0) or -1 on error.
 */
int32_t propagator_add_node(
    PropagatorHandle* handle,
    uint32_t window_id,
    uint32_t space_id,
    uint32_t depth,
    int32_t x, int32_t y,
    uint32_t w, uint32_t h);

/** Connect two nodes as adjacent by their indices. */
void propagator_connect(PropagatorHandle* handle, uint32_t a, uint32_t b);

/** Auto-detect adjacency from node bounding rects (edge-sharing). */
void propagator_detect_adjacency(PropagatorHandle* handle);

/**
 * Ingest topology from Syrup-encoded bytes.
 * Expected format: <split-tree [<node ...>...] [[src dst]...]>
 * @return 0 on success, negative on error.
 */
int32_t propagator_ingest_topology(
    PropagatorHandle* handle,
    const uint8_t* syrup_bytes,
    size_t len);

// ---- Color Assignment ----

/** Assign colors via deterministic golden-angle spiral. */
void propagator_assign_colors(PropagatorHandle* handle);

/**
 * Assign colors from BCI brainwave entropy.
 * Mirrors Python valence_bridge.py project_to_color algorithm:
 *   Hue   = (phi * golden_angle) % 360, per-node offset
 *   Chroma = 0.3 + 0.6 * sigmoid(valence + 3)
 *   Lightness = 0.3 + 0.4 * sigmoid(fisher - 1)
 *   Trit: +1 → +20° hue (warmer), -1 → -20° (cooler)
 *
 * @param phi      Integrated information (Φ), typical 0–50
 * @param valence  -log(vortex_count), typical -10..0
 * @param fisher   Mean Fisher-Rao distance, typical 0..5
 * @param trit     GF(3) symmetry: -1, 0, or +1
 */
void propagator_assign_colors_bci(
    PropagatorHandle* handle,
    float phi,
    float valence,
    float fisher,
    int32_t trit);

/** Set a specific node's colors directly (from external source). */
void propagator_set_node_color(
    PropagatorHandle* handle,
    uint32_t node_id,
    uint32_t fg,
    uint32_t bg);

// ---- Focus ----

/** Set focus to node by window_id. Propagates halo to adjacent nodes. */
void propagator_set_focus(PropagatorHandle* handle, uint32_t node_id);

// ---- Read Back ----

/**
 * Get spatial colors packed into output buffer.
 * Format per node: [u32 node_id, u32 fg_argb, u32 bg_argb] = 12 bytes.
 * fg includes focus brightness adjustment.
 * @return Bytes written.
 */
size_t propagator_get_spatial_colors(
    PropagatorHandle* handle,
    uint8_t* output_buf,
    size_t len);

#ifdef __cplusplus
}
#endif

#endif /* SPATIAL_PROPAGATOR_H */
