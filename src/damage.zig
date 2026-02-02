//! Terminal Frame Damage Tracking
//!
//! Efficient dirty-cell tracking for terminal multiplexers.
//! Tracks damage across multiple PTY/TTY panes like boxxy.
//!
//! Inspired by:
//! - notcurses damage tracking
//! - egui immediate-mode repaint regions  
//! - wezterm/ghostty cell diffing
//! - tree-sitter incremental parsing edits
//!
//! No demos. Worlds only.

const std = @import("std");
const syrup = @import("syrup.zig");
const Allocator = std.mem.Allocator;

/// World identifier (Grove sphere index)
pub const WorldId = u64;

/// Tile coordinates within a world
pub const TileCoord = struct {
    x: i32,
    y: i32,
    z: i32 = 0, // Layer/depth

    pub fn hash(self: TileCoord) u64 {
        const hx: u64 = @bitCast(@as(i64, self.x));
        const hy: u64 = @bitCast(@as(i64, self.y));
        const hz: u64 = @bitCast(@as(i64, self.z));
        return hx *% 0x517cc1b727220a95 +% hy *% 0x77f4a7c5e8d2bc5d +% hz;
    }

    pub fn eql(a: TileCoord, b: TileCoord) bool {
        return a.x == b.x and a.y == b.y and a.z == b.z;
    }
};

/// Axis-aligned bounding box for damage regions
pub const AABB = struct {
    min_x: i32,
    min_y: i32,
    max_x: i32,
    max_y: i32,
    z: i32 = 0,

    pub fn contains(self: AABB, coord: TileCoord) bool {
        return coord.x >= self.min_x and coord.x <= self.max_x and
            coord.y >= self.min_y and coord.y <= self.max_y and
            coord.z == self.z;
    }

    pub fn area(self: AABB) u64 {
        const w: u64 = @intCast(@max(0, self.max_x - self.min_x + 1));
        const h: u64 = @intCast(@max(0, self.max_y - self.min_y + 1));
        return w * h;
    }

    pub fn merge(a: AABB, b: AABB) AABB {
        return .{
            .min_x = @min(a.min_x, b.min_x),
            .min_y = @min(a.min_y, b.min_y),
            .max_x = @max(a.max_x, b.max_x),
            .max_y = @max(a.max_y, b.max_y),
            .z = a.z,
        };
    }

    pub fn intersects(a: AABB, b: AABB) bool {
        return a.min_x <= b.max_x and a.max_x >= b.min_x and
            a.min_y <= b.max_y and a.max_y >= b.min_y and
            a.z == b.z;
    }

    pub fn fromTile(coord: TileCoord) AABB {
        return .{
            .min_x = coord.x,
            .min_y = coord.y,
            .max_x = coord.x,
            .max_y = coord.y,
            .z = coord.z,
        };
    }
};

/// Damage cause for debugging/tracing
pub const DamageCause = enum(u8) {
    world_transition, // Grove sphere hop
    state_mutation, // Local state change
    external_event, // Input, network, etc.
    cascade, // Propagated from neighbor
    full_redraw, // Forced invalidation
};

/// Single damage event
pub const DamageEvent = struct {
    region: AABB,
    cause: DamageCause,
    world_id: WorldId,
    timestamp: i64,
};

