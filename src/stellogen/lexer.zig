//! Stellogen Lexer - Tokenizes Stellogen source code

const std = @import("std");

pub const TokenKind = enum {
    // Structural
    lparen, // (
    rparen, // )
    lbracket, // [
    rbracket, // ]
    lbrace, // {
    rbrace, // }
    at, // @
    sharp, // #
    pipe, // |
    bang_eq, // !=
    tilde_eq, // ~=
    eq_eq, // ==
    colon_eq, // :=
    quote, // '

    // Literals
    symbol, // lowercase identifier or operator
    variable, // uppercase identifier
    string, // "..."
    number, // integer

    // Keywords
    kw_def,
    kw_show,
    kw_exec,
    kw_fire,
    kw_use,
    kw_macro,
    kw_process,
    kw_ok,
    kw_galaxy,
    kw_end,
    kw_spec,

    // Control
    newline,
    eof,
    invalid,
};

pub const Token = struct {
    kind: TokenKind,
    text: []const u8,
    line: u32,
    column: u32,
};

pub const Lexer = struct {
    source: []const u8,
    pos: usize = 0,
    line: u32 = 1,
    column: u32 = 1,

    const Self = @This();

    pub fn init(source: []const u8) Self {
        return .{ .source = source };
    }

    fn peek(self: *Self) ?u8 {
        if (self.pos >= self.source.len) return null;
        return self.source[self.pos];
    }

    fn peekAhead(self: *Self, n: usize) ?u8 {
        if (self.pos + n >= self.source.len) return null;
        return self.source[self.pos + n];
    }

    fn advance(self: *Self) ?u8 {
        if (self.pos >= self.source.len) return null;
        const c = self.source[self.pos];
        self.pos += 1;
        if (c == '\n') {
            self.line += 1;
            self.column = 1;
        } else {
            self.column += 1;
        }
        return c;
    }

    fn skipWhitespace(self: *Self) void {
        while (self.peek()) |c| {
            switch (c) {
                ' ', '\t', '\r' => _ = self.advance(),
                '\'' => {
                    // Comment - skip to end of line
                    while (self.peek()) |cc| {
                        if (cc == '\n') break;
                        _ = self.advance();
                    }
                },
                else => break,
            }
        }
    }

    fn isIdentChar(c: u8) bool {
        return std.ascii.isAlphanumeric(c) or c == '_' or c == '-' or c == '!' or c == '?' or c == '*' or c == '/';
    }

    fn isUppercase(c: u8) bool {
        return c >= 'A' and c <= 'Z';
    }

    fn readIdentifier(self: *Self, start: usize) []const u8 {
        while (self.peek()) |c| {
            if (!isIdentChar(c)) break;
            _ = self.advance();
        }
        return self.source[start..self.pos];
    }

    fn readString(self: *Self) []const u8 {
        const start = self.pos;
        _ = self.advance(); // Skip opening quote
        while (self.peek()) |c| {
            if (c == '"') {
                _ = self.advance(); // Skip closing quote
                break;
            }
            if (c == '\\') {
                _ = self.advance(); // Skip escape char
                _ = self.advance(); // Skip escaped char
            } else {
                _ = self.advance();
            }
        }
        return self.source[start..self.pos];
    }

    fn readNumber(self: *Self, start: usize) []const u8 {
        while (self.peek()) |c| {
            if (!std.ascii.isDigit(c)) break;
            _ = self.advance();
        }
        return self.source[start..self.pos];
    }

    fn classifyKeyword(text: []const u8) TokenKind {
        const keywords = std.StaticStringMap(TokenKind).initComptime(.{
            .{ "def", .kw_def },
            .{ "show", .kw_show },
            .{ "exec", .kw_exec },
            .{ "fire", .kw_fire },
            .{ "use", .kw_use },
            .{ "macro", .kw_macro },
            .{ "process", .kw_process },
            .{ "ok", .kw_ok },
            .{ "galaxy", .kw_galaxy },
            .{ "end", .kw_end },
            .{ "spec", .kw_spec },
        });
        return keywords.get(text) orelse .symbol;
    }

    pub fn nextToken(self: *Self) Token {
        self.skipWhitespace();

        const start_line = self.line;
        const start_col = self.column;
        const start_pos = self.pos;

        const c = self.peek() orelse {
            return .{ .kind = .eof, .text = "", .line = start_line, .column = start_col };
        };

        // Single-char tokens
        const single_char_tokens = .{
            .{ '(', TokenKind.lparen },
            .{ ')', TokenKind.rparen },
            .{ '[', TokenKind.lbracket },
            .{ ']', TokenKind.rbracket },
            .{ '{', TokenKind.lbrace },
            .{ '}', TokenKind.rbrace },
            .{ '@', TokenKind.at },
            .{ '#', TokenKind.sharp },
            .{ '|', TokenKind.pipe },
        };

        inline for (single_char_tokens) |pair| {
            if (c == pair[0]) {
                _ = self.advance();
                return .{
                    .kind = pair[1],
                    .text = self.source[start_pos..self.pos],
                    .line = start_line,
                    .column = start_col,
                };
            }
        }

        // Multi-char operators
        if (c == '!' and self.peekAhead(1) == '=') {
            _ = self.advance();
            _ = self.advance();
            return .{ .kind = .bang_eq, .text = "!=", .line = start_line, .column = start_col };
        }

        if (c == '~' and self.peekAhead(1) == '=') {
            _ = self.advance();
            _ = self.advance();
            return .{ .kind = .tilde_eq, .text = "~=", .line = start_line, .column = start_col };
        }

        if (c == '=' and self.peekAhead(1) == '=') {
            _ = self.advance();
            _ = self.advance();
            return .{ .kind = .eq_eq, .text = "==", .line = start_line, .column = start_col };
        }

        if (c == ':' and self.peekAhead(1) == '=') {
            _ = self.advance();
            _ = self.advance();
            return .{ .kind = .colon_eq, .text = ":=", .line = start_line, .column = start_col };
        }

        // Newline
        if (c == '\n') {
            _ = self.advance();
            return .{ .kind = .newline, .text = "\n", .line = start_line, .column = start_col };
        }

        // String literal
        if (c == '"') {
            const text = self.readString();
            return .{ .kind = .string, .text = text, .line = start_line, .column = start_col };
        }

        // Number
        if (std.ascii.isDigit(c)) {
            const text = self.readNumber(start_pos);
            return .{ .kind = .number, .text = text, .line = start_line, .column = start_col };
        }

        // Polarity prefix (+/-)
        if (c == '+' or c == '-') {
            _ = self.advance();
            if (self.peek()) |next| {
                if (std.ascii.isAlphabetic(next)) {
                    const text = self.readIdentifier(start_pos);
                    return .{ .kind = .symbol, .text = text, .line = start_line, .column = start_col };
                }
            }
            // Just the operator alone
            return .{ .kind = .symbol, .text = self.source[start_pos..self.pos], .line = start_line, .column = start_col };
        }

        // Identifier or keyword
        if (std.ascii.isAlphabetic(c)) {
            const text = self.readIdentifier(start_pos);
            if (isUppercase(c)) {
                return .{ .kind = .variable, .text = text, .line = start_line, .column = start_col };
            } else {
                const kind = classifyKeyword(text);
                return .{ .kind = kind, .text = text, .line = start_line, .column = start_col };
            }
        }

        // Invalid character
        _ = self.advance();
        return .{ .kind = .invalid, .text = self.source[start_pos..self.pos], .line = start_line, .column = start_col };
    }

    /// Tokenize entire source
    pub fn tokenize(self: *Self, allocator: std.mem.Allocator) ![]Token {
        var tokens = std.ArrayListUnmanaged(Token){};
        defer tokens.deinit(allocator);
        while (true) {
            const tok = self.nextToken();
            try tokens.append(allocator, tok);
            if (tok.kind == .eof) break;
        }
        return try tokens.toOwnedSlice(allocator);
    }
};

