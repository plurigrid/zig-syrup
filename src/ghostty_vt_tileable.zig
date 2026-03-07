//! ghostty_vt_tileable — Custom libghostty-vt Adaptation
//!
//! Links against the libghostty-vt.dylib to parse SGR/OSC sequences,
//! then renders a gain-of-function viral tile display via retty's AnsiBackend.
//!
//! One-shot rapid display: init → infect → spread → render → stdout
//!
//! Architecture:
//!   libghostty-vt (dylib) → SGR color parsing → trit classification
//!   tileable_gof           → viral tile layout + infection spread
//!   retty                  → AnsiBackend → ANSI escape sequences → stdout
//!
//! GF(3) Color: #564516 (dark olive-bronze) = TriadicColor(+1, 0, -1)
//! Trit: gain-of-function (+1) × terminal:// (0) × tidar-verify (-1) = 0 ✓

const std = @import("std");
const retty = @import("retty");
const terminal_mod = @import("terminal");
const virion = @import("virion");
const tileable_gof = @import("tileable_gof");

const Color = terminal_mod.Color;
const Cell = terminal_mod.Cell;
const Rect = retty.Rect;
const Buffer = retty.Buffer;
const Block = retty.Block;
const Borders = retty.Borders;
const Style = retty.Style;
const Span = retty.Span;
const Line = retty.Line;
const Text = retty.Text;
const Paragraph = retty.Paragraph;
const Gauge = retty.Gauge;
const AnsiBackend = retty.AnsiBackend;
const Trit = virion.Trit;

// ===========================================================================
// libghostty-vt C FFI declarations
// ===========================================================================

// Verified FFI declarations (matching libghostty-vt C headers)
// -- color.h --
const GhosttyColorRgb = extern struct { r: u8, g: u8, b: u8 };
const GhosttyColorPaletteIndex = u8;
extern "c" fn ghostty_color_rgb_get(color: GhosttyColorRgb, r: *u8, g: *u8, b: *u8) void;

// -- simd --
extern "c" fn ghostty_simd_codepoint_width(cp: u32) i8;

// -- result.h --
const GhosttyResult = enum(c_int) {
    success = 0,
    out_of_memory = -1,
    invalid_value = -2,
};

// -- sgr.h --
const GhosttySgrParser = ?*anyopaque;

const GhosttySgrAttributeTag = enum(c_int) {
    unset = 0,
    unknown = 1,
    bold = 2,
    reset_bold = 3,
    italic = 4,
    reset_italic = 5,
    faint = 6,
    underline = 7,
    reset_underline = 8,
    underline_color = 9,
    underline_color_256 = 10,
    reset_underline_color = 11,
    overline = 12,
    reset_overline = 13,
    blink = 14,
    reset_blink = 15,
    inverse = 16,
    reset_inverse = 17,
    invisible = 18,
    reset_invisible = 19,
    strikethrough = 20,
    reset_strikethrough = 21,
    direct_color_fg = 22,
    direct_color_bg = 23,
    bg_8 = 24,
    fg_8 = 25,
    reset_fg = 26,
    reset_bg = 27,
    bright_bg_8 = 28,
    bright_fg_8 = 29,
    bg_256 = 30,
    fg_256 = 31,
};

const GhosttySgrUnderline = enum(c_int) {
    none = 0,
    single = 1,
    double_ = 2,
    curly = 3,
    dotted = 4,
    dashed = 5,
};

const GhosttySgrUnknown = extern struct {
    full_ptr: ?[*]const u16,
    full_len: usize,
    partial_ptr: ?[*]const u16,
    partial_len: usize,
};

const GhosttySgrAttributeValue = extern union {
    unknown: GhosttySgrUnknown,
    underline: GhosttySgrUnderline,
    underline_color: GhosttyColorRgb,
    underline_color_256: GhosttyColorPaletteIndex,
    direct_color_fg: GhosttyColorRgb,
    direct_color_bg: GhosttyColorRgb,
    bg_8: GhosttyColorPaletteIndex,
    fg_8: GhosttyColorPaletteIndex,
    bright_bg_8: GhosttyColorPaletteIndex,
    bright_fg_8: GhosttyColorPaletteIndex,
    bg_256: GhosttyColorPaletteIndex,
    fg_256: GhosttyColorPaletteIndex,
    _padding: [8]u64,
};

const GhosttySgrAttribute = extern struct {
    tag: GhosttySgrAttributeTag,
    value: GhosttySgrAttributeValue,
};

