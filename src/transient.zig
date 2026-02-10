//! transient.zig — Emacs transient.el popup menus as retty widgets
//!
//! Ports the transient.el UI model (prefix → suffix popup with keybindings)
//! into zig-syrup's retty widget system, compilable to WASM/WebGPU.
//!
//! Architecture:
//!   Emacs transient.el declarative menus
//!     → Zig Transient widget (this file)
//!     → retty Buffer (2D cell grid)
//!     → AnsiBackend (ANSI escape sequences)
//!     → terminal_wasm.zig (WASM export)
//!     → Restty/WebGPU browser rendering
//!
//! Key concepts from transient.el:
//!   - Prefix: entry command that opens the popup (e.g., C-x g for Magit)
//!   - Suffix: action bound to a key within the popup (e.g., 'p' for push)
//!   - Infix: toggle/option that modifies suffix behavior (e.g., --force)
//!   - Group: visual grouping of related suffixes
//!   - Column: layout direction for groups
//!
//! GF(3) integration:
//!   - Suffix keys colored by trit: red(-1), green(0), blue(+1)
//!   - Infix toggles cycle through trit states
//!   - On-chain randomness seeds the initial trit assignment
//!
//! wasm32-freestanding compatible. No allocator in hot path.

const retty = @import("retty");
const Rect = retty.Rect;
const Buffer = retty.Buffer;
const Style = retty.Style;
const Color = retty.Color;
const Block = retty.Block;
const Borders = retty.Borders;
const BorderType = retty.BorderType;
const Line = retty.Line;
const Constraint = retty.Constraint;
const Cell = retty.Cell;
const CellAttrs = retty.CellAttrs;

// ============================================================================
// On-chain randomness seed (pluggable)
// ============================================================================

/// Randomness source tag — which on-chain RNG produced this seed
pub const RandomnessSource = enum(u8) {
    /// No randomness (deterministic from static seed)
    none = 0,
    /// Aptos native randomness (aptos_framework::randomness)
    aptos_vrf = 1,
    /// drand distributed beacon (League of Entropy)
    drand = 2,
    /// SplitMix64 bijection (Gay.jl / fountain.zig)
    splitmix = 3,
    /// ChaCha8 CSPRNG (passport.gay identity proofs)
    chacha = 4,
    /// Rybka minimax evaluation (splitmix_trit.zig)
    rybka = 5,
    /// EEG entropy (bci_homotopy.zig)
    eeg = 6,
};

/// On-chain randomness seed with provenance
pub const RandomnessSeed = struct {
    /// The seed value (256-bit, enough for any RNG)
    value: [32]u8 = [_]u8{0} ** 32,
    /// Which source produced this seed
    source: RandomnessSource = .none,
    /// Block height / round number (Aptos) or drand round
    round: u64 = 0,
    /// Epoch (Aptos epoch or drand epoch)
    epoch: u64 = 0,

    /// Initialize from a u64 (SplitMix64 / ChaCha / Rybka)
    pub fn fromU64(val: u64, source: RandomnessSource) RandomnessSeed {
        var seed = RandomnessSeed{ .source = source };
        seed.value[0] = @truncate(val);
        seed.value[1] = @truncate(val >> 8);
        seed.value[2] = @truncate(val >> 16);
        seed.value[3] = @truncate(val >> 24);
        seed.value[4] = @truncate(val >> 32);
        seed.value[5] = @truncate(val >> 40);
        seed.value[6] = @truncate(val >> 48);
        seed.value[7] = @truncate(val >> 56);
        return seed;
    }

    /// Extract first 8 bytes as u64
    pub fn toU64(self: *const RandomnessSeed) u64 {
        var val: u64 = 0;
        inline for (0..8) |i| {
            val |= @as(u64, self.value[i]) << @intCast(i * 8);
        }
        return val;
    }

    /// Extract a trit from byte at position
    pub fn tritAt(self: *const RandomnessSeed, index: usize) Trit {
        const byte = self.value[index % 32];
        return switch (byte % 3) {
            0 => .minus,
            1 => .ergodic,
            2 => .plus,
            else => unreachable,
        };
    }
};

