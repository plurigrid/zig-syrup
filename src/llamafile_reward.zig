//! llamafile Local Inference Reward Model
//!
//! Wires a local llamafile instance (OpenAI-compatible API on localhost:8080)
//! into the RL color curriculum as an external reward signal.
//!
//! The LLM acts as a critic/reward model, scoring color palettes for:
//!   - Readability: depth distinction, contrast ratios
//!   - Semantic coherence: similar ops → similar colors
//!   - Aesthetic harmony: perceptual balance
//!   - GF(3) awareness: carry-free verification
//!
//! Architecture (sectorlisp-inspired minimalism):
//!   The prompt is a pure s-expression describing the palette state.
//!   The response is a single float. No chat history, no session state.
//!   Stateless eval/apply — each call is independent, like sectorlisp.
//!
//! Protocol: POST /v1/chat/completions (HTTP/1.1 over TCP)
//! Auth: Bearer no-key (llamafile default)
//! Fallback: hardcoded reward when llamafile unavailable
//!
//! Integration point: color_policy.zig RewardComponents
//!   Before: 4 hardcoded component scores
//!   After:  4 components + LLM critic score (weighted blend)

const std = @import("std");
const net = std.net;
const lux = @import("lux_color");

const Trit = lux.Trit;
const RGB = lux.RGB;

pub const DEFAULT_HOST = "127.0.0.1";
pub const DEFAULT_PORT: u16 = 8090;
pub const MAX_RESPONSE_SIZE: usize = 8192;

// ============================================================================
// Connection
// ============================================================================

pub const Client = struct {
    host: []const u8,
    port: u16,
    timeout_ms: u32,

    pub fn init(host: []const u8, port: u16) Client {
        return .{
            .host = host,
            .port = port,
            .timeout_ms = 5000,
        };
    }

    pub fn initDefault() Client {
        return init(DEFAULT_HOST, DEFAULT_PORT);
    }

    /// Check if llamafile is reachable (fast probe)
    pub fn isAvailable(self: *const Client, allocator: std.mem.Allocator) bool {
        const addr = net.Address.resolveIp(self.host, self.port) catch return false;
        const stream = net.tcpConnectToAddress(addr) catch return false;
        defer stream.close();
        // Send minimal GET to /health or just check TCP handshake
        _ = allocator;
        return true;
    }

    /// Send a chat completion request and return the response content string.
    /// Caller owns returned slice.
    pub fn chatCompletion(
        self: *const Client,
        allocator: std.mem.Allocator,
        system_prompt: []const u8,
        user_prompt: []const u8,
        temperature: f32,
        max_tokens: u32,
    ) ![]u8 {
        // Build JSON body
        const body = try std.fmt.allocPrint(allocator,
            \\{{"model":"LLaMA_CPP","messages":[{{"role":"system","content":"{s}"}},{{"role":"user","content":"{s}"}}],"temperature":{d:.2},"max_tokens":{d}}}
        , .{ system_prompt, user_prompt, temperature, max_tokens });
        defer allocator.free(body);

        // Build HTTP request
        const request = try std.fmt.allocPrint(allocator,
            "POST /v1/chat/completions HTTP/1.1\r\n" ++
                "Host: {s}:{d}\r\n" ++
                "Content-Type: application/json\r\n" ++
                "Content-Length: {d}\r\n" ++
                "Authorization: Bearer no-key\r\n" ++
                "Connection: close\r\n" ++
                "\r\n" ++
                "{s}",
            .{ self.host, self.port, body.len, body },
        );
        defer allocator.free(request);

        // Connect and send
        const addr = try net.Address.resolveIp(self.host, self.port);
        const stream = try net.tcpConnectToAddress(addr);
        defer stream.close();

        try stream.writeAll(request);

        // Read response
        var response_buf: std.ArrayListUnmanaged(u8) = .empty;
        defer response_buf.deinit(allocator);

        var read_buf: [4096]u8 = undefined;
        while (true) {
            const n = stream.read(&read_buf) catch |err| switch (err) {
                error.ConnectionResetByPeer => break,
                else => return err,
            };
            if (n == 0) break;
            try response_buf.appendSlice(allocator, read_buf[0..n]);
            if (response_buf.items.len > MAX_RESPONSE_SIZE) break;
        }

        // Parse HTTP response: skip headers, find JSON body
        const response = response_buf.items;
        const body_start = std.mem.indexOf(u8, response, "\r\n\r\n") orelse
            return error.MalformedResponse;
        const json_body = response[body_start + 4 ..];

        // Extract content from OpenAI response format
        return try extractContent(allocator, json_body);
    }
};

