///! salon_demo.zig — Live 3-chair BCI salon grid renderer
///!
///! Modes:
///!   simulate  — run synthetic BCI profiles through the grid (no hardware needed)
///!   pipe      — read JSON epochs from stdin, render each one
///!   snapshot  — render one frame from stdin JSON, print Syrup CID, exit
///!
///! Usage:
///!   zig-out/bin/salon simulate
///!   echo '{"A":[0.1,0.2,0.3,0.7,0.5],"B":[0.3,0.3,0.8,0.2,0.1],"C":[0.5,0.9,0.4,0.1,0.05]}' | zig-out/bin/salon pipe
///!   echo '...' | zig-out/bin/salon snapshot

const std = @import("std");
const compat = @import("compat.zig");
const salon = @import("salon.zig");

const Grid = salon.Grid;
const BandPowers = salon.BandPowers;
const Chair = salon.Chair;
const RGB = salon.RGB;

pub fn main() !void {
    var gpa = compat.makeDebugAllocator();
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var stdout = CompatWriter{};

    if (args.len < 2) {
        try printUsage(stdout);
        return;
    }

    const mode = args[1];

    if (std.mem.eql(u8, mode, "simulate")) {
        try runSimulation(stdout);
    } else if (std.mem.eql(u8, mode, "snapshot")) {
        try runSnapshot(allocator, stdout);
    } else if (std.mem.eql(u8, mode, "grid")) {
        try renderEmptyGrid(stdout);
    } else {
        try printUsage(stdout);
    }
}

fn printUsage(w: anytype) !void {
    try w.writeAll(
        \\salon — 3-Chair BCI Installation Grid
        \\
        \\Usage:
        \\  salon simulate    Run 20-epoch synthetic simulation with ANSI rendering
        \\  salon snapshot    Read one JSON epoch from stdin, render + print CID
        \\  salon grid        Render empty grid layout
        \\
        \\JSON epoch format:
        \\  {"A":[delta,theta,alpha,beta,gamma],"B":[...],"C":[...]}
        \\
        \\Chair roles:
        \\  A = Generator (+1)    B = Coordinator (0)    C = Validator (-1)
        \\
    );
}

// ============================================================
// Simulation: 20 epochs of synthetic BCI state transitions
// ============================================================

const Profile = struct {
    label: []const u8,
    a: BandPowers,
    b: BandPowers,
    c: BandPowers,
};

const simulation_profiles = [_]Profile{
    // Phase 1: All resting (baseline calibration)
    .{ .label = "baseline", .a = resting, .b = resting, .c = resting },
    .{ .label = "baseline", .a = resting, .b = resting, .c = resting },
    // Phase 2: A begins to focus
    .{ .label = "A warming up", .a = .{ .delta = 0.2, .theta = 0.25, .alpha = 0.6, .beta = 0.4, .gamma = 0.2 }, .b = resting, .c = resting },
    .{ .label = "A focusing", .a = focused, .b = resting, .c = resting },
    .{ .label = "A deep focus", .a = .{ .delta = 0.05, .theta = 0.1, .alpha = 0.2, .beta = 0.8, .gamma = 0.6 }, .b = resting, .c = resting },
    // Phase 3: C drifts off
    .{ .label = "C drowsing", .a = focused, .b = resting, .c = drowsy },
    .{ .label = "C deep drowsy", .a = focused, .b = resting, .c = .{ .delta = 0.6, .theta = 1.0, .alpha = 0.3, .beta = 0.05, .gamma = 0.02 } },
    // Phase 4: B enters meditation
    .{ .label = "B meditating", .a = focused, .b = meditative, .c = drowsy },
    .{ .label = "B deep meditate", .a = focused, .b = .{ .delta = 0.15, .theta = 0.7, .alpha = 1.0, .beta = 0.08, .gamma = 0.03 }, .c = drowsy },
    // Phase 5: Triadic divergence (maximum color contrast)
    .{ .label = "DIVERGENCE", .a = .{ .delta = 0.05, .theta = 0.1, .alpha = 0.15, .beta = 0.9, .gamma = 0.8 }, .b = .{ .delta = 0.1, .theta = 0.8, .alpha = 1.0, .beta = 0.05, .gamma = 0.02 }, .c = .{ .delta = 0.7, .theta = 1.0, .alpha = 0.2, .beta = 0.03, .gamma = 0.01 } },
    .{ .label = "DIVERGENCE peak", .a = .{ .delta = 0.02, .theta = 0.05, .alpha = 0.1, .beta = 1.0, .gamma = 0.9 }, .b = .{ .delta = 0.15, .theta = 0.9, .alpha = 1.0, .beta = 0.05, .gamma = 0.01 }, .c = .{ .delta = 0.8, .theta = 1.0, .alpha = 0.15, .beta = 0.02, .gamma = 0.01 } },
    // Phase 6: Convergence begins
    .{ .label = "converging", .a = .{ .delta = 0.15, .theta = 0.3, .alpha = 0.5, .beta = 0.5, .gamma = 0.4 }, .b = .{ .delta = 0.2, .theta = 0.5, .alpha = 0.7, .beta = 0.2, .gamma = 0.1 }, .c = .{ .delta = 0.4, .theta = 0.5, .alpha = 0.5, .beta = 0.15, .gamma = 0.1 } },
    .{ .label = "converging", .a = .{ .delta = 0.2, .theta = 0.35, .alpha = 0.6, .beta = 0.4, .gamma = 0.3 }, .b = .{ .delta = 0.25, .theta = 0.4, .alpha = 0.65, .beta = 0.25, .gamma = 0.15 }, .c = .{ .delta = 0.3, .theta = 0.4, .alpha = 0.55, .beta = 0.2, .gamma = 0.15 } },
    // Phase 7: Collective resonance (all similar)
    .{ .label = "RESONANCE", .a = resonant, .b = resonant, .c = resonant },
    .{ .label = "RESONANCE", .a = resonant, .b = resonant, .c = resonant },
    // Phase 8: A stressed, disruption
    .{ .label = "A stressed!", .a = stressed, .b = resonant, .c = resonant },
    .{ .label = "disruption", .a = stressed, .b = .{ .delta = 0.3, .theta = 0.3, .alpha = 0.5, .beta = 0.4, .gamma = 0.3 }, .c = .{ .delta = 0.35, .theta = 0.35, .alpha = 0.5, .beta = 0.35, .gamma = 0.25 } },
    // Phase 9: Recovery
    .{ .label = "recovering", .a = .{ .delta = 0.2, .theta = 0.3, .alpha = 0.5, .beta = 0.5, .gamma = 0.3 }, .b = resting, .c = resting },
    .{ .label = "recovered", .a = resting, .b = resting, .c = resting },
    .{ .label = "final rest", .a = resting, .b = resting, .c = resting },
};

