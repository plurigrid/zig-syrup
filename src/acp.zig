//! ACP (Agent Client Protocol) Implementation in Zig
//!
//! Uses zig-syrup for serialization instead of JSON-RPC.
//! This enables CapTP-native communication with OCapN semantics.
//!
//! Borrowed from:
//! - xenodium/acp.el (protocol flow)
//! - soramimi/mcp-sdk-cpp (struct patterns)  
//! - toad/src/toad/acp/protocol.py (type definitions)
//! - agentclientprotocol/registry (agent schema)
//!
//! Reference: https://agentclientprotocol.com/protocol/

const std = @import("std");
const syrup = @import("syrup");
const xev_io = @import("xev_io");
const acp_mnxfi = @import("acp_mnxfi");

const Allocator = std.mem.Allocator;

// ============================================================================
// Protocol Constants (from acp.el)
// ============================================================================

pub const PROTOCOL_VERSION: i64 = 1;
pub const JSONRPC_VERSION = "2.0"; // For JSON-RPC compat layer

// ============================================================================
// Agent Registry Types (from agent.schema.json)
// ============================================================================

pub const AgentTarget = enum {
    darwin_aarch64,
    darwin_x86_64,
    linux_aarch64,
    linux_x86_64,
    windows_aarch64,
    windows_x86_64,

    pub fn fromString(s: []const u8) ?AgentTarget {
        const map = std.StaticStringMap(AgentTarget).initComptime(.{
            .{ "darwin-aarch64", .darwin_aarch64 },
            .{ "darwin-x86_64", .darwin_x86_64 },
            .{ "linux-aarch64", .linux_aarch64 },
            .{ "linux-x86_64", .linux_x86_64 },
            .{ "windows-aarch64", .windows_aarch64 },
            .{ "windows-x86_64", .windows_x86_64 },
        });
        return map.get(s);
    }
};

pub const BinaryTarget = struct {
    archive: []const u8,
    cmd: []const u8,
    args: ?[]const []const u8 = null,
    env: ?[]const EnvVariable = null,
};

pub const PackageDistribution = struct {
    package: []const u8,
    args: ?[]const []const u8 = null,
    env: ?[]const EnvVariable = null,
};

pub const Distribution = struct {
    binary: ?std.StringHashMap(BinaryTarget) = null,
    npx: ?PackageDistribution = null,
    uvx: ?PackageDistribution = null,
};

/// Agent registry entry (from agent.schema.json)
pub const AgentEntry = struct {
    id: []const u8,
    name: []const u8,
    version: []const u8,
    description: []const u8,
    repository: ?[]const u8 = null,
    authors: ?[]const []const u8 = null,
    license: ?[]const u8 = null,
    icon: ?[]const u8 = null,
    distribution: Distribution,
};

// ============================================================================
// ACP Protocol Types (from toad/protocol.py)

/// Client capabilities sent during initialization
pub const ClientCapabilities = struct {
    fs: ?FileSystemCapability = null,
    terminal: bool = false,

    pub const FileSystemCapability = struct {
        read_text_file: bool = false,
        write_text_file: bool = false,
    };

    /// Encode to Syrup dictionary
    pub fn toSyrup(self: ClientCapabilities, allocator: Allocator) !syrup.Value {
        // Build entries using inline allocation
        var entry_count: usize = 1; // terminal always present
        if (self.fs != null) entry_count += 1;

        const entries = try allocator.alloc(syrup.Value.DictEntry, entry_count);
        var idx: usize = 0;

        if (self.fs) |fs| {
            const fs_entries = try allocator.alloc(syrup.Value.DictEntry, 2);
            fs_entries[0] = .{
                .key = syrup.symbol("readTextFile"),
                .value = syrup.boolean(fs.read_text_file),
            };
            fs_entries[1] = .{
                .key = syrup.symbol("writeTextFile"),
                .value = syrup.boolean(fs.write_text_file),
            };

            entries[idx] = .{
                .key = syrup.symbol("fs"),
                .value = syrup.dictionary(fs_entries),
            };
            idx += 1;
        }

        entries[idx] = .{
            .key = syrup.symbol("terminal"),
            .value = syrup.boolean(self.terminal),
        };

        return syrup.dictionary(entries);
    }
};

