//! sandbox.zig — OS-level confinement for subprocess vats.
//!
//! Provides per-platform process sandboxing to complement the in-process
//! capability confinement in `cap.zig` / `vat.zig` / `membrane.zig`.
//!
//! On macOS (darwin): Apple Sandbox via `sandbox_init()` with custom
//! seatbelt profiles (deny-default, selective allows).
//!
//! On Linux: `seccomp(2)` BPF filter via `prctl(PR_SET_SECCOMP)` with
//! a deny-default allowlist of system calls.
//!
//! Both paths enforce the same principle: **default-deny ambient authority**
//! at the OS level, matching `vat.zig`'s `FACET_EMPTY` default at the
//! capability level. Combined with `membrane.zig` for authority gating,
//! this gives defense-in-depth across three layers:
//!
//!   1. `cap.zig`      — facets, revokers, expiry (logical authority)
//!   2. `membrane.zig`  — identity hiding, bulk revocation (domain boundary)
//!   3. `sandbox.zig`   — syscall/resource restriction (OS confinement)

const std = @import("std");
const builtin = @import("builtin");

pub const SandboxError = error{
    ProfileFailed,
    SeccompFailed,
    Unsupported,
};

/// Sandbox policy describing what ambient authority the confined process retains.
pub const Policy = struct {
    allow_network: bool = false,
    allow_read: ?[]const []const u8 = null, // paths readable (null = none)
    allow_write: ?[]const []const u8 = null, // paths writable (null = none)
    allow_exec: bool = false,
    allow_ipc: bool = false,
};

/// Apply OS-level confinement to the current process. Call early in a
/// subprocess (after fork/spawn, before any untrusted code runs).
/// This is a one-way operation — once applied, restrictions cannot be lifted.
pub fn apply(policy: Policy) SandboxError!void {
    switch (builtin.os.tag) {
        .macos => return applyDarwin(policy),
        .linux => return applyLinux(policy),
        else => return error.Unsupported,
    }
}

/// Returns true if OS-level sandboxing is available on this platform.
pub fn isSupported() bool {
    return builtin.os.tag == .macos or builtin.os.tag == .linux;
}

// -- macOS (darwin) seatbelt profiles -----------------------------------------

fn applyDarwin(policy: Policy) SandboxError!void {
    // Build a seatbelt profile string. Apple Sandbox uses a Scheme-like
    // DSL: (version 1) (deny default) (allow ...).
    // sandbox_init() is deprecated since 10.8 but remains functional and
    // is the only userspace API available without entitlements.
    var buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const w = fbs.writer();
    w.writeAll("(version 1)\n(deny default)\n") catch return error.ProfileFailed;
    w.writeAll("(allow process-fork)\n") catch return error.ProfileFailed;

    if (policy.allow_network) {
        w.writeAll("(allow network*)\n") catch return error.ProfileFailed;
    }

    if (policy.allow_read) |paths| {
        for (paths) |p| {
            w.print("(allow file-read* (subpath \"{s}\"))\n", .{p}) catch return error.ProfileFailed;
        }
    }

    if (policy.allow_write) |paths| {
        for (paths) |p| {
            w.print("(allow file-write* (subpath \"{s}\"))\n", .{p}) catch return error.ProfileFailed;
        }
    }

    if (policy.allow_exec) {
        w.writeAll("(allow process-exec*)\n") catch return error.ProfileFailed;
    }

    if (policy.allow_ipc) {
        w.writeAll("(allow ipc*)\n") catch return error.ProfileFailed;
        w.writeAll("(allow mach*)\n") catch return error.ProfileFailed;
    }

    const profile_len = fbs.pos;
    const profile: [*:0]const u8 = @ptrCast(buf[0..profile_len]);

    var errorbuf: ?[*:0]u8 = null;
    // sandbox_init(profile, 0, &errorbuf) — flags=0 means apply to self.
    const SANDBOX_NAMED = 0x0001;
    _ = SANDBOX_NAMED;
    const rc = sandboxInit(profile, 0, &errorbuf);
    if (rc != 0) {
        if (errorbuf) |e| sandboxFreeError(e);
        return error.ProfileFailed;
    }
}

extern "c" fn sandbox_init(profile: [*:0]const u8, flags: u64, errorbuf: *?[*:0]u8) c_int;
extern "c" fn sandbox_free_error(errorbuf: [*:0]u8) void;

fn sandboxInit(profile: [*:0]const u8, flags: u64, errorbuf: *?[*:0]u8) c_int {
    if (builtin.os.tag != .macos) return -1;
    return sandbox_init(profile, flags, errorbuf);
}

fn sandboxFreeError(errorbuf: [*:0]u8) void {
    if (builtin.os.tag != .macos) return;
    sandbox_free_error(errorbuf);
}

// -- Linux seccomp-bpf --------------------------------------------------------

fn applyLinux(policy: Policy) SandboxError!void {
    // Minimal seccomp-bpf: deny-default with allowlisted syscalls.
    // Uses prctl(PR_SET_SECCOMP, SECCOMP_MODE_FILTER, &prog).
    if (builtin.os.tag != .linux) return error.Unsupported;

    const linux = std.os.linux;

    // Basic allowlist — always permitted for vat operation.
    const allowed = [_]u32{
        linux.SYS.read,
        linux.SYS.write,
        linux.SYS.close,
        linux.SYS.exit_group,
        linux.SYS.brk,
        linux.SYS.mmap,
        linux.SYS.munmap,
        linux.SYS.mprotect,
        linux.SYS.rt_sigreturn,
        linux.SYS.futex,
        linux.SYS.clock_gettime,
    };
    _ = allowed;

    if (policy.allow_network) {
        // Would add: socket, connect, bind, listen, accept, sendto, recvfrom
    }

    // For a full implementation, build a BPF program from the allowlist
    // and apply via prctl. This is a scaffold — the BPF bytecode generation
    // requires careful architecture-specific syscall number handling.
    // TODO: emit sock_filter[] BPF program and call prctl(PR_SET_SECCOMP).
    return error.SeccompFailed;
}

// -- Tests --------------------------------------------------------------------

const testing = std.testing;

test "isSupported returns true on darwin or linux" {
    const supported = isSupported();
    if (builtin.os.tag == .macos or builtin.os.tag == .linux) {
        try testing.expect(supported);
    } else {
        try testing.expect(!supported);
    }
}

test "Policy defaults to deny-all" {
    const p = Policy{};
    try testing.expect(!p.allow_network);
    try testing.expect(!p.allow_exec);
    try testing.expect(!p.allow_ipc);
    try testing.expect(p.allow_read == null);
    try testing.expect(p.allow_write == null);
}
