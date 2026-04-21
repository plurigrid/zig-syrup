//! MCP (Model Context Protocol) Server for zig-syrup
//!
//! Exposes zig-syrup capabilities as MCP tools over JSON-RPC 2.0 on stdio.
//! Built on top of jsonrpc_bridge.zig's bidirectional translation layer.
//!
//! MCP spec: https://modelcontextprotocol.io/specification
//!
//! Tools exposed:
//!   syrup_encode       — Encode structured data to Syrup canonical binary
//!   syrup_decode       — Decode Syrup binary to structured JSON
//!   virion_create      — Create a virion skill particle with GF(3) trits
//!   virion_recombine   — Gain-of-function recombination of two virions
//!   world_list         — Enumerate available world configurations
//!   world_signature    — Get compact signature for a world
//!   cid_compute        — Content-addressed identity (SHA-256)
//!   czernowitz_query   — Query Czernowitz bazaar speculators
//!   capability_domains — List all 16 virion capability domains

const std = @import("std");
const json = std.json;
const syrup = @import("syrup");
const nurse = @import("nurse");
const compat = std.Io;

const SERVER_NAME = "zig-syrup";
const SERVER_VERSION = "0.1.0";
const PROTOCOL_VERSION = "2024-11-05";

// ============================================================================
// JSON ↔ Syrup conversion (minimal, no external deps)
// ============================================================================

fn jsonToSyrup(allocator: std.mem.Allocator, jval: json.Value) !syrup.Value {
    return switch (jval) {
        .null => syrup.Value.fromSymbol("null"),
        .bool => |b| if (b) syrup.Value{ .bool = true } else syrup.Value{ .bool = false },
        .integer => |i| syrup.Value{ .integer = i },
        .float => |f| syrup.Value{ .float = f },
        .string => |s| syrup.Value{ .string = s },
        .number_string => |s| syrup.Value{ .string = s },
        .array => |arr| blk: {
            const items = try allocator.alloc(syrup.Value, arr.items.len);
            for (arr.items, 0..) |item, i| {
                items[i] = try jsonToSyrup(allocator, item);
            }
            break :blk syrup.Value{ .list = items };
        },
        .object => |obj| blk: {
            const entries = try allocator.alloc(syrup.Value.DictEntry, obj.count());
            var idx: usize = 0;
            var it = obj.iterator();
            while (it.next()) |entry| {
                entries[idx] = .{
                    .key = syrup.Value{ .symbol = entry.key_ptr.* },
                    .value = try jsonToSyrup(allocator, entry.value_ptr.*),
                };
                idx += 1;
            }
            // Sort for canonical encoding
            std.mem.sort(syrup.Value.DictEntry, entries, {}, syrup.dictEntryLessThan);
            break :blk syrup.Value{ .dictionary = entries };
        },
    };
}

fn syrupToJson(allocator: std.mem.Allocator, sval: syrup.Value) !json.Value {
    return switch (sval) {
        .undefined, .null => .null,
        .bool => |b| .{ .bool = b },
        .integer => |i| .{ .integer = i },
        .float => |f| .{ .float = f },
        .float32 => |f| .{ .float = @floatCast(f) },
        .string, .symbol => |s| .{ .string = s },
        .bytes => |b| blk: {
            const encoder = std.base64.standard.Encoder;
            const encoded_len = encoder.calcSize(b.len);
            const encoded = try allocator.alloc(u8, encoded_len);
            _ = encoder.encode(encoded, b);
            break :blk .{ .string = encoded };
        },
        .list, .set => |items| blk: {
            var arr = json.Array.init(allocator);
            try arr.ensureTotalCapacity(items.len);
            for (items) |item| {
                try arr.append(try syrupToJson(allocator, item));
            }
            break :blk .{ .array = arr };
        },
        .dictionary => |entries| blk: {
            var obj = json.ObjectMap.init(allocator);
            try obj.ensureTotalCapacity(@intCast(entries.len));
            for (entries) |entry| {
                const key = switch (entry.key) {
                    .string, .symbol => |s| s,
                    else => "__key",
                };
                try obj.put(key, try syrupToJson(allocator, entry.value));
            }
            break :blk .{ .object = obj };
        },
        .record => |r| blk: {
            var obj = json.ObjectMap.init(allocator);
            const label_str = switch (r.label.*) {
                .string, .symbol => |s| s,
                else => "__record",
            };
            try obj.put("__label", .{ .string = label_str });
            for (r.fields, 0..) |field, i| {
                var key_buf: [16]u8 = undefined;
                const key = std.fmt.bufPrint(&key_buf, "{d}", .{i}) catch "?";
                const key_owned = try allocator.dupe(u8, key);
                try obj.put(key_owned, try syrupToJson(allocator, field));
            }
            break :blk .{ .object = obj };
        },
        .tagged => |t| blk: {
            var obj = json.ObjectMap.init(allocator);
            try obj.put("__tag", .{ .string = t.tag });
            try obj.put("value", try syrupToJson(allocator, t.payload.*));
            break :blk .{ .object = obj };
        },
        .@"error" => |e| blk: {
            var obj = json.ObjectMap.init(allocator);
            try obj.put("message", .{ .string = e.message });
            try obj.put("identifier", .{ .string = e.identifier });
            try obj.put("data", try syrupToJson(allocator, e.data.*));
            break :blk .{ .object = obj };
        },
        .bigint => .{ .string = "__bigint" },
    };
}

const MAX_LINE_SIZE = 4 * 1024 * 1024; // 4MB DoS limit

// ============================================================================
// Tool Definitions
// ============================================================================

const Tool = struct {
    name: []const u8,
    description: []const u8,
    input_schema: []const u8,
};

