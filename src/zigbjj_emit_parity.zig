//! Standalone CLI: emit parity test cases as JSONL on stdout.
//!
//!   zig run src/zigbjj_emit_parity.zig -- N SEED_BASE
//!
//! N defaults to 1000, SEED_BASE to 0xCAFE.

const std = @import("std");
const parity = @import("zigbjj_parity.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);

    const n: usize = if (args.len > 1) try std.fmt.parseInt(usize, args[1], 10) else 1000;
    const seed_base: u64 = if (args.len > 2) try std.fmt.parseInt(u64, args[2], 10) else 0xCAFE;

    const json = try parity.emitCasesJsonl(alloc, n, seed_base);
    defer alloc.free(json);

    var stdout_buf: [4096]u8 = undefined;
    var stdout_w = std.fs.File.stdout().writer(&stdout_buf);
    try stdout_w.interface.writeAll(json);
    try stdout_w.interface.flush();
}
