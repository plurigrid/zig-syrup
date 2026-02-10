//! ZOAD — Zig Agent Desktop (pixel-perfect TOAD replica)
//!
//! Architecture: retty constraint layout + ACP/Syrup transport + notcurses backend
//! The key insight from zeta: worlds are spectral dashboards over evolving graphs.
//! In zoad, the "graph" is the agent interaction graph (sessions × tools × messages).
//!
//! Layout (matching toad.tcss exactly via retty constraints):
//!   ┌──────────────────────────────────────────────────────────────────┐
//!   │ Throbber: gradient ━━━ bar (retty.Gauge, height=1)              │
//!   ├──────────┬───────────────────────────────────────────────────────┤
//!   │ Sidebar  │ Conversation (retty.Block + message stream)          │
//!   │ w=40     │ ┌─┬────────────────────────────────────────────────┐ │
//!   │ max=45%  │ │▌│ ❯ UserInput  (bg: $secondary 15%)             │ │
//!   │          │ │ │   AgentResponse (markdown stream)              │ │
//!   │ ▼ Plan   │ │ │   AgentThought (bg: $primary-muted 20%)      │ │
//!   │  [H] ... │ │ │   ▼🔧 ToolCall [status]                      │ │
//!   │  [M] ... │ │ │   $ ShellResult (bg: $fg 4%)                 │ │
//!   │          │ │ │   ╭─TerminalOutput─╮                          │ │
//!   │ ▼ Proj   │ └─┴────────────────────────────────────────────────┘ │
//!   │  ├ src/  │                                                      │
//!   ├──────────┴───────────────────────────────────────────────────────┤
//!   │ ┃ Prompt input...                                       cursor┃ │
//!   │ AgentInfo │ WorkDir              StatusLine │ ModeInfo          │
//!   ├──────────────────────────────────────────────────────────────────┤
//!   │ ctrl+q quit  f1 help  ctrl+b sidebar  @ files  / cmds         │
//!   └──────────────────────────────────────────────────────────────────┘
//!
//! GF(3) trit: zeta (-1 validator, spectral) ⊗ zoad (0 coordinator, TUI) ⊗ acp (+1 generator, protocol) = 0

const std = @import("std");
const retty = @import("retty");
const terminal = @import("terminal");
const acp = @import("acp");
const nc_backend = @import("notcurses_backend");
const simple_tcp = @import("simple_tcp");
const syrup = @import("syrup");
const zeta_widget = @import("zeta_widget.zig");
const tape_recorder = @import("tape_recorder");
const damage = @import("damage");

const posix = std.posix;

// ============================================================================
// Dracula Theme (from TOAD app.py, mapped to retty.Color)
// ============================================================================

const Dracula = struct {
    const bg = retty.Color.rgb(40, 42, 54); // #282A36
    const fg = retty.Color.rgb(248, 248, 242); // #F8F8F2
    const current_line = retty.Color.rgb(68, 71, 90); // #44475A
    const comment = retty.Color.rgb(98, 114, 164); // #6272A4
    const cyan = retty.Color.rgb(139, 233, 253); // #8BE9FD  ($secondary)
    const green = retty.Color.rgb(80, 250, 123); // #50FA7B
    const orange = retty.Color.rgb(255, 184, 108); // #FFB86C
    const pink = retty.Color.rgb(255, 121, 198); // #FF79C6
    const purple = retty.Color.rgb(189, 147, 249); // #BD93F9  ($primary)
    const red = retty.Color.rgb(255, 85, 85); // #FF5555
    const yellow = retty.Color.rgb(241, 250, 140); // #F1FA8C
};

// Semantic tokens
const primary = Dracula.purple;
const secondary = Dracula.cyan;
const text_muted = Dracula.comment;
const text_success = Dracula.green;
const text_error = Dracula.red;

// ============================================================================
// Message types (matching TOAD's conversation.py widget kinds)
// ============================================================================