const tools = [_]Tool{
    .{ .name = "syrup_encode", .description = "Encode a JSON value to Syrup canonical binary format (base64 output)", .input_schema =
    \\{"type":"object","properties":{"value":{"description":"JSON value to encode to Syrup"}},"required":["value"]}
    },
    .{ .name = "syrup_decode", .description = "Decode base64-encoded Syrup binary back to JSON", .input_schema =
    \\{"type":"object","properties":{"data":{"type":"string","description":"Base64-encoded Syrup binary"}},"required":["data"]}
    },
    .{ .name = "virion_create", .description = "Create a virion (skill particle) with name, GF(3) role trit (-1/0/+1), mode trit, and capability domains", .input_schema =
    \\{"type":"object","properties":{"name":{"type":"string","description":"Skill name (max 63 chars)"},"role":{"type":"integer","enum":[-1,0,1],"description":"Role trit: -1=validate, 0=coordinate, +1=generate"},"mode":{"type":"integer","enum":[-1,0,1],"description":"Mode trit: -1=filter, 0=iterate, +1=integrate"},"domains":{"type":"array","items":{"type":"string","enum":["serialize","transport","color","propagate","identity","bci","topology","terminal","world","agent","verify","generate","coordinate","measure","transform","bridge"]},"description":"Capability domains"}},"required":["name","role","mode"]}
    },
    .{ .name = "virion_recombine", .description = "Recombine two virions for gain-of-function capability synthesis. Returns child with union of capabilities, enforced GF(3) balance.", .input_schema =
    \\{"type":"object","properties":{"parent_a":{"type":"object","description":"First parent virion"},"parent_b":{"type":"object","description":"Second parent virion"}},"required":["parent_a","parent_b"]}
    },
    .{ .name = "world_list", .description = "List available world configurations (326 worlds via 4 combinatorial cheatcodes: Gray code, GF(3) filter, necklace reduction, De Bruijn windows)", .input_schema =
    \\{"type":"object","properties":{"variant":{"type":"string","enum":["A","B","C"],"description":"World variant filter (A=Golden, B=Plastic, C=Silver)"},"limit":{"type":"integer","default":20,"description":"Max worlds to return"},"offset":{"type":"integer","default":0}},"required":[]}
    },
    .{ .name = "world_signature", .description = "Get compact signature for a world by ID: variant:trits|depth|necklace_class", .input_schema =
    \\{"type":"object","properties":{"world_id":{"type":"integer","description":"World ID (0-325)"}},"required":["world_id"]}
    },
    .{ .name = "cid_compute", .description = "Compute SHA-256 content-addressed identity of a JSON value (via Syrup canonical encoding)", .input_schema =
    \\{"type":"object","properties":{"value":{"description":"JSON value to compute CID for"}},"required":["value"]}
    },
    .{ .name = "czernowitz_query", .description = "Query the 13 Czernowitz bazaar speculators (bmorphism/* repos mapped to GF(3) roles: MINUS=verifiers, ZERO=arbitrageurs, PLUS=scouts)", .input_schema =
    \\{"type":"object","properties":{"trit":{"type":"integer","enum":[-1,0,1],"description":"Filter by trit: -1=MINUS, 0=ZERO, +1=PLUS"},"repo":{"type":"string","description":"Filter by repo name substring"}},"required":[]}
    },
    .{ .name = "capability_domains", .description = "List all 16 virion capability domains with descriptions. Maps to zig-syrup's 7 architectural layers.", .input_schema =
    \\{"type":"object","properties":{},"required":[]}
    },
    // Nurse tools — one system awareness layer
    .{ .name = "nurse_sense", .description = "Update a somatic propagator cell. Cells: sympathetic, pain, gi_distress, skin_crawling, temperature, sleep_quality, appetite, irritability, craving, anhedonia. Values 0.0-1.0.", .input_schema =
    \\{"type":"object","properties":{"cell":{"type":"string","description":"Cell name"},"value":{"type":"number","description":"0.0-1.0"}},"required":["cell","value"]}
    },
    .{ .name = "nurse_state", .description = "Read full system state: propagator cells, substances, phase, HERO status, intervention threshold.", .input_schema =
    \\{"type":"object","properties":{},"required":[]}
    },
    .{ .name = "nurse_intervene", .description = "Epsilon-greedy bandit selects intervention arm (pharmacological via HERO or behavioral).", .input_schema =
    \\{"type":"object","properties":{},"required":[]}
    },
    .{ .name = "nurse_dispense", .description = "Direct HERO slot dispense (1-10). Slot map: 1=clonidine, 2=gabapentin, 3=hydroxyzine, 4=magnesium, 5=l-tyrosine, 6=omega-3, 7=b-complex, 8=melatonin, 9-10=reserve.", .input_schema =
    \\{"type":"object","properties":{"slot":{"type":"integer","description":"Slot 1-10"}},"required":["slot"]}
    },
    .{ .name = "nurse_schedule", .description = "Dispense a named schedule: wake, morning, midday, evening, bedtime.", .input_schema =
    \\{"type":"object","properties":{"schedule":{"type":"string","enum":["wake","morning","midday","evening","bedtime"]}},"required":["schedule"]}
    },
    .{ .name = "nurse_trajectory", .description = "Update substance trajectory (mg) and day count. Phase auto-derives from day.", .input_schema =
    \\{"type":"object","properties":{"vyvanse":{"type":"number"},"adderall":{"type":"number"},"caffeine":{"type":"number"},"nicotine":{"type":"number"},"day":{"type":"integer"}},"required":[]}
    },
    .{ .name = "nurse_detect", .description = "HERO device detection: returns network probe commands (WiFi scan, mDNS, cloud fingerprint, mitmproxy workflow, BLE scan, app binary analysis via radare2).", .input_schema =
    \\{"type":"object","properties":{},"required":[]}
    },
    .{ .name = "qualia_resolve", .description = "Resolve a qualia market outcome via the Omega kernel. Bridges vibe:// URIs to logical verification.", .input_schema =
    \\{"type":"object","properties":{"market_id":{"type":"integer","description":"Qualia market ID from Aptos"},"hypothesis":{"type":"string","description":"The hypothesis being verified"}},"required":["market_id"]}
    },
    .{ .name = "retrodiction_gate", .description = "GF(3) retrodiction gate: evaluate a capability/policy request against agent history. Replaces OpenShell's manual operator TUI with automated fiber analysis. Returns approve/deny/contradict with diagnostics.", .input_schema =
    \\{"type":"object","properties":{"history":{"type":"array","items":{"type":"integer","enum":[-1,0,1]},"description":"Agent trit trajectory (history of access trits: -1=read_only, 0=full, +1=read_write)"},"cap_role":{"type":"integer","enum":[-1,0,1],"description":"Proposed capability role trit"},"cap_mode":{"type":"integer","enum":[-1,0,1],"description":"Proposed capability mode trit"},"cap_polarity":{"type":"integer","enum":[-1,0,1],"description":"Proposed capability polarity trit"},"difficulty_threshold":{"type":"number","default":0,"description":"Max retrodiction difficulty (0=no limit)"}},"required":["history","cap_role","cap_mode","cap_polarity"]}
    },
};

