/// Ghostty Interactive Execution (IX) - Shell Executor
///
/// Implements shell command execution via std.process.Child
/// Routes output back to ghostty_web_server.broadcastOutput()
///
/// Key design decisions:
/// - Buffered output capture (max 16KB per command)
/// - Non-blocking execution (could be enhanced to async)
/// - Trit classification: PLUS (+1) generation command
/// - Error messages included in output on failure

const std = @import("std");
const ghostty_ix = @import("ghostty_ix");

pub const ExecutionResult = ghostty_ix.ExecutionResult;
pub const Command = ghostty_ix.Command;

/// Maximum output size per command execution
pub const MAX_OUTPUT = 16 * 1024; // 16KB

/// Shell executor for running arbitrary commands
pub const ShellExecutor = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) ShellExecutor {
        return ShellExecutor{
            .allocator = allocator,
        };
    }

    /// Execute a shell command and capture output
    /// Command format: "command arg1 arg2 ..." (parsed from shell-style input)
    pub fn execute(self: ShellExecutor, cmd: Command) !ExecutionResult {
        // Parse command string into argv
        const argv = try self.parseCommand(cmd.args);
        defer self.allocator.free(argv);

        if (argv.len == 0) {
            return ExecutionResult{
                .success = false,
                .output = "",
                .error_message = "empty command",
            };
        }

        // Create child process
        var child = std.process.Child.init(argv, self.allocator);
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;
        child.stdin_behavior = .Ignore;

        // Spawn the process
        try child.spawn();

        // Collect stdout
        const stdout_data = child.stdout.?.readToEndAlloc(
            self.allocator,
            MAX_OUTPUT,
        ) catch |err| {
            // Attempt to kill process on read error
            _ = child.kill() catch {};
            const output = try std.fmt.allocPrint(self.allocator, "stdout read error: {}", .{err});
            return ExecutionResult{
                .success = false,
                .output = output,
                .error_message = "failed to read command output",
            };
        };

        // Collect stderr
        const stderr_data = child.stderr.?.readToEndAlloc(
            self.allocator,
            MAX_OUTPUT,
        ) catch |err| {
            // Log but don't fail if stderr read has issues
            std.debug.print("stderr read error: {}\n", .{err});
            self.allocator.free(stdout_data);
            const output = try std.fmt.allocPrint(self.allocator, "stderr read error: {}", .{err});
            return ExecutionResult{
                .success = false,
                .output = output,
                .error_message = "failed to read error output",
            };
        };

        // Wait for process to complete
        const term = child.wait() catch |err| {
            self.allocator.free(stdout_data);
            self.allocator.free(stderr_data);
            const output = try std.fmt.allocPrint(self.allocator, "wait error: {}", .{err});
            return ExecutionResult{
                .success = false,
                .output = output,
                .error_message = "process wait failed",
            };
        };

        // Check exit status
        const success = switch (term) {
            .Exited => |code| code == 0,
            else => false,
        };

        // Combine stdout and stderr for output
        var combined = std.ArrayList(u8).init(self.allocator);
        defer combined.deinit();

        try combined.appendSlice(stdout_data);
        if (stderr_data.len > 0) {
            if (combined.items.len > 0 and combined.items[combined.items.len - 1] != '\n') {
                try combined.append('\n');
            }
            try combined.appendSlice(stderr_data);
        }

        self.allocator.free(stdout_data);
        self.allocator.free(stderr_data);

        // Return result
        const result_output = if (combined.items.len > 0)
            try combined.toOwnedSlice()
        else
            try self.allocator.dupe(u8, "");

        return ExecutionResult{
            .success = success,
            .output = result_output,
            .error_message = if (!success)
                try std.fmt.allocPrint(self.allocator, "command failed with exit code: {}", .{
                    switch (term) {
                        .Exited => |code| code,
                        else => 1,
                    },
                })
            else
                null,
            .colors_updated = false,
            .spatial_changed = false,
        };
    }

    /// Parse shell-style command string into argv array
    /// Simple implementation: split on whitespace, respect quoted strings
    fn parseCommand(self: ShellExecutor, input: []const u8) ![][]const u8 {
        var args = std.ArrayList([]const u8).init(self.allocator);
        defer args.deinit();

        var i: usize = 0;
        while (i < input.len) {
            // Skip whitespace
            while (i < input.len and std.ascii.isWhitespace(input[i])) {
                i += 1;
            }
            if (i >= input.len) break;

            // Find end of argument
            const start = i;
            const in_quote = input[i] == '"' or input[i] == '\'';
            const quote_char = if (in_quote) input[i] else 0;

            if (in_quote) {
                i += 1; // Skip opening quote
                while (i < input.len and input[i] != quote_char) {
                    i += 1;
                }
                if (i < input.len) i += 1; // Skip closing quote
            } else {
                while (i < input.len and !std.ascii.isWhitespace(input[i])) {
                    i += 1;
                }
            }

            if (i > start) {
                const arg = input[start..i];
                // Strip quotes if present
                const clean_arg = if (in_quote)
                    arg[1 .. arg.len - 1]
                else
                    arg;

                try args.append(try self.allocator.dupe(u8, clean_arg));
            }
        }

        return args.toOwnedSlice();
    }
};

// Tests
pub const testing = struct {
    pub fn testSimpleCommand(allocator: std.mem.Allocator) !void {
        const executor = ShellExecutor.init(allocator);

        // Test: echo hello
        const cmd = Command{
            .command_type = .shell,
            .args = "echo hello world",
            .modifiers = 0,
        };

        const result = try executor.execute(cmd);
        defer allocator.free(result.output);

        try std.testing.expect(result.success);
        try std.testing.expect(std.mem.indexOf(u8, result.output, "hello world") != null);
    }

    pub fn testFailedCommand(allocator: std.mem.Allocator) !void {
        const executor = ShellExecutor.init(allocator);

        // Test: false (should fail)
        const cmd = Command{
            .command_type = .shell,
            .args = "false",
            .modifiers = 0,
        };

        const result = try executor.execute(cmd);
        defer allocator.free(result.output);
        if (result.error_message) |err| {
            defer allocator.free(err);
        }

        try std.testing.expect(!result.success);
    }

    pub fn testCommandParsing(allocator: std.mem.Allocator) !void {
        const executor = ShellExecutor.init(allocator);

        // Test: parse "echo 'hello world'" correctly
        const cmd = Command{
            .command_type = .shell,
            .args = "echo 'hello world'",
            .modifiers = 0,
        };

        const result = try executor.execute(cmd);
        defer allocator.free(result.output);

        try std.testing.expect(result.success);
        try std.testing.expect(std.mem.indexOf(u8, result.output, "hello world") != null);
    }
};
