//! Coloring Functor — Graph k-Coloring via Structured Decompositions
//!
//! Port of Coloring(n) from StructuredDecompositions.jl.
//!
//! The Coloring(n) functor maps:
//!   - A graph G to FinSet(valid n-colorings of G)
//!   - A graph homomorphism f: G -> H to FinFunction(colorings(H) -> colorings(G))
//!     via precomposition: coloring_G = coloring_H ∘ f
//!
//! Combined with the 𝐃 functor from decomposition.zig and adhesion_filter,
//! this gives an O(n^tw) algorithm for deciding k-colorability where
//! tw is the treewidth of the graph.
//!
//! For GF(3): Coloring(3) is exactly the 3-colorability problem,
//! and valid 3-colorings correspond to balanced ternary assignments.
//!
//! This lives in contrib/ because graph coloring is an application
//! of the core decomposition machinery, not infrastructure.

const std = @import("std");
const Allocator = std.mem.Allocator;
const finset_mod = @import("finset");
const FinSet = finset_mod.FinSet;
const FinFunction = finset_mod.FinFunction;
const decomp = @import("decomposition");
const StrDecomp = decomp.StrDecomp;

/// A simple undirected graph as adjacency list.
pub const Graph = struct {
    num_vertices: u32,
    edges: []const [2]u32, // each edge is [src, dst]

    /// Check if two vertices are adjacent.
    pub fn adjacent(self: Graph, u: u32, v: u32) bool {
        for (self.edges) |e| {
            if ((e[0] == u and e[1] == v) or (e[0] == v and e[1] == u)) return true;
        }
        return false;
    }
};

/// A graph homomorphism f: G -> H (vertex map preserving adjacency).
pub const GraphHom = struct {
    vertex_map: []const u32, // vertex_map[v_G] = v_H
    source: Graph,
    target: Graph,
};

// ============================================================================
// Coloring Functor
// ============================================================================

/// Enumerate all valid n-colorings of a graph.
/// A coloring assigns each vertex a color in {0..n-1} such that
/// no two adjacent vertices share a color.
///
/// Returns the colorings as a flat array: colorings[c * num_verts + v] = color of v in coloring c.
/// Also returns the count of valid colorings.
pub fn enumerateColorings(
    allocator: Allocator,
    graph: Graph,
    n: u32,
) !struct { colorings: []u32, count: u32 } {
    const nv = graph.num_vertices;
    if (nv == 0) return .{ .colorings = &.{}, .count = 1 };

    var results = std.ArrayListUnmanaged(u32){};
    defer results.deinit(allocator);
    var count: u32 = 0;

    // Enumerate via backtracking
    const assignment = try allocator.alloc(u32, nv);
    defer allocator.free(assignment);

    var stack = std.ArrayListUnmanaged(struct { vertex: u32, color: u32 }){};
    defer stack.deinit(allocator);

    try stack.append(allocator, .{ .vertex = 0, .color = 0 });

    while (stack.items.len > 0) {
        const top = stack.pop().?;

        if (top.color >= n) continue;

        // Try assigning this color
        assignment[top.vertex] = top.color;

        // Check validity: no adjacent vertex has same color
        var valid = true;
        for (graph.edges) |e| {
            const u = e[0];
            const v = e[1];
            if (u == top.vertex and v < top.vertex and assignment[v] == top.color) {
                valid = false;
                break;
            }
            if (v == top.vertex and u < top.vertex and assignment[u] == top.color) {
                valid = false;
                break;
            }
        }

        if (!valid) {
            // Try next color
            if (top.color + 1 < n) {
                try stack.append(allocator, .{ .vertex = top.vertex, .color = top.color + 1 });
            }
            continue;
        }

        if (top.vertex + 1 == nv) {
            // Found a valid coloring — record it
            try results.appendSlice(allocator, assignment);
            count += 1;
            // Backtrack: try next color for this vertex
            if (top.color + 1 < n) {
                try stack.append(allocator, .{ .vertex = top.vertex, .color = top.color + 1 });
            }
        } else {
            // Recurse: try next color for this vertex, then move to next vertex
            if (top.color + 1 < n) {
                try stack.append(allocator, .{ .vertex = top.vertex, .color = top.color + 1 });
            }
            try stack.append(allocator, .{ .vertex = top.vertex + 1, .color = 0 });
        }
    }

    return .{
        .colorings = try results.toOwnedSlice(allocator),
        .count = count,
    };
}

