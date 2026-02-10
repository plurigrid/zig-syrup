//! Hyperreal and Symmetric Number System for Zig Syrup
//!
//! "Arbitrary precision color arbitrary precision number by completely undefining float
//!  as the default and redefining around symmetric numbers and intuitionistic logic"
//!
//! This module implements:
//! 1. `SymmetricInt`: Arbitrary precision balanced ternary integer (backed by BigInt).
//! 2. `HyperReal(T)`: Dual number construction (a + bε) for intuitionistic infinitesimals.
//! 3. `HyperColor`: Color perception with infinitesimal precision.

const std = @import("std");
const math = std.math;
const testing = std.testing;

/// Symmetric Number (Balanced Ternary logic)
/// Instead of [0, 1], we use [-1, 0, 1].
///
/// In standard binary: 0, 1. (Asymmetric)
/// In balanced ternary: -, 0, +. (Symmetric around 0)
///
/// This implementation wraps std.math.big.int for arbitrary precision,
/// but interprets values through a symmetric lens.
pub const SymmetricInt = struct {
    value: std.math.big.int.Managed,

    pub fn init(allocator: std.mem.Allocator, v: i64) !SymmetricInt {
        var m = try std.math.big.int.Managed.init(allocator);
        try m.set(v);
        return .{ .value = m };
    }

    pub fn deinit(self: *SymmetricInt) void {
        self.value.deinit();
    }

    /// Returns the "trit" sign of the number: -1, 0, or 1.
    /// This is the intuitionistic "judgment" of the value.
    pub fn trit(self: SymmetricInt) i2 {
        if (self.value.eqZero()) return 0;
        return if (self.value.isPositive()) 1 else -1;
    }
};

/// Hyperreal Number (Standard Part + Infinitesimal)
///
/// Based on synthetic differential geometry / dual numbers.
/// x = a + bε where ε² = 0.
///
/// - `standard`: The "visible" value (what renders to screen).
/// - `infinitesimal`: The "tangent" value (velocity/derivative/uncertainty).
///
/// This allows "arbitrary precision color" by carrying the gradient
/// or sub-perceptual difference alongside the pixel value.
pub fn HyperReal(comptime T: type) type {
    return struct {
        standard: T,
        infinitesimal: T,

        const Self = @This();

        pub fn init(s: T, i: T) Self {
            return .{ .standard = s, .infinitesimal = i };
        }

        /// Pure constant (zero infinitesimal)
        pub fn constant(s: T) Self {
            return .{ .standard = s, .infinitesimal = 0 };
        }

        /// The "ε" unit
        pub fn epsilon() Self {
            return .{ .standard = 0, .infinitesimal = 1 };
        }

        // Arithmetic (Constructive/Intuitionistic Logic)

        pub fn add(self: Self, other: Self) Self {
            return .{
                .standard = self.standard + other.standard,
                .infinitesimal = self.infinitesimal + other.infinitesimal,
            };
        }

        pub fn sub(self: Self, other: Self) Self {
            return .{
                .standard = self.standard - other.standard,
                .infinitesimal = self.infinitesimal - other.infinitesimal,
            };
        }

        pub fn mul(self: Self, other: Self) Self {
            // (a + bε)(c + dε) = ac + (ad + bc)ε + bdε²
            // Since ε² = 0, we get: ac + (ad + bc)ε
            return .{
                .standard = self.standard * other.standard,
                .infinitesimal = self.standard * other.infinitesimal + self.infinitesimal * other.standard,
            };
        }

        /// Scale by a scalar
        pub fn scale(self: Self, s: T) Self {
            return .{
                .standard = self.standard * s,
                .infinitesimal = self.infinitesimal * s,
            };
        }

        /// Intuitionistic Equality
        /// Returns true only if standard parts are equal.
        /// Infinitesimal differences are "indistinguishable" in the standard world.
        pub fn eqStandard(self: Self, other: Self) bool {
            return self.standard == other.standard;
        }

        /// Strict Equality (Hyperreal)
        pub fn eqStrict(self: Self, other: Self) bool {
            return self.standard == other.standard and self.infinitesimal == other.infinitesimal;
        }
    };
}

/// HyperColor: Arbitrary Precision Color
///
/// A color defined not just by its RGB location, but by its
/// "motion" or "uncertainty" in color space.
///
/// Significance to Color:
/// 1. **Gradients**: `infinitesimal` stores the slope. Rendering a gradient becomes
///    evaluating `c(t) = c₀ + t * ε`.
/// 2. **Perception**: The standard part is what you see. The infinitesimal part
///    is the "just noticeable difference" or the spectral distribution tail.
pub const HyperColor = struct {
    r: HyperReal(f64),
    g: HyperReal(f64),
    b: HyperReal(f64),

    pub fn init(r: f64, g: f64, b: f64) HyperColor {
        return .{
            .r = HyperReal(f64).constant(r),
            .g = HyperReal(f64).constant(g),
            .b = HyperReal(f64).constant(b),
        };
    }

    /// Create a color with "velocity" (infinitesimal change)
    pub fn withVelocity(r: f64, g: f64, b: f64, dr: f64, dg: f64, db: f64) HyperColor {
        return .{
            .r = HyperReal(f64).init(r, dr),
            .g = HyperReal(f64).init(g, dg),
            .b = HyperReal(f64).init(b, db),
        };
    }

    /// Project to standard sRGB (collapse wavefunction)
    pub fn toRgb24(self: HyperColor) u24 {
        const r_u8 = @as(u8, @intFromFloat(std.math.clamp(self.r.standard * 255.0, 0.0, 255.0)));
        const g_u8 = @as(u8, @intFromFloat(std.math.clamp(self.g.standard * 255.0, 0.0, 255.0)));
        const b_u8 = @as(u8, @intFromFloat(std.math.clamp(self.b.standard * 255.0, 0.0, 255.0)));
        return (@as(u24, r_u8) << 16) | (@as(u24, g_u8) << 8) | @as(u24, b_u8);
    }
};

test "HyperReal arithmetic" {
    const H = HyperReal(f64);
    const x = H.init(10.0, 1.0); // 10 + ε
    const y = H.init(5.0, 2.0);  // 5 + 2ε

    // Addition: 15 + 3ε
    const sum = x.add(y);
    try testing.expectEqual(15.0, sum.standard);
    try testing.expectEqual(3.0, sum.infinitesimal);

    // Multiplication: 10*5 + (10*2 + 1*5)ε = 50 + 25ε
    const prod = x.mul(y);
    try testing.expectEqual(50.0, prod.standard);
    try testing.expectEqual(25.0, prod.infinitesimal);
}
