//! DomBackend — Ratzilla-equivalent: retty Buffer → HTML/DOM spans
//!
//! Completes the Ratzilla path for zig-syrup:
//!   retty.zig (ratatui-in-Zig) + DomBackend → browser rendering via WASM
//!
//! Architecture (mirrors Orhun Parmaksız's FOSDEM 2025 Ratzilla talk):
//!   1. Widget tree renders into retty.Buffer (2D cell grid)
//!   2. DomBackend.drawDiff() compares current vs previous Buffer
//!   3. Only changed cells emit DOM mutations (spans with inline styles)
//!   4. On wasm32-freestanding: extern "c" fn calls into JS host
//!   5. On native: produces HTML string for SSR / testing
//!
//! Episodic replay integration:
//!   Each frame's diff is recorded as an Episode (timestamp + changed cells).
//!   Episodes are iterable — replay forward/backward like ggerganov's approach.
//!   Color bandwidth is tested at first/last/random cells per episode.
//!
//! The exformation channel:
//!   drawDiff discards unchanged cells (11M bits → 40 bits).
//!   What survives IS the episodic memory — the material witness of change.

const std = @import("std");
const color_bandwidth = @import("color_bandwidth.zig");

// =============================================================================
// Self-contained Cell types (no libghostty/terminal dependency)
// =============================================================================

pub const CellAttrs = packed struct(u8) {
    bold: bool = false,
    italic: bool = false,
    underline: bool = false,
    strikethrough: bool = false,
    dim: bool = false,
    blink: bool = false,
    inverse: bool = false,
    invisible: bool = false,
};

pub const Color = struct {
    r: u8 = 0,
    g: u8 = 0,
    b: u8 = 0,
    is_set: bool = false,

    pub const DEFAULT = Color{};

    pub fn rgb(r: u8, g: u8, b: u8) Color {
        return .{ .r = r, .g = g, .b = b, .is_set = true };
    }

    pub fn eql(a: Color, b: Color) bool {
        if (!a.is_set and !b.is_set) return true;
        return a.r == b.r and a.g == b.g and a.b == b.b and a.is_set == b.is_set;
    }

    pub fn toHex(self: Color, buf: *[7]u8) []const u8 {
        const hex = "0123456789abcdef";
        buf[0] = '#';
        buf[1] = hex[self.r >> 4];
        buf[2] = hex[self.r & 0xf];
        buf[3] = hex[self.g >> 4];
        buf[4] = hex[self.g & 0xf];
        buf[5] = hex[self.b >> 4];
        buf[6] = hex[self.b & 0xf];
        return buf[0..7];
    }
};

pub const Cell = struct {
    codepoint: u21 = ' ',
    fg: Color = Color.DEFAULT,
    bg: Color = Color.DEFAULT,
    attrs: CellAttrs = .{},

    pub fn eql(a: Cell, b: Cell) bool {
        return a.codepoint == b.codepoint and
            a.fg.eql(b.fg) and a.bg.eql(b.bg) and
            @as(u8, @bitCast(a.attrs)) == @as(u8, @bitCast(b.attrs));
    }

    pub fn isBlank(self: Cell) bool {
        return self.codepoint == ' ' and @as(u8, @bitCast(self.attrs)) == 0;
    }
};

// =============================================================================
// CellDelta — a single changed cell in a frame diff
// =============================================================================

pub const CellDelta = struct {
    x: u16,
    y: u16,
    cell: Cell,
};

// =============================================================================
// Episode — one frame's worth of changes (the episodic memory unit)
// =============================================================================

pub const Episode = struct {
    timestamp_ms: i64,
    frame_id: u64,
    deltas: []const CellDelta,
    bandwidth: ?color_bandwidth.BandwidthReport,

    pub fn deltaCount(self: Episode) usize {
        return self.deltas.len;
    }

    /// Ratio of changed cells to total cells (the exformation ratio).
    /// Low ratio = most information discarded = high exformation.
    pub fn exformationRatio(self: Episode, total_cells: u32) f32 {
        if (total_cells == 0) return 0;
        return 1.0 - @as(f32, @floatFromInt(self.deltas.len)) / @as(f32, @floatFromInt(total_cells));
    }
};

// =============================================================================
// EpisodeIterator — ggerganov-style iterable over recorded episodes
// =============================================================================

