# Zig 0.16 Migration Cheatsheet

Field-tested patterns from zig-syrup codebase migration (0.14 → 0.15 → 0.16).

## 1. `@cImport` → `addTranslateC` + `@import("c")`

**The big one.** `@cImport` is deprecated in 0.16. Replace with build-time translate-C.

### Before (0.14/0.15):
```zig
const c = @cImport({
    @cInclude("notcurses/notcurses.h");
});
```

### After (0.16-forward):

**Step 1:** Create a C header shim (e.g., `src/c_headers/notcurses.h`):
```c
// Zig 0.16 translate-c header for notcurses
#include <notcurses/notcurses.h>
```

**Step 2:** Wire in `build.zig`:
```zig
const nc_translate_c = b.addTranslateC(.{
    .root_source_file = b.path("src/c_headers/notcurses.h"),
    .target = target,
    .optimize = optimize,
    .link_libc = true,
});
nc_translate_c.addSystemIncludePath(.{ .cwd_relative = "/opt/homebrew/include" });
nc_translate_c.addSystemIncludePath(.{ .cwd_relative = "/usr/local/include" });
my_module.addImport("c", nc_translate_c.createModule());
```

**Step 3:** In source, change `@cImport(...)` to `@import("c")`:
```zig
const c = @import("c");
```

### POSIX variant (no external lib):
```c
// src/c_headers/posix_net.h
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <unistd.h>
```

---

## 2. `ArrayList` → `ArrayListUnmanaged`

Managed `ArrayList.init(allocator)` removed. Two patterns:

### Pattern A: Unmanaged (preferred)
```zig
// Before:
var buf = std.ArrayList(u8).init(allocator);
defer buf.deinit();
try buf.appendSlice(data);

// After:
var buf: std.ArrayListUnmanaged(u8) = .empty;
defer buf.deinit(allocator);
try buf.appendSlice(allocator, data);
```

### Pattern B: Struct-init (managed, if allocator is stored)
```zig
var buf: std.ArrayList(u8) = .{ .allocator = allocator };
```

---

## 3. `ArrayList.writer()` removed

Managed ArrayList lost `.writer()`. Use this adapter:

```zig
fn arrayListWriter(list: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator) std.io.AnyWriter {
    return .{
        .context = @ptrCast(&.{ list, alloc }),
        .writeFn = struct {
            fn write(ctx: *const anyopaque, bytes: []const u8) !usize {
                // ... adapter logic
            }
        }.write,
    };
}
```

See `src/syrup.zig` lines 29-50 for the production version used in this codebase.

---

## 4. `std.crypto.random` removed

```zig
// Before:
std.crypto.random.bytes(&buf);

// After: seed from clock, use DefaultPrng
const seed: u64 = @bitCast(std.time.nanoTimestamp());
var prng = std.Random.DefaultPrng.init(seed);
prng.random().bytes(&buf);
```

See `src/tapo_energy.zig` line 30 for example.

---

## 5. `std.time.timestamp()` / `nanoTimestamp()` changes

```zig
// Before:
const now = std.time.timestamp();

// After (0.16): use clock_gettime
const ts = std.posix.clock_gettime(.REALTIME);
const now_ns: i128 = @as(i128, ts.sec) * 1_000_000_000 + ts.nsec;
```

See `src/continuation.zig` line 17, `src/lsl_inlet.zig` line 31.

---

## 6. `deprecatedWriter` removed from stdout/stderr

```zig
// Before:
const writer = std.io.getStdOut().deprecatedWriter();

// After:
const writer = std.io.getStdOut().writer();
// or for buffered:
var bw = std.io.bufferedWriter(std.io.getStdOut().writer());
const writer = bw.writer();
```

See `src/salon_demo.zig` line 207.

---

## 7. Module visibility: `pub` everything consumed cross-module

In 0.16 with separate module definitions in build.zig, the compiler is stricter about visibility. Functions and types used from imported modules must be `pub`.

```zig
// set_game.zig — must be pub if osc1069 imports set_game and calls toTrit
pub fn toTrit(self: Card) Trit { ... }

// gumbel_trit.zig — Rng must be pub if osc1069 uses gumbel_trit.Rng
pub const Rng = struct { ... };
```

---

## 8. Unused variables are hard errors

Zig 0.15+ makes unused locals a compile error, not a warning.

```zig
// Error: unused local constant 'foo'
const foo = computeSomething();

// Fix option 1: discard
_ = computeSomething();

// Fix option 2: use it
const foo = computeSomething();
try std.testing.expect(foo < 10);
```

---

## 9. `addModule` vs `createModule` in build.zig

```zig
// Public module (importable by name from other modules):
const my_mod = b.addModule("my_mod", .{ ... });

// Private module (test-only, not importable by name):
const my_test_mod = b.createModule(.{ ... });
```

Standard pattern for test wiring:
```zig
const mod = b.addModule("name", .{
    .root_source_file = b.path("src/name.zig"),
    .target = target,
    .optimize = optimize,
});
mod.addImport("lux_color", lux_color_mod);

const test_mod = b.createModule(.{
    .root_source_file = b.path("src/name.zig"),
    .target = target,
    .optimize = optimize,
});
test_mod.addImport("lux_color", lux_color_mod);
const tests = b.addTest(.{ .root_module = test_mod });
const run_tests = b.addRunArtifact(tests);
const test_step = b.step("test-name", "Run name tests");
test_step.dependOn(&run_tests.step);
```

---

## 10. Avoiding `std.http.Client` API churn

The `std.http.Client` API changes between every Zig release. For stability, use raw TCP:

```zig
const addr = try std.net.Address.resolveIp("127.0.0.1", 8080);
const stream = try std.net.tcpConnectToAddress(addr);
defer stream.close();

const request = "POST /v1/chat/completions HTTP/1.1\r\nHost: 127.0.0.1:8080\r\n...";
try stream.writeAll(request);

var buf: [4096]u8 = undefined;
const n = try stream.read(&buf);
```

See `src/llamafile_reward.zig` for a full HTTP/1.1 client over raw TCP.

---

## Quick reference: files migrated in zig-syrup

| File | Migration | Status |
|------|-----------|--------|
| `notcurses_backend.zig` | `@cImport` → `@import("c")` | Done |
| `c_headers/notcurses.h` | translate-C header shim | Created |
| `c_headers/posix_net.h` | POSIX translate-C header | Created |
| `llamafile_reward.zig` | `ArrayList.init` → `ArrayListUnmanaged` | Done |
| `set_game.zig` | `toTrit` visibility | Done |
| `gumbel_trit.zig` | `Rng` visibility | Done |
| `tapo_energy.zig` | `std.crypto.random` → `DefaultPrng` | Done |
| `continuation.zig` | `std.time.timestamp` compat | Done |
| `syrup.zig` | ArrayList writer adapter | Done |
| `nanoclj-zig/nrepl.zig` | Pending `@cImport` migration | TODO |
