const std = @import("std");
const cell_sync = @import("cell_sync");

const CellSync = cell_sync.CellSync;
const CellDiff = cell_sync.CellDiff;
const Allocator = std.mem.Allocator;

// ============================================================================
// WORKLOAD CONFIGURATION
// ============================================================================

const WorkloadSize = struct {
    name: []const u8,
    cols: u16,
    rows: u16,
    iters: usize,

    fn numCells(self: WorkloadSize) usize {
        return @as(usize, self.cols) * self.rows;
    }
};

const WORKLOADS = [_]WorkloadSize{
    .{ .name = "tiny", .cols = 10, .rows = 1, .iters = 100_000 },
    .{ .name = "small", .cols = 20, .rows = 5, .iters = 50_000 },
    .{ .name = "medium", .cols = 80, .rows = 24, .iters = 10_000 },
    .{ .name = "large", .cols = 160, .rows = 50, .iters = 1_000 },
    .{ .name = "4K", .cols = 200, .rows = 75, .iters = 500 },
};

// ============================================================================
// BENCHMARK RESULTS
// ============================================================================

const BenchResult = struct {
    workload: WorkloadSize,
    // Stage timings (ns/op)
    commit_ns: i128,
    pack_ns: i128,
    unpack_ns: i128,
    syrup_encode_ns: i128,
    syrup_decode_ns: i128,
    apply_ns: i128,
    // Size metrics
    raw_bytes: usize,
    compressed_bytes: usize,
    num_diffs: usize,
    // Zero-alloc fast path: syrup decode + apply combined
    fast_path_ns: i128,
    // Allocation counts (pack + unpack)
    pack_allocs: usize,
    unpack_allocs: usize,

    /// True pipeline total: commit → syrup_encode → syrup_decode → apply.
    /// syrup_encode already includes pack, syrup_decode already includes unpack,
    /// so pack/unpack are NOT added separately (that would double-count).
    fn totalNs(self: BenchResult) i128 {
        return self.commit_ns + self.syrup_encode_ns + self.syrup_decode_ns + self.apply_ns;
    }

    /// Pipeline total using zero-alloc fast path for decode side
    fn totalFastNs(self: BenchResult) i128 {
        return self.commit_ns + self.syrup_encode_ns + self.fast_path_ns;
    }

    fn fastOpsPerSec(self: BenchResult) i128 {
        const total = self.totalFastNs();
        if (total <= 0) return 0;
        return @divFloor(1_000_000_000, total);
    }

    fn fastCellsPerSec(self: BenchResult) i128 {
        const total = self.totalFastNs();
        if (total <= 0) return 0;
        return @divFloor(@as(i128, self.num_diffs) * 1_000_000_000, total);
    }

    /// Syrup record overhead beyond pack/unpack (allocation + field setup)
    fn syrupOverheadEncode(self: BenchResult) i128 {
        return @max(0, self.syrup_encode_ns - self.pack_ns);
    }

    fn syrupOverheadDecode(self: BenchResult) i128 {
        return @max(0, self.syrup_decode_ns - self.unpack_ns);
    }

    fn opsPerSec(self: BenchResult) i128 {
        const total = self.totalNs();
        if (total <= 0) return 0;
        return @divFloor(1_000_000_000, total);
    }

    fn cellsPerSec(self: BenchResult) i128 {
        const total = self.totalNs();
        if (total <= 0) return 0;
        return @divFloor(@as(i128, self.num_diffs) * 1_000_000_000, total);
    }

    fn wireEfficiency(self: BenchResult) f64 {
        // Bytes on wire per cell (compressed)
        if (self.num_diffs == 0) return 0;
        return @as(f64, @floatFromInt(self.compressed_bytes)) / @as(f64, @floatFromInt(self.num_diffs));
    }
};

// ============================================================================
// COLOR AND RENDERING
// ============================================================================

const RGB = struct {
    r: u8,
    g: u8,
    b: u8,

    fn fg(self: RGB, writer: anytype) !void {
        try writer.print("\x1b[38;2;{d};{d};{d}m", .{ self.r, self.g, self.b });
    }

    fn bg(self: RGB, writer: anytype) !void {
        try writer.print("\x1b[48;2;{d};{d};{d}m", .{ self.r, self.g, self.b });
    }

    fn lerp(a: RGB, b: RGB, t: f64) RGB {
        return .{
            .r = @intFromFloat(@as(f64, @floatFromInt(a.r)) * (1.0 - t) + @as(f64, @floatFromInt(b.r)) * t),
            .g = @intFromFloat(@as(f64, @floatFromInt(a.g)) * (1.0 - t) + @as(f64, @floatFromInt(b.g)) * t),
            .b = @intFromFloat(@as(f64, @floatFromInt(a.b)) * (1.0 - t) + @as(f64, @floatFromInt(b.b)) * t),
        };
    }
};

const RESET = "\x1b[0m";
const BOLD = "\x1b[1m";
const DIM = "\x1b[2m";

// GF(3)-inspired stage colors
const COLOR_COMMIT = RGB{ .r = 255, .g = 107, .b = 53 }; // warm orange (+1)
const COLOR_PACK = RGB{ .r = 59, .g = 130, .b = 246 }; // cool blue (-1)
const COLOR_UNPACK = RGB{ .r = 100, .g = 200, .b = 100 }; // green
const COLOR_SYRUP_ENC = RGB{ .r = 160, .g = 160, .b = 160 }; // neutral gray (0)
const COLOR_SYRUP_DEC = RGB{ .r = 180, .g = 140, .b = 255 }; // violet
const COLOR_APPLY = RGB{ .r = 255, .g = 215, .b = 0 }; // gold
const COLOR_BORDER = RGB{ .r = 80, .g = 80, .b = 80 };
const COLOR_TITLE = RGB{ .r = 255, .g = 255, .b = 255 };
const COLOR_LABEL = RGB{ .r = 200, .g = 200, .b = 200 };
const COLOR_GOOD = RGB{ .r = 100, .g = 220, .b = 100 };
const COLOR_BAD = RGB{ .r = 220, .g = 80, .b = 80 };
const COLOR_DIM = RGB{ .r = 120, .g = 120, .b = 120 };

// Sparkline characters (8 levels)
const SPARK = [_][]const u8{ "\u{2581}", "\u{2582}", "\u{2583}", "\u{2584}", "\u{2585}", "\u{2586}", "\u{2587}", "\u{2588}" };

