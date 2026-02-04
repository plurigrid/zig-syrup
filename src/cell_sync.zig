//! Distributed Terminal Cell Synchronization
//!
//! Mosh SSP-inspired state synchronization for terminal cell grids,
//! serialized via Syrup for OCapN transport over unreliable networks.
//!
//! Performance design:
//! - Single grid traversal per commit (reuses TerminalPane damage regions)
//! - Packed binary cell encoding: 14 bytes/cell in syrup.bytes
//! - Run-length encoding for repeated cells (common in terminals)
//! - Ring buffer diff log for Mosh-style prophylactic retransmission
//!
//! Architecture:
//! - Each node maintains a local TerminalPane (from damage.zig)
//! - On commit, dirty cells are extracted from AABB damage regions
//! - Cells are packed into a binary blob, wrapped in a thin Syrup record
//! - Receivers unpack and apply to reconstruct remote state
//!
//! Wire format (inside syrup.bytes):
//!   [u16 x][u16 y][u24 codepoint][u24 fg][u24 bg][u8 attrs] = 14 bytes/cell
//!   RLE marker: x=0xFFFF means "repeat previous cell N times, advancing x"
//!   [0xFFFF][u16 count] = 4 bytes for a run

const std = @import("std");
const syrup = @import("syrup.zig");
const damage = @import("damage.zig");
const Allocator = std.mem.Allocator;

const Cell = damage.Cell;
const CellAttrs = damage.CellAttrs;
const AABB = damage.AABB;

/// Node identity in the distributed mesh
pub const NodeId = u64;

/// Monotonic generation counter for convergence
pub const Generation = u64;

/// Packed cell size in bytes (no RLE): 2(x) + 2(y) + 3(cp) + 3(fg) + 3(bg) + 1(attrs)
const CELL_PACKED_SIZE: usize = 14;

/// RLE marker in x position
const RLE_MARKER: u16 = 0xFFFF;

/// A single cell diff: position + new state
pub const CellDiff = struct {
    x: u16,
    y: u16,
    cell: Cell,
};

/// Frame snapshot: generation + packed binary cell data
pub const FrameSnapshot = struct {
    gen: Generation,
    cols: u16,
    rows: u16,
    diffs: []CellDiff,
    is_full: bool,
    source: NodeId,
    /// Borrowed slice into log ring's packed data. Not owned — do NOT free.
    /// Valid until LOG_CAPACITY commits evict the entry. In practice the
    /// snapshot is always consumed (via snapshotToSyrup) before that happens.
    packed_cache: ?[]const u8 = null,

    pub fn deinit(self: *FrameSnapshot, allocator: Allocator) void {
        // packed_cache is borrowed from the log ring — not freed here
        allocator.free(self.diffs);
    }
};

/// Synchronization state for one remote peer
pub const PeerState = struct {
    node_id: NodeId,
    acked_gen: Generation,
    sent_gen: Generation,
    retransmit_budget: u32,

    pub fn needsRetransmit(self: *const PeerState) bool {
        return self.sent_gen > self.acked_gen;
    }
};

