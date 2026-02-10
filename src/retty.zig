//! retty — ratatui-like widget/layout engine for Zig
//!
//! A self-contained TUI framework that reuses Cell/CellAttrs from terminal.zig.
//! Provides layout constraint solving, styled text, and composable widgets
//! with a comptime Widget interface (duck typing).
//!
//! No allocator in hot path. wasm32-freestanding compatible.
//!
//! Architecture mirrors ratatui:
//!   Constraint → Layout → Rect splits
//!   Style → Span → Line → Text
//!   Buffer (2D cell grid with set/get)
//!   Widget interface (comptime duck typing)
//!   Block, Paragraph, List, Gauge widgets
//!   Frame (drawing context)
//!   AnsiBackend (buffer → ANSI escape sequences)

const terminal = @import("terminal");
pub const Cell = terminal.Cell;
pub const CellAttrs = terminal.CellAttrs;

// ============================================================================
// Platform detection
// ============================================================================

const builtin = @import("builtin");
const is_freestanding = builtin.os.tag == .freestanding;

// ============================================================================
// Rect — axis-aligned area rectangle
// ============================================================================

pub const Rect = struct {
    x: u16 = 0,
    y: u16 = 0,
    width: u16 = 0,
    height: u16 = 0,

    pub fn area(self: Rect) u32 {
        return @as(u32, self.width) * self.height;
    }

    pub fn left(self: Rect) u16 {
        return self.x;
    }

    pub fn right(self: Rect) u16 {
        return self.x +| self.width;
    }

    pub fn top(self: Rect) u16 {
        return self.y;
    }

    pub fn bottom(self: Rect) u16 {
        return self.y +| self.height;
    }

    pub fn isEmpty(self: Rect) bool {
        return self.width == 0 or self.height == 0;
    }

    /// Return inner rect with margin removed from each side.
    pub fn inner(self: Rect, margin: u16) Rect {
        const double = @as(u16, margin) *| 2;
        if (self.width <= double or self.height <= double) {
            return .{ .x = self.x, .y = self.y, .width = 0, .height = 0 };
        }
        return .{
            .x = self.x +| margin,
            .y = self.y +| margin,
            .width = self.width -| double,
            .height = self.height -| double,
        };
    }

    /// Split vertically into N rects according to constraints.
    pub fn splitVertical(self: Rect, constraints: []const Constraint, out: []Rect) void {
        solveLayout(self, .vertical, constraints, out);
    }

    /// Split horizontally into N rects according to constraints.
    pub fn splitHorizontal(self: Rect, constraints: []const Constraint, out: []Rect) void {
        solveLayout(self, .horizontal, constraints, out);
    }
};

// ============================================================================
// Constraint — layout size constraint
// ============================================================================

pub const Constraint = union(enum) {
    length: u16,
    min: u16,
    max: u16,
    percentage: u16,
    ratio: [2]u16, // [num, den]
    fill: void,
};

// ============================================================================
// Direction
// ============================================================================

pub const Direction = enum {
    vertical,
    horizontal,
};

// ============================================================================
// Layout solver
// ============================================================================

pub const MAX_SPLITS: usize = 16;

pub const Layout = struct {
    direction: Direction,
    constraints: []const Constraint,

    pub fn vertical(constraints: []const Constraint) Layout {
        return .{ .direction = .vertical, .constraints = constraints };
    }

    pub fn horizontal(constraints: []const Constraint) Layout {
        return .{ .direction = .horizontal, .constraints = constraints };
    }

    pub fn split(self: Layout, area: Rect, out: []Rect) void {
        solveLayout(area, self.direction, self.constraints, out);
    }
};

fn solveLayout(area: Rect, direction: Direction, constraints: []const Constraint, out: []Rect) void {
    const n = @min(constraints.len, out.len);
    if (n == 0) return;

    const total: u16 = switch (direction) {
        .vertical => area.height,
        .horizontal => area.width,
    };

    // First pass: calculate sizes
    var sizes: [MAX_SPLITS]u16 = [_]u16{0} ** MAX_SPLITS;
    var remaining: u16 = total;
    var fill_count: u16 = 0;

    // Resolve fixed-size constraints first
    for (constraints[0..n], 0..) |c, i| {
        sizes[i] = switch (c) {
            .length => |v| blk: {
                const s = @min(v, remaining);
                remaining -|= s;
                break :blk s;
            },
            .percentage => |pct| blk: {
                const s: u16 = @intCast((@as(u32, total) * @min(pct, 100)) / 100);
                const clamped = @min(s, remaining);
                remaining -|= clamped;
                break :blk clamped;
            },
            .ratio => |r| blk: {
                if (r[1] == 0) break :blk 0;
                const s: u16 = @intCast(@min(@as(u32, total) * r[0] / r[1], remaining));
                remaining -|= s;
                break :blk s;
            },
            .min => |v| blk: {
                const s = @min(v, remaining);
                remaining -|= s;
                break :blk s;
            },
            .max => |v| blk: {
                _ = v;
                // Max gets resolved after fills
                fill_count += 1;
                break :blk 0;
            },
            .fill => blk: {
                fill_count += 1;
                break :blk 0;
            },
        };
    }

    // Second pass: distribute remaining space to fill/max constraints
    if (fill_count > 0) {
        const per_fill = remaining / fill_count;
        var fill_remainder = remaining - per_fill * fill_count;

        for (constraints[0..n], 0..) |c, i| {
            switch (c) {
                .fill => {
                    sizes[i] = per_fill;
                    if (fill_remainder > 0) {
                        sizes[i] += 1;
                        fill_remainder -= 1;
                    }
                },
                .max => |v| {
                    sizes[i] = @min(per_fill, v);
                    if (fill_remainder > 0 and sizes[i] < v) {
                        sizes[i] += 1;
                        fill_remainder -= 1;
                    }
                },
                else => {},
            }
        }
    }

    // Third pass: build output rects
    var offset: u16 = 0;
    for (0..n) |i| {
        switch (direction) {
            .vertical => {
                out[i] = .{
                    .x = area.x,
                    .y = area.y +| offset,
                    .width = area.width,
                    .height = sizes[i],
                };
            },
            .horizontal => {
                out[i] = .{
                    .x = area.x +| offset,
                    .y = area.y,
                    .width = sizes[i],
                    .height = area.height,
                };
            },
        }
        offset +|= sizes[i];
    }
}