extern "c" fn ghostty_sgr_new(allocator: ?*const anyopaque, parser: *GhosttySgrParser) GhosttyResult;
extern "c" fn ghostty_sgr_free(parser: GhosttySgrParser) void;
extern "c" fn ghostty_sgr_reset(parser: GhosttySgrParser) void;
extern "c" fn ghostty_sgr_set_params(parser: GhosttySgrParser, params: [*]const u16, separators: ?[*]const u8, len: usize) GhosttyResult;
extern "c" fn ghostty_sgr_next(parser: GhosttySgrParser, attr: *GhosttySgrAttribute) bool;
extern "c" fn ghostty_sgr_unknown_full(unknown: GhosttySgrUnknown, ptr: ?*?[*]const u16) usize;
extern "c" fn ghostty_sgr_unknown_partial(unknown: GhosttySgrUnknown, ptr: ?*?[*]const u16) usize;
extern "c" fn ghostty_sgr_attribute_tag(attr: GhosttySgrAttribute) GhosttySgrAttributeTag;
extern "c" fn ghostty_sgr_attribute_value(attr: *GhosttySgrAttribute) *GhosttySgrAttributeValue;

// -- osc.h --
const GhosttyOscParser = ?*anyopaque;
const GhosttyOscCommand = ?*anyopaque;

const GhosttyOscCommandType = enum(c_int) {
    invalid = 0,
    change_window_title = 1,
    change_window_icon = 2,
    prompt_start = 3,
    prompt_end = 4,
    end_of_input = 5,
    end_of_command = 6,
    clipboard_contents = 7,
    report_pwd = 8,
    mouse_shape = 9,
    color_operation = 10,
    kitty_color_protocol = 11,
    show_desktop_notification = 12,
    hyperlink_start = 13,
    hyperlink_end = 14,
    conemu_sleep = 15,
    conemu_show_message_box = 16,
    conemu_change_tab_title = 17,
    conemu_progress_report = 18,
    conemu_wait_input = 19,
    conemu_guimacro = 20,
};

const GhosttyOscCommandData = enum(c_int) {
    invalid = 0,
    change_window_title_str = 1,
};

extern "c" fn ghostty_osc_new(allocator: ?*const anyopaque, parser: *GhosttyOscParser) GhosttyResult;
extern "c" fn ghostty_osc_free(parser: GhosttyOscParser) void;
extern "c" fn ghostty_osc_reset(parser: GhosttyOscParser) void;
extern "c" fn ghostty_osc_next(parser: GhosttyOscParser, byte: u8) void;
extern "c" fn ghostty_osc_end(parser: GhosttyOscParser, terminator: u8) GhosttyOscCommand;
extern "c" fn ghostty_osc_command_type(command: GhosttyOscCommand) GhosttyOscCommandType;
extern "c" fn ghostty_osc_command_data(command: GhosttyOscCommand, data: GhosttyOscCommandData, out: *anyopaque) bool;

// -- key/event.h --
const GhosttyKeyEvent = ?*anyopaque;

const GhosttyKeyAction = enum(c_int) {
    release = 0,
    press = 1,
    repeat = 2,
};

const GhosttyMods = u16;
const GhosttyKey = enum(c_int) {
    unidentified = 0,
    // Writing System Keys
    backquote, backslash, bracket_left, bracket_right, comma,
    digit_0, digit_1, digit_2, digit_3, digit_4,
    digit_5, digit_6, digit_7, digit_8, digit_9,
    equal, intl_backslash, intl_ro, intl_yen,
    a, b, c, d, e, f, g, h, i, j, k, l, m,
    n, o, p, q, r, s, t, u, v, w, x, y, z,
    minus, period, quote, semicolon, slash,
    // Functional Keys
    alt_left, alt_right, backspace, caps_lock, context_menu,
    control_left, control_right, enter, meta_left, meta_right,
    shift_left, shift_right, space, tab, convert, kana_mode, non_convert,
    // Control Pad
    delete, end, help, home, insert, page_down, page_up,
    // Arrow Pad
    arrow_down, arrow_left, arrow_right, arrow_up,
    // Numpad
    num_lock,
    numpad_0, numpad_1, numpad_2, numpad_3, numpad_4,
    numpad_5, numpad_6, numpad_7, numpad_8, numpad_9,
    numpad_add, numpad_backspace, numpad_clear, numpad_clear_entry,
    numpad_comma, numpad_decimal, numpad_divide, numpad_enter,
    numpad_equal, numpad_memory_add, numpad_memory_clear,
    numpad_memory_recall, numpad_memory_store, numpad_memory_subtract,
    numpad_multiply, numpad_paren_left, numpad_paren_right,
    numpad_subtract, numpad_separator,
    numpad_up, numpad_down, numpad_right, numpad_left,
    numpad_begin, numpad_home, numpad_end,
    numpad_insert, numpad_delete, numpad_page_up, numpad_page_down,
    // Function Keys
    escape,
    f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12,
    f13, f14, f15, f16, f17, f18, f19, f20, f21, f22, f23, f24, f25,
    fn_key, fn_lock, print_screen, scroll_lock, pause,
    // Media Keys
    browser_back, browser_favorites, browser_forward, browser_home,
    browser_refresh, browser_search, browser_stop, eject,
    launch_app_1, launch_app_2, launch_mail,
    media_play_pause, media_select, media_stop,
    media_track_next, media_track_previous,
    power, sleep, audio_volume_down, audio_volume_mute, audio_volume_up, wake_up,
    // Legacy
    copy, cut, paste,
};

