//! zigbjj jj integration: shell-out wrapper around the `jj` CLI.
//!
//! Phase 3 of the lazybjj-unison rebuild plan. Equivalent of the Unison
//! `JJ` ability + `handleJJ` shell-out handler.
//!
//! Reads change_ids and descriptions out of jj via templated log commands;
//! parses 64-char lowercase hex into [32]u8 ChangeIds; surfaces a small,
//! capability-bounded API. No mutation operations.

const std = @import("std");
const ziggit = @import("ziggit.zig");
const splitmix = @import("splitmix_trit.zig");
const Trit = splitmix.Trit;
const Allocator = std.mem.Allocator;

pub const Error = error{
    NotInJjRepo,
    JjBinaryMissing,
    InvalidHex,
    JjFailed,
    OutOfMemory,
    UnexpectedEof,
};

/// Result of a `jj` invocation.
pub const RunResult = struct {
    stdout: []u8,
    stderr: []u8,
    exit_code: u8,

    pub fn deinit(self: *RunResult, alloc: Allocator) void {
        alloc.free(self.stdout);
        alloc.free(self.stderr);
    }
};

const MAX_OUTPUT: usize = 4 * 1024 * 1024;

/// Run `jj <args...>` in `cwd` (or current dir if cwd == null).
/// Caller owns the returned RunResult buffers.
pub fn runJj(
    alloc: Allocator,
    cwd: ?[]const u8,
    args: []const []const u8,
) !RunResult {
    var argv = std.ArrayList([]const u8){};
    defer argv.deinit(alloc);
    try argv.append(alloc, "jj");
    for (args) |a| try argv.append(alloc, a);

    var child = std.process.Child.init(argv.items, alloc);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    child.stdin_behavior = .Ignore;
    if (cwd) |c| child.cwd = c;

    child.spawn() catch return Error.JjBinaryMissing;

    const stdout = child.stdout.?.readToEndAlloc(alloc, MAX_OUTPUT) catch |err| {
        _ = child.kill() catch {};
        return err;
    };
    errdefer alloc.free(stdout);

    const stderr = child.stderr.?.readToEndAlloc(alloc, MAX_OUTPUT) catch |err| {
        _ = child.kill() catch {};
        return err;
    };
    errdefer alloc.free(stderr);

    const term = try child.wait();
    const code: u8 = switch (term) {
        .Exited => |c| c,
        else => 255,
    };
    return .{ .stdout = stdout, .stderr = stderr, .exit_code = code };
}

/// Parse one 64-char lowercase hex string into a 32-byte change_id.
pub fn parseHexChangeId(hex: []const u8) Error![32]u8 {
    if (hex.len != 64) return Error.InvalidHex;
    var out: [32]u8 = undefined;
    for (0..32) |i| {
        const hi = nibble(hex[i * 2]) orelse return Error.InvalidHex;
        const lo = nibble(hex[i * 2 + 1]) orelse return Error.InvalidHex;
        out[i] = (hi << 4) | lo;
    }
    return out;
}