// ============================================================================
// Style — fg/bg/attrs combination
// ============================================================================

pub const Color = terminal.Color;

pub const Style = struct {
    fg_color: Color = Color.DEFAULT,
    bg_color: Color = Color.DEFAULT,
    attrs: CellAttrs = .{},

    pub const default: Style = .{};

    pub fn fg(color: Color) Style {
        return .{ .fg_color = color };
    }

    pub fn bg(color: Color) Style {
        return .{ .bg_color = color };
    }

    pub fn bold(self: Style) Style {
        var s = self;
        s.attrs.bold = true;
        return s;
    }

    pub fn italic(self: Style) Style {
        var s = self;
        s.attrs.italic = true;
        return s;
    }

    pub fn underline(self: Style) Style {
        var s = self;
        s.attrs.underline = true;
        return s;
    }

    pub fn dim(self: Style) Style {
        var s = self;
        s.attrs.dim = true;
        return s;
    }

    pub fn inverse(self: Style) Style {
        var s = self;
        s.attrs.inverse = true;
        return s;
    }

    pub fn withFg(self: Style, color: Color) Style {
        var s = self;
        s.fg_color = color;
        return s;
    }

    pub fn withBg(self: Style, color: Color) Style {
        var s = self;
        s.bg_color = color;
        return s;
    }

    /// Resolve color, defaulting to fallback if default.
    fn resolveColor(color: Color, fallback: Color) Color {
        if (color.tag == .default) return fallback;
        return color;
    }

    /// Apply style to a Cell, returning a new Cell with the style's colors/attrs.
    pub fn applyToCell(self: Style, cell: Cell) Cell {
        return .{
            .codepoint = cell.codepoint,
            .fg = resolveColor(self.fg_color, cell.fg),
            .bg = resolveColor(self.bg_color, cell.bg),
            .attrs = if (@as(u8, @bitCast(self.attrs)) != 0) self.attrs else cell.attrs,
        };
    }
};

// ============================================================================
// Span — styled text fragment
// ============================================================================

pub const MAX_SPANS_PER_LINE: usize = 32;
pub const MAX_LINES: usize = 256;

pub const Span = struct {
    content: []const u8,
    style: Style = .{},

    pub fn raw(content: []const u8) Span {
        return .{ .content = content };
    }

    pub fn styled(content: []const u8, style: Style) Span {
        return .{ .content = content, .style = style };
    }

    pub fn width(self: Span) u16 {
        // ASCII-only width (each byte = 1 column)
        return @intCast(@min(self.content.len, 65535));
    }
};

// ============================================================================
// Line — a sequence of spans forming one terminal row
// ============================================================================

pub const Line = struct {
    spans: []const Span = &.{},
    /// Convenience field for single-string lines (avoids needing a Span array).
    raw_content: []const u8 = "",

    pub fn from(spans: []const Span) Line {
        return .{ .spans = spans };
    }

    pub fn raw(content: []const u8) Line {
        return .{ .raw_content = content };
    }

    pub fn width(self: Line) u16 {
        if (self.raw_content.len > 0) {
            return @intCast(@min(self.raw_content.len, 65535));
        }
        var w: u16 = 0;
        for (self.spans) |span| {
            w +|= span.width();
        }
        return w;
    }
};

// ============================================================================
// Text — a sequence of lines
// ============================================================================

pub const Text = struct {
    lines: []const Line = &.{},

    pub fn from(lines: []const Line) Text {
        return .{ .lines = lines };
    }

    pub fn height(self: Text) u16 {
        return @intCast(@min(self.lines.len, 65535));
    }
};

// ============================================================================
// Buffer — 2D cell grid with set/get operations
// ============================================================================

pub const MAX_BUF_COLS: u16 = terminal.MAX_COLS;
pub const MAX_BUF_ROWS: u16 = terminal.MAX_ROWS;
const MAX_BUF_CELLS: usize = @as(usize, MAX_BUF_COLS) * MAX_BUF_ROWS;

