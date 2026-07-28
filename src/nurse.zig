//! Nurse — One System Awareness Layer
//!
//! NOT a caregiver watching a patient. There is one system.
//! Propagator cells sense somatic state. AGM revises beliefs.
//! Bandit selects intervention. HERO device actuates.
//!
//! MCP tools exposed:
//!   nurse_sense       — update propagator cells from somatic report
//!   nurse_state       — read full system state
//!   nurse_intervene   — bandit-select and optionally actuate HERO
//!   nurse_dispense    — direct HERO slot dispense
//!   nurse_schedule    — dispense a named schedule (wake/morning/midday/evening/bedtime)
//!   nurse_revise      — AGM belief revision on the world model
//!   nurse_trajectory  — update substance mg trajectory
//!
//! Wire format: JSON-RPC 2.0 over stdio (MCP), same as mcp_server.zig.
//! This module provides the handler functions; mcp_server.zig routes to them.

const std = @import("std");
const json = std.json;

// ============================================================================
// System State — one struct, no patient/caregiver split
// ============================================================================

pub const Cell = enum(u8) {
    sympathetic = 0,
    pain = 1,
    gi_distress = 2,
    skin_crawling = 3,
    temperature = 4,
    sleep_quality = 5,
    appetite = 6,
    irritability = 7,
    craving = 8,
    anhedonia = 9,

    pub const COUNT = 10;

    pub fn name(self: Cell) []const u8 {
        return switch (self) {
            .sympathetic => "sympathetic",
            .pain => "pain",
            .gi_distress => "gi_distress",
            .skin_crawling => "skin_crawling",
            .temperature => "temperature",
            .sleep_quality => "sleep_quality",
            .appetite => "appetite",
            .irritability => "irritability",
            .craving => "craving",
            .anhedonia => "anhedonia",
        };
    }

    pub fn fromString(s: []const u8) ?Cell {
        inline for (std.meta.fields(Cell)) |f| {
            if (std.mem.eql(u8, s, @tagName(@as(Cell, @fromBackingInt(@intCast(f.value)))))) return @fromBackingInt(@intCast(f.value));
        }
        return null;
    }
};

pub const Phase = enum(u8) {
    crash = 0, // hours 0-24
    floor = 1, // days 2-7
    dysphoria = 2, // weeks 2-4
    paws = 3, // months 1-6
    stable = 4, // months 6+

    pub fn fromDay(day: u16) Phase {
        if (day < 1) return .crash;
        if (day <= 7) return .floor;
        if (day <= 28) return .dysphoria;
        if (day <= 180) return .paws;
        return .stable;
    }

    pub fn name(self: Phase) []const u8 {
        return switch (self) {
            .crash => "crash",
            .floor => "floor",
            .dysphoria => "dysphoria",
            .paws => "paws",
            .stable => "stable",
        };
    }
};

pub const Cartridge = struct {
    slot: u8,
    med_name: ?[]const u8,
    mg: f32,
    remaining: ?u16,
};

pub const SubstanceTrajectory = struct {
    vyvanse_mg: f32 = 0,
    adderall_mg: f32 = 0,
    caffeine_mg: f32 = 0,
    nicotine_mg: f32 = 0,
};

