//! Stellogen Compiler - Logic-agnostic programming language
//!
//! Based on Girard's transcendental syntax and Lafont's interaction nets.
//! Compiles to WebAssembly (wasm32-standalone).
//!
//! Usage:
//!   const stellogen = @import("stellogen");
//!   const wasm = try stellogen.compile(allocator, source);
//!
//! Language features:
//!   - Polarized rays: +output(X), -input(X)
//!   - Stars: [ray1 ray2 ray3]
//!   - Constellations: {star1 @star2}
//!   - Focus (@): marks state stars for interaction
//!   - exec: non-linear execution (reusable actions)
//!   - fire: linear execution (each action used once)
//!
//! GF(3) mapping:
//!   - (+) polarity → +1 (production)
//!   - (-) polarity → -1 (consumption)
//!   - neutral → 0 (balance)

const std = @import("std");

pub const ast = @import("ast.zig");
pub const lexer = @import("lexer.zig");
pub const parser = @import("parser.zig");
pub const unify = @import("unify.zig");
pub const executor = @import("executor.zig");
pub const codegen = @import("codegen.zig");

// Re-exports
pub const Term = ast.Term;
pub const Star = ast.Star;
pub const Constellation = ast.Constellation;
pub const Polarity = ast.Polarity;
pub const Expr = ast.Expr;

pub const Lexer = lexer.Lexer;
pub const Token = lexer.Token;
pub const TokenKind = lexer.TokenKind;

pub const Parser = parser.Parser;
pub const ParseError = parser.ParseError;

pub const Substitution = unify.Substitution;
pub const UnifyError = unify.UnifyError;

pub const WasmBuilder = codegen.WasmBuilder;
pub const Compiler = codegen.Compiler;

/// Compile Stellogen source to WASM binary
pub fn compile(allocator: std.mem.Allocator, source: []const u8) ![]const u8 {
    // Parse source
    const program = try parser.parse(allocator, source);

    // Compile to WASM
    var compiler = try Compiler.init(allocator);
    defer compiler.deinit();

    return compiler.compileProgram(program);
}

/// Parse and execute Stellogen source (interpreted mode)
pub fn interpret(allocator: std.mem.Allocator, source: []const u8) !Constellation {
    const program = try parser.parse(allocator, source);

    // Build constellation from program
    var stars = std.ArrayListUnmanaged(Star){};
    defer stars.deinit(allocator);

    for (program) |expr| {
        switch (expr) {
            .constellation => |c| {
                try stars.appendSlice(allocator, c.stars);
            },
            .star => |s| {
                try stars.append(allocator, s);
            },
            .focus => |e| {
                switch (e.*) {
                    .star => |s| {
                        var focused = s;
                        focused.is_state = true;
                        try stars.append(allocator, focused);
                    },
                    else => {},
                }
            },
            else => {},
        }
    }

    const constellation = Constellation{
        .stars = try allocator.dupe(Star, stars.items),
    };

    // Execute
    return executor.execute(allocator, constellation, false);
}

/// Check if result contains 'ok' (successful verification)
pub fn isOk(result: Constellation) bool {
    return executor.hasOk(result);
}

// ============================================================================
// Tests
// ============================================================================

test "compile simple program" {
    const allocator = std.testing.allocator;
    const source = "(def nat {[(+nat z)] [(-nat X) (+nat (s X))]})";

    const wasm = try compile(allocator, source);

    // Check WASM magic
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x00, 0x61, 0x73, 0x6D }, wasm[0..4]);
}

test "polarity to GF(3)" {
    try std.testing.expectEqual(@as(i8, 1), Polarity.pos.toGF3());
    try std.testing.expectEqual(@as(i8, -1), Polarity.neg.toGF3());
    try std.testing.expectEqual(@as(i8, 0), Polarity.null.toGF3());
}

test "lexer tokenizes stellogen" {
    var lex = Lexer.init("(def add {[(+add z Y Y)] [(-add X Y Z) (+add (s X) Y (s Z))]})");
    const allocator = std.testing.allocator;
    const tokens = try lex.tokenize(allocator);
    defer allocator.free(tokens);

    try std.testing.expect(tokens.len > 10);
}
