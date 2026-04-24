// sexp.zig: S-expression parser, printer, and evaluator for Gay color system
// Zig translation of Gay.jl/src/sexp.jl
//
// Supported forms:
//   (+ 1 2)              — arithmetic
//   (define-cell name)   — propagator cell definition
//   (let [x 1 y 2] body) — let bindings (parsed, not evaluated)
//   (if cond then else)  — conditionals
//   {:key val}           — dictionaries
//   [a b c]              — vectors
//   'symbol              — quoted symbols
//   "string"             — strings with escape sequences
//   ; comment            — line comments
//
// Design: Parse to SExp AST. No eval (Zig is not Julia).
// Gay-colored pretty printing via SplitMix64 chromatic hash.

const std = @import("std");
const splitmix = @import("splitmix.zig");
const Allocator = std.mem.Allocator;

// ═══════════════════════════════════════════════════════════════════════════════
// AST Node Types
// ═══════════════════════════════════════════════════════════════════════════════

pub const SExp = union(enum) {
    atom: []const u8,
    number_int: i64,
    number_float: f64,
    string: []const u8,
    keyword: []const u8,
    boolean: bool,
    nil,
    list: []const SExp,
    vector: []const SExp,
    dict: []const DictPair,
    quote: *const SExp,

    pub const DictPair = struct {
        key: SExp,
        value: SExp,
    };

    pub fn deinit(self: SExp, allocator: Allocator) void {
        switch (self) {
            .list => |items| {
                for (items) |item| item.deinit(allocator);
                allocator.free(items);
            },
            .vector => |items| {
                for (items) |item| item.deinit(allocator);
                allocator.free(items);
            },
            .dict => |pairs| {
                for (pairs) |pair| {
                    pair.key.deinit(allocator);
                    pair.value.deinit(allocator);
                }
                allocator.free(pairs);
            },
            .quote => |inner| {
                inner.deinit(allocator);
                const ptr: *SExp = @ptrCast(@constCast(inner));
                allocator.destroy(ptr);
            },
            .atom => |s| allocator.free(s),
            .string => |s| allocator.free(s),
            .keyword => |s| allocator.free(s),
            else => {},
        }
    }

    pub fn eql(a: SExp, b: SExp) bool {
        const tag_a: u8 = @intFromEnum(a);
        const tag_b: u8 = @intFromEnum(b);
        if (tag_a != tag_b) return false;
        return switch (a) {
            .atom => |s| std.mem.eql(u8, s, b.atom),
            .number_int => |v| v == b.number_int,
            .number_float => |v| v == b.number_float,
            .string => |s| std.mem.eql(u8, s, b.string),
            .keyword => |s| std.mem.eql(u8, s, b.keyword),
            .boolean => |v| v == b.boolean,
            .nil => true,
            .list => |items| {
                if (items.len != b.list.len) return false;
                for (items, b.list) |x, y| {
                    if (!x.eql(y)) return false;
                }
                return true;
            },
            .vector => |items| {
                if (items.len != b.vector.len) return false;
                for (items, b.vector) |x, y| {
                    if (!x.eql(y)) return false;
                }
                return true;
            },
            .dict => |pairs| {
                if (pairs.len != b.dict.len) return false;
                for (pairs, b.dict) |x, y| {
                    if (!x.key.eql(y.key) or !x.value.eql(y.value)) return false;
                }
                return true;
            },
            .quote => |inner| inner.eql(b.quote.*),
        };
    }
};

// ═══════════════════════════════════════════════════════════════════════════════
// Token Types
// ═══════════════════════════════════════════════════════════════════════════════

const TokenType = enum {
    lparen,
    rparen,
    lbracket,
    rbracket,
    lbrace,
    rbrace,
    quote_mark,
    symbol,
    number_int,
    number_float,
    string,
    keyword,
    bool_true,
    bool_false,
    nil,
};

const Token = struct {
    type: TokenType,
    text: []const u8,
    pos: usize,
};

