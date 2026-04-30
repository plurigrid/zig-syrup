//! SET Card Game CLI — JSON-line protocol for Emacs comint interface
//!
//! Protocol (one JSON object per line on stdin, one per line on stdout):
//!   -> {"cmd":"deal","n":12,"seed":1069}
//!   -> {"cmd":"find_sets"}
//!   -> {"cmd":"is_set","indices":[0,1,2]}
//!   -> {"cmd":"evolve","generations":100,"seed":1069}
//!   -> {"cmd":"cap_search","restarts":50,"seed":1069}
//!   -> {"cmd":"mobius","card_idx":0}
//!   -> {"cmd":"deck"}
//!   -> {"cmd":"quit"}

const std = @import("std");
const set = @import("set_game");

fn out(bytes: []const u8) void {
    var off: usize = 0;
    while (off < bytes.len) {
        const n = std.c.write(std.c.STDOUT_FILENO, bytes.ptr + off, bytes.len - off);
        if (n <= 0) break;
        off += @intCast(n);
    }
}

fn outFmt(comptime fmt: []const u8, args: anytype) void {
    var buf: [8192]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch return;
    out(s);
}

fn stdinRead(buf: []u8) usize {
    const n = std.c.read(std.c.STDIN_FILENO, buf.ptr, buf.len);
    if (n < 0) return 0;
    return @intCast(n);
}

const Card = set.Card;
const Board = set.Board;
const Arena = set.Arena;
const CapSearch = set.CapSearch;
const DECK = set.DECK;
const isSet = set.isSet;

var current_board: Board = .{ .cards = undefined, .len = 0 };

fn writeCard(card: Card) void {
    outFmt("{{\"raw\":{d},\"color\":{d},\"shape\":{d},\"number\":{d},\"shading\":{d}}}", .{
        card.raw, card.color(), card.shape(), card.number(), card.shading(),
    });
}

fn writeCardArray(cards: []const Card) void {
    out("[");
    for (cards, 0..) |card, i| {
        if (i > 0) out(",");
        writeCard(card);
    }
    out("]");
}

fn handleLine(line: []const u8) bool {
    const cmd = extractString(line, "\"cmd\"") orelse {
        out("{\"ok\":false,\"error\":\"missing cmd\"}\n");
        return true;
    };

    if (std.mem.eql(u8, cmd, "quit")) {
        out("{\"ok\":true,\"bye\":true}\n");
        return false;
    }

    if (std.mem.eql(u8, cmd, "deal")) {
        const n = extractInt(line, "\"n\"") orelse 12;
        const seed = extractInt(line, "\"seed\"") orelse 1069;
        var rng = set.Rng.init(@intCast(seed));
        current_board = Board.deal(&rng, @intCast(@min(n, 21)));
        outFmt("{{\"ok\":true,\"len\":{d},\"cards\":", .{current_board.len});
        writeCardArray(current_board.cards[0..current_board.len]);
        out("}\n");
        return true;
    }

    if (std.mem.eql(u8, cmd, "find_sets")) {
        const result = current_board.findAllSets();
        outFmt("{{\"ok\":true,\"count\":{d},\"sets\":[", .{result.count});
        for (0..result.count) |i| {
            if (i > 0) out(",");
            outFmt("[{d},{d},{d}]", .{ result.sets[i].i, result.sets[i].j, result.sets[i].k });
        }
        out("]}\n");
        return true;
    }

    if (std.mem.eql(u8, cmd, "is_set")) {
        const indices = extractIntArray(line, "\"indices\"");
        if (indices.len >= 3 and indices.items[0] < current_board.len and
            indices.items[1] < current_board.len and indices.items[2] < current_board.len)
        {
            const a = current_board.cards[indices.items[0]];
            const b = current_board.cards[indices.items[1]];
            const c = current_board.cards[indices.items[2]];
            const valid = isSet(a, b, c);
            outFmt("{{\"ok\":true,\"is_set\":{s}}}\n", .{if (valid) "true" else "false"});
        } else {
            out("{\"ok\":false,\"error\":\"need 3 valid indices\"}\n");
        }
        return true;
    }

    if (std.mem.eql(u8, cmd, "evolve")) {
        const gens = extractInt(line, "\"generations\"") orelse 100;
        const seed = extractInt(line, "\"seed\"") orelse 1069;
        var arena = Arena.init(@intCast(seed));
        arena.run(@intCast(@min(gens, 10000)));
        const b = arena.best();
        outFmt("{{\"ok\":true,\"generation\":{d},\"best_fitness\":{d},\"best\":{{\"scan_order\":{d},\"group_threshold\":{d},\"switch_after\":{d},\"depth_limit\":{d}}}}}\n", .{
            arena.generation,
            @as(u32, @intFromFloat(arena.best_fitness * 100)),
            @intFromEnum(b.scan_order),
            b.group_threshold,
            b.switch_after,
            b.depth_limit,
        });
        return true;
    }

    if (std.mem.eql(u8, cmd, "cap_search")) {
        const restarts_n = extractInt(line, "\"restarts\"") orelse 50;
        const seed = extractInt(line, "\"seed\"") orelse 1069;
        var search = CapSearch.init();
        var rng = set.Rng.init(@intCast(seed));
        var i: u32 = 0;
        while (i < @as(u32, @intCast(@min(restarts_n, 1000)))) : (i += 1) {
            const cap = CapSearch.greedyCap(&rng);
            if (cap.len > search.best_size) {
                search.best_size = cap.len;
                search.best_cards = cap.cards;
            }
            search.nodes_visited += 1;
        }
        outFmt("{{\"ok\":true,\"best_size\":{d},\"nodes\":{d},\"cards\":", .{
            search.best_size, search.nodes_visited,
        });
        writeCardArray(search.best_cards[0..search.best_size]);
        out("}\n");
        return true;
    }

    if (std.mem.eql(u8, cmd, "mobius")) {
        const card_idx = extractInt(line, "\"card_idx\"") orelse 0;
        if (card_idx >= 0 and card_idx < current_board.len) {
            const target = current_board.cards[@intCast(card_idx)];
            var zeta: [16]i32 = undefined;
            for (0..16) |mask| {
                zeta[mask] = @intCast(set.countMatching(&current_board, target, @intCast(mask)));
            }
            const mu_count = set.mobiusCount(&current_board, target);
            outFmt("{{\"ok\":true,\"card_idx\":{d},\"mu_count\":{d},\"zeta\":[", .{ card_idx, mu_count });
            for (0..16) |i| {
                if (i > 0) out(",");
                outFmt("{d}", .{zeta[i]});
            }
            out("]}\n");
        } else {
            out("{\"ok\":false,\"error\":\"card_idx out of range\"}\n");
        }
        return true;
    }

    if (std.mem.eql(u8, cmd, "deck")) {
        out("{\"ok\":true,\"size\":81,\"cards\":");
        writeCardArray(&DECK);
        out("}\n");
        return true;
    }

    out("{\"ok\":false,\"error\":\"unknown cmd\"}\n");
    return true;
}