const MessageKind = enum {
    user_input, // ❯ prefix, bg secondary 15%
    agent_response, // plain markdown
    agent_thought, // bg primary-muted 20%, collapsible
    tool_call, // ▼🔧 title [status]
    shell_result, // $ prefix, bg foreground 4%
    terminal_output, // panel border
    system, // system messages (connect, etc.)
};

const Message = struct {
    kind: MessageKind,
    content: []const u8,
    tool_title: []const u8 = "",
    tool_status: []const u8 = "", // "pending"|"completed"|"failed"
    expanded: bool = false,
};

// ============================================================================
// Layout Constants (from toad.tcss)
// ============================================================================

const SIDEBAR_WIDTH: u16 = 40;
const SIDEBAR_MAX_PCT: u16 = 45;
const THROBBER_HEIGHT: u16 = 2;
const FOOTER_HEIGHT: u16 = 1;
const PROMPT_HEIGHT: u16 = 2; // input + info bar
const THOUGHT_MAX_LINES: u16 = 10;

// Unicode chars (from TOAD)
const PROMPT_USER = "\xE2\x9D\xAF"; // ❯ U+276F
const PROMPT_SHELL = "$";
const CURSOR_CHAR = "\xE2\x96\x8C"; // ▌ U+258C
const THROBBER_CHAR = "\xE2\x94\x81"; // ━ U+2501
const EXPAND_CHAR = "\xE2\x96\xBC"; // ▼ U+25BC
const COLLAPSE_CHAR = "\xE2\x96\xB6"; // ▶ U+25B6
const TOOL_ICON = "\xF0\x9F\x94\xA7"; // 🔧
const CHECK_MARK = "\xE2\x9C\x94"; // ✔ U+2714
const TIMER = "\xE2\x8F\xB2"; // ⏲ U+23F2

// ============================================================================
// App State (TOAD-equivalent MainScreen)
// ============================================================================

const AppState = struct {
    should_quit: bool = false,
    messages: std.ArrayListUnmanaged(Message),
    input_buffer: std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    conn: ?simple_tcp.Connection = null,

    // Layout state
    sidebar_visible: bool = true,
    throbber_busy: bool = false,
    throbber_offset: u16 = 0,
    cursor_pos: usize = 0,
    scroll_offset: u16 = 0,

    zeta: zeta_widget.ZetaWidget,

    // Tape recording (damage → boxxy tapes/)
    tape: tape_recorder.VhsWriter,
    tape_bridge: tape_recorder.DamageTapeBridge,
    damage_tracker: damage.DamageTracker,
    recording: bool = false,

    // Agent info (TOAD info bar)
    agent_name: []const u8 = "Claude Code",
    working_dir: []const u8 = ".",
    mode_name: []const u8 = "",
    status_text: []const u8 = "",

    // Plan entries (sidebar)
    plan_entries: std.ArrayListUnmanaged(PlanEntry),

    // Session
    session_id: ?[]const u8 = null,

    // Transport
    agent_host: []const u8 = "127.0.0.1",
    agent_port: u16 = 5555,

    const PlanEntry = struct {
        content: []const u8,
        priority: u8, // 'H', 'M', 'L'
        completed: bool,
    };

    pub fn init(allocator: std.mem.Allocator) AppState {
        var tape = tape_recorder.VhsWriter.init(allocator, .{
            .title = "zoad session",
            .output_gif = "tapes/zoad-session.gif",
            .output_mp4 = "tapes/zoad-session.mp4",
            .theme = "Catppuccin Mocha",
        });
        return .{
            .messages = .{},
            .input_buffer = .{},
            .plan_entries = .{},
            .allocator = allocator,
            .zeta = zeta_widget.ZetaWidget.init(allocator),
            .tape = tape,
            .tape_bridge = tape_recorder.DamageTapeBridge.init(&tape),
            .damage_tracker = damage.DamageTracker.init(allocator),
        };
    }

    pub fn deinit(self: *AppState) void {
        self.damage_tracker.deinit();
        self.tape.deinit();
        self.zeta.deinit();
        if (self.conn) |*c| c.close();
        for (self.messages.items) |msg| {
            self.allocator.free(msg.content);
        }
        self.messages.deinit(self.allocator);
        self.input_buffer.deinit(self.allocator);
        self.plan_entries.deinit(self.allocator);
    }

    pub fn addMessage(self: *AppState, kind: MessageKind, content: []const u8) !void {
        try self.messages.append(self.allocator, .{
            .kind = kind,
            .content = try self.allocator.dupe(u8, content),
        });
    }

    pub fn addToolCall(self: *AppState, title: []const u8, status: []const u8) !void {
        try self.messages.append(self.allocator, .{
            .kind = .tool_call,
            .content = "",
            .tool_title = try self.allocator.dupe(u8, title),
            .tool_status = try self.allocator.dupe(u8, status),
        });
    }

    pub fn connectToAgent(self: *AppState) !void {
        self.conn = try simple_tcp.Connection.connect(self.allocator, self.agent_host, self.agent_port);
        try self.addMessage(.system, "Connected to agent at 127.0.0.1:5555");

        const init_msg = acp.Message{
            .initialize = .{
                .protocol_version = 1,
                .client_capabilities = .{ .fs = null, .terminal = true },
                .client_info = .{ .name = "zoad", .version = "0.2.0" },
            },
        };
        const syrup_val = try init_msg.toSyrup(self.allocator);
        var buf: [1024]u8 = undefined;
        const encoded = try syrup_val.encodeBuf(&buf);
        try self.conn.?.stream.writeAll(encoded);
        try self.addMessage(.system, "Sent ACP Initialize (Syrup-encoded)");
    }

    fn sidebarWidth(self: *const AppState, screen_width: u16) u16 {
        if (!self.sidebar_visible) return 0;
        const max = screen_width * SIDEBAR_MAX_PCT / 100;
        return @min(SIDEBAR_WIDTH, max);
    }
};