/// Agent capabilities returned from initialization
pub const AgentCapabilities = struct {
    load_session: bool = false,
    prompt_capabilities: PromptCapabilities = .{},

    pub const PromptCapabilities = struct {
        image: bool = false,
        audio: bool = false,
        embedded_content: bool = false,
    };

    /// Decode from Syrup dictionary
    pub fn fromSyrup(value: syrup.Value) !AgentCapabilities {
        if (value != .dictionary) return error.InvalidType;

        var result = AgentCapabilities{};
        for (value.dictionary) |entry| {
            if (entry.key == .symbol) {
                if (std.mem.eql(u8, entry.key.symbol, "loadSession")) {
                    if (entry.value == .bool) result.load_session = entry.value.bool;
                } else if (std.mem.eql(u8, entry.key.symbol, "promptCapabilities")) {
                    if (entry.value == .dictionary) {
                        for (entry.value.dictionary) |pe| {
                            if (pe.key == .symbol) {
                                if (std.mem.eql(u8, pe.key.symbol, "image")) {
                                    if (pe.value == .bool) result.prompt_capabilities.image = pe.value.bool;
                                } else if (std.mem.eql(u8, pe.key.symbol, "audio")) {
                                    if (pe.value == .bool) result.prompt_capabilities.audio = pe.value.bool;
                                } else if (std.mem.eql(u8, pe.key.symbol, "embeddedContent")) {
                                    if (pe.value == .bool) result.prompt_capabilities.embedded_content = pe.value.bool;
                                }
                            }
                        }
                    }
                }
            }
        }
        return result;
    }
};

/// Implementation info (client or agent)
pub const Implementation = struct {
    name: []const u8,
    title: ?[]const u8 = null,
    version: []const u8,

    pub fn toSyrup(self: Implementation, allocator: Allocator) !syrup.Value {
        // Count entries: name + version + optional title
        var entry_count: usize = 2;
        if (self.title != null) entry_count += 1;

        const entries = try allocator.alloc(syrup.Value.DictEntry, entry_count);
        var idx: usize = 0;

        entries[idx] = .{ .key = syrup.symbol("name"), .value = syrup.string(self.name) };
        idx += 1;
        if (self.title) |t| {
            entries[idx] = .{ .key = syrup.symbol("title"), .value = syrup.string(t) };
            idx += 1;
        }
        entries[idx] = .{ .key = syrup.symbol("version"), .value = syrup.string(self.version) };

        return syrup.dictionary(entries);
    }
};

// ============================================================================
// ACP Messages (Syrup Records instead of JSON-RPC)
// ============================================================================

