//! Distributed Terminal Rendering Example
//!
//! Demonstrates transducer-based parallel cell dispatch

const std = @import("std");
const cell_dispatch = @import("cell_dispatch");
const damage = @import("damage");

const Cell = cell_dispatch.Cell;
const CellBatch = cell_dispatch.CellBatch;
const CellCoord = cell_dispatch.CellCoord;
const DispatchEngine = cell_dispatch.DispatchEngine;
const TransducerContext = cell_dispatch.TransducerContext;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("Distributed Terminal Cell Dispatch Demo\n", .{});
    std.debug.print("======================================\n\n", .{});

    // Initialize the dispatch engine with thread pool
    var engine = try DispatchEngine.init(allocator, .{
        .thread_count = 4,
    });
    defer engine.deinit();

    // Create a batch of cells
    const origin = CellCoord{ .x = 0, .y = 0, .world_id = 1 };
    var batch = try CellBatch.init(allocator, origin, 16, 16);
    defer batch.deinit();

    // Initialize cells
    for (0..16) |y| {
        for (0..16) |x| {
            const cell = Cell{
                .codepoint = ' ',
                .fg = 0xFFFFFFFF,
                .bg = 0xFF000000,
                .attrs = @as(u32, engine.generation) << 8,
            };
            batch.set(@intCast(x), @intCast(y), cell);
        }
    }

    // Simulate damage
    for (0..5) |i| {
        const cell = Cell{
            .codepoint = 'X',
            .fg = 0xFFFF0000,
            .bg = 0xFF0000FF,
            .attrs = 0, // Dirty
        };
        batch.set(@intCast(i * 3), @intCast(i * 2), cell);
    }

    const before = batch.dirtyCount(engine.generation);
    std.debug.print("Dirty cells: {} / {}\n", .{before, batch.cells.len});

    // Process through transducer
    const filter_dirty = cell_dispatch.filterDirty();
    var processed: u32 = 0;
    
    const cb = struct {
        var count: *u32 = undefined;
        fn callback(cell: Cell, ctx: TransducerContext) !void {
            _ = cell;
            _ = ctx;
            count.* += 1;
        }
    }.cb;
    cb.count = &processed;

    try engine.dispatchBatch(&batch, filter_dirty, cb);

    std.debug.print("Processed: {} cells\n", .{processed});
    std.debug.print("Efficiency: {d:.1}%\n", .{
        100.0 * @as(f64, @floatFromInt(processed)) / @as(f64, @floatFromInt(batch.cells.len)),
    });
}