extern "c" fn ghostty_key_event_new(allocator: ?*const anyopaque, event: *GhosttyKeyEvent) GhosttyResult;
extern "c" fn ghostty_key_event_free(event: GhosttyKeyEvent) void;
extern "c" fn ghostty_key_event_set_action(event: GhosttyKeyEvent, action: GhosttyKeyAction) void;
extern "c" fn ghostty_key_event_get_action(event: GhosttyKeyEvent) GhosttyKeyAction;
extern "c" fn ghostty_key_event_set_key(event: GhosttyKeyEvent, key: GhosttyKey) void;
extern "c" fn ghostty_key_event_get_key(event: GhosttyKeyEvent) GhosttyKey;
extern "c" fn ghostty_key_event_set_mods(event: GhosttyKeyEvent, mods: GhosttyMods) void;
extern "c" fn ghostty_key_event_get_mods(event: GhosttyKeyEvent) GhosttyMods;
extern "c" fn ghostty_key_event_set_consumed_mods(event: GhosttyKeyEvent, consumed_mods: GhosttyMods) void;
extern "c" fn ghostty_key_event_get_consumed_mods(event: GhosttyKeyEvent) GhosttyMods;
extern "c" fn ghostty_key_event_set_composing(event: GhosttyKeyEvent, composing: bool) void;
extern "c" fn ghostty_key_event_get_composing(event: GhosttyKeyEvent) bool;
extern "c" fn ghostty_key_event_set_utf8(event: GhosttyKeyEvent, utf8: ?[*]const u8, len: usize) void;
extern "c" fn ghostty_key_event_get_utf8(event: GhosttyKeyEvent, len: ?*usize) ?[*]const u8;
extern "c" fn ghostty_key_event_set_unshifted_codepoint(event: GhosttyKeyEvent, codepoint: u32) void;
extern "c" fn ghostty_key_event_get_unshifted_codepoint(event: GhosttyKeyEvent) u32;

// -- key/encoder.h --
const GhosttyKeyEncoder = ?*anyopaque;
const GhosttyKittyKeyFlags = u8;

const GhosttyOptionAsAlt = enum(c_int) {
    false_ = 0,
    true_ = 1,
    left = 2,
    right = 3,
};

const GhosttyKeyEncoderOption = enum(c_int) {
    cursor_key_application = 0,
    keypad_key_application = 1,
    ignore_keypad_with_numlock = 2,
    alt_esc_prefix = 3,
    modify_other_keys_state_2 = 4,
    kitty_flags = 5,
    macos_option_as_alt = 6,
};

extern "c" fn ghostty_key_encoder_new(allocator: ?*const anyopaque, encoder: *GhosttyKeyEncoder) GhosttyResult;
extern "c" fn ghostty_key_encoder_free(encoder: GhosttyKeyEncoder) void;
extern "c" fn ghostty_key_encoder_setopt(encoder: GhosttyKeyEncoder, option: GhosttyKeyEncoderOption, value: ?*const anyopaque) void;
extern "c" fn ghostty_key_encoder_encode(encoder: GhosttyKeyEncoder, event: GhosttyKeyEvent, out_buf: ?[*]u8, out_buf_size: usize, out_len: ?*usize) GhosttyResult;

// -- paste.h --
extern "c" fn ghostty_paste_is_safe(data: [*]const u8, len: usize) bool;

// ===========================================================================
// libghostty-vt FFI wrappers
// ===========================================================================

/// Extract RGB components from a GhosttyColorRgb using libghostty-vt
pub fn ghosttyColorRgb(r: u8, g: u8, b: u8) [3]u8 {
    var out_r: u8 = 0;
    var out_g: u8 = 0;
    var out_b: u8 = 0;
    ghostty_color_rgb_get(.{ .r = r, .g = g, .b = b }, &out_r, &out_g, &out_b);
    return .{ out_r, out_g, out_b };
}

/// Get codepoint display width via libghostty-vt SIMD
pub fn ghosttyCodepointWidth(cp: u32) i8 {
    return ghostty_simd_codepoint_width(cp);
}

