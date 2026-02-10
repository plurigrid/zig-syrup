const std = @import("std");
const retty = @import("retty");
const hyper = @import("hyperreal.zig");

const Color = retty.Color;
const Style = retty.Style;
const Rect = retty.Rect;
const Buffer = retty.Buffer;

/// ZetaWidget: Visualizes the Ihara Zeta Function of the interaction graph.
///
/// "The non-backtracking spectrum of a graph encodes thermodynamic quantities."
///
/// This widget renders:
/// 1. The "Spectral Gap" (lambda_2) as a HyperReal value (with velocity).
/// 2. The "Entropy" (log of Zeta at critical point).
/// 3. A "Ramanujan" indicator (is the graph an optimal expander?).
///
/// It uses Alok Singh-style optimization heuristics (via Layout constraints)
/// and Terence Tao-style non-standard analysis (via HyperReal precision).
pub const ZetaWidget = struct {
    /// The current spectral gap of the graph.
    /// Standard part: 0.0 to 1.0 (normalized).
    /// Infinitesimal: Velocity of the gap (is it opening or closing?).
    gap: hyper.HyperReal(f64),

    /// Network Entropy (S = -Σ p log p)
    entropy: hyper.HyperReal(f64),

    /// Is the current graph Ramanujan? (λ₂ ≤ 2√(d-1))
    is_ramanujan: bool,

    /// History for sparklines
    history: std.ArrayListUnmanaged(f64),
    
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) ZetaWidget {
        return .{
            .gap = hyper.HyperReal(f64).init(0.5, 0.01),
            .entropy = hyper.HyperReal(f64).init(0.8, -0.005),
            .is_ramanujan = true,
            .history = .{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ZetaWidget) void {
        self.history.deinit(self.allocator);
    }

    /// Simulate an update (in a real app, this would come from the graph analyzer)
    pub fn tick(self: *ZetaWidget) void {
        // "Kontorovich Dynamics": Random walk on the moduli space of graphs
        // Update gap with its velocity
        var next_std = self.gap.standard + self.gap.infinitesimal;
        
        // Bounce off bounds (0.0 - 1.0)
        if (next_std > 1.0 or next_std < 0.0) {
            self.gap.infinitesimal *= -1.0;
            next_std = std.math.clamp(next_std, 0.0, 1.0);
        }
        
        self.gap.standard = next_std;

        // Entropy tends to increase (Second Law), but we "work" to reduce it (Maxwell's Demon)
        // This models the "human vat" applying structure to the chaos.
        self.entropy.standard += self.entropy.infinitesimal;
        if (self.entropy.standard > 1.0) self.entropy.infinitesimal = -0.01;
        if (self.entropy.standard < 0.2) self.entropy.infinitesimal = 0.005;

        // Record history
        if (self.history.items.len >= 40) {
            _ = self.history.orderedRemove(0);
        }
        self.history.append(self.allocator, self.gap.standard) catch {};

        // Check Ramanujan condition (simplified: gap > 0.8 is "good")
        self.is_ramanujan = self.gap.standard > 0.8;
    }

    /// Render the Zeta Dashboard
    ///
    /// Layout:
    /// [ Gap: 0.85 (+0.01ε) ] [ Entropy: 0.42 ] [ RAMANUJAN ]
    /// [ ▂▃▅▇█▇▅▃▂      ] (Sparkline)
    pub fn render(self: ZetaWidget, buf: *Buffer, area: Rect) void {
        // Use retty.Layout for internal structure (Singh optimization)
        var chunks: [2]Rect = undefined;
        retty.Layout.vertical(&.{
            .{ .length = 1 }, // Stats row
            .{ .length = 1 }, // Sparkline row
        }).split(area, &chunks);

        const stats_area = chunks[0];
        const graph_area = chunks[1];

        // 1. Stats Row
        self.renderStats(buf, stats_area);

        // 2. Sparkline Row
        self.renderSparkline(buf, graph_area);
    }

    fn renderStats(self: ZetaWidget, buf: *Buffer, area: Rect) void {
        var x = area.x;
        
        // Label
        buf.setString(x, area.y, "ζ-Gap:", Style.default);
        x += 7;

        // Gap Value (with HyperReal velocity indicator)
        var val_buf: [32]u8 = undefined;
        const val_str = std.fmt.bufPrint(&val_buf, "{d:.2}", .{self.gap.standard}) catch "ERR";
        
        // Color depends on velocity (Green = improving/opening, Red = closing)
        // "Opening" spectral gap is good (better expansion)
        const vel_color = if (self.gap.infinitesimal > 0) Color.green else Color.red;
        
        buf.setString(x, area.y, val_str, Style.fg(vel_color).bold());
        x += @intCast(val_str.len);

        // Epsilon indicator (velocity magnitude)
        const eps_char = if (self.gap.infinitesimal > 0) "↑" else "↓";
        buf.setString(x, area.y, eps_char, Style.fg(vel_color));
        x += 2;

        // Ramanujan Badge
        x += 2;
        if (self.is_ramanujan) {
            buf.setString(x, area.y, "[RAMANUJAN]", Style.fg(Color.magenta).bold().withBg(Color.black));
        } else {
            buf.setString(x, area.y, "[IRREGULAR]", Style.fg(Color.yellow));
        }
    }

    fn renderSparkline(self: ZetaWidget, buf: *Buffer, area: Rect) void {
        // Sparkline characters:  ▂▃▄▅▆▇█
        const levels = " ▂▃▄▅▆▇█";
        
        var i: usize = 0;
        while (i < area.width and i < self.history.items.len) : (i += 1) {
            // Get value from end of history backwards
            const idx = self.history.items.len - 1 - i;
            const val = self.history.items[idx];
            
            // Map 0.0-1.0 to 0-7
            const level_idx = @as(usize, @intFromFloat(val * 7.0));
            const clamped_idx = std.math.clamp(level_idx, 0, 7);
            
            // Render from right to left
            const x = area.x + area.width - 1 - @as(u16, @intCast(i));
            
            // Color mapping: High gap = Blue/Purple (Deep structure), Low gap = Grey (Noise)
            const color = if (val > 0.8) Color.cyan else if (val > 0.5) Color.blue else Color.dark_gray;

            buf.set(x, area.y, .{
                .codepoint = levels[clamped_idx],
                .fg = color,
                .bg = Color.DEFAULT,
            });
        }
    }
};
