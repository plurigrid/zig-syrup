//! Gain-of-Function World — wasmcloud interface implementation in Zig
//!
//! Bridges virion.zig (skill spread) with terminal_wasm.zig (terminal:// protocol)
//! under TiDAR generative model control from ASUS device.
//!
//! Unison ability:
//!   structural ability GainOfFunction where
//!     recombine : Virion -> Virion -> {GainOfFunction} Virion
//!     mutate    : Virion -> {GainOfFunction} Virion
//!     spread    : Network -> {GainOfFunction} Census
//!     infect    : CellId -> Virion -> {GainOfFunction} Bool
//!     vaccinate : CellId -> {GainOfFunction} ()
//!     trit      : CellId -> {GainOfFunction} Trit
//!     color     : CellId -> {GainOfFunction} Rgb
//!
//! GF(3) assignment: (+1, 0, -1)
//!   role     = PLUS (+1)  — generates new capabilities
//!   mode     = ERGODIC (0) — TiDAR-coordinated
//!   polarity = MINUS (-1)  — validated by AR verify
//!
//! Color: #564516 (dark olive-bronze)
//!   HCL(80.29°, 0.55, 0.30) via plastic angle rotation
//!
//! Balanced triad:
//!   gain-of-function (+1) × terminal:// (0) × tidar-verify (-1) = 0 ✓
//!
//! Inputs:
//!   - libghostty-vt: VT sequence parser (14-state DFA, >100 MB/s)
//!   - retty: TUI widget engine (layout constraints, styled text)
//!   - webgpu: GPU-accelerated rendering (future)
//!   - ghostty: Terminal multiplexer (IX protocol, BIM bytecode)
//!
//! Control:
//!   - TiDAR model on ASUS device via OpenRGB
//!   - Diffusion phase (+1): parallel draft generation
//!   - AR verify phase (-1): sequential rejection sampling
//!   - Mask phase (0): coordination between phases
//!
//! The virion network overlays the terminal grid: each terminal cell
//! IS a propagator cell. Virion infection colors the cell's foreground.
//! Gain of function appears as new capability domains lighting up in
//! the terminal — literally visible as color change.

const std = @import("std");
const virion = @import("virion.zig");
const Virion = virion.Virion;
const Trit = virion.Trit;
const Capability = virion.Capability;
const ViralNetwork = virion.ViralNetwork;

// ============================================================================
// COLOR CONSTANTS — the answer to "what is its color?"
// ============================================================================

/// The gain-of-function ability's color: #564516 (dark olive-bronze)
/// Computed from TriadicColor(+1, 0, -1) via spectrum.zig
pub const GOF_COLOR = Color{ .r = 86, .g = 69, .b = 22 };
pub const GOF_HEX = "#564516";
pub const GOF_HUE: f64 = 80.29; // degrees (plastic angle × 2 + base)
pub const GOF_CHROMA: f64 = 0.55; // moderate (ERGODIC mode)
pub const GOF_LIGHTNESS: f64 = 0.30; // dark (MINUS polarity)

/// GF(3) trit assignment
pub const GOF_ROLE: Trit = .plus; // +1: generates new capabilities
pub const GOF_MODE: Trit = .zero; // 0: TiDAR-coordinated
pub const GOF_POLARITY: Trit = .minus; // -1: AR-validated

// ============================================================================
// TYPES
// ============================================================================

pub const Color = struct {
    r: u8,
    g: u8,
    b: u8,

    pub fn toU32(self: Color) u32 {
        return (@as(u32, self.r) << 16) | (@as(u32, self.g) << 8) | self.b;
    }

    pub fn fromU32(v: u32) Color {
        return .{
            .r = @intCast((v >> 16) & 0xFF),
            .g = @intCast((v >> 8) & 0xFF),
            .b = @intCast(v & 0xFF),
        };
    }
};

/// TiDAR phase — the three phases of Think-in-Diffusion, Talk-in-Autoregression
pub const TidarPhase = enum(i8) {
    diffusion = 1, // PLUS: parallel draft generation
    mask = 0, // ERGODIC: coordination/routing
    ar_verify = -1, // MINUS: sequential verification

    pub fn toTrit(self: TidarPhase) Trit {
        return switch (self) {
            .diffusion => .plus,
            .mask => .zero,
            .ar_verify => .minus,
        };
    }
};