// ============================================================================
// GF(3) Trit (local copy, no cross-module dep in freestanding)
// ============================================================================

pub const Trit = enum(i8) {
    minus = -1,
    ergodic = 0,
    plus = 1,

    pub fn color(self: Trit) Color {
        return switch (self) {
            .minus => Color.red,
            .ergodic => Color.green,
            .plus => Color.blue,
        };
    }

    pub fn label(self: Trit) []const u8 {
        return switch (self) {
            .minus => "[-]",
            .ergodic => "[=]",
            .plus => "[+]",
        };
    }

    pub fn cycle(self: Trit) Trit {
        return switch (self) {
            .minus => .ergodic,
            .ergodic => .plus,
            .plus => .minus,
        };
    }
};

// ============================================================================
// Suffix — a keybinding action in the transient popup
// ============================================================================

pub const MAX_SUFFIXES: usize = 64;
pub const MAX_GROUPS: usize = 8;
pub const MAX_INFIXES: usize = 16;
pub const MAX_COLUMNS: usize = 4;

pub const Suffix = struct {
    /// Key binding (single char)
    key: u8,
    /// Description shown next to key
    description: []const u8 = "",
    /// GF(3) trit coloring
    trit: Trit = .ergodic,
    /// Whether this suffix is currently enabled
    enabled: bool = true,
    /// Action ID (for dispatch in event handler)
    action_id: u16 = 0,

    /// Format: "k  description" with trit-colored key
    fn keyWidth(_: Suffix) u16 {
        return 1; // single char key
    }
};

// ============================================================================
// Infix — a toggle/option that modifies suffix behavior
// ============================================================================

pub const InfixKind = enum {
    /// Boolean toggle: on/off
    toggle,
    /// Trit cycle: -1 → 0 → +1 → -1
    trit_cycle,
    /// Value: numeric input
    value,
};

pub const Infix = struct {
    /// Key binding (single char)
    key: u8,
    /// Flag name (e.g., "--force", "--verbose")
    flag: []const u8 = "",
    /// Description
    description: []const u8 = "",
    /// Kind of infix
    kind: InfixKind = .toggle,
    /// Current state
    active: bool = false,
    /// Current trit (for trit_cycle kind)
    trit_state: Trit = .ergodic,
    /// Current numeric value (for value kind)
    num_value: i32 = 0,
};

// ============================================================================
// Group — visual grouping of suffixes
// ============================================================================

pub const Group = struct {
    /// Group title (e.g., "Push", "Pull", "Branch")
    title: []const u8 = "",
    /// Style for the group title
    title_style: Style = Style.fg(Color.yellow).bold(),
    /// Suffixes in this group
    suffixes: []const Suffix = &[_]Suffix{},
    /// Infixes (toggles) in this group
    infixes: []const Infix = &[_]Infix{},
};

// ============================================================================
// Transient — the main popup widget
// ============================================================================