// ═══════════════════════════════════════════════════════════════════════════════
// Tokenizer
// ═══════════════════════════════════════════════════════════════════════════════

pub const TokenizeError = error{
    UnterminatedString,
    UnexpectedCharacter,
    OutOfMemory,
};

pub fn tokenize(input: []const u8, allocator: Allocator) TokenizeError![]Token {
    var tokens: std.ArrayList(Token) = .{};
    errdefer tokens.deinit(allocator);

    var i: usize = 0;
    while (i < input.len) {
        const c = input[i];

        // Whitespace
        if (std.ascii.isWhitespace(c)) {
            i += 1;
            continue;
        }

        // Comments
        if (c == ';') {
            while (i < input.len and input[i] != '\n') i += 1;
            continue;
        }

        // Single-char delimiters
        if (c == '(') {
            try tokens.append(allocator, .{ .type = .lparen, .text = input[i .. i + 1], .pos = i });
            i += 1;
        } else if (c == ')') {
            try tokens.append(allocator, .{ .type = .rparen, .text = input[i .. i + 1], .pos = i });
            i += 1;
        } else if (c == '[') {
            try tokens.append(allocator, .{ .type = .lbracket, .text = input[i .. i + 1], .pos = i });
            i += 1;
        } else if (c == ']') {
            try tokens.append(allocator, .{ .type = .rbracket, .text = input[i .. i + 1], .pos = i });
            i += 1;
        } else if (c == '{') {
            try tokens.append(allocator, .{ .type = .lbrace, .text = input[i .. i + 1], .pos = i });
            i += 1;
        } else if (c == '}') {
            try tokens.append(allocator, .{ .type = .rbrace, .text = input[i .. i + 1], .pos = i });
            i += 1;
        } else if (c == '\'') {
            try tokens.append(allocator, .{ .type = .quote_mark, .text = input[i .. i + 1], .pos = i });
            i += 1;
        } else if (c == '"') {
            // String literal — we store the raw span including quotes for later unescape
            const start = i;
            i += 1;
            while (i < input.len and input[i] != '"') {
                if (input[i] == '\\' and i + 1 < input.len) i += 1;
                i += 1;
            }
            if (i >= input.len) return error.UnterminatedString;
            i += 1; // closing "
            try tokens.append(allocator, .{ .type = .string, .text = input[start..i], .pos = start });
        } else if (c == ':') {
            // Keyword
            const start = i;
            i += 1;
            while (i < input.len and (std.ascii.isAlphanumeric(input[i]) or input[i] == '_' or input[i] == '-' or input[i] == '!' or input[i] == '?')) i += 1;
            try tokens.append(allocator, .{ .type = .keyword, .text = input[start + 1 .. i], .pos = start });
        } else if (std.ascii.isDigit(c) or (c == '-' and i + 1 < input.len and std.ascii.isDigit(input[i + 1]))) {
            // Number
            const start = i;
            if (c == '-') i += 1;
            while (i < input.len and std.ascii.isDigit(input[i])) i += 1;
            var is_float = false;
            if (i < input.len and input[i] == '.' and i + 1 < input.len and std.ascii.isDigit(input[i + 1])) {
                is_float = true;
                i += 1;
                while (i < input.len and std.ascii.isDigit(input[i])) i += 1;
                if (i < input.len and (input[i] == 'e' or input[i] == 'E')) {
                    i += 1;
                    if (i < input.len and (input[i] == '+' or input[i] == '-')) i += 1;
                    while (i < input.len and std.ascii.isDigit(input[i])) i += 1;
                }
            }
            const tt: TokenType = if (is_float) .number_float else .number_int;
            try tokens.append(allocator, .{ .type = tt, .text = input[start..i], .pos = start });
        } else if (isSymbolStart(c)) {
            const start = i;
            while (i < input.len and isSymbolContinue(input[i])) i += 1;
            const text = input[start..i];
            const tt: TokenType = if (std.mem.eql(u8, text, "true"))
                .bool_true
            else if (std.mem.eql(u8, text, "false"))
                .bool_false
            else if (std.mem.eql(u8, text, "nil"))
                .nil
            else
                .symbol;
            try tokens.append(allocator, .{ .type = tt, .text = text, .pos = start });
        } else {
            return error.UnexpectedCharacter;
        }
    }

    return tokens.toOwnedSlice(allocator);
}

