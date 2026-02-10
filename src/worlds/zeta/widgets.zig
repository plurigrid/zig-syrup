//! Zeta World Widgets - Thermodynamic Control Surfaces
//! 
//! Visual components for rendering spectral properties of the Zeta World.
//! Built on the retty.zig constraint-based layout engine.

const std = @import("std");
const retty = @import("retty");

/// Renders the Spectral Gap (λ₁ - λ₂) as a gauge.
/// Green indicates Ramanujan property (optimal expansion).
pub const ZetaWidget = struct {
    spectral_gap: f64,
    is_ramanujan: bool,
    
    pub fn render(self: ZetaWidget, buffer: *retty.Buffer, rect: retty.Rect) void {
        // Ramanujan bound is roughly 2√(d-1). For small graphs, hard to define exact max.
        // We normalize assuming a gap of ~2.0 is "good/max" for visualization.
        const gap_ratio = @min(1.0, @as(f32, @floatCast(self.spectral_gap)) / 2.0);
        
        var gauge = retty.Gauge.default()
            .withRatio(gap_ratio)
            .withLabel("Spectral Gap (λ₁-λ₂)")
            .withGaugeStyle(retty.Style.fg(
                if (self.is_ramanujan) retty.Color.green else retty.Color.red
            ));
            
        gauge.render(rect, buffer);
    }
};

/// Thermodynamic Dashboard showing Entropy (log ζ) and Expansion.
pub const EntropyDashboard = struct {
    entropy: f64,
    spectral_gap: f64,
    is_ramanujan: bool,
    tick_count: u64,
    
    pub fn render(self: EntropyDashboard, buffer: *retty.Buffer, rect: retty.Rect) void {
        var layout = retty.Layout.vertical(&.{
            retty.Constraint{ .length = 1 }, // Title
            retty.Constraint{ .length = 1 }, // Entropy
            retty.Constraint{ .length = 1 }, // Spectral Gap
            retty.Constraint{ .min = 0 },    // Filler
        });
        
        var chunks: [4]retty.Rect = undefined;
        layout.split(rect, &chunks);
        
        // 1. Title with Tick Count
        var title_buf: [64]u8 = undefined;
        const title_text = std.fmt.bufPrint(&title_buf, "Zeta World (t={d})", .{self.tick_count}) catch "Zeta World";
        var title = retty.Paragraph.new(retty.Text.from(&.{retty.Line.raw(title_text)}))
            .withStyle(retty.Style.fg(retty.Color.cyan).bold());
        
        title.render(chunks[0], buffer);
        
        // 2. Entropy Gauge
        // Entropy = log(zeta). For C_10, lambda1=2, entropy ~ 0.69.
        // Normalize to some reasonable max (e.g. 5.0).
        const entropy_ratio = @min(1.0, @as(f32, @floatCast(self.entropy)) / 3.0);
        var entropy_gauge = retty.Gauge.default()
            .withRatio(entropy_ratio)
            .withLabel("Entropy (log ζ)")
            .withGaugeStyle(retty.Style.fg(retty.Color.magenta));
            
        entropy_gauge.render(chunks[1], buffer);
        
        // 3. Spectral Gap Widget (Composition)
        const zeta_widget = ZetaWidget{
            .spectral_gap = self.spectral_gap,
            .is_ramanujan = self.is_ramanujan,
        };
        zeta_widget.render(buffer, chunks[2]);
    }
};
