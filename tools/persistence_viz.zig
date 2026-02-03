//! Persistence Diagram Terminal Visualizer
//!
//! Renders persistent homology barcodes and persistence diagrams
//! using ANSI terminal graphics.
//!
//! Usage: zig build persistence
//!   Generates sample point cloud, computes persistence, renders diagram

const std = @import("std");

// ============================================================================
// PERSISTENCE DATA TYPES (standalone, no import needed)
// ============================================================================

pub const PersistencePair = struct {
    birth: f64,
    death: f64,
    dimension: usize,
};

pub const PersistenceDiagram = struct {
    pairs: []const PersistencePair,
};

// ============================================================================
// ANSI TERMINAL RENDERING
// ============================================================================

const ANSI = struct {
    const reset = "\x1b[0m";
    const bold = "\x1b[1m";
    const dim = "\x1b[2m";

    // Dimension colors
    const dim0 = "\x1b[38;5;39m"; // Blue - H₀ (connected components)
    const dim1 = "\x1b[38;5;208m"; // Orange - H₁ (loops)
    const dim2 = "\x1b[38;5;196m"; // Red - H₂ (voids)
    const dim3 = "\x1b[38;5;141m"; // Purple - H₃

    const bar_char = "\xe2\x94\x81"; // ━
    const dot_birth = "\xe2\x97\x8f"; // ●
    const dot_death = "\xe2\x97\x8b"; // ○
    const infinity = "\xe2\x88\x9e"; // ∞
    const arrow_right = "\xe2\x86\x92"; // →

    fn dimColor(d: usize) []const u8 {
        return switch (d) {
            0 => dim0,
            1 => dim1,
            2 => dim2,
            3 => dim3,
            else => reset,
        };
    }

    fn dimLabel(d: usize) []const u8 {
        return switch (d) {
            0 => "H\xe2\x82\x80",
            1 => "H\xe2\x82\x81",
            2 => "H\xe2\x82\x82",
            3 => "H\xe2\x82\x83",
            else => "H\xe2\x82\x99",
        };
    }
};

// ============================================================================
// BARCODE RENDERER
// ============================================================================

fn renderBarcodes(writer: anytype, diagram: PersistenceDiagram, width: usize) !void {
    if (diagram.pairs.len == 0) {
        try writer.writeAll("  (empty diagram)\n");
        return;
    }

    // Find global min/max for scaling
    var min_val: f64 = std.math.inf(f64);
    var max_val: f64 = 0;
    var max_dim: usize = 0;
    var has_infinite = false;

    for (diagram.pairs) |pair| {
        min_val = @min(min_val, pair.birth);
        if (pair.death != std.math.inf(f64)) {
            max_val = @max(max_val, pair.death);
        } else {
            has_infinite = true;
            max_val = @max(max_val, pair.birth + 1.0);
        }
        max_dim = @max(max_dim, pair.dimension);
    }

    if (has_infinite) max_val *= 1.2;
    const range = if (max_val > min_val) max_val - min_val else 1.0;

    // Header
    try writer.writeAll("\n" ++ ANSI.bold ++ "\x1b[38;5;255m" ++ "  PERSISTENCE BARCODE" ++ ANSI.reset ++ "\n");
    try writer.writeAll("  " ++ ANSI.dim ++ "birth" ++ ANSI.reset);
    for (0..width -| 10) |_| try writer.writeAll(" ");
    try writer.writeAll(ANSI.dim ++ "death" ++ ANSI.reset ++ "\n");

    // Axis
    try writer.writeAll("  ");
    try writer.print("{d:.2}", .{min_val});
    const label_len: usize = 8;
    if (width > label_len * 2) {
        for (0..width - label_len * 2) |_| try writer.writeAll("\xe2\x94\x80");
    }
    try writer.print("{d:.2}\n", .{max_val});

    // Sort by dimension then birth
    const sorted = try std.heap.page_allocator.alloc(PersistencePair, diagram.pairs.len);
    defer std.heap.page_allocator.free(sorted);
    @memcpy(sorted, diagram.pairs);
    std.mem.sort(PersistencePair, sorted, {}, struct {
        fn lessThan(_: void, a: PersistencePair, b: PersistencePair) bool {
            if (a.dimension != b.dimension) return a.dimension < b.dimension;
            return a.birth < b.birth;
        }
    }.lessThan);

    // Render each bar
    var current_dim: usize = std.math.maxInt(usize);
    for (sorted) |pair| {
        if (pair.dimension != current_dim) {
            current_dim = pair.dimension;
            try writer.writeAll("\n  " ++ ANSI.bold);
            try writer.writeAll(ANSI.dimColor(current_dim));
            try writer.writeAll(ANSI.dimLabel(current_dim));
            try writer.writeAll(ANSI.reset ++ "\n");
        }

        const color = ANSI.dimColor(pair.dimension);
        const birth_pos = @as(usize, @intFromFloat((pair.birth - min_val) / range * @as(f64, @floatFromInt(width))));
        const death_pos = if (pair.death == std.math.inf(f64))
            width
        else
            @as(usize, @intFromFloat((pair.death - min_val) / range * @as(f64, @floatFromInt(width))));

        // Leading space
        try writer.writeAll("  ");
        for (0..birth_pos) |_| try writer.writeAll(" ");

        // Bar
        try writer.writeAll(color);
        try writer.writeAll(ANSI.dot_birth);
        if (death_pos > birth_pos + 1) {
            for (0..death_pos - birth_pos - 1) |_| try writer.writeAll(ANSI.bar_char);
        }
        if (pair.death == std.math.inf(f64)) {
            try writer.writeAll(ANSI.arrow_right);
            try writer.writeAll(ANSI.infinity);
        } else {
            try writer.writeAll(ANSI.dot_death);
        }
        try writer.writeAll(ANSI.reset);

        // Annotation
        try writer.writeAll("  " ++ ANSI.dim);
        try writer.print("[{d:.3}, ", .{pair.birth});
        if (pair.death == std.math.inf(f64)) {
            try writer.writeAll(ANSI.infinity ++ ")");
        } else {
            try writer.print("{d:.3})", .{pair.death});
        }
        try writer.writeAll(ANSI.reset ++ "\n");
    }
}