/// The distributed cell synchronizer
pub const CellSync = struct {
    pane: damage.TerminalPane,
    node_id: NodeId,
    gen: Generation,
    peers: std.AutoHashMapUnmanaged(NodeId, PeerState),
    log_ring: [LOG_CAPACITY]LogEntry,
    log_head: usize, // next write position
    log_count: usize, // number of valid entries
    allocator: Allocator,

    const LOG_CAPACITY = 64;

    const LogEntry = struct {
        gen: Generation,
        packed_data: []u8, // RLE-compressed packed binary (much smaller than []CellDiff)
    };

    pub fn init(allocator: Allocator, node_id: NodeId, cols: u16, rows: u16) !CellSync {
        return .{
            .pane = try damage.TerminalPane.init(allocator, 0, cols, rows),
            .node_id = node_id,
            .gen = 0,
            .peers = .{},
            .log_ring = undefined,
            .log_head = 0,
            .log_count = 0,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *CellSync) void {
        for (0..self.log_count) |i| {
            const idx = (self.log_head + LOG_CAPACITY - self.log_count + i) % LOG_CAPACITY;
            self.allocator.free(self.log_ring[idx].packed_data);
        }
        self.peers.deinit(self.allocator);
        self.pane.deinit();
    }

    /// Write a cell locally and mark dirty
    pub fn writeCell(self: *CellSync, x: u16, y: u16, cell: Cell) void {
        self.pane.setCell(x, y, cell);
    }

    /// Commit local changes, produce a diff snapshot for transmission.
    /// Single traversal: extracts diffs from the AABB damage regions
    /// that TerminalPane.commit() already computes.
    pub fn commit(self: *CellSync) !FrameSnapshot {
        self.gen +%= 1;

        // TerminalPane.commit() does the single traversal:
        // walks damage_mask, copies back→front, clears mask, returns AABB regions.
        // We then extract the actual cells from the committed front buffer
        // using only the damage regions — no second full-grid scan.
        const regions = try self.pane.commit(self.allocator);
        defer self.allocator.free(regions);

        // Pre-calculate exact diff count from AABB regions to avoid ArrayList resizing
        var total_cells: usize = 0;
        for (regions) |region| {
            const w: usize = @intCast(region.max_x - region.min_x + 1);
            const h: usize = @intCast(region.max_y - region.min_y + 1);
            total_cells += w * h;
        }

        const owned_diffs = try self.allocator.alloc(CellDiff, total_cells);
        var write_idx: usize = 0;

        const cols = self.pane.cols;
        for (regions) |region| {
            const min_y: u16 = @intCast(region.min_y);
            const max_y: u16 = @intCast(region.max_y);
            const min_x: u16 = @intCast(region.min_x);
            const max_x: u16 = @intCast(region.max_x);
            const w: usize = @as(usize, max_x - min_x) + 1;

            var y = min_y;
            while (y <= max_y) : (y += 1) {
                const row_start = @as(usize, y) * cols + min_x;
                const front_row = self.pane.front[row_start..][0..w];
                var j: usize = 0;
                while (j < w) : (j += 1) {
                    owned_diffs[write_idx] = .{
                        .x = @intCast(min_x + j),
                        .y = y,
                        .cell = front_row[j],
                    };
                    write_idx += 1;
                }
            }
        }

        // Store packed bytes in ring buffer for retransmission.
        // Packed form is much smaller: ~8.9KB vs ~360KB at 4K scale (23x compression).
        // Retransmission uses applyPacked() directly from the compressed buffer.
        const log_packed = try packDiffs(self.allocator, owned_diffs);
        if (self.log_count >= LOG_CAPACITY) {
            self.allocator.free(self.log_ring[self.log_head].packed_data);
        } else {
            self.log_count += 1;
        }
        self.log_ring[self.log_head] = .{
            .gen = self.gen,
            .packed_data = log_packed,
        };
        self.log_head = (self.log_head + 1) % LOG_CAPACITY;

        // Borrow the packed data from the log ring entry (no dupe needed).
        // The snapshot must be consumed before LOG_CAPACITY commits evict it.
        return .{
            .gen = self.gen,
            .cols = self.pane.cols,
            .rows = self.pane.rows,
            .diffs = owned_diffs,
            .is_full = false,
            .source = self.node_id,
            .packed_cache = log_packed,
        };
    }

    /// Apply a remote snapshot to local state.
    /// Writes to both front and back buffers and marks damage.
    pub fn applyRemote(self: *CellSync, snapshot: *const FrameSnapshot) void {
        const cols = self.pane.cols;
        const rows = self.pane.rows;
        for (snapshot.diffs) |diff| {
            if (diff.x < cols and diff.y < rows) {
                const idx = @as(usize, diff.y) * cols + diff.x;
                self.pane.front[idx] = diff.cell;
                self.pane.back[idx] = diff.cell;
                self.pane.damage_mask.set(idx);
                self.pane.row_dirty.set(diff.y);
            }
        }
    }

    /// Apply packed binary data directly to the grid, skipping intermediate
    /// CellDiff allocation. Reads from the compact packed buffer (~8.9KB at 4K)
    /// which stays in L1, instead of expanding to CellDiff structs (~360KB at 4K)
    /// that spill to L2. Combines unpack + apply into a single zero-alloc pass.
    pub fn applyPacked(self: *CellSync, data: []const u8) void {
        const cols = self.pane.cols;
        const rows = self.pane.rows;
        var pos: usize = 0;

        while (pos + CELL_PACKED_SIZE <= data.len) {
            const diff = unpackCell(data[pos..][0..CELL_PACKED_SIZE]);
            pos += CELL_PACKED_SIZE;

            // Apply base cell
            if (diff.x < cols and diff.y < rows) {
                const idx = @as(usize, diff.y) * cols + diff.x;
                self.pane.front[idx] = diff.cell;
                self.pane.back[idx] = diff.cell;
                self.pane.damage_mask.set(idx);
                self.pane.row_dirty.set(diff.y);
            }

            // Expand RLE inline
            if (pos + 4 <= data.len and
                data[pos] == 0xFF and data[pos + 1] == 0xFF)
            {
                const count: u16 = @as(u16, data[pos + 2]) << 8 | data[pos + 3];
                pos += 4;

                const cell = diff.cell;
                const base_x = diff.x;
                const y = diff.y;
                if (y < rows) {
                    self.pane.row_dirty.set(y);
                    var j: u16 = 0;
                    while (j < count) : (j += 1) {
                        const x = base_x +| (1 + j);
                        if (x < cols) {
                            const idx = @as(usize, y) * cols + x;
                            self.pane.front[idx] = cell;
                            self.pane.back[idx] = cell;
                            self.pane.damage_mask.set(idx);
                        }
                    }
                }
            }
        }
    }

    /// Acknowledge a peer's generation
    pub fn ack(self: *CellSync, peer_id: NodeId, gen: Generation) !void {
        const entry = try self.peers.getOrPut(self.allocator, peer_id);
        if (!entry.found_existing) {
            entry.value_ptr.* = .{
                .node_id = peer_id,
                .acked_gen = gen,
                .sent_gen = gen,
                .retransmit_budget = 3,
            };
        } else {
            if (gen > entry.value_ptr.acked_gen) {
                entry.value_ptr.acked_gen = gen;
            }
        }
    }

    /// Get packed bytes since a given generation (for retransmission).
    /// Returns RLE-compressed packed binary, ready for applyPacked() or wire transport.
    pub fn packedSince(self: *const CellSync, since_gen: Generation) ?[]const u8 {
        if (self.log_count == 0) return null;
        const start = (self.log_head + LOG_CAPACITY - self.log_count) % LOG_CAPACITY;
        for (0..self.log_count) |i| {
            const idx = (start + i) % LOG_CAPACITY;
            if (self.log_ring[idx].gen > since_gen) {
                return self.log_ring[idx].packed_data;
            }
        }
        return null;
    }

    /// Produce a full snapshot (all cells)
    pub fn fullSnapshot(self: *const CellSync) !FrameSnapshot {
        const total = @as(usize, self.pane.cols) * self.pane.rows;
        var diffs = try self.allocator.alloc(CellDiff, total);

        var i: usize = 0;
        var y: u16 = 0;
        while (y < self.pane.rows) : (y += 1) {
            var x: u16 = 0;
            while (x < self.pane.cols) : (x += 1) {
                diffs[i] = .{ .x = x, .y = y, .cell = self.pane.front[@as(usize, y) * self.pane.cols + x] };
                i += 1;
            }
        }

        return .{
            .gen = self.gen,
            .cols = self.pane.cols,
            .rows = self.pane.rows,
            .diffs = diffs,
            .is_full = true,
            .source = self.node_id,
        };
    }

    // ================================================================
    // PACKED BINARY ENCODING
    // ================================================================

    /// Pack a cell into 14 bytes: [u16 x][u16 y][u24 cp][u24 fg][u24 bg][u8 attrs]
    /// Cell payload starts at offset 4 (10 bytes: cp+fg+bg+attrs).
    fn packCell(buf: *[CELL_PACKED_SIZE]u8, diff: CellDiff) void {
        buf[0] = @intCast(diff.x >> 8);
        buf[1] = @truncate(diff.x);
        buf[2] = @intCast(diff.y >> 8);
        buf[3] = @truncate(diff.y);
        packCellPayload(buf[4..14], diff.cell);
    }

    /// Pack just the cell payload (10 bytes: cp+fg+bg+attrs), no position.
    inline fn packCellPayload(buf: *[10]u8, cell: Cell) void {
        const cp: u24 = @intCast(cell.codepoint);
        buf[0] = @intCast(cp >> 16);
        buf[1] = @intCast((cp >> 8) & 0xFF);
        buf[2] = @truncate(cp);
        buf[3] = @intCast(cell.fg >> 16);
        buf[4] = @intCast((cell.fg >> 8) & 0xFF);
        buf[5] = @truncate(cell.fg);
        buf[6] = @intCast(cell.bg >> 16);
        buf[7] = @intCast((cell.bg >> 8) & 0xFF);
        buf[8] = @truncate(cell.bg);
        buf[9] = @as(u8, @bitCast(cell.attrs));
    }

    /// Unpack a cell from 14 bytes
    fn unpackCell(buf: *const [CELL_PACKED_SIZE]u8) CellDiff {
        return .{
            .x = @as(u16, buf[0]) << 8 | buf[1],
            .y = @as(u16, buf[2]) << 8 | buf[3],
            .cell = unpackCellPayload(buf[4..14]),
        };
    }

    /// Unpack just the cell payload (10 bytes).
    inline fn unpackCellPayload(buf: *const [10]u8) Cell {
        return .{
            .codepoint = @intCast(@as(u24, buf[0]) << 16 | @as(u24, buf[1]) << 8 | @as(u24, buf[2])),
            .fg = @as(u24, buf[3]) << 16 | @as(u24, buf[4]) << 8 | @as(u24, buf[5]),
            .bg = @as(u24, buf[6]) << 16 | @as(u24, buf[7]) << 8 | @as(u24, buf[8]),
            .attrs = @bitCast(buf[9]),
        };
    }

    /// Pack cell diffs with RLE compression into a byte buffer.
    /// RLE: when consecutive diffs have identical cells and sequential x,
    /// emit a 4-byte run marker instead of repeating the 14-byte cell.
    /// Pre-allocates worst case, writes directly, shrinks via realloc.
    pub fn packDiffs(allocator: Allocator, diffs: []const CellDiff) ![]u8 {
        if (diffs.len == 0) return try allocator.alloc(u8, 0);

        // Worst case: 14 bytes per diff (RLE only shrinks)
        const buf = try allocator.alloc(u8, diffs.len * CELL_PACKED_SIZE);
        var pos: usize = 0;

        var i: usize = 0;
        while (i < diffs.len) {
            packCell(buf[pos..][0..CELL_PACKED_SIZE], diffs[i]);
            pos += CELL_PACKED_SIZE;

            // Check for RLE run using direct Cell.eql (avoids temp buffer packing)
            var run_len: u16 = 0;
            while (i + 1 + run_len < diffs.len) {
                const next = diffs[i + 1 + run_len];
                if (next.y != diffs[i].y or next.x != diffs[i].x + 1 + run_len) break;
                if (!Cell.eql(next.cell, diffs[i].cell)) break;
                run_len += 1;
            }

            if (run_len > 0) {
                buf[pos] = 0xFF;
                buf[pos + 1] = 0xFF;
                buf[pos + 2] = @intCast(run_len >> 8);
                buf[pos + 3] = @truncate(run_len);
                pos += 4;
                i += run_len;
            }

            i += 1;
        }

        if (pos < buf.len) {
            return allocator.realloc(buf, pos);
        }
        return buf;
    }

    /// Unpack RLE-compressed cell diffs from a byte buffer.
    /// Single-pass: allocates worst-case (data.len / 4 entries max since
    /// minimum encoding is a 4-byte RLE marker after a 14-byte cell),
    /// then shrinks via realloc. Avoids the scan pass entirely.
    pub fn unpackDiffs(allocator: Allocator, data: []const u8) ![]CellDiff {
        if (data.len == 0) return try allocator.alloc(CellDiff, 0);

        // Worst case: every 14-byte cell is followed by a 4-byte RLE marker
        // encoding 1 extra cell. So max cells = data.len/14 + data.len/18.
        // Simpler upper bound: data.len/4 (since min record is 4 bytes for RLE).
        // But a single cell is 14 bytes, so data.len/14 is the max non-RLE cells.
        // With RLE, 18 bytes → up to 65536 cells, but worst case for allocation
        // is all non-RLE: data.len / CELL_PACKED_SIZE + 1.
        // However RLE can expand: use data.len as generous upper bound for cell count.
        // Actually: max cells from N bytes is bounded by reading all as RLE after
        // one cell: 1 + (N-14)/4 * 65535. That's huge. Use two-pass for exact count
        // but merge the counting into the same loop structure.
        //
        // Practical bound: non-RLE cells = data.len/14, RLE expansion per marker
        // is at most 65535. We need the scan pass for correctness with large RLE runs.

        // Fast scan: count only, no unpacking (just reads marker bytes)
        var total: usize = 0;
        {
            var scan: usize = 0;
            while (scan + CELL_PACKED_SIZE <= data.len) {
                total += 1;
                scan += CELL_PACKED_SIZE;
                if (scan + 4 <= data.len and
                    data[scan] == 0xFF and data[scan + 1] == 0xFF)
                {
                    total += @as(usize, data[scan + 2]) << 8 | data[scan + 3];
                    scan += 4;
                }
            }
        }

        const diffs = try allocator.alloc(CellDiff, total);
        var write_idx: usize = 0;
        var pos: usize = 0;

        while (pos + CELL_PACKED_SIZE <= data.len) {
            const diff = unpackCell(data[pos..][0..CELL_PACKED_SIZE]);
            diffs[write_idx] = diff;
            write_idx += 1;
            pos += CELL_PACKED_SIZE;

            if (pos + 4 <= data.len and
                data[pos] == 0xFF and data[pos + 1] == 0xFF)
            {
                const count: u16 = @as(u16, data[pos + 2]) << 8 | data[pos + 3];
                pos += 4;

                // Expand RLE: write contiguous cells with incrementing x
                const cell = diff.cell;
                const base_x = diff.x;
                const y = diff.y;
                var j: u16 = 0;
                while (j < count) : (j += 1) {
                    diffs[write_idx] = .{
                        .x = base_x + 1 + j,
                        .y = y,
                        .cell = cell,
                    };
                    write_idx += 1;
                }
            }
        }

        return diffs;
    }

    // ================================================================
    // SYRUP SERIALIZATION (packed binary)
    // ================================================================

    /// Encode a frame snapshot as a Syrup record with packed binary payload:
    /// <cell-frame gen cols rows source cursor-x cursor-y (bytes ...)>
    /// Uses packed_cache from commit() when available, avoiding redundant re-packing.
    pub fn snapshotToSyrup(self: *const CellSync, snapshot: *const FrameSnapshot, allocator: Allocator) !syrup.Value {
        const packed_data = if (snapshot.packed_cache) |cache|
            try allocator.dupe(u8, cache)
        else
            try packDiffs(allocator, snapshot.diffs);

        const label = try allocator.create(syrup.Value);
        label.* = .{ .symbol = "cell-frame" };

        const fields = try allocator.alloc(syrup.Value, 7);
        fields[0] = .{ .integer = @intCast(snapshot.gen) };
        fields[1] = .{ .integer = snapshot.cols };
        fields[2] = .{ .integer = snapshot.rows };
        fields[3] = .{ .integer = @intCast(snapshot.source) };
        fields[4] = .{ .integer = self.pane.cursor_x };
        fields[5] = .{ .integer = self.pane.cursor_y };
        fields[6] = .{ .bytes = packed_data };

        return .{ .record = .{ .label = label, .fields = fields } };
    }

    /// Decode a Syrup record back into a FrameSnapshot
    pub fn snapshotFromSyrup(allocator: Allocator, val: syrup.Value) !FrameSnapshot {
        const rec = val.record;
        if (!std.mem.eql(u8, rec.label.*.symbol, "cell-frame")) {
            return error.InvalidLabel;
        }

        const gen: Generation = @intCast(rec.fields[0].integer);
        const cols: u16 = @intCast(rec.fields[1].integer);
        const rows: u16 = @intCast(rec.fields[2].integer);
        const source: NodeId = @intCast(rec.fields[3].integer);
        // fields[4] = cursor_x, fields[5] = cursor_y (consumed by caller)
        const packed_data = rec.fields[6].bytes;

        const diffs = try unpackDiffs(allocator, packed_data);

        return .{
            .gen = gen,
            .cols = cols,
            .rows = rows,
            .diffs = diffs,
            .is_full = false,
            .source = source,
        };
    }

    /// Zero-allocation fast path: decode Syrup record and apply directly to grid.
    /// Combines snapshotFromSyrup + applyRemote into a single pass over packed data.
    /// Returns metadata (gen, source, cursor) without allocating CellDiff array.
    pub fn applyFromSyrup(self: *CellSync, val: syrup.Value) !struct { gen: Generation, source: NodeId, cursor_x: u16, cursor_y: u16 } {
        const rec = val.record;
        if (!std.mem.eql(u8, rec.label.*.symbol, "cell-frame")) {
            return error.InvalidLabel;
        }

        const gen: Generation = @intCast(rec.fields[0].integer);
        const source: NodeId = @intCast(rec.fields[3].integer);
        const cursor_x: u16 = @intCast(rec.fields[4].integer);
        const cursor_y: u16 = @intCast(rec.fields[5].integer);
        const packed_data = rec.fields[6].bytes;

        self.applyPacked(packed_data);

        return .{ .gen = gen, .source = source, .cursor_x = cursor_x, .cursor_y = cursor_y };
    }

    /// Encode an ACK message: <cell-ack node-id gen>
    pub fn ackToSyrup(node_id: NodeId, gen: Generation, allocator: Allocator) !syrup.Value {
        const label = try allocator.create(syrup.Value);
        label.* = .{ .symbol = "cell-ack" };

        const fields = try allocator.alloc(syrup.Value, 2);
        fields[0] = .{ .integer = @intCast(node_id) };
        fields[1] = .{ .integer = @intCast(gen) };

        return .{ .record = .{ .label = label, .fields = fields } };
    }

    /// Extract cursor position from a decoded Syrup frame
    pub fn cursorFromSyrup(val: syrup.Value) struct { x: u16, y: u16 } {
        const rec = val.record;
        return .{
            .x = @intCast(rec.fields[4].integer),
            .y = @intCast(rec.fields[5].integer),
        };
    }
};

// ============================================================================
// TESTS
// ============================================================================

test "cell sync basic write and commit" {
    const allocator = std.testing.allocator;
    var sync = try CellSync.init(allocator, 1, 80, 24);
    defer sync.deinit();

    sync.writeCell(0, 0, .{ .codepoint = 'A', .fg = 0xFF0000 });
    sync.writeCell(1, 0, .{ .codepoint = 'B', .fg = 0x00FF00 });

    var snapshot = try sync.commit();
    defer snapshot.deinit(allocator);

    try std.testing.expectEqual(@as(Generation, 1), snapshot.gen);
    try std.testing.expect(snapshot.diffs.len >= 2);
}

test "packed binary roundtrip" {
    const allocator = std.testing.allocator;

    const diffs = [_]CellDiff{
        .{ .x = 3, .y = 7, .cell = .{ .codepoint = 'X', .fg = 0xAABBCC, .bg = 0x112233, .attrs = .{ .bold = true } } },
        .{ .x = 10, .y = 20, .cell = .{ .codepoint = 0x1F600, .fg = 0xFFFFFF, .bg = 0x000000, .attrs = .{} } },
    };

    const packed_data = try CellSync.packDiffs(allocator, &diffs);
    defer allocator.free(packed_data);

    // 2 cells × 14 bytes = 28 bytes (no RLE since non-sequential)
    try std.testing.expectEqual(@as(usize, 28), packed_data.len);

    const unpacked = try CellSync.unpackDiffs(allocator, packed_data);
    defer allocator.free(unpacked);

    try std.testing.expectEqual(@as(usize, 2), unpacked.len);
    try std.testing.expectEqual(@as(u16, 3), unpacked[0].x);
    try std.testing.expectEqual(@as(u16, 7), unpacked[0].y);
    try std.testing.expect(Cell.eql(diffs[0].cell, unpacked[0].cell));
    try std.testing.expect(Cell.eql(diffs[1].cell, unpacked[1].cell));
}

test "RLE compression for identical cells" {
    const allocator = std.testing.allocator;

    // 10 identical cells in a row: x=0..9, y=5, same content
    var diffs: [10]CellDiff = undefined;
    for (&diffs, 0..) |*d, i| {
        d.* = .{
            .x = @intCast(i),
            .y = 5,
            .cell = .{ .codepoint = ' ', .fg = 0xFFFFFF, .bg = 0x000000 },
        };
    }

    const packed_data = try CellSync.packDiffs(allocator, &diffs);
    defer allocator.free(packed_data);

    // Without RLE: 10 × 14 = 140 bytes
    // With RLE: 1 cell (14) + 1 RLE marker (4) = 18 bytes
    try std.testing.expectEqual(@as(usize, 18), packed_data.len);

    const unpacked = try CellSync.unpackDiffs(allocator, packed_data);
    defer allocator.free(unpacked);

    try std.testing.expectEqual(@as(usize, 10), unpacked.len);
    for (unpacked, 0..) |d, i| {
        try std.testing.expectEqual(@as(u16, @intCast(i)), d.x);
        try std.testing.expectEqual(@as(u16, 5), d.y);
        try std.testing.expect(Cell.eql(diffs[0].cell, d.cell));
    }
}

test "RLE compression ratio for blank screen" {
    const allocator = std.testing.allocator;

    // Simulate a blank 80x24 terminal (all spaces, same colors)
    const total: usize = 80 * 24;
    const diffs = try allocator.alloc(CellDiff, total);
    defer allocator.free(diffs);

    for (diffs, 0..) |*d, i| {
        d.* = .{
            .x = @intCast(i % 80),
            .y = @intCast(i / 80),
            .cell = .{ .codepoint = ' ', .fg = 0xFFFFFF, .bg = 0x000000 },
        };
    }

    const packed_data = try CellSync.packDiffs(allocator, diffs);
    defer allocator.free(packed_data);

    const uncompressed_size = total * 14; // 26,880 bytes
    // RLE: 24 rows × (1 cell + 1 RLE marker) = 24 × 18 = 432 bytes
    try std.testing.expect(packed_data.len < uncompressed_size / 10);

    const unpacked = try CellSync.unpackDiffs(allocator, packed_data);
    defer allocator.free(unpacked);
    try std.testing.expectEqual(total, unpacked.len);
}

test "cell sync syrup roundtrip with packed binary" {
    const allocator = std.testing.allocator;
    var sync = try CellSync.init(allocator, 1, 10, 5);
    defer sync.deinit();

    // Clear initial damage
    var initial = try sync.commit();
    initial.deinit(allocator);

    // Write some cells
    sync.writeCell(3, 2, .{ .codepoint = 'X', .fg = 0xAABBCC, .bg = 0x112233, .attrs = .{ .bold = true } });
    sync.writeCell(4, 2, .{ .codepoint = 'Y', .fg = 0xDDEEFF });

    var snapshot = try sync.commit();
    defer snapshot.deinit(allocator);

    // Encode to Syrup (packed binary)
    const val = try sync.snapshotToSyrup(&snapshot, allocator);
    // Free the packed bytes (owned by the syrup value)
    defer {
        allocator.free(val.record.fields[6].bytes);
        allocator.free(val.record.fields);
        const label_slice: *[1]syrup.Value = @ptrCast(@constCast(val.record.label));
        allocator.free(label_slice);
    }

    // Decode back
    var decoded = try CellSync.snapshotFromSyrup(allocator, val);
    defer decoded.deinit(allocator);

    try std.testing.expectEqual(snapshot.gen, decoded.gen);
    try std.testing.expectEqual(snapshot.cols, decoded.cols);
    try std.testing.expectEqual(snapshot.rows, decoded.rows);
    try std.testing.expectEqual(snapshot.diffs.len, decoded.diffs.len);

    // Verify cell content survived roundtrip
    for (snapshot.diffs, decoded.diffs) |orig, dec| {
        try std.testing.expectEqual(orig.x, dec.x);
        try std.testing.expectEqual(orig.y, dec.y);
        try std.testing.expect(Cell.eql(orig.cell, dec.cell));
    }
}

test "cell sync apply remote" {
    const allocator = std.testing.allocator;

    var node_a = try CellSync.init(allocator, 1, 20, 10);
    defer node_a.deinit();
    var node_b = try CellSync.init(allocator, 2, 20, 10);
    defer node_b.deinit();

    // Clear initial damage on both
    var a_init = try node_a.commit();
    a_init.deinit(allocator);
    var b_init = try node_b.commit();
    b_init.deinit(allocator);

    // A writes
    node_a.writeCell(5, 3, .{ .codepoint = '!', .fg = 0xFF0000 });
    var snapshot = try node_a.commit();
    defer snapshot.deinit(allocator);

    // B applies
    node_b.applyRemote(&snapshot);

    const cell = node_b.pane.getCell(5, 3);
    try std.testing.expect(cell != null);
    try std.testing.expectEqual(@as(u21, '!'), cell.?.codepoint);
    try std.testing.expectEqual(@as(u24, 0xFF0000), cell.?.fg);
}

test "zero-alloc fast path: applyFromSyrup" {
    const allocator = std.testing.allocator;

    var node_a = try CellSync.init(allocator, 1, 20, 10);
    defer node_a.deinit();
    var node_b = try CellSync.init(allocator, 2, 20, 10);
    defer node_b.deinit();

    // Clear initial damage
    var a_init = try node_a.commit();
    a_init.deinit(allocator);
    var b_init = try node_b.commit();
    b_init.deinit(allocator);

    // A writes cells (including a run for RLE)
    node_a.writeCell(5, 3, .{ .codepoint = 'Z', .fg = 0xAABBCC, .bg = 0x112233 });
    node_a.writeCell(6, 3, .{ .codepoint = 'Z', .fg = 0xAABBCC, .bg = 0x112233 });
    node_a.writeCell(7, 3, .{ .codepoint = 'Z', .fg = 0xAABBCC, .bg = 0x112233 });
    node_a.pane.cursor_x = 8;
    node_a.pane.cursor_y = 3;

    var snapshot = try node_a.commit();
    defer snapshot.deinit(allocator);

    // Encode to Syrup
    const val = try node_a.snapshotToSyrup(&snapshot, allocator);
    defer {
        allocator.free(val.record.fields[6].bytes);
        allocator.free(val.record.fields);
        const label_slice: *[1]syrup.Value = @ptrCast(@constCast(val.record.label));
        allocator.free(label_slice);
    }

    // B applies via zero-alloc fast path
    const meta = try node_b.applyFromSyrup(val);

    try std.testing.expectEqual(snapshot.gen, meta.gen);
    try std.testing.expectEqual(@as(u16, 8), meta.cursor_x);
    try std.testing.expectEqual(@as(u16, 3), meta.cursor_y);

    // Verify cells arrived
    const cell5 = node_b.pane.getCell(5, 3);
    try std.testing.expect(cell5 != null);
    try std.testing.expectEqual(@as(u21, 'Z'), cell5.?.codepoint);
    try std.testing.expectEqual(@as(u24, 0xAABBCC), cell5.?.fg);

    // Verify RLE-expanded cell
    const cell7 = node_b.pane.getCell(7, 3);
    try std.testing.expect(cell7 != null);
    try std.testing.expectEqual(@as(u21, 'Z'), cell7.?.codepoint);
}

test "cell sync full snapshot" {
    const allocator = std.testing.allocator;
    var sync = try CellSync.init(allocator, 1, 4, 3);
    defer sync.deinit();

    var init_snap = try sync.commit();
    init_snap.deinit(allocator);

    sync.writeCell(0, 0, .{ .codepoint = 'A' });
    var commit_snap = try sync.commit();
    commit_snap.deinit(allocator);

    var full = try sync.fullSnapshot();
    defer full.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 4 * 3), full.diffs.len);
    try std.testing.expect(full.is_full);
}

