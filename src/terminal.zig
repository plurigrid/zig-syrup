//! terminal:// Protocol Pipeline
//!
//! Forward-oriented, wasm32-freestanding compatible terminal cell pipeline
//! using Syrup (OCapN) serialization and length-prefixed message framing.
//!
//! Architecture:
//!   terminal://cell/write   → write cells to local grid
//!   terminal://cell/read    → read cells from local grid
//!   terminal://frame/sync   → commit dirty cells → Syrup frame
//!   terminal://frame/apply  → apply incoming Syrup frame
//!   terminal://frame/resize → resize grid
//!   terminal://color/trit   → GF(3) classification of cell colors
//!
//! Wire format (Syrup record per operation):
//!   <terminal:sync <gen:u64> <cols:u16> <rows:u16> <packed:bytes>>
//!   <terminal:write <x:u16> <y:u16> <cp:u32> <fg:u32> <bg:u32> <attrs:u8>>
//!   <terminal:resize <cols:u16> <rows:u16>>
//!
//! Cell packed format (14 bytes, cell_sync compatible):
//!   [u16 x][u16 y][u24 codepoint][u24 fg][u24 bg][u8 attrs]
//!
//! No OS dependencies. No allocator in the hot path.
//! Works on native (with std) and wasm32-freestanding.

// ============================================================================
// Platform detection
// ============================================================================

const builtin = @import("builtin");
const std = @import("std");
const gf3 = @import("gf3_palette.zig");

const is_wasm = builtin.cpu.arch == .wasm32 or builtin.cpu.arch == .wasm64;
const is_freestanding = builtin.os.tag == .freestanding;

// ============================================================================
// COLOR SYSTEM (Referentially Transparent / GF(3))
// ============================================================================

/// Universal Color Type (32-bit)
/// Preserves semantic intent better than raw RGB.
///
/// Layout (MSB -> LSB):
///   [8 bits: type] [24 bits: payload]
///
/// Types:
///   0x00: sRGB (Legacy)       -> payload = 0xRRGGBB
///   0x01: GF(3) TritWord      -> payload = index (0..242)
///   0x02: System Palette      -> payload = index (0..255) (e.g. ANSI)
///   0xFF: Default/Transparent
pub const Color = packed struct(u32) {
    payload: u24,
    tag: Tag,

    pub const Tag = enum(u8) {
        srgb = 0x00,
        gf3 = 0x01,
        palette = 0x02,
        default = 0xFF,
    };

    pub const DEFAULT = Color{ .tag = .default, .payload = 0 };
    pub const BLACK = Color{ .tag = .srgb, .payload = 0x000000 };
    pub const RED = Color{ .tag = .srgb, .payload = 0xFF0000 };
    pub const GREEN = Color{ .tag = .srgb, .payload = 0x00FF00 };
    pub const YELLOW = Color{ .tag = .srgb, .payload = 0xFFFF00 };
    pub const BLUE = Color{ .tag = .srgb, .payload = 0x0000FF };
    pub const MAGENTA = Color{ .tag = .srgb, .payload = 0xFF00FF };
    pub const CYAN = Color{ .tag = .srgb, .payload = 0x00FFFF };
    pub const WHITE = Color{ .tag = .srgb, .payload = 0xFFFFFF };
    pub const GRAY = Color{ .tag = .srgb, .payload = 0x808080 };
    pub const DARK_GRAY = Color{ .tag = .srgb, .payload = 0x404040 };

    // Lowercase aliases for compatibility with retty
    pub const white = WHITE;
    pub const black = BLACK;
    pub const red = RED;
    pub const green = GREEN;
    pub const blue = BLUE;
    pub const yellow = YELLOW;
    pub const magenta = MAGENTA;
    pub const cyan = CYAN;
    pub const gray = GRAY;
    pub const dark_gray = DARK_GRAY;

    /// Construct sRGB color
    pub fn rgb(r: u8, g: u8, b: u8) Color {
        const val = (@as(u24, r) << 16) | (@as(u24, g) << 8) | @as(u24, b);
        return .{ .tag = .srgb, .payload = val };
    }

    /// Construct from GF(3) TritWord
    pub fn fromTrit(word: gf3.TritWord) Color {
        return .{ .tag = .gf3, .payload = word.toIndex() };
    }

    /// Convert to 24-bit sRGB (lossy for wide gamut/semantic)
    pub fn toRgb24(self: Color) u24 {
        switch (self.tag) {
            .srgb => return self.payload,
            .gf3 => {
                // Lookup in GF(3) palette
                const word = gf3.TritWord.fromIndex(@intCast(self.payload));
                const c = gf3.PALETTE.lookup(word);
                return (@as(u24, c.r) << 16) | (@as(u24, c.g) << 8) | @as(u24, c.b);
            },
            .palette => {
                // TODO: Implement ANSI palette lookup if needed
                // For now, map simple indices or fallback
                return 0xFFFFFF;
            },
            .default => return 0x000000, // or handling context dependent
        }
    }
};

