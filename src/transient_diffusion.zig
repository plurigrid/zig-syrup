//! Transient Control of Diffusions
//! Wires transient.zig popup UI → propagator.zig constraint cells → prigogine.zig Brusselator
//! with optimal_control.zig PID/LQR for closed-loop bifurcation navigation.

const std = @import("std");
const transient = @import("transient.zig");
const propagator = @import("propagator.zig");
const prigogine = @import("prigogine.zig");
const control = @import("optimal_control.zig");

// Action IDs dispatched by transient popup keybindings
const Action = enum(u16) {
    // Brusselator parameter control
    increase_a = 0x10,
    decrease_a = 0x11,
    increase_b = 0x12,
    decrease_b = 0x13,
    // Diffusion coefficient control
    increase_dx = 0x20,
    decrease_dx = 0x21,
    increase_dy = 0x22,
    decrease_dy = 0x23,
    // Preset regimes
    goto_equilibrium = 0x30,
    goto_critical = 0x31,
    goto_far_from_eq = 0x32,
    // Simulation
    step_forward = 0x40,
    toggle_autopilot = 0x41,
    reset = 0x42,
    // Turing analysis
    scan_bifurcation = 0x50,
    find_hopf = 0x51,

    fn fromU16(v: u16) ?Action {
        return std.meta.intToEnum(Action, v) catch null;
    }
};

// Propagator cell network for Brusselator parameter space
const F64Cell = propagator.SimpleCell(f64);
const F64Propagator = propagator.SimplePropagator(f64);

pub const DiffusionCells = struct {
    a: F64Cell,
    b: F64Cell,
    dx: F64Cell,
    dy: F64Cell,
    entropy_rate: F64Cell,
    regime_trit: F64Cell,
    hopf_b: F64Cell,

    pub fn init(allocator: std.mem.Allocator) DiffusionCells {
        return .{
            .a = F64Cell.init(allocator, "brusselator_a"),
            .b = F64Cell.init(allocator, "brusselator_b"),
            .dx = F64Cell.init(allocator, "diffusion_x"),
            .dy = F64Cell.init(allocator, "diffusion_y"),
            .entropy_rate = F64Cell.init(allocator, "entropy_production"),
            .regime_trit = F64Cell.init(allocator, "dissipative_regime"),
            .hopf_b = F64Cell.init(allocator, "hopf_bifurcation_b"),
        };
    }

    pub fn deinit(self: *DiffusionCells) void {
        self.a.deinit();
        self.b.deinit();
        self.dx.deinit();
        self.dy.deinit();
        self.entropy_rate.deinit();
        self.regime_trit.deinit();
        self.hopf_b.deinit();
    }

    pub fn syncFromBrusselator(self: *DiffusionCells, br: prigogine.Brusselator) !void {
        try self.a.set_content(br.a);
        try self.b.set_content(br.b);
        try self.dx.set_content(br.dx);
        try self.dy.set_content(br.dy);
        try self.entropy_rate.set_content(br.steadyStateEntropyProduction());
        const regime = prigogine.DissipativeRegime.fromBrusselator(br);
        try self.regime_trit.set_content(@as(f64, @floatFromInt(regime.trit())));
        try self.hopf_b.set_content(br.hopfBifurcation());
    }

    pub fn toBrusselator(self: *const DiffusionCells) prigogine.Brusselator {
        return prigogine.Brusselator.init(
            self.a.get_content() orelse 2.0,
            self.b.get_content() orelse 5.0,
            self.dx.get_content() orelse 1.0,
            self.dy.get_content() orelse 8.0,
        );
    }
};

