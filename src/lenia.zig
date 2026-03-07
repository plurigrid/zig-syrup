//! Lenia: Continuous Cellular Automata

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const LeniaConfig = struct {
    size: usize,
    dt: f32,
    mu: f32,
    sigma: f32,
};

pub const LeniaWorld = struct {
    grid: []f32,
    next_grid: []f32,
    config: LeniaConfig,
    allocator: Allocator,

    pub fn init(allocator: Allocator, config: LeniaConfig) !LeniaWorld {
        const len = config.size * config.size;
        const grid = try allocator.alloc(f32, len);
        const next_grid = try allocator.alloc(f32, len);
        @memset(grid, 0);
        @memset(next_grid, 0);
        return .{
            .grid = grid,
            .next_grid = next_grid,
            .config = config,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *LeniaWorld) void {
        self.allocator.free(self.grid);
        self.allocator.free(self.next_grid);
    }
};

test "lenia init" {
    const allocator = std.testing.allocator;
    var world = try LeniaWorld.init(allocator, .{
        .size = 64,
        .dt = 0.1,
        .mu = 0.15,
        .sigma = 0.017,
    });
    defer world.deinit();
    try std.testing.expectEqual(world.grid.len, 4096);
}