pub const Buffer = struct {
    cells: [MAX_BUF_CELLS]Cell = [_]Cell{.{}} ** MAX_BUF_CELLS,
    area: Rect = .{},

    pub fn init(area: Rect) Buffer {
        return .{
            .area = .{
                .x = area.x,
                .y = area.y,
                .width = @min(area.width, MAX_BUF_COLS),
                .height = @min(area.height, MAX_BUF_ROWS),
            },
        };
    }

    fn idx(self: *const Buffer, x: u16, y: u16) ?usize {
        if (x < self.area.x or y < self.area.y) return null;
        const lx = x - self.area.x;
        const ly = y - self.area.y;
        if (lx >= self.area.width or ly >= self.area.height) return null;
        return @as(usize, ly) * MAX_BUF_COLS + lx;
    }

    pub fn get(self: *const Buffer, x: u16, y: u16) Cell {
        const i = self.idx(x, y) orelse return .{};
        return self.cells[i];
    }

    pub fn set(self: *Buffer, x: u16, y: u16, cell: Cell) void {
        const i = self.idx(x, y) orelse return;
        self.cells[i] = cell;
    }

    pub fn setChar(self: *Buffer, x: u16, y: u16, ch: u21) void {
        const i = self.idx(x, y) orelse return;
        self.cells[i].codepoint = ch;
    }

    pub fn setStyle(self: *Buffer, area: Rect, style: Style) void {
        const x0 = @max(area.x, self.area.x);
        const y0 = @max(area.y, self.area.y);
        const x1 = @min(area.right(), self.area.right());
        const y1 = @min(area.bottom(), self.area.bottom());

        var y = y0;
        while (y < y1) : (y += 1) {
            var x = x0;
            while (x < x1) : (x += 1) {
                const i = self.idx(x, y) orelse continue;
                self.cells[i] = style.applyToCell(self.cells[i]);
            }
        }
    }

    pub fn setString(self: *Buffer, x: u16, y: u16, string: []const u8, style: Style) void {
        var col = x;
        for (string) |byte| {
            if (col >= self.area.right()) break;
            const cell = style.applyToCell(.{ .codepoint = byte });
            self.set(col, y, cell);
            col +|= 1;
        }
    }

    pub fn setSpan(self: *Buffer, x: u16, y: u16, span: Span) u16 {
        self.setString(x, y, span.content, span.style);
        return @intCast(@min(span.content.len, 65535));
    }

    pub fn setLine(self: *Buffer, x: u16, y: u16, line: Line) void {
        if (line.raw_content.len > 0) {
            self.setString(x, y, line.raw_content, Style.default);
            return;
        }
        var col = x;
        for (line.spans) |span| {
            col +|= self.setSpan(col, y, span);
        }
    }

    /// Fill entire area with a cell.
    pub fn fill(self: *Buffer, cell: Cell) void {
        const total = @as(usize, self.area.width) * self.area.height;
        for (0..@min(total, MAX_BUF_CELLS)) |i| {
            self.cells[i] = cell;
        }
    }

    /// Clear buffer to default cells.
    pub fn clear(self: *Buffer) void {
        self.fill(.{});
    }

    /// Merge another buffer's cells into this one (for compositing).
    pub fn merge(self: *Buffer, other: *const Buffer) void {
        const x0 = @max(self.area.x, other.area.x);
        const y0 = @max(self.area.y, other.area.y);
        const x1 = @min(self.area.right(), other.area.right());
        const y1 = @min(self.area.bottom(), other.area.bottom());

        var y = y0;
        while (y < y1) : (y += 1) {
            var x = x0;
            while (x < x1) : (x += 1) {
                const cell = other.get(x, y);
                if (!cell.isBlank()) {
                    self.set(x, y, cell);
                }
            }
        }
    }
};

// ============================================================================
// Widget interface — comptime duck typing
// ============================================================================

/// Render any type that has `fn render(self, Rect, *Buffer) void`.
pub fn renderWidget(widget: anytype, area: Rect, buf: *Buffer) void {
    const T = @TypeOf(widget);
    if (@typeInfo(T) == .pointer) {
        widget.render(area, buf);
    } else {
        widget.render(area, buf);
    }
}

// ============================================================================
// Border — border characters and style
// ============================================================================

pub const BorderType = enum {
    none,
    plain,
    rounded,
    double,
    thick,
};

pub const Borders = packed struct(u8) {
    top: bool = false,
    right: bool = false,
    bottom: bool = false,
    left_side: bool = false,
    _pad: u4 = 0,

    pub const NONE: Borders = .{};
    pub const ALL: Borders = .{ .top = true, .right = true, .bottom = true, .left_side = true };
    pub const TOP: Borders = .{ .top = true };
    pub const BOTTOM: Borders = .{ .bottom = true };
    pub const LEFT: Borders = .{ .left_side = true };
    pub const RIGHT: Borders = .{ .right = true };
};

fn borderChars(border_type: BorderType) struct { tl: u21, tr: u21, bl: u21, br: u21, h: u21, v: u21 } {
    return switch (border_type) {
        .none => .{ .tl = ' ', .tr = ' ', .bl = ' ', .br = ' ', .h = ' ', .v = ' ' },
        .plain => .{ .tl = 0x250C, .tr = 0x2510, .bl = 0x2514, .br = 0x2518, .h = 0x2500, .v = 0x2502 },
        .rounded => .{ .tl = 0x256D, .tr = 0x256E, .bl = 0x2570, .br = 0x256F, .h = 0x2500, .v = 0x2502 },
        .double => .{ .tl = 0x2554, .tr = 0x2557, .bl = 0x255A, .br = 0x255D, .h = 0x2550, .v = 0x2551 },
        .thick => .{ .tl = 0x250F, .tr = 0x2513, .bl = 0x2517, .br = 0x251B, .h = 0x2501, .v = 0x2503 },
    };
}

// ============================================================================
// Block widget — borders, title, padding
// ============================================================================