// ============================================================================
// CORE TYPES (zero OS deps)
// ============================================================================

/// Cell attributes packed into a single byte
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

/// A single terminal cell: codepoint + fg/bg color + attributes
pub const Cell = struct {
    codepoint: u21 = ' ',
    fg: Color = Color.DEFAULT,
    bg: Color = Color.DEFAULT,
    attrs: CellAttrs = .{},

    pub fn eql(a: Cell, b: Cell) bool {
        return a.codepoint == b.codepoint and
            @as(u32, @bitCast(a.fg)) == @as(u32, @bitCast(b.fg)) and
            @as(u32, @bitCast(a.bg)) == @as(u32, @bitCast(b.bg)) and
            @as(u8, @bitCast(a.attrs)) == @as(u8, @bitCast(b.attrs));
    }

    pub fn isBlank(self: Cell) bool {
        return self.codepoint == ' ' and
            @as(u8, @bitCast(self.attrs)) == 0;
    }
};

/// GF(3) trit classification from hue
pub const Trit = enum(i8) {
    plus = 1, // hue ∈ [0°, 120°)  — Generator
    ergodic = 0, // hue ∈ [120°, 240°) — Coordinator
    minus = -1, // hue ∈ [240°, 360°) — Validator

    pub fn fromHue(hue: f32) Trit {
        if (hue < 120.0) return .plus;
        if (hue < 240.0) return .ergodic;
        return .minus;
    }

    pub fn fromRgb24(rgb: u24) Trit {
        const r: f32 = @floatFromInt((rgb >> 16) & 0xFF);
        const g: f32 = @floatFromInt((rgb >> 8) & 0xFF);
        const b: f32 = @floatFromInt(rgb & 0xFF);
        const hue = rgbToHue(r / 255.0, g / 255.0, b / 255.0);
        return fromHue(hue);
    }
};

/// Convert RGB [0,1] to hue [0,360)
fn rgbToHue(r: f32, g: f32, b: f32) f32 {
    const max_c = @max(r, @max(g, b));
    const min_c = @min(r, @min(g, b));
    const delta = max_c - min_c;

    if (delta < 0.00001) return 0.0;

    var hue: f32 = 0.0;
    if (max_c == r) {
        hue = 60.0 * @mod((g - b) / delta, 6.0);
    } else if (max_c == g) {
        hue = 60.0 * ((b - r) / delta + 2.0);
    } else {
        hue = 60.0 * ((r - g) / delta + 4.0);
    }

    if (hue < 0.0) hue += 360.0;
    return hue;
}

// ============================================================================
// TERMINAL GRID (fixed-capacity, no allocator)
// ============================================================================

/// Maximum grid dimensions
pub const MAX_COLS: u16 = 512;
pub const MAX_ROWS: u16 = 256;
const MAX_CELLS: usize = @as(usize, MAX_COLS) * MAX_ROWS;

/// Packed cell format size (cell_sync compatible)
pub const CELL_PACKED_SIZE: usize = 14;

/// Maximum dirty cells per commit
pub const MAX_DIRTY: usize = 4096;