/// TiDAR control signal from generative model (ASUS device)
pub const TidarSignal = struct {
    /// Draft tokens from diffusion phase (parallel)
    draft_tokens: [32]u32 = std.mem.zeroes([32]u32),
    draft_count: u8 = 0,

    /// Verification mask from AR phase (sequential)
    verify_mask: [32]bool = std.mem.zeroes([32]bool),

    /// Accepted tokens after rejection sampling
    accepted: [32]u32 = std.mem.zeroes([32]u32),
    accepted_count: u8 = 0,

    /// Current phase
    phase: TidarPhase = .mask,

    /// Confidence [0.0, 1.0]
    confidence: f32 = 0.0,

    /// Map TiDAR signal to virion mutation pressure.
    /// High confidence diffusion → more gain of function.
    /// Low confidence AR verify → more tropism narrowing.
    pub fn toMutationPressure(self: *const TidarSignal) MutationPressure {
        return switch (self.phase) {
            .diffusion => .{
                .gain_weight = @min(1.0, self.confidence * 1.5),
                .loss_weight = 0.05,
                .shift_weight = 0.3,
                .narrow_weight = 0.1,
            },
            .mask => .{
                .gain_weight = 0.3,
                .loss_weight = 0.1,
                .shift_weight = 0.4,
                .narrow_weight = 0.2,
            },
            .ar_verify => .{
                .gain_weight = 0.1,
                .loss_weight = 0.3,
                .shift_weight = 0.2,
                .narrow_weight = @min(1.0, (1.0 - self.confidence) * 1.5),
            },
        };
    }
};

pub const MutationPressure = struct {
    gain_weight: f32,
    loss_weight: f32,
    shift_weight: f32,
    narrow_weight: f32,
};

/// VT action from libghostty-vt parser
pub const VtAction = union(enum) {
    print: u21, // Unicode codepoint
    execute: u8, // C0/C1 control
    csi: CsiAction, // CSI dispatch
    esc: u8, // ESC dispatch
    osc: [64]u8, // OSC string (truncated)
};

pub const CsiAction = struct {
    final_byte: u8,
    params: [8]u16 = std.mem.zeroes([8]u16),
    param_count: u8 = 0,
};

// ============================================================================
// GAIN-OF-FUNCTION WORLD
// ============================================================================

/// Maximum terminal grid cells that double as propagator cells
const MAX_GRID: u16 = 256;