/// ACP message types as Syrup records
/// Using OCapN convention: <desc:op-name args...>
pub const Message = union(enum) {
    // Initialization
    initialize: InitializeRequest,
    initialize_response: InitializeResponse,

    // Session
    session_new: SessionNewRequest,
    session_new_response: SessionNewResponse,
    session_prompt: SessionPromptRequest,
    session_prompt_response: SessionPromptResponse,
    session_cancel: SessionCancelNotification,
    session_update: SessionUpdateNotification,

    // File system
    fs_read_text_file: FsReadRequest,
    fs_read_text_file_response: FsReadResponse,
    fs_write_text_file: FsWriteRequest,

    // Terminal
    terminal_create: TerminalCreateRequest,
    terminal_create_response: TerminalCreateResponse,
    terminal_output: TerminalOutputRequest,
    terminal_output_response: TerminalOutputResponse,
    terminal_kill: TerminalKillRequest,

    // Market (mnx.fi prediction markets)
    market_state_update: acp_mnxfi.MarketStateUpdate,
    position_open_request: acp_mnxfi.PositionOpenRequest,
    position_open_response: acp_mnxfi.PositionOpenResponse,
    portfolio_snapshot: acp_mnxfi.PortfolioSnapshot,
    brick_diagram_meta: acp_mnxfi.BrickDiagramMeta,
    arkhai_liquidation: acp_mnxfi.ArkaiLiquidation,

    pub const InitializeRequest = struct {
        protocol_version: i64,
        client_capabilities: ClientCapabilities,
        client_info: Implementation,
    };

    pub const InitializeResponse = struct {
        protocol_version: i64,
        agent_capabilities: AgentCapabilities,
        agent_info: ?Implementation = null,
        auth_methods: []const AuthMethod = &.{},
    };

    pub const SessionNewRequest = struct {
        cwd: []const u8,
        mcp_servers: []const McpServer = &.{},
    };

    pub const SessionNewResponse = struct {
        session_id: []const u8,
    };

    pub const SessionPromptRequest = struct {
        session_id: []const u8,
        prompt: []const ContentBlock,
    };

    pub const SessionPromptResponse = struct {
        stop_reason: StopReason,
    };

    pub const SessionCancelNotification = struct {
        session_id: []const u8,
    };

    pub const SessionUpdateNotification = struct {
        session_id: []const u8,
        update: SessionUpdate,
    };

    pub const FsReadRequest = struct {
        session_id: []const u8,
        path: []const u8,
        line: ?i64 = null,
        limit: ?i64 = null,
    };

    pub const FsReadResponse = struct {
        content: []const u8,
    };

    pub const FsWriteRequest = struct {
        session_id: []const u8,
        path: []const u8,
        content: []const u8,
    };

    pub const TerminalCreateRequest = struct {
        session_id: []const u8,
        command: []const u8,
        args: ?[]const []const u8 = null,
        cwd: ?[]const u8 = null,
    };

    pub const TerminalCreateResponse = struct {
        terminal_id: []const u8,
    };

    pub const TerminalOutputRequest = struct {
        session_id: []const u8,
        terminal_id: []const u8,
    };

    pub const TerminalOutputResponse = struct {
        output: []const u8,
        truncated: bool,
        exit_status: ?TerminalExitStatus = null,
    };

    pub const TerminalKillRequest = struct {
        session_id: []const u8,
        terminal_id: []const u8,
    };

    /// Encode message to Syrup record
    pub fn toSyrup(self: Message, allocator: Allocator) !syrup.Value {
        return switch (self) {
            .initialize => |req| blk: {
                // Single allocation: [label, field0, field1, field2]
                const combined = try allocator.alloc(syrup.Value, 1 + 3);
                combined[0] = syrup.symbol("initialize");
                const label_ptr = &combined[0];
                const fields = combined[1..];
                fields[0] = syrup.integer(req.protocol_version);
                fields[1] = try req.client_capabilities.toSyrup(allocator);
                fields[2] = try req.client_info.toSyrup(allocator);
                break :blk syrup.record(label_ptr, fields);
            },
            .session_new => |req| blk: {
                // Single allocation: [label, field0]
                const combined = try allocator.alloc(syrup.Value, 1 + 1);
                combined[0] = syrup.symbol("session/new");
                const label_ptr = &combined[0];
                const fields = combined[1..];
                fields[0] = syrup.string(req.cwd);
                break :blk syrup.record(label_ptr, fields);
            },
            .session_prompt => |req| blk: {
                var content_values = try allocator.alloc(syrup.Value, req.prompt.len);
                for (req.prompt, 0..) |block, i| {
                    content_values[i] = try block.toSyrup(allocator);
                }
                // Single allocation: [label, field0, field1]
                const combined = try allocator.alloc(syrup.Value, 1 + 2);
                combined[0] = syrup.symbol("session/prompt");
                const label_ptr = &combined[0];
                const fields = combined[1..];
                fields[0] = syrup.string(req.session_id);
                fields[1] = syrup.list(content_values);
                break :blk syrup.record(label_ptr, fields);
            },
            .session_cancel => |notif| blk: {
                // Single allocation: [label, field0]
                const combined = try allocator.alloc(syrup.Value, 1 + 1);
                combined[0] = syrup.symbol("session/cancel");
                const label_ptr = &combined[0];
                const fields = combined[1..];
                fields[0] = syrup.string(notif.session_id);
                break :blk syrup.record(label_ptr, fields);
            },
            .fs_read_text_file => |req| blk: {
                // Single allocation: [label, field0, field1]
                const combined = try allocator.alloc(syrup.Value, 1 + 2);
                combined[0] = syrup.symbol("fs/read_text_file");
                const label_ptr = &combined[0];
                const fields = combined[1..];
                fields[0] = syrup.string(req.session_id);
                fields[1] = syrup.string(req.path);
                break :blk syrup.record(label_ptr, fields);
            },
            .terminal_create => |req| blk: {
                // Single allocation: [label, field0, field1]
                const combined = try allocator.alloc(syrup.Value, 1 + 2);
                combined[0] = syrup.symbol("terminal/create");
                const label_ptr = &combined[0];
                const fields = combined[1..];
                fields[0] = syrup.string(req.session_id);
                fields[1] = syrup.string(req.command);
                break :blk syrup.record(label_ptr, fields);
            },
            else => error.NotImplemented,
        };
    }
};