/// Terminal grid state
pub const Grid = struct {
    cells: [MAX_CELLS]Cell = [_]Cell{.{}} ** MAX_CELLS,
    dirty: [MAX_DIRTY]DirtyEntry = undefined,
    dirty_count: usize = 0,
    cols: u16 = 80,
    rows: u16 = 24,
    generation: u64 = 0,
    cursor_x: u16 = 0,
    cursor_y: u16 = 0,

    pub const DirtyEntry = struct {
        x: u16,
        y: u16,
    };

    /// Initialize with dimensions
    pub fn init(cols: u16, rows: u16) Grid {
        return .{
            .cols = @min(cols, MAX_COLS),
            .rows = @min(rows, MAX_ROWS),
        };
    }

    /// Cell index from coordinates
    fn idx(self: *const Grid, x: u16, y: u16) ?usize {
        if (x >= self.cols or y >= self.rows) return null;
        return @as(usize, y) * MAX_COLS + x;
    }

    /// Write a cell at (x, y), marking it dirty
    pub fn writeCell(self: *Grid, x: u16, y: u16, cell: Cell) void {
        const i = self.idx(x, y) orelse return;
        if (self.cells[i].eql(cell)) return; // no-op if unchanged
        self.cells[i] = cell;
        if (self.dirty_count < MAX_DIRTY) {
            self.dirty[self.dirty_count] = .{ .x = x, .y = y };
            self.dirty_count += 1;
        }
    }

    /// Read a cell at (x, y)
    pub fn readCell(self: *const Grid, x: u16, y: u16) Cell {
        const i = self.idx(x, y) orelse return .{};
        return self.cells[i];
    }

    /// Write a codepoint with explicit colors
    pub fn put(self: *Grid, x: u16, y: u16, cp: u21, fg: Color, bg: Color, attrs: CellAttrs) void {
        self.writeCell(x, y, .{
            .codepoint = cp,
            .fg = fg,
            .bg = bg,
            .attrs = attrs,
        });
    }

    /// Write a string at cursor position, advancing cursor
    pub fn writeString(self: *Grid, str: []const u8, fg: Color, bg: Color) void {
        for (str) |byte| {
            if (byte == '\n') {
                self.cursor_x = 0;
                self.cursor_y += 1;
                if (self.cursor_y >= self.rows) self.cursor_y = self.rows - 1;
                continue;
            }
            self.put(self.cursor_x, self.cursor_y, byte, fg, bg, .{});
            self.cursor_x += 1;
            if (self.cursor_x >= self.cols) {
                self.cursor_x = 0;
                self.cursor_y += 1;
                if (self.cursor_y >= self.rows) self.cursor_y = self.rows - 1;
            }
        }
    }

    /// Resize the grid (clears dirty)
    pub fn resize(self: *Grid, cols: u16, rows: u16) void {
        self.cols = @min(cols, MAX_COLS);
        self.rows = @min(rows, MAX_ROWS);
        self.dirty_count = 0;
        self.generation += 1;
    }

    /// Clear the grid
    pub fn clear(self: *Grid) void {
        const total: usize = @as(usize, self.cols) * self.rows;
        // Clear only used cells
        for (0..@min(total, MAX_CELLS)) |row_start| {
            self.cells[row_start] = .{};
        }
        self.dirty_count = 0;
        self.cursor_x = 0;
        self.cursor_y = 0;
        self.generation += 1;
    }

    /// Commit dirty cells: pack into binary buffer, advance generation.
    /// Returns the number of bytes written to `out`.
    /// Format: packed cell data (14 bytes per cell, cell_sync compatible)
    pub fn commit(self: *Grid, out: []u8) usize {
        var pos: usize = 0;
        for (self.dirty[0..self.dirty_count]) |entry| {
            const cell = self.readCell(entry.x, entry.y);
            if (pos + CELL_PACKED_SIZE > out.len) break;
            packCell(entry.x, entry.y, cell, out[pos..][0..CELL_PACKED_SIZE]);
            pos += CELL_PACKED_SIZE;
        }
        self.dirty_count = 0;
        self.generation += 1;
        return pos;
    }

    /// Apply packed cell data from a remote frame
    pub fn apply(self: *Grid, data: []const u8) usize {
        var applied: usize = 0;
        var pos: usize = 0;
        while (pos + CELL_PACKED_SIZE <= data.len) {
            const entry = unpackCell(data[pos..][0..CELL_PACKED_SIZE]);
            const i = self.idx(entry.x, entry.y) orelse {
                pos += CELL_PACKED_SIZE;
                continue;
            };
            self.cells[i] = entry.cell;
            applied += 1;
            pos += CELL_PACKED_SIZE;
        }
        return applied;
    }
};

// ============================================================================
// CELL PACKING (cell_sync compatible, 14 bytes)
// ============================================================================

/// Pack a cell into 14 bytes: [u16 x][u16 y][u24 cp][u24 fg][u24 bg][u8 attrs]
fn packCell(x: u16, y: u16, cell: Cell, out: *[CELL_PACKED_SIZE]u8) void {
    // x: big-endian u16
    out[0] = @intCast((x >> 8) & 0xFF);
    out[1] = @intCast(x & 0xFF);
    // y: big-endian u16
    out[2] = @intCast((y >> 8) & 0xFF);
    out[3] = @intCast(y & 0xFF);
    // codepoint: big-endian u24 (from u21, zero-extended)
    const cp: u24 = @intCast(cell.codepoint);
    out[4] = @intCast((cp >> 16) & 0xFF);
    out[5] = @intCast((cp >> 8) & 0xFF);
    out[6] = @intCast(cp & 0xFF);
    // fg: big-endian u24
    const fg = cell.fg.toRgb24();
    out[7] = @intCast((fg >> 16) & 0xFF);
    out[8] = @intCast((fg >> 8) & 0xFF);
    out[9] = @intCast(fg & 0xFF);
    // bg: big-endian u24
    const bg = cell.bg.toRgb24();
    out[10] = @intCast((bg >> 16) & 0xFF);
    out[11] = @intCast((bg >> 8) & 0xFF);
    out[12] = @intCast(bg & 0xFF);
    // attrs: u8
    out[13] = @bitCast(cell.attrs);
}

/// Unpack 14 bytes into position + cell
fn unpackCell(data: *const [CELL_PACKED_SIZE]u8) struct { x: u16, y: u16, cell: Cell } {
    return .{
        .x = @as(u16, data[0]) << 8 | data[1],
        .y = @as(u16, data[2]) << 8 | data[3],
        .cell = .{
            .codepoint = @intCast(@as(u24, data[4]) << 16 | @as(u24, data[5]) << 8 | data[6]),
            .fg = Color.rgb(data[7], data[8], data[9]),
            .bg = Color.rgb(data[10], data[11], data[12]),
            .attrs = @bitCast(data[13]),
        },
    };
}

// ============================================================================
// SYRUP FRAME ENCODING (terminal:// wire format)
// ============================================================================