// Controller: PID tracks distance-to-Hopf as error signal
pub const DiffusionController = struct {
    pid: control.PidController,
    target_regime: prigogine.DissipativeRegime,
    autopilot: bool,
    step_size: f64,

    pub fn init() DiffusionController {
        return .{
            .pid = control.PidController.init(0.5, 0.1, 0.05),
            .target_regime = .critical,
            .autopilot = false,
            .step_size = 0.1,
        };
    }

    pub fn controlStep(self: *DiffusionController, br: *prigogine.Brusselator, dt: f64) control.PidController.Output {
        const hopf_b = br.hopfBifurcation();
        const target_b: f64 = switch (self.target_regime) {
            .near_equilibrium => hopf_b * 0.7,
            .critical => hopf_b,
            .far_from_equilibrium => hopf_b * 1.5,
        };
        self.pid.setpoint = target_b;
        const out = self.pid.step(br.b, dt);
        if (self.autopilot) {
            br.b += out.control * dt;
        }
        return out;
    }
};

// Build the transient popup menu for diffusion control
pub fn diffusionTransient() transient.Transient {
    const param_suffixes = [_]transient.Suffix{
        .{ .key = 'A', .description = "a +0.1", .action_id = @intFromEnum(Action.increase_a) },
        .{ .key = 'a', .description = "a -0.1", .action_id = @intFromEnum(Action.decrease_a) },
        .{ .key = 'B', .description = "b +0.1", .action_id = @intFromEnum(Action.increase_b) },
        .{ .key = 'b', .description = "b -0.1", .action_id = @intFromEnum(Action.decrease_b) },
    };

    const diff_suffixes = [_]transient.Suffix{
        .{ .key = 'X', .description = "Dx +0.5", .action_id = @intFromEnum(Action.increase_dx) },
        .{ .key = 'x', .description = "Dx -0.5", .action_id = @intFromEnum(Action.decrease_dx) },
        .{ .key = 'Y', .description = "Dy +0.5", .action_id = @intFromEnum(Action.increase_dy) },
        .{ .key = 'y', .description = "Dy -0.5", .action_id = @intFromEnum(Action.decrease_dy) },
    };

    const regime_suffixes = [_]transient.Suffix{
        .{ .key = 'e', .description = "→ equilibrium", .action_id = @intFromEnum(Action.goto_equilibrium) },
        .{ .key = 'c', .description = "→ critical", .action_id = @intFromEnum(Action.goto_critical) },
        .{ .key = 'f', .description = "→ far-from-eq", .action_id = @intFromEnum(Action.goto_far_from_eq) },
    };

    const sim_suffixes = [_]transient.Suffix{
        .{ .key = ' ', .description = "step", .action_id = @intFromEnum(Action.step_forward) },
        .{ .key = 'p', .description = "autopilot", .action_id = @intFromEnum(Action.toggle_autopilot) },
        .{ .key = 'r', .description = "reset", .action_id = @intFromEnum(Action.reset) },
        .{ .key = 's', .description = "scan bifurcation", .action_id = @intFromEnum(Action.scan_bifurcation) },
        .{ .key = 'h', .description = "find Hopf", .action_id = @intFromEnum(Action.find_hopf) },
    };

    const groups = [_]transient.Group{
        .{ .name = "Parameters", .suffixes = &param_suffixes },
        .{ .name = "Diffusion", .suffixes = &diff_suffixes },
        .{ .name = "Regime", .suffixes = &regime_suffixes },
        .{ .name = "Simulation", .suffixes = &sim_suffixes },
    };

    return transient.Transient.new("Prigogine")
        .withGroups(&groups)
        .withColumns(2)
        .withSeed(transient.RandomnessSeed.fromU64(1069, .splitmix));
}