/// SGR parser wrapper — parse SGR params and iterate attributes
pub const SgrParser = struct {
    handle: GhosttySgrParser = null,

    pub fn init() !SgrParser {
        var parser: GhosttySgrParser = null;
        const result = ghostty_sgr_new(null, &parser);
        if (result != .success) return error.SgrInitFailed;
        return .{ .handle = parser };
    }

    pub fn deinit(self: *SgrParser) void {
        if (self.handle != null) ghostty_sgr_free(self.handle);
        self.handle = null;
    }

    pub fn setParams(self: *SgrParser, params: []const u16, separators: ?[]const u8) !void {
        const sep_ptr: ?[*]const u8 = if (separators) |s| s.ptr else null;
        const result = ghostty_sgr_set_params(self.handle, params.ptr, sep_ptr, params.len);
        if (result != .success) return error.SgrSetParamsFailed;
    }

    pub fn next(self: *SgrParser) ?GhosttySgrAttribute {
        var attr: GhosttySgrAttribute = undefined;
        if (ghostty_sgr_next(self.handle, &attr)) return attr;
        return null;
    }

    pub fn reset(self: *SgrParser) void {
        ghostty_sgr_reset(self.handle);
    }
};

/// OSC parser wrapper — streaming byte-by-byte OSC sequence parsing
pub const OscParser = struct {
    handle: GhosttyOscParser = null,

    pub fn init() !OscParser {
        var parser: GhosttyOscParser = null;
        const result = ghostty_osc_new(null, &parser);
        if (result != .success) return error.OscInitFailed;
        return .{ .handle = parser };
    }

    pub fn deinit(self: *OscParser) void {
        if (self.handle != null) ghostty_osc_free(self.handle);
        self.handle = null;
    }

    pub fn feedByte(self: *OscParser, byte: u8) void {
        ghostty_osc_next(self.handle, byte);
    }

    pub fn end(self: *OscParser, terminator: u8) OscCommand {
        const cmd = ghostty_osc_end(self.handle, terminator);
        return .{ .handle = cmd };
    }

    pub fn reset(self: *OscParser) void {
        ghostty_osc_reset(self.handle);
    }
};

pub const OscCommand = struct {
    handle: GhosttyOscCommand,

    pub fn getType(self: OscCommand) GhosttyOscCommandType {
        return ghostty_osc_command_type(self.handle);
    }
};

/// Key encoder wrapper — converts key events to terminal escape sequences
pub const KeyEncoder = struct {
    handle: GhosttyKeyEncoder = null,

    pub fn init() !KeyEncoder {
        var encoder: GhosttyKeyEncoder = null;
        const result = ghostty_key_encoder_new(null, &encoder);
        if (result != .success) return error.KeyEncoderInitFailed;
        return .{ .handle = encoder };
    }

    pub fn deinit(self: *KeyEncoder) void {
        if (self.handle != null) ghostty_key_encoder_free(self.handle);
        self.handle = null;
    }

    pub fn setOpt(self: *KeyEncoder, option: GhosttyKeyEncoderOption, value: ?*const anyopaque) void {
        ghostty_key_encoder_setopt(self.handle, option, value);
    }

    pub fn encode(self: *KeyEncoder, event: GhosttyKeyEvent, buf: []u8) !usize {
        var written: usize = 0;
        const result = ghostty_key_encoder_encode(self.handle, event, buf.ptr, buf.len, &written);
        if (result == .out_of_memory) return error.BufferTooSmall;
        if (result != .success) return error.KeyEncodeFailed;
        return written;
    }
};

/// Key event wrapper — create and configure key events for encoding
pub const KeyEventBuilder = struct {
    handle: GhosttyKeyEvent = null,

    pub fn init() !KeyEventBuilder {
        var event: GhosttyKeyEvent = null;
        const result = ghostty_key_event_new(null, &event);
        if (result != .success) return error.KeyEventInitFailed;
        return .{ .handle = event };
    }

    pub fn deinit(self: *KeyEventBuilder) void {
        if (self.handle != null) ghostty_key_event_free(self.handle);
        self.handle = null;
    }

    pub fn setAction(self: *KeyEventBuilder, action: GhosttyKeyAction) void {
        ghostty_key_event_set_action(self.handle, action);
    }

    pub fn setKey(self: *KeyEventBuilder, key: GhosttyKey) void {
        ghostty_key_event_set_key(self.handle, key);
    }

    pub fn setMods(self: *KeyEventBuilder, mods: GhosttyMods) void {
        ghostty_key_event_set_mods(self.handle, mods);
    }

    pub fn setUtf8(self: *KeyEventBuilder, text: []const u8) void {
        ghostty_key_event_set_utf8(self.handle, text.ptr, text.len);
    }

    pub fn setUnshiftedCodepoint(self: *KeyEventBuilder, cp: u32) void {
        ghostty_key_event_set_unshifted_codepoint(self.handle, cp);
    }
};