/// Syrup record label for terminal sync frames
const LABEL_SYNC = "terminal:sync";
const LABEL_RESIZE = "terminal:resize";
const LABEL_CURSOR = "terminal:cursor";

/// Maximum Syrup frame size (header + payload)
pub const MAX_FRAME_SIZE: usize = 4 + // length prefix
    64 + // record overhead (label, delimiters, integers)
    MAX_DIRTY * CELL_PACKED_SIZE; // cell data

/// Encode a terminal sync frame into Syrup wire format.
///
/// Format: length-prefixed Syrup record
///   [u32 len]<13"terminal:sync <gen>+ <cols>+ <rows>+ <N>:<packed-cells>>
///
/// The record uses Syrup encoding:
///   < = record start
///   13"terminal:sync = label (string)
///   <gen>+ = generation (positive integer)
///   <cols>+ = columns
///   <rows>+ = rows
///   <N>:<packed> = cell data (byte string)
///   > = record end
pub fn encodeSyncFrame(grid: *Grid, out: []u8) !usize {
    // First, commit dirty cells to a packed buffer
    var cell_buf: [MAX_DIRTY * CELL_PACKED_SIZE]u8 = undefined;
    const packed_len = grid.commit(&cell_buf);

    // Build Syrup record manually (no allocator needed)
    var pos: usize = 4; // skip length prefix

    // Record start
    out[pos] = '<';
    pos += 1;

    // Label: string "terminal:sync"
    pos += writeDecimal(out[pos..], LABEL_SYNC.len);
    out[pos] = '"';
    pos += 1;
    @memcpy(out[pos..][0..LABEL_SYNC.len], LABEL_SYNC);
    pos += LABEL_SYNC.len;

    // Field 1: generation (positive integer)
    pos += writeDecimal(out[pos..], grid.generation);
    out[pos] = '+';
    pos += 1;

    // Field 2: cols
    pos += writeDecimal(out[pos..], grid.cols);
    out[pos] = '+';
    pos += 1;

    // Field 3: rows
    pos += writeDecimal(out[pos..], grid.rows);
    out[pos] = '+';
    pos += 1;

    // Field 4: packed cell data (byte string)
    pos += writeDecimal(out[pos..], packed_len);
    out[pos] = ':';
    pos += 1;
    if (packed_len > 0) {
        @memcpy(out[pos..][0..packed_len], cell_buf[0..packed_len]);
        pos += packed_len;
    }

    // Record end
    out[pos] = '>';
    pos += 1;

    // Write length prefix (big-endian u32)
    const payload_len: u32 = @intCast(pos - 4);
    out[0] = @intCast((payload_len >> 24) & 0xFF);
    out[1] = @intCast((payload_len >> 16) & 0xFF);
    out[2] = @intCast((payload_len >> 8) & 0xFF);
    out[3] = @intCast(payload_len & 0xFF);

    return pos;
}

/// Encode a resize frame
pub fn encodeResizeFrame(cols: u16, rows: u16, out: []u8) !usize {
    var pos: usize = 4; // skip length prefix

    out[pos] = '<';
    pos += 1;

    pos += writeDecimal(out[pos..], LABEL_RESIZE.len);
    out[pos] = '"';
    pos += 1;
    @memcpy(out[pos..][0..LABEL_RESIZE.len], LABEL_RESIZE);
    pos += LABEL_RESIZE.len;

    pos += writeDecimal(out[pos..], cols);
    out[pos] = '+';
    pos += 1;

    pos += writeDecimal(out[pos..], rows);
    out[pos] = '+';
    pos += 1;

    out[pos] = '>';
    pos += 1;

    const payload_len: u32 = @intCast(pos - 4);
    out[0] = @intCast((payload_len >> 24) & 0xFF);
    out[1] = @intCast((payload_len >> 16) & 0xFF);
    out[2] = @intCast((payload_len >> 8) & 0xFF);
    out[3] = @intCast(payload_len & 0xFF);

    return pos;
}

/// Encode a cursor position frame
pub fn encodeCursorFrame(x: u16, y: u16, out: []u8) !usize {
    var pos: usize = 4;

    out[pos] = '<';
    pos += 1;

    pos += writeDecimal(out[pos..], LABEL_CURSOR.len);
    out[pos] = '"';
    pos += 1;
    @memcpy(out[pos..][0..LABEL_CURSOR.len], LABEL_CURSOR);
    pos += LABEL_CURSOR.len;

    pos += writeDecimal(out[pos..], x);
    out[pos] = '+';
    pos += 1;

    pos += writeDecimal(out[pos..], y);
    out[pos] = '+';
    pos += 1;

    out[pos] = '>';
    pos += 1;

    const payload_len: u32 = @intCast(pos - 4);
    out[0] = @intCast((payload_len >> 24) & 0xFF);
    out[1] = @intCast((payload_len >> 16) & 0xFF);
    out[2] = @intCast((payload_len >> 8) & 0xFF);
    out[3] = @intCast(payload_len & 0xFF);

    return pos;
}

// ============================================================================
// SYRUP FRAME DECODING
// ============================================================================

