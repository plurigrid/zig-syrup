//! Colored Parentheses Demo
//!
//! Demonstrates referentially transparent coloring of nested S-expressions
//! based on GF(3) operadic composition.

const std = @import("std");
const lux_color = @import("lux_color.zig");

const Trit = lux_color.Trit;
const ExprColor = lux_color.ExprColor;
const RGB = lux_color.RGB;

/// S-expression tree node for demo
const Expr = union(enum) {
    atom: []const u8,
    list: struct {
        op: []const u8,
        args: []const Expr,
    },
};

/// Metadata: operation name → GF(3) trit
const OpTrit = struct {
    name: []const u8,
    trit: Trit,
};

const OPERATION_TRITS = [_]OpTrit{
    // BCI Pipeline operations
    .{ .name = "fisher_rao_distance", .trit = .minus },
    .{ .name = "sigmoid", .trit = .minus },
    .{ .name = "golden_spiral_color", .trit = .ergodic },
    .{ .name = "aptos_commit_color", .trit = .plus },

    // Generic operations
    .{ .name = "compose", .trit = .ergodic },
    .{ .name = "map", .trit = .ergodic },
    .{ .name = "filter", .trit = .minus },
    .{ .name = "reduce", .trit = .plus },
};

fn lookupTrit(op_name: []const u8) Trit {
    for (OPERATION_TRITS) |entry| {
        if (std.mem.eql(u8, entry.name, op_name)) {
            return entry.trit;
        }
    }
    return .ergodic; // Default for unknown ops
}

/// Render expression with colored parentheses
fn renderColoredExpr(
    expr: Expr,
    depth: u16,
    writer: anytype,
) !void {
    var ansi_buf: [19]u8 = undefined;

    switch (expr) {
        .atom => |name| {
            try writer.print("{s}", .{name});
        },
        .list => |list| {
            const op_trit = lookupTrit(list.op);
            const color = ExprColor.init(op_trit, depth);

            // Opening paren with color
            const open_ansi = color.rgb.toAnsiFg(&ansi_buf);
            try writer.print("{s}({s}", .{ open_ansi, "\x1b[0m" }); // Color then reset

            // Operation name
            try writer.print("{s}", .{list.op});

            // Recursive render args
            for (list.args) |arg| {
                try writer.print(" ", .{});
                try renderColoredExpr(arg, depth + 1, writer);
            }

            // Closing paren with same color
            const close_ansi = color.rgb.toAnsiFg(&ansi_buf);
            try writer.print("{s}){s}", .{ close_ansi, "\x1b[0m" });
        },
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const stdout = std.io.getStdOut().writer();

    try stdout.print("\n=== Colored Parentheses Demo ===\n\n", .{});

    // Example 1: Simple nested expression
    const simple = Expr{
        .list = .{
            .op = "compose",
            .args = &[_]Expr{
                .{ .atom = "f" },
                .{ .atom = "g" },
            },
        },
    };

    try stdout.print("Simple: ", .{});
    try renderColoredExpr(simple, 0, stdout);
    try stdout.print("\n\n", .{});

    // Example 2: BCI Pipeline (from tests)
    const eeg_data = Expr{ .atom = "eeg_data" };

    const fisher_rao = Expr{
        .list = .{
            .op = "fisher_rao_distance",
            .args = &[_]Expr{eeg_data},
        },
    };

    const sigmoid_expr = Expr{
        .list = .{
            .op = "sigmoid",
            .args = &[_]Expr{fisher_rao},
        },
    };

    const golden_expr = Expr{
        .list = .{
            .op = "golden_spiral_color",
            .args = &[_]Expr{sigmoid_expr},
        },
    };

    const aptos_expr = Expr{
        .list = .{
            .op = "aptos_commit_color",
            .args = &[_]Expr{golden_expr},
        },
    };

    try stdout.print("BCI Pipeline:\n", .{});
    try renderColoredExpr(aptos_expr, 0, stdout);
    try stdout.print("\n\n", .{});

    // Example 3: Show color computation trace
    try stdout.print("Color Trace:\n", .{});
    try stdout.print("─────────────────────────────────────────────\n", .{});
    try stdout.print("Depth  Operation              Trit   Hue\n", .{});
    try stdout.print("─────────────────────────────────────────────\n", .{});

    const ops = [_]struct { name: []const u8, trit: Trit }{
        .{ .name = "fisher_rao_distance", .trit = .minus },
        .{ .name = "sigmoid", .trit = .minus },
        .{ .name = "golden_spiral_color", .trit = .ergodic },
        .{ .name = "aptos_commit_color", .trit = .plus },
    };

    for (ops, 0..) |op, i| {
        const color = ExprColor.init(op.trit, @intCast(i));
        const trit_name = switch (op.trit) {
            .minus => "MINUS ",
            .ergodic => "ERGODIC",
            .plus => "PLUS  ",
        };

        // Show color swatch
        var swatch_buf: [19]u8 = undefined;
        const swatch_ansi = color.rgb.toAnsiFg(&swatch_buf);

        try stdout.print("{d}      {s:<22} {s} {s}█████{s}  {d:.1}°\n", .{
            i,
            op.name,
            trit_name,
            swatch_ansi,
            "\x1b[0m",
            color.hue,
        });
    }

    try stdout.print("─────────────────────────────────────────────\n\n", .{});

    // Example 4: Conservation test
    try stdout.print("GF(3) Conservation Test:\n", .{});
    const test_triad = [_]Trit{ .minus, .ergodic, .plus };
    const conserved = Trit.conserved(&test_triad);
    try stdout.print("Triad: [MINUS, ERGODIC, PLUS] → ", .{});
    if (conserved) {
        try stdout.print("\x1b[32m✓ CONSERVED\x1b[0m\n", .{});
    } else {
        try stdout.print("\x1b[31m✗ NOT CONSERVED\x1b[0m\n", .{});
    }

    try stdout.print("\n", .{});

    _ = allocator;
}