/// Per-world damage state
pub const WorldDamage = struct {
    world_id: WorldId,
    dirty_tiles: std.AutoHashMapUnmanaged(TileCoord, DamageCause),
    damage_regions: std.ArrayListUnmanaged(AABB),
    generation: u64,
    full_redraw: bool,
    allocator: Allocator,

    pub fn init(allocator: Allocator, world_id: WorldId) WorldDamage {
        return .{
            .world_id = world_id,
            .dirty_tiles = .{},
            .damage_regions = .{},
            .generation = 0,
            .full_redraw = false,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *WorldDamage) void {
        self.dirty_tiles.deinit(self.allocator);
        self.damage_regions.deinit(self.allocator);
    }

    /// Mark single tile as damaged
    pub fn damageTile(self: *WorldDamage, coord: TileCoord, cause: DamageCause) !void {
        try self.dirty_tiles.put(self.allocator, coord, cause);
        self.generation +%= 1;
    }

    /// Mark region as damaged (without iterating all tiles)
    pub fn damageRegion(self: *WorldDamage, region: AABB, _: DamageCause) !void {
        try self.damage_regions.append(self.allocator, region);
        self.generation +%= 1;
    }

    /// Mark entire world for full redraw
    pub fn damageAll(self: *WorldDamage) void {
        self.full_redraw = true;
        self.generation +%= 1;
    }

    /// Coalesce dirty tiles into minimal bounding boxes
    pub fn coalesce(self: *WorldDamage) ![]AABB {
        // If full redraw, return existing regions (or empty)
        if (self.full_redraw or self.dirty_tiles.count() == 0) {
            return self.damage_regions.items;
        }

        // Group by z-layer
        var layers = std.AutoHashMapUnmanaged(i32, std.ArrayListUnmanaged(TileCoord)){};
        defer {
            var it = layers.valueIterator();
            while (it.next()) |list| list.deinit(self.allocator);
            layers.deinit(self.allocator);
        }

        var tile_it = self.dirty_tiles.keyIterator();
        while (tile_it.next()) |coord| {
            const entry = try layers.getOrPut(self.allocator, coord.z);
            if (!entry.found_existing) entry.value_ptr.* = .{};
            try entry.value_ptr.append(self.allocator, coord.*);
        }

        // For each layer, compute bounding box
        var layer_it = layers.iterator();
        while (layer_it.next()) |entry| {
            const tiles = entry.value_ptr.items;
            if (tiles.len == 0) continue;

            var bb = AABB.fromTile(tiles[0]);
            for (tiles[1..]) |t| {
                bb = bb.merge(AABB.fromTile(t));
            }
            try self.damage_regions.append(self.allocator, bb);
        }

        return self.damage_regions.items;
    }

    /// Clear all damage (after redraw)
    pub fn clear(self: *WorldDamage) void {
        self.dirty_tiles.clearRetainingCapacity();
        self.damage_regions.clearRetainingCapacity();
        self.full_redraw = false;
    }

    /// Check if any damage pending
    pub fn isDirty(self: *const WorldDamage) bool {
        return self.full_redraw or self.dirty_tiles.count() > 0 or self.damage_regions.items.len > 0;
    }

    pub fn toSyrup(self: *WorldDamage, allocator: Allocator) !syrup.Value {
        const regions = try self.coalesce();

        var region_values = std.ArrayListUnmanaged(syrup.Value){};
        defer region_values.deinit(allocator);

        for (regions) |r| {
            const entries = try allocator.alloc(syrup.Value.DictEntry, 5);
            entries[0] = .{ .key = .{ .symbol = "min-x" }, .value = .{ .integer = r.min_x } };
            entries[1] = .{ .key = .{ .symbol = "min-y" }, .value = .{ .integer = r.min_y } };
            entries[2] = .{ .key = .{ .symbol = "max-x" }, .value = .{ .integer = r.max_x } };
            entries[3] = .{ .key = .{ .symbol = "max-y" }, .value = .{ .integer = r.max_y } };
            entries[4] = .{ .key = .{ .symbol = "z" }, .value = .{ .integer = r.z } };
            try region_values.append(allocator, .{ .dictionary = entries });
        }

        const label = try allocator.create(syrup.Value);
        label.* = .{ .symbol = "world-damage" };

        const fields = try allocator.alloc(syrup.Value, 3);
        fields[0] = .{ .integer = @intCast(self.world_id) };
        fields[1] = .{ .integer = @intCast(self.generation) };
        fields[2] = .{ .list = try region_values.toOwnedSlice(allocator) };

        return .{ .record = .{ .label = label, .fields = fields } };
    }
};

/// Global damage tracker across all worlds
pub const DamageTracker = struct {
    worlds: std.AutoHashMapUnmanaged(WorldId, WorldDamage),
    event_log: std.ArrayListUnmanaged(DamageEvent),
    active_world: WorldId,
    allocator: Allocator,
    max_events: usize,

    pub fn init(allocator: Allocator) DamageTracker {
        return .{
            .worlds = .{},
            .event_log = .{},
            .active_world = 0,
            .allocator = allocator,
            .max_events = 1024,
        };
    }

    pub fn deinit(self: *DamageTracker) void {
        var it = self.worlds.valueIterator();
        while (it.next()) |w| w.deinit();
        self.worlds.deinit(self.allocator);
        self.event_log.deinit(self.allocator);
    }

    /// Get or create world damage state
    pub fn world(self: *DamageTracker, world_id: WorldId) !*WorldDamage {
        const entry = try self.worlds.getOrPut(self.allocator, world_id);
        if (!entry.found_existing) {
            entry.value_ptr.* = WorldDamage.init(self.allocator, world_id);
        }
        return entry.value_ptr;
    }

    /// Damage tile in active world
    pub fn damage(self: *DamageTracker, coord: TileCoord, cause: DamageCause) !void {
        const w = try self.world(self.active_world);
        try w.damageTile(coord, cause);
        try self.logEvent(.{
            .region = AABB.fromTile(coord),
            .cause = cause,
            .world_id = self.active_world,
            .timestamp = std.time.milliTimestamp(),
        });
    }

    /// Damage region in active world
    pub fn damageRect(self: *DamageTracker, region: AABB, cause: DamageCause) !void {
        const w = try self.world(self.active_world);
        try w.damageRegion(region, cause);
        try self.logEvent(.{
            .region = region,
            .cause = cause,
            .world_id = self.active_world,
            .timestamp = std.time.milliTimestamp(),
        });
    }

    /// Transition to different world (marks old world for full redraw on return)
    pub fn hopWorld(self: *DamageTracker, new_world: WorldId) !void {
        if (new_world != self.active_world) {
            // Mark old world for full redraw on return
            const old = try self.world(self.active_world);
            old.damageAll();

            self.active_world = new_world;

            try self.logEvent(.{
                .region = .{ .min_x = 0, .min_y = 0, .max_x = 0, .max_y = 0 },
                .cause = .world_transition,
                .world_id = new_world,
                .timestamp = std.time.milliTimestamp(),
            });
        }
    }

    /// Get coalesced damage for rendering
    pub fn getActiveDamage(self: *DamageTracker) ![]AABB {
        const w = try self.world(self.active_world);
        return w.coalesce();
    }

    /// Clear damage after render
    pub fn clearActive(self: *DamageTracker) !void {
        const w = try self.world(self.active_world);
        w.clear();
    }

    /// Check if active world needs redraw
    pub fn needsRedraw(self: *DamageTracker) bool {
        if (self.worlds.get(self.active_world)) |w| {
            return w.isDirty();
        }
        return false;
    }

    fn logEvent(self: *DamageTracker, event: DamageEvent) !void {
        if (self.event_log.items.len >= self.max_events) {
            _ = self.event_log.orderedRemove(0);
        }
        try self.event_log.append(self.allocator, event);
    }
};

/// Tiling layout for damage-aware rendering
pub const TilingLayout = enum {
    grid, // Regular NxM grid
    bsp, // Binary space partition
    spiral, // Golden ratio spiral
    masonry, // Variable height columns
};

/// Tile content state for change detection
pub const TileState = struct {
    content_hash: u64,
    color_seed: u32,
    generation: u64,

    pub fn changed(old: TileState, new: TileState) bool {
        return old.content_hash != new.content_hash or old.color_seed != new.color_seed;
    }
};

/// Tiled world with damage tracking
pub const TiledWorld = struct {
    id: WorldId,
    width: u32,
    height: u32,
    layers: u32,
    tiles: []TileState,
    damage: *WorldDamage,
    layout: TilingLayout,
    allocator: Allocator,

    pub fn init(allocator: Allocator, damage_tracker: *DamageTracker, id: WorldId, width: u32, height: u32, layers: u32) !TiledWorld {
        const total = width * height * layers;
        const tiles = try allocator.alloc(TileState, total);
        @memset(tiles, .{ .content_hash = 0, .color_seed = 0, .generation = 0 });

        return .{
            .id = id,
            .width = width,
            .height = height,
            .layers = layers,
            .tiles = tiles,
            .damage = try damage_tracker.world(id),
            .layout = .grid,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *TiledWorld) void {
        self.allocator.free(self.tiles);
    }

    fn tileIndex(self: *const TiledWorld, coord: TileCoord) ?usize {
        if (coord.x < 0 or coord.y < 0 or coord.z < 0) return null;
        const x: u32 = @intCast(coord.x);
        const y: u32 = @intCast(coord.y);
        const z: u32 = @intCast(coord.z);
        if (x >= self.width or y >= self.height or z >= self.layers) return null;
        return z * self.width * self.height + y * self.width + x;
    }

    /// Update tile and track damage if changed
    pub fn setTile(self: *TiledWorld, coord: TileCoord, new_state: TileState) !void {
        if (self.tileIndex(coord)) |idx| {
            const old = self.tiles[idx];
            if (TileState.changed(old, new_state)) {
                self.tiles[idx] = new_state;
                try self.damage.damageTile(coord, .state_mutation);
            }
        }
    }

    /// Get current tile state
    pub fn getTile(self: *const TiledWorld, coord: TileCoord) ?TileState {
        if (self.tileIndex(coord)) |idx| {
            return self.tiles[idx];
        }
        return null;
    }

    /// Cascade damage to neighbors (for effects that spread)
    pub fn cascadeDamage(self: *TiledWorld, center: TileCoord, radius: i32) !void {
        var dy: i32 = -radius;
        while (dy <= radius) : (dy += 1) {
            var dx: i32 = -radius;
            while (dx <= radius) : (dx += 1) {
                const coord = TileCoord{
                    .x = center.x + dx,
                    .y = center.y + dy,
                    .z = center.z,
                };
                if (self.tileIndex(coord) != null) {
                    try self.damage.damageTile(coord, .cascade);
                }
            }
        }
    }

    pub fn toSyrup(self: *TiledWorld, allocator: Allocator) !syrup.Value {
        const label = try allocator.create(syrup.Value);
        label.* = .{ .symbol = "tiled-world" };

        const damage_syrup = try self.damage.toSyrup(allocator);

        const fields = try allocator.alloc(syrup.Value, 5);
        fields[0] = .{ .integer = @intCast(self.id) };
        fields[1] = .{ .integer = @intCast(self.width) };
        fields[2] = .{ .integer = @intCast(self.height) };
        fields[3] = .{ .integer = @intCast(self.layers) };
        fields[4] = damage_syrup;

        return .{ .record = .{ .label = label, .fields = fields } };
    }
};

// ============================================================================
// TESTS
// ============================================================================

test "damage single tile" {
    const allocator = std.testing.allocator;
    var tracker = DamageTracker.init(allocator);
    defer tracker.deinit();

    try tracker.damage(.{ .x = 5, .y = 10, .z = 0 }, .state_mutation);

    try std.testing.expect(tracker.needsRedraw());

    const regions = try tracker.getActiveDamage();
    try std.testing.expectEqual(@as(usize, 1), regions.len);
    try std.testing.expectEqual(@as(i32, 5), regions[0].min_x);
    try std.testing.expectEqual(@as(i32, 10), regions[0].min_y);
}

test "damage region coalesces" {
    const allocator = std.testing.allocator;
    var tracker = DamageTracker.init(allocator);
    defer tracker.deinit();

    try tracker.damageRect(.{ .min_x = 0, .min_y = 0, .max_x = 3, .max_y = 3, .z = 0 }, .external_event);

    const regions = try tracker.getActiveDamage();
    try std.testing.expectEqual(@as(usize, 1), regions.len);
    try std.testing.expectEqual(@as(u64, 16), regions[0].area());
}

test "world hop damages old world" {
    const allocator = std.testing.allocator;
    var tracker = DamageTracker.init(allocator);
    defer tracker.deinit();

    tracker.active_world = 1;
    try tracker.hopWorld(2);

    try std.testing.expectEqual(@as(WorldId, 2), tracker.active_world);

    // Old world should be marked dirty
    const old_world = try tracker.world(1);
    try std.testing.expect(old_world.isDirty());
}

test "tiled world change detection" {
    const allocator = std.testing.allocator;
    var tracker = DamageTracker.init(allocator);
    defer tracker.deinit();

    var world = try TiledWorld.init(allocator, &tracker, 0, 10, 10, 1);
    defer world.deinit();

    // Initial set should damage
    try world.setTile(.{ .x = 5, .y = 5, .z = 0 }, .{ .content_hash = 123, .color_seed = 0, .generation = 1 });
    try std.testing.expect(world.damage.isDirty());

    world.damage.clear();

    // Same value should not damage
    try world.setTile(.{ .x = 5, .y = 5, .z = 0 }, .{ .content_hash = 123, .color_seed = 0, .generation = 1 });
    try std.testing.expect(!world.damage.isDirty());

    // Different value should damage
    try world.setTile(.{ .x = 5, .y = 5, .z = 0 }, .{ .content_hash = 456, .color_seed = 0, .generation = 2 });
    try std.testing.expect(world.damage.isDirty());
}

test "aabb operations" {
    const a = AABB{ .min_x = 0, .min_y = 0, .max_x = 5, .max_y = 5, .z = 0 };
    const b = AABB{ .min_x = 3, .min_y = 3, .max_x = 8, .max_y = 8, .z = 0 };

    try std.testing.expect(a.intersects(b));
    try std.testing.expect(a.contains(.{ .x = 2, .y = 2, .z = 0 }));
    try std.testing.expect(!a.contains(.{ .x = 6, .y = 6, .z = 0 }));

    const merged = a.merge(b);
    try std.testing.expectEqual(@as(i32, 0), merged.min_x);
    try std.testing.expectEqual(@as(i32, 8), merged.max_x);
}

// ============================================================================
// TERMINAL CELL DAMAGE (PTY/TTY frame-level)
// ============================================================================

/// Terminal cell attributes (VT100/xterm compatible)
pub const CellAttrs = packed struct {
    bold: bool = false,
    italic: bool = false,
    underline: bool = false,
    blink: bool = false,
    reverse: bool = false,
    strikethrough: bool = false,
    dim: bool = false,
    hidden: bool = false,
};

/// A single terminal cell
pub const Cell = struct {
    codepoint: u21 = ' ', // Unicode codepoint
    fg: u24 = 0xFFFFFF, // 24-bit foreground
    bg: u24 = 0x000000, // 24-bit background
    attrs: CellAttrs = .{},

    pub fn eql(a: Cell, b: Cell) bool {
        return a.codepoint == b.codepoint and
            a.fg == b.fg and a.bg == b.bg and
            @as(u8, @bitCast(a.attrs)) == @as(u8, @bitCast(b.attrs));
    }

    pub fn hash(self: Cell) u64 {
        var h: u64 = @as(u64, self.codepoint);
        h = h *% 0x517cc1b727220a95 +% @as(u64, self.fg);
        h = h *% 0x77f4a7c5e8d2bc5d +% @as(u64, self.bg);
        h = h *% 0x2545f4914f6cdd1d +% @as(u64, @as(u8, @bitCast(self.attrs)));
        return h;
    }
};

/// Pane identifier for multiplexed terminals
pub const PaneId = u32;

/// Terminal pane with double-buffered damage tracking
pub const TerminalPane = struct {
    id: PaneId,
    cols: u16,
    rows: u16,
    front: []Cell, // Currently displayed
    back: []Cell, // Being rendered to
    damage_mask: []bool, // Per-cell dirty bit
    cursor_x: u16,
    cursor_y: u16,
    cursor_visible: bool,
    scroll_region_top: u16,
    scroll_region_bottom: u16,
    allocator: Allocator,

    pub fn init(allocator: Allocator, id: PaneId, cols: u16, rows: u16) !TerminalPane {
        const size = @as(usize, cols) * rows;
        const front = try allocator.alloc(Cell, size);
        const back = try allocator.alloc(Cell, size);
        const mask = try allocator.alloc(bool, size);

        @memset(front, Cell{});
        @memset(back, Cell{});
        @memset(mask, true); // Initially all dirty

        return .{
            .id = id,
            .cols = cols,
            .rows = rows,
            .front = front,
            .back = back,
            .damage_mask = mask,
            .cursor_x = 0,
            .cursor_y = 0,
            .cursor_visible = true,
            .scroll_region_top = 0,
            .scroll_region_bottom = rows - 1,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *TerminalPane) void {
        self.allocator.free(self.front);
        self.allocator.free(self.back);
        self.allocator.free(self.damage_mask);
    }

    fn cellIndex(self: *const TerminalPane, x: u16, y: u16) ?usize {
        if (x >= self.cols or y >= self.rows) return null;
        return @as(usize, y) * self.cols + x;
    }

    /// Write cell to back buffer, mark damaged if different from front
    pub fn setCell(self: *TerminalPane, x: u16, y: u16, cell: Cell) void {
        if (self.cellIndex(x, y)) |idx| {
            self.back[idx] = cell;
            if (!Cell.eql(self.front[idx], cell)) {
                self.damage_mask[idx] = true;
            }
        }
    }

    /// Get cell from front buffer (what's displayed)
    pub fn getCell(self: *const TerminalPane, x: u16, y: u16) ?Cell {
        if (self.cellIndex(x, y)) |idx| {
            return self.front[idx];
        }
        return null;
    }

    /// Swap buffers after render, return damaged regions
    pub fn commit(self: *TerminalPane, allocator: Allocator) ![]AABB {
        var regions = std.ArrayListUnmanaged(AABB){};

        // Find damaged runs and convert to AABBs
        var y: u16 = 0;
        while (y < self.rows) : (y += 1) {
            var x: u16 = 0;
            while (x < self.cols) {
                const idx = self.cellIndex(x, y).?;
                if (self.damage_mask[idx]) {
                    // Start of damaged run
                    const start_x = x;
                    while (x < self.cols) {
                        const run_idx = self.cellIndex(x, y).?;
                        if (!self.damage_mask[run_idx]) break;
                        // Copy back to front
                        self.front[run_idx] = self.back[run_idx];
                        self.damage_mask[run_idx] = false;
                        x += 1;
                    }
                    try regions.append(allocator, .{
                        .min_x = start_x,
                        .min_y = y,
                        .max_x = x - 1,
                        .max_y = y,
                        .z = 0,
                    });
                } else {
                    x += 1;
                }
            }
        }

        return regions.toOwnedSlice(allocator);
    }

    /// Damage entire pane (resize, etc)
    pub fn damageAll(self: *TerminalPane) void {
        @memset(self.damage_mask, true);
    }

    /// Scroll region up, damaging affected rows
    pub fn scrollUp(self: *TerminalPane, lines: u16) void {
        const top = self.scroll_region_top;
        const bot = self.scroll_region_bottom;

        var y = top;
        while (y <= bot - lines) : (y += 1) {
            const dst_row = @as(usize, y) * self.cols;
            const src_row = @as(usize, y + lines) * self.cols;
            @memcpy(self.back[dst_row..][0..self.cols], self.back[src_row..][0..self.cols]);
            @memset(self.damage_mask[dst_row..][0..self.cols], true);
        }

        // Clear scrolled-in lines
        while (y <= bot) : (y += 1) {
            const row = @as(usize, y) * self.cols;
            @memset(self.back[row..][0..self.cols], Cell{});
            @memset(self.damage_mask[row..][0..self.cols], true);
        }
    }

    /// Count dirty cells
    pub fn dirtyCount(self: *const TerminalPane) usize {
        var count: usize = 0;
        for (self.damage_mask) |d| {
            if (d) count += 1;
        }
        return count;
    }
};

/// Tree-sitter compatible edit for incremental parsing
pub const TSEdit = struct {
    start_byte: u32,
    old_end_byte: u32,
    new_end_byte: u32,
    start_row: u16,
    start_col: u16,
    old_end_row: u16,
    old_end_col: u16,
    new_end_row: u16,
    new_end_col: u16,

    /// Convert AABB damage to TSEdit (for syntax re-highlight)
    pub fn fromDamage(damage: AABB, cols: u16) TSEdit {
        return .{
            .start_byte = @as(u32, @intCast(damage.min_y)) * cols + @as(u32, @intCast(damage.min_x)),
            .old_end_byte = @as(u32, @intCast(damage.max_y)) * cols + @as(u32, @intCast(damage.max_x)) + 1,
            .new_end_byte = @as(u32, @intCast(damage.max_y)) * cols + @as(u32, @intCast(damage.max_x)) + 1,
            .start_row = @intCast(damage.min_y),
            .start_col = @intCast(damage.min_x),
            .old_end_row = @intCast(damage.max_y),
            .old_end_col = @intCast(damage.max_x),
            .new_end_row = @intCast(damage.max_y),
            .new_end_col = @intCast(damage.max_x),
        };
    }
};

/// Multiplexed terminal frame (like tmux/boxxy)
pub const TerminalFrame = struct {
    panes: std.AutoHashMapUnmanaged(PaneId, TerminalPane),
    layout: FrameLayout,
    active_pane: PaneId,
    frame_gen: u64,
    allocator: Allocator,

    pub const FrameLayout = enum {
        single,
        horizontal_split,
        vertical_split,
        grid,
        floating,
    };

    pub fn init(allocator: Allocator) TerminalFrame {
        return .{
            .panes = .{},
            .layout = .single,
            .active_pane = 0,
            .frame_gen = 0,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *TerminalFrame) void {
        var it = self.panes.valueIterator();
        while (it.next()) |pane| pane.deinit();
        self.panes.deinit(self.allocator);
    }

    pub fn createPane(self: *TerminalFrame, cols: u16, rows: u16) !PaneId {
        const id: PaneId = @intCast(self.panes.count());
        const pane = try TerminalPane.init(self.allocator, id, cols, rows);
        try self.panes.put(self.allocator, id, pane);
        return id;
    }

    pub fn getPane(self: *TerminalFrame, id: PaneId) ?*TerminalPane {
        return self.panes.getPtr(id);
    }

    /// Commit all panes, return total edit regions for tree-sitter
    pub fn commitFrame(self: *TerminalFrame, allocator: Allocator) ![]TSEdit {
        var edits = std.ArrayListUnmanaged(TSEdit){};
        self.frame_gen +%= 1;

        var it = self.panes.valueIterator();
        while (it.next()) |pane| {
            const regions = try pane.commit(allocator);
            defer allocator.free(regions);

            for (regions) |r| {
                try edits.append(allocator, TSEdit.fromDamage(r, pane.cols));
            }
        }

        return edits.toOwnedSlice(allocator);
    }

    pub fn toSyrup(self: *TerminalFrame, allocator: Allocator) !syrup.Value {
        var pane_list = std.ArrayListUnmanaged(syrup.Value){};

        var it = self.panes.iterator();
        while (it.next()) |entry| {
            const pane = entry.value_ptr;
            const pane_entries = try allocator.alloc(syrup.Value.DictEntry, 5);
            pane_entries[0] = .{ .key = .{ .symbol = "id" }, .value = .{ .integer = pane.id } };
            pane_entries[1] = .{ .key = .{ .symbol = "cols" }, .value = .{ .integer = pane.cols } };
            pane_entries[2] = .{ .key = .{ .symbol = "rows" }, .value = .{ .integer = pane.rows } };
            pane_entries[3] = .{ .key = .{ .symbol = "cursor-x" }, .value = .{ .integer = pane.cursor_x } };
            pane_entries[4] = .{ .key = .{ .symbol = "cursor-y" }, .value = .{ .integer = pane.cursor_y } };
            try pane_list.append(allocator, .{ .dictionary = pane_entries });
        }

        const label = try allocator.create(syrup.Value);
        label.* = .{ .symbol = "terminal-frame" };

        const fields = try allocator.alloc(syrup.Value, 3);
        fields[0] = .{ .integer = @intCast(self.frame_gen) };
        fields[1] = .{ .symbol = @tagName(self.layout) };
        fields[2] = .{ .list = try pane_list.toOwnedSlice(allocator) };

        return .{ .record = .{ .label = label, .fields = fields } };
    }
};

test "terminal pane damage" {
    const allocator = std.testing.allocator;
    var pane = try TerminalPane.init(allocator, 0, 80, 24);
    defer pane.deinit();

    // Initially all dirty
    try std.testing.expectEqual(@as(usize, 80 * 24), pane.dirtyCount());

    // Write and commit
    pane.setCell(10, 5, .{ .codepoint = 'A', .fg = 0xFF0000, .bg = 0x000000, .attrs = .{} });
    const regions = try pane.commit(allocator);
    defer allocator.free(regions);

    // After commit, should be clean
    try std.testing.expectEqual(@as(usize, 0), pane.dirtyCount());

    // Same write should not damage
    pane.setCell(10, 5, .{ .codepoint = 'A', .fg = 0xFF0000, .bg = 0x000000, .attrs = .{} });
    try std.testing.expectEqual(@as(usize, 0), pane.dirtyCount());

    // Different write should damage
    pane.setCell(10, 5, .{ .codepoint = 'B', .fg = 0xFF0000, .bg = 0x000000, .attrs = .{} });
    try std.testing.expectEqual(@as(usize, 1), pane.dirtyCount());
}

test "terminal frame multiplex" {
    const allocator = std.testing.allocator;
    var frame = TerminalFrame.init(allocator);
    defer frame.deinit();

    const pane1 = try frame.createPane(80, 24);
    const pane2 = try frame.createPane(80, 24);

    try std.testing.expectEqual(@as(PaneId, 0), pane1);
    try std.testing.expectEqual(@as(PaneId, 1), pane2);

    // Write to both panes
    if (frame.getPane(pane1)) |p| p.setCell(0, 0, .{ .codepoint = '1' });
    if (frame.getPane(pane2)) |p| p.setCell(0, 0, .{ .codepoint = '2' });

    // Commit and get tree-sitter edits
    const edits = try frame.commitFrame(allocator);
    defer allocator.free(edits);

    try std.testing.expect(edits.len > 0);
}

test "cell comparison" {
    const a = Cell{ .codepoint = 'X', .fg = 0xFFFFFF, .bg = 0x000000, .attrs = .{ .bold = true } };
    const b = Cell{ .codepoint = 'X', .fg = 0xFFFFFF, .bg = 0x000000, .attrs = .{ .bold = true } };
    const c = Cell{ .codepoint = 'X', .fg = 0xFFFFFF, .bg = 0x000000, .attrs = .{ .bold = false } };

    try std.testing.expect(Cell.eql(a, b));
    try std.testing.expect(!Cell.eql(a, c));
}

test "multi-layer damage coalescing" {
    const allocator = std.testing.allocator;
    var tracker = DamageTracker.init(allocator);
    defer tracker.deinit();

    // Damage tiles at different z layers in the active world
    try tracker.damage(.{ .x = 1, .y = 1, .z = 0 }, .state_mutation);
    try tracker.damage(.{ .x = 2, .y = 2, .z = 0 }, .state_mutation);
    try tracker.damage(.{ .x = 5, .y = 5, .z = 1 }, .state_mutation);

    const w = try tracker.world(0);
    const regions = try w.coalesce();

    // Should have at least 2 regions (one per z-layer)
    try std.testing.expect(regions.len >= 2);
}

test "cascade damage 3x3 grid" {
    const allocator = std.testing.allocator;
    var tracker = DamageTracker.init(allocator);
    defer tracker.deinit();

    var world_tiles = try TiledWorld.init(allocator, &tracker, 0, 10, 10, 1);
    defer world_tiles.deinit();

    // Cascade with radius 1 around center (5,5)
    try world_tiles.cascadeDamage(.{ .x = 5, .y = 5, .z = 0 }, 1);

    // Should damage 3x3 = 9 tiles
    try std.testing.expectEqual(@as(usize, 9), world_tiles.damage.dirty_tiles.count());
}

test "tiled world syrup roundtrip structure" {
    const allocator = std.testing.allocator;
    var tracker = DamageTracker.init(allocator);
    defer tracker.deinit();

    var world_tiles = try TiledWorld.init(allocator, &tracker, 42, 8, 8, 1);
    defer world_tiles.deinit();

    try world_tiles.setTile(.{ .x = 0, .y = 0, .z = 0 }, .{ .content_hash = 999, .color_seed = 1, .generation = 1 });

    const val = try world_tiles.toSyrup(allocator);
    // Should be a record
    try std.testing.expectEqual(syrup.Value.record, std.meta.activeTag(val));
    const label = val.record.label.*;
    try std.testing.expectEqualStrings("tiled-world", label.symbol);
}

test "terminal pane scroll damages rows" {
    const allocator = std.testing.allocator;
    var pane = try TerminalPane.init(allocator, 0, 20, 10);
    defer pane.deinit();

    // Commit to clear initial damage
    const initial = try pane.commit(allocator);
    allocator.free(initial);
    try std.testing.expectEqual(@as(usize, 0), pane.dirtyCount());

    // Scroll up 2 lines
    pane.scrollUp(2);

    // All rows in scroll region should be damaged
    try std.testing.expect(pane.dirtyCount() > 0);
    // The full pane cols * rows cells should be dirty
    try std.testing.expectEqual(@as(usize, 20 * 10), pane.dirtyCount());
}

test "terminal pane multiple writes single commit" {
    const allocator = std.testing.allocator;
    var pane = try TerminalPane.init(allocator, 0, 40, 10);
    defer pane.deinit();

    // Commit initial state to clear all-dirty mask
    const initial = try pane.commit(allocator);
    allocator.free(initial);

    // Write multiple cells
    pane.setCell(0, 0, .{ .codepoint = 'A', .fg = 0xFF0000 });
    pane.setCell(1, 0, .{ .codepoint = 'B', .fg = 0x00FF00 });
    pane.setCell(2, 0, .{ .codepoint = 'C', .fg = 0x0000FF });
    // Non-adjacent
    pane.setCell(10, 5, .{ .codepoint = 'X', .fg = 0xFFFFFF });

    try std.testing.expectEqual(@as(usize, 4), pane.dirtyCount());

    const regions = try pane.commit(allocator);
    defer allocator.free(regions);

    // Should produce 2 damage regions (run at row 0 cols 0-2, and row 5 col 10)
    try std.testing.expectEqual(@as(usize, 2), regions.len);
    try std.testing.expectEqual(@as(usize, 0), pane.dirtyCount());
}

test "damage tracker circular event buffer" {
    const allocator = std.testing.allocator;
    var tracker = DamageTracker.init(allocator);
    defer tracker.deinit();
    tracker.max_events = 10; // Small buffer for testing

    // Log more events than buffer size
    for (0..25) |j| {
        try tracker.damage(.{ .x = @intCast(j), .y = 0, .z = 0 }, .state_mutation);
    }

    // Should be capped at max_events
    try std.testing.expectEqual(@as(usize, 10), tracker.event_log.items.len);
}

test "AABB merge non-overlapping" {
    const a = AABB{ .min_x = 0, .min_y = 0, .max_x = 2, .max_y = 2, .z = 0 };
    const b = AABB{ .min_x = 10, .min_y = 10, .max_x = 12, .max_y = 12, .z = 0 };

    try std.testing.expect(!a.intersects(b));

    const merged = a.merge(b);
    try std.testing.expectEqual(@as(i32, 0), merged.min_x);
    try std.testing.expectEqual(@as(i32, 0), merged.min_y);
    try std.testing.expectEqual(@as(i32, 12), merged.max_x);
    try std.testing.expectEqual(@as(i32, 12), merged.max_y);
    // Merged area is larger than sum of parts (includes empty space)
    try std.testing.expect(merged.area() > a.area() + b.area());
}

test "full redraw flag" {
    const allocator = std.testing.allocator;
    var wd = WorldDamage.init(allocator, 0);
    defer wd.deinit();

    try std.testing.expect(!wd.isDirty());

    wd.damageAll();
    try std.testing.expect(wd.isDirty());
    try std.testing.expect(wd.full_redraw);

    wd.clear();
    try std.testing.expect(!wd.isDirty());
    try std.testing.expect(!wd.full_redraw);
}