const resting = BandPowers{ .delta = 0.3, .theta = 0.3, .alpha = 0.8, .beta = 0.2, .gamma = 0.1 };
const focused = BandPowers{ .delta = 0.1, .theta = 0.2, .alpha = 0.3, .beta = 0.7, .gamma = 0.5 };
const drowsy = BandPowers{ .delta = 0.5, .theta = 0.9, .alpha = 0.4, .beta = 0.1, .gamma = 0.05 };
const meditative = BandPowers{ .delta = 0.2, .theta = 0.6, .alpha = 0.9, .beta = 0.1, .gamma = 0.05 };
const stressed = BandPowers{ .delta = 0.2, .theta = 0.1, .alpha = 0.1, .beta = 0.9, .gamma = 0.7 };
const resonant = BandPowers{ .delta = 0.25, .theta = 0.35, .alpha = 0.7, .beta = 0.3, .gamma = 0.2 };

fn runSimulation(w: anytype) !void {
    var grid = Grid.init();

    for (simulation_profiles, 0..) |prof, epoch| {
        grid.updateChair(0, prof.a);
        grid.updateChair(1, prof.b);
        grid.updateChair(2, prof.c);

        // Clear screen and render
        try w.writeAll("\x1b[2J\x1b[H");
        try w.print("  Salon BCI Grid  |  epoch {d}/20  |  {s}\n", .{ epoch, prof.label });
        try renderChairStatus(w, &grid);
        try w.writeByte('\n');
        try renderGrid(w, &grid);
        try renderStats(w, &grid);
        try w.writeAll("\n  Press Ctrl-C to exit\n");

        // Sleep 800ms between frames
        std.Thread.sleep(800 * std.time.ns_per_ms);
    }

    // Final summary
    try w.writeAll("\n  Simulation complete. 20 epochs rendered.\n");
}

fn runSnapshot(allocator: std.mem.Allocator, w: anytype) !void {
    const input = try readAllStdin(allocator, 1024 * 1024);
    defer allocator.free(input);

    // Parse JSON: {"A":[d,t,a,b,g],"B":[...],"C":[...]}
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, input, .{}) catch {
        try w.writeAll("Error: invalid JSON. Expected: {\"A\":[d,t,a,b,g],\"B\":[...],\"C\":[...]}\n");
        return;
    };
    defer parsed.deinit();

    const root = parsed.value.object;

    var grid = Grid.init();

    if (root.get("A")) |a_val| {
        grid.updateChair(0, parseBands(a_val));
    }
    if (root.get("B")) |b_val| {
        grid.updateChair(1, parseBands(b_val));
    }
    if (root.get("C")) |c_val| {
        grid.updateChair(2, parseBands(c_val));
    }

    try renderChairStatus(w, &grid);
    try w.writeByte('\n');
    try renderGrid(w, &grid);
    try renderStats(w, &grid);

    // Compute CID
    var json_buf: [16384]u8 = undefined;
    const json_out = try grid.toJson(&json_buf);
    var hasher = std.crypto.hash.Blake3.init(.{});
    hasher.update(json_out);
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    try w.writeAll("\n  CID (blake3 of grid JSON): ");
    for (digest) |byte| {
        try w.print("{x:0>2}", .{byte});
    }
    try w.writeByte('\n');
}

