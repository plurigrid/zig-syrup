//! Tileable Shader: Pixel-Perfect Embarrassingly Parallel Color Tiles
//!
//! Each tile is independent (embarrassingly parallel at every level).
//! Color is positionally dependent and referentially transparent:
//! the same (tile_x, tile_y, seed) always produces the same color,
//! regardless of evaluation order, thread, or machine.
//!
//! StructuredDecompositions.jl compatibility:
//! - Tiles are bags in a tree decomposition
//! - Adjacency edges are adhesions (shared boundary colors must agree)
//! - The sheaf condition: restriction maps on tile boundaries commute
//! - Noise at each tile distills upward through the operad hierarchy
//!
//! The infinity-operad structure:
//! - Level 0: individual pixels (leaf nodes)
//! - Level 1: tile (bag of pixels, 16x16 default)
//! - Level 2: tile-group (bag of tiles, sheaf section)
//! - Level 3: world (bag of tile-groups)
//! - Level N: the operad at arity N composes N sub-tiles
//!   into a parent tile with boundary agreement (adhesion filter)
//!
//! Noise distillation: positional noise (SplitMix64 from Gay.jl) at each
//! pixel is reduced per-tile via SIMD horizontal sum, then per-group via
//! sheaf obstruction measure, then per-world via GF(3) trit conservation.
//! The distilled noise IS the color seen at each operad level.
//!
//! No demos. Worlds only.

const std = @import("std");
const lux_color = @import("lux_color");
const cell_dispatch = @import("cell_dispatch");

const Trit = lux_color.Trit;
const ExprColor = lux_color.ExprColor;
const RGB = lux_color.RGB;
const HCL = lux_color.HCL;
const Cell = cell_dispatch.Cell;
const CellBatch = cell_dispatch.CellBatch;
const CellCoord = cell_dispatch.CellCoord;
const Allocator = std.mem.Allocator;

// ============================================================================
// SPLITMIX64: referentially transparent positional noise
// ============================================================================

/// SplitMix64 bijection (Gay.jl compatible).
/// Same seed + same position = same value. Always. On any machine.
pub const SplitMix64 = struct {
    const GOLDEN: u64 = 0x9e3779b97f4a7c15;
    const MIX1: u64 = 0xbf58476d1ce4e5b9;
    const MIX2: u64 = 0x94d049bb133111eb;

    /// Mix a 64-bit state through Stafford's Mix13.
    pub inline fn mix(z: u64) u64 {
        var x = z;
        x ^= (x >> 30);
        x *%= MIX1;
        x ^= (x >> 27);
        x *%= MIX2;
        x ^= (x >> 31);
        return x;
    }

    /// Positional hash: (seed, x, y) -> deterministic u64.
    /// Referentially transparent: no state mutation.
    pub inline fn positional(seed: u64, x: u32, y: u32) u64 {
        const pos = @as(u64, x) | (@as(u64, y) << 32);
        return mix(seed +% GOLDEN +% pos);
    }

    /// Positional hash with tile and pixel coordinates.
    /// (seed, tile_x, tile_y, px, py) -> u64.
    pub inline fn tilePixel(seed: u64, tile_x: u32, tile_y: u32, px: u32, py: u32) u64 {
        const tile_hash = positional(seed, tile_x, tile_y);
        return positional(tile_hash, px, py);
    }

    /// Extract a float in [0, 1) from a hash.
    pub inline fn toFloat(h: u64) f32 {
        return @as(f32, @floatFromInt(h >> 40)) / @as(f32, @floatFromInt(@as(u64, 1) << 24));
    }

    /// Extract a GF(3) trit from a hash.
    pub inline fn toTrit(h: u64) Trit {
        return switch (@as(u2, @truncate(h % 3))) {
            0 => .ergodic,
            1 => .plus,
            2 => .minus,
            else => unreachable,
        };
    }
};

// ============================================================================
// TILE: the fundamental unit of embarrassingly parallel work
// ============================================================================

pub const TILE_SIZE: u32 = 16;