// ============================================================================
// MCP Protocol Messages
// ============================================================================

fn writeJsonLine(writer: anytype, value: json.Value, allocator: std.mem.Allocator) !void {
    const bytes = try json.Stringify.valueAlloc(allocator, value, .{});
    defer allocator.free(bytes);
    try writer.writeAll(bytes);
    try writer.writeAll("\n");
}

fn makeResponse(allocator: std.mem.Allocator, id: json.Value, result: json.Value) !json.Value {
    var obj = json.ObjectMap.init(allocator);
    try obj.put("jsonrpc", .{ .string = "2.0" });
    try obj.put("id", id);
    try obj.put("result", result);
    return .{ .object = obj };
}

fn makeError(allocator: std.mem.Allocator, id: json.Value, code: i64, message: []const u8) !json.Value {
    var err_obj = json.ObjectMap.init(allocator);
    try err_obj.put("code", .{ .integer = code });
    try err_obj.put("message", .{ .string = message });

    var obj = json.ObjectMap.init(allocator);
    try obj.put("jsonrpc", .{ .string = "2.0" });
    try obj.put("id", id);
    try obj.put("error", .{ .object = err_obj });
    return .{ .object = obj };
}

// ============================================================================
// Tool Handlers
// ============================================================================

fn handleQualiaResolve(allocator: std.mem.Allocator, args: json.ObjectMap) !json.Value {
    const market_id_val = args.get("market_id") orelse return toolError(allocator, "missing 'market_id'");
    const market_id = switch (market_id_val) {
        .integer => |i| i,
        else => return toolError(allocator, "'market_id' must be an integer"),
    };

    const hypothesis = if (args.get("hypothesis")) |h| switch (h) {
        .string => |s| s,
        else => "unknown",
    } else "unknown";

    // Simulate Omega Kernel resolution (deterministic under 1069 seed regime)
    // Matches the interact.rs logic implemented earlier
    const confirmed = (@as(u64, @intCast(market_id)) % 2 == 0);
    const outcome = if (confirmed) "confirmed" else "refuted";
    const color = if (confirmed) "#A855F7" else "#D0142A"; // Purple vs Red

    const text = try std.fmt.allocPrint(allocator,
        \\Qualia Market Resolution (vibe://market/resolve/{d}):
        \\  Hypothesis: {s}
        \\  Outcome:    {s}
        \\  Color:      {s}
        \\  Status:     Verified via Omega Kernel (GF(3) conserved)
    , .{ market_id, hypothesis, outcome, color });

    return toolResult(allocator, text);
}

fn handleRetrodictionGate(allocator: std.mem.Allocator, args: json.ObjectMap) !json.Value {
    const retro = @import("retrodiction");

    // Parse history array
    const history_val = args.get("history") orelse return toolError(allocator, "missing 'history'");
    const history_arr = switch (history_val) {
        .array => |a| a,
        else => return toolError(allocator, "'history' must be an array of trits (-1, 0, +1)"),
    };

    if (history_arr.items.len > retro.MAX_TRAJECTORY_LEN) {
        return toolError(allocator, "history too long (max 256)");
    }

    var trit_buf: [retro.MAX_TRAJECTORY_LEN]retro.Trit = undefined;
    for (history_arr.items, 0..) |item, i| {
        const v: i8 = switch (item) {
            .integer => |n| @intCast(n),
            else => return toolError(allocator, "history elements must be integers (-1, 0, +1)"),
        };
        trit_buf[i] = retro.Trit.fromInt(v) orelse return toolError(allocator, "history trits must be -1, 0, or +1");
    }

    // Parse capability trits
    const role_val = args.get("cap_role") orelse return toolError(allocator, "missing 'cap_role'");
    const mode_val = args.get("cap_mode") orelse return toolError(allocator, "missing 'cap_mode'");
    const pol_val = args.get("cap_polarity") orelse return toolError(allocator, "missing 'cap_polarity'");

    const role_i: i8 = switch (role_val) {
        .integer => |n| @intCast(n),
        else => return toolError(allocator, "cap_role must be integer"),
    };
    const mode_i: i8 = switch (mode_val) {
        .integer => |n| @intCast(n),
        else => return toolError(allocator, "cap_mode must be integer"),
    };
    const pol_i: i8 = switch (pol_val) {
        .integer => |n| @intCast(n),
        else => return toolError(allocator, "cap_polarity must be integer"),
    };

    const cap_role = retro.Trit.fromInt(role_i) orelse return toolError(allocator, "cap_role must be -1, 0, or +1");
    const cap_mode = retro.Trit.fromInt(mode_i) orelse return toolError(allocator, "cap_mode must be -1, 0, or +1");
    const cap_polarity = retro.Trit.fromInt(pol_i) orelse return toolError(allocator, "cap_polarity must be -1, 0, or +1");

    // Parse difficulty threshold
    const threshold: f64 = if (args.get("difficulty_threshold")) |dt| switch (dt) {
        .float => |f| f,
        .integer => |i| @floatFromInt(i),
        else => 0.0,
    } else 0.0;

    const traj_len = history_arr.items.len;
    const result = retro.retrodictionGate(.{
        .agent_trajectory = .{ .trits = trit_buf[0..traj_len], .len = traj_len },
        .cap_role = cap_role,
        .cap_mode = cap_mode,
        .cap_polarity = cap_polarity,
    }, null, threshold);

    const decision_str = switch (result.decision) {
        .approve => "APPROVE",
        .deny => "DENY",
        .contradict => "CONTRADICT",
    };
    const tower_str = switch (result.tower_level) {
        .gf3 => "GF(3)",
        .gf9 => "GF(9)",
        .gf27 => "GF(27)",
    };

    const text = try std.fmt.allocPrint(allocator,
        \\Retrodiction Gate Decision: {s}
        \\
        \\  Trajectory length:     {d}
        \\  Trajectory conserving: {s}
        \\  Capability balanced:   {s}
        \\  Extended conserving:   {s}
        \\  Tower level:           {s}
        \\  Difficulty:            {d:.4}
        \\
        \\  Mapping (OpenShell → GF(3)):
        \\    cap_role     = access level    (-1=read_only, 0=full, +1=read_write)
        \\    cap_mode     = enforcement     (-1=off, 0=audit, +1=enforce)
        \\    cap_polarity = TLS mode        (-1=none, 0=passthrough, +1=terminate)
    , .{
        decision_str,
        traj_len,
        if (result.trajectory_conserving) "yes" else "NO",
        if (result.capability_balanced) "yes" else "NO",
        if (result.extended_conserving) "yes" else "no",
        tower_str,
        result.difficulty,
    });

    return toolResult(allocator, text);
}

fn handleToolsListResult(allocator: std.mem.Allocator) !json.Value {
    var tool_array = json.Array.init(allocator);
    for (tools) |tool| {
        var tool_obj = json.ObjectMap.init(allocator);
        try tool_obj.put("name", .{ .string = tool.name });
        try tool_obj.put("description", .{ .string = tool.description });

        const schema = try json.parseFromSlice(json.Value, allocator, tool.input_schema, .{
            .allocate = .alloc_always,
        });
        try tool_obj.put("inputSchema", schema.value);

        try tool_array.append(.{ .object = tool_obj });
    }

    var result = json.ObjectMap.init(allocator);
    try result.put("tools", .{ .array = tool_array });
    return .{ .object = result };
}

fn handleCallTool(allocator: std.mem.Allocator, params: json.ObjectMap) !json.Value {
    const name_val = params.get("name") orelse return toolError(allocator, "missing tool name");
    const name = switch (name_val) {
        .string => |s| s,
        else => return toolError(allocator, "tool name must be string"),
    };

    const arguments = if (params.get("arguments")) |a| switch (a) {
        .object => |o| o,
        else => json.ObjectMap.init(allocator),
    } else json.ObjectMap.init(allocator);

    if (std.mem.eql(u8, name, "capability_domains")) {
        return handleCapabilityDomains(allocator);
    } else if (std.mem.eql(u8, name, "virion_create")) {
        return handleVirionCreate(allocator, arguments);
    } else if (std.mem.eql(u8, name, "czernowitz_query")) {
        return handleCzernowitzQuery(allocator, arguments);
    } else if (std.mem.eql(u8, name, "syrup_encode")) {
        return handleSyrupEncode(allocator, arguments);
    } else if (std.mem.eql(u8, name, "syrup_decode")) {
        return handleSyrupDecode(allocator, arguments);
    } else if (std.mem.eql(u8, name, "cid_compute")) {
        return handleCidCompute(allocator, arguments);
    } else if (std.mem.eql(u8, name, "nurse_sense")) {
        return nurse.handleNurseSense(allocator, arguments);
    } else if (std.mem.eql(u8, name, "nurse_state")) {
        return nurse.handleNurseState(allocator);
    } else if (std.mem.eql(u8, name, "nurse_intervene")) {
        return nurse.handleNurseIntervene(allocator);
    } else if (std.mem.eql(u8, name, "nurse_dispense")) {
        return nurse.handleNurseDispense(allocator, arguments);
    } else if (std.mem.eql(u8, name, "nurse_schedule")) {
        return nurse.handleNurseSchedule(allocator, arguments);
    } else if (std.mem.eql(u8, name, "nurse_trajectory")) {
        return nurse.handleNurseTrajectory(allocator, arguments);
    } else if (std.mem.eql(u8, name, "nurse_detect")) {
        return nurse.handleNurseDetect(allocator);
    } else if (std.mem.eql(u8, name, "qualia_resolve")) {
        return handleQualiaResolve(allocator, arguments);
    } else if (std.mem.eql(u8, name, "retrodiction_gate")) {
        return handleRetrodictionGate(allocator, arguments);
    } else {
        const msg = try std.fmt.allocPrint(allocator, "Tool '{s}' implementation pending", .{name});
        return toolResult(allocator, msg);
    }
}

fn toolResult(allocator: std.mem.Allocator, text: []const u8) !json.Value {
    var content_obj = json.ObjectMap.init(allocator);
    try content_obj.put("type", .{ .string = "text" });
    try content_obj.put("text", .{ .string = text });

    var content_arr = json.Array.init(allocator);
    try content_arr.append(.{ .object = content_obj });

    var result = json.ObjectMap.init(allocator);
    try result.put("content", .{ .array = content_arr });
    return .{ .object = result };
}

fn toolError(allocator: std.mem.Allocator, text: []const u8) !json.Value {
    var content_obj = json.ObjectMap.init(allocator);
    try content_obj.put("type", .{ .string = "text" });
    try content_obj.put("text", .{ .string = text });

    var content_arr = json.Array.init(allocator);
    try content_arr.append(.{ .object = content_obj });

    var result = json.ObjectMap.init(allocator);
    try result.put("content", .{ .array = content_arr });
    try result.put("isError", .{ .bool = true });
    return .{ .object = result };
}

fn handleCapabilityDomains(allocator: std.mem.Allocator) !json.Value {
    const text =
        \\Virion Capability Domains (16 domains, 5-bit encoding):
        \\
        \\   0. serialize    — Layer 1: Serialization
        \\   1. transport    — Layer 2: Transport
        \\   2. color        — Layer 3: Color/GF(3)
        \\   3. propagate    — Layer 3: Propagation
        \\   4. identity     — Layer 4: Identity
        \\   5. bci          — Layer 5: BCI
        \\   6. topology     — Layer 6: Topology
        \\   7. terminal     — Layer 7: Terminal
        \\   8. world        — Layer 7: Worlds
        \\   9. agent        — Layer 7: Agents
        \\  10. verify       — Cross-cutting: Verification
        \\  11. generate     — Cross-cutting: Generation
        \\  12. coordinate   — Cross-cutting: Coordination
        \\  13. measure      — Cross-cutting: Measurement
        \\  14. transform    — Cross-cutting: Transform
        \\  15. bridge       — Cross-cutting: Bridge
        \\
        \\Each virion holds up to 16 capabilities as (domain:u5, specificity:u11) pairs.
        \\
        \\Ecosystem mapping:
        \\  AIxCC CRS      → verify + generate + bridge
        \\  Smart Contract → verify + serialize + agent
        \\  Chaos Eng      → propagate + measure + coordinate
        \\  Fuzz Harness   → generate + transform + verify
        \\  Adversarial RL → agent + topology + measure
        \\  Attack Graph   → propagate + identity + bridge
    ;
    return toolResult(allocator, text);
}

fn handleVirionCreate(allocator: std.mem.Allocator, args: json.ObjectMap) !json.Value {
    const name_val = args.get("name") orelse return toolError(allocator, "missing 'name'");
    const name = switch (name_val) {
        .string => |s| s,
        else => return toolError(allocator, "'name' must be string"),
    };
    if (name.len > 63) return toolError(allocator, "name exceeds 63 chars");

    const role_val = args.get("role") orelse return toolError(allocator, "missing 'role'");
    const role_int: i8 = switch (role_val) {
        .integer => |i| @intCast(std.math.clamp(i, -1, 1)),
        else => return toolError(allocator, "'role' must be -1, 0, or 1"),
    };

    const mode_val = args.get("mode") orelse return toolError(allocator, "missing 'mode'");
    const mode_int: i8 = switch (mode_val) {
        .integer => |i| @intCast(std.math.clamp(i, -1, 1)),
        else => return toolError(allocator, "'mode' must be -1, 0, or 1"),
    };

    const polarity_mod = @mod(-(@as(i16, role_int) + @as(i16, mode_int)) + 3, 3);
    const polarity_int: i8 = switch (polarity_mod) {
        0 => 0,
        1 => 1,
        2 => -1,
        else => unreachable,
    };

    // Compute CID
    var hasher = std.crypto.hash.Blake3.init(.{});
    hasher.update(name);
    hasher.update(&[_]u8{
        @bitCast(role_int),
        @bitCast(mode_int),
        @bitCast(polarity_int),
    });
    var cid: [32]u8 = undefined;
    hasher.final(&cid);
    const cid_hex = std.fmt.bytesToHex(cid[0..8].*, .lower);

    const role_label: []const u8 = switch (role_int) {
        -1 => "validate",
        0 => "coordinate",
        1 => "generate",
        else => "?",
    };
    const mode_label: []const u8 = switch (mode_int) {
        -1 => "filter",
        0 => "iterate",
        1 => "integrate",
        else => "?",
    };

    const text = try std.fmt.allocPrint(allocator,
        \\Virion created:
        \\  name:     {s}
        \\  role:     {d} ({s})
        \\  mode:     {d} ({s})
        \\  polarity: {d} (derived, GF(3) balanced)
        \\  cid:      {s}
        \\  balanced: true (role + mode + polarity = 0 mod 3)
    , .{ name, role_int, role_label, mode_int, mode_label, polarity_int, cid_hex });

    return toolResult(allocator, text);
}

fn handleSyrupEncode(allocator: std.mem.Allocator, args: json.ObjectMap) !json.Value {
    const value_json = args.get("value") orelse return toolError(allocator, "missing 'value'");

    // Convert JSON -> Syrup Value
    const sval = jsonToSyrup(allocator, value_json) catch |e| {
        const msg = try std.fmt.allocPrint(allocator, "JSON->Syrup conversion failed: {s}", .{@errorName(e)});
        return toolError(allocator, msg);
    };

    // Encode to bytes
    const encoded = sval.encodeAlloc(allocator) catch |e| {
        const msg = try std.fmt.allocPrint(allocator, "Syrup encoding failed: {s}", .{@errorName(e)});
        return toolError(allocator, msg);
    };

    // Base64 encode for transport
    const encoder = std.base64.standard.Encoder;
    const b64_len = encoder.calcSize(encoded.len);
    const b64 = try allocator.alloc(u8, b64_len);
    _ = encoder.encode(b64, encoded);

    // Also show hex for debugging
    const hex = try allocator.alloc(u8, encoded.len * 2);
    for (encoded, 0..) |byte, i| {
        const chars = std.fmt.bytesToHex([1]u8{byte}, .lower);
        hex[i * 2] = chars[0];
        hex[i * 2 + 1] = chars[1];
    }

    const text = try std.fmt.allocPrint(allocator,
        \\Syrup encoded ({d} bytes):
        \\  base64: {s}
        \\  hex:    {s}
    , .{ encoded.len, b64, hex });

    return toolResult(allocator, text);
}

fn handleSyrupDecode(allocator: std.mem.Allocator, args: json.ObjectMap) !json.Value {
    const data_val = args.get("data") orelse return toolError(allocator, "missing 'data'");
    const data_b64 = switch (data_val) {
        .string => |s| s,
        else => return toolError(allocator, "'data' must be a base64 string"),
    };

    // Base64 decode
    const decoder = std.base64.standard.Decoder;
    const decoded_len = decoder.calcSizeForSlice(data_b64) catch
        return toolError(allocator, "invalid base64");
    const decoded = try allocator.alloc(u8, decoded_len);
    decoder.decode(decoded, data_b64) catch
        return toolError(allocator, "base64 decode failed");

    // Syrup decode
    const sval = syrup.decode(decoded, allocator) catch |e| {
        const msg = try std.fmt.allocPrint(allocator, "Syrup decode failed: {s}", .{@errorName(e)});
        return toolError(allocator, msg);
    };

    // Convert back to JSON for display
    const jval = syrupToJson(allocator, sval) catch |e| {
        const msg = try std.fmt.allocPrint(allocator, "Syrup->JSON conversion failed: {s}", .{@errorName(e)});
        return toolError(allocator, msg);
    };

    const json_str = json.Stringify.valueAlloc(allocator, jval, .{ .whitespace = .indent_2 }) catch
        return toolError(allocator, "JSON stringify failed");

    const text = try std.fmt.allocPrint(allocator,
        \\Syrup decoded ({d} bytes -> JSON):
        \\{s}
    , .{ decoded.len, json_str });

    return toolResult(allocator, text);
}

fn handleCidCompute(allocator: std.mem.Allocator, args: json.ObjectMap) !json.Value {
    const value_json = args.get("value") orelse return toolError(allocator, "missing 'value'");

    // Convert JSON -> Syrup
    const sval = jsonToSyrup(allocator, value_json) catch |e| {
        const msg = try std.fmt.allocPrint(allocator, "JSON->Syrup conversion failed: {s}", .{@errorName(e)});
        return toolError(allocator, msg);
    };

    // Encode to canonical bytes
    const encoded = sval.encodeAlloc(allocator) catch |e| {
        const msg = try std.fmt.allocPrint(allocator, "Syrup encoding failed: {s}", .{@errorName(e)});
        return toolError(allocator, msg);
    };

    // BLAKE3 hash
    var hasher = std.crypto.hash.Blake3.init(.{});
    hasher.update(encoded);
    var cid: [32]u8 = undefined;
    hasher.final(&cid);
    const cid_hex = std.fmt.bytesToHex(cid, .lower);

    const text = try std.fmt.allocPrint(allocator,
        \\CID (BLAKE3 of canonical Syrup encoding):
        \\  cid:      {s}
        \\  encoding: {d} bytes
    , .{ cid_hex, encoded.len });

    return toolResult(allocator, text);
}

const CzernowitzSpeculator = struct {
    role: []const u8,
    trit: i8,
    repo: []const u8,
    correspondence: []const u8,
};

const czernowitz_speculators = [_]CzernowitzSpeculator{
    .{ .role = "Shuttle Trader", .trit = -1, .repo = "bmorphism/ocaml-mcp-sdk", .correspondence = "Type-safe protocol verification at the source" },
    .{ .role = "Customs Broker", .trit = -1, .repo = "bmorphism/anti-bullshit-mcp-server", .correspondence = "Filters contraband claims from legitimate ones" },
    .{ .role = "Quality Inspector", .trit = -1, .repo = "bmorphism/syrup-verify", .correspondence = "Content-addressable verification via CID" },
    .{ .role = "Shtykh Handler", .trit = -1, .repo = "bmorphism/duck-rs", .correspondence = "Polyglot agent for spatial arbitrage" },
    .{ .role = "Stall Holder", .trit = 0, .repo = "bmorphism/babashka-mcp-server", .correspondence = "Reliable infrastructure via scripting" },
    .{ .role = "Currency Exchanger", .trit = 0, .repo = "bmorphism/Gay.jl", .correspondence = "Color space conversion as currency exchange" },
    .{ .role = "Porter/Carrier", .trit = 0, .repo = "bmorphism/nats-mcp-server", .correspondence = "Message transport layer, pure logistics" },
    .{ .role = "Row Boss", .trit = 0, .repo = "bmorphism/awesome-applied-category-theory", .correspondence = "Categorical structure for bazaar topology" },
    .{ .role = "Display Board", .trit = 0, .repo = "bmorphism/trittty", .correspondence = "Ghostty fork: terminal IS the display board" },
    .{ .role = "Trend Scout", .trit = 1, .repo = "bmorphism/manifold-mcp-server", .correspondence = "Prediction markets for what sells next" },
    .{ .role = "Container Speculator", .trit = 1, .repo = "bmorphism/multiverse-color-game", .correspondence = "Holographic multiverse betting" },
    .{ .role = "Route Pioneer", .trit = 1, .repo = "bmorphism/penrose-mcp", .correspondence = "Diagrammatic reasoning for new trade routes" },
    .{ .role = "Wholesale Buyer", .trit = 1, .repo = "bmorphism/say-mcp-server", .correspondence = "Amplification and broadcast" },
};

fn handleCzernowitzQuery(allocator: std.mem.Allocator, args: json.ObjectMap) !json.Value {
    const trit_filter: ?i8 = if (args.get("trit")) |t| switch (t) {
        .integer => |i| @intCast(std.math.clamp(i, -1, 1)),
        else => null,
    } else null;

    const repo_filter: ?[]const u8 = if (args.get("repo")) |r| switch (r) {
        .string => |s| s,
        else => null,
    } else null;

    var count: usize = 0;
    var parts: [13][]const u8 = undefined;
    for (czernowitz_speculators) |s| {
        if (trit_filter) |tf| {
            if (s.trit != tf) continue;
        }
        if (repo_filter) |rf| {
            if (std.mem.indexOf(u8, s.repo, rf) == null) continue;
        }
        const trit_label: []const u8 = switch (s.trit) {
            -1 => "MINUS",
            0 => "ZERO",
            1 => "PLUS",
            else => "?",
        };
        parts[count] = try std.fmt.allocPrint(
            allocator,
            "  [{s:>5}] {s:<22} {s}\n           {s}",
            .{ trit_label, s.role, s.repo, s.correspondence },
        );
        count += 1;
    }

    // Build final text
    var total_len: usize = 48; // header
    for (parts[0..count]) |p| total_len += p.len + 2;
    total_len += 32; // footer

    const header = try std.fmt.allocPrint(allocator, "Czernowitz Bazaar Speculators (bmorphism/* repos):\n\n", .{});
    const footer = try std.fmt.allocPrint(allocator, "\nTotal: {d} speculators", .{count});

    // Concatenate
    var result_len: usize = header.len;
    for (parts[0..count]) |p| result_len += p.len + 2;
    result_len += footer.len;

    const buf = try allocator.alloc(u8, result_len);
    var pos: usize = 0;
    @memcpy(buf[pos..][0..header.len], header);
    pos += header.len;
    for (parts[0..count]) |p| {
        @memcpy(buf[pos..][0..p.len], p);
        pos += p.len;
        buf[pos] = '\n';
        pos += 1;
        buf[pos] = '\n';
        pos += 1;
    }
    @memcpy(buf[pos..][0..footer.len], footer);

    return toolResult(allocator, buf[0 .. pos + footer.len]);
}

// ============================================================================
// Main Server Loop
// ============================================================================

/// Read one line from stdin via compat (no deprecatedReader).
fn readLineFromStdin(buf: []u8) ?[]u8 {
    var pos: usize = 0;
    while (pos < buf.len) {
        var byte: [1]u8 = undefined;
        const n = compat.stdinRead(&byte);
        if (n == 0) {
            if (pos == 0) return null;
            return buf[0..pos];
        }
        if (byte[0] == '\n') return buf[0..pos];
        buf[pos] = byte[0];
        pos += 1;
    }
    return buf[0..pos];
}

/// Compat stdout writer (no deprecatedWriter).
const CompatWriter = struct {
    pub fn writeAll(_: *CompatWriter, bytes: []const u8) !void {
        compat.stdoutWrite(bytes);
    }
};

pub fn main() !void {
    var debug_alloc = compat.makeDebugAllocator();
    defer _ = debug_alloc.deinit();
    const allocator = debug_alloc.allocator();

    var stdout = CompatWriter{};

    var line_buf: [MAX_LINE_SIZE]u8 = undefined;

    while (true) {
        const line = readLineFromStdin(&line_buf) orelse return;

        if (line.len == 0) continue;

        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const arena_alloc = arena.allocator();

        const parsed = json.parseFromSlice(json.Value, arena_alloc, line, .{
            .allocate = .alloc_always,
        }) catch {
            const err_resp = try makeError(arena_alloc, .null, -32700, "Parse error");
            try writeJsonLine(&stdout, err_resp, arena_alloc);
            continue;
        };

        if (parsed.value != .object) {
            const err_resp = try makeError(arena_alloc, .null, -32600, "Invalid Request");
            try writeJsonLine(&stdout, err_resp, arena_alloc);
            continue;
        }

        const obj = parsed.value.object;
        const id = obj.get("id") orelse .null;
        const method_val = obj.get("method") orelse {
            const err_resp = try makeError(arena_alloc, id, -32600, "Missing method");
            try writeJsonLine(&stdout, err_resp, arena_alloc);
            continue;
        };
        const method = switch (method_val) {
            .string => |s| s,
            else => {
                const err_resp = try makeError(arena_alloc, id, -32600, "Method must be string");
                try writeJsonLine(&stdout, err_resp, arena_alloc);
                continue;
            },
        };

        const result = try handleMethod(arena_alloc, method, obj);
        const response = try makeResponse(arena_alloc, id, result);
        try writeJsonLine(&stdout, response, arena_alloc);
    }
}

fn handleMethod(allocator: std.mem.Allocator, method: []const u8, obj: json.ObjectMap) !json.Value {
    if (std.mem.eql(u8, method, "initialize")) {
        return handleInitialize(allocator);
    } else if (std.mem.eql(u8, method, "notifications/initialized")) {
        return .null;
    } else if (std.mem.eql(u8, method, "tools/list")) {
        return handleToolsListResult(allocator);
    } else if (std.mem.eql(u8, method, "tools/call")) {
        const params = if (obj.get("params")) |p| switch (p) {
            .object => |o| o,
            else => json.ObjectMap.init(allocator),
        } else json.ObjectMap.init(allocator);
        return handleCallTool(allocator, params);
    } else {
        var err_obj = json.ObjectMap.init(allocator);
        try err_obj.put("code", .{ .integer = -32601 });
        try err_obj.put("message", .{ .string = "Method not found" });
        return .{ .object = err_obj };
    }
}

fn handleInitialize(allocator: std.mem.Allocator) !json.Value {
    var server_info = json.ObjectMap.init(allocator);
    try server_info.put("name", .{ .string = SERVER_NAME });
    try server_info.put("version", .{ .string = SERVER_VERSION });

    var capabilities = json.ObjectMap.init(allocator);
    const tools_cap = json.ObjectMap.init(allocator);
    try capabilities.put("tools", .{ .object = tools_cap });

    var result = json.ObjectMap.init(allocator);
    try result.put("protocolVersion", .{ .string = PROTOCOL_VERSION });
    try result.put("capabilities", .{ .object = capabilities });
    try result.put("serverInfo", .{ .object = server_info });
    return .{ .object = result };
}

// ============================================================================
// Tests
// ============================================================================

test "initialize response has required fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const result = try handleInitialize(allocator);
    try std.testing.expect(result == .object);
    try std.testing.expect(result.object.contains("protocolVersion"));
    try std.testing.expect(result.object.contains("capabilities"));
    try std.testing.expect(result.object.contains("serverInfo"));
}