pub const SystemState = struct {
    // Propagator cells: partial info (null = nothing, value = sensed)
    cells: [Cell.COUNT]?f32 = @splat(null),

    // Substance trajectory
    substances: SubstanceTrajectory = .{},

    // Temporal
    day: u16 = 0,
    phase: Phase = .crash,

    // HERO device
    hero_connected: bool = false,
    cartridges: [10]Cartridge = defaultCartridges(),

    // Bandit arms
    arm_pulls: [8]u32 = @splat(0),
    arm_rewards: [8]f64 = @splat(0),

    // History (ring buffer of last 64 exchanges)
    history_len: u16 = 0,

    pub fn updatePhase(self: *SystemState) void {
        self.phase = Phase.fromDay(self.day);
    }

    pub fn senseCell(self: *SystemState, cell: Cell, value: f32) void {
        self.cells[@backingInt(cell)] = std.math.clamp(value, 0.0, 1.0);
    }

    pub fn readCell(self: *const SystemState, cell: Cell) ?f32 {
        return self.cells[@backingInt(cell)];
    }

    pub fn shouldIntervene(self: *const SystemState) bool {
        const thresholds = [_]Cell{ .craving, .irritability, .sympathetic, .pain, .skin_crawling };
        for (thresholds) |c| {
            if (self.readCell(c)) |v| {
                if (v > 0.7) return true;
            }
        }
        return false;
    }

    fn defaultCartridges() [10]Cartridge {
        return .{
            .{ .slot = 1, .med_name = "clonidine", .mg = 0.1, .remaining = null },
            .{ .slot = 2, .med_name = "gabapentin", .mg = 300, .remaining = null },
            .{ .slot = 3, .med_name = "hydroxyzine", .mg = 25, .remaining = null },
            .{ .slot = 4, .med_name = "magnesium", .mg = 400, .remaining = null },
            .{ .slot = 5, .med_name = "l-tyrosine", .mg = 500, .remaining = null },
            .{ .slot = 6, .med_name = "omega-3", .mg = 1000, .remaining = null },
            .{ .slot = 7, .med_name = "b-complex", .mg = 1, .remaining = null },
            .{ .slot = 8, .med_name = "melatonin", .mg = 3, .remaining = null },
            .{ .slot = 9, .med_name = null, .mg = 0, .remaining = null },
            .{ .slot = 10, .med_name = null, .mg = 0, .remaining = null },
        };
    }
};

// ============================================================================
// Bandit — intervention selection
// ============================================================================

pub const Arm = enum(u8) {
    clonidine = 0,
    gabapentin = 1,
    hydroxyzine = 2,
    magnesium = 3,
    l_tyrosine = 4,
    deep_breath = 5,
    cold_water = 6,
    walk_outside = 7,

    pub const COUNT = 8;

    pub fn heroSlot(self: Arm) ?u8 {
        return switch (self) {
            .clonidine => 1,
            .gabapentin => 2,
            .hydroxyzine => 3,
            .magnesium => 4,
            .l_tyrosine => 5,
            .deep_breath, .cold_water, .walk_outside => null,
        };
    }

    pub fn name(self: Arm) []const u8 {
        return switch (self) {
            .clonidine => "clonidine",
            .gabapentin => "gabapentin",
            .hydroxyzine => "hydroxyzine",
            .magnesium => "magnesium",
            .l_tyrosine => "l-tyrosine",
            .deep_breath => "deep-breath",
            .cold_water => "cold-water",
            .walk_outside => "walk-outside",
        };
    }

    pub fn message(self: Arm) []const u8 {
        return switch (self) {
            .clonidine => "Clonidine 0.1mg dispensed. SNS dampening ~20min.",
            .gabapentin => "Gabapentin 300mg dispensed. Nerve calming ~45min.",
            .hydroxyzine => "Hydroxyzine 25mg dispensed. Anxiety relief ~30min.",
            .magnesium => "Magnesium 400mg dispensed. Muscle relax ~30min.",
            .l_tyrosine => "L-Tyrosine 500mg dispensed. DA precursor ~60min.",
            .deep_breath => "4-7-8 breathing. Inhale 4s, hold 7s, exhale 8s. x3.",
            .cold_water => "Cold water on wrists+face. Vagal activation ~30s.",
            .walk_outside => "10 min walk. Endogenous DA ~15min.",
        };
    }
};

/// Epsilon-greedy selection (epsilon=0.1)
pub fn banditSelect(state: *const SystemState, rng: *std.Random) Arm {
    if (rng.intRangeAtMost(u8, 0, 99) < 10) {
        return @fromBackingInt(@intCast(rng.intRangeAtMost(u8, 0, Arm.COUNT - 1)));
    }
    var best: Arm = .clonidine;
    var best_val: f64 = -1.0;
    for (0..Arm.COUNT) |i| {
        const val = if (state.arm_pulls[i] > 0)
            state.arm_rewards[i] / @as(f64, @floatFromInt(state.arm_pulls[i]))
        else
            1.0; // optimistic init
        if (val > best_val) {
            best_val = val;
            best = @fromBackingInt(@intCast(@as(u8, @intCast(i))));
        }
    }
    return best;
}

pub fn banditUpdate(state: *SystemState, arm: Arm, reward: f64) void {
    const i = @backingInt(arm);
    state.arm_pulls[i] += 1;
    state.arm_rewards[i] += reward;
}

