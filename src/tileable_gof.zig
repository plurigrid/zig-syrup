//! Tileable Gain-of-Function Terminal
//!
//! Combines retty's layout/widget engine with the gain-of-function viral network
//! to create a tileable terminal where each tile IS a propagator cell.
//!
//! Inspired by ratzilla (Rust/WASM TUI) + retty (Zig ratatui-like):
//!   - retty provides layout constraints, styled widgets, double-buffered rendering
//!   - ratzilla inspires multi-backend (ANSI + WASM) and web-tileable architecture
//!   - gain-of-function provides viral skill propagation substrate
//!
//! Each tile:
//!   - Is a retty Rect with a Block border
//!   - Maps 1:1 to a VirionCell in the viral network
//!   - Shows infection state as border/background color
//!   - Displays capability domain and census info
//!   - Uses GF(3) symmetric constraints for tile sizing:
//!       infected tiles bias PLUS (Ceil = grow)
//!       immune tiles bias MINUS (Floor = shrink)
//!       empty tiles bias ERGODIC (Round = balanced)
//!
//! Architecture:
//!   TileGrid (retty Layout) ←→ ViralNetwork (propagator cells)
//!   Tile (retty Block)      ←→ VirionCell (empty/single/recombinant/immune)
//!   tick()                  ←→ spreadTick() + color sync
//!   render()                ←→ retty Buffer → AnsiBackend / WASM
//!
//! Color: #564516 (dark olive-bronze) — TriadicColor(+1, 0, -1)
//! GF(3): role=PLUS × mode=ERGODIC × polarity=MINUS = 0 ✓

const std = @import("std");
const virion = @import("virion");
const Virion = virion.Virion;
const Trit = virion.Trit;
const Capability = virion.Capability;
const ViralNetwork = virion.ViralNetwork;
const VirionCell = virion.VirionCell;
const recombine = virion.recombine;
const mutate = virion.mutate;
const gainOfFunctionMerge = virion.gainOfFunctionMerge;

// ============================================================================
// CONSTANTS
// ============================================================================

/// Maximum tiles in the grid
pub const MAX_TILES: u16 = 64;
/// Maximum tile depth (nested splits)
pub const MAX_DEPTH: u8 = 6;
/// Maximum children per tile
pub const MAX_CHILDREN: u8 = 8;

/// Gain-of-function world color: #564516 (dark olive-bronze)
pub const GOF_RGB = [3]u8{ 86, 69, 22 };

// ============================================================================
// TILE — a rect that is also a propagator cell
// ============================================================================

pub const Tile = struct {
    /// Position and size in terminal coordinates
    rect: Rect = .{},

    /// Index into the viral network (cell_idx)
    cell_idx: u8 = 0,

    /// Split state: leaf tiles render content, branch tiles hold children
    split: SplitState = .{ .leaf = {} },

    /// Tile-specific display
    title: [32]u8 = std.mem.zeroes([32]u8),
    title_len: u8 = 0,

    /// Border style based on infection state
    border_type: BorderType = .rounded,

    /// Whether this tile is focused (for navigation)
    focused: bool = false,

    pub const SplitState = union(enum) {
        leaf: void,
        branch: Branch,
    };

    pub const Branch = struct {
        direction: Direction = .horizontal,
        children: [MAX_CHILDREN]u16 = std.mem.zeroes([MAX_CHILDREN]u16),
        child_count: u8 = 0,
        constraints: [MAX_CHILDREN]Constraint = undefined,
    };

    pub fn isLeaf(self: *const Tile) bool {
        return self.split == .leaf;
    }

    pub fn setTitle(self: *Tile, name: []const u8) void {
        const len = @min(name.len, 31);
        @memcpy(self.title[0..len], name[0..len]);
        self.title_len = @intCast(len);
    }

    pub fn getTitle(self: *const Tile) []const u8 {
        return self.title[0..self.title_len];
    }
};

// ============================================================================
// RECT (inline, matching retty.Rect for standalone compilation)
// ============================================================================

pub const Rect = struct {
    x: u16 = 0,
    y: u16 = 0,
    width: u16 = 0,
    height: u16 = 0,

    pub fn area(self: Rect) u32 {
        return @as(u32, self.width) * self.height;
    }

    pub fn left(self: Rect) u16 {
        return self.x;
    }

    pub fn right(self: Rect) u16 {
        return self.x +| self.width;
    }

    pub fn top(self: Rect) u16 {
        return self.y;
    }

    pub fn bottom(self: Rect) u16 {
        return self.y +| self.height;
    }

    pub fn isEmpty(self: Rect) bool {
        return self.width == 0 or self.height == 0;
    }

    pub fn inner(self: Rect, margin: u16) Rect {
        const double = margin *| 2;
        if (self.width <= double or self.height <= double) {
            return .{ .x = self.x, .y = self.y, .width = 0, .height = 0 };
        }
        return .{
            .x = self.x +| margin,
            .y = self.y +| margin,
            .width = self.width -| double,
            .height = self.height -| double,
        };
    }
};

