//! Stellogen Parser - Recursive descent parser for Stellogen source code

const std = @import("std");
const lexer = @import("lexer.zig");
const ast = @import("ast.zig");

const Token = lexer.Token;
const TokenKind = lexer.TokenKind;
const Term = ast.Term;
const Ray = ast.Ray;
const Star = ast.Star;
const Constellation = ast.Constellation;
const Expr = ast.Expr;
const Polarity = ast.Polarity;

pub const ParseError = error{
    UnexpectedToken,
    UnexpectedEof,
    InvalidPolarity,
    UnmatchedParen,
    OutOfMemory,
};

pub const Parser = struct {
    tokens: []const Token,
    pos: usize = 0,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, tokens: []const Token) Self {
        return .{ .tokens = tokens, .allocator = allocator };
    }

    fn peek(self: *Self) ?Token {
        // Skip newlines when peeking
        var i = self.pos;
        while (i < self.tokens.len) {
            if (self.tokens[i].kind != .newline) {
                return self.tokens[i];
            }
            i += 1;
        }
        return null;
    }

    fn current(self: *Self) ?Token {
        if (self.pos >= self.tokens.len) return null;
        return self.tokens[self.pos];
    }

    fn advance(self: *Self) void {
        if (self.pos < self.tokens.len) self.pos += 1;
        // Skip newlines
        while (self.pos < self.tokens.len and self.tokens[self.pos].kind == .newline) {
            self.pos += 1;
        }
    }

    fn expect(self: *Self, kind: TokenKind) ParseError!Token {
        const tok = self.peek() orelse return ParseError.UnexpectedEof;
        if (tok.kind != kind) return ParseError.UnexpectedToken;
        self.advance();
        return tok;
    }

    fn parsePolarity(text: []const u8) struct { polarity: Polarity, name: []const u8 } {
        if (text.len > 0) {
            if (text[0] == '+') {
                return .{ .polarity = .pos, .name = text[1..] };
            } else if (text[0] == '-') {
                return .{ .polarity = .neg, .name = text[1..] };
            }
        }
        return .{ .polarity = .null, .name = text };
    }

    /// Parse a term (variable or function application)
    pub fn parseTerm(self: *Self) ParseError!Term {
        const tok = self.peek() orelse return ParseError.UnexpectedEof;

        switch (tok.kind) {
            .variable => {
                self.advance();
                return .{ .variable = .{ .name = tok.text } };
            },
            .symbol, .kw_ok => {
                self.advance();
                const parsed = parsePolarity(tok.text);

                // Check for arguments
                if (self.peek()) |next| {
                    if (next.kind == .lparen) {
                        return self.parseFunctionArgs(parsed.polarity, parsed.name);
                    }
                }

                // No args - it's an atom
                return .{
                    .function = .{
                        .id = .{ .polarity = parsed.polarity, .name = parsed.name },
                        .args = &.{},
                    },
                };
            },
            .lparen => {
                // S-expression: (func arg1 arg2 ...)
                _ = try self.expect(.lparen);
                return self.parseSExpr();
            },
            .number => {
                self.advance();
                // Treat numbers as atoms
                return .{
                    .function = .{
                        .id = .{ .polarity = .null, .name = tok.text },
                        .args = &.{},
                    },
                };
            },
            else => return ParseError.UnexpectedToken,
        }
    }

    /// Parse function with arguments: f(arg1, arg2)
    fn parseFunctionArgs(self: *Self, polarity: Polarity, name: []const u8) ParseError!Term {
        _ = try self.expect(.lparen);

        var args = std.ArrayListUnmanaged(Term){};
        defer args.deinit(self.allocator);

        while (true) {
            const next = self.peek() orelse return ParseError.UnexpectedEof;
            if (next.kind == .rparen) break;
            const arg = try self.parseTerm();
            try args.append(self.allocator, arg);
        }

        _ = try self.expect(.rparen);

        return .{
            .function = .{
                .id = .{ .polarity = polarity, .name = name },
                .args = try self.allocator.dupe(Term, args.items),
            },
        };
    }

    /// Parse S-expression: (func arg1 arg2 ...)
    fn parseSExpr(self: *Self) ParseError!Term {
        // First element is the function symbol
        const func_tok = self.peek() orelse return ParseError.UnexpectedEof;

        if (func_tok.kind != .symbol and func_tok.kind != .kw_ok) {
            return ParseError.UnexpectedToken;
        }

        self.advance();
        const parsed = parsePolarity(func_tok.text);

        // Parse arguments
        var args = std.ArrayListUnmanaged(Term){};
        defer args.deinit(self.allocator);

        while (true) {
            const next = self.peek() orelse return ParseError.UnexpectedEof;
            if (next.kind == .rparen) break;
            const arg = try self.parseTerm();
            try args.append(self.allocator, arg);
        }

        _ = try self.expect(.rparen);

        return .{
            .function = .{
                .id = .{ .polarity = parsed.polarity, .name = parsed.name },
                .args = try self.allocator.dupe(Term, args.items),
            },
        };
    }

    /// Parse a star: [ray1 ray2 ... || ban1 ban2]
    pub fn parseStar(self: *Self) ParseError!Star {
        _ = try self.expect(.lbracket);

        var rays = std.ArrayListUnmanaged(Ray){};
        defer rays.deinit(self.allocator);

        var bans = std.ArrayListUnmanaged(ast.Ban){};
        defer bans.deinit(self.allocator);

        var in_bans = false;

        while (true) {
            const next = self.peek() orelse return ParseError.UnexpectedEof;

            if (next.kind == .rbracket) break;

            if (next.kind == .pipe) {
                self.advance();
                if (self.peek()) |p| {
                    if (p.kind == .pipe) {
                        self.advance();
                        in_bans = true;
                        continue;
                    }
                }
            }

            if (in_bans) {
                // Parse ban (inequality constraint)
                const ban = try self.parseBan();
                try bans.append(self.allocator, ban);
            } else {
                const ray = try self.parseTerm();
                try rays.append(self.allocator, ray);
            }
        }

        _ = try self.expect(.rbracket);

        return .{
            .content = try self.allocator.dupe(Ray, rays.items),
            .bans = try self.allocator.dupe(ast.Ban, bans.items),
            .is_state = false,
        };
    }

    /// Parse ban constraint: (!= X Y)
    fn parseBan(self: *Self) ParseError!ast.Ban {
        _ = try self.expect(.lparen);

        const op = self.peek() orelse return ParseError.UnexpectedEof;
        if (op.kind != .bang_eq) return ParseError.UnexpectedToken;
        self.advance();

        const a = try self.parseTerm();
        const b = try self.parseTerm();

        _ = try self.expect(.rparen);

        return .{ .inequality = .{ .a = a, .b = b } };
    }

    /// Parse constellation: {star1 star2 ...}
    pub fn parseConstellation(self: *Self) ParseError!Constellation {
        _ = try self.expect(.lbrace);

        var stars = std.ArrayListUnmanaged(Star){};
        defer stars.deinit(self.allocator);

        while (true) {
            const next = self.peek() orelse return ParseError.UnexpectedEof;

            if (next.kind == .rbrace) break;

            // Check for focus (@)
            var is_state = false;
            if (next.kind == .at) {
                self.advance();
                is_state = true;
            }

            if (self.peek()) |p| {
                if (p.kind == .lbracket) {
                    var star = try self.parseStar();
                    star.is_state = is_state;
                    try stars.append(self.allocator, star);
                } else if (p.kind == .lparen or p.kind == .symbol or p.kind == .variable) {
                    // Single term as star
                    const term = try self.parseTerm();
                    try stars.append(self.allocator, .{
                        .content = try self.allocator.dupe(Ray, &.{term}),
                        .is_state = is_state,
                    });
                } else {
                    return ParseError.UnexpectedToken;
                }
            }
        }

        _ = try self.expect(.rbrace);

        return .{
            .stars = try self.allocator.dupe(Star, stars.items),
        };
    }

    /// Parse top-level expression
    pub fn parseExpr(self: *Self) ParseError!Expr {
        const tok = self.peek() orelse return ParseError.UnexpectedEof;

        switch (tok.kind) {
            .lparen => {
                // Check for special forms
                _ = try self.expect(.lparen);
                const form = self.peek() orelse return ParseError.UnexpectedEof;

                switch (form.kind) {
                    .kw_def => {
                        self.advance();
                        const name_tok = try self.expect(.symbol);
                        const value = try self.parseExpr();
                        _ = try self.expect(.rparen);

                        const value_ptr = try self.allocator.create(Expr);
                        value_ptr.* = value;

                        return .{ .def = .{ .name = name_tok.text, .value = value_ptr } };
                    },
                    .kw_show => {
                        self.advance();
                        var exprs = std.ArrayListUnmanaged(Expr){};
                        defer exprs.deinit(self.allocator);

                        while (true) {
                            const next = self.peek() orelse return ParseError.UnexpectedEof;
                            if (next.kind == .rparen) break;
                            const expr = try self.parseExpr();
                            try exprs.append(self.allocator, expr);
                        }

                        _ = try self.expect(.rparen);
                        return .{ .show = try self.allocator.dupe(Expr, exprs.items) };
                    },
                    .kw_exec => {
                        self.advance();
                        const expr = try self.parseExpr();
                        _ = try self.expect(.rparen);

                        const expr_ptr = try self.allocator.create(Expr);
                        expr_ptr.* = expr;

                        return .{ .exec = .{ .linear = false, .constellation = expr_ptr } };
                    },
                    .kw_fire => {
                        self.advance();
                        const expr = try self.parseExpr();
                        _ = try self.expect(.rparen);

                        const expr_ptr = try self.allocator.create(Expr);
                        expr_ptr.* = expr;

                        return .{ .exec = .{ .linear = true, .constellation = expr_ptr } };
                    },
                    .kw_use => {
                        self.advance();
                        const path_tok = try self.expect(.string);
                        _ = try self.expect(.rparen);
                        // Strip quotes
                        const path = path_tok.text[1 .. path_tok.text.len - 1];
                        return .{ .use = path };
                    },
                    .eq_eq => {
                        self.advance();
                        const left = try self.parseExpr();
                        const right = try self.parseExpr();
                        _ = try self.expect(.rparen);

                        const left_ptr = try self.allocator.create(Expr);
                        left_ptr.* = left;
                        const right_ptr = try self.allocator.create(Expr);
                        right_ptr.* = right;

                        return .{ .expect = .{ .left = left_ptr, .right = right_ptr } };
                    },
                    else => {
                        // Regular S-expression term
                        // Backtrack the lparen consumption
                        self.pos -= 1;
                        while (self.pos > 0 and self.tokens[self.pos - 1].kind == .newline) {
                            self.pos -= 1;
                        }
                        const term = try self.parseTerm();
                        return .{ .raw = term };
                    },
                }
            },
            .at => {
                // Focus: @expr
                self.advance();
                const expr = try self.parseExpr();
                const expr_ptr = try self.allocator.create(Expr);
                expr_ptr.* = expr;
                return .{ .focus = expr_ptr };
            },
            .sharp => {
                // Call: #identifier
                self.advance();
                const name_tok = try self.expect(.symbol);
                return .{ .call = name_tok.text };
            },
            .lbrace => {
                // Constellation
                const constellation = try self.parseConstellation();
                return .{ .constellation = constellation };
            },
            .lbracket => {
                // Single star
                const star = try self.parseStar();
                return .{ .star = star };
            },
            .variable, .symbol, .kw_ok, .number => {
                // Raw term
                const term = try self.parseTerm();
                return .{ .raw = term };
            },
            else => return ParseError.UnexpectedToken,
        }
    }

    /// Parse a complete program
    pub fn parseProgram(self: *Self) ParseError![]Expr {
        var exprs = std.ArrayListUnmanaged(Expr){};
        defer exprs.deinit(self.allocator);

        while (true) {
            // Skip newlines
            while (self.current()) |tok| {
                if (tok.kind != .newline) break;
                self.pos += 1;
            }

            const tok = self.current() orelse break;
            if (tok.kind == .eof) break;

            const expr = try self.parseExpr();
            try exprs.append(self.allocator, expr);
        }

        return try self.allocator.dupe(Expr, exprs.items);
    }
};