pub const Block = struct {
    title: []const u8 = "",
    borders: Borders = Borders.NONE,
    border_type: BorderType = .plain,
    border_style: Style = .{},
    title_style: Style = .{},
    padding: Padding = .{},

    pub const Padding = struct {
        left: u16 = 0,
        right: u16 = 0,
        top: u16 = 0,
        bottom: u16 = 0,
    };

    pub fn default() Block {
        return .{};
    }

    pub fn withTitle(self: Block, title: []const u8) Block {
        var b = self;
        b.title = title;
        return b;
    }

    pub fn withBorders(self: Block, borders: Borders) Block {
        var b = self;
        b.borders = borders;
        return b;
    }

    pub fn withBorderType(self: Block, border_type: BorderType) Block {
        var b = self;
        b.border_type = border_type;
        return b;
    }

    pub fn withBorderStyle(self: Block, style: Style) Block {
        var b = self;
        b.border_style = style;
        return b;
    }

    pub fn withTitleStyle(self: Block, style: Style) Block {
        var b = self;
        b.title_style = style;
        return b;
    }

    pub fn withPadding(self: Block, padding: Padding) Block {
        var b = self;
        b.padding = padding;
        return b;
    }

    /// Return the inner area after accounting for borders and padding.
    pub fn innerArea(self: Block, area: Rect) Rect {
        var x = area.x;
        var y = area.y;
        var w = area.width;
        var h = area.height;

        if (self.borders.left_side) {
            x +|= 1;
            w -|= 1;
        }
        if (self.borders.top) {
            y +|= 1;
            h -|= 1;
        }
        if (self.borders.right) {
            w -|= 1;
        }
        if (self.borders.bottom) {
            h -|= 1;
        }

        x +|= self.padding.left;
        y +|= self.padding.top;
        w -|= self.padding.left +| self.padding.right;
        h -|= self.padding.top +| self.padding.bottom;

        return .{ .x = x, .y = y, .width = w, .height = h };
    }

    pub fn render(self: Block, area: Rect, buf: *Buffer) void {
        if (area.isEmpty()) return;

        const chars = borderChars(self.border_type);
        const bs = self.border_style;

        // Draw borders
        if (self.borders.top) {
            var x = area.left();
            while (x < area.right()) : (x += 1) {
                buf.set(x, area.top(), bs.applyToCell(.{ .codepoint = chars.h }));
            }
        }
        if (self.borders.bottom) {
            var x = area.left();
            while (x < area.right()) : (x += 1) {
                buf.set(x, area.bottom() -| 1, bs.applyToCell(.{ .codepoint = chars.h }));
            }
        }
        if (self.borders.left_side) {
            var y = area.top();
            while (y < area.bottom()) : (y += 1) {
                buf.set(area.left(), y, bs.applyToCell(.{ .codepoint = chars.v }));
            }
        }
        if (self.borders.right) {
            var y = area.top();
            while (y < area.bottom()) : (y += 1) {
                buf.set(area.right() -| 1, y, bs.applyToCell(.{ .codepoint = chars.v }));
            }
        }

        // Corners
        if (self.borders.top and self.borders.left_side) {
            buf.set(area.left(), area.top(), bs.applyToCell(.{ .codepoint = chars.tl }));
        }
        if (self.borders.top and self.borders.right) {
            buf.set(area.right() -| 1, area.top(), bs.applyToCell(.{ .codepoint = chars.tr }));
        }
        if (self.borders.bottom and self.borders.left_side) {
            buf.set(area.left(), area.bottom() -| 1, bs.applyToCell(.{ .codepoint = chars.bl }));
        }
        if (self.borders.bottom and self.borders.right) {
            buf.set(area.right() -| 1, area.bottom() -| 1, bs.applyToCell(.{ .codepoint = chars.br }));
        }

        // Title (rendered on top border, after left corner)
        if (self.title.len > 0 and self.borders.top and area.width > 2) {
            const max_title = area.width -| 2;
            const title_len = @min(@as(u16, @intCast(self.title.len)), max_title);
            const tx = area.left() +| 1;
            buf.setString(tx, area.top(), self.title[0..title_len], self.title_style);
        }
    }
};

// ============================================================================
// Paragraph widget — text display
// ============================================================================

pub const Paragraph = struct {
    text: Text = .{ .lines = &.{} },
    block: ?Block = null,
    style: Style = .{},

    pub fn new(text: Text) Paragraph {
        return .{ .text = text };
    }

    pub fn withBlock(self: Paragraph, block: Block) Paragraph {
        var p = self;
        p.block = block;
        return p;
    }

    pub fn withStyle(self: Paragraph, style: Style) Paragraph {
        var p = self;
        p.style = style;
        return p;
    }

    pub fn render(self: Paragraph, area: Rect, buf: *Buffer) void {
        if (area.isEmpty()) return;

        // Render block if present
        var text_area = area;
        if (self.block) |block| {
            block.render(area, buf);
            text_area = block.innerArea(area);
        }

        // Apply paragraph background style
        buf.setStyle(text_area, self.style);

        // Render text lines
        const max_rows = text_area.height;
        const line_count = @min(@as(u16, @intCast(self.text.lines.len)), max_rows);

        for (0..line_count) |i| {
            const line = self.text.lines[i];
            const row = text_area.y +| @as(u16, @intCast(i));
            buf.setLine(text_area.x, row, line);
        }
    }
};

// ============================================================================
// ListItem — single item in a list
// ============================================================================

pub const ListItem = struct {
    content: Line,
    style: Style = .{},

    pub fn new(content: []const u8) ListItem {
        return .{ .content = Line.raw(content) };
    }

    pub fn fromLine(line: Line) ListItem {
        return .{ .content = line };
    }

    pub fn withStyle(self: ListItem, style: Style) ListItem {
        var item = self;
        item.style = style;
        return item;
    }
};

// ============================================================================
// List widget — selectable items
// ============================================================================

pub const MAX_LIST_ITEMS: usize = 256;

pub const List = struct {
    items: []const ListItem,
    block: ?Block = null,
    style: Style = .{},
    highlight_style: Style = .{},
    selected: ?usize = null,

    pub fn new(items: []const ListItem) List {
        return .{ .items = items };
    }

    pub fn withBlock(self: List, block: Block) List {
        var l = self;
        l.block = block;
        return l;
    }

    pub fn withStyle(self: List, style: Style) List {
        var l = self;
        l.style = style;
        return l;
    }

    pub fn withHighlightStyle(self: List, style: Style) List {
        var l = self;
        l.highlight_style = style;
        return l;
    }

    pub fn withSelected(self: List, selected: ?usize) List {
        var l = self;
        l.selected = selected;
        return l;
    }

    pub fn render(self: List, area: Rect, buf: *Buffer) void {
        if (area.isEmpty()) return;

        var list_area = area;
        if (self.block) |block| {
            block.render(area, buf);
            list_area = block.innerArea(area);
        }

        buf.setStyle(list_area, self.style);

        const max_rows = list_area.height;
        const item_count = @min(@as(u16, @intCast(self.items.len)), max_rows);

        for (0..item_count) |i| {
            const item = self.items[i];
            const row = list_area.y +| @as(u16, @intCast(i));

            // Apply item or highlight style
            const item_style = if (self.selected != null and self.selected.? == i)
                self.highlight_style
            else
                item.style;

            // Fill row with style
            const row_rect = Rect{
                .x = list_area.x,
                .y = row,
                .width = list_area.width,
                .height = 1,
            };
            buf.setStyle(row_rect, item_style);

            // Render content
            buf.setLine(list_area.x, row, item.content);

            // Re-apply style on top of content for highlight
            if (self.selected != null and self.selected.? == i) {
                buf.setStyle(row_rect, self.highlight_style);
            }
        }
    }
};