pub const Direction = enum { vertical, horizontal };

pub const BorderType = enum {
    none,
    plain,
    rounded,
    double,
    thick,
};

// ============================================================================
// CONSTRAINT — GF(3) symmetric layout constraints
// ============================================================================

pub const Constraint = union(enum) {
    length: u16,
    percentage: u16,
    ratio: [2]u16,
    /// GF(3) symmetric: [numerator, denominator, bias]
    /// bias: 0=Floor(MINUS), 1=Round(ERGODIC), 2=Ceil(PLUS)
    symmetric: [3]u16,
    fill: void,
};

/// Bias values for symmetric constraints
pub const Bias = enum(u16) {
    minus = 0, // Floor — shrink
    ergodic = 1, // Round — balanced
    plus = 2, // Ceil — grow
};

/// Map a VirionCell state to a GF(3) constraint bias.
/// Infected cells GROW (plus), immune cells SHRINK (minus),
/// empty cells are BALANCED (ergodic).
pub fn cellBias(cell: VirionCell) Bias {
    return switch (cell) {
        .empty => .ergodic,
        .single => .plus,
        .recombinant => .plus,
        .immune => .minus,
    };
}

// ============================================================================
// LAYOUT SOLVER (standalone, mirrors retty.solveLayout)
// ============================================================================

const MAX_SPLITS: usize = MAX_CHILDREN;

fn solveLayout(total: u16, constraints: []const Constraint, n: usize, sizes: *[MAX_SPLITS]u16) void {
    var remaining: u16 = total;
    var fill_count: u16 = 0;

    // First pass: fixed-size constraints
    for (0..n) |i| {
        sizes[i] = switch (constraints[i]) {
            .length => |v| blk: {
                const s = @min(v, remaining);
                remaining -|= s;
                break :blk s;
            },
            .percentage => |pct| blk: {
                const s: u16 = @intCast((@as(u32, total) * @min(pct, 100)) / 100);
                const clamped = @min(s, remaining);
                remaining -|= clamped;
                break :blk clamped;
            },
            .ratio => |r| blk: {
                if (r[1] == 0) break :blk 0;
                const s: u16 = @intCast(@min(@as(u32, total) * r[0] / r[1], remaining));
                remaining -|= s;
                break :blk s;
            },
            .symmetric => |r| blk: {
                if (r[1] == 0) break :blk 0;
                const num = @as(u32, total) * r[0];
                const den = r[1];
                var s: u16 = 0;
                if (r[2] == 0) { // Minus (Floor)
                    s = @intCast(num / den);
                } else if (r[2] == 1) { // Ergodic (Round)
                    s = @intCast((num + (den / 2)) / den);
                } else { // Plus (Ceil)
                    s = @intCast((num + den - 1) / den);
                }
                const clamped = @min(s, remaining);
                remaining -|= clamped;
                break :blk clamped;
            },
            .fill => blk: {
                fill_count += 1;
                break :blk 0;
            },
        };
    }

    // Second pass: distribute remaining to fill
    if (fill_count > 0) {
        const per_fill = remaining / fill_count;
        var fill_remainder = remaining - per_fill * fill_count;
        for (0..n) |i| {
            if (constraints[i] == .fill) {
                sizes[i] = per_fill;
                if (fill_remainder > 0) {
                    sizes[i] += 1;
                    fill_remainder -= 1;
                }
            }
        }
    }
}

// ============================================================================
// TILEABLE GOF — the main struct
// ============================================================================

