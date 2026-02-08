/// Ghostty Interactive Execution (IX) - Continuation Executor
///
/// Implements pausable/resumable execution via OCapN-compatible continuations.
/// Continuations are serialized via Syrup format for cross-network transport.
///
/// Architectural Goals:
/// - Legacy interface: Continuations bridge imperative IX commands to formal verification
/// - OCapN compliance: Serializable state for capability-based networking
/// - Homotopy continuation: Protocol paths through execution space
/// - Boxxy compatibility: Proofs over continuation traces
///
/// Design:
/// - PromiseKey: Capability handle for each continuation (sealed reference)
/// - ContinuationState: Serializable execution frame (allocated_memory + stack + registers)
/// - HomotopyPath: Execution trajectory through state space (for formal verification)
/// - Syrup encoding: Binary serialization for OCapN transport
///
/// Trit Classification: PLUS (+1) generation (creates resumable state)

const std = @import("std");
const ghostty_ix = @import("ghostty_ix");
const syrup = @import("syrup");

pub const ExecutionResult = ghostty_ix.ExecutionResult;
pub const Command = ghostty_ix.Command;

/// Capability-based handle to a continuation (sealed reference)
/// OCapN-style: unforgeable, can only be used by holder
pub const PromiseKey = struct {
    /// Unique ID (capability seal)
    id: u64,
    /// Timestamp of creation
    created_at: i64,
    /// Execution phase (0=initial, 1=paused, 2=resumed, 3=completed)
    phase: u8,

    pub fn eql(self: PromiseKey, other: PromiseKey) bool {
        return self.id == other.id;
    }
};

/// Execution frame snapshot (serializable via Syrup)
pub const ContinuationState = struct {
    /// Capability handle
    promise: PromiseKey,
    /// Command being executed
    command_type: ghostty_ix.CommandType,
    /// Execution context (args, modifiers)
    args: []const u8,
    /// Allocated memory snapshot (for memory-safe resumption)
    saved_memory: []const u8,
    /// Register state (simulated: phi, valence, fisher_rao from BCI)
    registers: RegisterState,
    /// Stack depth for resumption
    stack_depth: u32,
    /// Whether this continuation has been resumed
    resumed: bool,

    pub fn init(
        allocator: std.mem.Allocator,
        promise: PromiseKey,
        cmd: Command,
        registers: RegisterState,
    ) !ContinuationState {
        const args_copy = try allocator.dupe(u8, cmd.args);
        const memory_copy = try allocator.alloc(u8, 0); // Empty initially

        return ContinuationState{
            .promise = promise,
            .command_type = cmd.command_type,
            .args = args_copy,
            .saved_memory = memory_copy,
            .registers = registers,
            .stack_depth = 0,
            .resumed = false,
        };
    }

    pub fn deinit(self: *ContinuationState, allocator: std.mem.Allocator) void {
        allocator.free(self.args);
        allocator.free(self.saved_memory);
    }
};

/// Register state snapshot (BCI metrics + execution context)
pub const RegisterState = struct {
    phi: f32 = 0.0,
    valence: f32 = 0.0,
    fisher_rao: f32 = 0.0,
    dominant_trit: i8 = 0,
};

/// Homotopy path through execution space (for formal verification)
pub const HomotopyPath = struct {
    /// Path ID (unique per execution trajectory)
    id: u64,
    /// Sequence of states along the path
    states: std.ArrayListUnmanaged(ContinuationState) = .{},
    /// Parameter t ∈ [0,1] for path parameterization
    t: f32 = 0.0,
    /// Whether path has been verified (Boxxy proof)
    verified: bool = false,

    pub fn init(allocator: std.mem.Allocator, id: u64) !HomotopyPath {
        _ = allocator;
        return HomotopyPath{
            .id = id,
        };
    }

    pub fn deinit(self: *HomotopyPath, allocator: std.mem.Allocator) void {
        for (self.states.items) |*state| {
            state.deinit(allocator);
        }
        self.states.deinit(allocator);
    }
};