pub const Transient = struct {
    /// Prefix name (shown in title bar)
    name: []const u8 = "Transient",
    /// Groups arranged in the popup
    groups: []const Group = &[_]Group{},
    /// Number of columns for layout
    columns: u16 = 1,
    /// Border style
    border_type: BorderType = .rounded,
    /// Randomness seed for trit coloring
    seed: RandomnessSeed = .{},
    /// Whether the transient is currently active (visible)
    active: bool = true,
    /// Currently highlighted suffix index (for keyboard nav)
    selected: ?usize = null,
    /// Selection within selected group
    selected_suffix: ?usize = null,

    // ---- Static buffers for rendering (no allocator) ----
    /// Column rects (computed during render)
    col_rects: [MAX_COLUMNS]Rect = [_]Rect{.{}} ** MAX_COLUMNS,

    pub fn new(name: []const u8) Transient {
        return .{ .name = name };
    }

    pub fn withGroups(self: Transient, groups: []const Group) Transient {
        var t = self;
        t.groups = groups;
        return t;
    }

    pub fn withColumns(self: Transient, columns: u16) Transient {
        var t = self;
        t.columns = @max(1, @min(columns, MAX_COLUMNS));
        return t;
    }

    pub fn withBorderType(self: Transient, border_type: BorderType) Transient {
        var t = self;
        t.border_type = border_type;
        return t;
    }

    pub fn withSeed(self: Transient, seed_val: RandomnessSeed) Transient {
        var t = self;
        t.seed = seed_val;
        return t;
    }

    // ---- Event handling ----

    /// Handle a key press. Returns the action_id of the triggered suffix, or null.
    pub fn handleKey(self: *Transient, key: u8) ?u16 {
        // Check infixes first (toggles)
        for (self.groups) |group| {
            for (group.infixes) |*infix_const| {
                // Can't mutate const infixes directly in transient popup
                // Caller should handle infix toggling via action dispatch
                _ = infix_const;
            }
        }

        // Check suffixes
        for (self.groups) |group| {
            for (group.suffixes) |suffix| {
                if (suffix.key == key and suffix.enabled) {
                    return suffix.action_id;
                }
            }
        }

        // Navigation keys
        switch (key) {
            'q', 27 => { // q or ESC
                self.active = false;
                return null;
            },
            'j' => { // down
                self.moveSelection(1);
                return null;
            },
            'k' => { // up
                self.moveSelection(-1);
                return null;
            },
            else => return null,
        }
    }

    fn moveSelection(self: *Transient, delta: i32) void {
        const total = self.totalSuffixes();
        if (total == 0) return;

        if (self.selected) |sel| {
            const next_sel = @as(i32, @intCast(sel)) + delta;
            if (next_sel < 0) {
                self.selected = total - 1;
            } else if (next_sel >= @as(i32, @intCast(total))) {
                self.selected = 0;
            } else {
                self.selected = @intCast(next_sel);
            }
        } else {
            self.selected = 0;
        }
    }

    fn totalSuffixes(self: *const Transient) usize {
        var count: usize = 0;
        for (self.groups) |group| {
            count += group.suffixes.len;
        }
        return count;
    }

    // ---- Rendering (Widget interface) ----

    pub fn render(self: Transient, area: Rect, buf: *Buffer) void {
        if (!self.active or area.isEmpty()) return;

        // Draw outer block with title
        const block = Block.default()
            .withTitle(self.name)
            .withBorders(Borders.ALL)
            .withBorderType(self.border_type)
            .withBorderStyle(Style.fg(Color.cyan))
            .withTitleStyle(Style.fg(Color.magenta).bold());

        block.render(area, buf);
        const inner = block.innerArea(area);
        if (inner.isEmpty()) return;

        // Single-column layout: render groups top-to-bottom
        var y = inner.y;
        var global_suffix_idx: usize = 0;

        for (self.groups) |group| {
            if (y >= inner.bottom()) break;

            // Group title
            if (group.title.len > 0) {
                renderGroupTitle(buf, inner.x, y, inner.width, group.title, group.title_style);
                y += 1;
            }

            // Infixes (toggles)
            for (group.infixes) |infix| {
                if (y >= inner.bottom()) break;
                renderInfix(buf, inner.x, y, inner.width, infix);
                y += 1;
            }

            // Suffixes (actions)
            for (group.suffixes) |suffix| {
                if (y >= inner.bottom()) break;
                const is_selected = self.selected != null and self.selected.? == global_suffix_idx;
                renderSuffix(buf, inner.x, y, inner.width, suffix, is_selected, self.seed, global_suffix_idx);
                y += 1;
                global_suffix_idx += 1;
            }

            // Separator line between groups
            if (y < inner.bottom()) {
                y += 1; // blank line
            }
        }

        // Footer: randomness source indicator
        if (y < inner.bottom()) {
            renderRandomnessFooter(buf, inner.x, inner.bottom() -| 1, inner.width, self.seed);
        }
    }
};