// ============================================================================
// Response Parsing
// ============================================================================

fn extractContent(allocator: std.mem.Allocator, json_body: []const u8) ![]u8 {
    // Find "content":" that is NOT part of "reasoning_content"
    const marker = "\"content\":\"";
    var search_pos: usize = 0;
    while (std.mem.indexOfPos(u8, json_body, search_pos, marker)) |start| {
        // Check if preceded by "reasoning_" — skip if so
        if (start >= 10 and std.mem.eql(u8, json_body[start - 10 .. start], "reasoning_")) {
            search_pos = start + marker.len;
            continue;
        }
        const content_start = start + marker.len;
        // Handle empty content (gemma4 reasoning models may return "")
        if (content_start < json_body.len and json_body[content_start] == '"') {
            // Empty content — try to extract from reasoning_content instead
            const rc_marker = "\"reasoning_content\":\"";
            if (std.mem.indexOf(u8, json_body, rc_marker)) |rc_start| {
                const rc_content_start = rc_start + rc_marker.len;
                // Find closing quote (handle escaped quotes)
                var rc_end = rc_content_start;
                while (rc_end < json_body.len) : (rc_end += 1) {
                    if (json_body[rc_end] == '"' and (rc_end == 0 or json_body[rc_end - 1] != '\\')) break;
                }
                return try allocator.dupe(u8, json_body[rc_content_start..rc_end]);
            }
            return error.NoContentField;
        }
        const content_end = std.mem.indexOfPos(u8, json_body, content_start, "\"") orelse
            return error.UnterminatedContent;
        return try allocator.dupe(u8, json_body[content_start..content_end]);
    }
    return error.NoContentField;
}

// ============================================================================
// Color Critic: palette scoring via LLM
// ============================================================================

pub const PaletteEntry = struct {
    op_name: []const u8,
    trit: Trit,
    color: RGB,
};

pub const CriticScore = struct {
    readability: f32,
    semantic: f32,
    harmony: f32,
    overall: f32,
    raw_response: []const u8,

    pub fn deinit(self: *CriticScore, allocator: std.mem.Allocator) void {
        allocator.free(self.raw_response);
    }
};

const SYSTEM_PROMPT =
    "You are a color palette critic for syntax highlighting. " ++
    "Score palettes on a 0.0-1.0 scale. Respond ONLY with a JSON object: " ++
    "{\"readability\":0.X,\"semantic\":0.X,\"harmony\":0.X,\"overall\":0.X}. " ++
    "Readability: depth levels distinguishable, good contrast. " ++
    "Semantic: related operations have related colors. " ++
    "Harmony: colors work well together perceptually.";

/// Score a color palette using the local llamafile critic.
/// Returns null if llamafile is unavailable (caller falls back to hardcoded).
pub fn scorePalette(
    client: *const Client,
    allocator: std.mem.Allocator,
    entries: []const PaletteEntry,
) ?CriticScore {
    // Format palette as compact description
    var prompt_buf: [2048]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&prompt_buf);
    const w = fbs.writer();
    w.writeAll("Score this s-expression color palette:\n") catch return null;
    for (entries) |e| {
        w.print("  {s} = {s} #{X:0>2}{X:0>2}{X:0>2}\n", .{
            e.op_name,
            @tagName(e.trit),
            e.color.r,
            e.color.g,
            e.color.b,
        }) catch return null;
    }
    w.print("GF(3) trit sum: {d} (mod 3 = {d})\n", .{
        tritSum(entries),
        @mod(tritSum(entries), @as(i32, 3)),
    }) catch return null;
    const prompt = fbs.getWritten();

    // Call llamafile
    const response = client.chatCompletion(
        allocator,
        SYSTEM_PROMPT,
        prompt,
        0.1, // low temperature for consistent scoring
        1500, // gemma4 needs ~1K reasoning tokens before producing JSON
    ) catch return null;

    // Try to parse JSON scores from response
    return parseCriticResponse(response) orelse {
        // If JSON parse fails, try to extract a single float
        const overall = parseFloat(response) orelse 0.5;
        return CriticScore{
            .readability = overall,
            .semantic = overall,
            .harmony = overall,
            .overall = overall,
            .raw_response = response,
        };
    };
}

fn tritSum(entries: []const PaletteEntry) i32 {
    var sum: i32 = 0;
    for (entries) |e| {
        sum += switch (e.trit) {
            .minus => @as(i32, -1),
            .ergodic => 0,
            .plus => 1,
        };
    }
    return sum;
}