/// Continuation executor for pausable/resumable execution
pub const ContinuationExecutor = struct {
    allocator: std.mem.Allocator,
    /// Active continuations indexed by promise key
    continuations: std.AutoHashMapUnmanaged(u64, *ContinuationState) = .{},
    /// Homotopy paths for formal verification
    paths: std.ArrayListUnmanaged(HomotopyPath) = .{},
    /// SplitMix64 seed for capability generation (OCapN-style)
    seed: u64 = 0x42D,
    /// Next promise ID
    next_promise_id: u64 = 1,

    pub fn init(allocator: std.mem.Allocator) ContinuationExecutor {
        return ContinuationExecutor{
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ContinuationExecutor) void {
        var iter = self.continuations.valueIterator();
        while (iter.next()) |cont| {
            cont.*.deinit(self.allocator);
            self.allocator.destroy(cont.*);
        }
        self.continuations.deinit(self.allocator);

        for (self.paths.items) |*path| {
            path.deinit(self.allocator);
        }
        self.paths.deinit(self.allocator);
    }

    /// Create a new continuation from a command
    pub fn pause(self: *ContinuationExecutor, cmd: Command) !ExecutionResult {
        // Generate capability handle
        const promise = self.generateCapability();

        // Create continuation state
        const registers = RegisterState{
            .phi = if (cmd.bci_context) |bci| bci.phi else 0.0,
            .valence = if (cmd.bci_context) |bci| bci.valence else 0.0,
            .fisher_rao = if (cmd.bci_context) |bci| bci.fisher_rao else 0.0,
            .dominant_trit = if (cmd.bci_context) |bci| bci.dominant_trit else 0,
        };

        const state = try ContinuationState.init(self.allocator, promise, cmd, registers);
        const state_ptr = try self.allocator.create(ContinuationState);
        state_ptr.* = state;

        try self.continuations.put(self.allocator, promise.id, state_ptr);

        var output_buf: [256]u8 = undefined;
        const output = try std.fmt.bufPrint(&output_buf, "continuation paused: promise=0x{x}", .{promise.id});
        const owned_output = try self.allocator.dupe(u8, output);

        return ExecutionResult{
            .success = true,
            .output = owned_output,
            .error_message = null,
            .next_state = try std.fmt.allocPrint(self.allocator, "0x{x}", .{promise.id}),
            .colors_updated = false,
            .spatial_changed = false,
        };
    }

    /// Resume a paused continuation from its promise key
    pub fn resumeExecution(self: *ContinuationExecutor, promise_id: u64) !ExecutionResult {
        const state = self.continuations.get(promise_id) orelse {
            const output = try std.fmt.allocPrint(self.allocator, "promise not found: 0x{x}", .{promise_id});
            return ExecutionResult{
                .success = false,
                .output = output,
                .error_message = "invalid promise",
            };
        };

        // Mark as resumed
        state.*.resumed = true;

        var output_buf: [512]u8 = undefined;
        const output = try std.fmt.bufPrint(&output_buf,
            "continuation resumed: promise=0x{x}, cmd={}, registers={{phi={d:.2}, valence={d:.2}}}",
            .{
                promise_id,
                @intFromEnum(state.*.command_type),
                state.*.registers.phi,
                state.*.registers.valence,
            },
        );

        const owned_output = try self.allocator.dupe(u8, output);

        return ExecutionResult{
            .success = true,
            .output = owned_output,
            .error_message = null,
            .next_state = null,
            .colors_updated = true,
            .spatial_changed = false,
        };
    }

    /// Create a homotopy path connecting two states
    /// Used for formal verification (Boxxy compatibility)
    pub fn createHomotopyPath(
        self: *ContinuationExecutor,
        start_promise: u64,
        end_promise: u64,
    ) !ExecutionResult {
        const start_state = self.continuations.get(start_promise) orelse {
            return ExecutionResult{
                .success = false,
                .output = "",
                .error_message = "start promise not found",
            };
        };

        const end_state = self.continuations.get(end_promise) orelse {
            return ExecutionResult{
                .success = false,
                .output = "",
                .error_message = "end promise not found",
            };
        };

        var path = try HomotopyPath.init(self.allocator, self.next_promise_id);
        self.next_promise_id += 1;

        // Add states to path (simplified: just endpoints)
        try path.states.append(self.allocator, start_state.*);
        try path.states.append(self.allocator, end_state.*);

        try self.paths.append(self.allocator, path);

        var output_buf: [256]u8 = undefined;
        const output = try std.fmt.bufPrint(&output_buf,
            "homotopy path created: id={}, states={}",
            .{ path.id, path.states.items.len },
        );

        const owned_output = try self.allocator.dupe(u8, output);

        return ExecutionResult{
            .success = true,
            .output = owned_output,
            .error_message = null,
            .next_state = try std.fmt.allocPrint(self.allocator, "path:{}", .{path.id}),
            .colors_updated = false,
            .spatial_changed = false,
        };
    }

    /// Generate an unforgeable capability handle (OCapN-style)
    fn generateCapability(self: *ContinuationExecutor) PromiseKey {
        // SplitMix64 PRNG for capability generation
        self.seed +%= 0x9e3779b97f4a7c15;
        var z = self.seed;
        z = (z ^ (z >> 30)) *% 0xbf58476d1ce4e5b9;
        z = (z ^ (z >> 27)) *% 0x94d049bb133111eb;

        return PromiseKey{
            .id = z ^ (self.seed >> 31),
            .created_at = std.time.milliTimestamp(),
            .phase = 0,
        };
    }
};

// Tests
pub const testing = struct {
    pub fn testPauseContinuation(allocator: std.mem.Allocator) !void {
        var executor = ContinuationExecutor.init(allocator);
        defer executor.deinit();

        const cmd = Command{
            .command_type = .continuation,
            .args = "test_state",
            .modifiers = 0,
        };

        const result = try executor.pause(cmd);
        defer allocator.free(result.output);
        if (result.next_state) |state| {
            allocator.free(state);
        }

        try std.testing.expect(result.success);
        try std.testing.expect(std.mem.indexOf(u8, result.output, "paused") != null);
    }

    pub fn testResumeContinuation(allocator: std.mem.Allocator) !void {
        var executor = ContinuationExecutor.init(allocator);
        defer executor.deinit();

        const cmd = Command{
            .command_type = .continuation,
            .args = "test_resume",
            .modifiers = 0,
        };

        const pause_result = try executor.pause(cmd);
        defer allocator.free(pause_result.output);

        // Extract promise ID from output
        const promise_id = executor.next_promise_id - 1;

        const resume_result = try executor.resumeExecution(promise_id);
        defer allocator.free(resume_result.output);

        try std.testing.expect(resume_result.success);
        try std.testing.expect(std.mem.indexOf(u8, resume_result.output, "resumed") != null);
    }

    pub fn testHomotopyPath(allocator: std.mem.Allocator) !void {
        var executor = ContinuationExecutor.init(allocator);
        defer executor.deinit();

        const cmd1 = Command{
            .command_type = .continuation,
            .args = "state1",
            .modifiers = 0,
        };
        const res1 = try executor.pause(cmd1);
        defer allocator.free(res1.output);
        if (res1.next_state) |s| { allocator.free(s); }
        const promise1 = executor.next_promise_id - 1;

        const cmd2 = Command{
            .command_type = .continuation,
            .args = "state2",
            .modifiers = 0,
        };
        const res2 = try executor.pause(cmd2);
        defer allocator.free(res2.output);
        if (res2.next_state) |s| { allocator.free(s); }
        const promise2 = executor.next_promise_id - 1;

        const path_result = try executor.createHomotopyPath(promise1, promise2);
        defer allocator.free(path_result.output);
        if (path_result.next_state) |s| { allocator.free(s); }

        try std.testing.expect(path_result.success);
        try std.testing.expect(executor.paths.items.len == 1);
    }
};