// ============================================================================
// Rendering (retty widget composition, guided by zeta's dashboard pattern)
// ============================================================================

fn renderThrobber(buf: *retty.Buffer, area: retty.Rect, offset: u16, busy: bool) void {
    if (!busy) return;
    // Animated gradient bar using ━ chars (13-color purple↔cyan)
    // Same pattern as zeta's EntropyDashboard gauge but as raw cells
    const gradient = [13]retty.Color{
        Dracula.purple, retty.Color.rgb(172, 157, 251),
        retty.Color.rgb(155, 167, 253), retty.Color.rgb(139, 177, 253),
        retty.Color.rgb(139, 195, 253), retty.Color.rgb(139, 213, 253),
        Dracula.cyan, retty.Color.rgb(139, 213, 253),
        retty.Color.rgb(139, 195, 253), retty.Color.rgb(139, 177, 253),
        retty.Color.rgb(155, 167, 253), retty.Color.rgb(172, 157, 251),
        Dracula.purple,
    };

    var col: u16 = 0;
    while (col < area.width) : (col += 1) {
        const idx = (col +% offset) % 13;
        buf.set(area.x + col, area.y, .{
            .codepoint = 0x2501, // ━
            .fg = gradient[idx],
            .bg = Dracula.bg,
        });
    }
}