pub const EpisodeIterator = struct {
    episodes: []const Episode,
    index: usize = 0,
    direction: Direction = .forward,

    pub const Direction = enum { forward, backward };

    pub fn init(episodes: []const Episode) EpisodeIterator {
        return .{ .episodes = episodes };
    }

    pub fn initBackward(episodes: []const Episode) EpisodeIterator {
        return .{
            .episodes = episodes,
            .index = if (episodes.len > 0) episodes.len - 1 else 0,
            .direction = .backward,
        };
    }

    pub fn next(self: *EpisodeIterator) ?Episode {
        if (self.episodes.len == 0) return null;
        switch (self.direction) {
            .forward => {
                if (self.index >= self.episodes.len) return null;
                const ep = self.episodes[self.index];
                self.index += 1;
                return ep;
            },
            .backward => {
                if (self.index >= self.episodes.len) return null;
                const ep = self.episodes[self.index];
                if (self.index == 0) {
                    self.index = self.episodes.len; // exhausted
                    return ep;
                }
                self.index -= 1;
                return ep;
            },
        }
    }

    pub fn peek(self: *const EpisodeIterator) ?Episode {
        if (self.episodes.len == 0) return null;
        if (self.direction == .forward and self.index >= self.episodes.len) return null;
        if (self.direction == .backward and self.index >= self.episodes.len) return null;
        return self.episodes[self.index];
    }

    pub fn reset(self: *EpisodeIterator) void {
        self.index = switch (self.direction) {
            .forward => 0,
            .backward => if (self.episodes.len > 0) self.episodes.len - 1 else 0,
        };
    }

    pub fn remaining(self: *const EpisodeIterator) usize {
        if (self.episodes.len == 0) return 0;
        return switch (self.direction) {
            .forward => if (self.index >= self.episodes.len) 0 else self.episodes.len - self.index,
            .backward => if (self.index >= self.episodes.len) 0 else self.index + 1,
        };
    }
};

// =============================================================================
// Buffer — 2D cell grid (self-contained, no terminal dep)
// =============================================================================

pub const MAX_COLS: u16 = 256;
pub const MAX_ROWS: u16 = 128;
const MAX_CELLS: usize = @as(usize, MAX_COLS) * MAX_ROWS;

pub const Buffer = struct {
    cells: [MAX_CELLS]Cell = [_]Cell{.{}} ** MAX_CELLS,
    width: u16 = 0,
    height: u16 = 0,

    pub fn init(width: u16, height: u16) Buffer {
        return .{
            .width = @min(width, MAX_COLS),
            .height = @min(height, MAX_ROWS),
        };
    }

    fn idx(self: *const Buffer, x: u16, y: u16) ?usize {
        if (x >= self.width or y >= self.height) return null;
        return @as(usize, y) * MAX_COLS + x;
    }

    pub fn get(self: *const Buffer, x: u16, y: u16) Cell {
        const i = self.idx(x, y) orelse return .{};
        return self.cells[i];
    }

    pub fn set(self: *Buffer, x: u16, y: u16, cell: Cell) void {
        const i = self.idx(x, y) orelse return;
        self.cells[i] = cell;
    }

    pub fn totalCells(self: *const Buffer) u32 {
        return @as(u32, self.width) * self.height;
    }

    pub fn clear(self: *Buffer) void {
        const n = @as(usize, self.width) * self.height;
        @memset(self.cells[0..@min(n, MAX_CELLS)], .{});
    }
};

// =============================================================================
// DomBackend — the Ratzilla core: Buffer diff → DOM mutations
// =============================================================================