// ============================================================================
// WORKLOAD GENERATION
// ============================================================================

fn generateWorkload(sync: *CellSync, w: WorkloadSize) void {
    const wire_char: u21 = 0x2500; // ─
    const gate_chars = [_]u21{ 'H', 'X', 'Z', 'S', 'T' };
    const control_char: u21 = 0x25CF; // ●
    const target_char: u21 = 0x2295; // ⊕
    const vert_char: u21 = 0x2502; // │

    const COLOR_WIRE: u24 = 0x666666;
    const COLOR_GATE: u24 = 0xFFD700;
    const COLOR_CTRL: u24 = 0xFF6B35;
    const COLOR_TGT: u24 = 0x3B82F6;

    const num_qubits: u16 = @min(w.rows, 8);
    if (num_qubits == 0) return;

    var q: u16 = 0;
    while (q < num_qubits) : (q += 1) {
        const row = q * 2;
        if (row >= w.rows) break;
        var col: u16 = 0;
        while (col < w.cols) : (col += 1) {
            sync.writeCell(col, row, .{
                .codepoint = wire_char,
                .fg = COLOR_WIRE,
                .bg = 0x000000,
            });
        }
    }

    var col: u16 = 4;
    while (col + 2 < w.cols) : (col += 5) {
        var qi: u16 = 0;
        while (qi < num_qubits) : (qi += 1) {
            const row = qi * 2;
            if (row >= w.rows) break;
            if ((qi + col) % 3 == 0) {
                const gate = gate_chars[(qi + col / 5) % gate_chars.len];
                sync.writeCell(col, row, .{ .codepoint = 0x2524, .fg = COLOR_GATE, .bg = 0x000000 });
                sync.writeCell(col + 1, row, .{ .codepoint = gate, .fg = COLOR_GATE, .bg = 0x1a1a2e });
                sync.writeCell(col + 2, row, .{ .codepoint = 0x251C, .fg = COLOR_GATE, .bg = 0x000000 });
            }
        }
        if (num_qubits > 1 and col % 10 == 4) {
            sync.writeCell(col + 1, 0, .{ .codepoint = control_char, .fg = COLOR_CTRL, .bg = 0x000000 });
            if (2 < w.rows) sync.writeCell(col + 1, 2, .{ .codepoint = target_char, .fg = COLOR_TGT, .bg = 0x000000 });
            if (1 < w.rows) sync.writeCell(col + 1, 1, .{ .codepoint = vert_char, .fg = COLOR_WIRE, .bg = 0x000000 });
        }
    }
}

// ============================================================================
// ALLOCATION COUNTING ALLOCATOR
// ============================================================================

fn CountingAllocator(comptime Inner: type) type {
    return struct {
        inner: Inner,
        alloc_count: usize = 0,
        free_count: usize = 0,
        bytes_allocated: usize = 0,
        peak_bytes: usize = 0,
        current_bytes: usize = 0,

        const Self = @This();

        fn allocator(self: *Self) Allocator {
            return .{
                .ptr = self,
                .vtable = &.{
                    .alloc = alloc,
                    .resize = resize,
                    .remap = remap,
                    .free = free,
                },
            };
        }

        fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.alloc_count += 1;
            self.bytes_allocated += len;
            self.current_bytes += len;
            if (self.current_bytes > self.peak_bytes) self.peak_bytes = self.current_bytes;
            return self.inner.allocator().rawAlloc(len, alignment, ret_addr);
        }

        fn resize(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) bool {
            return false;
        }

        fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
            const self: *Self = @ptrCast(@alignCast(ctx));
            if (new_len > memory.len) {
                self.current_bytes += new_len - memory.len;
                self.bytes_allocated += new_len - memory.len;
            } else {
                self.current_bytes -= memory.len - new_len;
            }
            if (self.current_bytes > self.peak_bytes) self.peak_bytes = self.current_bytes;
            return self.inner.allocator().rawRemap(memory, alignment, new_len, ret_addr);
        }

        fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.free_count += 1;
            self.current_bytes -= memory.len;
            self.inner.allocator().rawFree(memory, alignment, ret_addr);
        }

        fn reset(self: *Self) void {
            self.alloc_count = 0;
            self.free_count = 0;
            self.bytes_allocated = 0;
            self.peak_bytes = 0;
            self.current_bytes = 0;
        }
    };
}

// ============================================================================
// BENCHMARK FUNCTIONS
// ============================================================================

fn benchCommit(allocator: Allocator, w: WorkloadSize) !struct { ns: i128, diffs: []CellDiff } {
    var sync = try CellSync.init(allocator, 1, w.cols, w.rows);
    defer sync.deinit();
    generateWorkload(&sync, w);

    var warmup = try sync.commit();
    const diffs_copy = try allocator.dupe(CellDiff, warmup.diffs);
    warmup.deinit(allocator);

    const start = std.time.nanoTimestamp();
    var run: usize = 0;
    while (run < w.iters) : (run += 1) {
        for (diffs_copy) |d| sync.writeCell(d.x, d.y, d.cell);
        var snap = try sync.commit();
        snap.deinit(allocator);
    }
    const end = std.time.nanoTimestamp();

    return .{ .ns = @divFloor(end - start, @as(i128, w.iters)), .diffs = diffs_copy };
}

fn benchPack(allocator: Allocator, diffs: []const CellDiff, iters: usize) !struct { ns: i128, compressed_bytes: usize, allocs: usize } {
    const warmup = try CellSync.packDiffs(allocator, diffs);
    const compressed_len = warmup.len;
    allocator.free(warmup);

    // Count allocations for one run
    var counting = CountingAllocator(std.heap.GeneralPurposeAllocator(.{})){
        .inner = std.heap.GeneralPurposeAllocator(.{}){},
    };
    const ca = counting.allocator();
    const test_pack = try CellSync.packDiffs(ca, diffs);
    ca.free(test_pack);
    const allocs = counting.alloc_count;
    _ = counting.inner.deinit();

    const start = std.time.nanoTimestamp();
    var run: usize = 0;
    while (run < iters) : (run += 1) {
        const p = try CellSync.packDiffs(allocator, diffs);
        allocator.free(p);
    }
    const end = std.time.nanoTimestamp();
    return .{
        .ns = @divFloor(end - start, @as(i128, iters)),
        .compressed_bytes = compressed_len,
        .allocs = allocs,
    };
}