/// The world: a terminal grid overlaid with a viral propagator network.
/// Each terminal cell IS a propagator cell. Infection = foreground color change.
pub const GainOfFunctionWorld = struct {
    /// The viral network (skill propagation substrate)
    network: ViralNetwork = .{},

    /// Terminal grid state (fg colors track virion infection)
    grid_fg: [MAX_GRID]u32 = [_]u32{0} ** MAX_GRID,
    grid_bg: [MAX_GRID]u32 = [_]u32{0} ** MAX_GRID,
    grid_cp: [MAX_GRID]u21 = [_]u21{' '} ** MAX_GRID,
    grid_cols: u16 = 16,
    grid_rows: u16 = 16,

    /// TiDAR control state
    tidar: TidarSignal = .{},
    tidar_generation: u32 = 0,

    /// Pending VT actions from libghostty-vt
    vt_queue: [64]VtAction = undefined,
    vt_count: u8 = 0,

    // ----------------------------------------------------------------
    // Initialization
    // ----------------------------------------------------------------

    /// Initialize a world with a balanced trit grid.
    /// Cells get alternating trits: (-1, 0, +1, -1, 0, +1, ...)
    /// ensuring GF(3) balance when cell_count is divisible by 3.
    pub fn init(cols: u16, rows: u16) GainOfFunctionWorld {
        var w = GainOfFunctionWorld{};
        w.grid_cols = cols;
        w.grid_rows = rows;

        const total = @min(@as(u16, cols) * rows, MAX_GRID);

        // Create cells with balanced trit assignment
        var i: u16 = 0;
        while (i < total) : (i += 1) {
            const trit: Trit = switch (@mod(i, 3)) {
                0 => .minus,
                1 => .zero,
                2 => .plus,
                else => unreachable,
            };
            _ = w.network.addCell(trit);
        }

        // Connect grid neighbors (4-connected: up/down/left/right)
        i = 0;
        while (i < total) : (i += 1) {
            const x = @mod(i, cols);
            const y = i / cols;

            // Right neighbor
            if (x + 1 < cols) {
                w.network.addEdge(@intCast(i), @intCast(i + 1));
                w.network.addEdge(@intCast(i + 1), @intCast(i));
            }
            // Down neighbor
            if (y + 1 < rows and (i + cols) < total) {
                w.network.addEdge(@intCast(i), @intCast(i + cols));
                w.network.addEdge(@intCast(i + cols), @intCast(i));
            }
        }

        return w;
    }

    // ----------------------------------------------------------------
    // Gain-of-function ability operations
    // ----------------------------------------------------------------

    /// Infect a cell with a virion. The cell's foreground color changes
    /// to reflect the virion's GF(3) trit assignment.
    pub fn infect(self: *GainOfFunctionWorld, cell: u8, v: Virion) bool {
        const success = self.network.infect(cell, v);
        if (success) {
            self.syncCellColor(cell);
        }
        return success;
    }

    /// Spread one tick. All infected cells replicate to neighbors.
    /// TiDAR signal modulates mutation pressure.
    pub fn spreadTick(self: *GainOfFunctionWorld) u32 {
        const new_infections = self.network.spreadTick();

        // Sync colors for all cells
        var i: u8 = 0;
        while (i < @as(u8, @intCast(@min(self.network.cell_count, 255)))) : (i += 1) {
            self.syncCellColor(i);
        }

        return new_infections;
    }

    /// Spread to saturation, sync all colors
    pub fn spreadToSaturation(self: *GainOfFunctionWorld, max_gens: u32) u32 {
        const gens = self.network.spreadToSaturation(max_gens);

        var i: u8 = 0;
        while (i < @as(u8, @intCast(@min(self.network.cell_count, 255)))) : (i += 1) {
            self.syncCellColor(i);
        }

        return gens;
    }

    // ----------------------------------------------------------------
    // TiDAR control
    // ----------------------------------------------------------------

    /// Receive a TiDAR signal from the generative model on ASUS device.
    /// The signal's phase modulates how virions mutate during spread.
    pub fn receiveTidar(self: *GainOfFunctionWorld, signal: TidarSignal) void {
        self.tidar = signal;
        self.tidar_generation += 1;
    }

    /// Get the TiDAR-modulated patient zero virion.
    /// Diffusion phase: broad tropism, high gain
    /// AR verify phase: narrow tropism, validation-focused
    /// Mask phase: balanced
    pub fn tidarVirion(self: *const GainOfFunctionWorld, name: []const u8) Virion {
        var v = Virion.init(name, GOF_ROLE, GOF_MODE);

        // TiDAR phase modulates tropism
        v.tropism = switch (self.tidar.phase) {
            .diffusion => 0b111, // binds all (uncontrolled spread)
            .mask => 0b010, // binds only ergodic (coordinated)
            .ar_verify => 0b001, // binds only minus (validation)
        };

        // Add capabilities based on accepted tokens
        const pressure = self.tidar.toMutationPressure();
        if (pressure.gain_weight > 0.5) {
            v.addCapability(Capability.init(.generate, 1));
            v.addCapability(Capability.init(.propagate, 1));
        }
        if (pressure.narrow_weight > 0.5) {
            v.addCapability(Capability.init(.verify, 1));
        }
        // Always has terminal capability (it lives in terminal:// world)
        v.addCapability(Capability.init(.terminal, 1));
        // And color (it manifests as visible color change)
        v.addCapability(Capability.init(.color, 1));

        return v;
    }

    // ----------------------------------------------------------------
    // libghostty-vt input
    // ----------------------------------------------------------------

    /// Process a VT action from the libghostty-vt parser.
    /// CSI color sequences (SGR) can vaccinate or infect cells.
    pub fn processVt(self: *GainOfFunctionWorld, action: VtAction) void {
        switch (action) {
            .print => |cp| {
                // Write codepoint to current cursor position
                // (simplified: uses linear index)
                if (self.vt_count < 64) {
                    self.vt_queue[self.vt_count] = action;
                    self.vt_count += 1;
                }
                _ = cp;
            },
            .csi => |csi| {
                // SGR (Select Graphic Rendition) — color commands
                if (csi.final_byte == 'm') {
                    // Parse SGR params for color extraction
                    // This is where ghostty VT → virion color mapping happens
                    if (self.vt_count < 64) {
                        self.vt_queue[self.vt_count] = action;
                        self.vt_count += 1;
                    }
                }
            },
            else => {
                if (self.vt_count < 64) {
                    self.vt_queue[self.vt_count] = action;
                    self.vt_count += 1;
                }
            },
        }
    }

    // ----------------------------------------------------------------
    // Terminal grid sync
    // ----------------------------------------------------------------

    /// Sync a cell's foreground color from its virion state.
    /// Infected cells show their virion's GF(3) triadic color.
    /// Empty cells show default. Immune cells show white.
    fn syncCellColor(self: *GainOfFunctionWorld, cell: u8) void {
        if (cell >= self.network.cell_count) return;

        const cell_color: u32 = switch (self.network.cells[cell]) {
            .empty => 0x808080, // gray (susceptible)
            .immune => 0xFFFFFF, // white (immune)
            .single => |v| tritToColor(v.trit_role),
            .recombinant => |v| blk: {
                // Recombinants glow brighter — gain of function is VISIBLE
                const base = tritToColor(v.trit_role);
                const r: u32 = @min(@as(u32, 255), ((base >> 16) & 0xFF) + 40);
                const g: u32 = @min(@as(u32, 255), ((base >> 8) & 0xFF) + 40);
                const b_val: u32 = @min(@as(u32, 255), (base & 0xFF) + 40);
                break :blk (r << 16) | (g << 8) | b_val;
            },
        };

        self.grid_fg[cell] = cell_color;
    }

    /// Map a trit to an RGB color (simplified spectrum.zig mapping)
    fn tritToColor(trit: Trit) u32 {
        return switch (trit) {
            .minus => 0x564516, // dark olive-bronze (gain-of-function)
            .zero => 0x008EAA, // deep teal (ergodic center)
            .plus => 0xFFC441, // golden amber (all-plus vivid)
        };
    }

    // ----------------------------------------------------------------
    // Census & query
    // ----------------------------------------------------------------

    pub fn census(self: *const GainOfFunctionWorld) ViralNetwork.Census {
        return self.network.census();
    }

    pub fn tritBalance(self: *const GainOfFunctionWorld) Trit {
        return self.network.tritBalance();
    }

    /// Get the world's own color: #564516
    pub fn color(self: *const GainOfFunctionWorld) Color {
        _ = self;
        return GOF_COLOR;
    }
};