fn renderSidebar(buf: *retty.Buffer, area: retty.Rect, app: *const AppState) void {
    // Border right (tall style)
    var row: u16 = 0;
    while (row < area.height) : (row += 1) {
        buf.set(area.x + area.width -| 1, area.y + row, .{
            .codepoint = 0x2503, // ┃ tall vertical
            .fg = Dracula.current_line,
            .bg = Dracula.bg,
        });
    }

    // "▼ Plan" header
    buf.setString(area.x + 1, area.y, EXPAND_CHAR, retty.Style.fg(secondary));
    buf.setString(area.x + 4, area.y, "Plan", retty.Style.fg(secondary));

    // Plan entries
    var y = area.y + 1;
    for (app.plan_entries.items) |entry| {
        if (y >= area.y + area.height / 2) break;

        // Priority pill
        const pill_color = switch (entry.priority) {
            'H' => text_error,
            'M' => Dracula.yellow,
            else => secondary,
        };
        buf.set(area.x + 2, y, .{ .codepoint = 0x258C, .fg = pill_color, .bg = Dracula.bg }); // ▌
        var pill_buf: [4]u8 = undefined;
        const pill_str = std.fmt.bufPrint(&pill_buf, "[{c}]", .{entry.priority}) catch "[ ]";
        buf.setString(area.x + 4, y, pill_str, retty.Style.fg(pill_color));

        // Content
        const content_style = if (entry.completed)
            retty.Style.fg(text_success)
        else
            retty.Style.fg(Dracula.fg);
        buf.setString(area.x + 8, y, entry.content, content_style);

        y += 1;
    }

    // "▼ Project" header
    buf.setString(area.x + 1, y + 1, EXPAND_CHAR, retty.Style.fg(secondary));
    buf.setString(area.x + 4, y + 1, "Project", retty.Style.fg(secondary));
}

fn renderConversation(buf: *retty.Buffer, area: retty.Rect, app: *const AppState) void {
    // Cursor column (1 char wide, left edge)
    const cursor_x = area.x;
    const content_x = area.x + 2; // 1 for cursor + 1 padding
    const content_w = area.width -| 3; // cursor + padding + right padding

    var y = area.y;

    for (app.messages.items, 0..) |msg, idx| {
        if (y >= area.y + area.height) break;

        // Cursor indicator
        if (idx == app.cursor_pos) {
            buf.set(cursor_x, y, .{
                .codepoint = 0x258C, // ▌
                .fg = secondary,
                .bg = Dracula.bg,
            });
        }

        // Margin top (1 line)
        y += 1;
        if (y >= area.y + area.height) break;

        switch (msg.kind) {
            .user_input => {
                // ❯ prefix + content, bg: secondary 15% (approx: current_line)
                buf.setString(content_x, y, PROMPT_USER, retty.Style.fg(secondary).withBg(Dracula.current_line));
                buf.setString(content_x + 2, y, msg.content, retty.Style.fg(Dracula.fg).withBg(Dracula.current_line));
                // Fill background
                var fill: u16 = @intCast(@min(msg.content.len + 2, content_w));
                while (fill < content_w) : (fill += 1) {
                    buf.set(content_x + fill, y, .{ .codepoint = ' ', .bg = Dracula.current_line });
                }
                y += 1;
            },
            .agent_response => {
                // Plain text, wrapping by line
                var line_start: usize = 0;
                for (msg.content, 0..) |c, i| {
                    if (c == '\n' or i == msg.content.len - 1) {
                        const end = if (c == '\n') i else i + 1;
                        if (end > line_start) {
                            const line = msg.content[line_start..end];
                            const max_len = @min(line.len, @as(usize, content_w));
                            buf.setString(content_x, y, line[0..max_len], retty.Style.fg(Dracula.fg));
                        }
                        y += 1;
                        if (y >= area.y + area.height) break;
                        line_start = i + 1;
                    }
                }
            },
            .agent_thought => {
                // bg: primary-muted 20% (approx: comment bg)
                var lines: u16 = 0;
                var line_start: usize = 0;
                for (msg.content, 0..) |c, i| {
                    if (c == '\n' or i == msg.content.len - 1) {
                        if (lines >= THOUGHT_MAX_LINES) break;
                        const end = if (c == '\n') i else i + 1;
                        if (end > line_start) {
                            const line = msg.content[line_start..end];
                            const max_len = @min(line.len, @as(usize, content_w));
                            buf.setString(content_x + 1, y, line[0..max_len], retty.Style.fg(Dracula.fg).withBg(Dracula.comment));
                        }
                        y += 1;
                        lines += 1;
                        if (y >= area.y + area.height) break;
                        line_start = i + 1;
                    }
                }
            },
            .tool_call => {
                // ▼ 🔧 Title [status]
                buf.setString(content_x, y, EXPAND_CHAR, retty.Style.fg(Dracula.fg));
                buf.setString(content_x + 3, y, TOOL_ICON, retty.Style.fg(Dracula.fg));
                buf.setString(content_x + 6, y, msg.tool_title, retty.Style.fg(Dracula.fg));

                const status_style = if (std.mem.eql(u8, msg.tool_status, "completed"))
                    retty.Style.fg(text_success)
                else if (std.mem.eql(u8, msg.tool_status, "failed"))
                    retty.Style.fg(text_error)
                else
                    retty.Style.fg(text_muted);

                const status_icon = if (std.mem.eql(u8, msg.tool_status, "completed"))
                    CHECK_MARK
                else
                    TIMER;

                const title_end: u16 = @intCast(@min(msg.tool_title.len + 8, content_w -| 2));
                buf.setString(content_x + title_end, y, status_icon, status_style);
                y += 1;
            },
            .shell_result => {
                // $ prefix, bg: foreground 4% (approx: very subtle)
                buf.setString(content_x, y, PROMPT_SHELL, retty.Style.fg(primary));
                buf.setString(content_x + 2, y, msg.content, retty.Style.fg(Dracula.fg));
                y += 1;
            },
            .terminal_output => {
                // Panel border using retty.Block
                var term_block = retty.Block.default()
                    .withBorders(retty.Borders.ALL);
                const term_rect = retty.Rect{
                    .x = content_x,
                    .y = y,
                    .width = content_w,
                    .height = 3, // min height
                };
                term_block.render(term_rect, buf);
                const inner = term_block.innerArea(term_rect);
                buf.setString(inner.x, inner.y, msg.content, retty.Style.fg(Dracula.fg));
                y += 3;
            },
            .system => {
                buf.setString(content_x, y, msg.content, retty.Style.fg(text_muted).italic());
                y += 1;
            },
        }
    }
}