/// Check if paste data is safe (no newlines, no bracketed-paste-end escape)
pub fn pasteIsSafe(data: []const u8) bool {
    return ghostty_paste_is_safe(data.ptr, data.len);
}

// ===========================================================================
// GF(3) Color Constants
// ===========================================================================

/// GOF world color: dark olive-bronze #564516
const GOF_COLOR = Color{ .tag = .srgb, .payload = 0x564516 };

/// Trit-to-color mapping for infection display
fn tritColor(t: Trit) Color {
    return switch (t) {
        .minus => Color{ .tag = .srgb, .payload = 0xFF4444 }, // red: constrain
        .zero => Color{ .tag = .srgb, .payload = 0xFFDD44 }, // yellow: coordinate
        .plus => Color{ .tag = .srgb, .payload = 0x44FF44 }, // green: generate
    };
}

/// Infection state colors
fn infectionColor(state: u8) Color {
    return switch (state) {
        0 => Color{ .tag = .srgb, .payload = 0x333333 }, // empty: dark gray
        1 => GOF_COLOR, // infected: olive-bronze
        2 => Color{ .tag = .srgb, .payload = 0x8B6914 }, // recombinant: brighter gold
        3 => Color{ .tag = .srgb, .payload = 0xCCCCCC }, // immune: light gray
        else => Color.DEFAULT,
    };
}

// ===========================================================================
// Display renderer: tileable GOF → retty Buffer → ANSI
// ===========================================================================

const COLS: u16 = 80;
const ROWS: u16 = 24;