fn benchUnpack(allocator: Allocator, diffs: []const CellDiff, iters: usize) !struct { ns: i128, allocs: usize } {
    const packed_data = try CellSync.packDiffs(allocator, diffs);
    defer allocator.free(packed_data);

    // Count allocations
    var counting = CountingAllocator(std.heap.GeneralPurposeAllocator(.{})){
        .inner = std.heap.GeneralPurposeAllocator(.{}){},
    };
    const ca = counting.allocator();
    const test_unpack = try CellSync.unpackDiffs(ca, packed_data);
    ca.free(test_unpack);
    const allocs = counting.alloc_count;
    _ = counting.inner.deinit();

    const start = std.time.nanoTimestamp();
    var run: usize = 0;
    while (run < iters) : (run += 1) {
        const u = try CellSync.unpackDiffs(allocator, packed_data);
        allocator.free(u);
    }
    const end = std.time.nanoTimestamp();
    return .{
        .ns = @divFloor(end - start, @as(i128, iters)),
        .allocs = allocs,
    };
}

fn benchSyrupEncode(allocator: Allocator, w: WorkloadSize, diffs: []const CellDiff) !i128 {
    var sync = try CellSync.init(allocator, 1, w.cols, w.rows);
    defer sync.deinit();
    const snapshot = cell_sync.FrameSnapshot{
        .gen = 1, .cols = w.cols, .rows = w.rows,
        .diffs = @constCast(diffs), .is_full = false, .source = 1,
    };

    const start = std.time.nanoTimestamp();
    var run: usize = 0;
    while (run < w.iters) : (run += 1) {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        _ = try sync.snapshotToSyrup(&snapshot, arena.allocator());
    }
    const end = std.time.nanoTimestamp();
    return @divFloor(end - start, @as(i128, w.iters));
}

fn benchSyrupDecode(allocator: Allocator, w: WorkloadSize, diffs: []const CellDiff) !i128 {
    var sync = try CellSync.init(allocator, 1, w.cols, w.rows);
    defer sync.deinit();
    const snapshot = cell_sync.FrameSnapshot{
        .gen = 1, .cols = w.cols, .rows = w.rows,
        .diffs = @constCast(diffs), .is_full = false, .source = 1,
    };
    var encode_arena = std.heap.ArenaAllocator.init(allocator);
    defer encode_arena.deinit();
    const syrup_val = try sync.snapshotToSyrup(&snapshot, encode_arena.allocator());

    const start = std.time.nanoTimestamp();
    var run: usize = 0;
    while (run < w.iters) : (run += 1) {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        _ = try CellSync.snapshotFromSyrup(arena.allocator(), syrup_val);
    }
    const end = std.time.nanoTimestamp();
    return @divFloor(end - start, @as(i128, w.iters));
}

fn benchApply(allocator: Allocator, w: WorkloadSize, diffs: []const CellDiff) !i128 {
    var sync = try CellSync.init(allocator, 1, w.cols, w.rows);
    defer sync.deinit();
    const snapshot = cell_sync.FrameSnapshot{
        .gen = 1, .cols = w.cols, .rows = w.rows,
        .diffs = @constCast(diffs), .is_full = false, .source = 2,
    };

    const start = std.time.nanoTimestamp();
    var run: usize = 0;
    while (run < w.iters) : (run += 1) {
        sync.applyRemote(&snapshot);
    }
    const end = std.time.nanoTimestamp();
    return @divFloor(end - start, @as(i128, w.iters));
}

/// Benchmark the zero-alloc fast path: syrup decode + apply in one pass.
/// This combines syrup↓ + apply into a single operation with no intermediate allocation.
fn benchFastPath(allocator: Allocator, w: WorkloadSize, diffs: []const CellDiff) !i128 {
    var sync_enc = try CellSync.init(allocator, 1, w.cols, w.rows);
    defer sync_enc.deinit();
    var sync_dec = try CellSync.init(allocator, 2, w.cols, w.rows);
    defer sync_dec.deinit();

    const snapshot = cell_sync.FrameSnapshot{
        .gen = 1, .cols = w.cols, .rows = w.rows,
        .diffs = @constCast(diffs), .is_full = false, .source = 1,
    };
    var encode_arena = std.heap.ArenaAllocator.init(allocator);
    defer encode_arena.deinit();
    const syrup_val = try sync_enc.snapshotToSyrup(&snapshot, encode_arena.allocator());

    const start = std.time.nanoTimestamp();
    var run: usize = 0;
    while (run < w.iters) : (run += 1) {
        _ = try sync_dec.applyFromSyrup(syrup_val);
    }
    const end = std.time.nanoTimestamp();
    return @divFloor(end - start, @as(i128, w.iters));
}

// ============================================================================
// VISUALIZATION HELPERS
// ============================================================================

fn formatNs(writer: anytype, ns: i128) !void {
    if (ns >= 1_000_000) {
        try writer.print("{d:.1}ms", .{@as(f64, @floatFromInt(ns)) / 1_000_000.0});
    } else if (ns >= 1_000) {
        try writer.print("{d:.1}\u{03bc}s", .{@as(f64, @floatFromInt(ns)) / 1_000.0});
    } else {
        try writer.print("{d}ns", .{ns});
    }
}

fn formatOps(writer: anytype, ops: i128) !void {
    if (ops >= 1_000_000) {
        try writer.print("{d:.1}M", .{@as(f64, @floatFromInt(ops)) / 1_000_000.0});
    } else if (ops >= 1_000) {
        try writer.print("{d:.1}K", .{@as(f64, @floatFromInt(ops)) / 1_000.0});
    } else {
        try writer.print("{d}", .{ops});
    }
}

fn formatBytes(writer: anytype, bytes: usize) !void {
    if (bytes >= 1024 * 1024) {
        try writer.print("{d:.1}MB", .{@as(f64, @floatFromInt(bytes)) / (1024.0 * 1024.0)});
    } else if (bytes >= 1024) {
        try writer.print("{d:.1}KB", .{@as(f64, @floatFromInt(bytes)) / 1024.0});
    } else {
        try writer.print("{d}B", .{bytes});
    }
}

fn hline(writer: anytype, n: usize) !void {
    for (0..n) |_| try writer.writeAll("\u{2500}");
}