// Main dispatch loop: transient key → action → mutate cells → update Brusselator
pub const DiffusionSession = struct {
    cells: DiffusionCells,
    brusselator: prigogine.Brusselator,
    controller: DiffusionController,
    menu: transient.Transient,
    time: f64,

    pub fn init(allocator: std.mem.Allocator) !DiffusionSession {
        var session = DiffusionSession{
            .cells = DiffusionCells.init(allocator),
            .brusselator = prigogine.Brusselator.init(2.0, 5.0, 1.0, 8.0),
            .controller = DiffusionController.init(),
            .menu = diffusionTransient(),
            .time = 0.0,
        };
        try session.cells.syncFromBrusselator(session.brusselator);
        return session;
    }

    pub fn deinit(self: *DiffusionSession) void {
        self.cells.deinit();
    }

    pub fn dispatch(self: *DiffusionSession, action_id: u16) !void {
        const action = Action.fromU16(action_id) orelse return;
        const s = self.controller.step_size;

        switch (action) {
            .increase_a => self.brusselator.a += s,
            .decrease_a => self.brusselator.a = @max(0.01, self.brusselator.a - s),
            .increase_b => self.brusselator.b += s,
            .decrease_b => self.brusselator.b = @max(0.01, self.brusselator.b - s),
            .increase_dx => self.brusselator.dx += s * 5.0,
            .decrease_dx => self.brusselator.dx = @max(0.01, self.brusselator.dx - s * 5.0),
            .increase_dy => self.brusselator.dy += s * 5.0,
            .decrease_dy => self.brusselator.dy = @max(0.01, self.brusselator.dy - s * 5.0),
            .goto_equilibrium => {
                self.controller.target_regime = .near_equilibrium;
                self.controller.autopilot = true;
            },
            .goto_critical => {
                self.controller.target_regime = .critical;
                self.controller.autopilot = true;
            },
            .goto_far_from_eq => {
                self.controller.target_regime = .far_from_equilibrium;
                self.controller.autopilot = true;
            },
            .step_forward => {
                const dt = 0.01;
                _ = self.controller.controlStep(&self.brusselator, dt);
                self.time += dt;
            },
            .toggle_autopilot => self.controller.autopilot = !self.controller.autopilot,
            .reset => {
                self.brusselator = prigogine.Brusselator.init(2.0, 5.0, 1.0, 8.0);
                self.controller = DiffusionController.init();
                self.time = 0.0;
            },
            .scan_bifurcation, .find_hopf => {},
        }

        try self.cells.syncFromBrusselator(self.brusselator);
    }

    pub fn handleKey(self: *DiffusionSession, key: u8) !void {
        if (self.menu.handleKey(key)) |action_id| {
            try self.dispatch(action_id);
        }
    }

    pub fn regime(self: *const DiffusionSession) prigogine.DissipativeRegime {
        return prigogine.DissipativeRegime.fromBrusselator(self.brusselator);
    }

    pub fn turingAnalysis(self: *const DiffusionSession) prigogine.TuringAnalysis {
        return prigogine.TuringAnalysis.fromBrusselator(self.brusselator);
    }
};

// Tests
test "diffusion session lifecycle" {
    var session = try DiffusionSession.init(std.testing.allocator);
    defer session.deinit();

    try std.testing.expect(session.brusselator.a == 2.0);
    try std.testing.expect(session.brusselator.b == 5.0);

    // increase b via dispatch
    try session.dispatch(@intFromEnum(Action.increase_b));
    try std.testing.expect(session.brusselator.b == 5.1);

    // regime classification
    const r = session.regime();
    _ = r.trit();
}

test "propagator cells sync" {
    var cells = DiffusionCells.init(std.testing.allocator);
    defer cells.deinit();

    const br = prigogine.Brusselator.init(2.0, 6.0, 1.0, 8.0);
    try cells.syncFromBrusselator(br);

    try std.testing.expect(cells.a.get_content().? == 2.0);
    try std.testing.expect(cells.b.get_content().? == 6.0);
    try std.testing.expect(cells.hopf_b.get_content().? == br.hopfBifurcation());
}

test "controller drives toward critical" {
    var br = prigogine.Brusselator.init(2.0, 2.0, 1.0, 8.0); // below Hopf
    var ctrl = DiffusionController.init();
    ctrl.target_regime = .critical;
    ctrl.autopilot = true;

    // run 100 steps
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        _ = ctrl.controlStep(&br, 0.01);
    }

    // b should have moved toward hopf point
    const hopf = br.hopfBifurcation();
    const dist = @abs(br.b - hopf);
    try std.testing.expect(dist < 2.0); // converging
}

test "transient menu has 4 groups" {
    const menu = diffusionTransient();
    try std.testing.expect(menu.groups.len == 4);
}