/// Parse source code into AST
pub fn parse(allocator: std.mem.Allocator, source: []const u8) ParseError![]Expr {
    var lex = lexer.Lexer.init(source);
    const tokens = try lex.tokenize(allocator);
    var parser = Parser.init(allocator, tokens);
    return parser.parseProgram();
}

// ============================================================================
// Tests
// ============================================================================

test "parse variable" {
    const allocator = std.testing.allocator;
    var lex = lexer.Lexer.init("X");
    const tokens = try lex.tokenize(allocator);
    defer allocator.free(tokens);

    var parser = Parser.init(allocator, tokens);
    const term = try parser.parseTerm();

    try std.testing.expect(term.isVar());
}

test "parse atom" {
    const allocator = std.testing.allocator;
    var lex = lexer.Lexer.init("foo");
    const tokens = try lex.tokenize(allocator);
    defer allocator.free(tokens);

    var parser = Parser.init(allocator, tokens);
    const term = try parser.parseTerm();

    try std.testing.expect(term.isFunc());
    switch (term) {
        .function => |f| {
            try std.testing.expectEqualStrings("foo", f.id.name);
            try std.testing.expectEqual(Polarity.null, f.id.polarity);
        },
        else => unreachable,
    }
}

test "parse polarized atom" {
    const allocator = std.testing.allocator;
    var lex = lexer.Lexer.init("+foo");
    const tokens = try lex.tokenize(allocator);
    defer allocator.free(tokens);

    var parser = Parser.init(allocator, tokens);
    const term = try parser.parseTerm();

    switch (term) {
        .function => |f| {
            try std.testing.expectEqualStrings("foo", f.id.name);
            try std.testing.expectEqual(Polarity.pos, f.id.polarity);
        },
        else => unreachable,
    }
}

test "parse star" {
    const allocator = std.testing.allocator;
    var lex = lexer.Lexer.init("[+foo X]");
    const tokens = try lex.tokenize(allocator);
    defer allocator.free(tokens);

    var parser = Parser.init(allocator, tokens);
    const star = try parser.parseStar();

    try std.testing.expectEqual(@as(usize, 2), star.content.len);
}

test "parse constellation" {
    const allocator = std.testing.allocator;
    var lex = lexer.Lexer.init("{[+foo X] @[-bar Y]}");
    const tokens = try lex.tokenize(allocator);
    defer allocator.free(tokens);

    var parser = Parser.init(allocator, tokens);
    const constellation = try parser.parseConstellation();

    try std.testing.expectEqual(@as(usize, 2), constellation.stars.len);
    try std.testing.expect(!constellation.stars[0].is_state);
    try std.testing.expect(constellation.stars[1].is_state);
}

test "parse def expression" {
    const allocator = std.testing.allocator;
    const exprs = try parse(allocator, "(def foo X)");

    try std.testing.expectEqual(@as(usize, 1), exprs.len);
    switch (exprs[0]) {
        .def => |d| {
            try std.testing.expectEqualStrings("foo", d.name);
        },
        else => unreachable,
    }
}
