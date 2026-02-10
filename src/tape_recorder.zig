//! Tape Recorder — Damage-aware terminal session recording for boxxy
//!
//! Records damage.zig events + keystrokes into two formats:
//! 1. VHS tape format (charmbracelet/vhs) → bmorphism/boxxy tapes/ directory
//! 2. Syrup binary tape → OCapN-compatible replay for post-web transport
//!
//! Architecture:
//! ```
//!   Input Events ─┐
//!                  ├──→ TapeRecorder ──→ VHS .tape file (GIF/MP4 output)
//!   Damage Events ─┘         │
//!                            └──→ Syrup .stape file (binary replay)
//! ```
//!
//! Integration with boxxy:
//!   boxxy runs VMs via Joker/SCI REPL. Tapes record sessions for:
//!   - Demo generation (HOF, beta reduction, GF(3) composition)
//!   - Damage replay (which cells changed, when, why)
//!   - Performance profiling (dirty cell counts per frame)
//!
//! GF(3): tape-recorder (-1 validator) — records and validates frame integrity

const std = @import("std");
const syrup = @import("syrup");
const damage = @import("damage");
const Allocator = std.mem.Allocator;

// =============================================================================
// Tape Event Types
// =============================================================================

/// A single tape event — keystroke, damage, or metadata
pub const TapeEvent = union(enum) {
    /// User keystroke
    keystroke: Keystroke,
    /// Damage region from frame
    damage_frame: DamageFrame,
    /// Terminal resize
    resize: Resize,
    /// Metadata marker (session start, agent connect, etc.)
    marker: Marker,
    /// Frame snapshot (full cell grid at this point)
    snapshot: Snapshot,
};

pub const Keystroke = struct {
    timestamp_ms: i64,
    codepoint: u32,
    modifiers: u8, // packed: bit0=shift, bit1=alt, bit2=ctrl
    /// VHS-compatible key name (e.g. "Enter", "Ctrl+Q", "Backspace")
    vhs_key: []const u8,
};

pub const DamageFrame = struct {
    timestamp_ms: i64,
    frame_gen: u64,
    world_id: damage.WorldId,
    regions: []const damage.AABB,
    dirty_cell_count: u32,
    total_cell_count: u32,
    cause: damage.DamageCause,
};

pub const Resize = struct {
    timestamp_ms: i64,
    cols: u16,
    rows: u16,
};

pub const Marker = struct {
    timestamp_ms: i64,
    kind: MarkerKind,
    text: []const u8,
};

pub const MarkerKind = enum(u8) {
    session_start,
    session_end,
    agent_connect,
    agent_disconnect,
    world_hop,
    gf3_trit, // GF(3) classification event
    custom,
};

pub const Snapshot = struct {
    timestamp_ms: i64,
    cols: u16,
    rows: u16,
    /// Packed cell data: [codepoint:u32][fg:u24][bg:u24][attrs:u8] per cell
    cells: []const u8,
};

// =============================================================================
// VHS Tape Writer
// =============================================================================

