//! Colored Parentheses World
//!
//! A world where S-expressions are rendered with referentially transparent
//! colored parentheses based on GF(3) operadic composition.
//!
//! URI scheme: colored://parens?expr=<expression>&depth=<max_depth>
//!
//! World variants:
//! - a://colored/parens - Golden angle progression (137.5°)
//! - b://colored/parens - Plastic angle progression (205.14°)
//! - c://colored/parens - Silver angle progression (149.07°)

const std = @import("std");
const lux_color = @import("lux_color");
const world = @import("world.zig");

const Trit = lux_color.Trit;
const ExprColor = lux_color.ExprColor;
const RGB = lux_color.RGB;
const WorldVariant = world.WorldVariant;

/// S-expression tree node
pub const Expr = union(enum) {
    atom: []const u8,
    list: struct {
        op: []const u8,
        args: []const Expr,
    },

    pub fn deinit(self: Expr, allocator: std.mem.Allocator) void {
        switch (self) {
            .atom => {},
            .list => |list| {
                for (list.args) |arg| {
                    arg.deinit(allocator);
                }
                allocator.free(list.args);
            },
        }
    }
};

/// Operation metadata: name → GF(3) trit
const OpTrit = struct {
    name: []const u8,
    trit: Trit,
};

const OPERATION_TRITS = [_]OpTrit{
    // BCI Pipeline
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
    return .ergodic;
}

/// Angle progression strategy based on world variant
fn angleForVariant(variant: WorldVariant) f32 {
    return switch (variant) {
        .A => lux_color.GOLDEN_ANGLE, // 137.5°
        .B => lux_color.PLASTIC_ANGLE, // 205.14°
        .C => lux_color.SILVER_ANGLE, // 149.07°
    };
}

/// Colored Parentheses World State
pub const ColoredParensWorld = struct {
    allocator: std.mem.Allocator,
    variant: WorldVariant,
    angle: f32,
    root_expr: ?Expr,
    output_buffer: std.ArrayListUnmanaged(u8),

    pub fn init(allocator: std.mem.Allocator, variant: WorldVariant) !*ColoredParensWorld {
        const self = try allocator.create(ColoredParensWorld);
        self.* = .{
            .allocator = allocator,
            .variant = variant,
            .angle = angleForVariant(variant),
            .root_expr = null,
            .output_buffer = .{},
        };
        return self;
    }

    pub fn deinit(self: *ColoredParensWorld) void {
        if (self.root_expr) |expr| {
            expr.deinit(self.allocator);
        }
        self.output_buffer.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    /// Set expression to render
    pub fn setExpression(self: *ColoredParensWorld, expr: Expr) void {
        if (self.root_expr) |old| {
            old.deinit(self.allocator);
        }
        self.root_expr = expr;
    }

    /// Render the expression with colored parentheses to internal buffer
    pub fn render(self: *ColoredParensWorld) !void {
        self.output_buffer.clearRetainingCapacity();
        const writer = self.output_buffer.writer(self.allocator);

        if (self.root_expr) |expr| {
            try self.renderExpr(expr, 0, writer);
        }
    }

    /// Get rendered output
    pub fn getOutput(self: *const ColoredParensWorld) []const u8 {
        return self.output_buffer.items;
    }

    fn renderExpr(
        self: *ColoredParensWorld,
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
                const color = self.computeColor(op_trit, depth);

                // Opening paren with color
                const open_ansi = color.rgb.toAnsiFg(&ansi_buf);
                try writer.print("{s}({s}", .{ open_ansi, "\x1b[0m" });

                // Operation name
                try writer.print("{s}", .{list.op});

                // Recursive render args
                for (list.args) |arg| {
                    try writer.print(" ", .{});
                    try self.renderExpr(arg, depth + 1, writer);
                }

                // Closing paren with same color
                const close_ansi = color.rgb.toAnsiFg(&ansi_buf);
                try writer.print("{s}){s}", .{ close_ansi, "\x1b[0m" });
            },
        }
    }

    fn computeColor(self: *ColoredParensWorld, trit: Trit, depth: u16) ExprColor {
        const base = trit.baseHue();
        const rotation = @as(f32, @floatFromInt(depth)) * self.angle;
        const hue = @mod(base + rotation, 360.0);

        const hcl = lux_color.HCL{
            .h = hue,
            .c = 0.6,
            .l = 0.6,
        };
        const rgb = hcl.toRGB();

        return .{
            .trit = trit,
            .depth = depth,
            .hue = hue,
            .rgb = rgb,
        };
    }

    /// Build BCI pipeline example
    pub fn bciPipeline(allocator: std.mem.Allocator) !Expr {
        const eeg_data = Expr{ .atom = "eeg_data" };

        const fisher_args = try allocator.alloc(Expr, 1);
        fisher_args[0] = eeg_data;
        const fisher_rao = Expr{
            .list = .{
                .op = "fisher_rao_distance",
                .args = fisher_args,
            },
        };

        const sigmoid_args = try allocator.alloc(Expr, 1);
        sigmoid_args[0] = fisher_rao;
        const sigmoid_expr = Expr{
            .list = .{
                .op = "sigmoid",
                .args = sigmoid_args,
            },
        };

        const golden_args = try allocator.alloc(Expr, 1);
        golden_args[0] = sigmoid_expr;
        const golden_expr = Expr{
            .list = .{
                .op = "golden_spiral_color",
                .args = golden_args,
            },
        };

        const aptos_args = try allocator.alloc(Expr, 1);
        aptos_args[0] = golden_expr;
        return Expr{
            .list = .{
                .op = "aptos_commit_color",
                .args = aptos_args,
            },
        };
    }
};