/// ob_map: Graph -> FinSet
/// Returns the set of valid n-colorings of the graph.
pub fn coloringObMap(allocator: Allocator, graph: Graph, n: u32) !FinSet {
    const result = try enumerateColorings(allocator, graph, n);
    allocator.free(result.colorings);
    return FinSet.init(result.count);
}

/// hom_map: GraphHom -> FinFunction
/// Given f: G -> H and n-colorings of H, produce the induced map
/// on colorings by precomposition: c_G(v) = c_H(f(v)).
///
/// Returns a FinFunction: colorings(H) -> colorings(G)
/// mapping each coloring of H to the induced coloring of G.
pub fn coloringHomMap(
    allocator: Allocator,
    hom: GraphHom,
    n: u32,
) !FinFunction {
    const g_result = try enumerateColorings(allocator, hom.source, n);
    defer allocator.free(g_result.colorings);
    const h_result = try enumerateColorings(allocator, hom.target, n);
    defer allocator.free(h_result.colorings);

    const nv_g = hom.source.num_vertices;
    const nv_h = hom.target.num_vertices;

    // For each coloring of H, find the corresponding coloring of G
    const map = try allocator.alloc(u32, h_result.count);
    const induced = try allocator.alloc(u32, nv_g);
    defer allocator.free(induced);

    for (0..h_result.count) |ci| {
        const h_coloring = h_result.colorings[ci * nv_h .. (ci + 1) * nv_h];

        // Induce coloring on G: c_G(v) = c_H(f(v))
        for (0..nv_g) |v| {
            induced[v] = h_coloring[hom.vertex_map[v]];
        }

        // Find this coloring in G's coloring list
        var found: u32 = 0;
        var matched = false;
        for (0..g_result.count) |gi| {
            const g_coloring = g_result.colorings[gi * nv_g .. (gi + 1) * nv_g];
            if (std.mem.eql(u32, induced, g_coloring)) {
                found = @intCast(gi);
                matched = true;
                break;
            }
        }
        map[ci] = if (matched) found else 0;
    }

    return FinFunction.init(h_result.count, g_result.count, map);
}

/// Decide if a graph is n-colorable using tree decomposition.
/// Takes a tree decomposition as bags (subgraphs) with adhesions,
/// applies Coloring(n) to each bag, then runs adhesion_filter.
///
/// This is the sheaf-theoretic decision procedure from
/// StructuredDecompositions.jl: decide_sheaf_tree_shape.
pub fn decideColorable(
    allocator: Allocator,
    graphs: []const Graph,
    edges: []const decomp.Edge,
    adhesion_maps: []const struct {
        left_vmap: []const u32,
        right_vmap: []const u32,
        adhesion: Graph,
    },
    n: u32,
) !bool {
    const num_bags: u32 = @intCast(graphs.len);

    // Apply ob_map: compute FinSet of colorings for each bag
    const bag_sizes = try allocator.alloc(u32, num_bags);
    defer allocator.free(bag_sizes);
    for (graphs, 0..) |g, i| {
        const fs = try coloringObMap(allocator, g, n);
        bag_sizes[i] = fs.size;
    }

    // Build the CoDecomposition
    var d = try StrDecomp.init(allocator, num_bags, edges, bag_sizes, .co_decomposition);
    defer d.deinit();

    // Apply hom_map: compute cospan FinFunctions for each adhesion
    for (adhesion_maps, 0..) |am, e| {
        const edge = edges[e];
        const left_hom = GraphHom{
            .vertex_map = am.left_vmap,
            .source = am.adhesion,
            .target = graphs[edge.left_bag],
        };
        const right_hom = GraphHom{
            .vertex_map = am.right_vmap,
            .source = am.adhesion,
            .target = graphs[edge.right_bag],
        };

        const left_fn = try coloringHomMap(allocator, left_hom, n);
        const right_fn = try coloringHomMap(allocator, right_hom, n);
        d.setCospan(@intCast(e), left_fn, right_fn);
    }

    // Run adhesion_filter to convergence
    return try decomp.decideSheaf(&d);
}

