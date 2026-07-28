//! Fountain ↔ Propagator Bridge
//!
//! Makes fountain decoding composable with propagator networks.
//! Each source block = Cell(Block, latticeMerge).
//! Each incoming encoded block = Propagator that XOR-reduces known cells
//! and solves degree-1 residuals.
//!
//! This lets fountain decoding participate in larger propagator networks:
//!   - BCI neurofeedback_gate → scan priority (which QR frames to focus on)
//!   - Spatial adjacency_gate → multi-device cooperative decoding
//!   - Identity verification → passport.gay proof cell settles when all blocks known
//!
//! The decoder's adhesion_filter (Bumpus, StructuredDecompositions.jl) maps to
//! propagator alert cascades: solving one Cell fires neighbors, potentially
//! solving more Cells in a chain.
//!
//! GF(3) trit: 0 (ERGODIC) — bridges fountain(+1) ↔ propagator(-1)
//!
//! Zero-alloc in the hot path. Fixed-size block arrays, no heap.

const std = @import("std");
const fountain = @import("fountain.zig");
const propagator = @import("propagator.zig");

// =============================================================================
// Block type for propagator cells
// =============================================================================

/// A fixed-size source block with equality comparison for lattice merge.
pub const Block = struct {
    data: [fountain.DEFAULT_BLOCK_SIZE]u8 = undefined,
    len: usize = 0,

    pub fn eql(a: Block, b: Block) bool {
        if (a.len != b.len) return false;
        return std.mem.eql(u8, a.data[0..a.len], b.data[0..b.len]);
    }
};

// Use lattice merge: Nothing → Value → Contradiction (same as propagator.zig)
const BlockCell = propagator.CellValue(Block);

// =============================================================================
// Fountain Propagator Network
// =============================================================================

