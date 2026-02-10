//! Spatial Propagator Network
//! Bridges SplitTree topology (from Ghostty Swift) into the propagator/cell_dispatch pipeline.
//! Assigns golden-spiral colors to spatial nodes, propagates focus state, and exports via C ABI.

const std = @import("std");
const syrup = @import("syrup.zig");
const rainbow = @import("rainbow.zig");
const propagator = @import("propagator.zig");
const cell_dispatch = @import("cell_dispatch.zig");
const Allocator = std.mem.Allocator;

// =============================================================================
// HSL → RGB (matches Python valence_bridge.py for BCI color projection)
// =============================================================================

fn hueToRgb(p: f64, q: f64, t_in: f64) f64 {
    var t = t_in;
    if (t < 0) t += 1;
    if (t > 1) t -= 1;
    if (t < 1.0 / 6.0) return p + (q - p) * 6.0 * t;
    if (t < 1.0 / 2.0) return q;
    if (t < 2.0 / 3.0) return p + (q - p) * (2.0 / 3.0 - t) * 6.0;
    return p;
}

fn hslToRgb(h: f64, s: f64, l: f64) rainbow.RGB {
    if (s == 0) {
        const v: u8 = @intFromFloat(@max(0, @min(255, l * 255.0)));
        return .{ .r = v, .g = v, .b = v };
    }
    const q = if (l < 0.5) l * (1.0 + s) else l + s - l * s;
    const p = 2.0 * l - q;
    const h_norm = @mod(h, 360.0) / 360.0;
    return .{
        .r = @intFromFloat(@max(0, @min(255, hueToRgb(p, q, h_norm + 1.0 / 3.0) * 255.0))),
        .g = @intFromFloat(@max(0, @min(255, hueToRgb(p, q, h_norm) * 255.0))),
        .b = @intFromFloat(@max(0, @min(255, hueToRgb(p, q, h_norm - 1.0 / 3.0) * 255.0))),
    };
}

// =============================================================================
// Types
// =============================================================================

pub const Rect = struct {
    x: i32 = 0,
    y: i32 = 0,
    width: u32 = 0,
    height: u32 = 0,

    pub fn contains(self: Rect, px: i32, py: i32) bool {
        return px >= self.x and px < self.x + @as(i32, @intCast(self.width)) and
            py >= self.y and py < self.y + @as(i32, @intCast(self.height));
    }

    pub fn sharesEdge(self: Rect, other: Rect) bool {
        const self_right = self.x + @as(i32, @intCast(self.width));
        const self_bottom = self.y + @as(i32, @intCast(self.height));
        const other_right = other.x + @as(i32, @intCast(other.width));
        const other_bottom = other.y + @as(i32, @intCast(other.height));

        // Horizontal adjacency (left-right edge touching, vertical overlap)
        const h_adjacent = (self_right == other.x or other_right == self.x);
        const v_overlap = (self.y < other_bottom and self_bottom > other.y);
        if (h_adjacent and v_overlap) return true;

        // Vertical adjacency (top-bottom edge touching, horizontal overlap)
        const v_adjacent = (self_bottom == other.y or other_bottom == self.y);
        const h_overlap = (self.x < other_right and self_right > other.x);
        if (v_adjacent and h_overlap) return true;

        return false;
    }
};

pub const FocusState = enum(u8) {
    unfocused = 0,
    focused = 1,
    recently_focused = 2,
};

pub const SplitDirection = enum(u8) {
    horizontal = 0,
    vertical = 1,
};

pub const SpatialInfo = struct {
    bounds: Rect = .{},
    window_id: u32 = 0,
    space_id: u32 = 0,
    depth: u32 = 0,
    spatial_index: u32 = 0,
    focus_state: FocusState = .unfocused,
};

// =============================================================================
// SpatialNode: propagator cells for one split tree node
// =============================================================================