/// Render a single frame of the tileable GOF display
fn renderFrame(tgof: *tileable_gof.TileableGof, buf: *Buffer, gen: u32) void {
    // Clear buffer
    var y: u16 = 0;
    while (y < ROWS) : (y += 1) {
        var x: u16 = 0;
        while (x < COLS) : (x += 1) {
            buf.set(x, y, .{});
        }
    }

    // Render each tile as a bordered block with infection info
    var ti: u16 = 0;
    while (ti < tgof.tile_count) : (ti += 1) {
        const tile = &tgof.tiles[ti];
        if (tile.split != .leaf) continue;
        if (tile.rect.area() == 0) continue;

        const cell = &tgof.network.cells[tile.cell_idx];
        const state: u8 = switch (cell.*) {
            .empty => 0,
            .single => 1,
            .recombinant => 2,
            .immune => 3,
        };

        const fg = if (tile.focused) Color.WHITE else infectionColor(state);
        const bg = if (tile.focused) GOF_COLOR else Color.BLACK;

        // Draw border
        const r = tile.rect;
        if (r.width >= 2 and r.height >= 2) {
            // Corners
            const border_fg = if (tile.focused) Color.YELLOW else Color{ .tag = .srgb, .payload = 0x555555 };
            buf.set(r.x, r.y, .{ .codepoint = 0x256D, .fg = border_fg, .bg = bg }); // ╭
            buf.set(r.right() -| 1, r.y, .{ .codepoint = 0x256E, .fg = border_fg, .bg = bg }); // ╮
            buf.set(r.x, r.bottom() -| 1, .{ .codepoint = 0x2570, .fg = border_fg, .bg = bg }); // ╰
            buf.set(r.right() -| 1, r.bottom() -| 1, .{ .codepoint = 0x256F, .fg = border_fg, .bg = bg }); // ╯

            // Horizontal borders
            var bx: u16 = r.x + 1;
            while (bx < r.right() -| 1) : (bx += 1) {
                buf.set(bx, r.y, .{ .codepoint = 0x2500, .fg = border_fg, .bg = bg }); // ─
                buf.set(bx, r.bottom() -| 1, .{ .codepoint = 0x2500, .fg = border_fg, .bg = bg });
            }

            // Vertical borders
            var by: u16 = r.y + 1;
            while (by < r.bottom() -| 1) : (by += 1) {
                buf.set(r.x, by, .{ .codepoint = 0x2502, .fg = border_fg, .bg = bg }); // │
                buf.set(r.right() -| 1, by, .{ .codepoint = 0x2502, .fg = border_fg, .bg = bg });
            }

            // Title bar: cell index + state
            const title_chars: []const u8 = switch (state) {
                0 => " EMPTY ",
                1 => " INFCT ",
                2 => " RECMB ",
                3 => " IMMUN ",
                else => " ??? ",
            };
            var tx: u16 = r.x + 1;
            for (title_chars) |ch| {
                if (tx >= r.right() -| 1) break;
                buf.set(tx, r.y, .{ .codepoint = ch, .fg = fg, .bg = bg });
                tx += 1;
            }

            // Interior: virion info or empty
            if (r.width >= 4 and r.height >= 4) {
                switch (cell.*) {
                    .single => |v| {
                        // Show virion name (first 6 chars)
                        var nx: u16 = r.x + 1;
                        var ni: u8 = 0;
                        while (ni < 6 and ni < v.name_len) : (ni += 1) {
                            if (nx >= r.right() -| 1) break;
                            if (v.name[ni] == 0) break;
                            buf.set(nx, r.y + 1, .{ .codepoint = v.name[ni], .fg = fg, .bg = bg });
                            nx += 1;
                        }
                        // Show trit signature
                        const trit_chars = [3]u21{
                            switch (v.trit_role) { .minus => '-', .zero => '0', .plus => '+' },
                            switch (v.trit_mode) { .minus => '-', .zero => '0', .plus => '+' },
                            switch (v.trit_polarity) { .minus => '-', .zero => '0', .plus => '+' },
                        };
                        if (r.y + 2 < r.bottom() -| 1) {
                            var cx: u16 = r.x + 1;
                            for (trit_chars) |tc| {
                                if (cx >= r.right() -| 1) break;
                                const tc_color = tritColor(if (tc == '-') .minus else if (tc == '0') .zero else .plus);
                                buf.set(cx, r.y + 2, .{ .codepoint = tc, .fg = tc_color, .bg = bg });
                                cx += 1;
                            }
                        }
                        // Show generation + caps
                        if (r.y + 3 < r.bottom() -| 1) {
                            const gen_char: u21 = 'G';
                            buf.set(r.x + 1, r.y + 3, .{ .codepoint = gen_char, .fg = Color.GRAY, .bg = bg });
                            const gen_digit: u21 = '0' + @as(u21, @min(v.generation, 9));
                            if (r.x + 2 < r.right() -| 1)
                                buf.set(r.x + 2, r.y + 3, .{ .codepoint = gen_digit, .fg = Color.GRAY, .bg = bg });
                        }
                    },
                    .recombinant => |v| {
                        // Show recombinant indicator
                        var nx: u16 = r.x + 1;
                        for ("RECOM") |ch| {
                            if (nx >= r.right() -| 1) break;
                            buf.set(nx, r.y + 1, .{ .codepoint = ch, .fg = Color{ .tag = .srgb, .payload = 0xFFAA00 }, .bg = bg });
                            nx += 1;
                        }
                        if (r.y + 2 < r.bottom() -| 1) {
                            const cap_str = "caps:";
                            var cx: u16 = r.x + 1;
                            for (cap_str) |ch| {
                                if (cx >= r.right() -| 1) break;
                                buf.set(cx, r.y + 2, .{ .codepoint = ch, .fg = Color.GRAY, .bg = bg });
                                cx += 1;
                            }
                            const cap_digit: u21 = '0' + @as(u21, @min(v.cap_count, 9));
                            if (cx < r.right() -| 1)
                                buf.set(cx, r.y + 2, .{ .codepoint = cap_digit, .fg = Color.CYAN, .bg = bg });
                        }
                    },
                    .immune => {
                        var nx: u16 = r.x + 1;
                        for ("SHIELD") |ch| {
                            if (nx >= r.right() -| 1) break;
                            buf.set(nx, r.y + 1, .{ .codepoint = ch, .fg = Color.WHITE, .bg = bg });
                            nx += 1;
                        }
                    },
                    .empty => {
                        // Show empty dot pattern
                        if (r.width >= 4 and r.height >= 4) {
                            buf.set(r.x + 1, r.y + 1, .{ .codepoint = 0x00B7, .fg = Color.DARK_GRAY, .bg = bg }); // ·
                        }
                    },
                }
            }
        }
    }

    // Status bar at bottom
    const status_y = ROWS - 1;
    // Clear status line
    {
        var sx: u16 = 0;
        while (sx < COLS) : (sx += 1) {
            buf.set(sx, status_y, .{ .codepoint = ' ', .fg = Color.BLACK, .bg = GOF_COLOR });
        }
    }

    // Write status info
    const status_prefix = " GOF #564516 ";
    {
        var sx: u16 = 0;
        for (status_prefix) |ch| {
            if (sx >= COLS) break;
            buf.set(sx, status_y, .{ .codepoint = ch, .fg = Color.WHITE, .bg = GOF_COLOR });
            sx += 1;
        }
    }

    // Generation counter
    {
        const gen_prefix = "gen:";
        var gx: u16 = 16;
        for (gen_prefix) |ch| {
            if (gx >= COLS) break;
            buf.set(gx, status_y, .{ .codepoint = ch, .fg = Color.YELLOW, .bg = GOF_COLOR });
            gx += 1;
        }
        // Write gen number (up to 4 digits)
        var digits: [4]u8 = undefined;
        var g = gen;
        var di: u8 = 3;
        while (true) {
            digits[di] = @intCast(g % 10);
            g /= 10;
            if (di == 0) break;
            di -= 1;
        }
        for (digits) |d| {
            if (gx >= COLS) break;
            buf.set(gx, status_y, .{ .codepoint = '0' + @as(u21, d), .fg = Color.YELLOW, .bg = GOF_COLOR });
            gx += 1;
        }
    }

    // Census
    const census = tgof.census();
    {
        const census_prefix = " E:";
        var cx: u16 = 26;
        for (census_prefix) |ch| {
            if (cx >= COLS) break;
            buf.set(cx, status_y, .{ .codepoint = ch, .fg = Color.GRAY, .bg = GOF_COLOR });
            cx += 1;
        }
        const empty_d: u21 = '0' + @as(u21, @min(census.empty, 9));
        buf.set(cx, status_y, .{ .codepoint = empty_d, .fg = Color.GRAY, .bg = GOF_COLOR });
        cx += 1;

        for (" I:") |ch| {
            if (cx >= COLS) break;
            buf.set(cx, status_y, .{ .codepoint = ch, .fg = Color.GRAY, .bg = GOF_COLOR });
            cx += 1;
        }
        const inf_d: u21 = '0' + @as(u21, @min(census.infected, 9));
        buf.set(cx, status_y, .{ .codepoint = inf_d, .fg = tritColor(.plus), .bg = GOF_COLOR });
        cx += 1;

        for (" R:") |ch| {
            if (cx >= COLS) break;
            buf.set(cx, status_y, .{ .codepoint = ch, .fg = Color.GRAY, .bg = GOF_COLOR });
            cx += 1;
        }
        const rec_d: u21 = '0' + @as(u21, @min(census.recombinant, 9));
        buf.set(cx, status_y, .{ .codepoint = rec_d, .fg = Color{ .tag = .srgb, .payload = 0xFFAA00 }, .bg = GOF_COLOR });
        cx += 1;

        for (" M:") |ch| {
            if (cx >= COLS) break;
            buf.set(cx, status_y, .{ .codepoint = ch, .fg = Color.GRAY, .bg = GOF_COLOR });
            cx += 1;
        }
        const imm_d: u21 = '0' + @as(u21, @min(census.immune, 9));
        buf.set(cx, status_y, .{ .codepoint = imm_d, .fg = Color.WHITE, .bg = GOF_COLOR });
    }

    // Trit balance indicator
    {
        const balance = tgof.tritBalance();
        const balance_char: u21 = switch (balance) {
            .minus => '-',
            .zero => '=',
            .plus => '+',
        };
        const balance_color = tritColor(balance);
        buf.set(COLS - 4, status_y, .{ .codepoint = '[', .fg = Color.WHITE, .bg = GOF_COLOR });
        buf.set(COLS - 3, status_y, .{ .codepoint = balance_char, .fg = balance_color, .bg = GOF_COLOR });
        buf.set(COLS - 2, status_y, .{ .codepoint = ']', .fg = Color.WHITE, .bg = GOF_COLOR });
    }
}