fn sparkline(writer: anytype, values: []const f64, color: RGB) !void {
    var max: f64 = 0;
    for (values) |v| if (v > max) { max = v; };
    if (max == 0) max = 1;
    try color.fg(writer);
    for (values) |v| {
        const idx: usize = @min(7, @as(usize, @intFromFloat(v / max * 7.0)));
        try writer.writeAll(SPARK[idx]);
    }
    try writer.writeAll(RESET);
}

// ============================================================================
// VISUALIZATION: HIERARCHICAL FLAMEGRAPH
// ============================================================================

const Stage = struct {
    name: []const u8,
    ns: i128,
    color: RGB,
};

fn renderFlamegraph(writer: anytype, result: BenchResult) !void {
    const total = result.totalNs();
    if (total <= 0) return;

    // True pipeline stages (no double-counting):
    // commit → syrup_encode(includes pack) → syrup_decode(includes unpack) → apply
    const stages = [_]Stage{
        .{ .name = "commit", .ns = result.commit_ns, .color = COLOR_COMMIT },
        .{ .name = "syrup\u{2191}", .ns = result.syrup_encode_ns, .color = COLOR_PACK },
        .{ .name = "syrup\u{2193}", .ns = result.syrup_decode_ns, .color = COLOR_UNPACK },
        .{ .name = "apply", .ns = result.apply_ns, .color = COLOR_APPLY },
    };

    const W: usize = 72;

    // Top border with title
    try COLOR_BORDER.fg(writer);
    try writer.writeAll("  \u{250c}");
    try hline(writer, W);
    try writer.writeAll("\u{2510}\n");

    // Title
    try writer.writeAll("  \u{2502} ");
    try COLOR_TITLE.fg(writer);
    try writer.print("{s}{s}{s} ", .{ BOLD, result.workload.name, RESET });
    try COLOR_DIM.fg(writer);
    try writer.print("{d}\u{00d7}{d} ({d} diffs) ", .{ result.workload.cols, result.workload.rows, result.num_diffs });
    try COLOR_TITLE.fg(writer);
    try formatNs(writer, total);
    try writer.writeAll(" ");
    try COLOR_DIM.fg(writer);
    try writer.writeAll("(");
    try formatOps(writer, result.opsPerSec());
    try writer.writeAll(" ops/s)");
    try COLOR_BORDER.fg(writer);
    try writer.writeAll("\n");

    // Level 0: pipeline bar (true stages, no double-counting)
    try writer.writeAll("  \u{2502} ");
    for (stages) |stage| {
        const pct = @as(f64, @floatFromInt(stage.ns)) / @as(f64, @floatFromInt(total));
        const width: usize = @max(1, @as(usize, @intFromFloat(pct * @as(f64, @floatFromInt(W - 2)))));
        try stage.color.bg(writer);
        try writer.print("\x1b[30m", .{});
        if (width >= stage.name.len + 2) {
            const pad = (width - stage.name.len) / 2;
            for (0..pad) |_| try writer.writeAll(" ");
            try writer.writeAll(stage.name);
            for (0..width - stage.name.len - pad) |_| try writer.writeAll(" ");
        } else {
            for (0..width) |_| try writer.writeAll("\u{2588}");
        }
        try writer.writeAll(RESET);
    }
    try COLOR_BORDER.fg(writer);
    try writer.writeAll("\n");

    // Level 1: syrup breakdown — pack vs overhead within encode, unpack vs overhead within decode
    try writer.writeAll("  \u{2502} ");
    {
        // Commit portion (solid)
        const commit_pct = @as(f64, @floatFromInt(result.commit_ns)) / @as(f64, @floatFromInt(total));
        const commit_w: usize = @max(1, @as(usize, @intFromFloat(commit_pct * @as(f64, @floatFromInt(W - 2)))));
        try COLOR_COMMIT.bg(writer);
        try writer.writeAll("\x1b[30m");
        for (0..commit_w) |_| try writer.writeAll(" ");
        try writer.writeAll(RESET);

        // Syrup encode: pack portion + overhead portion
        const enc_total_w: usize = @max(1, @as(usize, @intFromFloat(
            @as(f64, @floatFromInt(result.syrup_encode_ns)) / @as(f64, @floatFromInt(total)) * @as(f64, @floatFromInt(W - 2)),
        )));
        const pack_frac = if (result.syrup_encode_ns > 0)
            @as(f64, @floatFromInt(result.pack_ns)) / @as(f64, @floatFromInt(result.syrup_encode_ns))
        else
            0.5;
        const pack_w: usize = @max(1, @as(usize, @intFromFloat(pack_frac * @as(f64, @floatFromInt(enc_total_w)))));
        const overhead_enc_w: usize = if (enc_total_w > pack_w) enc_total_w - pack_w else 0;

        try COLOR_PACK.bg(writer);
        try writer.writeAll("\x1b[30m");
        if (pack_w >= 6) {
            const pad = (pack_w - 4) / 2;
            for (0..pad) |_| try writer.writeAll(" ");
            try writer.writeAll("pack");
            for (0..pack_w - 4 - pad) |_| try writer.writeAll(" ");
        } else {
            for (0..pack_w) |_| try writer.writeAll("\u{2593}");
        }
        try writer.writeAll(RESET);
        if (overhead_enc_w > 0) {
            try COLOR_SYRUP_ENC.bg(writer);
            try writer.writeAll("\x1b[30m");
            if (overhead_enc_w >= 5) {
                const pad2 = (overhead_enc_w - 3) / 2;
                for (0..pad2) |_| try writer.writeAll(" ");
                try writer.writeAll("rec");
                for (0..overhead_enc_w - 3 - pad2) |_| try writer.writeAll(" ");
            } else {
                for (0..overhead_enc_w) |_| try writer.writeAll("\u{2591}");
            }
            try writer.writeAll(RESET);
        }

        // Syrup decode: unpack portion + overhead portion
        const dec_total_w_raw = @as(usize, @intFromFloat(
            @as(f64, @floatFromInt(result.syrup_decode_ns)) / @as(f64, @floatFromInt(total)) * @as(f64, @floatFromInt(W - 2)),
        ));
        const apply_w: usize = @max(1, @as(usize, @intFromFloat(
            @as(f64, @floatFromInt(result.apply_ns)) / @as(f64, @floatFromInt(total)) * @as(f64, @floatFromInt(W - 2)),
        )));
        const used = commit_w + enc_total_w + apply_w;
        const dec_total_w: usize = if (W - 2 > used) W - 2 - used else @max(1, dec_total_w_raw);

        const unpack_frac = if (result.syrup_decode_ns > 0)
            @as(f64, @floatFromInt(result.unpack_ns)) / @as(f64, @floatFromInt(result.syrup_decode_ns))
        else
            0.5;
        const unpack_w: usize = @max(1, @as(usize, @intFromFloat(unpack_frac * @as(f64, @floatFromInt(dec_total_w)))));
        const overhead_dec_w: usize = if (dec_total_w > unpack_w) dec_total_w - unpack_w else 0;

        try COLOR_UNPACK.bg(writer);
        try writer.writeAll("\x1b[30m");
        if (unpack_w >= 8) {
            const pad = (unpack_w - 6) / 2;
            for (0..pad) |_| try writer.writeAll(" ");
            try writer.writeAll("unpack");
            for (0..unpack_w - 6 - pad) |_| try writer.writeAll(" ");
        } else {
            for (0..unpack_w) |_| try writer.writeAll("\u{2593}");
        }
        try writer.writeAll(RESET);
        if (overhead_dec_w > 0) {
            try COLOR_SYRUP_DEC.bg(writer);
            try writer.writeAll("\x1b[30m");
            if (overhead_dec_w >= 5) {
                const pad2 = (overhead_dec_w - 3) / 2;
                for (0..pad2) |_| try writer.writeAll(" ");
                try writer.writeAll("rec");
                for (0..overhead_dec_w - 3 - pad2) |_| try writer.writeAll(" ");
            } else {
                for (0..overhead_dec_w) |_| try writer.writeAll("\u{2591}");
            }
            try writer.writeAll(RESET);
        }

        // Apply portion
        try COLOR_APPLY.bg(writer);
        try writer.writeAll("\x1b[30m");
        for (0..apply_w) |_| try writer.writeAll(" ");
        try writer.writeAll(RESET);
    }
    try COLOR_BORDER.fg(writer);
    try writer.writeAll("\n");

    // Percentage detail line
    try writer.writeAll("  \u{2502} ");
    for (stages) |stage| {
        const pct = @as(f64, @floatFromInt(stage.ns)) / @as(f64, @floatFromInt(total)) * 100.0;
        const width: usize = @max(1, @as(usize, @intFromFloat(
            @as(f64, @floatFromInt(stage.ns)) / @as(f64, @floatFromInt(total)) * @as(f64, @floatFromInt(W - 2)),
        )));
        try stage.color.fg(writer);
        if (width >= 5) {
            const pct_int: u32 = @intFromFloat(pct);
            const num_len: usize = if (pct_int >= 10) 4 else 3;
            const pad = (width - num_len) / 2;
            for (0..pad) |_| try writer.writeAll(" ");
            try writer.print("{d}%", .{pct_int});
            for (0..width - num_len - pad) |_| try writer.writeAll(" ");
        } else {
            for (0..width) |_| try writer.writeAll("\u{00b7}");
        }
    }
    try writer.writeAll(RESET);
    try COLOR_BORDER.fg(writer);
    try writer.writeAll("\n");

    // Wire efficiency + breakdown line
    try writer.writeAll("  \u{2502} ");
    try COLOR_DIM.fg(writer);
    try writer.print("wire: ", .{});
    try COLOR_PACK.fg(writer);
    try writer.print("{d:.1} B/cell", .{result.wireEfficiency()});
    try COLOR_DIM.fg(writer);
    try writer.writeAll("  syrup overhead: \u{2191}");
    try formatNs(writer, result.syrupOverheadEncode());
    try writer.writeAll(" \u{2193}");
    try formatNs(writer, result.syrupOverheadDecode());
    try writer.writeAll(RESET);
    try COLOR_BORDER.fg(writer);
    try writer.writeAll("\n");

    // Bottom border
    try writer.writeAll("  \u{2514}");
    try hline(writer, W);
    try writer.writeAll("\u{2518}");
    try writer.writeAll(RESET);
    try writer.writeAll("\n");
}

