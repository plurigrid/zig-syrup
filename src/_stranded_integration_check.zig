//! Stranded-file integration check.
//!
//! This module @imports each src/ file that was added to the tree during the
//! 2026-04-24 merge train but was not referenced by any existing @import chain
//! or build target. Wiring them through a single integration-check test target
//! ensures they compile as part of `zig build test-stranded-integration`
//! without forcing them onto the default test path.
//!
//! Promote to default test_step once each file's compile status is known.

const std = @import("std");

comptime {
    _ = @import("ocapn_vat.zig");
    _ = @import("ocapn_handoff.zig");
    _ = @import("ocapn_ws.zig");
    _ = @import("ocapn_tor.zig");
    _ = @import("holy.zig");
    _ = @import("holyzig.zig");
    _ = @import("backward_fiber.zig");
    _ = @import("world_control.zig");
}

test "stranded integration check — all 8 files compile" {
    // Comptime @import above already forces compile of each module.
    // This test is a placeholder so `zig test` registers at least one test.
    try std.testing.expect(true);
}