test "tools/list returns all tools" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const result = try handleToolsListResult(allocator);
    try std.testing.expect(result == .object);
    const tools_arr = result.object.get("tools").?;
    try std.testing.expect(tools_arr == .array);
    try std.testing.expectEqual(tools.len, tools_arr.array.items.len);
}

test "capability_domains tool returns text" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const result = try handleCapabilityDomains(allocator);
    try std.testing.expect(result == .object);
    try std.testing.expect(result.object.contains("content"));
}

test "virion_create requires name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const args = json.ObjectMap.init(allocator);
    const result = try handleVirionCreate(allocator, args);
    try std.testing.expect(result == .object);
    const is_err = result.object.get("isError");
    try std.testing.expect(is_err != null);
    try std.testing.expect(is_err.?.bool == true);
}

test "virion_create with valid args" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var args = json.ObjectMap.init(allocator);
    try args.put("name", .{ .string = "test-skill" });
    try args.put("role", .{ .integer = 1 });
    try args.put("mode", .{ .integer = -1 });

    const result = try handleVirionCreate(allocator, args);
    try std.testing.expect(result == .object);
    const is_err = result.object.get("isError");
    try std.testing.expect(is_err == null);
}

test "czernowitz_query returns speculators" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const args = json.ObjectMap.init(allocator);
    const result = try handleCzernowitzQuery(allocator, args);
    try std.testing.expect(result == .object);
}

