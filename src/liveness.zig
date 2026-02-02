//! Terminal Liveness Probes
//!
//! Simple probes to verify terminal/ACP system health.
//! Each probe returns quickly with pass/fail status.
//!
//! Usage:
//!   const probes = @import("liveness.zig");
//!   const result = try probes.echoProbe(allocator, fd, 1000);
//!   if (result.alive) { ... }

const std = @import("std");
const syrup = @import("syrup");
const acp = @import("acp");

const Allocator = std.mem.Allocator;
const posix = std.posix;

// ============================================================================
// Probe Results
// ============================================================================

pub const ProbeResult = struct {
    alive: bool,
    latency_ns: u64 = 0,
    message: []const u8 = "",
    raw_output: ?[]const u8 = null,
};

pub const ProbeError = error{
    Timeout,
    ReadError,
    WriteError,
    InvalidResponse,
    NotTerminal,
};

// ============================================================================
// Probe 1: Echo Probe (simplest liveness check)
// ============================================================================

/// Send "echo <marker>" and verify marker appears in output
pub fn echoProbe(allocator: Allocator, fd: posix.fd_t, timeout_ms: u32) !ProbeResult {
    const start = std.time.nanoTimestamp();
    
    // Unique marker to avoid matching stale output
    var marker_buf: [32]u8 = undefined;
    const marker = std.fmt.bufPrint(&marker_buf, "PROBE_{d}", .{@as(u64, @intCast(start)) % 1000000}) catch "PROBE_TEST";
    
    // Send echo command
    const cmd = try std.fmt.allocPrint(allocator, "echo {s}\n", .{marker});
    defer allocator.free(cmd);
    
    _ = posix.write(fd, cmd) catch |err| {
        return ProbeResult{ .alive = false, .message = @errorName(err) };
    };
    
    // Read with timeout
    var output_buf: [1024]u8 = undefined;
    const output = try readWithTimeout(fd, &output_buf, timeout_ms);
    
    const elapsed = @as(u64, @intCast(std.time.nanoTimestamp() - start));
    
    // Check if marker is in output
    if (std.mem.indexOf(u8, output, marker)) |_| {
        return ProbeResult{
            .alive = true,
            .latency_ns = elapsed,
            .message = "echo response received",
            .raw_output = try allocator.dupe(u8, output),
        };
    }
    
    return ProbeResult{
        .alive = false,
        .latency_ns = elapsed,
        .message = "marker not found in output",
        .raw_output = try allocator.dupe(u8, output),
    };
}

// ============================================================================
// Probe 2: ANSI Cursor Position Probe (terminal capability)
// ============================================================================

/// Send DSR (Device Status Report) and expect CPR (Cursor Position Report)
/// Request: ESC[6n → Response: ESC[{row};{col}R
pub fn ansiCursorProbe(fd: posix.fd_t, timeout_ms: u32) !ProbeResult {
    const start = std.time.nanoTimestamp();
    
    // Send cursor position request (DSR)
    const dsr = "\x1b[6n";
    _ = posix.write(fd, dsr) catch |err| {
        return ProbeResult{ .alive = false, .message = @errorName(err) };
    };
    
    // Read response
    var buf: [32]u8 = undefined;
    const output = try readWithTimeout(fd, &buf, timeout_ms);
    
    const elapsed = @as(u64, @intCast(std.time.nanoTimestamp() - start));
    
    // Check for CPR response: ESC[{n};{m}R
    if (std.mem.indexOf(u8, output, "\x1b[")) |esc_pos| {
        if (std.mem.indexOfScalar(u8, output[esc_pos..], 'R')) |_| {
            return ProbeResult{
                .alive = true,
                .latency_ns = elapsed,
                .message = "cursor position report received",
            };
        }
    }
    
    return ProbeResult{
        .alive = false,
        .latency_ns = elapsed,
        .message = "no CPR response",
    };
}

// ============================================================================
// Probe 3: File Descriptor Poll Probe (fd alive)
// ============================================================================