fn nibble(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

/// Get the change_id of the working-copy commit (`@`).
pub fn currentChange(alloc: Allocator, cwd: ?[]const u8) ![32]u8 {
    var r = try runJj(alloc, cwd, &.{ "log", "-r", "@", "--no-graph", "-T", "change_id" });
    defer r.deinit(alloc);
    if (r.exit_code != 0) return Error.NotInJjRepo;
    const trimmed = std.mem.trim(u8, r.stdout, " \n\t\r");
    return parseHexChangeId(trimmed);
}

/// Get the change_ids of the parents of `change`.
/// Caller owns the returned slice.
pub fn parents(
    alloc: Allocator,
    cwd: ?[]const u8,
    change: [32]u8,
) ![]const [32]u8 {
    var hex_buf: [64]u8 = undefined;
    formatHex(&hex_buf, change);
    const rev = try std.fmt.allocPrint(alloc, "{s}-", .{hex_buf});
    defer alloc.free(rev);
    var r = try runJj(alloc, cwd, &.{ "log", "-r", rev, "--no-graph", "-T", "change_id ++ \"\\n\"" });
    defer r.deinit(alloc);
    if (r.exit_code != 0) return Error.JjFailed;

    var lines = std.mem.tokenizeAny(u8, r.stdout, "\n");
    var out = std.ArrayList([32]u8){};
    errdefer out.deinit(alloc);
    while (lines.next()) |line| {
        const t = std.mem.trim(u8, line, " \r\t");
        if (t.len == 0) continue;
        const cid = try parseHexChangeId(t);
        try out.append(alloc, cid);
    }
    return try out.toOwnedSlice(alloc);
}

/// Get the description of `change` (trimmed).
/// Caller owns the returned slice.
pub fn description(
    alloc: Allocator,
    cwd: ?[]const u8,
    change: [32]u8,
) ![]u8 {
    var hex_buf: [64]u8 = undefined;
    formatHex(&hex_buf, change);
    var r = try runJj(alloc, cwd, &.{ "log", "-r", &hex_buf, "--no-graph", "-T", "description" });
    defer r.deinit(alloc);
    if (r.exit_code != 0) return Error.JjFailed;
    const t = std.mem.trim(u8, r.stdout, " \n\t\r");
    return try alloc.dupe(u8, t);
}

/// Render 32-byte change_id as 64 lowercase hex chars (no allocator).
pub fn formatHex(out: *[64]u8, change: [32]u8) void {
    const hex = "0123456789abcdef";
    for (change, 0..) |b, i| {
        out[i * 2] = hex[(b >> 4) & 0xF];
        out[i * 2 + 1] = hex[b & 0xF];
    }
}

/// Convenience: trit + RGB color of the working-copy commit.
pub fn currentColor(alloc: Allocator, cwd: ?[]const u8, seed: u64) !ziggit.ChangeColor {
    const cid = try currentChange(alloc, cwd);
    return ziggit.colorFromChangeId(cid, seed);
}

/// Convenience: dispatchCI for the working-copy commit.
pub fn currentDispatch(alloc: Allocator, cwd: ?[]const u8, seed: u64) !ziggit.CIAction {
    const cid = try currentChange(alloc, cwd);
    const ps = parents(alloc, cwd, cid) catch &[_][32]u8{};
    defer if (ps.len > 0) alloc.free(ps);
    return ziggit.dispatchCI(cid, ps, seed);
}

// ============================================================================
// Tests
// ============================================================================

const expectEqual = std.testing.expectEqual;
const expectError = std.testing.expectError;

test "parseHexChangeId: round-trip via formatHex" {
    const original: [32]u8 = .{
        0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef,
        0xfe, 0xdc, 0xba, 0x98, 0x76, 0x54, 0x32, 0x10,
        0xde, 0xad, 0xbe, 0xef, 0xca, 0xfe, 0xba, 0xbe,
        0xf0, 0x0d, 0xfa, 0xce, 0xb0, 0x0c, 0x12, 0x34,
    };
    var hex: [64]u8 = undefined;
    formatHex(&hex, original);
    const parsed = try parseHexChangeId(&hex);
    try std.testing.expectEqualSlices(u8, &original, &parsed);
}

test "parseHexChangeId: rejects wrong length" {
    try expectError(Error.InvalidHex, parseHexChangeId("abc"));
    const short_hex: []const u8 = "a" ** 63;
    try expectError(Error.InvalidHex, parseHexChangeId(short_hex));
    const long_hex: []const u8 = "a" ** 65;
    try expectError(Error.InvalidHex, parseHexChangeId(long_hex));
}

test "parseHexChangeId: rejects non-hex chars" {
    var bad: [64]u8 = undefined;
    @memset(&bad, '0');
    bad[33] = 'z';
    try expectError(Error.InvalidHex, parseHexChangeId(&bad));
}

test "formatHex: zero change_id → all zeros" {
    var hex: [64]u8 = undefined;
    formatHex(&hex, [_]u8{0} ** 32);
    try std.testing.expectEqualStrings(("0" ** 64), &hex);
}

test "formatHex: accepts uppercase via parser" {
    var hex_lower: [64]u8 = undefined;
    formatHex(&hex_lower, [_]u8{0xab} ** 32);
    var hex_upper: [64]u8 = undefined;
    for (hex_lower, 0..) |c, i| hex_upper[i] = std.ascii.toUpper(c);
    const a = try parseHexChangeId(&hex_lower);
    const b = try parseHexChangeId(&hex_upper);
    try std.testing.expectEqualSlices(u8, &a, &b);
}

test "currentChange: graceful failure outside a jj repo" {
    // /tmp is not a jj repo; expect NotInJjRepo (exit code != 0 from jj).
    // If `jj` binary is missing entirely, the test still passes by
    // returning JjBinaryMissing.
    const result = currentChange(std.testing.allocator, "/tmp");
    if (result) |_| {
        return error.UnexpectedSuccess;
    } else |err| {
        try std.testing.expect(
            err == Error.NotInJjRepo or err == Error.JjBinaryMissing,
        );
    }
}
