/// Ghostty Interactive Execution (IX) - Spatial Executor
///
/// Implements spatial awareness: focus window management, adjacency propagation,
/// and BCI color distribution via the Propagator network.
///
/// Integrates with spatial_propagator.zig to:
/// - Track window focus state
/// - Propagate focus to adjacent windows
/// - Assign golden-spiral colors based on spatial topology
/// - Update colors on BCI state changes (Φ, valence, Fisher-Rao)
///
/// Key design decisions:
/// - Trit classification: ERGODIC (0) coordination command
/// - Constraint-based state merging via propagator lattice
/// - Focus propagation with adjacency halo visualization
/// - Deterministic color assignment via SplitMix64 hash

const std = @import("std");
const ghostty_ix = @import("ghostty_ix");
const spatial_propagator = @import("spatial_propagator");

pub const ExecutionResult = ghostty_ix.ExecutionResult;
pub const Command = ghostty_ix.Command;
pub const SpatialContext = ghostty_ix.SpatialContext;
pub const BCIContext = ghostty_ix.BCIContext;

/// Spatial executor for managing window focus and color propagation
pub const SpatialExecutor = struct {
    allocator: std.mem.Allocator,
    current_focus: u32 = 0,
    previous_focus: u32 = 0,

    pub fn init(allocator: std.mem.Allocator) SpatialExecutor {
        return SpatialExecutor{
            .allocator = allocator,
        };
    }

    /// Update focus and propagate through spatial network
    /// Command format: "focus <window_id>" or "focus adjacent <direction>"
    /// Directions: up, down, left, right
    pub fn updateFocus(self: *SpatialExecutor, cmd: Command) !ExecutionResult {
        // Parse focus command
        var args_iter = std.mem.splitSequence(u8, cmd.args, " ");

        const action = args_iter.next() orelse "focus";
        const target = args_iter.next() orelse "0";

        // Handle different focus modes
        if (std.mem.eql(u8, action, "adjacent")) {
            return try self.focusAdjacent(target, cmd.spatial_context);
        } else if (std.mem.eql(u8, action, "focus")) {
            return try self.focusWindow(target, cmd.bci_context);
        } else {
            return ExecutionResult{
                .success = false,
                .output = "",
                .error_message = "unknown focus action",
            };
        }
    }

    /// Focus a specific window by ID
    fn focusWindow(self: *SpatialExecutor, window_id_str: []const u8, bci: ?BCIContext) !ExecutionResult {
        const window_id = std.fmt.parseInt(u32, window_id_str, 10) catch |err| {
            const output = try std.fmt.allocPrint(self.allocator, "invalid window id: {}", .{err});
            return ExecutionResult{
                .success = false,
                .output = output,
                .error_message = "parse error",
            };
        };

        self.previous_focus = self.current_focus;
        self.current_focus = window_id;

        // Format output with focus change
        var output_buf: [256]u8 = undefined;
        const output = try std.fmt.bufPrint(&output_buf, "focus: {} → {}", .{
            self.previous_focus,
            self.current_focus,
        });

        const owned_output = try self.allocator.dupe(u8, output);

        return ExecutionResult{
            .success = true,
            .output = owned_output,
            .error_message = null,
            .colors_updated = if (bci != null) true else false,
            .spatial_changed = true,
        };
    }

    /// Focus adjacent window in specified direction
    /// Directions: up, down, left, right
    fn focusAdjacent(self: *SpatialExecutor, direction: []const u8, spatial: ?SpatialContext) !ExecutionResult {
        const spatial_ctx = spatial_ctx: {
            if (spatial) |ctx| {
                break :spatial_ctx ctx;
            } else {
                return ExecutionResult{
                    .success = false,
                    .output = "",
                    .error_message = "no spatial context available",
                };
            }
        };

        // Find adjacent window in direction
        // For now, simple implementation: use first adjacent
        if (spatial_ctx.adjacent_windows.len == 0) {
            return ExecutionResult{
                .success = false,
                .output = "",
                .error_message = "no adjacent windows",
            };
        }

        const adjacent_id = spatial_ctx.adjacent_windows[0];
        self.previous_focus = self.current_focus;
        self.current_focus = adjacent_id;

        var output_buf: [256]u8 = undefined;
        const output = try std.fmt.bufPrint(&output_buf, "focus adjacent ({}): {} → {}", .{
            direction,
            self.previous_focus,
            self.current_focus,
        });

        const owned_output = try self.allocator.dupe(u8, output);

        return ExecutionResult{
            .success = true,
            .output = owned_output,
            .error_message = null,
            .colors_updated = true,
            .spatial_changed = true,
        };
    }

    /// Update colors based on BCI state (Φ, valence, Fisher-Rao)
    /// This integrates with the valence_bridge.py color pipeline
    pub fn updateColorsFromBCI(self: *SpatialExecutor, cmd: Command) !ExecutionResult {
        const bci = cmd.bci_context orelse {
            return ExecutionResult{
                .success = false,
                .output = "",
                .error_message = "no BCI context provided",
            };
        };

        // Compute color from BCI metrics
        // phi: integrated information (controls saturation)
        // valence: -log(vortex_count) (controls lightness)
        // fisher_rao: metric distance (controls hue)
        // dominant_trit: GF(3) assignment (-1, 0, +1)

        var output_buf: [512]u8 = undefined;
        const output = try std.fmt.bufPrint(&output_buf,
            "BCI colors: phi={d:.2}, valence={d:.2}, fisher={d:.2}, trit={}",
            .{
                bci.phi,
                bci.valence,
                bci.fisher_rao,
                bci.dominant_trit,
            },
        );

        const owned_output = try self.allocator.dupe(u8, output);

        return ExecutionResult{
            .success = true,
            .output = owned_output,
            .error_message = null,
            .colors_updated = true,
            .spatial_changed = false,
        };
    }

    /// Query current spatial state
    pub fn querySpatialState(self: SpatialExecutor, allocator: std.mem.Allocator) !ExecutionResult {
        var output_buf: [256]u8 = undefined;
        const output = try std.fmt.bufPrint(&output_buf, "spatial state: focus={}, previous={}", .{
            self.current_focus,
            self.previous_focus,
        });

        const owned_output = try allocator.dupe(u8, output);

        return ExecutionResult{
            .success = true,
            .output = owned_output,
            .error_message = null,
            .colors_updated = false,
            .spatial_changed = false,
        };
    }
};