fn isSymbolStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_' or c == '!' or c == '?' or c == '*' or c == '+' or c == '-' or c == '/' or c == '<' or c == '>' or c == '=' or c == '&';
}

fn isSymbolContinue(c: u8) bool {
    return isSymbolStart(c) or std.ascii.isDigit(c) or c == '.';
}

// ═══════════════════════════════════════════════════════════════════════════════
// Parser: Tokens -> SExp
// ═══════════════════════════════════════════════════════════════════════════════

pub const ParseError = error{
    UnexpectedEof,
    UnclosedParen,
    UnclosedBracket,
    UnclosedBrace,
    UnexpectedToken,
    InvalidNumber,
    OutOfMemory,
};

pub fn parse(input: []const u8, allocator: Allocator) (TokenizeError || ParseError)!SExp {
    const tokens = try tokenize(input, allocator);
    defer allocator.free(tokens);
    var pos: usize = 0;
    return parseSexp(tokens, &pos, allocator);
}

fn parseSexp(tokens: []const Token, pos: *usize, allocator: Allocator) ParseError!SExp {
    if (pos.* >= tokens.len) return error.UnexpectedEof;
    const tok = tokens[pos.*];

    switch (tok.type) {
        .lparen => {
            pos.* += 1;
            var items: std.ArrayList(SExp) = .{};
            errdefer {
                for (items.items) |item| item.deinit(allocator);
                items.deinit(allocator);
            }
            while (pos.* < tokens.len and tokens[pos.*].type != .rparen) {
                try items.append(allocator, try parseSexp(tokens, pos, allocator));
            }
            if (pos.* >= tokens.len) return error.UnclosedParen;
            pos.* += 1;
            return SExp{ .list = try items.toOwnedSlice(allocator) };
        },
        .lbracket => {
            pos.* += 1;
            var items: std.ArrayList(SExp) = .{};
            errdefer {
                for (items.items) |item| item.deinit(allocator);
                items.deinit(allocator);
            }
            while (pos.* < tokens.len and tokens[pos.*].type != .rbracket) {
                try items.append(allocator, try parseSexp(tokens, pos, allocator));
            }
            if (pos.* >= tokens.len) return error.UnclosedBracket;
            pos.* += 1;
            return SExp{ .vector = try items.toOwnedSlice(allocator) };
        },
        .lbrace => {
            pos.* += 1;
            var pairs: std.ArrayList(SExp.DictPair) = .{};
            errdefer {
                for (pairs.items) |pair| {
                    pair.key.deinit(allocator);
                    pair.value.deinit(allocator);
                }
                pairs.deinit(allocator);
            }
            while (pos.* < tokens.len and tokens[pos.*].type != .rbrace) {
                const key = try parseSexp(tokens, pos, allocator);
                if (pos.* >= tokens.len or tokens[pos.*].type == .rbrace) {
                    key.deinit(allocator);
                    return error.UnexpectedEof;
                }
                const val = try parseSexp(tokens, pos, allocator);
                try pairs.append(allocator, .{ .key = key, .value = val });
            }
            if (pos.* >= tokens.len) return error.UnclosedBrace;
            pos.* += 1;
            return SExp{ .dict = try pairs.toOwnedSlice(allocator) };
        },
        .quote_mark => {
            pos.* += 1;
            const inner = try allocator.create(SExp);
            inner.* = try parseSexp(tokens, pos, allocator);
            return SExp{ .quote = inner };
        },
        .symbol => {
            pos.* += 1;
            const duped = try allocator.dupe(u8, tok.text);
            return SExp{ .atom = duped };
        },
        .number_int => {
            pos.* += 1;
            const v = std.fmt.parseInt(i64, tok.text, 10) catch return error.InvalidNumber;
            return SExp{ .number_int = v };
        },
        .number_float => {
            pos.* += 1;
            const v = std.fmt.parseFloat(f64, tok.text) catch return error.InvalidNumber;
            return SExp{ .number_float = v };
        },
        .string => {
            pos.* += 1;
            // Unescape: strip quotes and handle \n \t \\ \"
            const raw = tok.text[1 .. tok.text.len - 1];
            const unescaped = try unescapeString(raw, allocator);
            return SExp{ .string = unescaped };
        },
        .keyword => {
            pos.* += 1;
            const duped = try allocator.dupe(u8, tok.text);
            return SExp{ .keyword = duped };
        },
        .bool_true => {
            pos.* += 1;
            return SExp{ .boolean = true };
        },
        .bool_false => {
            pos.* += 1;
            return SExp{ .boolean = false };
        },
        .nil => {
            pos.* += 1;
            return SExp{ .nil = {} };
        },
        else => return error.UnexpectedToken,
    }
}