// ============================================================================
// Tests
// ============================================================================

test "enumerate colorings of K2" {
    const allocator = std.testing.allocator;
    const edges = [_][2]u32{.{ 0, 1 }};
    const g = Graph{ .num_vertices = 2, .edges = &edges };

    // 2-colorable: 2! = 2 colorings
    const result2 = try enumerateColorings(allocator, g, 2);
    defer allocator.free(result2.colorings);
    try std.testing.expectEqual(@as(u32, 2), result2.count);

    // 3-colorable: 3*2 = 6 colorings
    const result3 = try enumerateColorings(allocator, g, 3);
    defer allocator.free(result3.colorings);
    try std.testing.expectEqual(@as(u32, 6), result3.count);
}

test "enumerate colorings of K3" {
    const allocator = std.testing.allocator;
    const edges = [_][2]u32{ .{ 0, 1 }, .{ 1, 2 }, .{ 0, 2 } };
    const g = Graph{ .num_vertices = 3, .edges = &edges };

    // K3 is not 2-colorable
    const result2 = try enumerateColorings(allocator, g, 2);
    defer allocator.free(result2.colorings);
    try std.testing.expectEqual(@as(u32, 0), result2.count);

    // K3 is 3-colorable: 3! = 6 colorings
    const result3 = try enumerateColorings(allocator, g, 3);
    defer allocator.free(result3.colorings);
    try std.testing.expectEqual(@as(u32, 6), result3.count);
}

test "enumerate colorings of independent set" {
    const allocator = std.testing.allocator;
    const g = Graph{ .num_vertices = 3, .edges = &.{} };

    // 2 colors on 3 independent vertices: 2^3 = 8
    const result = try enumerateColorings(allocator, g, 2);
    defer allocator.free(result.colorings);
    try std.testing.expectEqual(@as(u32, 8), result.count);
}

test "enumerate colorings of path P3" {
    const allocator = std.testing.allocator;
    const edges = [_][2]u32{ .{ 0, 1 }, .{ 1, 2 } };
    const g = Graph{ .num_vertices = 3, .edges = &edges };

    // P3 with 2 colors: 2*1*1 = 2 (alternating)
    const result = try enumerateColorings(allocator, g, 2);
    defer allocator.free(result.colorings);
    try std.testing.expectEqual(@as(u32, 2), result.count);

    // P3 with 3 colors: 3*2*2 = 12
    const result3 = try enumerateColorings(allocator, g, 3);
    defer allocator.free(result3.colorings);
    try std.testing.expectEqual(@as(u32, 12), result3.count);
}

test "coloringObMap returns correct FinSet size" {
    const allocator = std.testing.allocator;
    const edges = [_][2]u32{.{ 0, 1 }};
    const g = Graph{ .num_vertices = 2, .edges = &edges };

    const fs = try coloringObMap(allocator, g, 3);
    try std.testing.expectEqual(@as(u32, 6), fs.size);
}

test "graph adjacency check" {
    const edges = [_][2]u32{ .{ 0, 1 }, .{ 1, 2 } };
    const g = Graph{ .num_vertices = 3, .edges = &edges };

    try std.testing.expect(g.adjacent(0, 1));
    try std.testing.expect(g.adjacent(1, 0)); // symmetric
    try std.testing.expect(g.adjacent(1, 2));
    try std.testing.expect(!g.adjacent(0, 2));
}