/// Decoded terminal frame
pub const DecodedFrame = union(enum) {
    sync: SyncFrame,
    resize: ResizeFrame,
    cursor: CursorFrame,
    unknown: void,
};

pub const SyncFrame = struct {
    generation: u64,
    cols: u16,
    rows: u16,
    packed_data: []const u8,
};

pub const ResizeFrame = struct {
    cols: u16,
    rows: u16,
};

pub const CursorFrame = struct {
    x: u16,
    y: u16,
};

/// Decode a length-prefixed Syrup terminal frame
pub fn decodeFrame(data: []const u8) !DecodedFrame {
    if (data.len < 5) return error.Incomplete; // need at least prefix + '<'

    // Read length prefix
    const payload_len: usize = @as(usize, data[0]) << 24 |
        @as(usize, data[1]) << 16 |
        @as(usize, data[2]) << 8 |
        data[3];

    if (data.len < 4 + payload_len) return error.Incomplete;

    const payload = data[4 .. 4 + payload_len];

    // Expect record: <label fields...>
    if (payload.len < 2 or payload[0] != '<') return error.InvalidFrame;
    if (payload[payload.len - 1] != '>') return error.InvalidFrame;

    const inner = payload[1 .. payload.len - 1];

    // Parse label (string: <len>"<content>)
    const label_result = parseSyrupString(inner) orelse return error.InvalidFrame;
    const label = label_result.value;
    var rest = label_result.rest;

    if (strEql(label, LABEL_SYNC)) {
        // Parse: gen+ cols+ rows+ N:packed
        const gen = parseSyrupPosInt(rest) orelse return error.InvalidFrame;
        rest = gen.rest;
        const cols = parseSyrupPosInt(rest) orelse return error.InvalidFrame;
        rest = cols.rest;
        const rows = parseSyrupPosInt(rest) orelse return error.InvalidFrame;
        rest = rows.rest;
        const cell_data = parseSyrupBytes(rest) orelse return error.InvalidFrame;

        return .{ .sync = .{
            .generation = gen.value,
            .cols = @intCast(@min(cols.value, MAX_COLS)),
            .rows = @intCast(@min(rows.value, MAX_ROWS)),
            .packed_data = cell_data.value,
        } };
    } else if (strEql(label, LABEL_RESIZE)) {
        const cols = parseSyrupPosInt(rest) orelse return error.InvalidFrame;
        rest = cols.rest;
        const rows = parseSyrupPosInt(rest) orelse return error.InvalidFrame;

        return .{ .resize = .{
            .cols = @intCast(@min(cols.value, MAX_COLS)),
            .rows = @intCast(@min(rows.value, MAX_ROWS)),
        } };
    } else if (strEql(label, LABEL_CURSOR)) {
        const x = parseSyrupPosInt(rest) orelse return error.InvalidFrame;
        rest = x.rest;
        const y = parseSyrupPosInt(rest) orelse return error.InvalidFrame;

        return .{ .cursor = .{
            .x = @intCast(@min(x.value, MAX_COLS)),
            .y = @intCast(@min(y.value, MAX_ROWS)),
        } };
    }

    return .{ .unknown = {} };
}

// ============================================================================
// URI PARSING (terminal:// scheme)
// ============================================================================

/// Parsed terminal:// URI
pub const TerminalUri = struct {
    authority: Authority,
    path: []const u8,
    // Query params extracted inline (no allocator)
    param_cols: ?u16 = null,
    param_rows: ?u16 = null,
    param_x: ?u16 = null,
    param_y: ?u16 = null,
};

pub const Authority = enum {
    cell,
    frame,
    color,
    grid,
    unknown,
};

/// Parse a terminal:// URI without allocation
pub fn parseUri(uri: []const u8) ?TerminalUri {
    const prefix = "terminal://";
    if (uri.len < prefix.len) return null;
    if (!strEql(uri[0..prefix.len], prefix)) return null;

    const rest = uri[prefix.len..];

    // Find authority/path boundary
    var slash_pos: usize = rest.len;
    for (rest, 0..) |c, i| {
        if (c == '/' or c == '?') {
            slash_pos = i;
            break;
        }
    }

    const authority_str = rest[0..slash_pos];
    const authority: Authority = if (strEql(authority_str, "cell"))
        .cell
    else if (strEql(authority_str, "frame"))
        .frame
    else if (strEql(authority_str, "color"))
        .color
    else if (strEql(authority_str, "grid"))
        .grid
    else
        .unknown;

    // Path (after slash, before query)
    var path: []const u8 = "";
    var query_start: usize = rest.len;
    if (slash_pos < rest.len and rest[slash_pos] == '/') {
        const path_start = slash_pos + 1;
        for (rest[path_start..], 0..) |c, i| {
            if (c == '?') {
                query_start = path_start + i;
                break;
            }
        }
        if (query_start > path_start) {
            path = rest[path_start..query_start];
        } else if (query_start == rest.len) {
            path = rest[path_start..];
        }
    }

    var result = TerminalUri{
        .authority = authority,
        .path = path,
    };

    // Parse query params (simple key=value pairs)
    if (query_start < rest.len and rest[query_start] == '?') {
        var qrest = rest[query_start + 1 ..];
        while (qrest.len > 0) {
            // Find = and &
            var eq_pos: usize = qrest.len;
            var amp_pos: usize = qrest.len;
            for (qrest, 0..) |c, i| {
                if (c == '=' and eq_pos == qrest.len) eq_pos = i;
                if (c == '&') {
                    amp_pos = i;
                    break;
                }
            }

            if (eq_pos < amp_pos) {
                const key = qrest[0..eq_pos];
                const val = qrest[eq_pos + 1 .. amp_pos];
                const num = parseDecimal(val);

                if (strEql(key, "cols")) result.param_cols = @intCast(num orelse 80);
                if (strEql(key, "rows")) result.param_rows = @intCast(num orelse 24);
                if (strEql(key, "x")) result.param_x = @intCast(num orelse 0);
                if (strEql(key, "y")) result.param_y = @intCast(num orelse 0);
            }

            if (amp_pos < qrest.len) {
                qrest = qrest[amp_pos + 1 ..];
            } else {
                break;
            }
        }
    }

    return result;
}