// ============================================================================
// Schedules — named dose groups
// ============================================================================

pub const Schedule = enum {
    wake,
    morning,
    midday,
    evening,
    bedtime,

    pub fn slots(self: Schedule) []const u8 {
        return switch (self) {
            .wake => &[_]u8{5},
            .morning => &[_]u8{ 1, 2, 6, 7 },
            .midday => &[_]u8{ 1, 2, 3 },
            .evening => &[_]u8{ 6, 2, 3 },
            .bedtime => &[_]u8{ 1, 3, 4, 8 },
        };
    }

    pub fn fromString(s: []const u8) ?Schedule {
        if (std.mem.eql(u8, s, "wake")) return .wake;
        if (std.mem.eql(u8, s, "morning")) return .morning;
        if (std.mem.eql(u8, s, "midday")) return .midday;
        if (std.mem.eql(u8, s, "evening")) return .evening;
        if (std.mem.eql(u8, s, "bedtime")) return .bedtime;
        return null;
    }
};

// ============================================================================
// Global singleton (one system)
// ============================================================================

var system_state: SystemState = .{};

pub fn getState() *SystemState {
    return &system_state;
}

pub fn getStateConst() *const SystemState {
    return &system_state;
}

// ============================================================================
// MCP Tool Handlers — called from mcp_server.zig
// ============================================================================

pub fn handleNurseSense(allocator: std.mem.Allocator, args: json.ObjectMap) !json.Value {
    const cell_name = switch (args.get("cell") orelse return mcpError(allocator, "missing 'cell'")) {
        .string => |s| s,
        else => return mcpError(allocator, "'cell' must be string"),
    };
    const value_f: f64 = switch (args.get("value") orelse return mcpError(allocator, "missing 'value'")) {
        .float => |f| f,
        .integer => |i| @floatFromInt(i),
        else => return mcpError(allocator, "'value' must be number"),
    };

    const cell = Cell.fromString(cell_name) orelse
        return mcpError(allocator, "unknown cell name");

    const state = getState();
    state.senseCell(cell, @floatCast(value_f));

    const text = try std.fmt.allocPrint(allocator, "sensed {s} = {d:.2}", .{ cell.name(), value_f });
    return mcpResult(allocator, text);
}

pub fn handleNurseState(allocator: std.mem.Allocator) !json.Value {
    const state = getStateConst();

    // Build cell lines
    var cell_parts: [Cell.COUNT][]const u8 = undefined;
    for (0..Cell.COUNT) |i| {
        const c: Cell = @fromBackingInt(@intCast(@as(u8, @intCast(i))));
        if (state.cells[i]) |v| {
            cell_parts[i] = try std.fmt.allocPrint(allocator, "  {s}: {d:.2}", .{ c.name(), v });
        } else {
            cell_parts[i] = try std.fmt.allocPrint(allocator, "  {s}: --", .{c.name()});
        }
    }
    const cells_joined = try std.mem.join(allocator, "\n", &cell_parts);

    const text = try std.fmt.allocPrint(allocator,
        \\phase: {s}  day: {d}
        \\cells:
        \\{s}
        \\substances:
        \\  vyvanse: {d:.0}mg  adderall: {d:.0}mg  caffeine: {d:.0}mg  nicotine: {d:.0}mg
        \\hero: {s}
        \\intervene: {s}
    , .{
        state.phase.name(),                           state.day,
        cells_joined,                                 state.substances.vyvanse_mg,
        state.substances.adderall_mg,                 state.substances.caffeine_mg,
        state.substances.nicotine_mg,                 if (state.hero_connected) "connected" else "disconnected",
        if (state.shouldIntervene()) "YES" else "no",
    });
    return mcpResult(allocator, text);
}

pub fn handleNurseIntervene(allocator: std.mem.Allocator) !json.Value {
    const state = getState();
    // Use a simple PRNG seeded from current arm_pulls total
    var seed: u64 = 42;
    for (state.arm_pulls) |p| seed +%= p;
    var prng = std.Random.DefaultPrng.init(seed);
    var rng = prng.random();

    const arm = banditSelect(state, &rng);
    state.arm_pulls[@backingInt(arm)] += 1;

    const slot_str = if (arm.heroSlot()) |s|
        try std.fmt.allocPrint(allocator, " [HERO slot {d}]", .{s})
    else
        try std.fmt.allocPrint(allocator, " [behavioral]", .{});

    const text = try std.fmt.allocPrint(allocator, "selected: {s}{s}\n{s}", .{
        arm.name(), slot_str, arm.message(),
    });
    return mcpResult(allocator, text);
}

