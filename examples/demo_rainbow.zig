const std = @import("std");
const rainbow = @import("src/rainbow.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Sample Lisp expressions demonstrating nested parens
    const expressions = [_][]const u8{
        "(defn fibonacci [n]\n  (if (<= n 1)\n    n\n    (+ (fibonacci (- n 1))\n       (fibonacci (- n 2)))))",
        "(let [colors (rainbow/golden-spiral 8 271.0)]\n  (map render-paren colors))",
        "((lambda (x) ((lambda (y) (+ x y)) 3)) 5)",
        "(syrup/encode {:type \"colored-sexp\" :trit-sum 0})",
    };

    std.debug.print("\n🌈 HOMOICONIC RAINBOW PARENTHESES - ALL 16.7M CATHODE RAY COLORS 🌈\n", .{});
    std.debug.print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n\n", .{});

    // Golden angle palette (default)
    std.debug.print("φ Golden Angle (137.508°) Palette:\n", .{});
    const golden_palette = try rainbow.goldenSpiral(8, 271.0, 0.8, 0.6, allocator);
    defer allocator.free(golden_palette);
    printPalette(golden_palette);

    // Plastic angle palette (GF(3))
    std.debug.print("\nρ Plastic Angle (205.14°) GF(3) Palette:\n", .{});
    const plastic_palette = try rainbow.plasticSpiral(8, 271.0, 0.8, 0.6, allocator);
    defer allocator.free(plastic_palette);
    printPalette(plastic_palette);

    // Homotopy path
    std.debug.print("\n⟿ Homotopy Path (Purple → Cyan):\n", .{});
    const homotopy_palette = try rainbow.homotopyPath(
        rainbow.RGB.purple,
        rainbow.RGB{ .r = 0x22, .g = 0xD3, .b = 0xEE },
        8,
        allocator,
    );
    defer allocator.free(homotopy_palette);
    printPalette(homotopy_palette);

    std.debug.print("\n\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n", .{});
    std.debug.print("COLORED S-EXPRESSIONS (GF(3) trit-balanced):\n", .{});
    std.debug.print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n\n", .{});

    for (expressions) |expr| {
        var parser = rainbow.ColoredParser.withPalette(expr, golden_palette, allocator);
        const sexp = try parser.parse();
        defer allocator.free(sexp.tokens);

        const ansi = try sexp.renderAnsi(allocator);
        defer allocator.free(ansi);

        std.debug.print("{s}\n", .{ansi});
        std.debug.print("  └─ GF(3) trit sum: {d} (balanced: {s})\n\n", .{
            sexp.trit_sum,
            if (sexp.trit_sum == 0) "✓" else "✗",
        });
    }

    std.debug.print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n", .{});
    std.debug.print("Constants:\n", .{});
    std.debug.print("  φ (golden ratio)   = {d:.16}\n", .{rainbow.PHI});
    std.debug.print("  Golden angle       = {d:.6}°\n", .{rainbow.GOLDEN_ANGLE});
    std.debug.print("  ρ (plastic const)  = {d:.16}\n", .{rainbow.RHO});
    std.debug.print("  Plastic angle      = {d:.6}°\n", .{rainbow.PLASTIC_ANGLE});
    std.debug.print("  Total CRT colors   = {d:,} (2²⁴)\n", .{rainbow.TOTAL_COLORS});
    std.debug.print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n", .{});
}

fn printPalette(palette: []const rainbow.RGB) void {
    for (palette) |color| {
        var buf: [19]u8 = undefined;
        const ansi = color.toAnsiBg(&buf);
        std.debug.print("{s}   \x1b[0m", .{ansi});
    }
    std.debug.print("\n", .{});
    for (palette) |color| {
        var hex_buf: [7]u8 = undefined;
        const hex = color.toHex(&hex_buf);
        std.debug.print("{s} ", .{hex});
    }
    std.debug.print("\n", .{});
}