// ============================================================================
// VISUALIZATION: COMPRESSION TABLE
// ============================================================================

fn renderCompressionTable(writer: anytype, results: []const BenchResult) !void {
    try writer.writeAll("\n");
    try COLOR_TITLE.fg(writer);
    try writer.print("  {s}\u{2550}\u{2550}\u{2550} COMPRESSION \u{2550}\u{2550}\u{2550}{s}\n", .{ BOLD, RESET });

    // Find best ratio
    var best_ratio: f64 = 0;
    var best_idx: usize = 0;
    for (results, 0..) |r, i| {
        const ratio = if (r.compressed_bytes > 0)
            @as(f64, @floatFromInt(r.raw_bytes)) / @as(f64, @floatFromInt(r.compressed_bytes))
        else 0;
        if (ratio > best_ratio) { best_ratio = ratio; best_idx = i; }
    }

    for (results, 0..) |r, i| {
        const ratio = if (r.compressed_bytes > 0)
            @as(f64, @floatFromInt(r.raw_bytes)) / @as(f64, @floatFromInt(r.compressed_bytes))
        else 0;
        const savings = if (r.raw_bytes > 0)
            (1.0 - @as(f64, @floatFromInt(r.compressed_bytes)) / @as(f64, @floatFromInt(r.raw_bytes))) * 100.0
        else 0;

        try COLOR_LABEL.fg(writer);
        try writer.print("  {s: <6}", .{r.workload.name});
        try COLOR_COMMIT.fg(writer);
        try formatBytes(writer, r.raw_bytes);
        try COLOR_DIM.fg(writer);
        try writer.writeAll(" \u{2192} ");
        try COLOR_PACK.fg(writer);
        try formatBytes(writer, r.compressed_bytes);
        try writer.writeAll("  ");

        // Compression bar
        const bar_w: usize = 20;
        const fill: usize = @min(bar_w, @as(usize, @intFromFloat(savings / 100.0 * @as(f64, @floatFromInt(bar_w)))));
        try COLOR_GOOD.fg(writer);
        for (0..fill) |_| try writer.writeAll("\u{2588}");
        try COLOR_DIM.fg(writer);
        for (0..bar_w - fill) |_| try writer.writeAll("\u{2591}");
        try writer.writeAll(RESET);

        try COLOR_APPLY.fg(writer);
        try writer.print(" {d:.1}x", .{ratio});
        if (i == best_idx) {
            try COLOR_GOOD.fg(writer);
            try writer.writeAll(" \u{2605}");
        }
        try writer.writeAll(RESET);
        try writer.writeAll("\n");
    }
}