fn renderPrompt(buf: *retty.Buffer, area: retty.Rect, app: *const AppState) void {
    // Input line (row 0 of prompt area)
    // Border left: ┃ (tall, secondary when focused)
    buf.set(area.x, area.y, .{ .codepoint = 0x2503, .fg = secondary, .bg = Dracula.bg });

    // Input text
    const max_input = @min(app.input_buffer.items.len, @as(usize, area.width -| 3));
    if (max_input > 0) {
        buf.setString(area.x + 2, area.y, app.input_buffer.items[0..max_input], retty.Style.fg(Dracula.fg));
    }

    // Cursor (inverse video)
    const cursor_x: u16 = area.x + 2 + @as(u16, @intCast(max_input));
    buf.set(cursor_x, area.y, .{ .codepoint = ' ', .fg = Dracula.bg, .bg = Dracula.fg, .attrs = .{ .inverse = true } });

    // Right border
    buf.set(area.x + area.width -| 1, area.y, .{ .codepoint = 0x2503, .fg = secondary, .bg = Dracula.bg });

    // Info bar (row 1 of prompt area)
    if (area.height >= 2) {
        const info_y = area.y + 1;

        // Agent name (left, bg: primary 10%)
        buf.setString(area.x + 1, info_y, app.agent_name, retty.Style.fg(Dracula.fg).withBg(Dracula.comment));

        // Working dir (after agent name)
        const dir_x = area.x + 1 + @as(u16, @intCast(@min(app.agent_name.len + 2, area.width)));
        buf.setString(dir_x, info_y, app.working_dir, retty.Style.fg(text_muted));

        // Status text (right-aligned)
        if (app.status_text.len > 0) {
            const status_x = area.x + area.width -| @as(u16, @intCast(@min(app.status_text.len + 1, area.width)));
            buf.setString(status_x, info_y, app.status_text, retty.Style.fg(secondary));
        }
    }
}