// ============================================================================
// PERSISTENCE DIAGRAM (birth-death scatter plot)
// ============================================================================

fn renderScatterDiagram(writer: anytype, diagram: PersistenceDiagram, size: usize) !void {
    if (diagram.pairs.len == 0) return;

    try writer.writeAll("\n" ++ ANSI.bold ++ "\x1b[38;5;255m" ++ "  PERSISTENCE DIAGRAM" ++ ANSI.reset ++ "\n");

    var max_val: f64 = 0;
    for (diagram.pairs) |pair| {
        max_val = @max(max_val, pair.birth);
        if (pair.death != std.math.inf(f64)) {
            max_val = @max(max_val, pair.death);
        }
    }
    max_val *= 1.1;
    if (max_val == 0) max_val = 1;

    // Create grid
    var grid: [40][80]u8 = undefined;
    var color_grid: [40][80]usize = undefined;
    for (0..size) |r| {
        for (0..size * 2) |c| {
            grid[r][c] = ' ';
            color_grid[r][c] = 0;
        }
    }

    // Draw diagonal (birth = death line)
    for (0..@min(size, size * 2)) |i| {
        if (i < size and i * 2 < size * 2) {
            grid[size - 1 - i][i * 2] = '.';
        }
    }

    // Plot points
    for (diagram.pairs) |pair| {
        if (pair.death == std.math.inf(f64)) continue;

        const col = @as(usize, @intFromFloat(pair.birth / max_val * @as(f64, @floatFromInt(size * 2 - 1))));
        const row = size - 1 -| @as(usize, @intFromFloat(pair.death / max_val * @as(f64, @floatFromInt(size - 1))));

        if (row < size and col < size * 2) {
            grid[row][col] = '*';
            color_grid[row][col] = pair.dimension + 1;
        }
    }

    // Render
    try writer.writeAll("  " ++ ANSI.dim ++ "death" ++ ANSI.reset ++ "\n");
    try writer.print("  {d:.1} \xe2\x94\xa4", .{max_val});
    for (0..size * 2) |c| {
        const dim_idx = color_grid[0][c];
        if (dim_idx > 0) {
            try writer.writeAll(ANSI.dimColor(dim_idx - 1));
            try writer.writeByte(grid[0][c]);
            try writer.writeAll(ANSI.reset);
        } else {
            try writer.writeByte(grid[0][c]);
        }
    }
    try writer.writeAll("\n");

    for (1..size) |r| {
        try writer.writeAll("       \xe2\x94\x82");
        for (0..size * 2) |c| {
            const dim_idx = color_grid[r][c];
            if (dim_idx > 0) {
                try writer.writeAll(ANSI.dimColor(dim_idx - 1));
                try writer.writeByte(grid[r][c]);
                try writer.writeAll(ANSI.reset);
            } else {
                try writer.writeByte(grid[r][c]);
            }
        }
        try writer.writeAll("\n");
    }

    try writer.writeAll("       \xe2\x94\x94");
    for (0..size * 2) |_| try writer.writeAll("\xe2\x94\x80");
    try writer.writeAll("\n");
    try writer.writeAll("        0");
    for (0..size * 2 -| 6) |_| try writer.writeAll(" ");
    try writer.print("{d:.1}  " ++ ANSI.dim ++ "birth" ++ ANSI.reset ++ "\n", .{max_val});

    // Legend
    try writer.writeAll("\n  " ++ ANSI.bold ++ "Legend:" ++ ANSI.reset);
    var max_dim: usize = 0;
    for (diagram.pairs) |pair| max_dim = @max(max_dim, pair.dimension);
    for (0..max_dim + 1) |d| {
        try writer.writeAll("  ");
        try writer.writeAll(ANSI.dimColor(d));
        try writer.writeAll(ANSI.dot_birth ++ " ");
        try writer.writeAll(ANSI.dimLabel(d));
        try writer.writeAll(ANSI.reset);
    }
    try writer.writeAll("\n");
}