// ============================================================================
// Rendering helpers
// ============================================================================

fn renderGroupTitle(buf: *Buffer, x: u16, y: u16, width: u16, title: []const u8, style: Style) void {
    // Render title with underline-style separator
    var col = x;
    for (title) |ch| {
        if (col >= x + width) break;
        buf.set(col, y, style.applyToCell(.{ .codepoint = ch }));
        col += 1;
    }
    // Fill rest with horizontal line
    while (col < x + width) : (col += 1) {
        buf.set(col, y, Style.fg(Color.dark_gray).applyToCell(.{ .codepoint = 0x2500 })); // ─
    }
}

fn renderSuffix(
    buf: *Buffer,
    x: u16,
    y: u16,
    width: u16,
    suffix: Suffix,
    is_selected: bool,
    seed: RandomnessSeed,
    idx: usize,
) void {
    var col = x;

    // Determine trit color (from seed if available, else from suffix)
    const trit = if (seed.source != .none)
        seed.tritAt(idx)
    else
        suffix.trit;

    const key_style = if (is_selected)
        Style.fg(Color.black).inverse().bold()
    else if (!suffix.enabled)
        Style.fg(Color.dark_gray).dim()
    else
        Style.fg(trit.color()).bold();

    // Key character
    if (col < x + width) {
        buf.set(col, y, key_style.applyToCell(.{ .codepoint = suffix.key }));
        col += 1;
    }

    // Space
    if (col < x + width) {
        buf.set(col, y, .{ .codepoint = ' ' });
        col += 1;
    }

    // Trit indicator
    const trit_label = trit.label();
    for (trit_label) |ch| {
        if (col >= x + width) break;
        buf.set(col, y, Style.fg(trit.color()).applyToCell(.{ .codepoint = ch }));
        col += 1;
    }

    // Space
    if (col < x + width) {
        buf.set(col, y, .{ .codepoint = ' ' });
        col += 1;
    }

    // Description
    const desc_style: Style = if (is_selected)
        Style.fg(Color.white).bold()
    else if (!suffix.enabled)
        Style.fg(Color.dark_gray)
    else
        Style.fg(Color.white);

    for (suffix.description) |ch| {
        if (col >= x + width) break;
        buf.set(col, y, desc_style.applyToCell(.{ .codepoint = ch }));
        col += 1;
    }

    // Fill rest with selection highlight if selected
    if (is_selected) {
        while (col < x + width) : (col += 1) {
            buf.set(col, y, Style.fg(Color.dark_gray).applyToCell(.{ .codepoint = ' ' }));
        }
    }
}