/// Check if fd is writable using poll()
pub fn fdPollProbe(fd: posix.fd_t, timeout_ms: u32) !ProbeResult {
    const start = std.time.nanoTimestamp();
    
    var fds = [_]posix.pollfd{
        .{ .fd = fd, .events = posix.POLL.OUT, .revents = 0 },
    };
    
    const timeout_spec: i32 = @intCast(timeout_ms);
    const ready = posix.poll(&fds, timeout_spec) catch |err| {
        return ProbeResult{ .alive = false, .message = @errorName(err) };
    };
    
    const elapsed = @as(u64, @intCast(std.time.nanoTimestamp() - start));
    
    if (ready > 0 and (fds[0].revents & posix.POLL.OUT) != 0) {
        return ProbeResult{
            .alive = true,
            .latency_ns = elapsed,
            .message = "fd writable",
        };
    }
    
    if ((fds[0].revents & posix.POLL.HUP) != 0) {
        return ProbeResult{ .alive = false, .message = "fd hangup" };
    }
    
    if ((fds[0].revents & posix.POLL.ERR) != 0) {
        return ProbeResult{ .alive = false, .message = "fd error" };
    }
    
    return ProbeResult{
        .alive = false,
        .latency_ns = elapsed,
        .message = "poll timeout",
    };
}

// ============================================================================
// Probe 4: ACP Initialize Probe (protocol handshake)
// ============================================================================

/// Send ACP initialize request, verify response
pub fn acpInitializeProbe(allocator: Allocator, fd: posix.fd_t, timeout_ms: u32) !ProbeResult {
    const start = std.time.nanoTimestamp();
    
    // Build initialize message
    const msg = acp.Message{
        .initialize = .{
            .protocol_version = acp.PROTOCOL_VERSION,
            .client_capabilities = .{ .terminal = true },
            .client_info = .{ .name = "liveness-probe", .version = "0.1.0" },
        },
    };
    
    const value = try msg.toSyrup(allocator);
    
    // Encode to bytes
    var encode_buf: [4096]u8 = undefined;
    const encoded = syrup.encode(&encode_buf, value) catch |err| {
        return ProbeResult{ .alive = false, .message = @errorName(err) };
    };
    
    // Send
    _ = posix.write(fd, encoded) catch |err| {
        return ProbeResult{ .alive = false, .message = @errorName(err) };
    };
    
    // Read response
    var response_buf: [4096]u8 = undefined;
    const response = try readWithTimeout(fd, &response_buf, timeout_ms);
    
    const elapsed = @as(u64, @intCast(std.time.nanoTimestamp() - start));
    
    // Try to decode as Syrup
    const decoded = syrup.decode(allocator, response) catch {
        return ProbeResult{
            .alive = false,
            .latency_ns = elapsed,
            .message = "invalid syrup response",
        };
    };
    
    // Check if it's a record with "initialize" or "initialize-response" label
    if (decoded == .record) {
        const label = decoded.record.label;
        if (label == .symbol) {
            if (std.mem.eql(u8, label.symbol, "initialize-response") or
                std.mem.eql(u8, label.symbol, "initialize"))
            {
                return ProbeResult{
                    .alive = true,
                    .latency_ns = elapsed,
                    .message = "ACP initialize response received",
                };
            }
        }
    }
    
    return ProbeResult{
        .alive = false,
        .latency_ns = elapsed,
        .message = "unexpected response type",
    };
}

// ============================================================================
// Probe 5: Shell PID Probe (process alive)
// ============================================================================

/// Send "echo $$" to get shell PID, verify numeric response
pub fn shellPidProbe(allocator: Allocator, fd: posix.fd_t, timeout_ms: u32) !ProbeResult {
    const start = std.time.nanoTimestamp();
    
    // Send PID request
    const cmd = "echo $$\n";
    _ = posix.write(fd, cmd) catch |err| {
        return ProbeResult{ .alive = false, .message = @errorName(err) };
    };
    
    // Read response
    var buf: [256]u8 = undefined;
    const output = try readWithTimeout(fd, &buf, timeout_ms);
    
    const elapsed = @as(u64, @intCast(std.time.nanoTimestamp() - start));
    
    // Look for numeric PID in output
    var pid_found = false;
    var iter = std.mem.tokenizeAny(u8, output, " \t\n\r");
    while (iter.next()) |token| {
        if (std.fmt.parseInt(u32, token, 10)) |pid| {
            if (pid > 0) {
                const msg = try std.fmt.allocPrint(allocator, "shell PID: {d}", .{pid});
                return ProbeResult{
                    .alive = true,
                    .latency_ns = elapsed,
                    .message = msg,
                };
            }
            pid_found = true;
        } else |_| {}
    }
    
    return ProbeResult{
        .alive = false,
        .latency_ns = elapsed,
        .message = if (pid_found) "PID is 0" else "no PID in output",
    };
}

// ============================================================================
// Probe 6: Heartbeat Probe (continuous liveness)
// ============================================================================

pub const HeartbeatConfig = struct {
    interval_ms: u32 = 1000,
    timeout_ms: u32 = 500,
    max_failures: u32 = 3,
};

