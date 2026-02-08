/// Ghostty Interactive Execution (IX) - Command Dispatcher
///
/// Receives input events from WebSocket layer and routes them to appropriate
/// execution strategies (Shell, Stellogen, BIM, Continuation, Propagator).
///
/// Architecture:
/// - CommandDispatcher: Main routing logic
/// - ExecutionContext: Tracks state, spatial focus, BCI colors
/// - Four execution modes: See ghostty_ix_*.zig modules
/// - HTTP feedback server on :7071
///
/// GF(3) Trifurcation Patterns:
/// - MINUS (-1): Validation commands (test, check, verify)
/// - ERGODIC (0): Coordination commands (focus, sync, state-update)
/// - PLUS (+1): Creation commands (create, execute, build)
/// Sum ≡ 0 (mod 3) constraint enforces balanced dispatch

const std = @import("std");
const websocket_framing = @import("websocket_framing");
const spatial_propagator = @import("spatial_propagator");
const propagator = @import("propagator");
const ghostty_ix_shell = @import("ghostty_ix_shell");
const ghostty_ix_spatial = @import("ghostty_ix_spatial");
const ghostty_ix_continuation = @import("ghostty_ix_continuation");
const ghostty_ix_bim = @import("ghostty_ix_bim");

pub const InputMessage = websocket_framing.InputMessage;
pub const MessageType = websocket_framing.MessageType;

/// Command classification for GF(3) trifurcation
pub const CommandTrit = enum(i8) {
    minus = -1,    // Validation/verification
    ergodic = 0,   // Coordination/state-management
    plus = 1,      // Generation/creation
};

/// Command types that IX recognizes
pub const CommandType = enum {
    /// Shell: Execute arbitrary shell command
    shell,

    /// Stellogen: Star fusion for spatial conflict resolution
    stellogen,

    /// BIM: Bytecode VM for unification/pattern-matching
    bim,

    /// Continuation: Pausable/resumable execution
    continuation,

    /// Propagator: Constraint-based state merging
    propagator_cmd,

    /// Focus: Update spatial focus and propagate adjacency halo
    focus_update,

    /// Query: Read current state (colors, focus, engagement)
    query,

    /// Noop: No operation (debugging/testing)
    noop,
};

/// Parsed command from input event
pub const Command = struct {
    command_type: CommandType,
    args: []const u8,           // Raw argument string
    modifiers: u8,              // Keyboard modifiers from INPUT
    spatial_context: ?SpatialContext = null,  // Optional spatial state
    bci_context: ?BCIContext = null,          // Optional BCI state

    pub fn trit(self: Command) CommandTrit {
        return switch (self.command_type) {
            // MINUS: validation
            .query => .minus,

            // ERGODIC: coordination
            .focus_update, .propagator_cmd => .ergodic,

            // PLUS: generation
            .shell, .stellogen, .bim, .continuation => .plus,
            .noop => .ergodic,
        };
    }
};

/// Spatial context from propagator
pub const SpatialContext = struct {
    focus_window_id: u32,
    adjacent_windows: []const u32,
    golden_colors: []const [3]f32,
};

/// BCI context for color/valence integration
pub const BCIContext = struct {
    phi: f32,                   // Integrated Information
    valence: f32,               // -log(vortex_count)
    fisher_rao: f32,            // Fisher-Rao metric
    dominant_trit: i8,          // GF(3) trit assignment
};

/// Execution result
pub const ExecutionResult = struct {
    success: bool,
    output: []const u8,
    error_message: ?[]const u8 = null,
    next_state: ?[]const u8 = null,     // For continuation/state machines
    colors_updated: bool = false,
    spatial_changed: bool = false,
};