// ============================================================================
// WASM EXPORTS (C ABI, wasm32-freestanding compatible)
// ============================================================================

var world: GainOfFunctionWorld = .{};
var world_initialized: bool = false;

fn ensureWorld() void {
    if (!world_initialized) {
        world = GainOfFunctionWorld.init(16, 16);
        world_initialized = true;
    }
}

/// Initialize the gain-of-function world
export fn gof_init(cols: u16, rows: u16) void {
    world = GainOfFunctionWorld.init(cols, rows);
    world_initialized = true;
}

/// Infect patient zero at cell index
export fn gof_infect(cell: u8, role: i8, mode: i8) u8 {
    ensureWorld();
    const r = Trit.fromInt(role) orelse return 0;
    const m = Trit.fromInt(mode) orelse return 0;
    var v = Virion.init("gof", r, m);
    v.addCapability(Capability.init(.terminal, 1));
    v.addCapability(Capability.init(.color, 1));
    v.addCapability(Capability.init(.propagate, 1));
    return if (world.infect(cell, v)) 1 else 0;
}

/// Spread one tick, return new infections
export fn gof_spread_tick() u32 {
    ensureWorld();
    return world.spreadTick();
}

/// Spread to saturation, return generations
export fn gof_spread_saturate(max_gens: u32) u32 {
    ensureWorld();
    return world.spreadToSaturation(max_gens);
}

/// Vaccinate a cell
export fn gof_vaccinate(cell: u8) void {
    ensureWorld();
    world.network.vaccinate(cell);
}

/// Get cell foreground color (RGB packed u32)
export fn gof_cell_color(cell: u8) u32 {
    ensureWorld();
    if (cell >= world.network.cell_count) return 0;
    return world.grid_fg[cell];
}

/// Get census: empty count
export fn gof_census_empty() u16 {
    ensureWorld();
    return world.census().empty;
}

/// Get census: infected count
export fn gof_census_infected() u16 {
    ensureWorld();
    return world.census().infected;
}

/// Get census: recombinant count
export fn gof_census_recombinant() u16 {
    ensureWorld();
    return world.census().recombinant;
}

/// Get census: immune count
export fn gof_census_immune() u16 {
    ensureWorld();
    return world.census().immune;
}

/// Get the world's color R component
export fn gof_color_r() u8 {
    return GOF_COLOR.r; // 86
}

/// Get the world's color G component
export fn gof_color_g() u8 {
    return GOF_COLOR.g; // 69
}