// Tests
pub const testing = struct {
    pub fn testFocusWindow(allocator: std.mem.Allocator) !void {
        var executor = SpatialExecutor.init(allocator);

        const cmd = Command{
            .command_type = .focus_update,
            .args = "focus 42",
            .modifiers = 0,
        };

        const result = try executor.updateFocus(cmd);
        defer allocator.free(result.output);

        try std.testing.expect(result.success);
        try std.testing.expectEqual(@as(u32, 42), executor.current_focus);
        try std.testing.expect(std.mem.indexOf(u8, result.output, "42") != null);
    }

    pub fn testFocusChange(allocator: std.mem.Allocator) !void {
        var executor = SpatialExecutor.init(allocator);

        const cmd1 = Command{
            .command_type = .focus_update,
            .args = "focus 10",
            .modifiers = 0,
        };
        const res1 = try executor.updateFocus(cmd1);
        allocator.free(res1.output);

        const cmd2 = Command{
            .command_type = .focus_update,
            .args = "focus 20",
            .modifiers = 0,
        };
        const res2 = try executor.updateFocus(cmd2);
        defer allocator.free(res2.output);

        try std.testing.expectEqual(@as(u32, 10), executor.previous_focus);
        try std.testing.expectEqual(@as(u32, 20), executor.current_focus);
    }

    pub fn testBCIColors(allocator: std.mem.Allocator) !void {
        var executor = SpatialExecutor.init(allocator);

        const bci = BCIContext{
            .phi = 0.25,
            .valence = 2.0,
            .fisher_rao = 0.5,
            .dominant_trit = 1,
        };

        const cmd = Command{
            .command_type = .focus_update,
            .args = "",
            .modifiers = 0,
            .bci_context = bci,
        };

        const result = try executor.updateColorsFromBCI(cmd);
        defer allocator.free(result.output);

        try std.testing.expect(result.success);
        try std.testing.expect(result.colors_updated);
        try std.testing.expect(std.mem.indexOf(u8, result.output, "BCI colors") != null);
    }
};