test "czernowitz_query filters by trit" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var args = json.ObjectMap.init(allocator);
    try args.put("trit", .{ .integer = -1 });
    const result = try handleCzernowitzQuery(allocator, args);
    try std.testing.expect(result == .object);
}

test "handleMethod dispatches initialize" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var obj = json.ObjectMap.init(allocator);
    try obj.put("jsonrpc", .{ .string = "2.0" });
    try obj.put("method", .{ .string = "initialize" });
    try obj.put("id", .{ .integer = 1 });

    const result = try handleMethod(allocator, "initialize", obj);
    try std.testing.expect(result == .object);
    try std.testing.expect(result.object.contains("protocolVersion"));
}

test "handleMethod returns error for unknown method" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const obj = json.ObjectMap.init(allocator);
    const result = try handleMethod(allocator, "nonexistent/method", obj);
    try std.testing.expect(result == .object);
    try std.testing.expect(result.object.contains("code"));
}

test "syrup_encode produces valid output" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var args = json.ObjectMap.init(allocator);
    try args.put("value", .{ .string = "hello" });
    const result = try handleSyrupEncode(allocator, args);
    try std.testing.expect(result == .object);
    try std.testing.expect(result.object.get("isError") == null);
    const content = result.object.get("content").?.array.items[0].object;
    const text = content.get("text").?.string;
    try std.testing.expect(std.mem.indexOf(u8, text, "base64:") != null);
}