// =============================================================================
// Tests
// =============================================================================

test "colored parens world golden angle" {
    const allocator = std.testing.allocator;

    var w = try ColoredParensWorld.init(allocator, .A);
    defer w.deinit();

    try std.testing.expectEqual(WorldVariant.A, w.variant);
    try std.testing.expectApproxEqAbs(lux_color.GOLDEN_ANGLE, w.angle, 0.001);
}

test "colored parens world BCI pipeline" {
    const allocator = std.testing.allocator;

    var w = try ColoredParensWorld.init(allocator, .A);
    defer w.deinit();

    const expr = try ColoredParensWorld.bciPipeline(allocator);
    w.setExpression(expr);

    try w.render();
    const output = w.getOutput();

    try std.testing.expect(output.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, output, "aptos_commit_color") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "eeg_data") != null);
}

test "colored parens three world variants" {
    const allocator = std.testing.allocator;

    const variants = [_]WorldVariant{ .A, .B, .C };
    for (variants) |v| {
        var w = try ColoredParensWorld.init(allocator, v);
        defer w.deinit();

        const expr = try ColoredParensWorld.bciPipeline(allocator);
        w.setExpression(expr);

        try w.render();
        const output = w.getOutput();

        try std.testing.expect(output.len > 0);
    }
}

// =============================================================================
// Fuzz Tests
// =============================================================================

test "fuzz: random expressions render without crash" {
    try std.testing.fuzz({}, struct {
        fn testOne(_: void, input: []const u8) anyerror!void {
            if (input.len < 3) return;

            const variant: WorldVariant = switch (input[0] % 3) {
                0 => .A,
                1 => .B,
                2 => .C,
                else => unreachable,
            };
            const depth = input[1] % 5; // 0-4 nesting depth
            const op_idx = input[2];

            const allocator = std.testing.allocator;

            var w = try ColoredParensWorld.init(allocator, variant);
            defer w.deinit();

            // Build a random expression tree from fuzz input
            const expr = try buildFuzzExpr(allocator, input[3..], depth, op_idx);
            w.setExpression(expr);

            try w.render();
            const output = w.getOutput();

            // Must produce some output (at minimum the atom name)
            if (output.len == 0) return error.EmptyOutput;
        }
    }.testOne, .{});
}

test "fuzz: trit lookup always returns valid trit" {
    try std.testing.fuzz({}, struct {
        fn testOne(_: void, input: []const u8) anyerror!void {
            // Any arbitrary string as op name should return a valid trit
            const trit = lookupTrit(input);
            const v = @intFromEnum(trit);
            if (v < -1 or v > 1) return error.InvalidTrit;
        }
    }.testOne, .{});
}

test "fuzz: computeColor produces valid RGB for any depth" {
    try std.testing.fuzz({}, struct {
        fn testOne(_: void, input: []const u8) anyerror!void {
            if (input.len < 4) return;

            const variant: WorldVariant = switch (input[0] % 3) {
                0 => .A,
                1 => .B,
                2 => .C,
                else => unreachable,
            };
            const trit: Trit = switch (input[1] % 3) {
                0 => .minus,
                1 => .ergodic,
                2 => .plus,
                else => unreachable,
            };
            const depth = std.mem.readInt(u16, input[2..4][0..2], .little);

            const allocator = std.testing.allocator;
            var w = try ColoredParensWorld.init(allocator, variant);
            defer w.deinit();

            const color = w.computeColor(trit, depth);

            if (color.rgb.r > 255 or color.rgb.g > 255 or color.rgb.b > 255)
                return error.InvalidRGB;
            if (std.math.isNan(color.hue) or std.math.isInf(color.hue))
                return error.InvalidHue;
        }
    }.testOne, .{});
}

/// Build a fuzz-driven expression tree
fn buildFuzzExpr(allocator: std.mem.Allocator, input: []const u8, max_depth: u8, seed: u8) !Expr {
    if (max_depth == 0 or input.len == 0) {
        return Expr{ .atom = "x" };
    }

    const ops = [_][]const u8{
        "compose",          "map",       "filter",
        "reduce",           "sigmoid",   "fisher_rao_distance",
        "golden_spiral_color", "aptos_commit_color",
    };
    const op = ops[seed % ops.len];

    const n_args = @min((seed / 8) % 3 + 1, 3); // 1-3 args
    const args = try allocator.alloc(Expr, n_args);

    for (args, 0..) |*arg, i| {
        const sub_input = if (input.len > i + 1) input[i + 1 ..] else input[0..0];
        const sub_seed = if (input.len > i) input[i] else 0;
        arg.* = try buildFuzzExpr(allocator, sub_input, max_depth - 1, sub_seed);
    }

    return Expr{ .list = .{ .op = op, .args = args } };
}