// ============================================================================
// Gauge widget — progress bar
// ============================================================================

pub const Gauge = struct {
    ratio: f32 = 0.0,
    label: []const u8 = "",
    block: ?Block = null,
    gauge_style: Style = .{},

    pub fn default() Gauge {
        return .{};
    }

    pub fn withRatio(self: Gauge, ratio: f32) Gauge {
        var g = self;
        g.ratio = @max(0.0, @min(1.0, ratio));
        return g;
    }

    pub fn withLabel(self: Gauge, label: []const u8) Gauge {
        var g = self;
        g.label = label;
        return g;
    }

    pub fn withBlock(self: Gauge, block: Block) Gauge {
        var g = self;
        g.block = block;
        return g;
    }

    pub fn withGaugeStyle(self: Gauge, style: Style) Gauge {
        var g = self;
        g.gauge_style = style;
        return g;
    }

    pub fn render(self: Gauge, area: Rect, buf: *Buffer) void {
        if (area.isEmpty()) return;

        var gauge_area = area;
        if (self.block) |block| {
            block.render(area, buf);
            gauge_area = block.innerArea(area);
        }

        if (gauge_area.isEmpty()) return;

        // Calculate filled width
        const filled: u16 = @intFromFloat(@as(f32, @floatFromInt(gauge_area.width)) * self.ratio);

        // Draw filled portion
        var x = gauge_area.left();
        while (x < gauge_area.left() +| filled) : (x += 1) {
            buf.set(x, gauge_area.top(), self.gauge_style.applyToCell(.{
                .codepoint = 0x2588, // Full block
            }));
        }

        // Draw empty portion
        const bg_style = Style.bg(if (self.gauge_style.bg_color.tag == .default) Color.dark_gray else self.gauge_style.bg_color);
        while (x < gauge_area.right()) : (x += 1) {
            buf.set(x, gauge_area.top(), bg_style.applyToCell(.{
                .codepoint = ' ',
            }));
        }

        // Center label on gauge
        if (self.label.len > 0) {
            const label_len: u16 = @intCast(@min(self.label.len, gauge_area.width));
            const label_x = gauge_area.left() +| (gauge_area.width -| label_len) / 2;
            buf.setString(label_x, gauge_area.top(), self.label[0..label_len], Style.fg(Color.white));
        }
    }
};

// ============================================================================
// Frame — drawing context (wraps Buffer)
// ============================================================================

pub const Frame = struct {
    buffer: *Buffer,
    area_val: Rect,

    pub fn init(buffer: *Buffer, rect: Rect) Frame {
        return .{ .buffer = buffer, .area_val = rect };
    }

    pub fn area(self: Frame) Rect {
        return self.area_val;
    }

    pub fn renderWidget(self: *Frame, widget: anytype, widget_area: Rect) void {
        widget.render(widget_area, self.buffer);
    }

    pub fn buf(self: *Frame) *Buffer {
        return self.buffer;
    }
};

// ============================================================================
// AnsiBackend — Buffer → ANSI escape sequences
// ============================================================================

pub const MAX_ANSI_OUTPUT: usize = 131072; // 128KB