// ===========================================================================
// Main: one-shot rapid display
// ===========================================================================

pub fn main() !void {
    const stdout_file = std.fs.File.stdout();
    var fmt_buf: [256]u8 = undefined;

    // Hide cursor + clear screen
    try stdout_file.writeAll("\x1b[?25l\x1b[2J\x1b[H");

    // Initialize tileable GOF
    var tgof = tileable_gof.TileableGof.init(COLS, ROWS - 1, 4, 3); // 4x3 tile grid

    // Patient zero: create a virion and infect the focused tile
    var patient_zero = virion.Virion{};
    patient_zero.trit_role = .plus; // generator
    patient_zero.trit_mode = .zero; // coordinator
    patient_zero.trit_polarity = .minus; // balance: +1 + 0 + (-1) = 0
    _ = tgof.infectFocused(patient_zero);

    // Create retty buffer
    var buf = Buffer.init(.{ .x = 0, .y = 0, .width = COLS, .height = ROWS });
    var backend = AnsiBackend.init(COLS, ROWS);

    // Render initial frame
    renderFrame(&tgof, &buf, 0);
    backend.draw(&buf);

    // Output initial frame
    try stdout_file.writeAll(backend.output());

    // Spread simulation: render each generation
    var gen: u32 = 0;
    while (gen < 20) : (gen += 1) {
        // Sleep 100ms between frames
        std.Thread.sleep(100 * std.time.ns_per_ms);

        // One tick of epidemic spread
        const new_infections = tgof.tick();

        // Vaccinate the focused tile every 5 generations (firewall)
        if (gen % 5 == 4) {
            tgof.vaccinateTile(tgof.focused_tile);
            tgof.focusNext();
        }

        // Move focus periodically
        if (gen % 3 == 0) {
            tgof.focusNext();
        }

        // Render
        var prev_buf = buf;
        renderFrame(&tgof, &buf, gen + 1);
        backend.drawDiff(&buf, &prev_buf);

        // Home cursor + output diff
        try stdout_file.writeAll("\x1b[H");
        try stdout_file.writeAll(backend.output());

        // Stop if no new infections and we've done at least 5 generations
        if (new_infections == 0 and gen >= 5) break;
    }

    // Final census
    const final_census = tgof.census();
    try stdout_file.writeAll(try std.fmt.bufPrint(&fmt_buf, "\n\x1b[{d};1H", .{ROWS + 1}));
    try stdout_file.writeAll("\x1b[0m\n  Gain-of-Function Simulation Complete\n");
    try stdout_file.writeAll(try std.fmt.bufPrint(&fmt_buf, "  Generations: {d}  Empty: {d}  Infected: {d}  Recombinant: {d}  Immune: {d}\n", .{
        tgof.generation,
        final_census.empty,
        final_census.infected,
        final_census.recombinant,
        final_census.immune,
    }));
    try stdout_file.writeAll(try std.fmt.bufPrint(&fmt_buf, "  Max Gen: {d}  Max Caps: {d}  Total Caps: {d}\n", .{
        final_census.max_generation,
        final_census.max_caps,
        final_census.total_caps,
    }));

    // Validate GOF color via libghostty-vt FFI
    const gof_rgb = ghosttyColorRgb(0x56, 0x45, 0x16);
    const cjk_w = ghosttyCodepointWidth(0x4E2D);
    try stdout_file.writeAll(try std.fmt.bufPrint(&fmt_buf, "  libghostty-vt: GOF=#{x:0>2}{x:0>2}{x:0>2}  CJK-width={d}\n", .{
        gof_rgb[0], gof_rgb[1], gof_rgb[2], cjk_w,
    }));

    // Show cursor
    try stdout_file.writeAll("\x1b[?25h");
}

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;

