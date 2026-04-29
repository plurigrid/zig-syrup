//! zigbjj narrative: commit-DAG tree construction + ASCII rendering.
//!
//! Phase 7 of the lazybjj-unison rebuild plan. Pure construction + render
//! over a caller-supplied adjacency map (change_id → parent slice). The
//! actual jj traversal lives in zigbjj_jj.zig; this module is environment-
//! independent so it can be unit-tested against synthetic DAGs.
//!
//! MCP-shaped JSON encoder (toJson) is provided so the existing nanoclj
//! MCP server can expose `get_colored_tree` without entangling its source.

const std = @import("std");
const ziggit = @import("ziggit.zig");
const splitmix = @import("splitmix_trit.zig");
const Trit = splitmix.Trit;
const Allocator = std.mem.Allocator;

pub const ChangeId = [32]u8;

pub const NarrativeNode = struct {
    change_id: ChangeId,
    description: []const u8,
    trit: Trit,
    color: ziggit.ChangeColor,
    children: []NarrativeNode,
    score: f64, // criticalityScore over [self trit + ancestors]

    /// Recursively free `children` (descriptions are caller-owned).
    pub fn deinit(self: *NarrativeNode, alloc: Allocator) void {
        for (self.children) |*c| c.deinit(alloc);
        alloc.free(self.children);
    }
};

/// Adjacency entry: a node knows its change_id, description, and the
/// list of its parent change_ids. Caller owns these slices.
pub const AdjacencyEntry = struct {
    change_id: ChangeId,
    description: []const u8,
    parent_ids: []const ChangeId,
};

/// Build a narrative tree rooted at `root` by walking parent edges.
/// `entries` is a flat slice; lookup is O(N) per hop — fine for short
/// histories. `seed` parameterises the plastic coloring.
/// `max_depth` bounds recursion to avoid cycles in degenerate graphs.
pub fn build(
    alloc: Allocator,
    entries: []const AdjacencyEntry,
    root: ChangeId,
    seed: u64,
    max_depth: u8,
) !NarrativeNode {
    return buildInner(alloc, entries, root, seed, max_depth, 0);
}

fn buildInner(
    alloc: Allocator,
    entries: []const AdjacencyEntry,
    cur: ChangeId,
    seed: u64,
    max_depth: u8,
    depth: u8,
) !NarrativeNode {
    const entry = findEntry(entries, cur);
    const desc = if (entry) |e| e.description else "";
    const parents = if (entry) |e| e.parent_ids else &[_]ChangeId{};
    const color = ziggit.colorFromChangeId(cur, seed);

    var children: []NarrativeNode = &[_]NarrativeNode{};
    if (depth < max_depth and parents.len > 0) {
        var list = std.ArrayList(NarrativeNode){};
        errdefer {
            for (list.items) |*c| c.deinit(alloc);
            list.deinit(alloc);
        }
        for (parents) |p| {
            const child = try buildInner(alloc, entries, p, seed, max_depth, depth + 1);
            try list.append(alloc, child);
        }
        children = try list.toOwnedSlice(alloc);
    }

    // Local score = entropy×variance over [self + child trits].
    var trit_buf: [256]Trit = undefined;
    const k = @min(children.len + 1, trit_buf.len);
    trit_buf[0] = color.trit;
    var i: usize = 0;
    while (i + 1 < k) : (i += 1) trit_buf[i + 1] = children[i].trit;
    const score = computeScore(trit_buf[0..k]);

    return .{
        .change_id = cur,
        .description = desc,
        .trit = color.trit,
        .color = color,
        .children = children,
        .score = score,
    };
}

fn findEntry(entries: []const AdjacencyEntry, id: ChangeId) ?AdjacencyEntry {
    for (entries) |e| {
        if (std.mem.eql(u8, &e.change_id, &id)) return e;
    }
    return null;
}