pub const AnsiBackend = struct {
    out: [MAX_ANSI_OUTPUT]u8 = undefined,
    len: usize = 0,
    width: u16 = 80,
    height: u16 = 24,

    pub fn init(width: u16, height: u16) AnsiBackend {
        return .{ .width = width, .height = height };
    }

    pub fn resize(self: *AnsiBackend, width: u16, height: u16) void {
        self.width = width;
        self.height = height;
    }

    /// Render a buffer to ANSI escape sequences.
    pub fn draw(self: *AnsiBackend, buffer: *const Buffer) void {
        self.len = 0;

        // Hide cursor
        self.writeStr("\x1b[?25l");

        var last_x: u16 = 0;
        var last_y: u16 = 0;
        var first = true;

        var y = buffer.area.y;
        while (y < buffer.area.bottom()) : (y += 1) {
            var x = buffer.area.x;
            while (x < buffer.area.right()) : (x += 1) {
                const cell = buffer.get(x, y);
                if (cell.isBlank()) {
                    x +|= 0; // no-op, just skip
                    continue;
                }

                // Cursor positioning
                const need_move = first or !(last_y == y and last_x + 1 == x);
                if (need_move) {
                    self.writeCursorPos(x, y);
                }
                first = false;

                self.writeSgr(cell);
                self.writeCodepoint(cell.codepoint);

                last_x = x;
                last_y = y;
            }
        }

        // Reset SGR
        self.writeStr("\x1b[0m");

        // Show cursor
        self.writeStr("\x1b[?25h");
    }

    /// Render buffer, diffing against previous buffer to minimize output.
    pub fn drawDiff(self: *AnsiBackend, current: *const Buffer, previous: *const Buffer) void {
        self.len = 0;
        self.writeStr("\x1b[?25l");

        var last_x: u16 = 0;
        var last_y: u16 = 0;
        var first = true;

        var y = current.area.y;
        while (y < current.area.bottom()) : (y += 1) {
            var x = current.area.x;
            while (x < current.area.right()) : (x += 1) {
                const cur = current.get(x, y);
                const prev = previous.get(x, y);

                if (cur.eql(prev)) continue;
                if (cur.isBlank()) continue;

                const need_move = first or !(last_y == y and last_x + 1 == x);
                if (need_move) {
                    self.writeCursorPos(x, y);
                }
                first = false;

                self.writeSgr(cur);
                self.writeCodepoint(cur.codepoint);

                last_x = x;
                last_y = y;
            }
        }

        self.writeStr("\x1b[0m");
        self.writeStr("\x1b[?25h");
    }

    pub fn clear(self: *AnsiBackend) void {
        self.len = 0;
        self.writeStr("\x1b[2J");
    }

    /// Get the rendered ANSI output.
    pub fn output(self: *const AnsiBackend) []const u8 {
        return self.out[0..self.len];
    }

    /// Reset output length.
    pub fn reset(self: *AnsiBackend) void {
        self.len = 0;
    }

    // -- private helpers --

    fn writeByte(self: *AnsiBackend, byte: u8) void {
        if (self.len < MAX_ANSI_OUTPUT) {
            self.out[self.len] = byte;
            self.len += 1;
        }
    }

    fn writeStr(self: *AnsiBackend, s: []const u8) void {
        for (s) |b| self.writeByte(b);
    }

    fn writeDecimal(self: *AnsiBackend, value: u16) void {
        if (value == 0) {
            self.writeByte('0');
            return;
        }
        var tmp: [5]u8 = undefined;
        var n: usize = 0;
        var v = value;
        while (v > 0) {
            tmp[n] = @intCast('0' + (v % 10));
            v /= 10;
            n += 1;
        }
        var i = n;
        while (i > 0) {
            i -= 1;
            self.writeByte(tmp[i]);
        }
    }

    fn writeCursorPos(self: *AnsiBackend, x: u16, y: u16) void {
        self.writeStr("\x1b[");
        self.writeDecimal(y + 1);
        self.writeByte(';');
        self.writeDecimal(x + 1);
        self.writeByte('H');
    }

    fn writeSgr(self: *AnsiBackend, cell: Cell) void {
        self.writeStr("\x1b[0"); // reset

        const attrs = cell.attrs;
        if (attrs.bold) self.writeStr(";1");
        if (attrs.dim) self.writeStr(";2");
        if (attrs.italic) self.writeStr(";3");
        if (attrs.underline) self.writeStr(";4");
        if (attrs.blink) self.writeStr(";5");
        if (attrs.inverse) self.writeStr(";7");
        if (attrs.invisible) self.writeStr(";8");
        if (attrs.strikethrough) self.writeStr(";9");

        // fg: 24-bit color
        if (cell.fg.tag == .srgb) {
            const rgb = cell.fg.payload;
            self.writeStr(";38;2;");
            self.writeDecimal(@intCast((rgb >> 16) & 0xFF));
            self.writeByte(';');
            self.writeDecimal(@intCast((rgb >> 8) & 0xFF));
            self.writeByte(';');
            self.writeDecimal(@intCast(rgb & 0xFF));
        }

        // bg: 24-bit color
        if (cell.bg.tag == .srgb) {
            const rgb = cell.bg.payload;
            self.writeStr(";48;2;");
            self.writeDecimal(@intCast((rgb >> 16) & 0xFF));
            self.writeByte(';');
            self.writeDecimal(@intCast((rgb >> 8) & 0xFF));
            self.writeByte(';');
            self.writeDecimal(@intCast(rgb & 0xFF));
        }

        self.writeByte('m');
    }

    fn writeCodepoint(self: *AnsiBackend, cp: u21) void {
        // UTF-8 encode
        if (cp < 0x80) {
            self.writeByte(@intCast(cp));
        } else if (cp < 0x800) {
            self.writeByte(@intCast(0xC0 | (cp >> 6)));
            self.writeByte(@intCast(0x80 | (cp & 0x3F)));
        } else if (cp < 0x10000) {
            self.writeByte(@intCast(0xE0 | (cp >> 12)));
            self.writeByte(@intCast(0x80 | ((cp >> 6) & 0x3F)));
            self.writeByte(@intCast(0x80 | (cp & 0x3F)));
        } else {
            self.writeByte(@intCast(0xF0 | (cp >> 18)));
            self.writeByte(@intCast(0x80 | ((cp >> 12) & 0x3F)));
            self.writeByte(@intCast(0x80 | ((cp >> 6) & 0x3F)));
            self.writeByte(@intCast(0x80 | (cp & 0x3F)));
        }
    }
};

// ============================================================================
// Terminal — high-level API combining Backend + double-buffered rendering
// ============================================================================

pub const Terminal = struct {
    backend: AnsiBackend,
    current: Buffer,
    previous: Buffer,

    pub fn init(width: u16, height: u16) Terminal {
        const rect = Rect{ .x = 0, .y = 0, .width = width, .height = height };
        return .{
            .backend = AnsiBackend.init(width, height),
            .current = Buffer.init(rect),
            .previous = Buffer.init(rect),
        };
    }

    pub fn resize(self: *Terminal, width: u16, height: u16) void {
        const rect = Rect{ .x = 0, .y = 0, .width = width, .height = height };
        self.backend.resize(width, height);
        self.current = Buffer.init(rect);
        self.previous = Buffer.init(rect);
    }

    /// Draw a frame: clear current buffer, call render callback, diff and emit ANSI.
    pub fn draw(self: *Terminal, render_fn: *const fn (*Frame) void) []const u8 {
        self.current.clear();
        var frame = Frame.init(&self.current, self.current.area);
        render_fn(&frame);

        self.backend.drawDiff(&self.current, &self.previous);

        // Swap buffers (copy current to previous for next diff)
        const total = @as(usize, self.current.area.width) * self.current.area.height;
        const n = @min(total, MAX_BUF_CELLS);
        @memcpy(self.previous.cells[0..n], self.current.cells[0..n]);
        self.previous.area = self.current.area;

        return self.backend.output();
    }

    pub fn area(self: *const Terminal) Rect {
        return self.current.area;
    }
};

// ============================================================================
// TESTS
// ============================================================================

const testing = if (!is_freestanding) @import("std").testing else struct {};

test "Rect basics" {
    const r = Rect{ .x = 5, .y = 10, .width = 20, .height = 15 };
    try testing.expectEqual(@as(u32, 300), r.area());
    try testing.expectEqual(@as(u16, 5), r.left());
    try testing.expectEqual(@as(u16, 25), r.right());
    try testing.expectEqual(@as(u16, 10), r.top());
    try testing.expectEqual(@as(u16, 25), r.bottom());
}