fn renderInfix(buf: *Buffer, x: u16, y: u16, width: u16, infix: Infix) void {
    var col = x;

    // Key
    const key_style = Style.fg(Color.yellow).bold();
    if (col < x + width) {
        buf.set(col, y, key_style.applyToCell(.{ .codepoint = infix.key }));
        col += 1;
    }

    // Space
    if (col < x + width) {
        buf.set(col, y, .{ .codepoint = ' ' });
        col += 1;
    }

    // State indicator
    switch (infix.kind) {
        .toggle => {
            const indicator: u21 = if (infix.active) 0x25C9 else 0x25CB; // ◉ or ○
            const ind_style = if (infix.active)
                Style.fg(Color.green)
            else
                Style.fg(Color.dark_gray);
            if (col < x + width) {
                buf.set(col, y, ind_style.applyToCell(.{ .codepoint = indicator }));
                col += 1;
            }
        },
        .trit_cycle => {
            const trit_label = infix.trit_state.label();
            for (trit_label) |ch| {
                if (col >= x + width) break;
                buf.set(col, y, Style.fg(infix.trit_state.color()).applyToCell(.{ .codepoint = ch }));
                col += 1;
            }
        },
        .value => {
            // Render numeric value as string
            const digits = "0123456789";
            var val = @as(u32, @intCast(if (infix.num_value < 0) -infix.num_value else infix.num_value));
            var num_buf: [10]u8 = undefined;
            var num_len: usize = 0;
            if (val == 0) {
                num_buf[0] = '0';
                num_len = 1;
            } else {
                while (val > 0 and num_len < 10) {
                    num_buf[num_len] = digits[val % 10];
                    val /= 10;
                    num_len += 1;
                }
            }
            if (infix.num_value < 0 and col < x + width) {
                buf.set(col, y, Style.fg(Color.red).applyToCell(.{ .codepoint = '-' }));
                col += 1;
            }
            // Reverse digits
            var di: usize = num_len;
            while (di > 0) {
                di -= 1;
                if (col >= x + width) break;
                buf.set(col, y, Style.fg(Color.cyan).applyToCell(.{ .codepoint = num_buf[di] }));
                col += 1;
            }
        },
    }

    // Space
    if (col < x + width) {
        buf.set(col, y, .{ .codepoint = ' ' });
        col += 1;
    }

    // Flag name
    for (infix.flag) |ch| {
        if (col >= x + width) break;
        buf.set(col, y, Style.fg(Color.yellow).applyToCell(.{ .codepoint = ch }));
        col += 1;
    }

    // Space + description
    if (infix.description.len > 0) {
        if (col < x + width) {
            buf.set(col, y, .{ .codepoint = ' ' });
            col += 1;
        }
        for (infix.description) |ch| {
            if (col >= x + width) break;
            buf.set(col, y, Style.fg(Color.gray).applyToCell(.{ .codepoint = ch }));
            col += 1;
        }
    }
}

fn renderRandomnessFooter(buf: *Buffer, x: u16, y: u16, width: u16, seed: RandomnessSeed) void {
    var col = x;
    const source_name: []const u8 = switch (seed.source) {
        .none => "deterministic",
        .aptos_vrf => "aptos:vrf",
        .drand => "drand",
        .splitmix => "splitmix64",
        .chacha => "chacha8",
        .rybka => "rybka",
        .eeg => "eeg:entropy",
    };

    // "RNG: <source> round:<n>"
    const prefix = "RNG:";
    for (prefix) |ch| {
        if (col >= x + width) break;
        buf.set(col, y, Style.fg(Color.dark_gray).applyToCell(.{ .codepoint = ch }));
        col += 1;
    }
    for (source_name) |ch| {
        if (col >= x + width) break;
        buf.set(col, y, Style.fg(Color.cyan).dim().applyToCell(.{ .codepoint = ch }));
        col += 1;
    }
}

// ============================================================================
// Predefined transient templates (Emacs-compatible patterns)
// ============================================================================

/// Git operations transient (Magit-style)
pub fn gitTransient() Transient {
    return Transient.new("Git")
        .withGroups(&[_]Group{
        .{
            .title = "Fetch",
            .suffixes = &[_]Suffix{
                .{ .key = 'f', .description = "fetch", .trit = .ergodic, .action_id = 1 },
                .{ .key = 'F', .description = "fetch all", .trit = .ergodic, .action_id = 2 },
            },
        },
        .{
            .title = "Push/Pull",
            .infixes = &[_]Infix{
                .{ .key = '-', .flag = "--force", .kind = .toggle, .description = "force push" },
                .{ .key = '=', .flag = "--rebase", .kind = .toggle, .description = "rebase on pull" },
            },
            .suffixes = &[_]Suffix{
                .{ .key = 'p', .description = "push", .trit = .plus, .action_id = 10 },
                .{ .key = 'P', .description = "pull", .trit = .minus, .action_id = 11 },
                .{ .key = 'u', .description = "push upstream", .trit = .plus, .action_id = 12 },
            },
        },
        .{
            .title = "Branch",
            .suffixes = &[_]Suffix{
                .{ .key = 'b', .description = "checkout", .trit = .ergodic, .action_id = 20 },
                .{ .key = 'B', .description = "new branch", .trit = .plus, .action_id = 21 },
                .{ .key = 'd', .description = "delete branch", .trit = .minus, .action_id = 22 },
            },
        },
        .{
            .title = "Commit",
            .infixes = &[_]Infix{
                .{ .key = 'a', .flag = "--amend", .kind = .toggle, .description = "amend previous" },
            },
            .suffixes = &[_]Suffix{
                .{ .key = 'c', .description = "commit", .trit = .plus, .action_id = 30 },
                .{ .key = 's', .description = "stage", .trit = .ergodic, .action_id = 31 },
                .{ .key = 'S', .description = "stage all", .trit = .ergodic, .action_id = 32 },
            },
        },
    })
        .withBorderType(.rounded);
}