fn computeScore(trits: []const Trit) f64 {
    if (trits.len == 0) return 0;
    var counts: ziggit.KernelTriad = .{ .plus = 0, .ergodic = 0, .minus = 0 };
    var sum: f64 = 0;
    var sq: f64 = 0;
    for (trits) |t| {
        switch (t) {
            .plus => counts.plus += 1,
            .ergodic => counts.ergodic += 1,
            .minus => counts.minus += 1,
        }
        const v: f64 = switch (t) {
            .minus => -1,
            .ergodic => 0,
            .plus => 1,
        };
        sum += v;
        sq += v * v;
    }
    const n = @as(f64, @floatFromInt(trits.len));
    const mean = sum / n;
    const var_ = (sq / n) - (mean * mean);
    var h: f64 = 0;
    inline for (.{ counts.plus, counts.ergodic, counts.minus }) |c| {
        if (c > 0) {
            const p = @as(f64, @floatFromInt(c)) / n;
            h -= p * @log2(p);
        }
    }
    return h * var_;
}

/// Render an ASCII tree of the narrative to `writer`.
/// Each line: "<trit-glyph> <short-hex>  <description>".
pub fn render(node: *const NarrativeNode, writer: anytype) !void {
    try renderInner(node, writer, 0, "");
}

fn renderInner(
    node: *const NarrativeNode,
    writer: anytype,
    depth: usize,
    _: []const u8,
) !void {
    var hex: [64]u8 = undefined;
    @import("zigbjj_jj.zig").formatHex(&hex, node.change_id);
    const sym = ziggit.tritSymbol(node.trit);
    // Two-space indent per depth level.
    var i: usize = 0;
    while (i < depth) : (i += 1) try writer.writeAll("  ");
    try writer.print("{s} {s} {s}\n", .{ sym, hex[0..8], node.description });
    for (node.children) |*c| {
        try renderInner(c, writer, depth + 1, "");
    }
}

/// Walk the tree following the highest-scoring child at each step.
/// Returns an owned slice of change_ids; first element is the root.
pub fn criticalPath(alloc: Allocator, node: *const NarrativeNode) ![]ChangeId {
    var list = std.ArrayList(ChangeId){};
    errdefer list.deinit(alloc);
    var cur: *const NarrativeNode = node;
    try list.append(alloc, cur.change_id);
    while (cur.children.len > 0) {
        var best: usize = 0;
        var best_score = cur.children[0].score;
        for (cur.children, 0..) |c, i| {
            if (c.score > best_score) {
                best_score = c.score;
                best = i;
            }
        }
        cur = &cur.children[best];
        try list.append(alloc, cur.change_id);
    }
    return try list.toOwnedSlice(alloc);
}

/// Simple JSON encoder for MCP exposure. Caller owns the returned slice.
pub fn toJson(alloc: Allocator, node: *const NarrativeNode) ![]u8 {
    var buf = std.ArrayList(u8){};
    errdefer buf.deinit(alloc);
    try toJsonInner(node, &buf, alloc);
    return try buf.toOwnedSlice(alloc);
}

fn toJsonInner(
    node: *const NarrativeNode,
    buf: *std.ArrayList(u8),
    alloc: Allocator,
) !void {
    var hex: [64]u8 = undefined;
    @import("zigbjj_jj.zig").formatHex(&hex, node.change_id);
    try buf.appendSlice(alloc, "{\"change_id\":\"");
    try buf.appendSlice(alloc, &hex);
    try buf.appendSlice(alloc, "\",\"trit\":");
    const trit_int: i8 = @intFromEnum(node.trit);
    try std.fmt.format(buf.writer(alloc), "{d}", .{trit_int});
    try buf.appendSlice(alloc, ",\"hue\":");
    try std.fmt.format(buf.writer(alloc), "{d:.3}", .{node.color.hue});
    try buf.appendSlice(alloc, ",\"score\":");
    try std.fmt.format(buf.writer(alloc), "{d:.6}", .{node.score});
    try buf.appendSlice(alloc, ",\"description\":\"");
    for (node.description) |c| {
        if (c == '"' or c == '\\') try buf.append(alloc, '\\');
        try buf.append(alloc, c);
    }
    try buf.appendSlice(alloc, "\",\"children\":[");
    for (node.children, 0..) |*c, i| {
        if (i > 0) try buf.append(alloc, ',');
        try toJsonInner(c, buf, alloc);
    }
    try buf.appendSlice(alloc, "]}");
}

// ============================================================================
// Tests
// ============================================================================

const expectEqual = std.testing.expectEqual;
const expect = std.testing.expect;

fn idFromByte(b: u8) ChangeId {
    var id: ChangeId = undefined;
    @memset(&id, b);
    return id;
}