fn parseCriticResponse(response: []const u8) ?CriticScore {
    // Look for JSON object in response
    const start = std.mem.indexOf(u8, response, "{") orelse return null;
    const end = std.mem.lastIndexOf(u8, response, "}") orelse return null;
    if (end <= start) return null;
    const json = response[start .. end + 1];

    // Simple field extraction (avoid full JSON parser for robustness)
    const readability = extractJsonFloat(json, "readability") orelse 0.5;
    const semantic = extractJsonFloat(json, "semantic") orelse 0.5;
    const harmony = extractJsonFloat(json, "harmony") orelse 0.5;
    const overall = extractJsonFloat(json, "overall") orelse
        (readability + semantic + harmony) / 3.0;

    return CriticScore{
        .readability = readability,
        .semantic = semantic,
        .harmony = harmony,
        .overall = overall,
        .raw_response = response,
    };
}

fn extractJsonFloat(json: []const u8, key: []const u8) ?f32 {
    // Find "key": and parse the float after it
    var search_buf: [64]u8 = undefined;
    const pattern = std.fmt.bufPrint(&search_buf, "\"{s}\":", .{key}) catch return null;
    const pos = std.mem.indexOf(u8, json, pattern) orelse return null;
    const after = json[pos + pattern.len ..];
    // Skip whitespace
    var i: usize = 0;
    while (i < after.len and (after[i] == ' ' or after[i] == '\t')) : (i += 1) {}
    // Find end of number
    var j = i;
    while (j < after.len and (after[j] == '.' or (after[j] >= '0' and after[j] <= '9'))) : (j += 1) {}
    if (j == i) return null;
    return std.fmt.parseFloat(f32, after[i..j]) catch null;
}

fn parseFloat(s: []const u8) ?f32 {
    // Find first float-like substring
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if ((s[i] >= '0' and s[i] <= '9') or s[i] == '.') {
            var j = i;
            var has_dot = false;
            while (j < s.len and ((s[j] >= '0' and s[j] <= '9') or (s[j] == '.' and !has_dot))) : (j += 1) {
                if (s[j] == '.') has_dot = true;
            }
            return std.fmt.parseFloat(f32, s[i..j]) catch {
                i = j;
                continue;
            };
        }
    }
    return null;
}

// ============================================================================
// Curriculum Generator: LLM generates coloring tasks
// ============================================================================

pub const CurriculumTask = struct {
    description: []const u8,
    target_ops: u8,    // number of distinct operations
    target_depth: u8,  // max nesting depth
    style_hint: Style,

    pub const Style = enum {
        warm,       // reds, oranges, yellows
        cool,       // blues, greens, purples
        monochrome, // single hue, vary lightness
        contrast,   // maximize perceptual distance
        semantic,   // group by meaning
    };

    pub fn deinit(self: *CurriculumTask, allocator: std.mem.Allocator) void {
        allocator.free(self.description);
    }
};

const CURRICULUM_PROMPT =
    "You generate s-expression coloring tasks for an RL agent. " ++
    "Respond with ONLY a JSON object: " ++
    "{\"description\":\"...\",\"ops\":N,\"depth\":N,\"style\":\"warm|cool|mono|contrast|semantic\"}";

/// Generate a curriculum task from the LLM.
/// Returns null if llamafile unavailable.
pub fn generateTask(
    client: *const Client,
    allocator: std.mem.Allocator,
    difficulty: u8, // 1-10
) ?CurriculumTask {
    var prompt_buf: [256]u8 = undefined;
    const prompt = std.fmt.bufPrint(&prompt_buf,
        "Generate a coloring task at difficulty {d}/10. " ++
            "More operations and deeper nesting = harder.",
        .{difficulty},
    ) catch return null;

    const response = client.chatCompletion(
        allocator,
        CURRICULUM_PROMPT,
        prompt,
        0.7, // higher temp for diversity
        150,
    ) catch return null;

    // Parse task from response
    const desc_start = std.mem.indexOf(u8, response, "\"description\":\"") orelse {
        allocator.free(response);
        return null;
    };
    const desc_content_start = desc_start + "\"description\":\"".len;
    _ = std.mem.indexOfPos(u8, response, desc_content_start, "\"") orelse {
        allocator.free(response);
        return null;
    };

    const ops = extractJsonInt(response, "ops") orelse @as(u8, 3) + difficulty;
    const depth = extractJsonInt(response, "depth") orelse @as(u8, 2) + difficulty / 2;

    return CurriculumTask{
        .description = response, // keep full response, description is a view into it
        .target_ops = @intCast(@min(ops, 16)),
        .target_depth = @intCast(@min(depth, 16)),
        .style_hint = .semantic,
    };
}