fn renderFooter(buf: *retty.Buffer, area: retty.Rect) void {
    const bindings = [_]struct { key: []const u8, desc: []const u8 }{
        .{ .key = "ctrl+q", .desc = "quit" },
        .{ .key = "f1", .desc = "help" },
        .{ .key = "ctrl+b", .desc = "sidebar" },
        .{ .key = "esc", .desc = "cancel" },
        .{ .key = "ctrl+o", .desc = "mode" },
        .{ .key = "ctrl+r", .desc = "record" },
        .{ .key = "/", .desc = "cmds" },
    };

    var x = area.x + 1;
    for (bindings) |b| {
        buf.setString(x, area.y, b.key, retty.Style.fg(Dracula.fg).bold());
        x += @intCast(@min(b.key.len + 1, 20));
        buf.setString(x, area.y, b.desc, retty.Style.fg(text_muted));
        x += @intCast(@min(b.desc.len + 2, 20));
    }
}

// ============================================================================
// Input handling (TOAD-equivalent key bindings via notcurses)
// ============================================================================

fn handleInput(app: *AppState, ev: nc_backend.NotcursesBackend.InputEvent) !void {
    const id = ev.id;

    // Ctrl+Q = quit (0x11 = 'q' - 0x60)
    if (ev.modifiers.ctrl and (id == 'q' or id == 'Q')) {
        app.should_quit = true;
        return;
    }

    // Ctrl+B = toggle sidebar
    if (ev.modifiers.ctrl and (id == 'b' or id == 'B')) {
        app.sidebar_visible = !app.sidebar_visible;
        return;
    }

    // Ctrl+R = toggle tape recording
    if (ev.modifiers.ctrl and (id == 'r' or id == 'R')) {
        app.recording = !app.recording;
        if (app.recording) {
            app.tape.recordMarker(.session_start, "recording started") catch {};
            app.addMessage(.system, "Recording started (Ctrl+R to stop)") catch {};
        } else {
            app.tape.recordMarker(.session_end, "recording stopped") catch {};
            // Export VHS tape
            if (app.tape.exportVhs(app.allocator)) |vhs_data| {
                defer app.allocator.free(vhs_data);
                const file = std.fs.cwd().createFile("tapes/zoad-session.tape", .{}) catch null;
                if (file) |f| {
                    defer f.close();
                    f.writeAll(vhs_data) catch {};
                    app.addMessage(.system, "Tape saved: tapes/zoad-session.tape") catch {};
                }
            } else |_| {}
        }
        return;
    }

    // Escape = cancel agent
    if (id == 27) { // ESC
        app.throbber_busy = false;
        return;
    }

    // Enter = submit prompt
    if (id == '\r' or id == '\n' or id == nc_backend.NotcursesBackend.InputEvent.ENTER) {
        if (app.input_buffer.items.len > 0) {
            const text = try app.allocator.dupe(u8, app.input_buffer.items);

            // Check for 'connect' command
            if (std.mem.eql(u8, text, "connect")) {
                app.connectToAgent() catch |err| {
                    var err_buf: [128]u8 = undefined;
                    const err_msg = std.fmt.bufPrint(&err_buf, "Connection failed: {}", .{err}) catch "Connection failed";
                    try app.addMessage(.system, err_msg);
                };
            } else {
                try app.addMessage(.user_input, text);
                // TODO: send to ACP agent if connected
                if (app.conn != null) {
                    app.throbber_busy = true;
                }
            }

            app.input_buffer.clearRetainingCapacity();
        }
        return;
    }

    // Backspace
    if (id == 127 or id == 8 or id == nc_backend.NotcursesBackend.InputEvent.BACKSPACE) {
        if (app.input_buffer.items.len > 0) {
            _ = app.input_buffer.pop();
        }
        return;
    }

    // Printable ASCII
    if (id >= 0x20 and id < 0x7F) {
        try app.input_buffer.append(app.allocator, @intCast(id));
        return;
    }
}