// ============================================================================
// Content Types
// ============================================================================

pub const ContentBlock = union(enum) {
    text: TextContent,
    image: ImageContent,
    audio: AudioContent,
    terminal_frame: TerminalFrameContent, // Extension for notcurses

    pub const TextContent = struct {
        text: []const u8,
    };

    pub const ImageContent = struct {
        data: []const u8,
        mime_type: []const u8,
    };

    pub const AudioContent = struct {
        data: []const u8,
        mime_type: []const u8,
    };

    /// Extension: Agent-generated terminal frame (notcurses plane)
    pub const TerminalFrameContent = struct {
        data: []const u8, // ANSI sequences or serialized notcurses plane
        mime_type: []const u8, // "text/x-ansi" or "application/x-notcurses-plane"
        width: ?i64 = null,
        height: ?i64 = null,
    };

    pub fn toSyrup(self: ContentBlock, allocator: Allocator) !syrup.Value {
        return switch (self) {
            .text => |t| blk: {
                // Single allocation: [label, field0]
                const combined = try allocator.alloc(syrup.Value, 1 + 1);
                combined[0] = syrup.symbol("text");
                const label_ptr = &combined[0];
                const fields = combined[1..];
                fields[0] = syrup.string(t.text);
                break :blk syrup.record(label_ptr, fields);
            },
            .image => |img| blk: {
                // Single allocation: [label, field0, field1]
                const combined = try allocator.alloc(syrup.Value, 1 + 2);
                combined[0] = syrup.symbol("image");
                const label_ptr = &combined[0];
                const fields = combined[1..];
                fields[0] = syrup.bytes(img.data);
                fields[1] = syrup.string(img.mime_type);
                break :blk syrup.record(label_ptr, fields);
            },
            .terminal_frame => |tf| blk: {
                // Count entries: data + mimeType + optional width + optional height
                var entry_count: usize = 2;
                if (tf.width != null) entry_count += 1;
                if (tf.height != null) entry_count += 1;

                const entries = try allocator.alloc(syrup.Value.DictEntry, entry_count);
                var idx: usize = 0;
                entries[idx] = .{ .key = syrup.symbol("data"), .value = syrup.bytes(tf.data) };
                idx += 1;
                entries[idx] = .{ .key = syrup.symbol("mimeType"), .value = syrup.string(tf.mime_type) };
                idx += 1;
                if (tf.width) |w| {
                    entries[idx] = .{ .key = syrup.symbol("width"), .value = syrup.integer(w) };
                    idx += 1;
                }
                if (tf.height) |h| {
                    entries[idx] = .{ .key = syrup.symbol("height"), .value = syrup.integer(h) };
                    idx += 1;
                }
                // Single allocation: [label, field0]
                const combined = try allocator.alloc(syrup.Value, 1 + 1);
                combined[0] = syrup.symbol("terminal-frame");
                const label_ptr = &combined[0];
                const fields = combined[1..];
                fields[0] = syrup.dictionary(entries);
                break :blk syrup.record(label_ptr, fields);
            },
            else => error.NotImplemented,
        };
    }
};