test "GOF color is correct" {
    try testing.expectEqual(@as(u24, 0x564516), GOF_COLOR.payload);
}

test "trit colors distinct" {
    const minus_c = tritColor(.minus);
    const zero_c = tritColor(.zero);
    const plus_c = tritColor(.plus);
    try testing.expect(minus_c.payload != zero_c.payload);
    try testing.expect(zero_c.payload != plus_c.payload);
}

test "infection colors distinct" {
    const empty = infectionColor(0);
    const infected = infectionColor(1);
    const recomb = infectionColor(2);
    const immune = infectionColor(3);
    try testing.expect(empty.payload != infected.payload);
    try testing.expect(infected.payload != recomb.payload);
    try testing.expect(recomb.payload != immune.payload);
}

test "render frame produces output" {
    var tgof = tileable_gof.TileableGof.init(40, 12, 4, 3);
    _ = tgof.infectFocused(.{});
    var buf_test = Buffer.init(.{ .x = 0, .y = 0, .width = 40, .height = 12 });
    renderFrame(&tgof, &buf_test, 0);

    // Should have some non-default cells
    var non_default: u32 = 0;
    var y: u16 = 0;
    while (y < 12) : (y += 1) {
        var x: u16 = 0;
        while (x < 40) : (x += 1) {
            const c = buf_test.get(x, y);
            if (c.codepoint != ' ' and c.codepoint != 0) non_default += 1;
        }
    }
    try testing.expect(non_default > 10);
}

test "ghostty FFI color rgb extraction" {
    // Test GOF color #564516 via libghostty-vt
    const rgb = ghosttyColorRgb(0x56, 0x45, 0x16);
    try testing.expectEqual(@as(u8, 0x56), rgb[0]);
    try testing.expectEqual(@as(u8, 0x45), rgb[1]);
    try testing.expectEqual(@as(u8, 0x16), rgb[2]);
}

test "ghostty FFI codepoint width" {
    // ASCII 'A' should have width 1
    try testing.expectEqual(@as(i8, 1), ghosttyCodepointWidth('A'));
    // Box-drawing ╭ should have width 1
    try testing.expectEqual(@as(i8, 1), ghosttyCodepointWidth(0x256D));
    // CJK character should have width 2
    try testing.expectEqual(@as(i8, 2), ghosttyCodepointWidth(0x4E2D)); // 中
}