// ============================================================================
// VISUALIZATION: THROUGHPUT + SPARKLINES
// ============================================================================

fn renderThroughput(writer: anytype, results: []const BenchResult) !void {
    try writer.writeAll("\n");
    try COLOR_TITLE.fg(writer);
    try writer.print("  {s}\u{2550}\u{2550}\u{2550} THROUGHPUT \u{2550}\u{2550}\u{2550}{s}\n\n", .{ BOLD, RESET });

    var max_ops: i128 = 0;
    var max_cells: i128 = 0;
    for (results) |r| {
        const ops = r.opsPerSec();
        const cells = r.cellsPerSec();
        if (ops > max_ops) max_ops = ops;
        if (cells > max_cells) max_cells = cells;
    }
    if (max_ops == 0) max_ops = 1;

    const bar_max: usize = 35;

    for (results) |r| {
        const ops = r.opsPerSec();
        const bar_len: usize = @intFromFloat(
            @as(f64, @floatFromInt(ops)) / @as(f64, @floatFromInt(max_ops)) * @as(f64, @floatFromInt(bar_max)),
        );
        const ratio = @as(f64, @floatFromInt(ops)) / @as(f64, @floatFromInt(max_ops));
        const bar_color = RGB.lerp(COLOR_BAD, COLOR_GOOD, ratio);

        try COLOR_LABEL.fg(writer);
        try writer.print("  {s: <6}", .{r.workload.name});
        try bar_color.fg(writer);
        for (0..bar_len) |_| try writer.writeAll("\u{2588}");
        try COLOR_DIM.fg(writer);
        for (0..bar_max - bar_len) |_| try writer.writeAll("\u{2591}");
        try writer.writeAll(" ");
        try COLOR_APPLY.fg(writer);
        try formatOps(writer, ops);
        try writer.writeAll("/s ");
        try COLOR_DIM.fg(writer);
        try writer.writeAll("(");
        try formatOps(writer, r.cellsPerSec());
        try writer.writeAll(" cells/s)");
        try writer.writeAll(RESET);
        try writer.writeAll("\n");
    }
}

// ============================================================================
// VISUALIZATION: PER-CELL COST TABLE WITH SPARKLINES
// ============================================================================

fn renderPerCellTable(writer: anytype, results: []const BenchResult) !void {
    try writer.writeAll("\n");
    try COLOR_TITLE.fg(writer);
    try writer.print("  {s}\u{2550}\u{2550}\u{2550} PER-CELL COST (ns/cell) \u{2550}\u{2550}\u{2550}{s}\n\n", .{ BOLD, RESET });

    // Header
    try COLOR_LABEL.fg(writer);
    try writer.print("  {s: <10}", .{"Stage"});
    for (results) |r| try writer.print("{s: >8}", .{r.workload.name});
    try writer.writeAll("  trend");
    try writer.writeAll(RESET);
    try writer.writeAll("\n");

    try writer.writeAll("  ");
    try COLOR_BORDER.fg(writer);
    try hline(writer, 10 + results.len * 8 + 8);
    try writer.writeAll(RESET);
    try writer.writeAll("\n");

    const stage_names = [_][]const u8{ "commit", "syrup\u{2191}", "  \u{2514}pack", "syrup\u{2193}", "  \u{2514}unpack", "apply" };
    const stage_colors = [_]RGB{ COLOR_COMMIT, COLOR_PACK, COLOR_DIM, COLOR_UNPACK, COLOR_DIM, COLOR_APPLY };

    for (stage_names, stage_colors) |name, color| {
        try color.fg(writer);
        try writer.print("  {s: <10}", .{name});

        var spark_vals: [WORKLOADS.len]f64 = undefined;
        var spark_count: usize = 0;

        for (results) |r| {
            const cells = r.num_diffs;
            if (cells == 0) {
                try writer.print("{s: >8}", .{"-"});
                continue;
            }
            const ns = getNsForStage(name, r);
            const per_cell = @as(f64, @floatFromInt(ns)) / @as(f64, @floatFromInt(cells));
            if (per_cell >= 100) {
                try writer.print("{d: >7.0} ", .{per_cell});
            } else if (per_cell >= 10) {
                try writer.print("{d: >7.1} ", .{per_cell});
            } else {
                try writer.print("{d: >7.2} ", .{per_cell});
            }
            if (spark_count < WORKLOADS.len) {
                spark_vals[spark_count] = per_cell;
                spark_count += 1;
            }
        }

        // Sparkline trend
        try writer.writeAll(" ");
        if (spark_count > 0) {
            try sparkline(writer, spark_vals[0..spark_count], color);
        }
        try writer.writeAll(RESET);
        try writer.writeAll("\n");
    }

    // Total row
    try writer.writeAll("  ");
    try COLOR_BORDER.fg(writer);
    try hline(writer, 10 + results.len * 8 + 8);
    try writer.writeAll(RESET);
    try writer.writeAll("\n");

    try COLOR_TITLE.fg(writer);
    try writer.print("{s}  {s: <10}", .{ BOLD, "TOTAL" });
    var total_sparks: [WORKLOADS.len]f64 = undefined;
    var total_count: usize = 0;
    for (results) |r| {
        const cells = r.num_diffs;
        if (cells == 0) { try writer.print("{s: >8}", .{"-"}); continue; }
        const per_cell = @as(f64, @floatFromInt(r.totalNs())) / @as(f64, @floatFromInt(cells));
        if (per_cell >= 100) {
            try writer.print("{d: >7.0} ", .{per_cell});
        } else if (per_cell >= 10) {
            try writer.print("{d: >7.1} ", .{per_cell});
        } else {
            try writer.print("{d: >7.2} ", .{per_cell});
        }
        if (total_count < WORKLOADS.len) {
            total_sparks[total_count] = per_cell;
            total_count += 1;
        }
    }
    try writer.writeAll(" ");
    try sparkline(writer, total_sparks[0..total_count], COLOR_TITLE);
    try writer.writeAll(RESET);
    try writer.writeAll("\n");
}