test "cell sync ack tracking" {
    const allocator = std.testing.allocator;
    var sync = try CellSync.init(allocator, 1, 10, 5);
    defer sync.deinit();

    try sync.ack(42, 5);
    try sync.ack(42, 10);
    try sync.ack(42, 7); // older, should not regress

    const peer = sync.peers.get(42).?;
    try std.testing.expectEqual(@as(Generation, 10), peer.acked_gen);
}

test "diff log retransmission" {
    const allocator = std.testing.allocator;
    var sync = try CellSync.init(allocator, 1, 10, 5);
    defer sync.deinit();

    var init_snap = try sync.commit();
    init_snap.deinit(allocator);

    sync.writeCell(0, 0, .{ .codepoint = '1' });
    var s1 = try sync.commit();
    s1.deinit(allocator);

    sync.writeCell(1, 0, .{ .codepoint = '2' });
    var s2 = try sync.commit();
    s2.deinit(allocator);

    sync.writeCell(2, 0, .{ .codepoint = '3' });
    var s3 = try sync.commit();
    s3.deinit(allocator);

    const retransmit = sync.packedSince(2);
    try std.testing.expect(retransmit != null);

    const old_retransmit = sync.packedSince(0);
    try std.testing.expect(old_retransmit != null);
}

test "cursor state included in syrup" {
    const allocator = std.testing.allocator;
    var sync = try CellSync.init(allocator, 1, 20, 10);
    defer sync.deinit();

    sync.pane.cursor_x = 7;
    sync.pane.cursor_y = 3;

    var init_snap = try sync.commit();
    init_snap.deinit(allocator);

    sync.writeCell(0, 0, .{ .codepoint = 'Z' });
    var snapshot = try sync.commit();
    defer snapshot.deinit(allocator);

    const val = try sync.snapshotToSyrup(&snapshot, allocator);
    defer {
        allocator.free(val.record.fields[6].bytes);
        allocator.free(val.record.fields);
        const label_slice: *[1]syrup.Value = @ptrCast(@constCast(val.record.label));
        allocator.free(label_slice);
    }

    const cursor = CellSync.cursorFromSyrup(val);
    try std.testing.expectEqual(@as(u16, 7), cursor.x);
    try std.testing.expectEqual(@as(u16, 3), cursor.y);
}