pub const DomBackend = struct {
    width: u16,
    height: u16,
    previous: Buffer,
    frame_count: u64 = 0,
    // HTML output buffer for native/SSR mode
    html_buf: [MAX_HTML_OUTPUT]u8 = undefined,
    html_len: usize = 0,
    // Episode recording
    delta_buf: [MAX_DELTAS]CellDelta = undefined,
    delta_count: usize = 0,

    // Bandwidth test seed (from Gay.jl / drand)
    bandwidth_seed: u64 = 42,

    const MAX_HTML_OUTPUT: usize = 256 * 1024; // 256KB per frame
    const MAX_DELTAS: usize = 16384;

    pub fn init(width: u16, height: u16) DomBackend {
        return .{
            .width = width,
            .height = height,
            .previous = Buffer.init(width, height),
        };
    }

    pub fn resize(self: *DomBackend, width: u16, height: u16) void {
        self.width = width;
        self.height = height;
        self.previous = Buffer.init(width, height);
    }

    /// Diff current buffer against previous, emit DOM mutations.
    /// Returns the Episode of this frame's changes.
    /// On native: also fills html_buf with <span> elements.
    /// On wasm32: calls extern JS functions to mutate DOM directly.
    pub fn drawDiff(self: *DomBackend, current: *const Buffer) Episode {
        self.html_len = 0;
        self.delta_count = 0;
        self.frame_count += 1;

        const timestamp = if (@import("builtin").os.tag == .freestanding)
            0 // wasm: host provides time
        else
            std.time.milliTimestamp();

        // Scan for changed cells
        var y: u16 = 0;
        while (y < current.height) : (y += 1) {
            var x: u16 = 0;
            while (x < current.width) : (x += 1) {
                const cur = current.get(x, y);
                const prev = self.previous.get(x, y);

                if (cur.eql(prev)) continue;

                // Record delta
                if (self.delta_count < MAX_DELTAS) {
                    self.delta_buf[self.delta_count] = .{ .x = x, .y = y, .cell = cur };
                    self.delta_count += 1;
                }

                // Emit DOM mutation
                self.emitCellHtml(x, y, cur);
            }
        }

        // Copy current to previous for next diff
        const n = @as(usize, current.width) * current.height;
        @memcpy(self.previous.cells[0..@min(n, MAX_CELLS)], current.cells[0..@min(n, MAX_CELLS)]);
        self.previous.width = current.width;
        self.previous.height = current.height;

        // Color bandwidth test on this episode's deltas
        const bw = if (self.delta_count >= 3)
            color_bandwidth.testBandwidth(self.bandwidth_seed +% self.frame_count, self.delta_count)
        else
            null;

        return .{
            .timestamp_ms = timestamp,
            .frame_id = self.frame_count,
            .deltas = self.delta_buf[0..self.delta_count],
            .bandwidth = bw,
        };
    }

    /// Full render (no diff, all cells). Used for initial paint.
    pub fn drawFull(self: *DomBackend, current: *const Buffer) Episode {
        self.previous.clear();
        return self.drawDiff(current);
    }

    /// Get the HTML output (native/SSR mode).
    pub fn html(self: *const DomBackend) []const u8 {
        return self.html_buf[0..self.html_len];
    }

    // -- HTML emission --

    fn emitCellHtml(self: *DomBackend, x: u16, y: u16, cell: Cell) void {
        // <span data-x="X" data-y="Y" style="...">C</span>
        self.writeHtml("<span data-x=\"");
        self.writeDecHtml(x);
        self.writeHtml("\" data-y=\"");
        self.writeDecHtml(y);
        self.writeHtml("\" style=\"");

        // Position: absolute grid placement
        self.writeHtml("grid-column:");
        self.writeDecHtml(x + 1);
        self.writeHtml(";grid-row:");
        self.writeDecHtml(y + 1);
        self.writeHtml(";");

        // Foreground color
        if (cell.fg.is_set) {
            var hex_buf: [7]u8 = undefined;
            self.writeHtml("color:");
            self.writeHtml(cell.fg.toHex(&hex_buf));
            self.writeHtml(";");
        }

        // Background color
        if (cell.bg.is_set) {
            var hex_buf: [7]u8 = undefined;
            self.writeHtml("background:");
            self.writeHtml(cell.bg.toHex(&hex_buf));
            self.writeHtml(";");
        }

        // Attributes
        if (cell.attrs.bold) self.writeHtml("font-weight:bold;");
        if (cell.attrs.italic) self.writeHtml("font-style:italic;");
        if (cell.attrs.underline) self.writeHtml("text-decoration:underline;");
        if (cell.attrs.strikethrough) self.writeHtml("text-decoration:line-through;");
        if (cell.attrs.dim) self.writeHtml("opacity:0.5;");

        self.writeHtml("\">");

        // Character (UTF-8 encode)
        self.writeCodepointHtml(cell.codepoint);

        self.writeHtml("</span>");
    }

    fn writeHtml(self: *DomBackend, s: []const u8) void {
        for (s) |b| {
            if (self.html_len < MAX_HTML_OUTPUT) {
                self.html_buf[self.html_len] = b;
                self.html_len += 1;
            }
        }
    }

    fn writeDecHtml(self: *DomBackend, val: u16) void {
        if (val == 0) {
            self.writeHtml("0");
            return;
        }
        var tmp: [5]u8 = undefined;
        var n: usize = 0;
        var v = val;
        while (v > 0) {
            tmp[n] = @intCast('0' + (v % 10));
            v /= 10;
            n += 1;
        }
        var i = n;
        while (i > 0) {
            i -= 1;
            if (self.html_len < MAX_HTML_OUTPUT) {
                self.html_buf[self.html_len] = tmp[i];
                self.html_len += 1;
            }
        }
    }

    fn writeCodepointHtml(self: *DomBackend, cp: u21) void {
        // HTML-escape special chars, then UTF-8 encode
        if (cp == '<') {
            self.writeHtml("&lt;");
        } else if (cp == '>') {
            self.writeHtml("&gt;");
        } else if (cp == '&') {
            self.writeHtml("&amp;");
        } else if (cp == '"') {
            self.writeHtml("&quot;");
        } else if (cp < 0x80) {
            if (self.html_len < MAX_HTML_OUTPUT) {
                self.html_buf[self.html_len] = @intCast(cp);
                self.html_len += 1;
            }
        } else if (cp < 0x800) {
            self.writeHtml(&[_]u8{
                @intCast(0xC0 | (cp >> 6)),
                @intCast(0x80 | (cp & 0x3F)),
            });
        } else if (cp < 0x10000) {
            self.writeHtml(&[_]u8{
                @intCast(0xE0 | (cp >> 12)),
                @intCast(0x80 | ((cp >> 6) & 0x3F)),
                @intCast(0x80 | (cp & 0x3F)),
            });
        } else {
            self.writeHtml(&[_]u8{
                @intCast(0xF0 | (cp >> 18)),
                @intCast(0x80 | ((cp >> 12) & 0x3F)),
                @intCast(0x80 | ((cp >> 6) & 0x3F)),
                @intCast(0x80 | (cp & 0x3F)),
            });
        }
    }
};