test "Rect inner" {
    const r = Rect{ .x = 0, .y = 0, .width = 40, .height = 20 };
    const i = r.inner(2);
    try testing.expectEqual(@as(u16, 2), i.x);
    try testing.expectEqual(@as(u16, 2), i.y);
    try testing.expectEqual(@as(u16, 36), i.width);
    try testing.expectEqual(@as(u16, 16), i.height);
}

test "Rect inner collapses" {
    const r = Rect{ .x = 0, .y = 0, .width = 3, .height = 3 };
    const i = r.inner(2);
    try testing.expectEqual(@as(u16, 0), i.width);
    try testing.expectEqual(@as(u16, 0), i.height);
}

test "Layout vertical split" {
    const area = Rect{ .x = 0, .y = 0, .width = 80, .height = 24 };
    const constraints = [_]Constraint{
        .{ .length = 3 },
        .{ .fill = {} },
        .{ .length = 3 },
    };
    var chunks: [3]Rect = undefined;
    area.splitVertical(&constraints, &chunks);

    try testing.expectEqual(@as(u16, 0), chunks[0].y);
    try testing.expectEqual(@as(u16, 3), chunks[0].height);
    try testing.expectEqual(@as(u16, 3), chunks[1].y);
    try testing.expectEqual(@as(u16, 18), chunks[1].height);
    try testing.expectEqual(@as(u16, 21), chunks[2].y);
    try testing.expectEqual(@as(u16, 3), chunks[2].height);
}

test "Layout horizontal percentage" {
    const area = Rect{ .x = 0, .y = 0, .width = 100, .height = 24 };
    const constraints = [_]Constraint{
        .{ .percentage = 50 },
        .{ .percentage = 50 },
    };
    var chunks: [2]Rect = undefined;
    area.splitHorizontal(&constraints, &chunks);

    try testing.expectEqual(@as(u16, 0), chunks[0].x);
    try testing.expectEqual(@as(u16, 50), chunks[0].width);
    try testing.expectEqual(@as(u16, 50), chunks[1].x);
    try testing.expectEqual(@as(u16, 50), chunks[1].width);
}

test "Layout ratio" {
    const area = Rect{ .x = 0, .y = 0, .width = 80, .height = 30 };
    const constraints = [_]Constraint{
        .{ .ratio = .{ 1, 3 } },
        .{ .ratio = .{ 2, 3 } },
    };
    var chunks: [2]Rect = undefined;
    area.splitVertical(&constraints, &chunks);

    try testing.expectEqual(@as(u16, 10), chunks[0].height);
    try testing.expectEqual(@as(u16, 20), chunks[1].height);
}

test "Style builder" {
    const s = Style.fg(Color.red).bold().withBg(Color.blue);
    try testing.expectEqual(true, s.attrs.bold);
    try testing.expectEqual(@as(u24, 0xFF0000), s.fg_color.toRgb24());
    try testing.expectEqual(@as(u24, 0x0000FF), s.bg_color.toRgb24());
}

test "Buffer set and get" {
    var buf = Buffer.init(.{ .x = 0, .y = 0, .width = 80, .height = 24 });
    buf.set(5, 3, .{ .codepoint = 'A', .fg = Color.red, .bg = Color.black });

    const cell = buf.get(5, 3);
    try testing.expectEqual(@as(u21, 'A'), cell.codepoint);
    try testing.expectEqual(@as(u24, 0xFF0000), cell.fg.toRgb24());
}

test "Buffer setString" {
    var buf = Buffer.init(.{ .x = 0, .y = 0, .width = 80, .height = 24 });
    buf.setString(2, 1, "Hello", Style.fg(Color.green));

    try testing.expectEqual(@as(u21, 'H'), buf.get(2, 1).codepoint);
    try testing.expectEqual(@as(u21, 'e'), buf.get(3, 1).codepoint);
    try testing.expectEqual(@as(u21, 'l'), buf.get(4, 1).codepoint);
    try testing.expectEqual(@as(u21, 'l'), buf.get(5, 1).codepoint);
    try testing.expectEqual(@as(u21, 'o'), buf.get(6, 1).codepoint);
}

test "Buffer out of bounds" {
    var buf = Buffer.init(.{ .x = 0, .y = 0, .width = 10, .height = 10 });
    buf.set(100, 100, .{ .codepoint = 'X' });
    const cell = buf.get(100, 100);
    try testing.expectEqual(@as(u21, ' '), cell.codepoint); // default
}

test "Block innerArea" {
    const block = Block.default().withBorders(Borders.ALL);
    const area = Rect{ .x = 0, .y = 0, .width = 40, .height = 20 };
    const inner = block.innerArea(area);

    try testing.expectEqual(@as(u16, 1), inner.x);
    try testing.expectEqual(@as(u16, 1), inner.y);
    try testing.expectEqual(@as(u16, 38), inner.width);
    try testing.expectEqual(@as(u16, 18), inner.height);
}

test "Block render borders" {
    var buf = Buffer.init(.{ .x = 0, .y = 0, .width = 10, .height = 5 });
    const block = Block.default().withBorders(Borders.ALL).withTitle("Hi");
    block.render(.{ .x = 0, .y = 0, .width = 10, .height = 5 }, &buf);

    // Top-left corner
    try testing.expectEqual(@as(u21, 0x250C), buf.get(0, 0).codepoint);
    // Top-right corner
    try testing.expectEqual(@as(u21, 0x2510), buf.get(9, 0).codepoint);
    // Title
    try testing.expectEqual(@as(u21, 'H'), buf.get(1, 0).codepoint);
    try testing.expectEqual(@as(u21, 'i'), buf.get(2, 0).codepoint);
    // Bottom-left corner
    try testing.expectEqual(@as(u21, 0x2514), buf.get(0, 4).codepoint);
}