// ============================================================================
// Main — TOAD-equivalent app.run()
// ============================================================================

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var backend = try nc_backend.NotcursesBackend.init();
    defer backend.deinit();

    var app = AppState.init(allocator);
    defer app.deinit();

    // Welcome messages
    try app.addMessage(.agent_response, "Welcome to ZOAD (Zig Agent Desktop) - ACP v1");
    try app.addMessage(.system, "15 agents available. Type 'connect' or select from sidebar.");
    try app.addMessage(.system, "retty layout engine + Syrup transport + notcurses backend");

    while (!app.should_quit) {
        // --- TOAD Layout via retty constraints ---

        const width = backend.width;
        const height = backend.height;
        const screen = retty.Rect{ .x = 0, .y = 0, .width = width, .height = height };

        var buf = retty.Buffer.init(screen);

        // Fill background
        buf.setStyle(screen, retty.Style.bg(Dracula.bg));

        // Vertical split: Throbber/Zeta | Main | Prompt | Footer
        var v_chunks: [4]retty.Rect = undefined;
        retty.Layout.vertical(&.{
            .{ .length = THROBBER_HEIGHT },  // Zeta spectral dashboard
            .{ .min = 0 },                   // Main area (fills)
            .{ .length = PROMPT_HEIGHT },     // Prompt + info bar
            .{ .length = FOOTER_HEIGHT },     // Footer
        }).split(screen, &v_chunks);

        const throbber_area = v_chunks[0];
        const main_area = v_chunks[1];
        const prompt_area = v_chunks[2];
        const footer_area = v_chunks[3];

        // Horizontal split of main: Sidebar | Conversation
        const sw = app.sidebarWidth(main_area.width);
        var h_chunks: [2]retty.Rect = undefined;
        retty.Layout.horizontal(&.{
            .{ .length = sw },               // Sidebar
            .{ .min = 0 },                   // Conversation (fills)
        }).split(main_area, &h_chunks);

        const sidebar_area = h_chunks[0];
        const conv_area = h_chunks[1];

        // Render all regions
        app.zeta.render(&buf, throbber_area);
        if (app.sidebar_visible) renderSidebar(&buf, sidebar_area, &app);
        renderConversation(&buf, conv_area, &app);
        renderPrompt(&buf, prompt_area, &app);
        renderFooter(&buf, footer_area);

        // Show recording + efficiency in status
        if (app.recording) {
            app.status_text = "REC";
        } else {
            var eff_buf: [32]u8 = undefined;
            const eff_pct = backend.efficiency() * 100.0;
            app.status_text = std.fmt.bufPrint(&eff_buf, "{d:.0}% drawn", .{eff_pct}) catch "";
        }

        // Flush (damage-aware: skips unchanged cells)
        backend.draw(&buf);

        // Tick animations
        if (app.throbber_busy) app.throbber_offset +%= 1;
        app.zeta.tick();

        // Input via notcurses (67ms timeout = ~15fps, matching TOAD's 1/15s throbber)
        if (backend.getInput(67)) |ev| {
            if (ev.evtype == .press or ev.evtype == .repeat) {
                // Record keystroke to tape if recording
                if (app.recording) {
                    const mods: u8 = (@as(u8, @intFromBool(ev.modifiers.shift))) |
                        (@as(u8, @intFromBool(ev.modifiers.alt)) << 1) |
                        (@as(u8, @intFromBool(ev.modifiers.ctrl)) << 2);
                    app.tape_bridge.onKeystroke(ev.id, mods) catch {};
                }
                handleInput(&app, ev) catch {};
            }
        }

        // Record damage frame to tape if recording
        if (app.recording) {
            const total = @as(u32, backend.width) * backend.height;
            app.tape_bridge.onFrame(&app.damage_tracker, total) catch {};
        }
    }
}