fn extractJsonInt(json: []const u8, key: []const u8) ?u8 {
    const f = extractJsonFloat(json, key) orelse return null;
    if (f < 0 or f > 255) return null;
    return @intFromFloat(f);
}

// ============================================================================
// Blended Reward: LLM critic + hardcoded components
// ============================================================================

pub const BlendedReward = struct {
    hardcoded: f32,   // from color_policy.zig RewardComponents.total()
    llm_critic: f32,  // from scorePalette()
    llm_weight: f32,  // 0.0 = pure hardcoded, 1.0 = pure LLM

    pub fn total(self: BlendedReward) f32 {
        return self.hardcoded * (1.0 - self.llm_weight) +
            self.llm_critic * self.llm_weight;
    }
};

/// Compute blended reward. Falls back to hardcoded-only if LLM unavailable.
pub fn blendedScore(
    client: *const Client,
    allocator: std.mem.Allocator,
    entries: []const PaletteEntry,
    hardcoded_reward: f32,
    llm_weight: f32,
) BlendedReward {
    const critic = scorePalette(client, allocator, entries);
    if (critic) |c| {
        var score = c;
        defer score.deinit(allocator);
        return .{
            .hardcoded = hardcoded_reward,
            .llm_critic = score.overall,
            .llm_weight = llm_weight,
        };
    }
    // LLM unavailable — pure hardcoded
    return .{
        .hardcoded = hardcoded_reward,
        .llm_critic = 0,
        .llm_weight = 0,
    };
}

// ============================================================================
// Tests (offline — no llamafile dependency)
// ============================================================================

test "extract content from mock response" {
    const mock_json =
        \\{"choices":[{"message":{"content":"0.85"}}]}
    ;
    const content = try extractContent(std.testing.allocator, mock_json);
    defer std.testing.allocator.free(content);
    try std.testing.expectEqualStrings("0.85", content);
}

test "parse critic JSON response" {
    const response =
        \\{"readability":0.9,"semantic":0.7,"harmony":0.8,"overall":0.8}
    ;
    // Need to dupe since parseCriticResponse takes ownership
    const duped = try std.testing.allocator.dupe(u8, response);
    const score = parseCriticResponse(duped) orelse {
        std.testing.allocator.free(duped);
        return error.ParseFailed;
    };
    defer std.testing.allocator.free(score.raw_response);
    try std.testing.expect(score.readability > 0.85);
    try std.testing.expect(score.semantic > 0.65);
    try std.testing.expect(score.harmony > 0.75);
    try std.testing.expect(score.overall > 0.75);
}

test "extract json float" {
    const json = "{\"readability\":0.92,\"semantic\":0.85}";
    const r = extractJsonFloat(json, "readability") orelse return error.NotFound;
    try std.testing.expect(r > 0.91 and r < 0.93);
    const s = extractJsonFloat(json, "semantic") orelse return error.NotFound;
    try std.testing.expect(s > 0.84 and s < 0.86);
    try std.testing.expect(extractJsonFloat(json, "missing") == null);
}

test "parse float from text" {
    try std.testing.expect(parseFloat("score: 0.75 out of 1.0").? > 0.74);
    try std.testing.expect(parseFloat("no numbers here") == null);
}

test "trit sum calculation" {
    const entries = [_]PaletteEntry{
        .{ .op_name = "compose", .trit = .plus, .color = .{ .r = 168, .g = 85, .b = 247 } },
        .{ .op_name = "apply", .trit = .minus, .color = .{ .r = 56, .g = 189, .b = 248 } },
        .{ .op_name = "quote", .trit = .ergodic, .color = .{ .r = 74, .g = 222, .b = 128 } },
    };
    try std.testing.expectEqual(@as(i32, 0), tritSum(&entries));
}

test "blended reward fallback without server" {
    const client = Client.initDefault();
    const entries = [_]PaletteEntry{
        .{ .op_name = "test", .trit = .ergodic, .color = .{ .r = 128, .g = 128, .b = 128 } },
    };
    const reward = blendedScore(&client, std.testing.allocator, &entries, 0.7, 0.3);
    // Should fall back to pure hardcoded since no server is running
    try std.testing.expectEqual(@as(f32, 0), reward.llm_weight);
    try std.testing.expect(reward.total() > 0.69);
}

test "client init" {
    const c = Client.initDefault();
    try std.testing.expectEqualStrings("127.0.0.1", c.host);
    try std.testing.expectEqual(@as(u16, 8090), c.port);
}

test "palette entry construction" {
    const e = PaletteEntry{
        .op_name = "lambda",
        .trit = .plus,
        .color = .{ .r = 255, .g = 0, .b = 128 },
    };
    try std.testing.expectEqualStrings("lambda", e.op_name);
}