/// GF(3) operations transient (triadic balance)
pub fn gf3Transient() Transient {
    return Transient.new("GF(3) Triadic Balance")
        .withGroups(&[_]Group{
        .{
            .title = "Generators (+1)",
            .title_style = Style.fg(Color.blue).bold(),
            .suffixes = &[_]Suffix{
                .{ .key = 'g', .description = "generate color", .trit = .plus, .action_id = 100 },
                .{ .key = 'G', .description = "generate theme", .trit = .plus, .action_id = 101 },
                .{ .key = 't', .description = "generate trit batch", .trit = .plus, .action_id = 102 },
            },
        },
        .{
            .title = "Coordinators (0)",
            .title_style = Style.fg(Color.green).bold(),
            .suffixes = &[_]Suffix{
                .{ .key = 'm', .description = "mix colors", .trit = .ergodic, .action_id = 110 },
                .{ .key = 'b', .description = "balance trits", .trit = .ergodic, .action_id = 111 },
                .{ .key = 'q', .description = "query conservation", .trit = .ergodic, .action_id = 112 },
            },
        },
        .{
            .title = "Validators (-1)",
            .title_style = Style.fg(Color.red).bold(),
            .suffixes = &[_]Suffix{
                .{ .key = 'v', .description = "verify GF(3) sum", .trit = .minus, .action_id = 120 },
                .{ .key = 'V', .description = "verify on-chain", .trit = .minus, .action_id = 121 },
                .{ .key = 'c', .description = "check conservation", .trit = .minus, .action_id = 122 },
            },
        },
    })
        .withBorderType(.double);
}

/// Betting/market transient ($REGRET / $GAY)
pub fn marketTransient() Transient {
    return Transient.new("Market: $REGRET / $GAY")
        .withGroups(&[_]Group{
        .{
            .title = "$REGRET",
            .title_style = Style.fg(Color.red).bold(),
            .infixes = &[_]Infix{
                .{ .key = 's', .flag = "--slippage", .kind = .value, .num_value = 5, .description = "max slippage %" },
            },
            .suffixes = &[_]Suffix{
                .{ .key = 'b', .description = "buy $REGRET", .trit = .plus, .action_id = 200 },
                .{ .key = 'x', .description = "sell $REGRET", .trit = .minus, .action_id = 201 },
                .{ .key = 'p', .description = "place bet", .trit = .plus, .action_id = 202 },
                .{ .key = 'r', .description = "resolve market", .trit = .minus, .action_id = 203 },
                .{ .key = 'w', .description = "claim winnings", .trit = .ergodic, .action_id = 204 },
            },
        },
        .{
            .title = "$GAY",
            .title_style = Style.fg(Color.magenta).bold(),
            .infixes = &[_]Infix{
                .{ .key = 't', .flag = "--trit", .kind = .trit_cycle, .description = "theme trit bias" },
            },
            .suffixes = &[_]Suffix{
                .{ .key = 'T', .description = "register theme", .trit = .plus, .action_id = 210 },
                .{ .key = 'P', .description = "purchase theme", .trit = .ergodic, .action_id = 211 },
                .{ .key = 'L', .description = "list themes", .trit = .ergodic, .action_id = 212 },
                .{ .key = 'S', .description = "swap REGRET->GAY", .trit = .minus, .action_id = 213 },
            },
        },
        .{
            .title = "Liquidity",
            .suffixes = &[_]Suffix{
                .{ .key = 'l', .description = "create LBP", .trit = .plus, .action_id = 220 },
                .{ .key = 'j', .description = "join LBP", .trit = .ergodic, .action_id = 221 },
                .{ .key = 'f', .description = "finalize LBP", .trit = .minus, .action_id = 222 },
            },
        },
    })
        .withBorderType(.rounded);
}