fn extractString(json: []const u8, key: []const u8) ?[]const u8 {
    const pos = std.mem.indexOf(u8, json, key) orelse return null;
    const after_key = json[pos + key.len ..];
    var i: usize = 0;
    while (i < after_key.len and (after_key[i] == ':' or after_key[i] == ' ')) : (i += 1) {}
    if (i >= after_key.len or after_key[i] != '"') return null;
    i += 1;
    const start = i;
    while (i < after_key.len and after_key[i] != '"') : (i += 1) {}
    return after_key[start..i];
}

fn extractInt(json: []const u8, key: []const u8) ?i64 {
    const pos = std.mem.indexOf(u8, json, key) orelse return null;
    const after_key = json[pos + key.len ..];
    var i: usize = 0;
    while (i < after_key.len and (after_key[i] == ':' or after_key[i] == ' ')) : (i += 1) {}
    if (i >= after_key.len) return null;
    const neg = after_key[i] == '-';
    if (neg) i += 1;
    var val: i64 = 0;
    var found_digit = false;
    while (i < after_key.len and after_key[i] >= '0' and after_key[i] <= '9') : (i += 1) {
        val = val * 10 + @as(i64, after_key[i] - '0');
        found_digit = true;
    }
    if (!found_digit) return null;
    return if (neg) -val else val;
}

const IntList = struct {
    items: [64]u8,
    len: usize,
};

fn extractIntArray(json: []const u8, key: []const u8) IntList {
    var result = IntList{ .items = undefined, .len = 0 };
    const pos = std.mem.indexOf(u8, json, key) orelse return result;
    const after_key = json[pos + key.len ..];
    var i: usize = 0;
    while (i < after_key.len and after_key[i] != '[') : (i += 1) {}
    i += 1;
    while (i < after_key.len and after_key[i] != ']') {
        while (i < after_key.len and (after_key[i] == ',' or after_key[i] == ' ')) : (i += 1) {}
        if (i >= after_key.len or after_key[i] == ']') break;
        var val: u8 = 0;
        while (i < after_key.len and after_key[i] >= '0' and after_key[i] <= '9') : (i += 1) {
            val = val * 10 + (after_key[i] - '0');
        }
        if (result.len < 64) {
            result.items[result.len] = val;
            result.len += 1;
        }
    }
    return result;
}

pub fn main() void {
    out("{\"ready\":true,\"version\":\"0.1.0\",\"deck_size\":81}\n");

    var buf: [4096]u8 = undefined;
    var pos: usize = 0;
    while (true) {
        const n = stdinRead(buf[pos..]);
        if (n == 0) break;
        pos += n;
        while (std.mem.indexOf(u8, buf[0..pos], "\n")) |nl| {
            const line = buf[0..nl];
            if (line.len > 0) {
                if (!handleLine(line)) return;
            }
            const rest = pos - nl - 1;
            if (rest > 0) std.mem.copyForwards(u8, buf[0..rest], buf[nl + 1 .. pos]);
            pos = rest;
        }
    }
}