// ============================================================================
// BETTI NUMBER SUMMARY
// ============================================================================

fn renderBettiSummary(writer: anytype, diagram: PersistenceDiagram) !void {
    try writer.writeAll("\n" ++ ANSI.bold ++ "\x1b[38;5;255m" ++ "  BETTI NUMBERS" ++ ANSI.reset ++ "\n");

    var max_dim: usize = 0;
    for (diagram.pairs) |pair| max_dim = @max(max_dim, pair.dimension);

    for (0..max_dim + 1) |d| {
        var count: usize = 0;
        var essential: usize = 0;
        var max_persistence: f64 = 0;
        for (diagram.pairs) |pair| {
            if (pair.dimension == d) {
                count += 1;
                if (pair.death == std.math.inf(f64)) essential += 1;
                if (pair.death != std.math.inf(f64)) {
                    max_persistence = @max(max_persistence, pair.death - pair.birth);
                }
            }
        }

        try writer.writeAll("  ");
        try writer.writeAll(ANSI.dimColor(d));
        try writer.writeAll(ANSI.dimLabel(d));
        try writer.writeAll(ANSI.reset);
        try writer.print(": \xce\xb2 = {d}  ({d} pairs, {d} essential", .{
            essential,
            count,
            essential,
        });
        if (max_persistence > 0) {
            try writer.print(", max pers = {d:.4}", .{max_persistence});
        }
        try writer.writeAll(")\n");
    }
}

// ============================================================================
// SAMPLE DATA GENERATORS
// ============================================================================

fn generateCircleData() PersistenceDiagram {
    // Pre-computed persistence for a circle (8 points)
    // H₀: one component, H₁: one loop
    const pairs = comptime [_]PersistencePair{
        // H₀: 7 edges merge components, 1 essential
        .{ .birth = 0.0, .death = 0.765, .dimension = 0 },
        .{ .birth = 0.0, .death = 0.765, .dimension = 0 },
        .{ .birth = 0.0, .death = 0.765, .dimension = 0 },
        .{ .birth = 0.0, .death = 0.765, .dimension = 0 },
        .{ .birth = 0.0, .death = 0.765, .dimension = 0 },
        .{ .birth = 0.0, .death = 0.765, .dimension = 0 },
        .{ .birth = 0.0, .death = 0.765, .dimension = 0 },
        .{ .birth = 0.0, .death = std.math.inf(f64), .dimension = 0 }, // essential H₀

        // H₁: one significant loop
        .{ .birth = 0.765, .death = 2.0, .dimension = 1 },
    };
    return .{ .pairs = &pairs };
}

