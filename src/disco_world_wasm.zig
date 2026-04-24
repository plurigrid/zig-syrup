//! Freestanding WASM surface for the Disco wire world.

const std = @import("std");

const WORLD_SOURCE = @embedFile("disco_wire_world");

const SUMMARY =
    "Disco wire world: retty native, restty browser host, dom_backend as " ++
    "Ratzilla-equivalent, wgpu_compute for GPU dispatch, and Hoot/Goblins " ++
    "best deployed today through browser-hosted reflect.js bootstraps.";

const ZEN_TODAY =
    "Morph Cloud -> Itaca Fest -> Lean -> ar.io -> automorphic forms -> " ++
    "miniKanren -> GeoACSet/olmoearth geodesics -> foot/kitty -> Baez/Bradley.";

const RENDERING_STACK =
    "retty | restty | dom_backend | wgpu_compute | Hoot reflect.js | " ++
    "Goblins on Hoot";

export fn disco_world_ptr() [*]const u8 {
    return WORLD_SOURCE.ptr;
}

export fn disco_world_len() u32 {
    return @intCast(WORLD_SOURCE.len);
}

export fn disco_summary_ptr() [*]const u8 {
    return SUMMARY.ptr;
}

export fn disco_summary_len() u32 {
    return @intCast(SUMMARY.len);
}

export fn disco_zen_today_ptr() [*]const u8 {
    return ZEN_TODAY.ptr;
}

export fn disco_zen_today_len() u32 {
    return @intCast(ZEN_TODAY.len);
}

export fn disco_rendering_stack_ptr() [*]const u8 {
    return RENDERING_STACK.ptr;
}

export fn disco_rendering_stack_len() u32 {
    return @intCast(RENDERING_STACK.len);
}

test "embedded disco world contains expected URI" {
    try std.testing.expect(std.mem.containsAtLeast(
        u8,
        WORLD_SOURCE,
        1,
        "world://ies/disco/wire",
    ));
}

test "summary mentions Hoot and retty" {
    try std.testing.expect(std.mem.containsAtLeast(u8, SUMMARY, 1, "Hoot"));
    try std.testing.expect(std.mem.containsAtLeast(u8, SUMMARY, 1, "retty"));
}

pub fn panic(
    msg: []const u8,
    stack_trace: ?*std.builtin.StackTrace,
    ret_addr: ?usize,
) noreturn {
    _ = msg;
    _ = stack_trace;
    _ = ret_addr;
    @trap();
}