// ============================================================================
// DISPATCH (terminal:// URI → operation)
// ============================================================================

/// Operation result
pub const OpResult = struct {
    /// Bytes written to output buffer (0 if read-only op)
    bytes_written: usize = 0,
    /// For read ops: the cell value
    cell: ?Cell = null,
    /// For trit ops: the GF(3) classification
    trit: ?Trit = null,
    /// Generation after operation
    generation: u64 = 0,
};

/// Dispatch a terminal:// URI against a grid.
/// For write ops, `out` receives the Syrup frame.
/// For read ops, the result contains the cell.
pub fn dispatch(grid: *Grid, uri: []const u8, out: []u8) !OpResult {
    const parsed = parseUri(uri) orelse return error.InvalidUri;

    switch (parsed.authority) {
        .cell => {
            if (strEql(parsed.path, "write")) {
                // Write a space at (x, y) — actual content set via grid.put()
                // The URI just triggers a commit
                return .{ .generation = grid.generation };
            } else if (strEql(parsed.path, "read")) {
                const x = parsed.param_x orelse 0;
                const y = parsed.param_y orelse 0;
                const cell = grid.readCell(x, y);
                return .{ .cell = cell, .generation = grid.generation };
            }
        },
        .frame => {
            if (strEql(parsed.path, "sync")) {
                const n = try encodeSyncFrame(grid, out);
                return .{ .bytes_written = n, .generation = grid.generation };
            } else if (strEql(parsed.path, "resize")) {
                const cols = parsed.param_cols orelse 80;
                const rows = parsed.param_rows orelse 24;
                grid.resize(cols, rows);
                const n = try encodeResizeFrame(cols, rows, out);
                return .{ .bytes_written = n, .generation = grid.generation };
            }
        },
        .color => {
            if (strEql(parsed.path, "trit")) {
                const x = parsed.param_x orelse 0;
                const y = parsed.param_y orelse 0;
                const cell = grid.readCell(x, y);
                return .{ .trit = Trit.fromRgb24(cell.fg.toRgb24()), .cell = cell, .generation = grid.generation };
            }
        },
        .grid => {
            if (strEql(parsed.path, "clear")) {
                grid.clear();
                return .{ .generation = grid.generation };
            } else if (strEql(parsed.path, "info")) {
                return .{ .generation = grid.generation };
            }
        },
        .unknown => {},
    }

    return error.UnknownOperation;
}

// ============================================================================
// MINI SYRUP PARSER (no allocator, for decoding incoming frames)
// ============================================================================

const ParseResult = struct {
    fn Of(comptime T: type) type {
        return struct { value: T, rest: []const u8 };
    }
};

/// Parse a Syrup string: <len>"<content>
fn parseSyrupString(data: []const u8) ?ParseResult.Of([]const u8) {
    const len_result = parseSyrupLenPrefix(data, '"') orelse return null;
    const str_len = len_result.value;
    const after_quote = len_result.rest;
    if (after_quote.len < str_len) return null;
    return .{
        .value = after_quote[0..str_len],
        .rest = after_quote[str_len..],
    };
}

/// Parse a Syrup byte string: <len>:<content>
fn parseSyrupBytes(data: []const u8) ?ParseResult.Of([]const u8) {
    const len_result = parseSyrupLenPrefix(data, ':') orelse return null;
    const byte_len = len_result.value;
    const after_colon = len_result.rest;
    if (after_colon.len < byte_len) return null;
    return .{
        .value = after_colon[0..byte_len],
        .rest = after_colon[byte_len..],
    };
}

/// Parse a Syrup positive integer: <digits>+
fn parseSyrupPosInt(data: []const u8) ?ParseResult.Of(u64) {
    var i: usize = 0;
    while (i < data.len and data[i] >= '0' and data[i] <= '9') : (i += 1) {}
    if (i == 0 or i >= data.len or data[i] != '+') return null;
    const value = parseDecimal(data[0..i]) orelse return null;
    return .{ .value = value, .rest = data[i + 1 ..] };
}