// ============================================================================
// WASM exports (C ABI for browser integration)
// ============================================================================

/// Predefined transient IDs
pub const TransientId = enum(u8) {
    git = 0,
    gf3 = 1,
    market = 2,
    custom = 255,
};

var active_transient: ?Transient = null;
var transient_buffer: Buffer = undefined;
var transient_backend: retty.AnsiBackend = .{};

/// Initialize a predefined transient popup
export fn transient_init(id: u8, cols: u16, rows: u16) void {
    const area = Rect{ .x = 0, .y = 0, .width = cols, .height = rows };
    transient_buffer = Buffer.init(area);

    active_transient = switch (@as(TransientId, @enumFromInt(id))) {
        .git => gitTransient(),
        .gf3 => gf3Transient(),
        .market => marketTransient(),
        .custom => null,
    };
}

/// Set randomness seed (from on-chain source)
export fn transient_set_seed(source: u8, seed_lo: u64, seed_hi: u64, round: u64) void {
    if (active_transient) |*t| {
        var seed = RandomnessSeed{
            .source = @enumFromInt(source),
            .round = round,
        };
        // Pack u128 seed
        const lo_bytes: [8]u8 = @bitCast(seed_lo);
        const hi_bytes: [8]u8 = @bitCast(seed_hi);
        @memcpy(seed.value[0..8], &lo_bytes);
        @memcpy(seed.value[8..16], &hi_bytes);
        t.seed = seed;
    }
}

/// Handle keypress, return action_id (0 = no action, 0xFFFF = transient closed)
export fn transient_key(key: u8) u16 {
    if (active_transient) |*t| {
        if (t.handleKey(key)) |action_id| {
            return action_id;
        }
        if (!t.active) return 0xFFFF;
    }
    return 0;
}

/// Render to ANSI buffer, return length of output
export fn transient_render() u32 {
    if (active_transient) |t| {
        transient_buffer.clear();
        t.render(transient_buffer.area, &transient_buffer);
        transient_backend.draw(&transient_buffer);
        return @intCast(transient_backend.len);
    }
    return 0;
}

/// Get pointer to ANSI output buffer
export fn transient_output_ptr() [*]const u8 {
    return &transient_backend.out;
}

/// Check if transient is still active
export fn transient_is_active() bool {
    if (active_transient) |t| return t.active;
    return false;
}

// ============================================================================
// Tests
// ============================================================================

const is_wasm = @import("builtin").cpu.arch == .wasm32 or @import("builtin").cpu.arch == .wasm64;
const testing = if (!is_wasm) @import("std").testing else struct {};

test "Trit color mapping" {
    try testing.expectEqual(Trit.minus.color(), Color.red);
    try testing.expectEqual(Trit.ergodic.color(), Color.green);
    try testing.expectEqual(Trit.plus.color(), Color.blue);
}

test "Trit cycling" {
    try testing.expectEqual(Trit.minus.cycle(), .ergodic);
    try testing.expectEqual(Trit.ergodic.cycle(), .plus);
    try testing.expectEqual(Trit.plus.cycle(), .minus);
}

