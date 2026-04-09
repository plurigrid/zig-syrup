//! COMPAT: Zig 0.15 → 0.16 compatibility layer for zig-syrup.
//!
//! 0.16 changes affecting this codebase:
//!   - std.fs.File removed → std.Io.File
//!   - std.Thread.Mutex removed → std.atomic.Mutex
//!   - ArrayListUnmanaged{} init removed → .empty
//!   - std.heap.GeneralPurposeAllocator → std.heap.DebugAllocator
//!   - std.io.fixedBufferStream stable but verify Writer protocol
//!
//! Strategy: comptime feature detection, no version checks.

const std = @import("std");

// ============================================================================
// ArrayListUnmanaged init
// ============================================================================

/// Empty ArrayListUnmanaged — works on both 0.15 and 0.16.
pub fn emptyList(comptime T: type) std.ArrayListUnmanaged(T) {
    const L = std.ArrayListUnmanaged(T);
    if (@hasDecl(L, "empty")) {
        return L.empty; // 0.16
    } else {
        return .{}; // 0.15
    }
}

// ============================================================================
// Mutex
// ============================================================================

/// Cross-version Mutex.
/// 0.15: std.Thread.Mutex (struct with lock/unlock)
/// 0.16: std.atomic.Mutex (enum with tryLock/unlock)
pub const Mutex = struct {
    inner: InnerType = inner_init,

    const has_thread_mutex = @hasDecl(std.Thread, "Mutex");

    const InnerType = if (has_thread_mutex)
        std.Thread.Mutex
    else if (@hasDecl(std, "atomic") and @hasDecl(std.atomic, "Mutex"))
        std.atomic.Mutex
    else
        @compileError("No Mutex found in std");

    const inner_init: InnerType = if (has_thread_mutex)
        .{}
    else
        .unlocked;

    pub fn lock(self: *Mutex) void {
        if (has_thread_mutex) {
            self.inner.lock();
        } else {
            while (!self.inner.tryLock()) {
                std.atomic.spinLoopHint();
            }
        }
    }

    pub fn unlock(self: *Mutex) void {
        self.inner.unlock();
    }
};

// ============================================================================
// File I/O
// ============================================================================

const has_fs_file = @hasDecl(std.fs, "File");

/// Cross-version File type.
pub const File = if (has_fs_file) std.fs.File else std.Io.File;

pub fn stdoutFile() File {
    if (has_fs_file) {
        return std.fs.File{ .handle = std.posix.STDOUT_FILENO };
    } else {
        return std.Io.File.stdout();
    }
}

pub fn stdinFile() File {
    if (has_fs_file) {
        return std.fs.File{ .handle = std.posix.STDIN_FILENO };
    } else {
        return std.Io.File.stdin();
    }
}

pub fn stderrFile() File {
    if (has_fs_file) {
        return std.fs.File{ .handle = std.posix.STDERR_FILENO };
    } else {
        return std.Io.File.stderr();
    }
}

/// Write bytes to a file descriptor, retrying short writes.
fn writeAllFd(fd: std.posix.fd_t, bytes: []const u8) void {
    var written: usize = 0;
    while (written < bytes.len) {
        const rc = std.c.write(fd, bytes.ptr + written, bytes.len - written);
        if (rc <= 0) break;
        written += @intCast(rc);
    }
}

pub fn stdoutWrite(bytes: []const u8) void {
    if (has_fs_file) {
        const f = std.fs.File{ .handle = std.posix.STDOUT_FILENO };
        f.writeAll(bytes) catch {};
    } else {
        writeAllFd(std.posix.STDOUT_FILENO, bytes);
    }
}

pub fn stderrWrite(bytes: []const u8) void {
    if (has_fs_file) {
        const f = std.fs.File{ .handle = std.posix.STDERR_FILENO };
        f.writeAll(bytes) catch {};
    } else {
        writeAllFd(std.posix.STDERR_FILENO, bytes);
    }
}

pub fn stdinRead(buf: []u8) usize {
    if (has_fs_file) {
        const f = std.fs.File{ .handle = std.posix.STDIN_FILENO };
        return f.read(buf) catch 0;
    } else {
        const rc = std.c.read(std.posix.STDIN_FILENO, buf.ptr, buf.len);
        if (rc <= 0) return 0;
        return @intCast(rc);
    }
}

pub fn fileWriteAll(f: File, bytes: []const u8) void {
    if (has_fs_file) {
        f.writeAll(bytes) catch {};
    } else {
        writeAllFd(f.handle, bytes);
    }
}

pub fn fileRead(f: File, buf: []u8) usize {
    if (has_fs_file) {
        return f.read(buf) catch 0;
    } else {
        const rc = std.c.read(f.handle, buf.ptr, buf.len);
        if (rc <= 0) return 0;
        return @intCast(rc);
    }
}

// ============================================================================
// Allocator
// ============================================================================

const has_gpa = @hasDecl(std.heap, "GeneralPurposeAllocator");

pub fn DebugAllocator() type {
    if (has_gpa) {
        return std.heap.GeneralPurposeAllocator(.{});
    } else {
        return std.heap.DebugAllocator(.{});
    }
}

pub fn makeDebugAllocator() DebugAllocator() {
    if (has_gpa) {
        return std.heap.GeneralPurposeAllocator(.{}){};
    } else {
        return std.heap.DebugAllocator(.{}).init;
    }
}