/// Writes VHS-compatible tape files for charmbracelet/vhs
pub const VhsWriter = struct {
    events: std.ArrayListUnmanaged(TapeEvent),
    allocator: Allocator,
    /// VHS preamble settings
    config: VhsConfig,

    pub const VhsConfig = struct {
        output_gif: []const u8 = "session.gif",
        output_mp4: ?[]const u8 = null,
        font_family: []const u8 = "Berkeley Mono",
        font_size: u16 = 16,
        width: u16 = 1400,
        height: u16 = 900,
        theme: []const u8 = "Catppuccin Mocha",
        typing_speed: []const u8 = "30ms",
        padding: u16 = 20,
        title: []const u8 = "zoad session",
    };

    pub fn init(allocator: Allocator, config: VhsConfig) VhsWriter {
        return .{
            .events = .{},
            .allocator = allocator,
            .config = config,
        };
    }

    pub fn deinit(self: *VhsWriter) void {
        self.events.deinit(self.allocator);
    }

    pub fn record(self: *VhsWriter, event: TapeEvent) !void {
        try self.events.append(self.allocator, event);
    }

    /// Record a keystroke with automatic VHS key name mapping
    pub fn recordKeystroke(self: *VhsWriter, codepoint: u32, mods: u8) !void {
        const ts = std.time.milliTimestamp();
        const vhs_key = mapToVhsKey(codepoint, mods);
        try self.record(.{ .keystroke = .{
            .timestamp_ms = ts,
            .codepoint = codepoint,
            .modifiers = mods,
            .vhs_key = vhs_key,
        } });
    }

    /// Record a damage frame
    pub fn recordDamage(self: *VhsWriter, frame: DamageFrame) !void {
        try self.record(.{ .damage_frame = frame });
    }

    /// Record a marker
    pub fn recordMarker(self: *VhsWriter, kind: MarkerKind, text: []const u8) !void {
        try self.record(.{ .marker = .{
            .timestamp_ms = std.time.milliTimestamp(),
            .kind = kind,
            .text = text,
        } });
    }

    /// Export as VHS tape file content
    pub fn exportVhs(self: *const VhsWriter, allocator: Allocator) ![]u8 {
        var out = std.ArrayListUnmanaged(u8){};
        const writer = out.writer(allocator);

        // Preamble
        try writer.print("# boxxy tape — {s}\n", .{self.config.title});
        try writer.print("# Recorded by zoad damage.zig tape_recorder\n", .{});
        try writer.print("# Events: {d}\n\n", .{self.events.items.len});

        try writer.print("Output {s}\n", .{self.config.output_gif});
        if (self.config.output_mp4) |mp4| {
            try writer.print("Output {s}\n", .{mp4});
        }
        try writer.writeAll("\n");

        try writer.print("Set FontSize {d}\n", .{self.config.font_size});
        try writer.print("Set FontFamily \"{s}\"\n", .{self.config.font_family});
        try writer.print("Set Width {d}\n", .{self.config.width});
        try writer.print("Set Height {d}\n", .{self.config.height});
        try writer.print("Set Theme \"{s}\"\n", .{self.config.theme});
        try writer.print("Set TypingSpeed {s}\n", .{self.config.typing_speed});
        try writer.print("Set Padding {d}\n\n", .{self.config.padding});

        // Events
        var prev_ts: i64 = 0;
        var typing_buf = std.ArrayListUnmanaged(u8){};
        defer typing_buf.deinit(allocator);

        for (self.events.items) |event| {
            switch (event) {
                .keystroke => |ks| {
                    // Insert sleep if gap > 100ms
                    if (prev_ts > 0 and ks.timestamp_ms - prev_ts > 100) {
                        // Flush any accumulated typing
                        if (typing_buf.items.len > 0) {
                            try writer.print("Type \"{s}\"\n", .{typing_buf.items});
                            typing_buf.clearRetainingCapacity();
                        }
                        const gap = ks.timestamp_ms - prev_ts;
                        if (gap >= 1000) {
                            try writer.print("Sleep {d}s\n", .{@divFloor(gap, 1000)});
                        } else {
                            try writer.print("Sleep {d}ms\n", .{gap});
                        }
                    }

                    // Special keys get their own VHS command
                    if (ks.codepoint == '\r' or ks.codepoint == '\n') {
                        if (typing_buf.items.len > 0) {
                            try writer.print("Type \"{s}\"\n", .{typing_buf.items});
                            typing_buf.clearRetainingCapacity();
                        }
                        try writer.writeAll("Enter\n");
                    } else if (ks.modifiers & 0x04 != 0) { // ctrl
                        if (typing_buf.items.len > 0) {
                            try writer.print("Type \"{s}\"\n", .{typing_buf.items});
                            typing_buf.clearRetainingCapacity();
                        }
                        try writer.print("{s}\n", .{ks.vhs_key});
                    } else if (ks.codepoint >= 0x20 and ks.codepoint < 0x7F) {
                        // Accumulate printable chars
                        try typing_buf.append(allocator, @intCast(ks.codepoint));
                    } else {
                        if (typing_buf.items.len > 0) {
                            try writer.print("Type \"{s}\"\n", .{typing_buf.items});
                            typing_buf.clearRetainingCapacity();
                        }
                        try writer.print("{s}\n", .{ks.vhs_key});
                    }
                    prev_ts = ks.timestamp_ms;
                },
                .damage_frame => |df| {
                    // Emit as VHS comment with damage stats
                    try writer.print("# frame:{d} dirty:{d}/{d} regions:{d} cause:{s}\n", .{
                        df.frame_gen,
                        df.dirty_cell_count,
                        df.total_cell_count,
                        df.regions.len,
                        @tagName(df.cause),
                    });
                    prev_ts = df.timestamp_ms;
                },
                .resize => |r| {
                    try writer.print("# resize:{d}x{d}\n", .{ r.cols, r.rows });
                    prev_ts = r.timestamp_ms;
                },
                .marker => |m| {
                    try writer.print("# [{s}] {s}\n", .{ @tagName(m.kind), m.text });
                    if (m.kind == .session_start) {
                        try writer.writeAll("Sleep 1s\n");
                    }
                    prev_ts = m.timestamp_ms;
                },
                .snapshot => |s| {
                    try writer.print("# snapshot:{d}x{d} ({d} bytes)\n", .{
                        s.cols, s.rows, s.cells.len,
                    });
                    prev_ts = s.timestamp_ms;
                },
            }
        }

        // Flush remaining typing
        if (typing_buf.items.len > 0) {
            try writer.print("Type \"{s}\"\n", .{typing_buf.items});
        }

        try writer.writeAll("\nSleep 2s\n");

        return out.toOwnedSlice(allocator);
    }

    /// Export as Syrup binary tape (for OCapN replay)
    pub fn exportSyrup(self: *const VhsWriter, allocator: Allocator) !syrup.Value {
        var event_list = std.ArrayListUnmanaged(syrup.Value){};
        defer event_list.deinit(allocator);

        for (self.events.items) |event| {
            const val = try eventToSyrup(event, allocator);
            try event_list.append(allocator, val);
        }

        const label = try allocator.create(syrup.Value);
        label.* = .{ .symbol = "boxxy-tape" };

        const fields = try allocator.alloc(syrup.Value, 3);
        fields[0] = .{ .symbol = self.config.title };
        fields[1] = .{ .integer = @intCast(self.events.items.len) };
        fields[2] = .{ .list = try event_list.toOwnedSlice(allocator) };

        return .{ .record = .{ .label = label, .fields = fields } };
    }
};