// ============================================================================
// Session Updates
// ============================================================================

pub const SessionUpdate = union(enum) {
    agent_message_chunk: AgentMessageChunk,
    tool_call: ToolCall,
    tool_call_update: ToolCallUpdate,
    plan: Plan,

    pub const AgentMessageChunk = struct {
        content: ContentBlock,
    };

    pub const ToolCall = struct {
        tool_call_id: []const u8,
        title: []const u8,
        kind: ToolKind,
        status: ToolCallStatus,
    };

    pub const ToolCallUpdate = struct {
        tool_call_id: []const u8,
        status: ?ToolCallStatus = null,
        content: ?[]const ToolCallContent = null,
    };

    pub const Plan = struct {
        entries: []const PlanEntry,
    };
};

pub const ToolKind = enum {
    read,
    edit,
    delete,
    move,
    search,
    execute,
    think,
    fetch,
    render, // Extension for notcurses output
    other,
};

pub const ToolCallStatus = enum {
    pending,
    in_progress,
    completed,
    failed,
};

pub const ToolCallContent = union(enum) {
    content: ContentBlock,
    diff: DiffContent,
    terminal: TerminalContent,

    pub const DiffContent = struct {
        path: []const u8,
        old_text: ?[]const u8 = null,
        new_text: []const u8,
    };

    pub const TerminalContent = struct {
        terminal_id: []const u8,
    };
};

pub const PlanEntry = struct {
    content: []const u8,
    status: enum { pending, in_progress, completed } = .pending,
    priority: enum { high, medium, low } = .medium,
};

pub const StopReason = enum {
    end_turn,
    max_tokens,
    max_turn_requests,
    refusal,
    cancelled,
};

pub const AuthMethod = struct {
    id: []const u8,
    name: []const u8,
    description: ?[]const u8 = null,
};

pub const McpServer = struct {
    name: []const u8,
    command: []const u8,
    args: []const []const u8 = &.{},
    env: []const EnvVariable = &.{},
};

pub const EnvVariable = struct {
    name: []const u8,
    value: []const u8,
};

pub const TerminalExitStatus = struct {
    exit_code: ?i32 = null,
    signal: ?[]const u8 = null,
};

// ============================================================================
// Terminal RPC Methods (from toad/acp/agent.py)
// These are standalone request/response types for direct use
// ============================================================================

/// Standalone request: terminal/create (more complete than Message variant)
pub const CreateTerminalParams = struct {
    command: []const u8,
    args: ?[]const []const u8 = null,
    cwd: ?[]const u8 = null,
    env: ?[]const EnvVariable = null,
    output_byte_limit: ?i64 = null,
    session_id: ?[]const u8 = null,
};

/// Standalone response: terminal/create
pub const CreateTerminalResult = struct {
    terminal_id: []const u8,
};

/// Standalone request: terminal/output
pub const TerminalOutputParams = struct {
    terminal_id: []const u8,
};

/// Standalone response: terminal/output
pub const TerminalOutputResult = struct {
    output: []const u8,
    exit_status: ?TerminalExitStatus = null,
};