/// A fountain decoder expressed as a propagator network.
/// Source blocks are cells; encoded blocks fire propagation.
/// Settles when all cells hold values (decode complete).
/// Contradicts if two different solutions reach the same cell (transmission error).
pub const FountainNet = struct {
    /// Cell values for each source block
    cells: [fountain.MAX_SOURCE_BLOCKS]BlockCell =
        @splat(.{ .nothing = {} }),
    /// Number of source blocks expected
    num_blocks: usize = 0,
    /// Number of cells that hold values (not nothing, not contradiction)
    num_settled: usize = 0,
    /// Number of contradictions detected
    num_contradictions: usize = 0,
    /// Pending encoded blocks (not yet solvable)
    pending: [fountain.MAX_SOURCE_BLOCKS * 4]PendingBlock =
        undefined,
    pending_count: usize = 0,
    /// Session seed
    seed: u64 = 0,
    /// PRNG mode
    prng_mode: fountain.PrngMode = .splitmix,

    const PendingBlock = struct {
        payload: [fountain.DEFAULT_BLOCK_SIZE]u8 = undefined,
        payload_len: usize = 0,
        indices: [fountain.MAX_DEGREE]u16 = undefined,
        degree: u8 = 0,
    };

    /// Initialize from session parameters.
    pub fn init(seed: u64, num_blocks: usize) FountainNet {
        return initWithMode(seed, num_blocks, .splitmix);
    }

    pub fn initWithMode(seed: u64, num_blocks: usize, mode: fountain.PrngMode) FountainNet {
        return .{
            .num_blocks = num_blocks,
            .seed = seed,
            .prng_mode = mode,
        };
    }

    /// Feed an encoded block. Returns true if any new cells settled.
    pub fn ingest(self: *FountainNet, block: *const fountain.EncodedBlock) bool {
        if (block.num_source_blocks != @as(u16, @intCast(self.num_blocks))) return false;

        // Re-derive source indices (deterministic from seed ^ block_index)
        var prng = fountain.Prng.init(self.prng_mode, block.seed ^ @as(u64, block.block_index));
        const degree = fountain.sampleDegree(&prng, self.num_blocks);
        var indices: [fountain.MAX_DEGREE]usize = undefined;
        const actual = fountain.selectSources(&prng, self.num_blocks, degree, &indices);

        // Copy payload for XOR reduction
        var payload: [fountain.DEFAULT_BLOCK_SIZE]u8 = undefined;
        @memcpy(&payload, &block.payload);
        const payload_len = block.payload_len;

        // XOR out known cells, collect unknown indices
        var unknown_count: u8 = 0;
        var unknown_indices: [fountain.MAX_DEGREE]u16 = undefined;
        for (0..actual) |i| {
            const idx = indices[i];
            switch (self.cells[idx]) {
                .value => |v| fountain.xorBlocks(&payload, v.data[0..v.len]),
                .nothing => {
                    unknown_indices[unknown_count] = @intCast(idx);
                    unknown_count += 1;
                },
                .contradiction => {}, // Skip contradicted cells
            }
        }

        if (unknown_count == 0) {
            return false; // Redundant
        } else if (unknown_count == 1) {
            // Solve: merge into cell via lattice
            const idx = unknown_indices[0];
            const solved = Block{
                .data = payload,
                .len = payload_len,
            };
            return self.settleCell(idx, solved);
        } else {
            // Buffer for later propagation
            if (self.pending_count < self.pending.len) {
                var pb = &self.pending[self.pending_count];
                @memcpy(&pb.payload, &payload);
                pb.payload_len = payload_len;
                pb.degree = unknown_count;
                for (0..unknown_count) |i| {
                    pb.indices[i] = unknown_indices[i];
                }
                self.pending_count += 1;
            }
            return false;
        }
    }

    /// Settle a cell via lattice merge. Propagates if successful.
    fn settleCell(self: *FountainNet, idx: u16, block: Block) bool {
        const incoming = BlockCell{ .value = block };
        const merged = latticeMergeBlock(self.cells[idx], incoming);

        switch (merged) {
            .nothing => return false,
            .value => {
                if (self.cells[idx] == .nothing) {
                    self.num_settled += 1;
                }
                self.cells[idx] = merged;
                // Propagate: check pending blocks
                self.propagate();
                return true;
            },
            .contradiction => {
                if (self.cells[idx] != .contradiction) {
                    self.num_contradictions += 1;
                }
                self.cells[idx] = merged;
                return false;
            },
        }
    }

    /// Adhesion filter: propagate newly-known cells through pending blocks.
    fn propagate(self: *FountainNet) void {
        var progress = true;
        while (progress) {
            progress = false;
            var i: usize = 0;
            while (i < self.pending_count) {
                var pb = &self.pending[i];

                // XOR out newly known cells
                var new_unknown: u8 = 0;
                var new_indices: [fountain.MAX_DEGREE]u16 = undefined;
                var j: u8 = 0;
                while (j < pb.degree) : (j += 1) {
                    const idx = pb.indices[j];
                    switch (self.cells[idx]) {
                        .value => |v| fountain.xorBlocks(&pb.payload, v.data[0..v.len]),
                        .nothing => {
                            new_indices[new_unknown] = idx;
                            new_unknown += 1;
                        },
                        .contradiction => {},
                    }
                }
                pb.degree = new_unknown;
                for (0..new_unknown) |k| {
                    pb.indices[k] = new_indices[k];
                }

                if (new_unknown == 0) {
                    self.removePending(i);
                    continue;
                } else if (new_unknown == 1) {
                    const idx = new_indices[0];
                    const solved = Block{
                        .data = pb.payload,
                        .len = pb.payload_len,
                    };
                    self.removePending(i);
                    _ = self.settleCell(idx, solved);
                    progress = true;
                    continue;
                }

                i += 1;
            }
        }
    }

    fn removePending(self: *FountainNet, idx: usize) void {
        if (self.pending_count > 0) {
            self.pending[idx] = self.pending[self.pending_count - 1];
            self.pending_count -= 1;
        }
    }

    // =========================================================================
    // Query interface
    // =========================================================================

    /// True when all cells hold values.
    pub fn isSettled(self: *const FountainNet) bool {
        return self.num_settled >= self.num_blocks;
    }

    /// True when any cell has contradicted (transmission error).
    pub fn hasContradiction(self: *const FountainNet) bool {
        return self.num_contradictions > 0;
    }

    /// Get the CellValue for a source block.
    pub fn cellAt(self: *const FountainNet, idx: usize) BlockCell {
        return self.cells[idx];
    }

    /// Get the solved value for a source block, or null.
    pub fn blockAt(self: *const FountainNet, idx: usize) ?*const Block {
        return switch (self.cells[idx]) {
            .value => |*v| v,
            else => null,
        };
    }

    /// Reassemble the original payload. Returns null if not settled.
    pub fn reassemble(self: *const FountainNet, out: []u8) ?usize {
        if (!self.isSettled()) return null;

        var written: usize = 0;
        for (0..self.num_blocks) |i| {
            const block = switch (self.cells[i]) {
                .value => |v| v,
                else => return null,
            };
            if (written + block.len > out.len) return null;
            @memcpy(out[written .. written + block.len], block.data[0..block.len]);
            written += block.len;
        }
        return written;
    }

    /// GF(3) trit status: +1 settled, 0 pending, -1 contradiction.
    pub fn trit(self: *const FountainNet) i2 {
        if (self.num_contradictions > 0) return -1;
        if (self.isSettled()) return 1;
        return 0;
    }
};

// =============================================================================
// Block lattice merge
// =============================================================================

fn latticeMergeBlock(existing: BlockCell, incoming: BlockCell) BlockCell {
    return switch (existing) {
        .nothing => incoming,
        .contradiction => existing,
        .value => |a| switch (incoming) {
            .nothing => existing,
            .value => |b| if (a.eql(b))
                existing
            else
                BlockCell{ .contradiction = .{ .a = a, .b = b } },
            .contradiction => incoming,
        },
    };
}