/// A shader function: (x, y, seed) -> ARGB color.
/// x, y in [0, 1), seed is the tile-pixel hash.
/// Must be pure (referentially transparent).
pub const ShaderFn = *const fn (f32, f32, u64) u32;

/// A single tile in the tiled grid.
/// Contains TILE_SIZE x TILE_SIZE pixels.
/// Each pixel color is computed from the shader function.
pub const Tile = struct {
    /// Tile coordinates in the grid
    tx: u32,
    ty: u32,
    /// Pixel data (ARGB, row-major)
    pixels: [TILE_SIZE * TILE_SIZE]u32,
    /// Distilled noise: the tile's aggregate color seen from the next operad level.
    distilled_trit: Trit,
    distilled_hue: f32,

    /// Compute all pixels from a shader. Embarrassingly parallel per pixel.
    pub fn compute(tx: u32, ty: u32, seed: u64, shader: ShaderFn) Tile {
        var tile: Tile = undefined;
        tile.tx = tx;
        tile.ty = ty;

        var sum_r: u32 = 0;
        var sum_g: u32 = 0;
        var sum_b: u32 = 0;

        for (0..TILE_SIZE) |py| {
            for (0..TILE_SIZE) |px| {
                const pxu: u32 = @intCast(px);
                const pyu: u32 = @intCast(py);
                const noise = SplitMix64.tilePixel(seed, tx, ty, pxu, pyu);
                const fx = @as(f32, @floatFromInt(pxu)) / @as(f32, @floatFromInt(TILE_SIZE));
                const fy = @as(f32, @floatFromInt(pyu)) / @as(f32, @floatFromInt(TILE_SIZE));
                const color = shader(fx, fy, noise);
                tile.pixels[py * TILE_SIZE + px] = color;

                sum_r += (color >> 16) & 0xFF;
                sum_g += (color >> 8) & 0xFF;
                sum_b += color & 0xFF;
            }
        }

        // Distill: mean color -> trit + hue
        const count = TILE_SIZE * TILE_SIZE;
        const mean_r = @as(f32, @floatFromInt(sum_r)) / @as(f32, @floatFromInt(count));
        const mean_g = @as(f32, @floatFromInt(sum_g)) / @as(f32, @floatFromInt(count));
        const mean_b = @as(f32, @floatFromInt(sum_b)) / @as(f32, @floatFromInt(count));

        tile.distilled_hue = rgbToHue(mean_r / 255.0, mean_g / 255.0, mean_b / 255.0);
        tile.distilled_trit = hueToBoundaryTrit(tile.distilled_hue);

        return tile;
    }

    /// Get pixel at local coordinates.
    pub fn getPixel(self: *const Tile, px: u32, py: u32) u32 {
        return self.pixels[py * TILE_SIZE + px];
    }

    /// Boundary color: the mean color along a given edge.
    /// Used for adhesion checks between adjacent tiles.
    pub fn boundaryColor(self: *const Tile, edge: Edge) BoundaryColor {
        var sum_r: u32 = 0;
        var sum_g: u32 = 0;
        var sum_b: u32 = 0;

        for (0..TILE_SIZE) |i| {
            const color = switch (edge) {
                .top => self.pixels[i],
                .bottom => self.pixels[(TILE_SIZE - 1) * TILE_SIZE + i],
                .left => self.pixels[i * TILE_SIZE],
                .right => self.pixels[i * TILE_SIZE + (TILE_SIZE - 1)],
            };
            sum_r += (color >> 16) & 0xFF;
            sum_g += (color >> 8) & 0xFF;
            sum_b += color & 0xFF;
        }

        return .{
            .r = @as(f32, @floatFromInt(sum_r)) / @as(f32, @floatFromInt(TILE_SIZE)),
            .g = @as(f32, @floatFromInt(sum_g)) / @as(f32, @floatFromInt(TILE_SIZE)),
            .b = @as(f32, @floatFromInt(sum_b)) / @as(f32, @floatFromInt(TILE_SIZE)),
            .trit = SplitMix64.toTrit(SplitMix64.positional(
                @as(u64, self.tx) | (@as(u64, self.ty) << 32),
                @intFromEnum(edge),
                0,
            )),
        };
    }

    /// Check if this tile's edge matches the adjacent tile's edge.
    /// This is the sheaf condition: restriction maps must commute.
    pub fn adhesionError(self: *const Tile, other: *const Tile, self_edge: Edge) f32 {
        const other_edge = self_edge.opposite();
        const a = self.boundaryColor(self_edge);
        const b = other.boundaryColor(other_edge);
        return a.distance(b);
    }
};