test "build: linear chain root → parent → grandparent" {
    const child = idFromByte(0x10);
    const parent = idFromByte(0x20);
    const grand = idFromByte(0x30);
    const entries = [_]AdjacencyEntry{
        .{ .change_id = child, .description = "fix bug", .parent_ids = &[_]ChangeId{parent} },
        .{ .change_id = parent, .description = "add feature", .parent_ids = &[_]ChangeId{grand} },
        .{ .change_id = grand, .description = "initial", .parent_ids = &[_]ChangeId{} },
    };
    var root = try build(std.testing.allocator, &entries, child, 1069, 8);
    defer root.deinit(std.testing.allocator);
    try expectEqual(@as(usize, 1), root.children.len);
    try expectEqual(@as(usize, 1), root.children[0].children.len);
    try expectEqual(@as(usize, 0), root.children[0].children[0].children.len);
    try std.testing.expectEqualSlices(u8, "fix bug", root.description);
}

test "build: respects max_depth" {
    const a = idFromByte(0xA1);
    const b = idFromByte(0xB2);
    const c = idFromByte(0xC3);
    const entries = [_]AdjacencyEntry{
        .{ .change_id = a, .description = "a", .parent_ids = &[_]ChangeId{b} },
        .{ .change_id = b, .description = "b", .parent_ids = &[_]ChangeId{c} },
        .{ .change_id = c, .description = "c", .parent_ids = &[_]ChangeId{} },
    };
    var root = try build(std.testing.allocator, &entries, a, 0, 1);
    defer root.deinit(std.testing.allocator);
    try expectEqual(@as(usize, 1), root.children.len);
    try expectEqual(@as(usize, 0), root.children[0].children.len);
}

test "build: missing parent yields empty children" {
    const a = idFromByte(0x77);
    const entries = [_]AdjacencyEntry{
        .{ .change_id = a, .description = "orphan", .parent_ids = &[_]ChangeId{} },
    };
    var root = try build(std.testing.allocator, &entries, a, 0, 8);
    defer root.deinit(std.testing.allocator);
    try expectEqual(@as(usize, 0), root.children.len);
}

test "criticalPath: linear chain returns the chain" {
    const a = idFromByte(0xAA);
    const b = idFromByte(0xBB);
    const c = idFromByte(0xCC);
    const entries = [_]AdjacencyEntry{
        .{ .change_id = a, .description = "a", .parent_ids = &[_]ChangeId{b} },
        .{ .change_id = b, .description = "b", .parent_ids = &[_]ChangeId{c} },
        .{ .change_id = c, .description = "c", .parent_ids = &[_]ChangeId{} },
    };
    var root = try build(std.testing.allocator, &entries, a, 1, 8);
    defer root.deinit(std.testing.allocator);
    const path = try criticalPath(std.testing.allocator, &root);
    defer std.testing.allocator.free(path);
    try expectEqual(@as(usize, 3), path.len);
    try std.testing.expectEqualSlices(u8, &a, &path[0]);
    try std.testing.expectEqualSlices(u8, &c, &path[2]);
}

test "render: emits one line per node" {
    const a = idFromByte(0x01);
    const b = idFromByte(0x02);
    const entries = [_]AdjacencyEntry{
        .{ .change_id = a, .description = "child", .parent_ids = &[_]ChangeId{b} },
        .{ .change_id = b, .description = "parent", .parent_ids = &[_]ChangeId{} },
    };
    var root = try build(std.testing.allocator, &entries, a, 1069, 8);
    defer root.deinit(std.testing.allocator);
    var out = std.ArrayList(u8){};
    defer out.deinit(std.testing.allocator);
    try render(&root, out.writer(std.testing.allocator));
    // Expect 2 lines (one per node).
    var lines = std.mem.tokenizeScalar(u8, out.items, '\n');
    var n: usize = 0;
    while (lines.next()) |_| n += 1;
    try expectEqual(@as(usize, 2), n);
}

test "toJson: round-tripable shape" {
    const a = idFromByte(0xAB);
    const entries = [_]AdjacencyEntry{
        .{ .change_id = a, .description = "hello", .parent_ids = &[_]ChangeId{} },
    };
    var root = try build(std.testing.allocator, &entries, a, 1069, 8);
    defer root.deinit(std.testing.allocator);
    const json = try toJson(std.testing.allocator, &root);
    defer std.testing.allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"change_id\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"trit\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"description\":\"hello\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"children\":[]") != null);
}