/// Standalone request: terminal/kill
pub const KillTerminalParams = struct {
    terminal_id: []const u8,
};

/// Standalone request: terminal/wait_for_exit
pub const WaitForExitParams = struct {
    terminal_id: []const u8,
    timeout_ms: ?i64 = null,
};

/// Standalone response: terminal/wait_for_exit
pub const WaitForExitResult = struct {
    exit_status: TerminalExitStatus,
};

// ============================================================================
// File System RPC Methods (from acp.el)
// ============================================================================

/// Standalone request: fs/read_text_file
pub const ReadTextFileParams = struct {
    path: []const u8,
    start_line: ?i64 = null,
    end_line: ?i64 = null,
};

/// Standalone response: fs/read_text_file
pub const ReadTextFileResult = struct {
    text: []const u8,
    total_lines: ?i64 = null,
};

/// Request: fs/write_text_file
pub const WriteTextFileRequest = struct {
    path: []const u8,
    text: []const u8,
    create_directories: bool = false,
};

/// Response: fs/write_text_file (empty on success)
pub const WriteTextFileResponse = struct {};

// ============================================================================
// Permission Request (from toad/protocol.py)
// ============================================================================

pub const PermissionOptionKind = enum {
    allow_once,
    allow_always,
    reject_once,
    reject_always,
};

pub const PermissionOption = struct {
    option_id: []const u8,
    name: []const u8,
    kind: PermissionOptionKind,
};

/// Request: session/request_permission
pub const RequestPermissionRequest = struct {
    session_id: []const u8,
    tool_call: ToolCallContent,
    options: []const PermissionOption,
    message: ?[]const u8 = null,
};

pub const PermissionOutcome = union(enum) {
    selected: struct { option_id: []const u8 },
    cancelled: void,
};

/// Response: session/request_permission  
pub const RequestPermissionResponse = struct {
    outcome: PermissionOutcome,
};

// ============================================================================
// Session Modes (from toad/protocol.py)
// ============================================================================

pub const SessionMode = struct {
    id: []const u8,
    name: []const u8,
    description: ?[]const u8 = null,
};

pub const SessionModeState = struct {
    current_mode_id: []const u8,
    available_modes: []const SessionMode,
};

pub const ModelInfo = struct {
    model_id: []const u8,
    name: []const u8,
    description: ?[]const u8 = null,
};

pub const SessionModelState = struct {
    current_model_id: []const u8,
    available_models: []const ModelInfo,
};

// ============================================================================
// ACP Client (borrowed from acp.el pattern)