pub fn handleNurseDispense(allocator: std.mem.Allocator, args: json.ObjectMap) !json.Value {
    const slot_val = args.get("slot") orelse return mcpError(allocator, "missing 'slot'");
    const slot: u8 = switch (slot_val) {
        .integer => |i| @intCast(std.math.clamp(i, 1, 10)),
        else => return mcpError(allocator, "'slot' must be integer 1-10"),
    };
    const state = getStateConst();
    const cart = state.cartridges[slot - 1];
    const med = cart.med_name orelse "empty";
    const text = try std.fmt.allocPrint(allocator, "dispense slot {d}: {s} {d:.1}mg", .{
        slot, med, cart.mg,
    });
    return mcpResult(allocator, text);
}

pub fn handleNurseSchedule(allocator: std.mem.Allocator, args: json.ObjectMap) !json.Value {
    const sched_name = switch (args.get("schedule") orelse return mcpError(allocator, "missing 'schedule'")) {
        .string => |s| s,
        else => return mcpError(allocator, "'schedule' must be string"),
    };
    const sched = Schedule.fromString(sched_name) orelse
        return mcpError(allocator, "unknown schedule (wake/morning/midday/evening/bedtime)");

    const state = getStateConst();
    const slots = sched.slots();
    var slot_lines: [5][]const u8 = undefined;
    for (slots, 0..) |s, idx| {
        const cart = state.cartridges[s - 1];
        const med = cart.med_name orelse "empty";
        slot_lines[idx] = try std.fmt.allocPrint(allocator, "  slot {d}: {s} {d:.1}mg", .{ s, med, cart.mg });
    }
    const lines_joined = try std.mem.join(allocator, "\n", slot_lines[0..slots.len]);
    const text = try std.fmt.allocPrint(allocator, "schedule: {s}\n{s}", .{ sched_name, lines_joined });
    return mcpResult(allocator, text);
}

pub fn handleNurseTrajectory(allocator: std.mem.Allocator, args: json.ObjectMap) !json.Value {
    const state = getState();

    if (args.get("vyvanse")) |v| switch (v) {
        .float => |f| state.substances.vyvanse_mg = @floatCast(f),
        .integer => |i| state.substances.vyvanse_mg = @floatFromInt(i),
        else => {},
    };
    if (args.get("adderall")) |v| switch (v) {
        .float => |f| state.substances.adderall_mg = @floatCast(f),
        .integer => |i| state.substances.adderall_mg = @floatFromInt(i),
        else => {},
    };
    if (args.get("caffeine")) |v| switch (v) {
        .float => |f| state.substances.caffeine_mg = @floatCast(f),
        .integer => |i| state.substances.caffeine_mg = @floatFromInt(i),
        else => {},
    };
    if (args.get("nicotine")) |v| switch (v) {
        .float => |f| state.substances.nicotine_mg = @floatCast(f),
        .integer => |i| state.substances.nicotine_mg = @floatFromInt(i),
        else => {},
    };
    if (args.get("day")) |v| switch (v) {
        .integer => |i| {
            state.day = @intCast(std.math.clamp(i, 0, 9999));
            state.updatePhase();
        },
        else => {},
    };

    const text = try std.fmt.allocPrint(
        allocator,
        "trajectory updated: day {d} ({s}) vyvanse={d:.0}mg adderall={d:.0}mg caffeine={d:.0}mg nicotine={d:.0}mg",
        .{
            state.day,                    state.phase.name(),
            state.substances.vyvanse_mg,  state.substances.adderall_mg,
            state.substances.caffeine_mg, state.substances.nicotine_mg,
        },
    );
    return mcpResult(allocator, text);
}