// =============================================================================
// Tests
// =============================================================================

test "fountain propagator: small payload round trip" {
    const data = "hello propagator fountain!";
    const seed: u64 = 0xBEEF;
    var enc = fountain.Encoder.init(seed, data);
    const k = enc.sourceCount();

    var net = FountainNet.init(seed, k);

    var blocks_sent: u32 = 0;
    while (!net.isSettled()) : (blocks_sent += 1) {
        const block = enc.nextBlock();
        _ = net.ingest(&block);
        if (blocks_sent > k * 20) break;
    }

    try std.testing.expect(net.isSettled());
    try std.testing.expect(!net.hasContradiction());
    try std.testing.expectEqual(@as(i2, 1), net.trit());

    var out: [1024]u8 = undefined;
    const len = net.reassemble(&out).?;
    try std.testing.expectEqualSlices(u8, data, out[0..len]);
}

test "fountain propagator: multi-block round trip" {
    var data: [fountain.DEFAULT_BLOCK_SIZE * 4]u8 = undefined;
    for (&data, 0..) |*b, i| b.* = @intCast(i % 251);

    const seed: u64 = 0xCAFE;
    var enc = fountain.Encoder.init(seed, &data);
    const k = enc.sourceCount();

    var net = FountainNet.init(seed, k);

    var blocks_sent: u32 = 0;
    while (!net.isSettled()) : (blocks_sent += 1) {
        const block = enc.nextBlock();
        _ = net.ingest(&block);
        if (blocks_sent > k * 20) break;
    }

    try std.testing.expect(net.isSettled());
    try std.testing.expectEqual(@as(i2, 1), net.trit());

    var out: [fountain.DEFAULT_BLOCK_SIZE * 4]u8 = undefined;
    const len = net.reassemble(&out).?;
    try std.testing.expectEqualSlices(u8, &data, out[0..len]);
}

test "fountain propagator: chacha mode" {
    const data = "passport.gay proof-of-brain via propagator lattice";
    const seed: u64 = 0xDA55;
    var enc = fountain.Encoder.initWithMode(seed, data, .chacha);
    const k = enc.sourceCount();

    var net = FountainNet.initWithMode(seed, k, .chacha);

    var blocks_sent: u32 = 0;
    while (!net.isSettled()) : (blocks_sent += 1) {
        const block = enc.nextBlock();
        _ = net.ingest(&block);
        if (blocks_sent > k * 20) break;
    }

    try std.testing.expect(net.isSettled());

    var out: [1024]u8 = undefined;
    const len = net.reassemble(&out).?;
    try std.testing.expectEqualSlices(u8, data, out[0..len]);
}

test "fountain propagator: trit transitions" {
    const data = "trit";
    const seed: u64 = 42;
    var enc = fountain.Encoder.init(seed, data);
    const k = enc.sourceCount();

    var net = FountainNet.init(seed, k);

    // Initially pending
    try std.testing.expectEqual(@as(i2, 0), net.trit());
    try std.testing.expect(!net.isSettled());

    // Feed until settled
    var i: u32 = 0;
    while (!net.isSettled()) : (i += 1) {
        const block = enc.nextBlock();
        _ = net.ingest(&block);
        if (i > 50) break;
    }

    // Now settled
    try std.testing.expectEqual(@as(i2, 1), net.trit());
}

test "fountain propagator: cell query" {
    const data = "ab"; // Fits in one block
    const seed: u64 = 99;
    var enc = fountain.Encoder.init(seed, data);
    const k = enc.sourceCount();

    var net = FountainNet.init(seed, k);

    // Before ingestion: nothing
    try std.testing.expect(net.cellAt(0) == .nothing);
    try std.testing.expect(net.blockAt(0) == null);

    // Feed one block (K=1, so degree=1 passthrough)
    const block = enc.nextBlock();
    _ = net.ingest(&block);

    // After: value
    try std.testing.expect(net.cellAt(0) == .value);
    const solved = net.blockAt(0).?;
    try std.testing.expectEqualSlices(u8, data, solved.data[0..solved.len]);
}

test "fountain propagator: redundant blocks harmless" {
    const data = "redundancy test";
    const seed: u64 = 7;
    var enc = fountain.Encoder.init(seed, data);
    const k = enc.sourceCount();

    var net = FountainNet.init(seed, k);

    // Send many more blocks than needed
    for (0..50) |_| {
        const block = enc.nextBlock();
        _ = net.ingest(&block);
    }

    try std.testing.expect(net.isSettled());
    try std.testing.expect(!net.hasContradiction());

    var out: [256]u8 = undefined;
    const len = net.reassemble(&out).?;
    try std.testing.expectEqualSlices(u8, data, out[0..len]);
}