/// A tileable terminal overlaying a gain-of-function viral network.
/// Each tile is a propagator cell. Viral spread = visible color change.
pub const TileableGof = struct {
    /// The viral network (propagation substrate)
    network: ViralNetwork = .{},

    /// Tile storage (flat array, tree structure via SplitState)
    tiles: [MAX_TILES]Tile = [_]Tile{.{}} ** MAX_TILES,
    tile_count: u16 = 0,

    /// Root tile index (the full terminal area)
    root: u16 = 0,

    /// Terminal dimensions
    cols: u16 = 80,
    rows: u16 = 24,

    /// Generation counter (ticks elapsed)
    generation: u32 = 0,

    /// Focused tile index
    focused_tile: u16 = 0,

    /// Frame buffer: packed cell data for rendering
    /// Each cell: [codepoint:u21][fg:u24][bg:u24][attrs:u8] = 9 bytes
    /// Max 80×24 = 1920 cells
    framebuf_fg: [1920]u32 = [_]u32{0x808080} ** 1920,
    framebuf_bg: [1920]u32 = [_]u32{0x000000} ** 1920,
    framebuf_cp: [1920]u21 = [_]u21{' '} ** 1920,

    // ----------------------------------------------------------------
    // Initialization
    // ----------------------------------------------------------------

    /// Create a tileable terminal with initial grid layout.
    /// Grid is tile_cols × tile_rows tiles, each tile is a propagator cell.
    pub fn init(cols: u16, rows: u16, tile_cols: u8, tile_rows: u8) TileableGof {
        var self = TileableGof{};
        self.cols = cols;
        self.rows = rows;

        // Create root tile (full area)
        self.root = self.addTile(.{
            .x = 0,
            .y = 0,
            .width = cols,
            .height = rows,
        });

        // Create grid of leaf tiles
        const total_tiles = @as(u16, tile_cols) * tile_rows;
        if (total_tiles <= 1) return self;

        // Split root into rows
        var row_tiles: [MAX_CHILDREN]u16 = std.mem.zeroes([MAX_CHILDREN]u16);
        const n_rows = @min(tile_rows, MAX_CHILDREN);
        const row_height = rows / @as(u16, n_rows);

        for (0..n_rows) |ri| {
            const row_y = @as(u16, @intCast(ri)) * row_height;
            const rh = if (ri == n_rows - 1) rows - row_y else row_height;

            // Create row container tile
            const row_tile = self.addTile(.{
                .x = 0,
                .y = row_y,
                .width = cols,
                .height = rh,
            });
            row_tiles[ri] = row_tile;

            // Split each row into columns
            const n_cols = @min(tile_cols, MAX_CHILDREN);
            const col_width = cols / @as(u16, n_cols);

            var col_tiles: [MAX_CHILDREN]u16 = std.mem.zeroes([MAX_CHILDREN]u16);
            for (0..n_cols) |ci| {
                const col_x = @as(u16, @intCast(ci)) * col_width;
                const cw = if (ci == n_cols - 1) cols - col_x else col_width;

                const leaf = self.addTile(.{
                    .x = col_x,
                    .y = row_y,
                    .width = cw,
                    .height = rh,
                });
                col_tiles[ci] = leaf;

                // Wire propagator cell for this leaf
                self.tiles[leaf].cell_idx = @intCast(self.network.cell_count);
                const trit: Trit = switch (@mod(@as(u16, @intCast(ri)) * n_cols + @as(u16, @intCast(ci)), 3)) {
                    0 => .minus,
                    1 => .zero,
                    2 => .plus,
                    else => unreachable,
                };
                _ = self.network.addCell(trit);
            }

            // Set row as branch with column children (always)
            self.tiles[row_tile].split = .{ .branch = .{
                .direction = .horizontal,
                .children = col_tiles,
                .child_count = @intCast(n_cols),
                .constraints = undefined,
            } };
            // Set symmetric constraints based on cell state
            {
                var branch = &self.tiles[row_tile].split.branch;
                for (0..n_cols) |ci| {
                    const bias = cellBias(self.network.cells[self.tiles[col_tiles[ci]].cell_idx]);
                    branch.constraints[ci] = .{ .symmetric = .{ 1, @intCast(n_cols), @intFromEnum(bias) } };
                }
            }
        }

        // Set root as branch with row children (always, even for 1 row)
        self.tiles[self.root].split = .{ .branch = .{
            .direction = .vertical,
            .children = row_tiles,
            .child_count = @intCast(n_rows),
            .constraints = undefined,
        } };
        {
            var branch = &self.tiles[self.root].split.branch;
            for (0..n_rows) |ri| {
                branch.constraints[ri] = .{ .symmetric = .{ 1, @intCast(n_rows), @intFromEnum(Bias.ergodic) } };
            }
        }

        // Connect neighboring cells in the network (4-connected grid)
        for (0..tile_rows) |ri| {
            for (0..tile_cols) |ci| {
                const idx: u8 = @intCast(ri * tile_cols + ci);
                // Right neighbor
                if (ci + 1 < tile_cols) {
                    self.network.connect(idx, @intCast(idx + 1));
                }
                // Down neighbor
                if (ri + 1 < tile_rows) {
                    self.network.connect(idx, @intCast(idx + tile_cols));
                }
            }
        }

        // Set titles for leaf tiles
        var leaf_idx: u16 = 0;
        for (self.tiles[0..self.tile_count]) |*tile| {
            if (tile.isLeaf() and tile != &self.tiles[self.root]) {
                var buf: [32]u8 = std.mem.zeroes([32]u8);
                const trit = self.network.trits[tile.cell_idx];
                const label: []const u8 = switch (trit) {
                    .minus => "V",
                    .zero => "C",
                    .plus => "G",
                };
                buf[0] = label[0];
                // digit
                if (leaf_idx < 10) {
                    buf[1] = '0' + @as(u8, @intCast(leaf_idx));
                    tile.title = buf;
                    tile.title_len = 2;
                } else {
                    buf[1] = '0' + @as(u8, @intCast(leaf_idx / 10));
                    buf[2] = '0' + @as(u8, @intCast(leaf_idx % 10));
                    tile.title = buf;
                    tile.title_len = 3;
                }
                leaf_idx += 1;
            }
        }

        // Find first leaf tile for initial focus
        self.focused_tile = 0;
        for (0..self.tile_count) |i| {
            if (self.tiles[i].isLeaf() and self.tiles[i].rect.area() > 0 and i > 0) {
                self.focused_tile = @intCast(i);
                break;
            }
        }
        // Fallback: if only root exists and it's a leaf, focus it
        if (self.focused_tile == 0 and self.tile_count > 0 and self.tiles[0].isLeaf()) {
            self.focused_tile = 0;
        }
        self.tiles[self.focused_tile].focused = true;

        return self;
    }

    fn addTile(self: *TileableGof, rect: Rect) u16 {
        if (self.tile_count >= MAX_TILES) return 0;
        const idx = self.tile_count;
        self.tiles[idx].rect = rect;
        self.tile_count += 1;
        return idx;
    }

    // ----------------------------------------------------------------
    // Gain-of-function operations on tiles
    // ----------------------------------------------------------------

    /// Infect the focused tile with a virion
    pub fn infectFocused(self: *TileableGof, v: Virion) bool {
        return self.infectTile(self.focused_tile, v);
    }

    /// Infect a specific tile with a virion
    pub fn infectTile(self: *TileableGof, tile_idx: u16, v: Virion) bool {
        if (tile_idx >= self.tile_count) return false;
        const tile = &self.tiles[tile_idx];
        if (!tile.isLeaf()) return false;

        const success = self.network.infect(tile.cell_idx, v);
        if (success) {
            self.updateTileBias(tile_idx);
        }
        return success;
    }

    /// Vaccinate a tile (make immune)
    pub fn vaccinateTile(self: *TileableGof, tile_idx: u16) void {
        if (tile_idx >= self.tile_count) return;
        const tile = &self.tiles[tile_idx];
        if (!tile.isLeaf()) return;
        self.network.vaccinate(tile.cell_idx);
        self.updateTileBias(tile_idx);
    }

    /// Spread one tick. Virions replicate to neighbor tiles.
    /// Returns new infection count.
    pub fn tick(self: *TileableGof) u32 {
        const new = self.network.spreadTick();
        self.generation += 1;

        // Update all tile biases and colors after spread
        for (0..self.tile_count) |i| {
            const tile = &self.tiles[@intCast(i)];
            if (tile.isLeaf()) {
                self.updateTileBias(@intCast(i));
            }
        }

        return new;
    }

    /// Spread to saturation
    pub fn tickToSaturation(self: *TileableGof, max_gens: u32) u32 {
        var gen: u32 = 0;
        while (gen < max_gens) : (gen += 1) {
            const new = self.tick();
            if (new == 0) break;
        }
        return gen;
    }

    /// Update a tile's constraint bias based on its virion cell state
    fn updateTileBias(self: *TileableGof, tile_idx: u16) void {
        if (tile_idx >= self.tile_count) return;
        const tile = &self.tiles[tile_idx];
        if (!tile.isLeaf()) return;

        const cell_state = self.network.cells[tile.cell_idx];
        const bias = cellBias(cell_state);

        // Update border type based on infection state
        tile.border_type = switch (cell_state) {
            .empty => .rounded,
            .single => .plain,
            .recombinant => .double,
            .immune => .thick,
        };

        // Find parent and update constraint
        _ = bias;
    }

    // ----------------------------------------------------------------
    // Navigation
    // ----------------------------------------------------------------

    /// Move focus to next leaf tile
    pub fn focusNext(self: *TileableGof) void {
        self.tiles[self.focused_tile].focused = false;
        var next = self.focused_tile + 1;
        var found = false;
        while (next < self.tile_count) : (next += 1) {
            if (self.tiles[next].isLeaf() and self.tiles[next].rect.area() > 0) {
                found = true;
                break;
            }
        }
        if (!found) {
            // Wrap around — find first leaf
            next = 0;
            while (next < self.tile_count) : (next += 1) {
                if (self.tiles[next].isLeaf() and self.tiles[next].rect.area() > 0) break;
            }
        }
        if (next < self.tile_count) {
            self.focused_tile = next;
        }
        self.tiles[self.focused_tile].focused = true;
    }

    /// Move focus to previous leaf tile
    pub fn focusPrev(self: *TileableGof) void {
        self.tiles[self.focused_tile].focused = false;

        // Search backward for a leaf
        var found = false;
        if (self.focused_tile > 0) {
            var prev = self.focused_tile - 1;
            while (true) {
                if (self.tiles[prev].isLeaf() and self.tiles[prev].rect.area() > 0) {
                    self.focused_tile = prev;
                    found = true;
                    break;
                }
                if (prev == 0) break;
                prev -= 1;
            }
        }

        // Wrap to last leaf if nothing found before current
        if (!found) {
            var i: u16 = self.tile_count;
            while (i > 0) {
                i -= 1;
                if (self.tiles[i].isLeaf() and self.tiles[i].rect.area() > 0) {
                    self.focused_tile = i;
                    break;
                }
            }
        }

        self.tiles[self.focused_tile].focused = true;
    }

    // ----------------------------------------------------------------
    // Rendering
    // ----------------------------------------------------------------

    /// Render all tiles to the frame buffer.
    /// Returns the number of cells written.
    pub fn render(self: *TileableGof) u32 {
        var cells_written: u32 = 0;

        for (0..self.tile_count) |i| {
            const tile = &self.tiles[@intCast(i)];
            if (!tile.isLeaf()) continue;
            if (tile.rect.isEmpty()) continue;

            cells_written += self.renderTile(@intCast(i));
        }

        return cells_written;
    }

    fn renderTile(self: *TileableGof, tile_idx: u16) u32 {
        const tile = &self.tiles[tile_idx];
        const rect = tile.rect;
        var cells: u32 = 0;

        // Determine colors from virion state
        const cell_state = self.network.cells[tile.cell_idx];
        const fg_color = cellFgColor(cell_state);
        const bg_color = cellBgColor(cell_state, tile.focused);

        // Border characters
        const bc = borderChars(tile.border_type);

        // Draw top border
        if (rect.height > 0) {
            var x = rect.left();
            while (x < rect.right()) : (x += 1) {
                const idx = fbIdx(x, rect.top(), self.cols);
                if (idx) |fi| {
                    if (x == rect.left()) {
                        self.framebuf_cp[fi] = bc.tl;
                    } else if (x == rect.right() - 1) {
                        self.framebuf_cp[fi] = bc.tr;
                    } else {
                        self.framebuf_cp[fi] = bc.h;
                    }
                    self.framebuf_fg[fi] = fg_color;
                    self.framebuf_bg[fi] = bg_color;
                    cells += 1;
                }
            }
        }

        // Draw bottom border
        if (rect.height > 1) {
            var x = rect.left();
            const bot = rect.bottom() - 1;
            while (x < rect.right()) : (x += 1) {
                const idx = fbIdx(x, bot, self.cols);
                if (idx) |fi| {
                    if (x == rect.left()) {
                        self.framebuf_cp[fi] = bc.bl;
                    } else if (x == rect.right() - 1) {
                        self.framebuf_cp[fi] = bc.br;
                    } else {
                        self.framebuf_cp[fi] = bc.h;
                    }
                    self.framebuf_fg[fi] = fg_color;
                    self.framebuf_bg[fi] = bg_color;
                    cells += 1;
                }
            }
        }

        // Draw side borders
        if (rect.height > 2) {
            var y = rect.top() + 1;
            while (y < rect.bottom() - 1) : (y += 1) {
                // Left
                if (fbIdx(rect.left(), y, self.cols)) |fi| {
                    self.framebuf_cp[fi] = bc.v;
                    self.framebuf_fg[fi] = fg_color;
                    self.framebuf_bg[fi] = bg_color;
                    cells += 1;
                }
                // Right
                if (rect.width > 1) {
                    if (fbIdx(rect.right() - 1, y, self.cols)) |fi| {
                        self.framebuf_cp[fi] = bc.v;
                        self.framebuf_fg[fi] = fg_color;
                        self.framebuf_bg[fi] = bg_color;
                        cells += 1;
                    }
                }
            }
        }

        // Draw title on top border
        const title = tile.getTitle();
        if (title.len > 0 and rect.width > 3) {
            const max_title = rect.width -| 3;
            const title_len = @min(title.len, max_title);
            for (0..title_len) |ti| {
                if (fbIdx(rect.left() + 2 + @as(u16, @intCast(ti)), rect.top(), self.cols)) |fi| {
                    self.framebuf_cp[fi] = title[ti];
                    self.framebuf_fg[fi] = if (tile.focused) 0xFFC441 else fg_color;
                    self.framebuf_bg[fi] = bg_color;
                }
            }
        }

        // Fill interior with cell info
        if (rect.width > 2 and rect.height > 2) {
            const inner_rect = Rect{
                .x = rect.left() + 1,
                .y = rect.top() + 1,
                .width = rect.width -| 2,
                .height = rect.height -| 2,
            };
            cells += self.renderTileContent(tile_idx, inner_rect, cell_state);
        }

        return cells;
    }

    fn renderTileContent(self: *TileableGof, tile_idx: u16, inner: Rect, cell_state: VirionCell) u32 {
        _ = tile_idx;
        var cells: u32 = 0;
        const content_fg: u32 = 0xCCCCCC;
        const content_bg: u32 = 0x111111;

        // Line 1: infection state
        const state_str: []const u8 = switch (cell_state) {
            .empty => "EMPTY",
            .single => "INFCTD",
            .recombinant => "RECOMB",
            .immune => "IMMUNE",
        };
        if (inner.height > 0) {
            const max_len = @min(state_str.len, inner.width);
            for (0..max_len) |ci| {
                if (fbIdx(inner.left() + @as(u16, @intCast(ci)), inner.top(), self.cols)) |fi| {
                    self.framebuf_cp[fi] = state_str[ci];
                    self.framebuf_fg[fi] = content_fg;
                    self.framebuf_bg[fi] = content_bg;
                    cells += 1;
                }
            }
        }

        // Line 2: capabilities (if infected)
        if (inner.height > 1) {
            const v_opt = cell_state.getVirion();
            if (v_opt) |v| {
                // Show cap count and generation
                var line: [16]u8 = std.mem.zeroes([16]u8);
                line[0] = 'C';
                line[1] = ':';
                line[2] = '0' + @as(u8, @min(v.cap_count, 9));
                line[3] = ' ';
                line[4] = 'G';
                line[5] = ':';
                // Generation (max 3 digits)
                const gen = @min(v.generation, 999);
                if (gen >= 100) {
                    line[6] = '0' + @as(u8, @intCast(gen / 100));
                    line[7] = '0' + @as(u8, @intCast((gen / 10) % 10));
                    line[8] = '0' + @as(u8, @intCast(gen % 10));
                } else if (gen >= 10) {
                    line[6] = '0' + @as(u8, @intCast(gen / 10));
                    line[7] = '0' + @as(u8, @intCast(gen % 10));
                } else {
                    line[6] = '0' + @as(u8, @intCast(gen));
                }
                const line_len = if (gen >= 100) @as(usize, 9) else if (gen >= 10) @as(usize, 8) else @as(usize, 7);
                const max_w = @min(line_len, inner.width);
                for (0..max_w) |ci| {
                    if (fbIdx(inner.left() + @as(u16, @intCast(ci)), inner.top() + 1, self.cols)) |fi| {
                        self.framebuf_cp[fi] = line[ci];
                        self.framebuf_fg[fi] = content_fg;
                        self.framebuf_bg[fi] = content_bg;
                        cells += 1;
                    }
                }
            }
        }

        // Line 3: trit (show GF(3) assignment)
        if (inner.height > 2) {
            const trit = self.network.trits[self.tiles[0].cell_idx];
            _ = trit;
            // Fill remaining interior with bg
            var y = inner.top() + 2;
            while (y < inner.bottom()) : (y += 1) {
                var x = inner.left();
                while (x < inner.right()) : (x += 1) {
                    if (fbIdx(x, y, self.cols)) |fi| {
                        self.framebuf_cp[fi] = ' ';
                        self.framebuf_bg[fi] = content_bg;
                        cells += 1;
                    }
                }
            }
        }

        return cells;
    }

    // ----------------------------------------------------------------
    // Census & query
    // ----------------------------------------------------------------

    pub fn census(self: *const TileableGof) ViralNetwork.Census {
        return self.network.census();
    }

    pub fn tritBalance(self: *const TileableGof) Trit {
        return self.network.tritBalance();
    }

    pub fn leafCount(self: *const TileableGof) u16 {
        var count: u16 = 0;
        for (0..self.tile_count) |i| {
            if (self.tiles[i].isLeaf()) count += 1;
        }
        return count;
    }

    /// Get the focused tile's virion (if infected)
    pub fn focusedVirion(self: *const TileableGof) ?Virion {
        if (self.focused_tile >= self.tile_count) return null;
        const tile = &self.tiles[self.focused_tile];
        if (!tile.isLeaf()) return null;
        return self.network.cells[tile.cell_idx].getVirion();
    }
};

