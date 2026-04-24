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

// Export each module so addObject forces them through semantic analysis.
pub const ocapn_vat = @import("ocapn_vat.zig");
pub const ocapn_handoff = @import("ocapn_handoff.zig");
pub const ocapn_ws = @import("ocapn_ws.zig");
pub const ocapn_tor = @import("ocapn_tor.zig");
pub const holy = @import("holy.zig");
pub const holyzig = @import("holyzig.zig");
pub const backward_fiber = @import("backward_fiber.zig");
pub const world_control = @import("world_control.zig");