fn parseBands(val: std.json.Value) BandPowers {
    if (val != .array) return resting;
    const arr = val.array;
    if (arr.items.len < 5) return resting;
    return .{
        .delta = jsonFloat(arr.items[0]),
        .theta = jsonFloat(arr.items[1]),
        .alpha = jsonFloat(arr.items[2]),
        .beta = jsonFloat(arr.items[3]),
        .gamma = jsonFloat(arr.items[4]),
    };
}

fn jsonFloat(v: std.json.Value) f32 {
    return switch (v) {
        .float => |f| @floatCast(f),
        .integer => |i| @floatFromInt(i),
        else => 0.0,
    };
}

/// Zig 0.16 compat: stdout writer without deprecatedWriter.
const CompatWriter = struct {
    pub const Error = error{};
    pub fn writeAll(self: *CompatWriter, bytes: []const u8) Error!void {
        _ = self;
        compat.stdoutWrite(bytes);
    }
    pub fn writeByte(self: *CompatWriter, byte: u8) Error!void {
        try self.writeAll(&.{byte});
    }
    pub fn writeBytesNTimes(self: *CompatWriter, bytes: []const u8, n: usize) Error!void {
        for (0..n) |_| try self.writeAll(bytes);
    }
    pub fn print(self: *CompatWriter, comptime fmt: []const u8, args: anytype) Error!void {
        std.fmt.format(self, fmt, args) catch {};
    }
    pub fn writeByteNTimes(self: *CompatWriter, byte: u8, n: usize) Error!void {
        var buf: [256]u8 = undefined;
        const fill = @min(n, buf.len);
        @memset(buf[0..fill], byte);
        var remaining = n;
        while (remaining > 0) {
            const chunk = @min(remaining, buf.len);
            try self.writeAll(buf[0..chunk]);
            remaining -= chunk;
        }
    }
};

/// Read all of stdin into an allocated buffer (compat: no readToEndAlloc).
fn readAllStdin(allocator: std.mem.Allocator, max_bytes: usize) ![]u8 {
    var buf = std.ArrayList(u8).init(allocator);
    errdefer buf.deinit();
    var tmp: [4096]u8 = undefined;
    while (true) {
        const n = compat.stdinRead(&tmp);
        if (n == 0) break;
        if (buf.items.len + n > max_bytes) return error.StreamTooLong;
        try buf.appendSlice(tmp[0..n]);
    }
    return buf.toOwnedSlice();
}

// ============================================================
// ANSI terminal rendering
// ============================================================

fn renderChairStatus(w: anytype, grid: *const Grid) !void {
    for (grid.chairs) |chair| {
        const c = chair.role.color();
        const st = chair.state;
        const band = chair.bands.dominant();
        try w.print("  \x1b[48;2;{d};{d};{d}m  \x1b[0m {s}  phi={d:.2} val={d:.2} ent={d:.2} trit={d: >2} dom={s}\n", .{
            c.r,        c.g,        c.b,
            chair.role.label(),
            st.phi,     st.valence, st.entropy,
            @as(i8, st.trit),
            band,
        });
    }
}

fn renderGrid(w: anytype, grid: *const Grid) !void {
    // Top border
    try w.writeAll("  ┌");
    for (0..salon.GRID_COLS) |_| try w.writeAll("──");
    try w.writeAll("┐\n");

    for (0..salon.GRID_ROWS) |row| {
        try w.writeAll("  │");
        for (0..salon.GRID_COLS) |col| {
            const cell = grid.cells[row * salon.GRID_COLS + col];
            try w.print("\x1b[48;2;{d};{d};{d}m  \x1b[0m", .{
                cell.color.r, cell.color.g, cell.color.b,
            });
        }
        try w.writeAll("│\n");
    }

    // Bottom border
    try w.writeAll("  └");
    for (0..salon.GRID_COLS) |_| try w.writeAll("──");
    try w.writeAll("┘\n");
}

fn renderStats(w: anytype, grid: *const Grid) !void {
    const dist = grid.gf3Distribution();
    try w.print("  GF(3): \x1b[32m+{d}\x1b[0m / \x1b[33m0:{d}\x1b[0m / \x1b[31m-{d}\x1b[0m  balanced={}\n", .{
        dist.plus, dist.ergodic, dist.minus, dist.balanced,
    });
}

fn renderEmptyGrid(w: anytype) !void {
    const grid = Grid.init();
    try w.writeAll("  Salon BCI Grid — 9x9 (81 cells), 3 chairs\n\n");
    try renderChairStatus(w, &grid);
    try w.writeByte('\n');
    try renderGrid(w, &grid);
    try renderStats(w, &grid);
    try w.writeAll("\n  Chair positions: A(3,3) B(4,3) C(3,4) — triangle formation\n");
    try w.writeAll("  Influence: inverse-square distance, normalized per cell\n");
}