pub const AcpClient = struct {
    allocator: Allocator,
    async_ctx: *xev_io.SyrupAsyncContext,
    fd: i32,

    // State
    session_id: ?[]const u8 = null,
    agent_capabilities: ?AgentCapabilities = null,

    pub fn init(allocator: Allocator, loop: *xev_io.xev.Loop, fd: i32) !*AcpClient {
        const client = try allocator.create(AcpClient);
        client.* = .{
            .allocator = allocator,
            .async_ctx = try xev_io.SyrupAsyncContext.init(allocator, loop, 64 * 1024),
            .fd = fd,
        };
        return client;
    }

    pub fn deinit(self: *AcpClient) void {
        self.async_ctx.deinit();
        self.allocator.destroy(self);
    }

    /// Send initialize request
    pub fn initialize(
        self: *AcpClient,
        capabilities: ClientCapabilities,
        info: Implementation,
    ) !void {
        const msg = Message{
            .initialize = .{
                .protocol_version = PROTOCOL_VERSION,
                .client_capabilities = capabilities,
                .client_info = info,
            },
        };

        const value = try msg.toSyrup(self.allocator);
        try self.async_ctx.asyncWrite(self.fd, value, onInitializeResponse);
    }

    fn onInitializeResponse(
        userdata: ?*anyopaque,
        loop: *xev_io.xev.Loop,
        completion: *xev_io.xev.Completion,
        result: xev_io.xev.Result,
    ) xev_io.xev.CallbackAction {
        _ = loop;
        _ = completion;
        _ = result;
        const ctx: *xev_io.SyrupAsyncContext = @ptrCast(@alignCast(userdata));
        _ = ctx;
        // Parse response, update agent_capabilities
        return .disarm;
    }

    /// Create new session
    pub fn newSession(self: *AcpClient, cwd: []const u8) !void {
        const msg = Message{
            .session_new = .{ .cwd = cwd },
        };
        const value = try msg.toSyrup(self.allocator);
        try self.async_ctx.asyncWrite(self.fd, value, onSessionNewResponse);
    }

    fn onSessionNewResponse(
        userdata: ?*anyopaque,
        loop: *xev_io.xev.Loop,
        completion: *xev_io.xev.Completion,
        result: xev_io.xev.Result,
    ) xev_io.xev.CallbackAction {
        _ = loop;
        _ = completion;
        _ = result;
        _ = userdata;
        // Parse response, store session_id
        return .disarm;
    }

    /// Send prompt
    pub fn prompt(self: *AcpClient, content: []const ContentBlock) !void {
        if (self.session_id == null) return error.NoSession;

        const msg = Message{
            .session_prompt = .{
                .session_id = self.session_id.?,
                .prompt = content,
            },
        };
        const value = try msg.toSyrup(self.allocator);
        try self.async_ctx.asyncWrite(self.fd, value, onPromptResponse);
    }

    fn onPromptResponse(
        userdata: ?*anyopaque,
        loop: *xev_io.xev.Loop,
        completion: *xev_io.xev.Completion,
        result: xev_io.xev.Result,
    ) xev_io.xev.CallbackAction {
        _ = loop;
        _ = completion;
        _ = result;
        _ = userdata;
        // Handle streaming session/update notifications
        return .disarm;
    }

    /// Cancel current session
    pub fn cancel(self: *AcpClient) !void {
        if (self.session_id == null) return error.NoSession;

        const msg = Message{
            .session_cancel = .{
                .session_id = self.session_id.?,
            },
        };
        const value = try msg.toSyrup(self.allocator);
        try self.async_ctx.asyncWrite(self.fd, value, null);
    }

    /// Set session mode
    pub fn setMode(self: *AcpClient, mode_id: []const u8) !void {
        if (self.session_id == null) return error.NoSession;

        const msg = Message{
            .session_set_mode = .{
                .session_id = self.session_id.?,
                .mode_id = mode_id,
            },
        };
        const value = try msg.toSyrup(self.allocator);
        try self.async_ctx.asyncWrite(self.fd, value, null);
    }
};

// ============================================================================
// ACP Agent (Server-side)
// ============================================================================