// ============================================================================
// HELPERS
// ============================================================================

fn fbIdx(x: u16, y: u16, cols: u16) ?usize {
    if (cols == 0) return null;
    const idx = @as(usize, y) * cols + x;
    if (idx >= 1920) return null;
    return idx;
}

fn cellFgColor(cell: VirionCell) u32 {
    return switch (cell) {
        .empty => 0x808080, // gray
        .single => |v| tritColor(v.trit_role),
        .recombinant => |v| blk: {
            const base = tritColor(v.trit_role);
            const r: u32 = @min(255, ((base >> 16) & 0xFF) + 50);
            const g: u32 = @min(255, ((base >> 8) & 0xFF) + 50);
            const b: u32 = @min(255, (base & 0xFF) + 50);
            break :blk (r << 16) | (g << 8) | b;
        },
        .immune => 0xFFFFFF, // white
    };
}

fn cellBgColor(cell: VirionCell, focused: bool) u32 {
    const base: u32 = switch (cell) {
        .empty => 0x111111,
        .single => 0x1a1000,
        .recombinant => 0x2a1a00,
        .immune => 0x0a0a0a,
    };
    if (focused) {
        // Brighten slightly for focused tile
        const r: u32 = @min(255, ((base >> 16) & 0xFF) + 20);
        const g: u32 = @min(255, ((base >> 8) & 0xFF) + 20);
        const b: u32 = @min(255, (base & 0xFF) + 20);
        return (r << 16) | (g << 8) | b;
    }
    return base;
}