pub const HeartbeatState = struct {
    consecutive_failures: u32 = 0,
    last_success_ns: i128 = 0,
    total_probes: u64 = 0,
    total_failures: u64 = 0,
    
    pub fn recordSuccess(self: *HeartbeatState) void {
        self.consecutive_failures = 0;
        self.last_success_ns = std.time.nanoTimestamp();
        self.total_probes += 1;
    }
    
    pub fn recordFailure(self: *HeartbeatState) void {
        self.consecutive_failures += 1;
        self.total_probes += 1;
        self.total_failures += 1;
    }
    
    pub fn isHealthy(self: HeartbeatState, config: HeartbeatConfig) bool {
        return self.consecutive_failures < config.max_failures;
    }
    
    pub fn successRate(self: HeartbeatState) f64 {
        if (self.total_probes == 0) return 1.0;
        return @as(f64, @floatFromInt(self.total_probes - self.total_failures)) / 
               @as(f64, @floatFromInt(self.total_probes));
    }
};

// ============================================================================
// Utilities
// ============================================================================

fn readWithTimeout(fd: posix.fd_t, buf: []u8, timeout_ms: u32) ![]const u8 {
    var fds = [_]posix.pollfd{
        .{ .fd = fd, .events = posix.POLL.IN, .revents = 0 },
    };
    
    const timeout_spec: i32 = @intCast(timeout_ms);
    const ready = posix.poll(&fds, timeout_spec) catch return error.ReadError;
    
    if (ready == 0) return error.Timeout;
    
    if ((fds[0].revents & posix.POLL.IN) != 0) {
        const n = posix.read(fd, buf) catch return error.ReadError;
        return buf[0..n];
    }
    
    return error.ReadError;
}

// ============================================================================
// Composite Probe (run multiple probes)
// ============================================================================

pub const CompositeResult = struct {
    fd_alive: bool = false,
    echo_alive: bool = false,
    ansi_alive: bool = false,
    total_latency_ns: u64 = 0,
    
    pub fn isFullyAlive(self: CompositeResult) bool {
        return self.fd_alive and self.echo_alive;
    }
    
    pub fn summary(self: CompositeResult) []const u8 {
        if (self.isFullyAlive()) return "all probes passed";
        if (self.fd_alive) return "fd alive, echo failed";
        return "fd not responding";
    }
};

/// Run fd poll + echo probe for quick health check
pub fn quickProbe(allocator: Allocator, fd: posix.fd_t, timeout_ms: u32) !CompositeResult {
    var result = CompositeResult{};
    
    // First check fd is writable
    const fd_result = try fdPollProbe(fd, timeout_ms / 3);
    result.fd_alive = fd_result.alive;
    result.total_latency_ns += fd_result.latency_ns;
    
    if (!fd_result.alive) return result;
    
    // Then check echo works
    const echo_result = try echoProbe(allocator, fd, timeout_ms * 2 / 3);
    result.echo_alive = echo_result.alive;
    result.total_latency_ns += echo_result.latency_ns;
    
    return result;
}

// ============================================================================
// Tests
// ============================================================================

test "probe result construction" {
    const result = ProbeResult{
        .alive = true,
        .latency_ns = 1_000_000, // 1ms
        .message = "test passed",
    };
    
    try std.testing.expect(result.alive);
    try std.testing.expectEqual(@as(u64, 1_000_000), result.latency_ns);
}

test "heartbeat state tracking" {
    var state = HeartbeatState{};
    const config = HeartbeatConfig{ .max_failures = 3 };
    
    // Initially healthy
    try std.testing.expect(state.isHealthy(config));
    
    // Record some successes
    state.recordSuccess();
    state.recordSuccess();
    try std.testing.expectEqual(@as(u64, 2), state.total_probes);
    try std.testing.expectEqual(@as(f64, 1.0), state.successRate());
    
    // Record failures
    state.recordFailure();
    state.recordFailure();
    try std.testing.expect(state.isHealthy(config)); // 2 < 3
    
    state.recordFailure();
    try std.testing.expect(!state.isHealthy(config)); // 3 >= 3
    
    // Success resets consecutive failures
    state.recordSuccess();
    try std.testing.expect(state.isHealthy(config));
}

test "composite result summary" {
    const full = CompositeResult{ .fd_alive = true, .echo_alive = true };
    try std.testing.expect(full.isFullyAlive());
    
    const partial = CompositeResult{ .fd_alive = true, .echo_alive = false };
    try std.testing.expect(!partial.isFullyAlive());
    
    const dead = CompositeResult{ .fd_alive = false, .echo_alive = false };
    try std.testing.expect(!dead.isFullyAlive());
}