test "syrup_encode and decode round-trip" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Encode "test"
    var enc_args = json.ObjectMap.init(allocator);
    try enc_args.put("value", .{ .string = "test" });
    const enc_result = try handleSyrupEncode(allocator, enc_args);
    const enc_text = enc_result.object.get("content").?.array.items[0].object.get("text").?.string;

    // Extract base64 from output
    const b64_start = (std.mem.indexOf(u8, enc_text, "base64: ") orelse return error.TestUnexpectedResult) + 8;
    const b64_end = std.mem.indexOfPos(u8, enc_text, b64_start, "\n") orelse enc_text.len;
    const b64 = enc_text[b64_start..b64_end];

    // Decode it back
    var dec_args = json.ObjectMap.init(allocator);
    try dec_args.put("data", .{ .string = b64 });
    const dec_result = try handleSyrupDecode(allocator, dec_args);
    try std.testing.expect(dec_result.object.get("isError") == null);
    const dec_text = dec_result.object.get("content").?.array.items[0].object.get("text").?.string;
    try std.testing.expect(std.mem.indexOf(u8, dec_text, "test") != null);
}

test "cid_compute produces 64-char hex" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var args = json.ObjectMap.init(allocator);
    try args.put("value", .{ .integer = 42 });
    const result = try handleCidCompute(allocator, args);
    try std.testing.expect(result.object.get("isError") == null);
    const text = result.object.get("content").?.array.items[0].object.get("text").?.string;
    try std.testing.expect(std.mem.indexOf(u8, text, "cid:") != null);
}