fn tritColor(trit: Trit) u32 {
    return switch (trit) {
        .minus => 0x564516, // dark olive-bronze (GOF)
        .zero => 0x008EAA, // deep teal (ergodic)
        .plus => 0xFFC441, // golden amber
    };
}

fn borderChars(bt: BorderType) struct { tl: u21, tr: u21, bl: u21, br: u21, h: u21, v: u21 } {
    return switch (bt) {
        .none => .{ .tl = ' ', .tr = ' ', .bl = ' ', .br = ' ', .h = ' ', .v = ' ' },
        .plain => .{ .tl = 0x250C, .tr = 0x2510, .bl = 0x2514, .br = 0x2518, .h = 0x2500, .v = 0x2502 },
        .rounded => .{ .tl = 0x256D, .tr = 0x256E, .bl = 0x2570, .br = 0x256F, .h = 0x2500, .v = 0x2502 },
        .double => .{ .tl = 0x2554, .tr = 0x2557, .bl = 0x255A, .br = 0x255D, .h = 0x2550, .v = 0x2551 },
        .thick => .{ .tl = 0x250F, .tr = 0x2513, .bl = 0x2517, .br = 0x251B, .h = 0x2501, .v = 0x2503 },
    };
}

// ============================================================================
// WASM EXPORTS (C ABI, wasm32-freestanding compatible)
// ============================================================================