pub const AcpAgent = struct {
    allocator: Allocator,
    async_ctx: *xev_io.SyrupAsyncContext,

    // Callbacks
    on_initialize: ?*const fn (*AcpAgent, Message.InitializeRequest) anyerror!Message.InitializeResponse = null,
    on_session_new: ?*const fn (*AcpAgent, Message.SessionNewRequest) anyerror!Message.SessionNewResponse = null,
    on_prompt: ?*const fn (*AcpAgent, Message.SessionPromptRequest) anyerror!void = null,
    on_fs_read: ?*const fn (*AcpAgent, Message.FsReadRequest) anyerror!Message.FsReadResponse = null,
    on_terminal_create: ?*const fn (*AcpAgent, Message.TerminalCreateRequest) anyerror!Message.TerminalCreateResponse = null,

    pub fn init(allocator: Allocator, loop: *xev_io.xev.Loop) !*AcpAgent {
        const agent = try allocator.create(AcpAgent);
        agent.* = .{
            .allocator = allocator,
            .async_ctx = try xev_io.SyrupAsyncContext.init(allocator, loop, 64 * 1024),
        };
        return agent;
    }

    pub fn deinit(self: *AcpAgent) void {
        self.async_ctx.deinit();
        self.allocator.destroy(self);
    }

    /// Send session update to client
    pub fn sendUpdate(self: *AcpAgent, fd: i32, session_id: []const u8, update: SessionUpdate) !void {
        const update_value = switch (update) {
            .agent_message_chunk => |chunk| blk: {
                // Single allocation: [label, field0]
                const inner_combined = try self.allocator.alloc(syrup.Value, 1 + 1);
                inner_combined[0] = syrup.symbol("agent_message_chunk");
                const inner_label = &inner_combined[0];
                const inner_fields = inner_combined[1..];
                inner_fields[0] = try chunk.content.toSyrup(self.allocator);
                break :blk syrup.record(inner_label, inner_fields);
            },
            .tool_call => |tc| blk: {
                const entries = try self.allocator.alloc(syrup.Value.DictEntry, 4);
                entries[0] = .{ .key = syrup.symbol("toolCallId"), .value = syrup.string(tc.tool_call_id) };
                entries[1] = .{ .key = syrup.symbol("title"), .value = syrup.string(tc.title) };
                entries[2] = .{ .key = syrup.symbol("kind"), .value = syrup.symbol(@tagName(tc.kind)) };
                entries[3] = .{ .key = syrup.symbol("status"), .value = syrup.symbol(@tagName(tc.status)) };
                // Single allocation: [label, field0]
                const inner_combined = try self.allocator.alloc(syrup.Value, 1 + 1);
                inner_combined[0] = syrup.symbol("tool_call");
                const inner_label = &inner_combined[0];
                const inner_fields = inner_combined[1..];
                inner_fields[0] = syrup.dictionary(entries);
                break :blk syrup.record(inner_label, inner_fields);
            },
            else => return error.NotImplemented,
        };

        // Single allocation: [label, field0, field1]
        const combined = try self.allocator.alloc(syrup.Value, 1 + 2);
        combined[0] = syrup.symbol("session/update");
        const label_ptr = &combined[0];
        const fields = combined[1..];
        fields[0] = syrup.string(session_id);
        fields[1] = update_value;

        const msg = syrup.record(label_ptr, fields);
        try self.async_ctx.asyncWrite(fd, msg, null);
    }
};

// ============================================================================
// Tests
// ============================================================================

test "client capabilities to syrup" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const caps = ClientCapabilities{
        .fs = .{ .read_text_file = true, .write_text_file = true },
        .terminal = true,
    };

    const value = try caps.toSyrup(allocator);
    _ = value;
    // Would encode to syrup and verify
}

test "initialize message encoding" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const msg = Message{
        .initialize = .{
            .protocol_version = 1,
            .client_capabilities = .{ .terminal = true },
            .client_info = .{ .name = "zig-acp", .version = "0.1.0" },
        },
    };

    const value = try msg.toSyrup(allocator);
    try std.testing.expect(value == .record);
    try std.testing.expectEqualStrings("initialize", value.record.label.symbol);
}

test "content block encoding" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const content = ContentBlock{
        .text = .{ .text = "Hello, agent!" },
    };

    const value = try content.toSyrup(allocator);
    try std.testing.expect(value == .record);
    try std.testing.expectEqualStrings("text", value.record.label.symbol);
}

test "terminal frame extension" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Agent-generated ANSI content
    const ansi_content = "\x1b[32m████████████████\x1b[0m Progress: 50%";

    const content = ContentBlock{
        .terminal_frame = .{
            .data = ansi_content,
            .mime_type = "text/x-ansi",
            .width = 40,
            .height = 1,
        },
    };

    const value = try content.toSyrup(allocator);
    try std.testing.expect(value == .record);
    try std.testing.expectEqualStrings("terminal-frame", value.record.label.symbol);
}