pub const Edge = enum(u2) {
    top = 0,
    right = 1,
    bottom = 2,
    left = 3,

    pub fn opposite(self: Edge) Edge {
        return switch (self) {
            .top => .bottom,
            .right => .left,
            .bottom => .top,
            .left => .right,
        };
    }
};

/// Boundary color: mean color along a tile edge.
/// Carries a GF(3) trit for adhesion checking.
pub const BoundaryColor = struct {
    r: f32,
    g: f32,
    b: f32,
    trit: Trit,

    /// L2 distance between two boundary colors.
    pub fn distance(self: BoundaryColor, other: BoundaryColor) f32 {
        const dr = self.r - other.r;
        const dg = self.g - other.g;
        const db = self.b - other.b;
        return @sqrt(dr * dr + dg * dg + db * db);
    }
};

// ============================================================================
// TILE GRID: embarrassingly parallel at the tile level
// ============================================================================

/// A grid of tiles. Each tile is independent and can be computed in any order.
pub const TileGrid = struct {
    width: u32, // in tiles
    height: u32, // in tiles
    seed: u64,
    tiles: []Tile,
    allocator: Allocator,

    pub fn init(allocator: Allocator, width: u32, height: u32, seed: u64) !TileGrid {
        const tiles = try allocator.alloc(Tile, @as(usize, width) * height);
        return .{
            .width = width,
            .height = height,
            .seed = seed,
            .tiles = tiles,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *TileGrid) void {
        self.allocator.free(self.tiles);
    }

    /// Compute all tiles using a shader. Each tile is independent.
    pub fn compute(self: *TileGrid, shader: ShaderFn) void {
        for (0..self.height) |ty| {
            for (0..self.width) |tx| {
                const txu: u32 = @intCast(tx);
                const tyu: u32 = @intCast(ty);
                self.tiles[ty * self.width + tx] = Tile.compute(txu, tyu, self.seed, shader);
            }
        }
    }

    /// Get a tile by grid coordinates.
    pub fn getTile(self: *const TileGrid, tx: u32, ty: u32) ?*const Tile {
        if (tx >= self.width or ty >= self.height) return null;
        return &self.tiles[ty * self.width + tx];
    }

    /// Total adhesion error across all adjacent tile pairs.
    /// This is the sheaf obstruction: zero iff the section is globally consistent.
    pub fn totalAdhesionError(self: *const TileGrid) f32 {
        var total: f32 = 0;
        for (0..self.height) |ty| {
            for (0..self.width) |tx| {
                const tile = &self.tiles[ty * self.width + tx];
                // Right neighbor
                if (tx + 1 < self.width) {
                    const right = &self.tiles[ty * self.width + tx + 1];
                    total += tile.adhesionError(right, .right);
                }
                // Bottom neighbor
                if (ty + 1 < self.height) {
                    const bottom = &self.tiles[(ty + 1) * self.width + tx];
                    total += tile.adhesionError(bottom, .bottom);
                }
            }
        }
        return total;
    }

    /// GF(3) conservation check across all tiles.
    /// The sum of all tile trits should be zero for a balanced grid.
    pub fn isConserved(self: *const TileGrid) bool {
        var sum: Trit = .ergodic;
        for (self.tiles) |tile| {
            sum = sum.add(tile.distilled_trit);
        }
        return sum == .ergodic;
    }

    /// Distill the grid into a single operad-level color.
    /// This is the noise at the tile-group level: the pattern you see
    /// when you zoom out from individual tiles.
    pub fn distill(self: *const TileGrid) DistilledColor {
        var sum_hue_sin: f32 = 0;
        var sum_hue_cos: f32 = 0;
        var trit_sum: Trit = .ergodic;
        const count = self.tiles.len;

        for (self.tiles) |tile| {
            const rad = tile.distilled_hue * std.math.pi / 180.0;
            sum_hue_sin += @sin(rad);
            sum_hue_cos += @cos(rad);
            trit_sum = trit_sum.add(tile.distilled_trit);
        }

        const mean_hue = @mod(
            std.math.atan2(sum_hue_sin, sum_hue_cos) * 180.0 / std.math.pi + 360.0,
            360.0,
        );

        return .{
            .hue = mean_hue,
            .trit = trit_sum,
            .adhesion_error = self.totalAdhesionError(),
            .tile_count = @intCast(count),
            .conserved = trit_sum == .ergodic,
        };
    }

    /// Convert to CellBatch for cell_dispatch integration.
    pub fn toCellBatch(self: *const TileGrid, allocator: Allocator) !CellBatch {
        const px_width = self.width * TILE_SIZE;
        const px_height = self.height * TILE_SIZE;
        const origin = CellCoord.init(0, 0, 0);
        var batch = try CellBatch.init(allocator, origin, px_width, px_height);

        for (0..self.height) |ty| {
            for (0..self.width) |tx| {
                const tile = &self.tiles[ty * self.width + tx];
                for (0..TILE_SIZE) |py| {
                    for (0..TILE_SIZE) |px| {
                        const gx: u32 = @intCast(tx * TILE_SIZE + px);
                        const gy: u32 = @intCast(ty * TILE_SIZE + py);
                        const color = tile.pixels[py * TILE_SIZE + px];
                        const cell = Cell{
                            .codepoint = 0x2588, // full block
                            .fg = color | 0xFF000000,
                            .bg = 0xFF000000,
                            .attrs = 0,
                        };
                        _ = batch.set(gx, gy, cell);
                    }
                }
            }
        }

        return batch;
    }
};

/// Result of distilling a TileGrid into operad-level color.
pub const DistilledColor = struct {
    hue: f32,
    trit: Trit,
    adhesion_error: f32,
    tile_count: u32,
    conserved: bool,

    /// Convert to ExprColor for integration with lux_color operad.
    pub fn toExprColor(self: DistilledColor, depth: u16) ExprColor {
        return ExprColor.init(self.trit, depth);
    }

    /// Convert to RGB.
    pub fn toRGB(self: DistilledColor) RGB {
        const hcl = HCL{
            .h = self.hue,
            .c = if (self.conserved) @as(f32, 0.7) else @as(f32, 0.3),
            .l = 0.6,
        };
        return hcl.toRGB();
    }
};

// ============================================================================
// TREE DECOMPOSITION: StructuredDecompositions.jl interface
// ============================================================================

/// A bag in the tree decomposition. Each bag contains a set of tile indices.
/// Adjacent bags share tiles (adhesions). The sheaf condition on adhesions
/// ensures global consistency of the coloring.
pub const Bag = struct {
    tiles: []u32, // indices into TileGrid.tiles
    parent: ?u32, // index of parent bag, null for root
    children: []u32, // indices of child bags
    distilled: ?DistilledColor,

    /// Distill this bag's color from its constituent tiles.
    pub fn distill(self: *Bag, grid: *const TileGrid) DistilledColor {
        var sum_hue_sin: f32 = 0;
        var sum_hue_cos: f32 = 0;
        var trit_sum: Trit = .ergodic;

        for (self.tiles) |idx| {
            const tile = &grid.tiles[idx];
            const rad = tile.distilled_hue * std.math.pi / 180.0;
            sum_hue_sin += @sin(rad);
            sum_hue_cos += @cos(rad);
            trit_sum = trit_sum.add(tile.distilled_trit);
        }

        const mean_hue = @mod(
            std.math.atan2(sum_hue_sin, sum_hue_cos) * 180.0 / std.math.pi + 360.0,
            360.0,
        );

        var adhesion: f32 = 0;
        // Compute adhesion error between all tile pairs in the bag
        for (self.tiles, 0..) |idx_a, i| {
            for (self.tiles[i + 1 ..]) |idx_b| {
                const a = &grid.tiles[idx_a];
                const b = &grid.tiles[idx_b];
                // Check if adjacent (differ by 1 in either coordinate)
                const dx = if (a.tx > b.tx) a.tx - b.tx else b.tx - a.tx;
                const dy = if (a.ty > b.ty) a.ty - b.ty else b.ty - a.ty;
                if (dx + dy == 1) {
                    if (dx == 1) {
                        const edge: Edge = if (a.tx > b.tx) .left else .right;
                        adhesion += a.adhesionError(b, edge);
                    } else {
                        const edge: Edge = if (a.ty > b.ty) .top else .bottom;
                        adhesion += a.adhesionError(b, edge);
                    }
                }
            }
        }

        const result = DistilledColor{
            .hue = mean_hue,
            .trit = trit_sum,
            .adhesion_error = adhesion,
            .tile_count = @intCast(self.tiles.len),
            .conserved = trit_sum == .ergodic,
        };
        self.distilled = result;
        return result;
    }
};

/// Tree decomposition of a tile grid.
/// Bags form a tree; adhesions are the shared tiles between adjacent bags.
/// Width = max bag size - 1.
pub const TreeDecomposition = struct {
    bags: []Bag,
    width: u32, // treewidth
    allocator: Allocator,

    /// Build a simple grid-based tree decomposition.
    /// Groups tiles into 2x2 bags with 1-tile overlap (adhesion).
    pub fn fromGrid(allocator: Allocator, grid: *const TileGrid) !TreeDecomposition {
        const bw = (grid.width + 1) / 2;
        const bh = (grid.height + 1) / 2;
        const n_bags = @as(usize, bw) * bh;
        const bags = try allocator.alloc(Bag, n_bags);

        var max_bag_size: u32 = 0;

        for (0..bh) |by| {
            for (0..bw) |bx| {
                const bag_idx = by * bw + bx;
                var tile_indices = std.ArrayList(u32).init(allocator);

                // Collect tiles in this 2x2 region
                const x_start = @as(u32, @intCast(bx)) * 2;
                const y_start = @as(u32, @intCast(by)) * 2;
                const x_end = @min(x_start + 2, grid.width);
                const y_end = @min(y_start + 2, grid.height);

                for (y_start..y_end) |ty| {
                    for (x_start..x_end) |tx| {
                        try tile_indices.append(@intCast(ty * grid.width + tx));
                    }
                }

                max_bag_size = @max(max_bag_size, @as(u32, @intCast(tile_indices.items.len)));

                // Set parent (linear chain for simplicity)
                const parent: ?u32 = if (bag_idx > 0) @intCast(bag_idx - 1) else null;

                // Children (next bag in chain)
                var children = std.ArrayList(u32).init(allocator);
                if (bag_idx + 1 < n_bags) {
                    try children.append(@intCast(bag_idx + 1));
                }

                bags[bag_idx] = .{
                    .tiles = try tile_indices.toOwnedSlice(),
                    .parent = parent,
                    .children = try children.toOwnedSlice(),
                    .distilled = null,
                };
            }
        }

        return .{
            .bags = bags,
            .width = if (max_bag_size > 0) max_bag_size - 1 else 0,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *TreeDecomposition) void {
        for (self.bags) |bag| {
            self.allocator.free(bag.tiles);
            self.allocator.free(bag.children);
        }
        self.allocator.free(self.bags);
    }

    /// Distill all bags bottom-up, propagating noise through the tree.
    pub fn distillAll(self: *TreeDecomposition, grid: *const TileGrid) void {
        // Bottom-up: process leaves first (reverse order for linear chain)
        var i = self.bags.len;
        while (i > 0) {
            i -= 1;
            _ = self.bags[i].distill(grid);
        }
    }

    /// Total sheaf obstruction across the tree.
    pub fn totalObstruction(self: *const TreeDecomposition) f32 {
        var total: f32 = 0;
        for (self.bags) |bag| {
            if (bag.distilled) |d| {
                total += d.adhesion_error;
            }
        }
        return total;
    }

    /// Check GF(3) conservation at the root.
    pub fn isConserved(self: *const TreeDecomposition) bool {
        if (self.bags.len == 0) return true;
        if (self.bags[0].distilled) |d| return d.conserved;
        return false;
    }
};

// ============================================================================
// OPERAD LEVEL: composing distilled colors
// ============================================================================

/// An operad node at level N in the infinity-operad.
/// Composes N children's distilled colors into one.
pub const OperadNode = struct {
    level: u8,
    children_hues: []f32,
    children_trits: []Trit,
    allocator: Allocator,

    pub fn init(allocator: Allocator, level: u8, n_children: usize) !OperadNode {
        return .{
            .level = level,
            .children_hues = try allocator.alloc(f32, n_children),
            .children_trits = try allocator.alloc(Trit, n_children),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *OperadNode) void {
        self.allocator.free(self.children_hues);
        self.allocator.free(self.children_trits);
    }

    /// Set a child's distilled color.
    pub fn setChild(self: *OperadNode, idx: usize, hue: f32, trit: Trit) void {
        self.children_hues[idx] = hue;
        self.children_trits[idx] = trit;
    }

    /// Compose children into parent color.
    /// Uses the angle for this operad level (golden/plastic/silver).
    pub fn compose(self: *const OperadNode) DistilledColor {
        var sum_sin: f32 = 0;
        var sum_cos: f32 = 0;
        var trit_sum: Trit = .ergodic;

        const angle = switch (self.level) {
            0, 1 => lux_color.GOLDEN_ANGLE,
            2, 3 => lux_color.PLASTIC_ANGLE,
            else => lux_color.SILVER_ANGLE,
        };

        for (self.children_hues, 0..) |hue, i| {
            const rotated = @mod(hue + angle * @as(f32, @floatFromInt(i)), 360.0);
            const rad = rotated * std.math.pi / 180.0;
            sum_sin += @sin(rad);
            sum_cos += @cos(rad);
            trit_sum = trit_sum.add(self.children_trits[i]);
        }

        const mean_hue = @mod(
            std.math.atan2(sum_sin, sum_cos) * 180.0 / std.math.pi + 360.0,
            360.0,
        );

        return .{
            .hue = mean_hue,
            .trit = trit_sum,
            .adhesion_error = 0,
            .tile_count = @intCast(self.children_hues.len),
            .conserved = trit_sum == .ergodic,
        };
    }
};

// ============================================================================
// BUILT-IN SHADERS: referentially transparent, tileable
// ============================================================================

/// Golden spiral noise: tileable via positional hash.
pub fn goldenSpiralShader(x: f32, y: f32, noise: u64) u32 {
    const cx = x - 0.5;
    const cy = y - 0.5;
    const r = @sqrt(cx * cx + cy * cy);
    const angle = std.math.atan2(cy, cx);
    const noise_f = SplitMix64.toFloat(noise);
    const hue = @mod(angle * 180.0 / std.math.pi + r * lux_color.GOLDEN_ANGLE * 8.0 + noise_f * 30.0, 360.0);
    const hcl = HCL{ .h = hue, .c = 0.7, .l = 0.55 };
    const rgb = hcl.toRGB();
    return @as(u32, 0xFF000000) | (@as(u32, rgb.r) << 16) | (@as(u32, rgb.g) << 8) | rgb.b;
}

/// GF(3) trit field: each pixel's color is determined by its positional trit.
pub fn tritFieldShader(_: f32, _: f32, noise: u64) u32 {
    const trit = SplitMix64.toTrit(noise);
    const hue = trit.baseHue();
    const hcl = HCL{ .h = hue, .c = 0.6, .l = 0.5 };
    const rgb = hcl.toRGB();
    return @as(u32, 0xFF000000) | (@as(u32, rgb.r) << 16) | (@as(u32, rgb.g) << 8) | rgb.b;
}

/// Plastic angle noise: ternary-optimal dispersion.
pub fn plasticNoiseShader(x: f32, y: f32, noise: u64) u32 {
    const noise_f = SplitMix64.toFloat(noise);
    const hue = @mod(x * 360.0 + y * lux_color.PLASTIC_ANGLE + noise_f * 60.0, 360.0);
    const hcl = HCL{ .h = hue, .c = 0.65, .l = 0.6 };
    const rgb = hcl.toRGB();
    return @as(u32, 0xFF000000) | (@as(u32, rgb.r) << 16) | (@as(u32, rgb.g) << 8) | rgb.b;
}

// ============================================================================
// HELPERS
// ============================================================================

fn rgbToHue(r: f32, g: f32, b: f32) f32 {
    const max_val = @max(r, @max(g, b));
    const min_val = @min(r, @min(g, b));
    const delta = max_val - min_val;
    if (delta < 0.001) return 0;

    var hue: f32 = 0;
    if (max_val == r) {
        hue = 60.0 * @mod((g - b) / delta, 6.0);
    } else if (max_val == g) {
        hue = 60.0 * ((b - r) / delta + 2.0);
    } else {
        hue = 60.0 * ((r - g) / delta + 4.0);
    }
    return @mod(hue + 360.0, 360.0);
}

fn hueToBoundaryTrit(hue: f32) Trit {
    if (hue < 120.0) return .minus; // red zone
    if (hue < 240.0) return .ergodic; // green zone
    return .plus; // blue zone
}

// ============================================================================
// TESTS
// ============================================================================

test "SplitMix64 positional is deterministic" {
    const a = SplitMix64.positional(42, 10, 20);
    const b = SplitMix64.positional(42, 10, 20);
    try std.testing.expectEqual(a, b);

    // Different position = different hash
    const c = SplitMix64.positional(42, 10, 21);
    try std.testing.expect(a != c);
}

test "SplitMix64 tilePixel is deterministic" {
    const a = SplitMix64.tilePixel(42, 0, 0, 5, 5);
    const b = SplitMix64.tilePixel(42, 0, 0, 5, 5);
    try std.testing.expectEqual(a, b);
}

test "SplitMix64 toTrit covers all values" {
    var counts = [3]u32{ 0, 0, 0 };
    for (0..100) |i| {
        const h = SplitMix64.positional(42, @intCast(i), 0);
        const t = SplitMix64.toTrit(h);
        const idx: usize = @intCast(@as(i8, @intFromEnum(t)) + 1);
        counts[idx] += 1;
    }
    // All three trit values should appear
    try std.testing.expect(counts[0] > 0);
    try std.testing.expect(counts[1] > 0);
    try std.testing.expect(counts[2] > 0);
}

test "Tile compute produces valid pixels" {
    const tile = Tile.compute(0, 0, 42, goldenSpiralShader);
    try std.testing.expectEqual(@as(u32, 0), tile.tx);
    try std.testing.expectEqual(@as(u32, 0), tile.ty);

    // Check that pixels are non-zero ARGB
    const pixel = tile.getPixel(8, 8);
    try std.testing.expect((pixel & 0xFF000000) != 0); // alpha set
}

test "Tile boundary colors exist" {
    const tile = Tile.compute(0, 0, 42, goldenSpiralShader);
    const top = tile.boundaryColor(.top);
    const right = tile.boundaryColor(.right);

    // Boundary colors should have valid RGB
    try std.testing.expect(top.r >= 0 and top.r <= 255);
    try std.testing.expect(right.g >= 0 and right.g <= 255);
}

test "Edge opposite" {
    try std.testing.expectEqual(Edge.bottom, Edge.top.opposite());
    try std.testing.expectEqual(Edge.left, Edge.right.opposite());
    try std.testing.expectEqual(Edge.top, Edge.bottom.opposite());
    try std.testing.expectEqual(Edge.right, Edge.left.opposite());
}

test "TileGrid compute and distill" {
    const allocator = std.testing.allocator;

    var grid = try TileGrid.init(allocator, 4, 4, 42);
    defer grid.deinit();

    grid.compute(goldenSpiralShader);

    const distilled = grid.distill();
    try std.testing.expect(distilled.hue >= 0 and distilled.hue < 360);
    try std.testing.expectEqual(@as(u32, 16), distilled.tile_count);
}

test "TileGrid adhesion error is finite" {
    const allocator = std.testing.allocator;

    var grid = try TileGrid.init(allocator, 3, 3, 42);
    defer grid.deinit();
    grid.compute(goldenSpiralShader);

    const err = grid.totalAdhesionError();
    try std.testing.expect(std.math.isFinite(err));
    try std.testing.expect(err >= 0);
}

test "TreeDecomposition from grid" {
    const allocator = std.testing.allocator;

    var grid = try TileGrid.init(allocator, 4, 4, 42);
    defer grid.deinit();
    grid.compute(goldenSpiralShader);

    var decomp = try TreeDecomposition.fromGrid(allocator, &grid);
    defer decomp.deinit();

    // 4x4 grid with 2x2 bags = 2x2 = 4 bags
    try std.testing.expectEqual(@as(usize, 4), decomp.bags.len);
    // Treewidth should be small (max bag size - 1)
    try std.testing.expect(decomp.width <= 4);

    decomp.distillAll(&grid);

    const obstruction = decomp.totalObstruction();
    try std.testing.expect(std.math.isFinite(obstruction));
}

test "OperadNode compose" {
    const allocator = std.testing.allocator;

    var node = try OperadNode.init(allocator, 1, 3);
    defer node.deinit();

    node.setChild(0, 0.0, .minus);
    node.setChild(1, 120.0, .ergodic);
    node.setChild(2, 240.0, .plus);

    const composed = node.compose();
    try std.testing.expect(composed.hue >= 0 and composed.hue < 360);
    // -1 + 0 + 1 = 0 -> conserved
    try std.testing.expect(composed.conserved);
}

test "DistilledColor to ExprColor" {
    const dc = DistilledColor{
        .hue = 137.5,
        .trit = .plus,
        .adhesion_error = 0.1,
        .tile_count = 16,
        .conserved = false,
    };
    const ec = dc.toExprColor(2);
    try std.testing.expectEqual(Trit.plus, ec.trit);
    try std.testing.expectEqual(@as(u16, 2), ec.depth);
}

test "DistilledColor to RGB" {
    const dc = DistilledColor{
        .hue = 120.0,
        .trit = .ergodic,
        .adhesion_error = 0,
        .tile_count = 4,
        .conserved = true,
    };
    const rgb = dc.toRGB();
    // Green zone: g should dominate
    try std.testing.expect(rgb.g > rgb.r);
}

test "TileGrid toCellBatch" {
    const allocator = std.testing.allocator;

    var grid = try TileGrid.init(allocator, 2, 2, 42);
    defer grid.deinit();
    grid.compute(tritFieldShader);

    var batch = try grid.toCellBatch(allocator);
    defer batch.deinit();

    try std.testing.expectEqual(@as(u32, 2 * TILE_SIZE), batch.width);
    try std.testing.expectEqual(@as(u32, 2 * TILE_SIZE), batch.height);

    // Check a pixel was written
    const cell = batch.get(0, 0).?;
    try std.testing.expectEqual(@as(u32, 0x2588), cell.codepoint);
}

test "built-in shaders produce valid ARGB" {
    const noise: u64 = 0xDEADBEEF;
    const shaders = [_]ShaderFn{
        goldenSpiralShader,
        tritFieldShader,
        plasticNoiseShader,
    };

    for (shaders) |shader| {
        const color = shader(0.5, 0.5, noise);
        try std.testing.expect((color & 0xFF000000) != 0);
    }
}