fn getNsForStage(name: []const u8, r: BenchResult) i128 {
    if (std.mem.eql(u8, name, "commit")) return r.commit_ns;
    if (std.mem.eql(u8, name, "syrup\u{2191}")) return r.syrup_encode_ns;
    if (std.mem.endsWith(u8, name, "unpack")) return r.unpack_ns;
    if (std.mem.endsWith(u8, name, "pack")) return r.pack_ns;
    if (std.mem.eql(u8, name, "syrup\u{2193}")) return r.syrup_decode_ns;
    if (std.mem.eql(u8, name, "apply")) return r.apply_ns;
    return 0;
}

// ============================================================================
// VISUALIZATION: FAST PATH COMPARISON
// ============================================================================

fn renderFastPathComparison(writer: anytype, results: []const BenchResult) !void {
    try writer.writeAll("\n");
    try COLOR_TITLE.fg(writer);
    try writer.print("  {s}\u{2550}\u{2550}\u{2550} ZERO-ALLOC FAST PATH \u{2550}\u{2550}\u{2550}{s}\n", .{ BOLD, RESET });
    try COLOR_DIM.fg(writer);
    try writer.writeAll("  applyFromSyrup: decode + apply in one pass, no intermediate []CellDiff\n\n");
    try writer.writeAll(RESET);

    try COLOR_LABEL.fg(writer);
    try writer.print("  {s: <8}{s: >12}{s: >12}{s: >10}{s: >14}\n", .{
        "Size", "standard", "fast path", "speedup", "cells/sec",
    });
    try COLOR_BORDER.fg(writer);
    try writer.writeAll("  ");
    try hline(writer, 56);
    try writer.writeAll(RESET);
    try writer.writeAll("\n");

    for (results) |r| {
        const std_decode = r.syrup_decode_ns + r.apply_ns;
        const fast = r.fast_path_ns;
        const speedup = if (fast > 0)
            @as(f64, @floatFromInt(std_decode)) / @as(f64, @floatFromInt(fast))
        else
            0;

        try COLOR_LABEL.fg(writer);
        try writer.print("  {s: <8}", .{r.workload.name});

        // Standard path
        try COLOR_DIM.fg(writer);
        try writer.print("  ", .{});
        try formatNs(writer, std_decode);

        // Fast path
        try writer.print("      ", .{});
        try COLOR_GOOD.fg(writer);
        try formatNs(writer, fast);

        // Speedup
        if (speedup > 1.0) {
            try COLOR_GOOD.fg(writer);
        } else {
            try COLOR_DIM.fg(writer);
        }
        try writer.print("    {d:.2}x", .{speedup});

        // Cells/sec with fast path pipeline
        try COLOR_DIM.fg(writer);
        try writer.print("     ", .{});
        try COLOR_APPLY.fg(writer);
        try formatOps(writer, r.fastCellsPerSec());
        try writer.writeAll("/s");

        try writer.writeAll(RESET);
        try writer.writeAll("\n");
    }

    // Summary line
    if (results.len > 0) {
        const r = results[results.len - 1]; // largest workload
        try writer.writeAll("\n  ");
        try COLOR_DIM.fg(writer);
        try writer.writeAll("Fast pipeline (commit\u{2192}syrup\u{2191}\u{2192}applyFromSyrup): ");
        try COLOR_TITLE.fg(writer);
        try writer.print("{s}", .{BOLD});
        try formatNs(writer, r.totalFastNs());
        try writer.writeAll(RESET);
        try COLOR_DIM.fg(writer);
        try writer.writeAll(" total, ");
        try COLOR_GOOD.fg(writer);
        const fast_ns_cell = @as(f64, @floatFromInt(r.totalFastNs())) / @as(f64, @floatFromInt(r.num_diffs));
        try writer.print("{d:.1} ns/cell", .{fast_ns_cell});
        try writer.writeAll(RESET);
        try writer.writeAll("\n");
    }
}

// ============================================================================
// VISUALIZATION: SCALING EFFICIENCY
// ============================================================================

fn renderScalingAnalysis(writer: anytype, results: []const BenchResult) !void {
    if (results.len < 2) return;

    try writer.writeAll("\n");
    try COLOR_TITLE.fg(writer);
    try writer.print("  {s}\u{2550}\u{2550}\u{2550} SCALING EFFICIENCY \u{2550}\u{2550}\u{2550}{s}\n\n", .{ BOLD, RESET });

    // Compare each pair: how does cost scale as cells increase?
    try COLOR_DIM.fg(writer);
    try writer.writeAll("  ");
    try writer.print("{s: <14}{s: >10}{s: >10}{s: >12}{s: >10}\n", .{
        "Transition", "cells\u{00d7}", "time\u{00d7}", "efficiency", "ns/cell\u{0394}",
    });
    try writer.writeAll("  ");
    try COLOR_BORDER.fg(writer);
    try hline(writer, 56);
    try writer.writeAll(RESET);
    try writer.writeAll("\n");

    for (0..results.len - 1) |i| {
        const a = results[i];
        const b = results[i + 1];
        if (a.totalNs() == 0 or a.num_diffs == 0) continue;

        const cells_ratio = @as(f64, @floatFromInt(b.num_diffs)) / @as(f64, @floatFromInt(a.num_diffs));
        const time_ratio = @as(f64, @floatFromInt(b.totalNs())) / @as(f64, @floatFromInt(a.totalNs()));
        const efficiency = cells_ratio / time_ratio; // >1 = sublinear scaling (good)
        const ns_a = @as(f64, @floatFromInt(a.totalNs())) / @as(f64, @floatFromInt(a.num_diffs));
        const ns_b = @as(f64, @floatFromInt(b.totalNs())) / @as(f64, @floatFromInt(b.num_diffs));
        const delta = ns_b - ns_a;

        try COLOR_LABEL.fg(writer);
        try writer.print("  {s: <6}\u{2192}{s: <6}", .{ a.workload.name, b.workload.name });

        try COLOR_DIM.fg(writer);
        try writer.print("{d: >8.0}x", .{cells_ratio});
        try writer.print("{d: >8.1}x", .{time_ratio});

        // Efficiency coloring
        if (efficiency > 1.5) {
            try COLOR_GOOD.fg(writer);
        } else if (efficiency > 0.8) {
            try COLOR_APPLY.fg(writer);
        } else {
            try COLOR_BAD.fg(writer);
        }
        try writer.print("{d: >10.1}x", .{efficiency});

        // Delta coloring (negative = improvement)
        if (delta < 0) {
            try COLOR_GOOD.fg(writer);
            try writer.print("{d: >9.1}", .{delta});
        } else {
            try COLOR_BAD.fg(writer);
            try writer.print("{d: >8.1}", .{delta});
        }
        try writer.writeAll(RESET);
        try writer.writeAll("\n");
    }
}