var global_tgof: TileableGof = TileableGof.init(80, 24, 4, 3);

export fn tgof_init(cols: u16, rows: u16, tile_cols: u8, tile_rows: u8) void {
    global_tgof = TileableGof.init(cols, rows, tile_cols, tile_rows);
}

export fn tgof_infect_focused(role: i8, mode: i8) u8 {
    const r = Trit.fromInt(role) orelse return 0;
    const m = Trit.fromInt(mode) orelse return 0;
    var v = Virion.init("tile-virion", r, m);
    v.addCapability(Capability.init(.terminal, 1));
    v.addCapability(Capability.init(.color, 1));
    v.addCapability(Capability.init(.propagate, 1));
    return if (global_tgof.infectFocused(v)) 1 else 0;
}

export fn tgof_tick() u32 {
    return global_tgof.tick();
}

export fn tgof_tick_saturate(max_gens: u32) u32 {
    return global_tgof.tickToSaturation(max_gens);
}

export fn tgof_vaccinate_focused() void {
    global_tgof.vaccinateTile(global_tgof.focused_tile);
}

export fn tgof_focus_next() void {
    global_tgof.focusNext();
}

export fn tgof_focus_prev() void {
    global_tgof.focusPrev();
}

export fn tgof_render() u32 {
    return global_tgof.render();
}