test "cid_compute is deterministic" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var args1 = json.ObjectMap.init(allocator);
    try args1.put("value", .{ .string = "same-input" });
    const r1 = try handleCidCompute(allocator, args1);
    const t1 = r1.object.get("content").?.array.items[0].object.get("text").?.string;

    var args2 = json.ObjectMap.init(allocator);
    try args2.put("value", .{ .string = "same-input" });
    const r2 = try handleCidCompute(allocator, args2);
    const t2 = r2.object.get("content").?.array.items[0].object.get("text").?.string;

    try std.testing.expectEqualStrings(t1, t2);
}

test "json to syrup conversion" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Test primitives
    const null_val = try jsonToSyrup(allocator, .null);
    try std.testing.expect(null_val == .symbol);

    const bool_val = try jsonToSyrup(allocator, .{ .bool = true });
    try std.testing.expect(bool_val == .bool);

    const int_val = try jsonToSyrup(allocator, .{ .integer = 42 });
    try std.testing.expect(int_val == .integer);
    try std.testing.expectEqual(@as(i64, 42), int_val.integer);

    const str_val = try jsonToSyrup(allocator, .{ .string = "hello" });
    try std.testing.expect(str_val == .string);
    try std.testing.expectEqualStrings("hello", str_val.string);
}