fn unescapeString(raw: []const u8, allocator: Allocator) ![]u8 {
    var buf: std.ArrayList(u8) = .{};
    errdefer buf.deinit(allocator);
    var i: usize = 0;
    while (i < raw.len) {
        if (raw[i] == '\\' and i + 1 < raw.len) {
            i += 1;
            switch (raw[i]) {
                'n' => try buf.append(allocator, '\n'),
                't' => try buf.append(allocator, '\t'),
                'e' => try buf.append(allocator, 0x1b),
                '"' => try buf.append(allocator, '"'),
                '\\' => try buf.append(allocator, '\\'),
                else => {
                    try buf.append(allocator, '\\');
                    try buf.append(allocator, raw[i]);
                },
            }
        } else {
            try buf.append(allocator, raw[i]);
        }
        i += 1;
    }
    return buf.toOwnedSlice(allocator);
}

// ═══════════════════════════════════════════════════════════════════════════════
// Printer: SExp -> String
// ═══════════════════════════════════════════════════════════════════════════════

pub fn print(sexp: SExp, allocator: Allocator) ![]u8 {
    var buf: std.ArrayList(u8) = .{};
    try printInto(sexp, &buf, allocator);
    return buf.toOwnedSlice(allocator);
}

fn printInto(sexp: SExp, buf: *std.ArrayList(u8), allocator: Allocator) !void {
    switch (sexp) {
        .atom => |s| try buf.appendSlice(allocator, s),
        .number_int => |v| {
            var tmp: [32]u8 = undefined;
            const s = std.fmt.bufPrint(&tmp, "{d}", .{v}) catch unreachable;
            try buf.appendSlice(allocator, s);
        },
        .number_float => |v| {
            var tmp: [64]u8 = undefined;
            const s = std.fmt.bufPrint(&tmp, "{d}", .{v}) catch unreachable;
            try buf.appendSlice(allocator, s);
        },
        .string => |s| {
            try buf.append(allocator, '"');
            for (s) |c| {
                switch (c) {
                    '\n' => try buf.appendSlice(allocator, "\\n"),
                    '\t' => try buf.appendSlice(allocator, "\\t"),
                    '"' => try buf.appendSlice(allocator, "\\\""),
                    '\\' => try buf.appendSlice(allocator, "\\\\"),
                    else => try buf.append(allocator, c),
                }
            }
            try buf.append(allocator, '"');
        },
        .keyword => |s| {
            try buf.append(allocator, ':');
            try buf.appendSlice(allocator, s);
        },
        .boolean => |v| try buf.appendSlice(allocator, if (v) "true" else "false"),
        .nil => try buf.appendSlice(allocator, "nil"),
        .list => |items| {
            try buf.append(allocator, '(');
            for (items, 0..) |item, idx| {
                if (idx > 0) try buf.append(allocator, ' ');
                try printInto(item, buf, allocator);
            }
            try buf.append(allocator, ')');
        },
        .vector => |items| {
            try buf.append(allocator, '[');
            for (items, 0..) |item, idx| {
                if (idx > 0) try buf.append(allocator, ' ');
                try printInto(item, buf, allocator);
            }
            try buf.append(allocator, ']');
        },
        .dict => |pairs| {
            try buf.append(allocator, '{');
            for (pairs, 0..) |pair, idx| {
                if (idx > 0) try buf.append(allocator, ' ');
                try printInto(pair.key, buf, allocator);
                try buf.append(allocator, ' ');
                try printInto(pair.value, buf, allocator);
            }
            try buf.append(allocator, '}');
        },
        .quote => |inner| {
            try buf.append(allocator, '\'');
            try printInto(inner.*, buf, allocator);
        },
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// Gay-Colored Pretty Printer
// ═══════════════════════════════════════════════════════════════════════════════
// Each AST node type gets a deterministic ANSI color via SplitMix64.
// Rainbow pride palette: 6 colors cycled by depth.

const RAINBOW_COLORS = [_][]const u8{
    "\x1b[38;5;196m", // red
    "\x1b[38;5;208m", // orange
    "\x1b[38;5;226m", // yellow
    "\x1b[38;5;46m", // green
    "\x1b[38;5;21m", // blue
    "\x1b[38;5;129m", // purple
};
const RESET = "\x1b[0m";

pub fn prettyPrint(sexp: SExp, allocator: Allocator) ![]u8 {
    var buf: std.ArrayList(u8) = .{};
    try prettyPrintInto(sexp, &buf, 0, allocator);
    try buf.appendSlice(allocator, RESET);
    return buf.toOwnedSlice(allocator);
}

fn prettyPrintInto(sexp: SExp, buf: *std.ArrayList(u8), depth: usize, allocator: Allocator) !void {
    const color = RAINBOW_COLORS[depth % RAINBOW_COLORS.len];

    switch (sexp) {
        .atom => |s| {
            // Color atom by its chromatic hash
            const hash = chromaticColorIndex(s);
            const atom_color = RAINBOW_COLORS[hash % RAINBOW_COLORS.len];
            try buf.appendSlice(allocator, atom_color);
            try buf.appendSlice(allocator, s);
        },
        .number_int => |v| {
            try buf.appendSlice(allocator, "\x1b[38;5;51m"); // cyan for numbers
            var tmp: [32]u8 = undefined;
            const s = std.fmt.bufPrint(&tmp, "{d}", .{v}) catch unreachable;
            try buf.appendSlice(allocator, s);
        },
        .number_float => |v| {
            try buf.appendSlice(allocator, "\x1b[38;5;51m");
            var tmp: [64]u8 = undefined;
            const s = std.fmt.bufPrint(&tmp, "{d}", .{v}) catch unreachable;
            try buf.appendSlice(allocator, s);
        },
        .string => |s| {
            try buf.appendSlice(allocator, "\x1b[38;5;214m"); // warm orange for strings
            try buf.append(allocator, '"');
            try buf.appendSlice(allocator, s);
            try buf.append(allocator, '"');
        },
        .keyword => |s| {
            try buf.appendSlice(allocator, "\x1b[38;5;169m"); // pink for keywords
            try buf.append(allocator, ':');
            try buf.appendSlice(allocator, s);
        },
        .boolean => |v| {
            try buf.appendSlice(allocator, "\x1b[38;5;118m"); // bright green for booleans
            try buf.appendSlice(allocator, if (v) "true" else "false");
        },
        .nil => {
            try buf.appendSlice(allocator, "\x1b[38;5;243m"); // gray for nil
            try buf.appendSlice(allocator, "nil");
        },
        .list => |items| {
            try buf.appendSlice(allocator, color);
            try buf.append(allocator, '(');
            for (items, 0..) |item, idx| {
                if (idx > 0) try buf.append(allocator, ' ');
                try prettyPrintInto(item, buf, depth + 1, allocator);
            }
            try buf.appendSlice(allocator, color);
            try buf.append(allocator, ')');
        },
        .vector => |items| {
            try buf.appendSlice(allocator, color);
            try buf.append(allocator, '[');
            for (items, 0..) |item, idx| {
                if (idx > 0) try buf.append(allocator, ' ');
                try prettyPrintInto(item, buf, depth + 1, allocator);
            }
            try buf.appendSlice(allocator, color);
            try buf.append(allocator, ']');
        },
        .dict => |pairs| {
            try buf.appendSlice(allocator, color);
            try buf.append(allocator, '{');
            for (pairs, 0..) |pair, idx| {
                if (idx > 0) try buf.append(allocator, ' ');
                try prettyPrintInto(pair.key, buf, depth + 1, allocator);
                try buf.append(allocator, ' ');
                try prettyPrintInto(pair.value, buf, depth + 1, allocator);
            }
            try buf.appendSlice(allocator, color);
            try buf.append(allocator, '}');
        },
        .quote => |inner| {
            try buf.appendSlice(allocator, color);
            try buf.append(allocator, '\'');
            try prettyPrintInto(inner.*, buf, depth + 1, allocator);
        },
    }
}

fn chromaticColorIndex(name: []const u8) usize {
    var seed: u64 = splitmix.GAY_SEED;
    for (name) |c| {
        seed = splitmix.splitmix64(seed +% @as(u64, c));
    }
    return @as(usize, @truncate(seed));
}

// ═══════════════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════════════

test "parse atom" {
    const allocator = std.testing.allocator;
    const sexp = try parse("hello", allocator);
    defer sexp.deinit(allocator);
    try std.testing.expect(sexp == .atom);
    try std.testing.expectEqualStrings("hello", sexp.atom);
}

test "parse integer" {
    const allocator = std.testing.allocator;
    const sexp = try parse("42", allocator);
    defer sexp.deinit(allocator);
    try std.testing.expect(sexp == .number_int);
    try std.testing.expectEqual(@as(i64, 42), sexp.number_int);
}

test "parse negative integer" {
    const allocator = std.testing.allocator;
    const sexp = try parse("-7", allocator);
    defer sexp.deinit(allocator);
    try std.testing.expectEqual(@as(i64, -7), sexp.number_int);
}

test "parse float" {
    const allocator = std.testing.allocator;
    const sexp = try parse("3.14", allocator);
    defer sexp.deinit(allocator);
    try std.testing.expect(sexp == .number_float);
    try std.testing.expect(@abs(sexp.number_float - 3.14) < 1e-10);
}

test "parse string with escapes" {
    const allocator = std.testing.allocator;
    const sexp = try parse("\"hello\\nworld\"", allocator);
    defer sexp.deinit(allocator);
    try std.testing.expect(sexp == .string);
    try std.testing.expectEqualStrings("hello\nworld", sexp.string);
}

test "parse list" {
    const allocator = std.testing.allocator;
    const sexp = try parse("(+ 1 2)", allocator);
    defer sexp.deinit(allocator);
    try std.testing.expect(sexp == .list);
    try std.testing.expectEqual(@as(usize, 3), sexp.list.len);
    try std.testing.expectEqualStrings("+", sexp.list[0].atom);
    try std.testing.expectEqual(@as(i64, 1), sexp.list[1].number_int);
    try std.testing.expectEqual(@as(i64, 2), sexp.list[2].number_int);
}

test "parse vector" {
    const allocator = std.testing.allocator;
    const sexp = try parse("[a b c]", allocator);
    defer sexp.deinit(allocator);
    try std.testing.expect(sexp == .vector);
    try std.testing.expectEqual(@as(usize, 3), sexp.vector.len);
}

test "parse dict" {
    const allocator = std.testing.allocator;
    const sexp = try parse("{:x 1 :y 2}", allocator);
    defer sexp.deinit(allocator);
    try std.testing.expect(sexp == .dict);
    try std.testing.expectEqual(@as(usize, 2), sexp.dict.len);
    try std.testing.expectEqualStrings("x", sexp.dict[0].key.keyword);
}

test "parse keyword" {
    const allocator = std.testing.allocator;
    const sexp = try parse(":hello-world", allocator);
    defer sexp.deinit(allocator);
    try std.testing.expect(sexp == .keyword);
    try std.testing.expectEqualStrings("hello-world", sexp.keyword);
}

test "parse quoted symbol" {
    const allocator = std.testing.allocator;
    const sexp = try parse("'foo", allocator);
    defer sexp.deinit(allocator);
    try std.testing.expect(sexp == .quote);
    try std.testing.expectEqualStrings("foo", sexp.quote.atom);
}

test "parse booleans and nil" {
    const allocator = std.testing.allocator;
    const t = try parse("true", allocator);
    defer t.deinit(allocator);
    try std.testing.expect(t == .boolean);
    try std.testing.expect(t.boolean);

    const f = try parse("false", allocator);
    defer f.deinit(allocator);
    try std.testing.expect(!f.boolean);

    const n = try parse("nil", allocator);
    defer n.deinit(allocator);
    try std.testing.expect(n == .nil);
}

test "parse nested list" {
    const allocator = std.testing.allocator;
    const sexp = try parse("(defn add [x y] (+ x y))", allocator);
    defer sexp.deinit(allocator);
    try std.testing.expect(sexp == .list);
    try std.testing.expectEqual(@as(usize, 4), sexp.list.len);
    try std.testing.expect(sexp.list[2] == .vector);
    try std.testing.expect(sexp.list[3] == .list);
}

test "parse comment" {
    const allocator = std.testing.allocator;
    const sexp = try parse("; this is a comment\n42", allocator);
    defer sexp.deinit(allocator);
    try std.testing.expectEqual(@as(i64, 42), sexp.number_int);
}

test "print roundtrip" {
    const allocator = std.testing.allocator;
    const sexp = try parse("(+ 1 2)", allocator);
    defer sexp.deinit(allocator);
    const printed = try print(sexp, allocator);
    defer allocator.free(printed);
    try std.testing.expectEqualStrings("(+ 1 2)", printed);
}

test "print dict roundtrip" {
    const allocator = std.testing.allocator;
    const sexp = try parse("{:x 1 :y 2}", allocator);
    defer sexp.deinit(allocator);
    const printed = try print(sexp, allocator);
    defer allocator.free(printed);
    try std.testing.expectEqualStrings("{:x 1 :y 2}", printed);
}

test "equality" {
    const allocator = std.testing.allocator;
    const a = try parse("(+ 1 2)", allocator);
    defer a.deinit(allocator);
    const b = try parse("(+ 1 2)", allocator);
    defer b.deinit(allocator);
    try std.testing.expect(a.eql(b));
}

test "pretty print produces output" {
    const allocator = std.testing.allocator;
    const sexp = try parse("(defn gay [r g b] (color r g b))", allocator);
    defer sexp.deinit(allocator);
    const pretty = try prettyPrint(sexp, allocator);
    defer allocator.free(pretty);
    // Should contain ANSI escape codes
    try std.testing.expect(std.mem.indexOf(u8, pretty, "\x1b[") != null);
    // Should contain the actual content
    try std.testing.expect(std.mem.indexOf(u8, pretty, "defn") != null);
    try std.testing.expect(std.mem.indexOf(u8, pretty, "gay") != null);
}

test "float with exponent" {
    const allocator = std.testing.allocator;
    const sexp = try parse("1.5e10", allocator);
    defer sexp.deinit(allocator);
    try std.testing.expect(sexp == .number_float);
    try std.testing.expect(@abs(sexp.number_float - 1.5e10) < 1e5);
}

test "unterminated string" {
    const allocator = std.testing.allocator;
    const result = parse("\"hello", allocator);
    try std.testing.expect(result == error.UnterminatedString);
}
