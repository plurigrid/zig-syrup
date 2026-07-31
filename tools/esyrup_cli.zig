//! esyrup — EDN text <-> Syrup canonical bytes (spec: ESYRUP.md).
//! The EDN projection of syrup: twin of src/cli.zig (JSON, $dict/$bytes
//! escapes), sibling of vivicat/zig-syrup's jsyrup (wire-faithful text).
//!
//! Modes:
//!   esyrup encode   stdin: EDN text     -> stdout: canonical syrup bytes
//!   esyrup decode   stdin: syrup bytes  -> stdout: EDN text
//!
//! The type mapping (and its escape conventions for syrup values EDN lacks)
//! lives entirely in src/edn_bridge.zig; this file is stdin/stdout plumbing,
//! deliberately isomorphic to cli.zig's structure.

const std = @import("std");
const syrup = @import("syrup");
const bridge = @import("edn_bridge");

const max_input_bytes = 1024 * 1024 * 10;
const stdio_buffer_size = 4096;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    if (args.len < 2) {
        fatal(io, "Usage: {s} [encode|decode]  (EDN on stdin for encode, syrup bytes for decode)\n", .{if (args.len > 0) args[0] else "esyrup"});
    }
    const mode = args[1];

    var stdout_buffer: [stdio_buffer_size]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    if (std.mem.eql(u8, mode, "encode")) {
        const input = try readAllStdin(io, gpa);
        defer gpa.free(input);

        var parsed = bridge.parse(gpa, input) catch |e| {
            fatal(io, "edn parse error: {s}\n", .{@errorName(e)});
        };
        defer parsed.deinit();

        const wire = try parsed.value.encodeAlloc(gpa);
        defer gpa.free(wire);
        try stdout.writeAll(wire);
    } else if (std.mem.eql(u8, mode, "decode")) {
        const input = try readAllStdin(io, gpa);
        defer gpa.free(input);

        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const val = syrup.decode(input, arena.allocator()) catch |e| {
            fatal(io, "syrup decode error: {s}\n", .{@errorName(e)});
        };

        const text = try bridge.emitAlloc(gpa, val);
        defer gpa.free(text);
        try stdout.writeAll(text);
        try stdout.writeAll("\n");
    } else {
        fatal(io, "Unknown mode: {s}\n", .{mode});
    }

    try stdout.flush();
}

fn fatal(io: std.Io, comptime format: []const u8, args: anytype) noreturn {
    var buffer: [512]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writerStreaming(io, &buffer);
    stderr_writer.interface.print(format, args) catch {};
    stderr_writer.interface.flush() catch {};
    std.process.exit(1);
}

fn readAllStdin(io: std.Io, gpa: std.mem.Allocator) ![]u8 {
    var stdin_buffer: [stdio_buffer_size]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().readerStreaming(io, &stdin_buffer);
    return stdin_reader.interface.allocRemaining(gpa, .limited(max_input_bytes + 1));
}