// =============================================================================
// Damage-to-Tape Bridge
// =============================================================================

/// Hooks into DamageTracker to automatically record frames
pub const DamageTapeBridge = struct {
    writer: *VhsWriter,
    last_gen: u64,
    frame_count: u64,
    /// Only record frames with > threshold dirty cells (skip idle frames)
    dirty_threshold: u32,
    /// Record every Nth frame (1 = all frames, 5 = every 5th)
    sample_rate: u32,

    pub fn init(writer: *VhsWriter) DamageTapeBridge {
        return .{
            .writer = writer,
            .last_gen = 0,
            .frame_count = 0,
            .dirty_threshold = 0,
            .sample_rate = 1,
        };
    }

    /// Call this after each render frame to maybe record damage
    pub fn onFrame(
        self: *DamageTapeBridge,
        tracker: *damage.DamageTracker,
        total_cells: u32,
    ) !void {
        self.frame_count += 1;

        // Sample rate gating
        if (self.frame_count % self.sample_rate != 0) return;

        const w = tracker.worlds.get(tracker.active_world) orelse return;

        // Skip if generation hasn't changed (no damage)
        if (w.generation == self.last_gen) return;
        self.last_gen = w.generation;

        // Get coalesced regions
        const world_ptr = tracker.worlds.getPtr(tracker.active_world) orelse return;
        const regions = try world_ptr.coalesce();

        // Count dirty cells
        const dirty_count = @as(u32, @intCast(world_ptr.dirty_tiles.count()));

        // Threshold gating
        if (dirty_count < self.dirty_threshold) return;

        try self.writer.recordDamage(.{
            .timestamp_ms = std.time.milliTimestamp(),
            .frame_gen = w.generation,
            .world_id = tracker.active_world,
            .regions = regions,
            .dirty_cell_count = dirty_count,
            .total_cell_count = total_cells,
            .cause = if (world_ptr.full_redraw) .full_redraw else .state_mutation,
        });
    }

    /// Record a keystroke through the bridge
    pub fn onKeystroke(self: *DamageTapeBridge, codepoint: u32, mods: u8) !void {
        try self.writer.recordKeystroke(codepoint, mods);
    }
};

// =============================================================================
// Helpers
// =============================================================================

