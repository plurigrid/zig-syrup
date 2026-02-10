//! Stellogen Executor - Star fusion and constellation execution
//! Implements the interaction net reduction semantics

const std = @import("std");
const ast = @import("ast.zig");
const unify = @import("unify.zig");

const Term = ast.Term;
const Ray = ast.Ray;
const Star = ast.Star;
const Constellation = ast.Constellation;
const Substitution = unify.Substitution;

/// Result of a single fusion step
pub const FusionResult = struct {
    merged_star: Star,
    used_action: bool, // For linear execution tracking
};

/// Execution error types
pub const ExecError = error{
    NoInteraction,
    Contradiction, // Ban constraint violated
    OutOfMemory,
};

/// Find compatible rays between a state and action star
/// Returns indices of matching rays if found
fn findCompatibleRays(state: Star, action: Star) ?struct { state_idx: usize, action_idx: usize } {
    for (state.content, 0..) |state_ray, si| {
        for (action.content, 0..) |action_ray, ai| {
            // Check polarity compatibility
            if (state_ray.polarity().compatible(action_ray.polarity())) {
                // Check if they can unify (same function symbol)
                switch (state_ray) {
                    .function => |sf| {
                        switch (action_ray) {
                            .function => |af| {
                                if (sf.id.compatible(af.id)) {
                                    return .{ .state_idx = si, .action_idx = ai };
                                }
                            },
                            else => {},
                        }
                    },
                    else => {},
                }
            }
        }
    }
    return null;
}

/// Perform star fusion: merge two stars via ray annihilation
pub fn fuse(
    allocator: std.mem.Allocator,
    state: Star,
    action: Star,
    state_ray_idx: usize,
    action_ray_idx: usize,
) !?FusionResult {
    const state_ray = state.content[state_ray_idx];
    const action_ray = action.content[action_ray_idx];

    // Attempt unification
    const subst_opt = try unify.unify(allocator, state_ray, action_ray);
    if (subst_opt == null) return null;
    var subst = subst_opt.?;
    defer subst.deinit();

    // Collect remaining rays from both stars (excluding the matched pair)
    var merged_rays = std.ArrayListUnmanaged(Ray){};
    defer merged_rays.deinit(allocator);

    // Add state rays (except the matched one)
    for (state.content, 0..) |ray, i| {
        if (i != state_ray_idx) {
            const applied = try subst.apply(ray);
            try merged_rays.append(allocator, applied);
        }
    }

    // Add action rays (except the matched one)
    for (action.content, 0..) |ray, i| {
        if (i != action_ray_idx) {
            const applied = try subst.apply(ray);
            try merged_rays.append(allocator, applied);
        }
    }

    // Merge bans and check coherence
    var merged_bans = std.ArrayListUnmanaged(ast.Ban){};
    defer merged_bans.deinit(allocator);

    for (state.bans) |ban| {
        try merged_bans.append(allocator, ban);
    }
    for (action.bans) |ban| {
        try merged_bans.append(allocator, ban);
    }

    // Check ban coherence (inequality constraints)
    for (merged_bans.items) |ban| {
        switch (ban) {
            .inequality => |ineq| {
                const applied_a = try subst.apply(ineq.a);
                const applied_b = try subst.apply(ineq.b);
                if (applied_a.eql(applied_b)) {
                    return ExecError.Contradiction;
                }
            },
            .incompatibility => {},
        }
    }

    return FusionResult{
        .merged_star = .{
            .content = try allocator.dupe(Ray, merged_rays.items),
            .bans = try allocator.dupe(ast.Ban, merged_bans.items),
            .is_state = true, // Result becomes a state
        },
        .used_action = true,
    };
}

