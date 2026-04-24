// Zig 0.16 compatibility shim for in-flight refactors.
// Restores the subset of symbols used by cli.zig, salon_demo.zig,
// mcp_server.zig, ghostty_web_server.zig, ghostty_vt_tileable.zig,
// and worlds/multiplayer.zig while the full std.Io migration is pending.
const std = @import("std");

pub const DebugAllocator = std.heap.DebugAllocator(.{});

pub fn makeDebugAllocator() DebugAllocator {
    return DebugAllocator.init;
}

pub fn stdoutWrite(bytes: []const u8) void {
    _ = std.c.write(std.c.STDOUT_FILENO, bytes.ptr, bytes.len);
}

pub fn stdinRead(buf: []u8) usize {
    const n = std.c.read(std.c.STDIN_FILENO, buf.ptr, buf.len);
    if (n < 0) return 0;
    return @intCast(n);
}

pub const Mutex = std.Thread.Mutex;