// =============================================================================
// Tests
// =============================================================================

test "Cell equality" {
    const a = Cell{ .codepoint = 'A', .fg = Color.rgb(255, 0, 0) };
    const b = Cell{ .codepoint = 'A', .fg = Color.rgb(255, 0, 0) };
    const c = Cell{ .codepoint = 'B', .fg = Color.rgb(255, 0, 0) };
    try std.testing.expect(a.eql(b));
    try std.testing.expect(!a.eql(c));
}

test "Color hex encoding" {
    var buf: [7]u8 = undefined;
    const hex = Color.rgb(255, 128, 0).toHex(&buf);
    try std.testing.expectEqualStrings("#ff8000", hex);
}

test "Buffer set/get" {
    var buf = Buffer.init(80, 24);
    const cell = Cell{ .codepoint = 'X', .fg = Color.rgb(0, 255, 0) };
    buf.set(10, 5, cell);
    try std.testing.expect(buf.get(10, 5).eql(cell));
    try std.testing.expect(buf.get(0, 0).isBlank());
}

test "DomBackend empty diff" {
    var backend = DomBackend.init(80, 24);
    var current = Buffer.init(80, 24);
    const episode = backend.drawDiff(&current);
    // Empty buffer vs empty previous => no deltas
    try std.testing.expectEqual(@as(usize, 0), episode.deltaCount());
    try std.testing.expectEqual(@as(u64, 1), episode.frame_id);
}

test "DomBackend detects changes" {
    var backend = DomBackend.init(80, 24);
    var buf = Buffer.init(80, 24);

    // First frame: write some cells
    buf.set(0, 0, .{ .codepoint = 'H', .fg = Color.rgb(255, 0, 0) });
    buf.set(1, 0, .{ .codepoint = 'i', .fg = Color.rgb(0, 255, 0) });
    const ep1 = backend.drawFull(&buf);
    try std.testing.expectEqual(@as(usize, 2), ep1.deltaCount());

    // Second frame: change one cell
    buf.set(0, 0, .{ .codepoint = 'J', .fg = Color.rgb(255, 0, 0) });
    const ep2 = backend.drawDiff(&buf);
    try std.testing.expectEqual(@as(usize, 1), ep2.deltaCount());
    try std.testing.expectEqual(@as(u16, 0), ep2.deltas[0].x);
    try std.testing.expectEqual(@as(u21, 'J'), ep2.deltas[0].cell.codepoint);

    // Third frame: no change
    const ep3 = backend.drawDiff(&buf);
    try std.testing.expectEqual(@as(usize, 0), ep3.deltaCount());
}