test "RandomnessSeed from u64" {
    const seed = RandomnessSeed.fromU64(0xDEADBEEFCAFEBABE, .splitmix);
    try testing.expectEqual(seed.source, .splitmix);
    try testing.expectEqual(seed.toU64(), 0xDEADBEEFCAFEBABE);
}

test "RandomnessSeed tritAt" {
    const seed = RandomnessSeed.fromU64(1069, .aptos_vrf);
    // Should produce valid trits at any index
    const t0 = seed.tritAt(0);
    const t1 = seed.tritAt(1);
    _ = t0;
    _ = t1;
    // Just verify they're valid enum values (no crash)
}

test "Transient creation" {
    const t = Transient.new("Test");
    try testing.expectEqualStrings(t.name, "Test");
    try testing.expect(t.active);
    try testing.expectEqual(t.groups.len, 0);
}

test "Git transient has expected structure" {
    const t = gitTransient();
    try testing.expectEqual(t.groups.len, 4);
    try testing.expectEqualStrings(t.groups[0].title, "Fetch");
    try testing.expectEqual(t.groups[0].suffixes.len, 2);
    try testing.expectEqual(t.groups[0].suffixes[0].key, 'f');
}

test "GF3 transient has triadic balance" {
    const t = gf3Transient();
    try testing.expectEqual(t.groups.len, 3);
    // Check each group has a different trit
    for (t.groups[0].suffixes) |s| {
        try testing.expectEqual(s.trit, .plus);
    }
    for (t.groups[1].suffixes) |s| {
        try testing.expectEqual(s.trit, .ergodic);
    }
    for (t.groups[2].suffixes) |s| {
        try testing.expectEqual(s.trit, .minus);
    }
}

test "Market transient has REGRET and GAY groups" {
    const t = marketTransient();
    try testing.expectEqual(t.groups.len, 3);
    try testing.expectEqualStrings(t.groups[0].title, "$REGRET");
    try testing.expectEqualStrings(t.groups[1].title, "$GAY");
}

test "handleKey dispatches suffix" {
    var t = gitTransient();
    // 'f' should trigger fetch (action_id = 1)
    const result = t.handleKey('f');
    try testing.expect(result != null);
    try testing.expectEqual(result.?, 1);
}

test "handleKey q closes transient" {
    var t = gitTransient();
    try testing.expect(t.active);
    _ = t.handleKey('q');
    try testing.expect(!t.active);
}

test "handleKey ESC closes transient" {
    var t = gitTransient();
    _ = t.handleKey(27); // ESC
    try testing.expect(!t.active);
}

test "handleKey navigation" {
    var t = gitTransient();
    try testing.expectEqual(t.selected, null);
    _ = t.handleKey('j'); // down
    try testing.expectEqual(t.selected, 0);
    _ = t.handleKey('j'); // down
    try testing.expectEqual(t.selected, 1);
    _ = t.handleKey('k'); // up
    try testing.expectEqual(t.selected, 0);
}

test "Transient render to buffer" {
    const t = gitTransient();
    const area = Rect{ .x = 0, .y = 0, .width = 60, .height = 30 };
    var buf = Buffer.init(area);
    t.render(area, &buf);
    // Buffer should have content (not all blank)
    var non_blank: u32 = 0;
    var row: u16 = 0;
    while (row < 30) : (row += 1) {
        var col: u16 = 0;
        while (col < 60) : (col += 1) {
            const cell = buf.get(col, row);
            if (!cell.isBlank()) non_blank += 1;
        }
    }
    try testing.expect(non_blank > 0);
}

test "Transient with randomness seed" {
    var t = gitTransient()
        .withSeed(RandomnessSeed.fromU64(1069, .drand));
    try testing.expectEqual(t.seed.source, .drand);

    const area = Rect{ .x = 0, .y = 0, .width = 60, .height = 30 };
    var buf = Buffer.init(area);
    t.render(area, &buf);
    // Should render without crashing
}