fn mapToVhsKey(codepoint: u32, mods: u8) []const u8 {
    const ctrl = mods & 0x04 != 0;

    if (ctrl) {
        return switch (codepoint) {
            'q', 'Q' => "Ctrl+Q",
            'b', 'B' => "Ctrl+B",
            'c', 'C' => "Ctrl+C",
            'd', 'D' => "Ctrl+D",
            'o', 'O' => "Ctrl+O",
            'l', 'L' => "Ctrl+L",
            else => "Ctrl+?",
        };
    }

    return switch (codepoint) {
        '\r', '\n' => "Enter",
        27 => "Escape",
        127, 8 => "Backspace",
        '\t' => "Tab",
        0x04000000 + 0x41 => "Up",
        0x04000000 + 0x42 => "Down",
        0x04000000 + 0x43 => "Right",
        0x04000000 + 0x44 => "Left",
        0x04000000 + 0x6f => "F1",
        else => "?",
    };
}

fn eventToSyrup(event: TapeEvent, allocator: Allocator) !syrup.Value {
    switch (event) {
        .keystroke => |ks| {
            const label = try allocator.create(syrup.Value);
            label.* = .{ .symbol = "keystroke" };
            const fields = try allocator.alloc(syrup.Value, 3);
            fields[0] = .{ .integer = @intCast(ks.timestamp_ms) };
            fields[1] = .{ .integer = @intCast(ks.codepoint) };
            fields[2] = .{ .integer = @intCast(ks.modifiers) };
            return .{ .record = .{ .label = label, .fields = fields } };
        },
        .damage_frame => |df| {
            const label = try allocator.create(syrup.Value);
            label.* = .{ .symbol = "damage-frame" };

            var region_list = std.ArrayListUnmanaged(syrup.Value){};
            defer region_list.deinit(allocator);
            for (df.regions) |r| {
                const entries = try allocator.alloc(syrup.Value, 4);
                entries[0] = .{ .integer = r.min_x };
                entries[1] = .{ .integer = r.min_y };
                entries[2] = .{ .integer = r.max_x };
                entries[3] = .{ .integer = r.max_y };
                try region_list.append(allocator, .{ .list = entries });
            }

            const fields = try allocator.alloc(syrup.Value, 5);
            fields[0] = .{ .integer = @intCast(df.timestamp_ms) };
            fields[1] = .{ .integer = @intCast(df.frame_gen) };
            fields[2] = .{ .integer = @intCast(df.dirty_cell_count) };
            fields[3] = .{ .integer = @intCast(df.total_cell_count) };
            fields[4] = .{ .list = try region_list.toOwnedSlice(allocator) };
            return .{ .record = .{ .label = label, .fields = fields } };
        },
        .resize => |r| {
            const label = try allocator.create(syrup.Value);
            label.* = .{ .symbol = "resize" };
            const fields = try allocator.alloc(syrup.Value, 3);
            fields[0] = .{ .integer = @intCast(r.timestamp_ms) };
            fields[1] = .{ .integer = r.cols };
            fields[2] = .{ .integer = r.rows };
            return .{ .record = .{ .label = label, .fields = fields } };
        },
        .marker => |m| {
            const label = try allocator.create(syrup.Value);
            label.* = .{ .symbol = "marker" };
            const fields = try allocator.alloc(syrup.Value, 3);
            fields[0] = .{ .integer = @intCast(m.timestamp_ms) };
            fields[1] = .{ .symbol = @tagName(m.kind) };
            fields[2] = .{ .symbol = m.text };
            return .{ .record = .{ .label = label, .fields = fields } };
        },
        .snapshot => |s| {
            const label = try allocator.create(syrup.Value);
            label.* = .{ .symbol = "snapshot" };
            const fields = try allocator.alloc(syrup.Value, 4);
            fields[0] = .{ .integer = @intCast(s.timestamp_ms) };
            fields[1] = .{ .integer = s.cols };
            fields[2] = .{ .integer = s.rows };
            fields[3] = .{ .bytestring = s.cells };
            return .{ .record = .{ .label = label, .fields = fields } };
        },
    }
}

// =============================================================================
// Tests
// =============================================================================

