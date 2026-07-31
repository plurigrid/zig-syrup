//! edn_roundtrip — measure the ⇄ in "EDN ⇄ syrup.Value" over edn.c's own corpus.
//!
//! Law checked per file:  parse ∘ emit ∘ parse = parse
//!   p1 = parse(text)             (EDN -> syrup.Value)
//!   t1 = emit(p1)                (syrup.Value -> EDN text, our emitter)
//!   p2 = parse(t1)               (through edn.c again)
//!   assert canonical_syrup_bytes(p1) == canonical_syrup_bytes(p2)
//!
//! Equality is judged on the canonical syrup wire, so formatting differences
//! are invisible but any semantic drift (type collapse, lost element, keyword
//! /symbol confusion, number damage) is a byte diff.
//!
//! Usage: edn-roundtrip FILE.edn [FILE.edn ...]
//! Exit: 0 all files hold the law; 1 otherwise.

const std = @import("std");
const syrup = @import("syrup");
const bridge = @import("edn_bridge");

fn checkFile(io: std.Io, gpa: std.mem.Allocator, path: []const u8) !bool {
    const text = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(64 * 1024 * 1024)) catch |e| {
        std.debug.print("SKIP  {s} (read: {s})\n", .{ path, @errorName(e) });
        return true;
    };
    defer gpa.free(text);

    var p1 = bridge.parse(gpa, text) catch |e| {
        std.debug.print("FAIL  {s} (parse1: {s})\n", .{ path, @errorName(e) });
        return false;
    };
    defer p1.deinit();

    const wire1 = try p1.value.encodeAlloc(gpa);
    defer gpa.free(wire1);

    const t1 = try bridge.emitAlloc(gpa, p1.value);
    defer gpa.free(t1);

    var p2 = bridge.parse(gpa, t1) catch |e| {
        std.debug.print("FAIL  {s} (parse2 of our emit: {s})\n", .{ path, @errorName(e) });
        return false;
    };
    defer p2.deinit();

    const wire2 = try p2.value.encodeAlloc(gpa);
    defer gpa.free(wire2);

    if (!std.mem.eql(u8, wire1, wire2)) {
        std.debug.print("FAIL  {s} (wire drift: {d} -> {d} bytes)\n", .{ path, wire1.len, wire2.len });
        return false;
    }
    std.debug.print("OK    {s} ({d} bytes edn, {d} bytes syrup)\n", .{ path, text.len, wire1.len });
    return true;
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var pass: usize = 0;
    var fail: usize = 0;
    for (args[1..]) |path| {
        if (try checkFile(init.io, gpa, path)) pass += 1 else fail += 1;
    }
    std.debug.print("\n{d}/{d} files hold parse∘emit∘parse = parse\n", .{ pass, pass + fail });
    if (fail > 0) std.process.exit(1);
}
