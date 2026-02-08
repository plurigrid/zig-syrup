//! terminal:// WASM Runtime — wasm32-freestanding exports
//!
//! C ABI exports for running the terminal pipeline in WASM.
//! Mirrors the stellogen wasm_runtime.zig pattern.
//!
//! Exports:
//!   terminal_init(cols, rows)          → initialize grid
//!   terminal_put(x, y, cp, fg, bg, a) → write a cell
//!   terminal_read(x, y)               → read cell codepoint
//!   terminal_read_fg(x, y)            → read cell fg color
//!   terminal_read_bg(x, y)            → read cell bg color
//!   terminal_read_attrs(x, y)         → read cell attrs
//!   terminal_write_str(ptr, len)      → write string at cursor
//!   terminal_resize(cols, rows)       → resize grid
//!   terminal_clear()                  → clear grid
//!   terminal_commit()                 → commit dirty → frame buffer
//!   terminal_frame_ptr()              → pointer to last frame
//!   terminal_frame_len()              → length of last frame
//!   terminal_apply(ptr, len)          → apply incoming packed data
//!   terminal_trit(x, y)              → GF(3) trit of cell fg
//!   terminal_generation()             → current generation
//!   terminal_cols()                   → current columns
//!   terminal_rows()                   → current rows
//!   terminal_cursor_x()               → cursor X
//!   terminal_cursor_y()               → cursor Y
//!   terminal_dispatch(uri_ptr, len)   → dispatch terminal:// URI

const terminal = @import("terminal.zig");
const Grid = terminal.Grid;

// ============================================================================
// Global State
// ============================================================================

var grid: Grid = Grid.init(80, 24);

/// Frame output buffer (static, no allocation)
var frame_buf: [terminal.MAX_FRAME_SIZE]u8 = undefined;
var frame_len: usize = 0;

// ============================================================================
// Exported Functions (C ABI)
// ============================================================================

/// Initialize terminal grid with dimensions
export fn terminal_init(cols: u16, rows: u16) void {
    grid = Grid.init(cols, rows);
    frame_len = 0;
}

/// Write a cell at (x, y)
export fn terminal_put(x: u16, y: u16, cp: u32, fg: u32, bg: u32, attrs: u8) void {
    grid.put(x, y, @intCast(cp & 0x1FFFFF), @intCast(fg & 0xFFFFFF), @intCast(bg & 0xFFFFFF), @bitCast(attrs));
}

/// Read cell codepoint at (x, y)
export fn terminal_read(x: u16, y: u16) u32 {
    return grid.readCell(x, y).codepoint;
}

/// Read cell foreground color at (x, y)
export fn terminal_read_fg(x: u16, y: u16) u32 {
    return grid.readCell(x, y).fg;
}

/// Read cell background color at (x, y)
export fn terminal_read_bg(x: u16, y: u16) u32 {
    return grid.readCell(x, y).bg;
}

/// Read cell attributes at (x, y)
export fn terminal_read_attrs(x: u16, y: u16) u8 {
    return @bitCast(grid.readCell(x, y).attrs);
}

/// Write a string at cursor position (reads from WASM linear memory)
export fn terminal_write_str(ptr: u32, len: u32, fg: u32, bg: u32) void {
    const str: [*]const u8 = @ptrFromInt(ptr);
    grid.writeString(str[0..len], @intCast(fg & 0xFFFFFF), @intCast(bg & 0xFFFFFF));
}

/// Resize the grid
export fn terminal_resize(cols: u16, rows: u16) void {
    grid.resize(cols, rows);
}

/// Clear the grid
export fn terminal_clear() void {
    grid.clear();
}

/// Commit dirty cells → length-prefixed Syrup frame in frame_buf
/// Returns the frame length (0 on failure)
export fn terminal_commit() u32 {
    frame_len = terminal.encodeSyncFrame(&grid, &frame_buf) catch return 0;
    return @intCast(frame_len);
}

/// Get pointer to the last committed frame (in WASM linear memory)
export fn terminal_frame_ptr() u32 {
    return @intFromPtr(&frame_buf);
}

/// Get length of the last committed frame
export fn terminal_frame_len() u32 {
    return @intCast(frame_len);
}

/// Apply incoming packed cell data (from WASM linear memory)
/// Returns number of cells applied
export fn terminal_apply(ptr: u32, len: u32) u32 {
    const data: [*]const u8 = @ptrFromInt(ptr);
    return @intCast(grid.apply(data[0..len]));
}

/// Get GF(3) trit of cell foreground at (x, y)
/// Returns -1 (MINUS), 0 (ERGODIC), or 1 (PLUS)
export fn terminal_trit(x: u16, y: u16) i8 {
    const cell = grid.readCell(x, y);
    return @intFromEnum(terminal.Trit.fromRgb24(cell.fg));
}

/// Get current generation counter
export fn terminal_generation() u64 {
    return grid.generation;
}

/// Get current grid columns
export fn terminal_cols() u16 {
    return grid.cols;
}

/// Get current grid rows
export fn terminal_rows() u16 {
    return grid.rows;
}

/// Get cursor X position
export fn terminal_cursor_x() u16 {
    return grid.cursor_x;
}

/// Get cursor Y position
export fn terminal_cursor_y() u16 {
    return grid.cursor_y;
}

/// Dispatch a terminal:// URI (reads URI from WASM linear memory)
/// Returns bytes_written to frame_buf (0 for non-output ops, >0 for sync/resize)
export fn terminal_dispatch(uri_ptr: u32, uri_len: u32) u32 {
    const uri: [*]const u8 = @ptrFromInt(uri_ptr);
    const result = terminal.dispatch(&grid, uri[0..uri_len], &frame_buf) catch return 0;
    frame_len = result.bytes_written;
    return @intCast(frame_len);
}

/// Get number of dirty cells pending commit
export fn terminal_dirty_count() u32 {
    return @intCast(grid.dirty_count);
}

// ============================================================================
// Panic Handler (required for wasm32-freestanding)
// ============================================================================

pub fn panic(msg: []const u8, stack_trace: ?*@import("std").builtin.StackTrace, ret_addr: ?usize) noreturn {
    _ = msg;
    _ = stack_trace;
    _ = ret_addr;
    @trap();
}