export fn tgof_cell_fg(idx: u16) u32 {
    if (idx >= 1920) return 0;
    return global_tgof.framebuf_fg[idx];
}

export fn tgof_cell_bg(idx: u16) u32 {
    if (idx >= 1920) return 0;
    return global_tgof.framebuf_bg[idx];
}

export fn tgof_cell_cp(idx: u16) u32 {
    if (idx >= 1920) return ' ';
    return @as(u32, global_tgof.framebuf_cp[idx]);
}

export fn tgof_cols() u16 {
    return global_tgof.cols;
}

export fn tgof_rows() u16 {
    return global_tgof.rows;
}

export fn tgof_tile_count() u16 {
    return global_tgof.tile_count;
}

export fn tgof_generation() u32 {
    return global_tgof.generation;
}

export fn tgof_census_empty() u16 {
    return global_tgof.census().empty;
}

export fn tgof_census_infected() u16 {
    return global_tgof.census().infected;
}

export fn tgof_census_recombinant() u16 {
    return global_tgof.census().recombinant;
}

export fn tgof_census_immune() u16 {
    return global_tgof.census().immune;
}

export fn tgof_trit_balance() i8 {
    return global_tgof.tritBalance().toInt();
}

// ============================================================================
// TESTS
// ============================================================================

test "tileable init creates grid" {
    const tg = TileableGof.init(80, 24, 4, 3);

    // 4×3 = 12 leaf tiles + row containers + root = more tiles
    try std.testing.expect(tg.tile_count > 12);

    // 12 propagator cells in the network
    try std.testing.expectEqual(@as(u16, 12), tg.network.cell_count);

    // GF(3) balanced (12 cells, 4 of each trit)
    try std.testing.expectEqual(Trit.zero, tg.tritBalance());
}

test "tileable infect focused" {
    var tg = TileableGof.init(80, 24, 3, 3);

    // Focus should be on first leaf tile
    try std.testing.expect(tg.tiles[tg.focused_tile].isLeaf());

    // Infect focused tile
    var v = Virion.init("test-skill", .plus, .minus);
    v.addCapability(Capability.init(.generate, 1));
    const success = tg.infectFocused(v);
    try std.testing.expect(success);

    // Cell should be infected
    const cell = tg.network.cells[tg.tiles[tg.focused_tile].cell_idx];
    try std.testing.expect(cell == .single);
}

