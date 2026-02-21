//! # Tileable Combinatorial Complex Substrate
//! 
//! Basic combinatorial complex infrastructure supporting arbitrary rank,
//! incidence, and zero-copy slab addressing.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const CellId = u32;
pub const INVALID_CELL: CellId = 0xFFFFFFFF;

pub const CellTag = enum(u2) {
    mortal = 0,
    immortal = 1,
    phantom = 2,
    frozen = 3,
};

pub const SLAB_SIZE: usize = 1 << 16;

pub const CellSlab = struct {
    ranks: [SLAB_SIZE]u8,
    trits: [SLAB_SIZE]i8,
    tags: [SLAB_SIZE]u2,
    energy_k: [SLAB_SIZE]f32,
    energy_p: [SLAB_SIZE]f32,
    members_inline: [SLAB_SIZE][8]CellId,
    members_count: [SLAB_SIZE]u8,
    members_overflow: [SLAB_SIZE]?[*]CellId,
    payload_offset: [SLAB_SIZE]u32,
    states: [SLAB_SIZE]std.atomic.Value(u8),
    live_count: std.atomic.Value(u32),

    pub fn init() CellSlab {
        var slab: CellSlab = undefined;
        @memset(&slab.ranks, 0);
        @memset(&slab.trits, 0);
        @memset(&slab.tags, 0);
        @memset(&slab.energy_k, 0);
        @memset(&slab.energy_p, 0);
        @memset(&slab.members_count, 0);
        for (&slab.members_overflow) |*p| p.* = null;
        @memset(&slab.payload_offset, 0);
        for (&slab.states) |*s| s.* = std.atomic.Value(u8).init(0);
        slab.live_count = std.atomic.Value(u32).init(0);
        return slab;
    }
};

pub const CombinatorialComplex = struct {
    const Self = @This();

    slabs: std.ArrayListUnmanaged(*CellSlab) = .{},
    next_id: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    max_rank: u8 = 0,
    trit_sum: std.atomic.Value(i32) = std.atomic.Value(i32).init(0),
    allocator: Allocator,
    rank_index: [256]std.ArrayListUnmanaged(CellId) = [_]std.ArrayListUnmanaged(CellId){.{}} ** 256,

    pub fn init(allocator: Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        for (self.slabs.items) |slab| self.allocator.destroy(slab);
        self.slabs.deinit(self.allocator);
        for (&self.rank_index) |*list| list.deinit(self.allocator);
    }

    fn ensureSlab(self: *Self, slab_idx: usize) !void {
        while (self.slabs.items.len <= slab_idx) {
            const slab = try self.allocator.create(CellSlab);
            slab.* = CellSlab.init();
            try self.slabs.append(self.allocator, slab);
        }
    }

    inline fn slabOf(id: CellId) usize { return id / SLAB_SIZE; }
    inline fn offsetOf(id: CellId) usize { return id % SLAB_SIZE; }

    pub fn addVertex(self: *Self, trit_val: i8) !CellId {
        const id = self.next_id.fetchAdd(1, .monotonic);
        try self.ensureSlab(slabOf(id));
        const slab = self.slabs.items[slabOf(id)];
        const off = offsetOf(id);
        slab.ranks[off] = 0;
        slab.trits[off] = trit_val;
        slab.tags[off] = @intFromEnum(CellTag.mortal);
        slab.members_count[off] = 0;
        _ = slab.live_count.fetchAdd(1, .monotonic);
        _ = self.trit_sum.fetchAdd(trit_val, .monotonic);
        try self.rank_index[0].append(self.allocator, id);
        return id;
    }

    pub fn cellCount(self: *const Self) u32 { return self.next_id.load(.monotonic); }
    pub fn isConserved(self: *const Self) bool { return @mod(self.trit_sum.load(.monotonic), 3) == 0; }
};

test "complex construction" {
    const allocator = std.testing.allocator;
    var cc = CombinatorialComplex.init(allocator);
    defer cc.deinit();
    _ = try cc.addVertex(1);
    _ = try cc.addVertex(-1);
    _ = try cc.addVertex(0);
    try std.testing.expect(cc.isConserved());
}