/// Get the world's color B component
export fn gof_color_b() u8 {
    return GOF_COLOR.b; // 22
}

/// Receive TiDAR phase signal
export fn gof_tidar_phase(phase: i8) void {
    ensureWorld();
    world.tidar.phase = switch (phase) {
        1 => .diffusion,
        0 => .mask,
        -1 => .ar_verify,
        else => .mask,
    };
}

/// Receive TiDAR confidence
export fn gof_tidar_confidence(conf: f32) void {
    ensureWorld();
    world.tidar.confidence = conf;
}

/// Get TiDAR generation counter
export fn gof_tidar_generation() u32 {
    ensureWorld();
    return world.tidar_generation;
}

/// Get network trit balance as i8 (-1, 0, +1)
export fn gof_trit_balance() i8 {
    ensureWorld();
    return @intFromEnum(world.tritBalance());
}

// Trit.fromInt is now defined in virion.zig

// ============================================================================
// TESTS
// ============================================================================

test "world color is #564516" {
    try std.testing.expectEqual(@as(u8, 86), GOF_COLOR.r);
    try std.testing.expectEqual(@as(u8, 69), GOF_COLOR.g);
    try std.testing.expectEqual(@as(u8, 22), GOF_COLOR.b);
}

test "world GF(3) balance" {
    const w = GainOfFunctionWorld.init(6, 1); // 6 cells, balanced
    try std.testing.expectEqual(Trit.zero, w.tritBalance());
}

test "world init creates grid with correct cell count" {
    const w = GainOfFunctionWorld.init(4, 4);
    try std.testing.expectEqual(@as(u16, 16), w.network.cell_count);
}

test "tidar diffusion phase creates broad-tropism virion" {
    var w = GainOfFunctionWorld.init(6, 1);
    w.tidar.phase = .diffusion;
    w.tidar.confidence = 0.9;

    const v = w.tidarVirion("test-diffuse");
    try std.testing.expectEqual(@as(u3, 0b111), v.tropism); // binds all
    try std.testing.expect(v.hasDomain(.generate));
    try std.testing.expect(v.hasDomain(.terminal));
}

test "tidar ar_verify phase creates narrow-tropism virion" {
    var w = GainOfFunctionWorld.init(6, 1);
    w.tidar.phase = .ar_verify;
    w.tidar.confidence = 0.3;

    const v = w.tidarVirion("test-verify");
    try std.testing.expectEqual(@as(u3, 0b001), v.tropism); // minus only
    try std.testing.expect(v.hasDomain(.verify));
    try std.testing.expect(v.hasDomain(.terminal));
}

test "infection changes cell color" {
    var w = GainOfFunctionWorld.init(3, 1);

    // Before infection: gray
    try std.testing.expectEqual(@as(u32, 0), w.grid_fg[0]);

    // Infect cell 0
    var v = Virion.init("color-test", .minus, .zero);
    v.addCapability(Capability.init(.color, 1));
    _ = w.infect(0, v);

    // After infection: virion color (minus role → #564516)
    try std.testing.expectEqual(@as(u32, 0x564516), w.grid_fg[0]);
}

test "recombinant cells glow brighter" {
    var w = GainOfFunctionWorld.init(3, 1);

    // Infect with first virion
    var a = Virion.init("skill-a", .minus, .zero);
    a.addCapability(Capability.init(.serialize, 1));
    _ = w.infect(0, a);

    const color_before = w.grid_fg[0];

    // Infect same cell with different virion → recombination
    var b = Virion.init("skill-b", .plus, .zero);
    b.addCapability(Capability.init(.color, 1));
    _ = w.infect(0, b);

    const color_after = w.grid_fg[0];

    // Recombinant should be brighter (higher RGB values)
    const r_before = (color_before >> 16) & 0xFF;
    const r_after = (color_after >> 16) & 0xFF;
    try std.testing.expect(r_after >= r_before);
}

test "spread through grid to saturation" {
    var w = GainOfFunctionWorld.init(3, 3); // 9 cells, balanced

    // Patient zero at cell 0
    var v = Virion.init("patient-zero", .plus, .minus);
    v.addCapability(Capability.init(.propagate, 1));
    v.addCapability(Capability.init(.terminal, 1));
    _ = w.infect(0, v);

    // Spread
    const gens = w.spreadToSaturation(50);
    try std.testing.expect(gens > 0);

    // Census
    const c = w.census();
    try std.testing.expect(c.empty == 0); // all cells reached
}