/// Main command dispatcher
pub const CommandDispatcher = struct {
    allocator: std.mem.Allocator,
    trit_histogram: [3]u32 = .{ 0, 0, 0 },  // Track -1, 0, +1 dispatch counts
    last_command_trit: i8 = 0,
    pending_continuations: std.ArrayListUnmanaged(*Continuation) = .{},

    pub fn init(allocator: std.mem.Allocator) CommandDispatcher {
        return CommandDispatcher{
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *CommandDispatcher) void {
        for (self.pending_continuations.items) |cont| {
            cont.deinit();
            self.allocator.destroy(cont);
        }
        self.pending_continuations.deinit(self.allocator);
    }

    /// Parse input event into Command
    pub fn parseCommand(self: *CommandDispatcher, input: InputMessage) !?Command {
        _ = self;

        // Only process key events for commands (mouse handled separately)
        if (input.event_type != .key) return null;

        const key_event = input.key_event orelse return null;
        const modifiers = key_event.modifiers;

        // Parse command from char code + modifiers
        // Ctrl+X = execute, Meta+X = explore, Shift+X = spatial, etc.

        // For now: simple key-to-command mapping
        const command_type: CommandType = switch (key_event.char_code) {
            'c' => if ((modifiers & 0x02) != 0) .shell else .noop,      // Ctrl+C = shell
            'q' => .query,                                                // Q = query state
            'f' => if ((modifiers & 0x08) != 0) .focus_update else .noop, // Meta+F = focus
            'm' => .propagator_cmd,                                        // M = merge/propagate
            's' => .stellogen,                                             // S = stellogen
            'b' => .bim,                                                   // B = BIM
            'p' => .continuation,                                          // P = pause/resume
            else => .noop,
        };

        return Command{
            .command_type = command_type,
            .args = "",
            .modifiers = modifiers,
        };
    }

    /// Execute parsed command
    pub fn execute(self: *CommandDispatcher, cmd: Command) !ExecutionResult {
        // Track trit for GF(3) balance
        const cmd_trit = cmd.trit();
        self.trit_histogram[@intCast(@as(i32, @intFromEnum(cmd_trit)) + 1)] += 1;
        self.last_command_trit = @intFromEnum(cmd_trit);

        return switch (cmd.command_type) {
            .shell => self.executeShell(cmd),
            .query => self.executeQuery(cmd),
            .focus_update => self.executeFocusUpdate(cmd),
            .propagator_cmd => self.executePropagator(cmd),
            .stellogen => self.executeStellogen(cmd),
            .bim => self.executeBim(cmd),
            .continuation => self.executeContinuation(cmd),
            .noop => ExecutionResult{
                .success = true,
                .output = "noop",
            },
        };
    }

    fn executeShell(self: *CommandDispatcher, cmd: Command) !ExecutionResult {
        const executor = ghostty_ix_shell.ShellExecutor.init(self.allocator);
        return try executor.execute(cmd);
    }

    fn executeQuery(self: *CommandDispatcher, cmd: Command) !ExecutionResult {
        _ = cmd;
        // Return histogram of trit dispatch counts
        var buf: [256]u8 = undefined;
        const output = try std.fmt.bufPrint(&buf, "trit_histogram: minus={} ergodic={} plus={}", .{
            self.trit_histogram[0],
            self.trit_histogram[1],
            self.trit_histogram[2],
        });
        const owned = try self.allocator.dupe(u8, output);
        return ExecutionResult{
            .success = true,
            .output = owned,
        };
    }

    fn executeFocusUpdate(self: *CommandDispatcher, cmd: Command) !ExecutionResult {
        // Initialize a spatial executor for this command
        var spatial_exec = ghostty_ix_spatial.SpatialExecutor.init(self.allocator);
        return try spatial_exec.updateFocus(cmd);
    }

    fn executePropagator(self: *CommandDispatcher, cmd: Command) !ExecutionResult {
        _ = self;
        _ = cmd;
        // TODO: Wire to ghostty_ix_propagator.zig
        return ExecutionResult{
            .success = false,
            .output = "",
            .error_message = "propagator: not yet implemented",
        };
    }

    fn executeStellogen(self: *CommandDispatcher, cmd: Command) !ExecutionResult {
        _ = self;
        _ = cmd;
        // TODO: Wire to ghostty_ix_stellogen.zig
        return ExecutionResult{
            .success = false,
            .output = "",
            .error_message = "stellogen: not yet implemented",
        };
    }

    fn executeBim(self: *CommandDispatcher, cmd: Command) !ExecutionResult {
        const executor = ghostty_ix_bim.BIMExecutor.init(self.allocator);
        return try executor.execute(cmd);
    }

    fn executeContinuation(self: *CommandDispatcher, cmd: Command) !ExecutionResult {
        var executor = ghostty_ix_continuation.ContinuationExecutor.init(self.allocator);

        // Parse command args for pause/resume/homotopy operations
        if (std.mem.startsWith(u8, cmd.args, "pause")) {
            return try executor.pause(cmd);
        } else if (std.mem.startsWith(u8, cmd.args, "resume")) {
            // Extract promise ID from args (format: "resume <promise_id>")
            var parts = std.mem.splitSequence(u8, cmd.args, " ");
            _ = parts.next(); // skip "resume"
            if (parts.next()) |promise_str| {
                const promise_id = std.fmt.parseUnsigned(u64, promise_str, 16) catch 0;
                return try executor.resumeExecution(promise_id);
            }
            return ExecutionResult{
                .success = false,
                .output = try self.allocator.dupe(u8, "resume requires promise ID"),
                .error_message = "invalid promise format",
            };
        } else if (std.mem.startsWith(u8, cmd.args, "homotopy")) {
            // Extract start and end promise IDs from args
            var parts = std.mem.splitSequence(u8, cmd.args, " ");
            _ = parts.next(); // skip "homotopy"
            if (parts.next()) |start_str| {
                if (parts.next()) |end_str| {
                    const start_id = std.fmt.parseUnsigned(u64, start_str, 16) catch 0;
                    const end_id = std.fmt.parseUnsigned(u64, end_str, 16) catch 0;
                    return try executor.createHomotopyPath(start_id, end_id);
                }
            }
            return ExecutionResult{
                .success = false,
                .output = try self.allocator.dupe(u8, "homotopy requires two promise IDs"),
                .error_message = "invalid homotopy format",
            };
        }

        // Default: pause
        return try executor.pause(cmd);
    }

    /// Check GF(3) balance of dispatch counts
    pub fn checkTritBalance(self: CommandDispatcher) bool {
        const sum: i32 = @as(i32, @intCast(self.trit_histogram[0])) * (-1) +
                         @as(i32, @intCast(self.trit_histogram[1])) * 0 +
                         @as(i32, @intCast(self.trit_histogram[2])) * 1;
        return @mod(sum, 3) == 0;
    }
};

/// Placeholder for continuation structure (to be fully defined in ghostty_ix_continuation.zig)
pub const Continuation = struct {
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Continuation) void {
        _ = self;
    }
};