/// Parse length prefix before a delimiter: <digits><delim>
fn parseSyrupLenPrefix(data: []const u8, delim: u8) ?ParseResult.Of(usize) {
    var i: usize = 0;
    while (i < data.len and data[i] >= '0' and data[i] <= '9') : (i += 1) {}
    if (i == 0 or i >= data.len or data[i] != delim) return null;
    const value = parseDecimal(data[0..i]) orelse return null;
    return .{ .value = @intCast(value), .rest = data[i + 1 ..] };
}

// ============================================================================
// HELPERS (no OS deps)
// ============================================================================

/// Write a decimal number to a buffer, return bytes written
fn writeDecimal(buf: []u8, value: anytype) usize {
    const v: u64 = @intCast(value);
    if (v == 0) {
        buf[0] = '0';
        return 1;
    }
    var tmp: [20]u8 = undefined;
    var n: usize = 0;
    var rem = v;
    while (rem > 0) {
        tmp[n] = @intCast('0' + (rem % 10));
        rem /= 10;
        n += 1;
    }
    // Reverse into output
    for (0..n) |i| {
        buf[i] = tmp[n - 1 - i];
    }
    return n;
}

/// Parse a decimal string to u64
fn parseDecimal(s: []const u8) ?u64 {
    if (s.len == 0) return null;
    var result: u64 = 0;
    for (s) |c| {
        if (c < '0' or c > '9') return null;
        result = result * 10 + (c - '0');
    }
    return result;
}

/// String equality without std
fn strEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (ca != cb) return false;
    }
    return true;
}

// ============================================================================
// TESTS
// ============================================================================

const testing = if (!is_freestanding) @import("std").testing else struct {};

test "grid write and read" {
    var grid = Grid.init(80, 24);
    grid.put(5, 3, 'A', 0xFF0000, 0x000000, .{});

    const cell = grid.readCell(5, 3);
    try testing.expectEqual(@as(u21, 'A'), cell.codepoint);
    try testing.expectEqual(@as(u24, 0xFF0000), cell.fg);
}

test "grid dirty tracking" {
    var grid = Grid.init(80, 24);
    try testing.expectEqual(@as(usize, 0), grid.dirty_count);

    grid.put(0, 0, 'X', 0xFFFFFF, 0x000000, .{});
    try testing.expectEqual(@as(usize, 1), grid.dirty_count);

    // Writing same cell again should not add to dirty
    grid.put(0, 0, 'X', 0xFFFFFF, 0x000000, .{});
    try testing.expectEqual(@as(usize, 1), grid.dirty_count);
}

test "cell pack and unpack roundtrip" {
    const cell = Cell{ .codepoint = 0x1F600, .fg = 0xABCDEF, .bg = 0x123456, .attrs = .{ .bold = true, .italic = true } };
    var buf: [CELL_PACKED_SIZE]u8 = undefined;
    packCell(42, 17, cell, &buf);

    const result = unpackCell(&buf);
    try testing.expectEqual(@as(u16, 42), result.x);
    try testing.expectEqual(@as(u16, 17), result.y);
    try testing.expectEqual(cell.codepoint, result.cell.codepoint);
    try testing.expectEqual(cell.fg, result.cell.fg);
    try testing.expectEqual(cell.bg, result.cell.bg);
    try testing.expectEqual(@as(u8, @bitCast(cell.attrs)), @as(u8, @bitCast(result.cell.attrs)));
}

test "sync frame encode and decode roundtrip" {
    var grid = Grid.init(80, 24);
    grid.put(0, 0, 'H', 0xFF0000, 0x000000, .{});
    grid.put(1, 0, 'i', 0x00FF00, 0x000000, .{});

    var buf: [4096]u8 = undefined;
    const frame_len = try encodeSyncFrame(&grid, &buf);
    try testing.expect(frame_len > 0);

    const decoded = try decodeFrame(buf[0..frame_len]);
    switch (decoded) {
        .sync => |sync| {
            try testing.expectEqual(@as(u16, 80), sync.cols);
            try testing.expectEqual(@as(u16, 24), sync.rows);
            try testing.expectEqual(@as(usize, 2 * CELL_PACKED_SIZE), sync.packed_data.len);
        },
        else => return error.UnexpectedFrame,
    }
}

test "resize frame encode and decode" {
    var buf: [256]u8 = undefined;
    const frame_len = try encodeResizeFrame(120, 40, &buf);

    const decoded = try decodeFrame(buf[0..frame_len]);
    switch (decoded) {
        .resize => |r| {
            try testing.expectEqual(@as(u16, 120), r.cols);
            try testing.expectEqual(@as(u16, 40), r.rows);
        },
        else => return error.UnexpectedFrame,
    }
}