test "VhsWriter basic recording" {
    const allocator = std.testing.allocator;

    var writer = VhsWriter.init(allocator, .{
        .title = "test tape",
        .output_gif = "test.gif",
    });
    defer writer.deinit();

    try writer.recordMarker(.session_start, "zoad test session");
    try writer.recordKeystroke('h', 0);
    try writer.recordKeystroke('i', 0);
    try writer.recordKeystroke('\r', 0);

    const vhs = try writer.exportVhs(allocator);
    defer allocator.free(vhs);

    // Should contain VHS preamble
    try std.testing.expect(std.mem.indexOf(u8, vhs, "Output test.gif") != null);
    try std.testing.expect(std.mem.indexOf(u8, vhs, "Set Theme") != null);
    try std.testing.expect(std.mem.indexOf(u8, vhs, "Enter") != null);
}

test "VhsWriter damage recording" {
    const allocator = std.testing.allocator;

    var writer = VhsWriter.init(allocator, .{});
    defer writer.deinit();

    const regions = [_]damage.AABB{
        .{ .min_x = 0, .min_y = 0, .max_x = 10, .max_y = 5, .z = 0 },
    };

    try writer.recordDamage(.{
        .timestamp_ms = 1000,
        .frame_gen = 1,
        .world_id = 0,
        .regions = &regions,
        .dirty_cell_count = 50,
        .total_cell_count = 2000,
        .cause = .state_mutation,
    });

    const vhs = try writer.exportVhs(allocator);
    defer allocator.free(vhs);

    // Damage frames appear as comments in VHS
    try std.testing.expect(std.mem.indexOf(u8, vhs, "# frame:1") != null);
    try std.testing.expect(std.mem.indexOf(u8, vhs, "dirty:50/2000") != null);
}

test "VhsWriter Syrup export" {
    const allocator = std.testing.allocator;

    var writer = VhsWriter.init(allocator, .{ .title = "syrup-test" });
    defer writer.deinit();

    try writer.recordMarker(.session_start, "begin");
    try writer.recordKeystroke('x', 0);

    const val = try writer.exportSyrup(allocator);
    defer val.deinitContainers(allocator);

    // Should be a record with label "boxxy-tape"
    try std.testing.expectEqual(syrup.Value.record, std.meta.activeTag(val));
    const label = val.record.label.*;
    try std.testing.expectEqualStrings("boxxy-tape", label.symbol);
}

test "DamageTapeBridge threshold gating" {
    const allocator = std.testing.allocator;

    var writer = VhsWriter.init(allocator, .{});
    defer writer.deinit();

    var bridge = DamageTapeBridge.init(&writer);
    bridge.dirty_threshold = 10; // Only record if >10 dirty cells

    var tracker = damage.DamageTracker.init(allocator);
    defer tracker.deinit();

    // Damage only 2 cells — should NOT record
    try tracker.damage(.{ .x = 0, .y = 0, .z = 0 }, .state_mutation);
    try tracker.damage(.{ .x = 1, .y = 0, .z = 0 }, .state_mutation);

    try bridge.onFrame(&tracker, 2000);

    try std.testing.expectEqual(@as(usize, 0), writer.events.items.len);
}

test "DamageTapeBridge sample rate" {
    const allocator = std.testing.allocator;

    var writer = VhsWriter.init(allocator, .{});
    defer writer.deinit();

    var bridge = DamageTapeBridge.init(&writer);
    bridge.sample_rate = 3; // Record every 3rd frame

    var tracker = damage.DamageTracker.init(allocator);
    defer tracker.deinit();

    // Force damage each frame
    for (0..9) |i| {
        try tracker.damage(.{ .x = @intCast(i), .y = 0, .z = 0 }, .state_mutation);
        try bridge.onFrame(&tracker, 2000);
    }

    // Should have recorded 3 frames (frame 3, 6, 9)
    try std.testing.expectEqual(@as(usize, 3), writer.events.items.len);
}

test "keystroke VHS key mapping" {
    try std.testing.expectEqualStrings("Enter", mapToVhsKey('\r', 0));
    try std.testing.expectEqualStrings("Escape", mapToVhsKey(27, 0));
    try std.testing.expectEqualStrings("Backspace", mapToVhsKey(127, 0));
    try std.testing.expectEqualStrings("Ctrl+Q", mapToVhsKey('q', 0x04));
    try std.testing.expectEqualStrings("Ctrl+B", mapToVhsKey('b', 0x04));
}