test "Paragraph render" {
    var buf = Buffer.init(.{ .x = 0, .y = 0, .width = 40, .height = 10 });
    const span1 = [_]Span{Span.raw("Hello World")};
    const span2 = [_]Span{Span.raw("Second Line")};
    const lines = [_]Line{
        Line.from(&span1),
        Line.from(&span2),
    };
    const text = Text{ .lines = &lines };
    const para = Paragraph.new(text).withBlock(
        Block.default().withBorders(Borders.ALL).withTitle("Test"),
    );
    para.render(.{ .x = 0, .y = 0, .width = 40, .height = 10 }, &buf);

    // Border exists
    try testing.expectEqual(@as(u21, 0x250C), buf.get(0, 0).codepoint);
    // Text starts at (1, 1)
    try testing.expectEqual(@as(u21, 'H'), buf.get(1, 1).codepoint);
    try testing.expectEqual(@as(u21, 'S'), buf.get(1, 2).codepoint);
}

test "Gauge render" {
    var buf = Buffer.init(.{ .x = 0, .y = 0, .width = 20, .height = 3 });
    const gauge = Gauge.default()
        .withRatio(0.5)
        .withGaugeStyle(Style.fg(Color.cyan).withBg(Color.black))
        .withBlock(Block.default().withBorders(Borders.ALL));
    gauge.render(.{ .x = 0, .y = 0, .width = 20, .height = 3 }, &buf);

    // Border exists
    try testing.expectEqual(@as(u21, 0x250C), buf.get(0, 0).codepoint);
    // First cell inside should be a block char (filled)
    try testing.expectEqual(@as(u21, 0x2588), buf.get(1, 1).codepoint);
}

test "AnsiBackend renders" {
    var buf = Buffer.init(.{ .x = 0, .y = 0, .width = 10, .height = 3 });
    buf.set(0, 0, .{ .codepoint = 'A', .fg = Color.red, .bg = Color.black });
    buf.set(1, 0, .{ .codepoint = 'B', .fg = Color.green, .bg = Color.black });

    var backend = AnsiBackend.init(10, 3);
    backend.draw(&buf);

    const out = backend.output();
    try testing.expect(out.len > 0);
    // Should contain the hide cursor sequence
    try testing.expect(out.len >= 6);
    try testing.expectEqual(@as(u8, 0x1b), out[0]);
    try testing.expectEqual(@as(u8, '['), out[1]);
}

test "AnsiBackend diff only changed cells" {
    // prev has many cells
    var prev = Buffer.init(.{ .x = 0, .y = 0, .width = 10, .height = 3 });
    var i: u16 = 0;
    while (i < 10) : (i += 1) {
        prev.set(i, 0, .{ .codepoint = 'A' +| @as(u21, i), .fg = Color.red, .bg = Color.black });
    }

    // curr is same except one cell changed
    var curr = Buffer.init(.{ .x = 0, .y = 0, .width = 10, .height = 3 });
    i = 0;
    while (i < 10) : (i += 1) {
        curr.set(i, 0, .{ .codepoint = 'A' +| @as(u21, i), .fg = Color.red, .bg = Color.black });
    }
    curr.set(5, 0, .{ .codepoint = 'Z', .fg = Color.green, .bg = Color.black }); // one change

    var backend = AnsiBackend.init(10, 3);

    backend.draw(&curr);
    const full_len = backend.len;

    backend.drawDiff(&curr, &prev);
    const diff_len = backend.len;

    // Diff output should be smaller since only 1 of 10 cells changed
    try testing.expect(diff_len < full_len);
}

test "Span width" {
    const s = Span.raw("Hello");
    try testing.expectEqual(@as(u16, 5), s.width());
}

test "Line width" {
    const spans = [_]Span{
        Span.raw("Hello"),
        Span.raw(" "),
        Span.styled("World", Style.fg(Color.red)),
    };
    const line = Line.from(&spans);
    try testing.expectEqual(@as(u16, 11), line.width());
}

test "List render with selection" {
    var buf = Buffer.init(.{ .x = 0, .y = 0, .width = 20, .height = 5 });
    // Use Line.raw which stores content directly (no span array needed)
    const items = [_]ListItem{
        .{ .content = Line.raw("Item 1") },
        .{ .content = Line.raw("Item 2") },
        .{ .content = Line.raw("Item 3") },
    };
    const list = List.new(&items)
        .withHighlightStyle(Style.fg(Color.yellow).bold())
        .withSelected(1);
    list.render(.{ .x = 0, .y = 0, .width = 20, .height = 5 }, &buf);

    try testing.expectEqual(@as(u21, 'I'), buf.get(0, 0).codepoint);
    try testing.expectEqual(@as(u21, 'I'), buf.get(0, 1).codepoint);
    try testing.expectEqual(@as(u21, 'I'), buf.get(0, 2).codepoint);
}

test "Terminal double buffer" {
    var term = Terminal.init(20, 5);
    try testing.expectEqual(@as(u16, 20), term.area().width);
    try testing.expectEqual(@as(u16, 5), term.area().height);
}

test "Buffer merge" {
    var base = Buffer.init(.{ .x = 0, .y = 0, .width = 10, .height = 5 });
    base.set(0, 0, .{ .codepoint = 'A' });

    var overlay = Buffer.init(.{ .x = 0, .y = 0, .width = 10, .height = 5 });
    overlay.set(1, 1, .{ .codepoint = 'B' });

    base.merge(&overlay);

    try testing.expectEqual(@as(u21, 'A'), base.get(0, 0).codepoint);
    try testing.expectEqual(@as(u21, 'B'), base.get(1, 1).codepoint);
}

test "Border types produce different chars" {
    const plain = borderChars(.plain);
    const rounded = borderChars(.rounded);
    const double = borderChars(.double);

    try testing.expect(plain.tl != rounded.tl);
    try testing.expect(plain.tl != double.tl);
    try testing.expect(rounded.tl != double.tl);
}

test "Layout with min constraint" {
    const area = Rect{ .x = 0, .y = 0, .width = 80, .height = 30 };
    const constraints = [_]Constraint{
        .{ .min = 5 },
        .{ .fill = {} },
    };
    var chunks: [2]Rect = undefined;
    area.splitVertical(&constraints, &chunks);

    try testing.expect(chunks[0].height >= 5);
    try testing.expectEqual(@as(u16, 25), chunks[1].height);
}