test "cursor frame encode and decode" {
    var buf: [256]u8 = undefined;
    const frame_len = try encodeCursorFrame(10, 5, &buf);

    const decoded = try decodeFrame(buf[0..frame_len]);
    switch (decoded) {
        .cursor => |c| {
            try testing.expectEqual(@as(u16, 10), c.x);
            try testing.expectEqual(@as(u16, 5), c.y);
        },
        else => return error.UnexpectedFrame,
    }
}

test "URI parsing" {
    const uri1 = parseUri("terminal://cell/read?x=5&y=10");
    try testing.expect(uri1 != null);
    try testing.expectEqual(Authority.cell, uri1.?.authority);
    try testing.expect(strEql(uri1.?.path, "read"));
    try testing.expectEqual(@as(u16, 5), uri1.?.param_x.?);
    try testing.expectEqual(@as(u16, 10), uri1.?.param_y.?);

    const uri2 = parseUri("terminal://frame/resize?cols=120&rows=40");
    try testing.expect(uri2 != null);
    try testing.expectEqual(Authority.frame, uri2.?.authority);
    try testing.expect(strEql(uri2.?.path, "resize"));
    try testing.expectEqual(@as(u16, 120), uri2.?.param_cols.?);
    try testing.expectEqual(@as(u16, 40), uri2.?.param_rows.?);
}

test "dispatch frame/sync" {
    var grid = Grid.init(80, 24);
    grid.put(0, 0, 'Z', 0xABCDEF, 0x000000, .{});

    var buf: [4096]u8 = undefined;
    const result = try dispatch(&grid, "terminal://frame/sync", &buf);
    try testing.expect(result.bytes_written > 0);
}

test "dispatch cell/read" {
    var grid = Grid.init(80, 24);
    grid.put(3, 7, 'Q', 0x112233, 0x445566, .{ .bold = true });

    var buf: [64]u8 = undefined;
    const result = try dispatch(&grid, "terminal://cell/read?x=3&y=7", &buf);
    try testing.expect(result.cell != null);
    try testing.expectEqual(@as(u21, 'Q'), result.cell.?.codepoint);
    try testing.expectEqual(@as(u24, 0x112233), result.cell.?.fg);
}

test "dispatch color/trit" {
    var grid = Grid.init(80, 24);
    // Red foreground → hue ≈ 0° → PLUS
    grid.put(0, 0, 'R', 0xFF0000, 0x000000, .{});

    var buf: [64]u8 = undefined;
    const result = try dispatch(&grid, "terminal://color/trit?x=0&y=0", &buf);
    try testing.expect(result.trit != null);
    try testing.expectEqual(Trit.plus, result.trit.?);
}

test "GF(3) trit from RGB" {
    // Red → PLUS (hue 0°)
    try testing.expectEqual(Trit.plus, Trit.fromRgb24(0xFF0000));
    // Green → ERGODIC (hue 120°)
    try testing.expectEqual(Trit.ergodic, Trit.fromRgb24(0x00FF00));
    // Blue → MINUS (hue 240°)
    try testing.expectEqual(Trit.minus, Trit.fromRgb24(0x0000FF));
}

test "full pipeline: write → commit → decode → apply" {
    // Source terminal
    var src = Grid.init(80, 24);
    src.put(0, 0, 'A', 0xFF0000, 0x000000, .{ .bold = true });
    src.put(1, 0, 'B', 0x00FF00, 0x000000, .{});
    src.put(2, 0, 'C', 0x0000FF, 0x000000, .{ .underline = true });

    // Encode sync frame
    var buf: [4096]u8 = undefined;
    const frame_len = try encodeSyncFrame(&src, &buf);

    // Decode on receiver
    const decoded = try decodeFrame(buf[0..frame_len]);
    const sync = switch (decoded) {
        .sync => |s| s,
        else => return error.UnexpectedFrame,
    };

    // Apply to destination terminal
    var dst = Grid.init(sync.cols, sync.rows);
    const applied = dst.apply(sync.packed_data);
    try testing.expectEqual(@as(usize, 3), applied);

    // Verify cells match
    try testing.expectEqual(src.readCell(0, 0).codepoint, dst.readCell(0, 0).codepoint);
    try testing.expectEqual(src.readCell(0, 0).fg, dst.readCell(0, 0).fg);
    try testing.expectEqual(src.readCell(1, 0).codepoint, dst.readCell(1, 0).codepoint);
    try testing.expectEqual(src.readCell(2, 0).codepoint, dst.readCell(2, 0).codepoint);
    try testing.expectEqual(
        @as(u8, @bitCast(src.readCell(2, 0).attrs)),
        @as(u8, @bitCast(dst.readCell(2, 0).attrs)),
    );
}

test "writeString" {
    var grid = Grid.init(80, 24);
    grid.writeString("Hi", 0xFFFFFF, 0x000000);

    try testing.expectEqual(@as(u21, 'H'), grid.readCell(0, 0).codepoint);
    try testing.expectEqual(@as(u21, 'i'), grid.readCell(1, 0).codepoint);
    try testing.expectEqual(@as(u16, 2), grid.cursor_x);
}