// Tests
pub const testing = struct {
    pub fn testCommandParsing(allocator: std.mem.Allocator) !void {
        var dispatcher = CommandDispatcher.init(allocator);
        defer dispatcher.deinit();

        const key_event = InputMessage.KeyEvent{
            .char_code = 'q',
            .modifiers = 0,
        };

        const input = InputMessage{
            .event_type = .key,
            .key_event = key_event,
        };

        const cmd = try dispatcher.parseCommand(input);
        try std.testing.expect(cmd != null);
        try std.testing.expectEqual(cmd.?.command_type, CommandType.query);
    }

    pub fn testTriBracketing(allocator: std.mem.Allocator) !void {
        var dispatcher = CommandDispatcher.init(allocator);
        defer dispatcher.deinit();

        // Dispatch three balanced commands: validation, coordination, creation
        const cmd1 = Command{ .command_type = .query, .args = "", .modifiers = 0 };  // MINUS
        const cmd2 = Command{ .command_type = .focus_update, .args = "", .modifiers = 0 };  // ERGODIC
        const cmd3 = Command{ .command_type = .shell, .args = "", .modifiers = 0 };  // PLUS

        _ = try dispatcher.execute(cmd1);
        _ = try dispatcher.execute(cmd2);
        _ = try dispatcher.execute(cmd3);

        try std.testing.expect(dispatcher.checkTritBalance());
    }
};