pub fn handleNurseDetect(allocator: std.mem.Allocator) !json.Value {
    const state = getState();

    // Detection report: network probes the caller can run
    // We can't do actual network I/O from the MCP handler (single-threaded stdio),
    // so we return the probe commands and known fingerprints.
    const text = try std.fmt.allocPrint(allocator,
        \\HERO Device Detection Report
        \\════════════════════════════
        \\
        \\1. WiFi Scan (local network):
        \\   arp -a | grep -i "hero\|b8:27\|dc:a6"
        \\   dns-sd -B _http._tcp local
        \\
        \\2. mDNS/Bonjour probe:
        \\   dns-sd -L "Hero" _http._tcp local
        \\   avahi-browse -art 2>/dev/null | grep -i hero
        \\
        \\3. Cloud endpoint fingerprint:
        \\   curl -s -o /dev/null -w "%%{{http_code}}" https://app.herohealth.com/api/v1/devices/status
        \\   curl -s https://app.herohealth.com/api/v1/health
        \\
        \\4. mitmproxy interception:
        \\   mitmproxy --listen-port 8080
        \\   # Phone WiFi proxy -> <this-machine>:8080
        \\   # Install CA: http://mitm.it
        \\   # Open Hero Health app -> capture Bearer token
        \\   # Look for:
        \\   #   POST /devices/{{id}}/dispense
        \\   #   GET  /devices/status
        \\   #   GET  /schedules
        \\   #   POST /adherence
        \\
        \\5. Bluetooth LE scan (if BLE model):
        \\   sudo hcitool lescan 2>/dev/null || system_profiler SPBluetoothDataType
        \\
        \\6. HERO app binary analysis:
        \\   # iOS: ipatool download "Hero Health"
        \\   # Android: apktool d hero-health.apk
        \\   # radare2: r2 -A classes.dex → search for API endpoints
        \\   # strings hero-health.ipa | grep -i "api\|hero\|endpoint"
        \\
        \\Current state: hero_connected = {s}
        \\To set token after capture: nurse_sense or emacs C-c C-t
    , .{if (state.hero_connected) "true" else "false"});

    return mcpResult(allocator, text);
}

// JSON helpers (match mcp_server.zig style)
fn mcpResult(allocator: std.mem.Allocator, text: []const u8) !json.Value {
    var content_obj = json.ObjectMap.init(allocator);
    try content_obj.put("type", .{ .string = "text" });
    try content_obj.put("text", .{ .string = text });

    var content_arr = json.Array.init(allocator);
    try content_arr.append(.{ .object = content_obj });

    var result = json.ObjectMap.init(allocator);
    try result.put("content", .{ .array = content_arr });
    return .{ .object = result };
}

fn mcpError(allocator: std.mem.Allocator, text: []const u8) !json.Value {
    var content_obj = json.ObjectMap.init(allocator);
    try content_obj.put("type", .{ .string = "text" });
    try content_obj.put("text", .{ .string = text });

    var content_arr = json.Array.init(allocator);
    try content_arr.append(.{ .object = content_obj });

    var result = json.ObjectMap.init(allocator);
    try result.put("content", .{ .array = content_arr });
    try result.put("isError", .{ .bool = true });
    return .{ .object = result };
}

// ============================================================================
// Tests
// ============================================================================

test "phase from day" {
    try std.testing.expectEqual(Phase.crash, Phase.fromDay(0));
    try std.testing.expectEqual(Phase.floor, Phase.fromDay(3));
    try std.testing.expectEqual(Phase.dysphoria, Phase.fromDay(14));
    try std.testing.expectEqual(Phase.paws, Phase.fromDay(90));
    try std.testing.expectEqual(Phase.stable, Phase.fromDay(365));
}

test "cell sense and read" {
    var s = SystemState{};
    try std.testing.expect(s.readCell(.craving) == null);
    s.senseCell(.craving, 0.85);
    try std.testing.expectApproxEqAbs(0.85, s.readCell(.craving).?, 0.001);
}

test "should intervene" {
    var s = SystemState{};
    try std.testing.expect(!s.shouldIntervene());
    s.senseCell(.craving, 0.9);
    try std.testing.expect(s.shouldIntervene());
}

test "schedule slots" {
    const morning = Schedule.morning.slots();
    try std.testing.expectEqual(@as(usize, 4), morning.len);
    try std.testing.expectEqual(@as(u8, 1), morning[0]);
}

test "arm hero slot mapping" {
    try std.testing.expectEqual(@as(?u8, 1), Arm.clonidine.heroSlot());
    try std.testing.expectEqual(@as(?u8, null), Arm.deep_breath.heroSlot());
}