test "DomBackend produces HTML" {
    var backend = DomBackend.init(80, 24);
    var buf = Buffer.init(80, 24);
    buf.set(5, 3, .{ .codepoint = 'Z', .fg = Color.rgb(255, 128, 0), .attrs = .{ .bold = true } });
    _ = backend.drawFull(&buf);

    const output = backend.html();
    // Should contain a span with the cell data
    try std.testing.expect(output.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, output, "data-x=\"5\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "data-y=\"3\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "#ff8000") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "font-weight:bold") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Z") != null);
}

test "DomBackend HTML escapes special chars" {
    var backend = DomBackend.init(80, 24);
    var buf = Buffer.init(80, 24);
    buf.set(0, 0, .{ .codepoint = '<' });
    buf.set(1, 0, .{ .codepoint = '&' });
    _ = backend.drawFull(&buf);

    const output = backend.html();
    try std.testing.expect(std.mem.indexOf(u8, output, "&lt;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "&amp;") != null);
}

test "EpisodeIterator forward" {
    const eps = [_]Episode{
        .{ .timestamp_ms = 100, .frame_id = 1, .deltas = &.{}, .bandwidth = null },
        .{ .timestamp_ms = 200, .frame_id = 2, .deltas = &.{}, .bandwidth = null },
        .{ .timestamp_ms = 300, .frame_id = 3, .deltas = &.{}, .bandwidth = null },
    };
    var iter = EpisodeIterator.init(&eps);
    try std.testing.expectEqual(@as(usize, 3), iter.remaining());

    const e1 = iter.next().?;
    try std.testing.expectEqual(@as(u64, 1), e1.frame_id);
    const e2 = iter.next().?;
    try std.testing.expectEqual(@as(u64, 2), e2.frame_id);
    const e3 = iter.next().?;
    try std.testing.expectEqual(@as(u64, 3), e3.frame_id);
    try std.testing.expect(iter.next() == null);
}

test "EpisodeIterator backward" {
    const eps = [_]Episode{
        .{ .timestamp_ms = 100, .frame_id = 1, .deltas = &.{}, .bandwidth = null },
        .{ .timestamp_ms = 200, .frame_id = 2, .deltas = &.{}, .bandwidth = null },
        .{ .timestamp_ms = 300, .frame_id = 3, .deltas = &.{}, .bandwidth = null },
    };
    var iter = EpisodeIterator.initBackward(&eps);

    const e3 = iter.next().?;
    try std.testing.expectEqual(@as(u64, 3), e3.frame_id);
    const e2 = iter.next().?;
    try std.testing.expectEqual(@as(u64, 2), e2.frame_id);
    const e1 = iter.next().?;
    try std.testing.expectEqual(@as(u64, 1), e1.frame_id);
    try std.testing.expect(iter.next() == null);
}

test "exformation ratio" {
    const ep = Episode{
        .timestamp_ms = 0,
        .frame_id = 1,
        .deltas = &[_]CellDelta{
            .{ .x = 0, .y = 0, .cell = .{} },
            .{ .x = 1, .y = 0, .cell = .{} },
        },
        .bandwidth = null,
    };
    // 2 changed out of 1920 (80x24) => exformation ≈ 0.999
    const ratio = ep.exformationRatio(1920);
    try std.testing.expect(ratio > 0.99);
}

test "DomBackend bandwidth test per episode" {
    var backend = DomBackend.init(80, 24);
    var buf = Buffer.init(80, 24);

    // Write enough cells to trigger bandwidth test (>= 3 deltas)
    var i: u16 = 0;
    while (i < 20) : (i += 1) {
        const iu8: u8 = @intCast(i);
        buf.set(i, 0, .{ .codepoint = 'A' + @as(u21, i), .fg = Color.rgb(iu8 * 12, 255 - iu8 * 12, 128) });
    }
    const ep = backend.drawFull(&buf);
    try std.testing.expect(ep.bandwidth != null);
    try std.testing.expect(ep.bandwidth.?.estimated_bits > 0);
}