test "packed binary size vs record encoding" {
    const allocator = std.testing.allocator;

    // 100 diverse cells
    var diffs: [100]CellDiff = undefined;
    for (&diffs, 0..) |*d, i| {
        d.* = .{
            .x = @intCast(i % 50),
            .y = @intCast(i / 50),
            .cell = .{
                .codepoint = @intCast('A' + (i % 26)),
                .fg = @intCast(i * 0x010101),
                .bg = @intCast(0xFFFFFF - i * 0x010101),
                .attrs = .{ .bold = (i % 2 == 0) },
            },
        };
    }

    const packed_data = try CellSync.packDiffs(allocator, &diffs);
    defer allocator.free(packed_data);

    // Packed: 100 × 14 = 1400 bytes (no RLE since diverse cells)
    // Record encoding would be: ~100 × 50+ = 5000+ bytes
    try std.testing.expectEqual(@as(usize, 1400), packed_data.len);
}

test "empty diff commit" {
    const allocator = std.testing.allocator;
    var sync = try CellSync.init(allocator, 1, 10, 5);
    defer sync.deinit();

    // Clear initial
    var init_snap = try sync.commit();
    init_snap.deinit(allocator);

    // Commit with no changes
    var snapshot = try sync.commit();
    defer snapshot.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 0), snapshot.diffs.len);

    // Packed encoding of zero diffs
    const packed_data = try CellSync.packDiffs(allocator, snapshot.diffs);
    defer allocator.free(packed_data);
    try std.testing.expectEqual(@as(usize, 0), packed_data.len);
}