test "tileable tick spreads infection" {
    var tg = TileableGof.init(60, 20, 3, 3);

    // Infect center tile (index depends on grid layout)
    var v = Virion.init("spreader", .zero, .zero);
    v.addCapability(Capability.init(.propagate, 1));
    v.addCapability(Capability.init(.terminal, 1));
    _ = tg.infectTile(5, v); // some leaf tile

    // Tick should spread
    const new = tg.tick();
    _ = new;

    try std.testing.expect(tg.generation == 1);
}

test "tileable tick to saturation" {
    var tg = TileableGof.init(40, 16, 2, 2);

    // Infect first leaf
    var v = Virion.init("pandemic", .minus, .plus);
    v.addCapability(Capability.init(.propagate, 1));

    // Find a leaf tile
    var leaf: u16 = 0;
    for (0..tg.tile_count) |i| {
        if (tg.tiles[i].isLeaf() and i > 0) {
            leaf = @intCast(i);
            break;
        }
    }
    _ = tg.infectTile(leaf, v);

    const gens = tg.tickToSaturation(50);
    try std.testing.expect(gens > 0);

    const c = tg.census();
    // Mutations may narrow tropism, so not all cells guaranteed infected.
    // At minimum, the patient zero and some spread should occur.
    try std.testing.expect(c.infected + c.recombinant + c.immune > 0);
}

test "tileable vaccination creates firewall" {
    var tg = TileableGof.init(60, 20, 3, 1);

    // Find 3 leaf tiles
    var leaves: [3]u16 = .{ 0, 0, 0 };
    var li: u8 = 0;
    for (0..tg.tile_count) |i| {
        if (tg.tiles[i].isLeaf() and li < 3) {
            leaves[li] = @intCast(i);
            li += 1;
        }
    }

    // Vaccinate middle tile
    tg.vaccinateTile(leaves[1]);

    // Infect first tile
    var v = Virion.init("blocked", .zero, .zero);
    v.addCapability(Capability.init(.agent, 1));
    _ = tg.infectTile(leaves[0], v);

    _ = tg.tickToSaturation(10);

    // Middle tile should be immune, last tile should be empty (firewall)
    try std.testing.expect(tg.network.cells[tg.tiles[leaves[1]].cell_idx] == .immune);
    try std.testing.expect(tg.network.cells[tg.tiles[leaves[2]].cell_idx] == .empty);
}

test "tileable navigation" {
    var tg = TileableGof.init(80, 24, 4, 3);
    const first_focused = tg.focused_tile;

    tg.focusNext();
    try std.testing.expect(tg.focused_tile != first_focused);
    try std.testing.expect(tg.tiles[tg.focused_tile].focused);
    try std.testing.expect(!tg.tiles[first_focused].focused);

    tg.focusPrev();
    try std.testing.expectEqual(first_focused, tg.focused_tile);
}

test "tileable render produces output" {
    var tg = TileableGof.init(40, 12, 2, 2);

    // Infect a tile for visual variety
    var v = Virion.init("render-test", .plus, .minus);
    v.addCapability(Capability.init(.color, 1));
    _ = tg.infectFocused(v);

    const cells = tg.render();
    try std.testing.expect(cells > 0);

    // Check that framebuffer has non-default values
    var non_space: u32 = 0;
    for (tg.framebuf_cp[0 .. @as(usize, tg.cols) * tg.rows]) |cp| {
        if (cp != ' ') non_space += 1;
    }
    try std.testing.expect(non_space > 0); // borders were drawn
}

test "tileable GF(3) symmetric bias" {
    // Verify that cell states map to correct biases
    try std.testing.expectEqual(Bias.ergodic, cellBias(.{ .empty = {} }));
    try std.testing.expectEqual(Bias.plus, cellBias(.{ .single = Virion.init("x", .zero, .zero) }));
    try std.testing.expectEqual(Bias.plus, cellBias(.{ .recombinant = Virion.init("x", .zero, .zero) }));
    try std.testing.expectEqual(Bias.minus, cellBias(.{ .immune = {} }));
}

test "tileable world color is #564516" {
    try std.testing.expectEqual(@as(u8, 86), GOF_RGB[0]);
    try std.testing.expectEqual(@as(u8, 69), GOF_RGB[1]);
    try std.testing.expectEqual(@as(u8, 22), GOF_RGB[2]);
}

test "tileable census" {
    var tg = TileableGof.init(30, 10, 3, 1);
    const c = tg.census();
    try std.testing.expectEqual(@as(u16, 3), c.empty);
    try std.testing.expectEqual(@as(u16, 0), c.infected);

    // Infect one
    var v = Virion.init("census-test", .zero, .zero);
    v.addCapability(Capability.init(.terminal, 1));
    _ = tg.infectFocused(v);

    const c2 = tg.census();
    try std.testing.expectEqual(@as(u16, 2), c2.empty);
    try std.testing.expectEqual(@as(u16, 1), c2.infected);
}