fn generateTorusData() PersistenceDiagram {
    // Pre-computed persistence for a torus
    // H₀ = 1, H₁ = 2, H₂ = 1
    const pairs = comptime [_]PersistencePair{
        // H₀
        .{ .birth = 0.0, .death = 0.3, .dimension = 0 },
        .{ .birth = 0.0, .death = 0.4, .dimension = 0 },
        .{ .birth = 0.0, .death = 0.5, .dimension = 0 },
        .{ .birth = 0.0, .death = std.math.inf(f64), .dimension = 0 },

        // H₁: two generators (meridian and longitude)
        .{ .birth = 0.5, .death = 1.8, .dimension = 1 },
        .{ .birth = 0.6, .death = 1.9, .dimension = 1 },
        .{ .birth = 0.3, .death = 0.45, .dimension = 1 }, // noise

        // H₂: one void
        .{ .birth = 1.0, .death = 2.5, .dimension = 2 },
    };
    return .{ .pairs = &pairs };
}

fn generateSphereData() PersistenceDiagram {
    // Persistence for a sphere: H₀ = 1, H₁ = 0, H₂ = 1
    const pairs = comptime [_]PersistencePair{
        .{ .birth = 0.0, .death = 0.5, .dimension = 0 },
        .{ .birth = 0.0, .death = 0.6, .dimension = 0 },
        .{ .birth = 0.0, .death = std.math.inf(f64), .dimension = 0 },

        // H₁: only noise
        .{ .birth = 0.8, .death = 0.85, .dimension = 1 },

        // H₂
        .{ .birth = 1.0, .death = 2.2, .dimension = 2 },
    };
    return .{ .pairs = &pairs };
}

// ============================================================================
// MAIN
// ============================================================================

pub fn main() !void {
    const stdout_file = std.fs.File{ .handle = std.posix.STDOUT_FILENO };
    const stdout = std.io.GenericWriter(std.fs.File, std.fs.File.WriteError, std.fs.File.write){ .context = stdout_file };

    try stdout.writeAll("\n\x1b[38;5;141m\xe2\x95\x94\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x97" ++ ANSI.reset ++ "\n");
    try stdout.writeAll("\x1b[38;5;141m\xe2\x95\x91  " ++ ANSI.bold ++ "\x1b[38;5;255m" ++ "zig-syrup persistence homology visualizer" ++ ANSI.reset ++ "\x1b[38;5;141m           \xe2\x95\x91" ++ ANSI.reset ++ "\n");
    try stdout.writeAll("\x1b[38;5;141m\xe2\x95\x9a\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x9d" ++ ANSI.reset ++ "\n");

    // Demo: Circle
    try stdout.writeAll("\n\x1b[38;5;45m" ++ "\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90 Circle (8 points on S\xc2\xb9) \xe2\x95\x90\xe2\x95\x90\xe2\x95\x90" ++ ANSI.reset ++ "\n");
    const circle = generateCircleData();
    try renderBarcodes(stdout, circle, 50);
    try renderBettiSummary(stdout, circle);

    // Demo: Torus
    try stdout.writeAll("\n\x1b[38;5;45m" ++ "\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90 Torus (T\xc2\xb2) \xe2\x95\x90\xe2\x95\x90\xe2\x95\x90" ++ ANSI.reset ++ "\n");
    const torus = generateTorusData();
    try renderBarcodes(stdout, torus, 50);
    try renderScatterDiagram(stdout, torus, 15);
    try renderBettiSummary(stdout, torus);

    // Demo: Sphere
    try stdout.writeAll("\n\x1b[38;5;45m" ++ "\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90 Sphere (S\xc2\xb2) \xe2\x95\x90\xe2\x95\x90\xe2\x95\x90" ++ ANSI.reset ++ "\n");
    const sphere = generateSphereData();
    try renderBarcodes(stdout, sphere, 50);
    try renderBettiSummary(stdout, sphere);

    // GF(3) trit summary
    try stdout.writeAll("\n" ++ ANSI.bold ++ "\x1b[38;5;255m" ++ "  GF(3) TRIT CLASSIFICATION" ++ ANSI.reset ++ "\n");
    try stdout.writeAll("  Birth events  \xe2\x86\x92 +1 (plus)\n");
    try stdout.writeAll("  Death events  \xe2\x86\x92 -1 (minus)\n");
    try stdout.writeAll("  Unpaired      \xe2\x86\x92  0 (zero)\n");

    var trit_sum: i32 = 0;
    for (torus.pairs) |pair| {
        trit_sum += 1; // birth
        if (pair.death != std.math.inf(f64)) {
            trit_sum -= 1; // death
        }
    }
    try stdout.print("  \xce\xa3 trits (torus) = {d} (conservation: essential classes)\n\n", .{trit_sum});
}