pub const SpatialNode = struct {
    info: SpatialInfo,
    /// Foreground color (packed ARGB8)
    fg_color: u32 = 0xFFFFFFFF,
    /// Background color (packed ARGB8)
    bg_color: u32 = 0xFF000000,
    /// Focus level (0.0 = unfocused, 1.0 = focused)
    focus_level: f32 = 0.0,
    /// Adjacency list (indices into SpatialNetwork.nodes)
    adjacent: std.ArrayListUnmanaged(u32),
    allocator: Allocator,

    pub fn init(allocator: Allocator, info: SpatialInfo) SpatialNode {
        return .{
            .info = info,
            .allocator = allocator,
            .adjacent = std.ArrayListUnmanaged(u32){},
        };
    }

    pub fn deinit(self: *SpatialNode) void {
        self.adjacent.deinit(self.allocator);
    }

    pub fn addAdjacent(self: *SpatialNode, other_idx: u32) !void {
        // Avoid duplicates
        for (self.adjacent.items) |idx| {
            if (idx == other_idx) return;
        }
        try self.adjacent.append(self.allocator, other_idx);
    }
};

// =============================================================================
// SpatialNetwork: the full propagator network for spatial topology
// =============================================================================

pub const SpatialNetwork = struct {
    nodes: std.ArrayListUnmanaged(SpatialNode),
    allocator: Allocator,
    lock: std.Thread.RwLock = .{},

    pub fn init(allocator: Allocator) SpatialNetwork {
        return .{
            .nodes = std.ArrayListUnmanaged(SpatialNode){},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *SpatialNetwork) void {
        for (self.nodes.items) |*node| {
            node.deinit();
        }
        self.nodes.deinit(self.allocator);
    }

    /// Add a node to the network. Returns the index.
    pub fn addNode(self: *SpatialNetwork, info: SpatialInfo) !u32 {
        const idx: u32 = @intCast(self.nodes.items.len);
        try self.nodes.append(self.allocator, SpatialNode.init(self.allocator, info));
        return idx;
    }

    /// Connect two nodes as adjacent (bidirectional).
    pub fn connect(self: *SpatialNetwork, a: u32, b: u32) !void {
        if (a >= self.nodes.items.len or b >= self.nodes.items.len) return;
        try self.nodes.items[a].addAdjacent(b);
        try self.nodes.items[b].addAdjacent(a);
    }

    /// Auto-detect adjacency from node bounds (nodes sharing an edge are adjacent).
    pub fn detectAdjacency(self: *SpatialNetwork) !void {
        const n = self.nodes.items.len;
        for (0..n) |i| {
            for (i + 1..n) |j| {
                if (self.nodes.items[i].info.bounds.sharesEdge(self.nodes.items[j].info.bounds)) {
                    try self.connect(@intCast(i), @intCast(j));
                }
            }
        }
    }

    /// Assign colors from BCI brainwave entropy.
    /// Mirrors Python valence_bridge.py project_to_color (HSL-based):
    ///   Hue = (Φ × golden_angle) % 360, per-node offset by spatial_index
    ///   Saturation = 0.3 + 0.6 × sigmoid(valence + 3)
    ///   Lightness = 0.3 + 0.4 × sigmoid(fisher - 1)
    ///   Trit: ±20° hue rotation
    pub fn assignColorsFromBCI(self: *SpatialNetwork, phi: f32, valence: f32, fisher: f32, trit: i32) !void {
        self.lock.lock();
        defer self.lock.unlock();

        const n = self.nodes.items.len;
        if (n == 0) return;

        // Sigmoid helper
        const valence_norm: f64 = 1.0 / (1.0 + @exp(-@as(f64, valence) - 3.0));
        const fisher_norm: f64 = 1.0 / (1.0 + @exp(-@as(f64, fisher) + 1.0));

        const saturation: f64 = 0.3 + 0.6 * valence_norm;
        const lightness: f64 = 0.3 + 0.4 * fisher_norm;

        // Base hue from Φ via golden angle
        const base_hue: f64 = @mod(@as(f64, phi) * rainbow.GOLDEN_ANGLE, 360.0);

        // Trit adjustment
        const trit_offset: f64 = switch (trit) {
            1 => 20.0, // PLUS: warmer
            -1 => -20.0, // MINUS: cooler
            else => 0.0,
        };

        for (self.nodes.items) |*node| {
            // Per-node hue offset by spatial_index (golden angle dispersion)
            const node_hue = @mod(base_hue + @as(f64, @floatFromInt(node.info.spatial_index)) * rainbow.GOLDEN_ANGLE + trit_offset, 360.0);
            // HSL → RGB (matches Python valence_bridge.py algorithm)
            const rgb = hslToRgb(node_hue, saturation, lightness);

            node.fg_color = 0xFF000000 |
                (@as(u32, rgb.r) << 16) |
                (@as(u32, rgb.g) << 8) |
                @as(u32, rgb.b);
            // Background: dark variant
            node.bg_color = 0xFF000000 |
                (@as(u32, rgb.r / 4) << 16) |
                (@as(u32, rgb.g / 4) << 8) |
                @as(u32, rgb.b / 4);
        }
    }

    /// Assign colors via golden spiral to all nodes by spatial_index.
    pub fn assignColors(self: *SpatialNetwork) !void {
        const n = self.nodes.items.len;
        if (n == 0) return;

        const palette = try rainbow.goldenSpiral(n, 271.0, 0.7, 0.55, self.allocator);
        defer self.allocator.free(palette);

        for (self.nodes.items, 0..) |*node, i| {
            const idx = node.info.spatial_index % n;
            const rgb = palette[idx];
            // Pack as ARGB8 (0xFF alpha)
            node.fg_color = 0xFF000000 |
                (@as(u32, rgb.r) << 16) |
                (@as(u32, rgb.g) << 8) |
                @as(u32, rgb.b);
            // Background: darker version
            node.bg_color = 0xFF000000 |
                (@as(u32, rgb.r / 4) << 16) |
                (@as(u32, rgb.g / 4) << 8) |
                @as(u32, rgb.b / 4);
            _ = i;
        }
    }

    /// Propagate focus: set one node focused, others unfocused, apply adjacency blending.
    pub fn setFocus(self: *SpatialNetwork, node_id: u32) void {
        self.lock.lock();
        defer self.lock.unlock();

        // Set raw focus levels
        for (self.nodes.items) |*node| {
            node.focus_level = if (node.info.window_id == node_id) 1.0 else 0.0;
            node.info.focus_state = if (node.info.window_id == node_id) .focused else .unfocused;
        }

        // Adjacency blending pass (halo effect around focused node)
        for (self.nodes.items) |*node| {
            if (node.focus_level == 1.0) continue; // Skip the focused node itself
            var neighbor_focus: f32 = 0;
            var count: u32 = 0;
            for (node.adjacent.items) |adj_idx| {
                if (adj_idx < self.nodes.items.len) {
                    neighbor_focus += self.nodes.items[adj_idx].focus_level;
                    count += 1;
                }
            }
            if (count > 0) {
                const avg = neighbor_focus / @as(f32, @floatFromInt(count));
                // Halo: 20% of neighbor focus
                node.focus_level = avg * 0.2;
            }
        }
    }

    /// Get spatial colors packed into output buffer.
    /// Format per node: [u32 node_id, u32 fg, u32 bg] = 12 bytes each.
    /// Returns bytes written.
    pub fn getSpatialColors(self: *SpatialNetwork, output_buf: []u8) usize {
        self.lock.lockShared();
        defer self.lock.unlockShared();

        var bytes_written: usize = 0;
        for (self.nodes.items) |node| {
            if (bytes_written + 12 > output_buf.len) break;

            // Apply focus brightness to fg color
            const brightness = 0.6 + node.focus_level * 0.4;
            const r: u8 = @intFromFloat(@min(255.0, @as(f32, @floatFromInt((node.fg_color >> 16) & 0xFF)) * brightness));
            const g: u8 = @intFromFloat(@min(255.0, @as(f32, @floatFromInt((node.fg_color >> 8) & 0xFF)) * brightness));
            const b: u8 = @intFromFloat(@min(255.0, @as(f32, @floatFromInt(node.fg_color & 0xFF)) * brightness));
            const fg_adjusted = 0xFF000000 | (@as(u32, r) << 16) | (@as(u32, g) << 8) | @as(u32, b);

            std.mem.writeInt(u32, output_buf[bytes_written..][0..4], node.info.window_id, .little);
            std.mem.writeInt(u32, output_buf[bytes_written + 4 ..][0..4], fg_adjusted, .little);
            std.mem.writeInt(u32, output_buf[bytes_written + 8 ..][0..4], node.bg_color, .little);
            bytes_written += 12;
        }
        return bytes_written;
    }

    /// Ingest topology from a Syrup-encoded record.
    /// Expected format:
    ///   <split-tree [<node window_id space_id depth x y w h>...] [[src dst]...]>
    /// Where:
    ///   - First field is a list of node records
    ///   - Second field is a list of edge pairs [src_index, dst_index]
    pub fn ingestTopology(self: *SpatialNetwork, syrup_bytes: []const u8) !void {
        const val = try syrup.decode(syrup_bytes, self.allocator);
        // val should be a record with label "split-tree"
        if (val != .record) return error.InvalidFormat;

        const rec = val.record;
        if (rec.fields.len < 2) return error.InvalidFormat;

        // First field: list of nodes
        const nodes_val = rec.fields[0];
        if (nodes_val != .list) return error.InvalidFormat;

        // Clear existing nodes
        for (self.nodes.items) |*node| {
            node.deinit();
        }
        self.nodes.clearRetainingCapacity();

        // Parse each node
        for (nodes_val.list, 0..) |node_val, i| {
            if (node_val != .list) continue;
            const fields = node_val.list;
            if (fields.len < 7) continue;

            const info = SpatialInfo{
                .window_id = @intCast(@as(u64, @bitCast(fields[0].integer))),
                .space_id = @intCast(@as(u64, @bitCast(fields[1].integer))),
                .depth = @intCast(@as(u64, @bitCast(fields[2].integer))),
                .bounds = .{
                    .x = @intCast(fields[3].integer),
                    .y = @intCast(fields[4].integer),
                    .width = @intCast(@as(u64, @bitCast(fields[5].integer))),
                    .height = @intCast(@as(u64, @bitCast(fields[6].integer))),
                },
                .spatial_index = @intCast(i),
            };
            _ = try self.addNode(info);
        }

        // Second field: list of edges
        const edges_val = rec.fields[1];
        if (edges_val == .list) {
            for (edges_val.list) |edge_val| {
                if (edge_val != .list) continue;
                const pair = edge_val.list;
                if (pair.len < 2) continue;
                const src: u32 = @intCast(@as(u64, @bitCast(pair[0].integer)));
                const dst: u32 = @intCast(@as(u64, @bitCast(pair[1].integer)));
                try self.connect(src, dst);
            }
        }

        try self.assignColors();
    }

    pub const Error = error{
        InvalidFormat,
    } || syrup.Parser.ParseError || Allocator.Error;

    /// Assign luminosity to each node based on its GF(3) qutrit classification.
    /// The trit of each node's fg_color controls its brightness:
    ///   minus (-1): dim 0.30,  zero (0): neutral 0.55,  plus (+1): bright 0.80
    /// With optional entanglement gate_order shifting the levels via CNOT₃.
    pub fn assignLuminosityFromTrit(self: *SpatialNetwork, gate_order: u2) void {
        self.lock.lock();
        defer self.lock.unlock();

        const entangle = @import("entangle.zig");
        const order: entangle.GateOrder = @enumFromInt(gate_order);

        for (self.nodes.items) |*node| {
            const trit = entangle.classifyColor(node.fg_color);
            const lum = entangle.entangledLuminosity(trit, order);
            node.fg_color = entangle.applyLuminosity(node.fg_color, lum);
            // Background: apply at 25% intensity (keep it dark)
            node.bg_color = entangle.applyLuminosity(node.bg_color, lum * 0.25);
        }
    }
};

// =============================================================================
// Pipeline Transform
// =============================================================================

/// Pipeline CellTransform that applies spatial colors from a SpatialNetwork.
/// The SpatialNetwork pointer must be passed via ctx.user_data.
pub fn spatialColorTransform(cell: cell_dispatch.Cell, ctx: cell_dispatch.TransducerContext) cell_dispatch.Cell {
    const network_ptr = ctx.user_data orelse return cell;
    const network: *SpatialNetwork = @ptrCast(@alignCast(network_ptr));

    network.lock.lockShared();
    defer network.lock.unlockShared();

    // Find the first node whose bounds contain this cell's position
    // We use the cell's codepoint as a spatial index hint (for cells tagged with node_id)
    // or fall back to the first node for global application
    const node_id = cell.codepoint;
    for (network.nodes.items) |node| {
        if (node.info.window_id == node_id) {
            var result = cell;
            // Apply focus-adjusted fg
            const brightness = 0.6 + node.focus_level * 0.4;
            const r: u8 = @intFromFloat(@min(255.0, @as(f32, @floatFromInt((node.fg_color >> 16) & 0xFF)) * brightness));
            const g: u8 = @intFromFloat(@min(255.0, @as(f32, @floatFromInt((node.fg_color >> 8) & 0xFF)) * brightness));
            const b: u8 = @intFromFloat(@min(255.0, @as(f32, @floatFromInt(node.fg_color & 0xFF)) * brightness));
            result.fg = 0xFF000000 | (@as(u32, r) << 16) | (@as(u32, g) << 8) | @as(u32, b);
            result.bg = node.bg_color;
            return result;
        }
    }
    return cell;
}

// =============================================================================
// C ABI Exports (for Swift bridge)
// =============================================================================

const PropagatorHandle = struct {
    network: SpatialNetwork,
    allocator: Allocator,
};

/// Initialize the propagator network. Returns opaque handle.
export fn propagator_init() callconv(.c) ?*PropagatorHandle {
    const allocator = std.heap.c_allocator;
    const handle = allocator.create(PropagatorHandle) catch return null;
    handle.* = .{
        .network = SpatialNetwork.init(allocator),
        .allocator = allocator,
    };
    return handle;
}

/// Ingest topology from Syrup bytes. Returns 0 on success, negative on error.
export fn propagator_ingest_topology(
    handle: ?*PropagatorHandle,
    syrup_bytes: [*]const u8,
    len: usize,
) callconv(.c) i32 {
    const h = handle orelse return -1;
    h.network.ingestTopology(syrup_bytes[0..len]) catch return -2;
    return 0;
}

/// Get spatial colors into output buffer.
/// Format: packed [node_id:u32, fg:u32, bg:u32] per node.
/// Returns bytes written.
export fn propagator_get_spatial_colors(
    handle: ?*PropagatorHandle,
    output_buf: [*]u8,
    len: usize,
) callconv(.c) usize {
    const h = handle orelse return 0;
    return h.network.getSpatialColors(output_buf[0..len]);
}

/// Set focus to a specific node by window_id.
export fn propagator_set_focus(
    handle: ?*PropagatorHandle,
    node_id: u32,
) callconv(.c) void {
    const h = handle orelse return;
    h.network.setFocus(node_id);
}

/// Add a node directly (without Syrup parsing). Returns node index or -1.
export fn propagator_add_node(
    handle: ?*PropagatorHandle,
    window_id: u32,
    space_id: u32,
    depth: u32,
    x: i32,
    y: i32,
    w: u32,
    h_param: u32,
) callconv(.c) i32 {
    const hnd = handle orelse return -1;
    const info = SpatialInfo{
        .window_id = window_id,
        .space_id = space_id,
        .depth = depth,
        .bounds = .{ .x = x, .y = y, .width = w, .height = h_param },
        .spatial_index = @intCast(hnd.network.nodes.items.len),
    };
    const idx = hnd.network.addNode(info) catch return -1;
    return @intCast(idx);
}

/// Connect two nodes as adjacent.
export fn propagator_connect(handle: ?*PropagatorHandle, a: u32, b: u32) callconv(.c) void {
    const h = handle orelse return;
    h.network.connect(a, b) catch {};
}

/// Auto-detect adjacency from node bounds.
export fn propagator_detect_adjacency(handle: ?*PropagatorHandle) callconv(.c) void {
    const h = handle orelse return;
    h.network.detectAdjacency() catch {};
}

/// Assign colors after all nodes are added.
export fn propagator_assign_colors(handle: ?*PropagatorHandle) callconv(.c) void {
    const h = handle orelse return;
    h.network.assignColors() catch {};
}

/// Set a specific node's color directly (from external BCI source).
export fn propagator_set_node_color(
    handle: ?*PropagatorHandle,
    node_id: u32,
    fg: u32,
    bg: u32,
) callconv(.c) void {
    const h = handle orelse return;
    h.network.lock.lock();
    defer h.network.lock.unlock();
    for (h.network.nodes.items) |*node| {
        if (node.info.window_id == node_id) {
            node.fg_color = fg;
            node.bg_color = bg;
            return;
        }
    }
}

/// Assign colors from BCI brainwave entropy.
/// phi: integrated information (0-50 typical), valence: -log(vortex) (-10..0),
/// fisher: mean Fisher-Rao distance (0..5), trit: GF(3) symmetry (-1, 0, 1).
/// Colors derived via golden-angle projection matching Python valence_bridge.py.
export fn propagator_assign_colors_bci(
    handle: ?*PropagatorHandle,
    phi: f32,
    valence: f32,
    fisher: f32,
    trit: i32,
) callconv(.c) void {
    const h = handle orelse return;
    h.network.assignColorsFromBCI(phi, valence, fisher, trit) catch {};
}

/// Assign luminosity to all nodes based on GF(3) qutrit classification.
/// gate_order: 0 = separable (direct), 1 = entangled (CNOT₃), 2 = conjugate (CNOT₃†).
/// Dim/neutral/bright levels rotate with gate_order via σ on the L register.
export fn propagator_assign_luminosity_trit(
    handle: ?*PropagatorHandle,
    gate_order: u8,
) callconv(.c) void {
    const h = handle orelse return;
    h.network.assignLuminosityFromTrit(@intCast(gate_order % 3));
}

/// Cleanup.
export fn propagator_deinit(handle: ?*PropagatorHandle) callconv(.c) void {
    const h = handle orelse return;
    h.network.deinit();
    h.allocator.destroy(h);
}

// =============================================================================
// Tests
// =============================================================================

test "SpatialNetwork init/deinit" {
    const allocator = std.testing.allocator;
    var network = SpatialNetwork.init(allocator);
    defer network.deinit();

    try std.testing.expectEqual(@as(usize, 0), network.nodes.items.len);
}

test "SpatialNetwork add nodes and connect" {
    const allocator = std.testing.allocator;
    var network = SpatialNetwork.init(allocator);
    defer network.deinit();

    const idx0 = try network.addNode(.{ .window_id = 1, .bounds = .{ .x = 0, .y = 0, .width = 100, .height = 100 } });
    const idx1 = try network.addNode(.{ .window_id = 2, .bounds = .{ .x = 100, .y = 0, .width = 100, .height = 100 } });

    try std.testing.expectEqual(@as(u32, 0), idx0);
    try std.testing.expectEqual(@as(u32, 1), idx1);
    try std.testing.expectEqual(@as(usize, 2), network.nodes.items.len);

    try network.connect(0, 1);
    try std.testing.expectEqual(@as(usize, 1), network.nodes.items[0].adjacent.items.len);
    try std.testing.expectEqual(@as(usize, 1), network.nodes.items[1].adjacent.items.len);
}

test "SpatialNetwork detect adjacency" {
    const allocator = std.testing.allocator;
    var network = SpatialNetwork.init(allocator);
    defer network.deinit();

    // Two side-by-side rects
    _ = try network.addNode(.{ .window_id = 1, .bounds = .{ .x = 0, .y = 0, .width = 100, .height = 100 } });
    _ = try network.addNode(.{ .window_id = 2, .bounds = .{ .x = 100, .y = 0, .width = 100, .height = 100 } });
    // One below (not touching the others)
    _ = try network.addNode(.{ .window_id = 3, .bounds = .{ .x = 0, .y = 200, .width = 100, .height = 100 } });

    try network.detectAdjacency();

    // 0 and 1 share an edge
    try std.testing.expectEqual(@as(usize, 1), network.nodes.items[0].adjacent.items.len);
    try std.testing.expectEqual(@as(usize, 1), network.nodes.items[1].adjacent.items.len);
    // 2 shares no edge with anyone
    try std.testing.expectEqual(@as(usize, 0), network.nodes.items[2].adjacent.items.len);
}

test "SpatialNetwork color assignment" {
    const allocator = std.testing.allocator;
    var network = SpatialNetwork.init(allocator);
    defer network.deinit();

    _ = try network.addNode(.{ .window_id = 1, .spatial_index = 0 });
    _ = try network.addNode(.{ .window_id = 2, .spatial_index = 1 });
    _ = try network.addNode(.{ .window_id = 3, .spatial_index = 2 });

    try network.assignColors();

    // All nodes should have non-zero fg colors
    for (network.nodes.items) |node| {
        try std.testing.expect(node.fg_color != 0);
        try std.testing.expect(node.bg_color != 0);
    }
    // Colors should be distinct
    try std.testing.expect(network.nodes.items[0].fg_color != network.nodes.items[1].fg_color);
    try std.testing.expect(network.nodes.items[1].fg_color != network.nodes.items[2].fg_color);
}

test "SpatialNetwork focus propagation" {
    const allocator = std.testing.allocator;
    var network = SpatialNetwork.init(allocator);
    defer network.deinit();

    _ = try network.addNode(.{ .window_id = 1 });
    _ = try network.addNode(.{ .window_id = 2 });
    try network.connect(0, 1);

    network.setFocus(1);

    // Node 0 (window_id=1) should be focused
    try std.testing.expectEqual(@as(f32, 1.0), network.nodes.items[0].focus_level);
    // Node 1 (window_id=2) should have halo effect (0.2 * 1.0 = 0.2)
    try std.testing.expectApproxEqAbs(@as(f32, 0.2), network.nodes.items[1].focus_level, 0.01);
}

test "SpatialNetwork getSpatialColors" {
    const allocator = std.testing.allocator;
    var network = SpatialNetwork.init(allocator);
    defer network.deinit();

    _ = try network.addNode(.{ .window_id = 42, .spatial_index = 0 });
    try network.assignColors();

    var buf: [24]u8 = undefined;
    const written = network.getSpatialColors(&buf);

    try std.testing.expectEqual(@as(usize, 12), written);
    // First 4 bytes should be window_id = 42
    const node_id = std.mem.readInt(u32, buf[0..4], .little);
    try std.testing.expectEqual(@as(u32, 42), node_id);
}

test "Rect sharesEdge" {
    const a = Rect{ .x = 0, .y = 0, .width = 100, .height = 100 };
    const b = Rect{ .x = 100, .y = 0, .width = 100, .height = 100 }; // right neighbor
    const c = Rect{ .x = 0, .y = 100, .width = 100, .height = 100 }; // bottom neighbor
    const d = Rect{ .x = 200, .y = 0, .width = 100, .height = 100 }; // gap

    try std.testing.expect(a.sharesEdge(b));
    try std.testing.expect(b.sharesEdge(a));
    try std.testing.expect(a.sharesEdge(c));
    try std.testing.expect(!a.sharesEdge(d));
}

test "Rect contains" {
    const r = Rect{ .x = 10, .y = 20, .width = 50, .height = 30 };
    try std.testing.expect(r.contains(10, 20));
    try std.testing.expect(r.contains(30, 30));
    try std.testing.expect(!r.contains(60, 20)); // x = 10 + 50 = 60 is exclusive
    try std.testing.expect(!r.contains(9, 20));
}

test "spatialColorTransform with null user_data" {
    const cell = cell_dispatch.Cell{ .codepoint = 65, .fg = 0xFFFFFFFF, .bg = 0xFF000000, .attrs = 0 };
    const ctx = cell_dispatch.TransducerContext.init(std.testing.allocator, 1, 0);
    const result = spatialColorTransform(cell, ctx);
    // With null user_data, cell passes through unchanged
    try std.testing.expectEqual(cell, result);
}

test "spatialColorTransform with network" {
    const allocator = std.testing.allocator;
    var network = SpatialNetwork.init(allocator);
    defer network.deinit();

    _ = try network.addNode(.{ .window_id = 65, .spatial_index = 0 });
    try network.assignColors();
    network.setFocus(65);

    const cell = cell_dispatch.Cell{ .codepoint = 65, .fg = 0xFFFFFFFF, .bg = 0xFF000000, .attrs = 0 };
    var ctx = cell_dispatch.TransducerContext.init(allocator, 1, 0);
    ctx = ctx.withUserData(@ptrCast(&network));

    const result = spatialColorTransform(cell, ctx);
    // fg should be modified (non-default white)
    try std.testing.expect(result.fg != 0xFFFFFFFF);
}

test "BCI entropy color assignment" {
    const allocator = std.testing.allocator;
    var network = SpatialNetwork.init(allocator);
    defer network.deinit();

    _ = try network.addNode(.{ .window_id = 1, .spatial_index = 0 });
    _ = try network.addNode(.{ .window_id = 2, .spatial_index = 1 });
    _ = try network.addNode(.{ .window_id = 3, .spatial_index = 2 });

    // Typical focused state: Φ≈25, valence≈-3, fisher≈1.5, trit=0
    try network.assignColorsFromBCI(25.0, -3.0, 1.5, 0);

    // All nodes should have colors
    for (network.nodes.items) |node| {
        try std.testing.expect(node.fg_color != 0);
        try std.testing.expect(node.bg_color != 0);
    }
    // Colors should be distinct (golden angle dispersion)
    try std.testing.expect(network.nodes.items[0].fg_color != network.nodes.items[1].fg_color);

    // Different Φ should produce different base hue
    var network2 = SpatialNetwork.init(allocator);
    defer network2.deinit();
    _ = try network2.addNode(.{ .window_id = 1, .spatial_index = 0 });
    try network2.assignColorsFromBCI(33.0, -3.0, 1.5, 0); // resting Φ≈33

    try std.testing.expect(network.nodes.items[0].fg_color != network2.nodes.items[0].fg_color);

    // Different valence should affect chroma → different color
    var network3 = SpatialNetwork.init(allocator);
    defer network3.deinit();
    _ = try network3.addNode(.{ .window_id = 1, .spatial_index = 0 });
    try network3.assignColorsFromBCI(25.0, -8.0, 1.5, 0); // low valence (many vortices)

    try std.testing.expect(network.nodes.items[0].fg_color != network3.nodes.items[0].fg_color);
}

test "luminosity from qutrit classification" {
    const allocator = std.testing.allocator;
    var network = SpatialNetwork.init(allocator);
    defer network.deinit();

    // Red-dominant node → trit minus → dim
    _ = try network.addNode(.{ .window_id = 1 });
    network.nodes.items[0].fg_color = 0xFF_FF_20_20; // red dominant

    // Green-dominant node → trit plus → bright
    _ = try network.addNode(.{ .window_id = 2 });
    network.nodes.items[1].fg_color = 0xFF_20_FF_20; // green dominant

    // Balanced node → trit zero → neutral
    _ = try network.addNode(.{ .window_id = 3 });
    network.nodes.items[2].fg_color = 0xFF_80_80_80; // gray

    // Apply luminosity with separable (no entanglement shift)
    network.assignLuminosityFromTrit(0);

    // Red node should be dimmer (R channel reduced from 0xFF)
    const red_r = (network.nodes.items[0].fg_color >> 16) & 0xFF;
    try std.testing.expect(red_r < 0xFF);

    // Green node should be brighter (G channel boosted toward 0xFF)
    const green_g = (network.nodes.items[1].fg_color >> 8) & 0xFF;
    try std.testing.expect(green_g > 0x20);

    // Red should be dimmer than green overall
    try std.testing.expect(red_r < green_g);
}