/// Execute a constellation until saturation
/// linear = true: each action can only be used once (fire)
/// linear = false: actions can be reused (exec)
pub fn execute(
    allocator: std.mem.Allocator,
    constellation: Constellation,
    linear: bool,
) !Constellation {
    // Separate states and actions
    var states = std.ArrayListUnmanaged(Star){};
    defer states.deinit(allocator);
    var actions = std.ArrayListUnmanaged(Star){};
    defer actions.deinit(allocator);

    for (constellation.stars) |star| {
        if (star.is_state) {
            try states.append(allocator, star);
        } else {
            try actions.append(allocator, star);
        }
    }

    // Work queue execution
    var changed = true;
    while (changed) {
        changed = false;

        var new_states = std.ArrayListUnmanaged(Star){};
        defer new_states.deinit(allocator);

        var action_used = std.AutoHashMap(usize, bool).init(allocator);
        defer action_used.deinit();

        for (states.items) |state| {
            var state_fused = false;

            // Try to fuse with each action
            for (actions.items, 0..) |action, ai| {
                if (linear and (action_used.get(ai) orelse false)) continue;

                if (findCompatibleRays(state, action)) |rays| {
                    const result = try fuse(allocator, state, action, rays.state_idx, rays.action_idx);
                    if (result) |fusion| {
                        try new_states.append(allocator, fusion.merged_star);
                        if (linear) {
                            try action_used.put(ai, true);
                        }
                        state_fused = true;
                        changed = true;
                        break;
                    }
                }
            }

            // If state didn't fuse, keep it
            if (!state_fused) {
                try new_states.append(allocator, state);
            }
        }

        // Update states for next iteration
        states.clearRetainingCapacity();
        try states.appendSlice(allocator, new_states.items);

        // Remove used actions in linear mode
        if (linear) {
            var remaining_actions = std.ArrayListUnmanaged(Star){};
            defer remaining_actions.deinit(allocator);
            for (actions.items, 0..) |action, ai| {
                if (!(action_used.get(ai) orelse false)) {
                    try remaining_actions.append(allocator, action);
                }
            }
            actions.clearRetainingCapacity();
            try actions.appendSlice(allocator, remaining_actions.items);
        }
    }

    // Recombine into constellation
    var result_stars = std.ArrayListUnmanaged(Star){};
    defer result_stars.deinit(allocator);

    // Only include non-empty states in result
    for (states.items) |state| {
        if (!state.isEmpty()) {
            try result_stars.append(allocator, state);
        }
    }

    // Include unused actions
    for (actions.items) |action| {
        try result_stars.append(allocator, action);
    }

    return Constellation{
        .stars = try allocator.dupe(Star, result_stars.items),
    };
}

/// Check if constellation contains the 'ok' atom (successful verification)
pub fn hasOk(constellation: Constellation) bool {
    for (constellation.stars) |star| {
        for (star.content) |ray| {
            switch (ray) {
                .function => |f| {
                    if (std.mem.eql(u8, f.id.name, "ok") and f.args.len == 0) {
                        return true;
                    }
                },
                else => {},
            }
        }
    }
    return false;
}

// ============================================================================
// Tests
// ============================================================================

test "basic fusion" {
    const allocator = std.testing.allocator;

    // State: [(-f X) X]
    // Action: [(+f a)]
    // Expected: [a]

    const x = ast.makeVar("X");
    const a = ast.makeAtom(.null, "a");
    const neg_fx = try ast.makeFunc(allocator, .neg, "f", &.{x});
    const pos_fa = try ast.makeFunc(allocator, .pos, "f", &.{a});

    const state = Star{
        .content = &.{ neg_fx, x },
        .is_state = true,
    };

    const action = Star{
        .content = &.{pos_fa},
        .is_state = false,
    };

    const result = try fuse(allocator, state, action, 0, 0);
    try std.testing.expect(result != null);

    const merged = result.?.merged_star;
    try std.testing.expectEqual(@as(usize, 1), merged.content.len);
    try std.testing.expect(merged.content[0].eql(a));
}

test "execute simple constellation" {
    const allocator = std.testing.allocator;

    // Natural number: 0 + Y = Y
    // Query: -add(0, 2, R) R
    // Expected: R = 2

    const y = ast.makeVar("Y");
    const r = ast.makeVar("R");
    const zero = ast.makeAtom(.null, "z");
    const two = ast.makeAtom(.null, "two");

    // Action: [(+add z Y Y)]
    const add_base = try ast.makeFunc(allocator, .pos, "add", &.{ zero, y, y });

    // State: [(-add z two R) R]
    const query = try ast.makeFunc(allocator, .neg, "add", &.{ zero, two, r });

    const constellation = Constellation{
        .stars = &.{
            Star{ .content = &.{add_base}, .is_state = false },
            Star{ .content = &.{ query, r }, .is_state = true },
        },
    };

    const result = try execute(allocator, constellation, false);
    try std.testing.expect(result.stars.len >= 1);
}