// ============================================================================
// Tests
// ============================================================================

test "lex basic tokens" {
    var lexer = Lexer.init("(def foo [X])");
    var tokens = std.ArrayListUnmanaged(Token){};
    defer tokens.deinit(std.testing.allocator);

    while (true) {
        const tok = lexer.nextToken();
        try tokens.append(std.testing.allocator, tok);
        if (tok.kind == .eof) break;
    }

    try std.testing.expectEqual(@as(usize, 8), tokens.items.len);
    try std.testing.expectEqual(TokenKind.lparen, tokens.items[0].kind);
    try std.testing.expectEqual(TokenKind.kw_def, tokens.items[1].kind);
    try std.testing.expectEqual(TokenKind.symbol, tokens.items[2].kind);
    try std.testing.expectEqual(TokenKind.lbracket, tokens.items[3].kind);
    try std.testing.expectEqual(TokenKind.variable, tokens.items[4].kind);
    try std.testing.expectEqual(TokenKind.rbracket, tokens.items[5].kind);
    try std.testing.expectEqual(TokenKind.rparen, tokens.items[6].kind);
}

test "lex polarity" {
    var lexer = Lexer.init("+foo -bar");

    const tok1 = lexer.nextToken();
    try std.testing.expectEqual(TokenKind.symbol, tok1.kind);
    try std.testing.expectEqualStrings("+foo", tok1.text);

    const tok2 = lexer.nextToken();
    try std.testing.expectEqual(TokenKind.symbol, tok2.kind);
    try std.testing.expectEqualStrings("-bar", tok2.text);
}

test "lex string" {
    var lexer = Lexer.init("\"hello world\"");
    const tok = lexer.nextToken();
    try std.testing.expectEqual(TokenKind.string, tok.kind);
    try std.testing.expectEqualStrings("\"hello world\"", tok.text);
}

test "lex comment" {
    var lexer = Lexer.init("foo ' this is a comment\nbar");
    const tok1 = lexer.nextToken();
    try std.testing.expectEqualStrings("foo", tok1.text);
    const tok2 = lexer.nextToken();
    try std.testing.expectEqual(TokenKind.newline, tok2.kind);
    const tok3 = lexer.nextToken();
    try std.testing.expectEqualStrings("bar", tok3.text);
}