// ============================================================================
// VISUALIZATION: FRAME BUDGET
// ============================================================================

fn renderFrameBudget(writer: anytype, results: []const BenchResult) !void {
    try writer.writeAll("\n");
    try COLOR_TITLE.fg(writer);
    try writer.print("  {s}\u{2550}\u{2550}\u{2550} FRAME BUDGET \u{2550}\u{2550}\u{2550}{s}\n\n", .{ BOLD, RESET });

    // Budget thresholds in nanoseconds
    const budget_60fps: f64 = 16_600_000.0; // 16.6ms
    const budget_30fps: f64 = 33_300_000.0; // 33.3ms

    try COLOR_LABEL.fg(writer);
    try writer.print("  {s: <10}{s: >10}   {s: <22}{s: <22}\n", .{
        "Size", "pipeline", "@60fps (16.6ms)", "@30fps (33.3ms)",
    });
    try COLOR_BORDER.fg(writer);
    try writer.writeAll("  ");
    try hline(writer, 66);
    try writer.writeAll(RESET);
    try writer.writeAll("\n");

    for (results) |r| {
        const pipeline_ns = r.totalFastNs();
        const pipeline_f: f64 = @floatFromInt(pipeline_ns);

        const frames_60 = budget_60fps / pipeline_f;
        const frames_30 = budget_30fps / pipeline_f;

        try COLOR_LABEL.fg(writer);
        try writer.print("  {s: <10}", .{r.workload.name});

        // Pipeline time
        try COLOR_DIM.fg(writer);
        try formatNs(writer, pipeline_ns);

        // @60fps bar + count
        try writer.writeAll("   ");
        const bar_max: usize = 16;
        const fill_60: usize = @min(bar_max, @as(usize, @intFromFloat(@min(frames_60, @as(f64, @floatFromInt(bar_max))))));
        if (frames_60 >= 1.0) {
            try COLOR_GOOD.fg(writer);
        } else {
            try COLOR_BAD.fg(writer);
        }
        for (0..fill_60) |_| try writer.writeAll("\u{2588}");
        try COLOR_DIM.fg(writer);
        for (0..bar_max - fill_60) |_| try writer.writeAll("\u{2591}");
        try writer.writeAll(" ");
        if (frames_60 >= 1.0) {
            try COLOR_GOOD.fg(writer);
        } else {
            try COLOR_BAD.fg(writer);
        }
        try writer.print("{d:.0}", .{frames_60});

        // @30fps bar + count
        try writer.writeAll("   ");
        const fill_30: usize = @min(bar_max, @as(usize, @intFromFloat(@min(frames_30, @as(f64, @floatFromInt(bar_max))))));
        if (frames_30 >= 1.0) {
            try COLOR_GOOD.fg(writer);
        } else {
            try COLOR_BAD.fg(writer);
        }
        for (0..fill_30) |_| try writer.writeAll("\u{2588}");
        try COLOR_DIM.fg(writer);
        for (0..bar_max - fill_30) |_| try writer.writeAll("\u{2591}");
        try writer.writeAll(" ");
        if (frames_30 >= 1.0) {
            try COLOR_GOOD.fg(writer);
        } else {
            try COLOR_BAD.fg(writer);
        }
        try writer.print("{d:.0}", .{frames_30});

        try writer.writeAll(RESET);
        try writer.writeAll("\n");
    }
}

// ============================================================================
// MAIN
// ============================================================================

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var out_buf: [512 * 1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&out_buf);
    const stdout = fbs.writer();

    // Header
    try stdout.writeAll(RESET);
    try COLOR_TITLE.fg(stdout);
    try stdout.print("\n  {s}\u{2550}\u{2550}\u{2550} CELL SYNC BENCHMARK \u{2550}\u{2550}\u{2550}{s}\n", .{ BOLD, RESET });
    try COLOR_DIM.fg(stdout);
    try stdout.writeAll("  Quantum circuit workloads \u{2502} Packed binary + RLE \u{2502} Syrup transport\n");
    try stdout.writeAll(RESET);

    var all_results: [WORKLOADS.len]BenchResult = undefined;

    for (WORKLOADS, 0..) |w, i| {
        try stdout.writeAll("\n");

        const commit_result = try benchCommit(allocator, w);
        defer allocator.free(commit_result.diffs);
        const pack_result = try benchPack(allocator, commit_result.diffs, w.iters);
        const unpack_result = try benchUnpack(allocator, commit_result.diffs, w.iters);
        const syrup_enc_ns = try benchSyrupEncode(allocator, w, commit_result.diffs);
        const syrup_dec_ns = try benchSyrupDecode(allocator, w, commit_result.diffs);
        const apply_ns = try benchApply(allocator, w, commit_result.diffs);
        const fast_path_ns = try benchFastPath(allocator, w, commit_result.diffs);

        const result = BenchResult{
            .workload = w,
            .commit_ns = commit_result.ns,
            .pack_ns = pack_result.ns,
            .unpack_ns = unpack_result.ns,
            .syrup_encode_ns = syrup_enc_ns,
            .syrup_decode_ns = syrup_dec_ns,
            .apply_ns = apply_ns,
            .fast_path_ns = fast_path_ns,
            .raw_bytes = commit_result.diffs.len * 14,
            .compressed_bytes = pack_result.compressed_bytes,
            .num_diffs = commit_result.diffs.len,
            .pack_allocs = pack_result.allocs,
            .unpack_allocs = unpack_result.allocs,
        };

        all_results[i] = result;
        try renderFlamegraph(stdout, result);
    }

    try renderCompressionTable(stdout, &all_results);
    try renderThroughput(stdout, &all_results);
    try renderPerCellTable(stdout, &all_results);
    try renderFastPathComparison(stdout, &all_results);
    try renderScalingAnalysis(stdout, &all_results);
    try renderFrameBudget(stdout, &all_results);

    try stdout.writeAll("\n  ");
    try COLOR_TITLE.fg(stdout);
    try stdout.print("{s}\u{2550}\u{2550}\u{2550} done \u{2550}\u{2550}\u{2550}{s}\n\n", .{ BOLD, RESET });

    _ = try std.posix.write(std.posix.STDOUT_FILENO, fbs.getWritten());
}
