# Confinement & Sandboxing Research for zig-syrup

## Context

This document surveys confinement primitives available in Zig and on macOS (darwin)
for implementing V8-isolate-like compartments, membrane proxies, and OS-level sandboxes
in the zig-syrup capability-secure system. Each approach is assessed against the existing
`vat.zig` + `cap.zig` architecture.

### Existing Architecture Summary

- **`vat.zig`**: In-process actor runtime with mailbox + turn loop, eventual send, backpressure, GF(3) trit conservation, vat hierarchy (parent/child), quiescence budget, and replay logging.
- **`cap.zig`**: Unforgeable `(vat_id, actor_id)` pair with 64-bit facet mask, Revoker, time-based expiry, Horton sender designation, ExportTable for distributed GC.
- **`sealer.zig`**: NaCl SecretBox sealer/unsealer pairs for opaque envelopes.
- **`vat_replay.zig`**: Deterministic rollout log (Syrup-encoded turn records).
- Multiple modules already compile to `wasm32-freestanding` (terminal_wasm, tileable_gof, stellogen, goi, etc.).
- `tileable_cc.zig` documents a planned `wasm_host.zig` embedding wasmtime via C API.

---

## 1. Zig-Native Confinement

### 1A. Custom Allocators as Capability Boundaries

| Aspect | Detail |
|--------|--------|
| **Mechanism** | `FixedBufferAllocator` with hard byte limit; `ArenaAllocator` scoped to vat lifetime; custom allocators that track high-water-mark and refuse above quota |
| **What it confines** | Memory consumption per vat/actor. A confined vat cannot OOM the host. |
| **E/CapTP mapping** | Analogous to seL4's per-CSpace memory budget (untyped memory caps). Each vat's allocator IS its memory capability — you can't allocate what you weren't granted. |
| **Feasibility** | **High**. Already used: `ArenaAllocator` in czernowitz.zig, syrup.zig, jsonrpc_bridge.zig. Vat.init already takes an `Allocator` parameter — passing a `FixedBufferAllocator` or a quota-wrapper is trivial. |
| **Complexity** | **Low**. ~50 LOC for a quota-enforcing allocator wrapper. |
| **Composes with vat.zig** | **Yes, directly**. `Vat.init(allocator, id)` already accepts an allocator. Pass a confined allocator and the vat is memory-bounded. No code changes to vat.zig needed. |
| **Limitations** | Only confines memory. Does not prevent I/O, network, or ambient authority access. Not a process boundary — a misbehaving actor can still corrupt shared address-space memory via unsafe pointer casts. |

### 1B. Comptime Interface Restrictions

| Aspect | Detail |
|--------|--------|
| **Mechanism** | Zig's `comptime` type checking enforces that behaviors declare SELECTORS (POLA default = empty), TRIT values, and conform to the `handle(*Self, *Vat, Message) !Become` signature. The vat.zig `spawn(comptime B, init)` derives a typed vtable at compile time. |
| **What it confines** | Selector surface (facet mask), trit conservation (checked at quiescence), behavior interface compliance. Unknown selectors are a comptime error when statically picked. |
| **E/CapTP mapping** | Directly maps to Goblins facet narrowing. A behavior that doesn't declare SELECTORS receives FACET_EMPTY — zero authority by default (POLA). This is structural confinement at the type level. |
| **Feasibility** | **High**. Already implemented in vat.zig and cap.zig. |
| **Complexity** | **Already done** (0 LOC additional). |
| **Composes with vat.zig** | **Is vat.zig**. The comptime behavior vtable derivation is the core confinement mechanism. |
| **Limitations** | Only enforces what the Zig type system can see. Cannot confine runtime-dynamic behavior or prevent a `@ptrCast` escape. No isolation between actors sharing the same address space. |

### 1C. Ambient Authority Audit (std.os, std.fs, std.net)

| Aspect | Detail |
|--------|--------|
| **Mechanism** | Zig's standard library exposes ambient authority through `std.os` (syscalls), `std.fs` (filesystem), `std.net` (networking), `std.heap.page_allocator` (mmap). A confined module should not `@import("std")` at all, or import only approved subsets. |
| **Current state in codebase** | Mixed. Core modules (virion, splitmix_trit, terminal, retty, fft_bands) are `wasm32-freestanding` compatible and avoid std.os. Network modules (tcp_transport, ghostty_ix_http, ocapn_tor) use std.net freely. File modules (worlds/ewig/store.zig, worlds/simulation.zig) use std.fs. |
| **E/CapTP mapping** | In E/CapTP, I/O capabilities must be explicitly granted (powerbox pattern). A vat should not have ambient access to the filesystem — it should receive a `Directory` capability or `File` capability explicitly. |
| **Feasibility** | **Medium**. Zig has no module-level import restrictions (unlike Deno's `--allow-net`). Enforcement requires either: (a) code review discipline, (b) compiling confined vats as separate WASM modules, or (c) a custom build step that rejects `@import("std")` in confined code. |
| **Complexity** | **Medium**. A build.zig lint step (~100 LOC) could parse imports. True enforcement requires process or WASM boundary. |
| **Composes with vat.zig** | **Partially**. The vat itself imports std for ArrayList. Confined behaviors could be restricted to not import std, but this requires convention/tooling, not language enforcement. |
| **Limitations** | Zig deliberately provides full std access. There's no `--deny-import` flag. This is an architectural discipline, not a language guarantee. |

### 1D. WASM Target Compilation (Zig → wasm32-freestanding)

| Aspect | Detail |
|--------|--------|
| **Mechanism** | Zig compiles to `wasm32-freestanding` natively. Many modules already do (terminal_wasm, tileable_gof, goi, stellogen, etc.). A WASM module has NO ambient authority — only explicitly imported functions. |
| **What it confines** | Everything. Memory (linear memory with bounds checking), computation (no syscalls), I/O (only imported host functions), time (no clock unless imported). |
| **E/CapTP mapping** | **This is the strongest match to E's confinement model.** A WASM module's imports ARE its capabilities. This is exactly the seL4/Hoot isomorphism documented in `SEL4_EWIG_EMERGENT_SIMPLICITY.md`: "the WASM sandbox IS a CSpace. A module's imports ARE its capabilities." |
| **Feasibility** | **High**. build.zig already has 5+ WASM targets. The codebase is designed for it. `tileable_cc.zig` plans `wasm_host.zig` embedding wasmtime via C API. |
| **Complexity** | **Medium-High**. The WASM module itself is easy (already done). The host runtime embedding (wasmtime C API or wasm3) is ~1200 LOC as estimated in tileable_cc.zig. |
| **Composes with vat.zig** | **Yes, as a wrapper**. Each confined vat compiles as a WASM module. The host vat exposes capability-attenuated imports. Messages cross the WASM boundary via Syrup encoding (already the wire format). |
| **Limitations** | Performance overhead (~2-10x vs native). WASM GC not yet standard. No shared memory between WASM instances without explicit copying. Adds a runtime dependency (wasmtime or wasm3). |

---

## 2. macOS (Darwin) OS-Level Sandboxing

### 2A. sandbox_init / sandbox-exec (Seatbelt Profiles)

| Aspect | Detail |
|--------|--------|
| **Mechanism** | macOS "seatbelt" sandbox uses Scheme-like profile language (SBPL). `sandbox-exec -f profile.sb command` or `sandbox_init()` from C. Profiles specify `(deny default)` then `(allow ...)` rules for file, network, IPC, etc. System profiles exist at `/usr/share/sandbox/*.sb`. |
| **Current API status** | **`sandbox_init()` is deprecated since macOS 10.8.** The header says "No longer supported". Apple now prefers App Sandbox entitlements. However, `sandbox-exec` CLI still works, and custom SBPL profiles still function (used by system daemons as of macOS 26.2). |
| **E/CapTP mapping** | Seatbelt = OS-level capability attenuation. `(deny default) (allow file-read* (literal "/path"))` is equivalent to granting a read-only file capability. The profile IS the CSpace. |
| **Feasibility** | **Medium**. Works on macOS today via `sandbox-exec` or SBPL + private API. But deprecated, undocumented for third-party use, and Apple could remove it. Zig can call sandbox_init via `@cImport` of `<sandbox.h>`. |
| **Complexity** | **Low-Medium**. ~80 LOC Zig FFI + a .sb profile per confinement level. |
| **Composes with vat.zig** | **At process boundary only**. A confined vat would run in a child process under sandbox-exec. Communication via pipe/socket (already supported by tcp_transport.zig / message_frame.zig). |
| **Limitations** | macOS-only. Deprecated API. No fine-grained per-thread sandboxing. Process-level granularity only. Cannot sandbox individual actors within a single process. |

### 2B. Endpoint Security Framework

| Aspect | Detail |
|--------|--------|
| **Mechanism** | `EndpointSecurity.framework` provides ES clients that receive notifications for process exec, file access, mmap, etc. Clients can AUTH (allow/deny) or NOTIFY (observe). Headers at SDK: `ESClient.h`, `ESMessage.h`, `ESTypes.h`. |
| **E/CapTP mapping** | This is a monitoring/auditing layer, not a confinement layer. It's the "CDT auditor" — it watches what capabilities are exercised, but doesn't prevent access proactively (AUTH mode can, but requires a system extension). |
| **Feasibility** | **Low for confinement, High for auditing**. Requires a System Extension or Endpoint Security entitlement (Apple must approve). Not suitable for general sandboxing. Good for monitoring capability exercises. |
| **Complexity** | **High**. Requires entitlements, System Extension packaging, and Apple approval. |
| **Composes with vat.zig** | **As audit layer only**. Could log which syscalls a vat process makes. Not practical for confinement. |
| **Limitations** | Requires Apple entitlement. Not a sandbox — it's a security audit framework. Heavy-weight. |

### 2C. posix_spawn with file_actions for fd Restriction

| Aspect | Detail |
|--------|--------|
| **Mechanism** | `posix_spawn()` with `posix_spawn_file_actions_t` allows launching a child process with a restricted set of file descriptors. Only explicitly inherited fds are available. Combined with closing stdin/stdout/stderr and only passing specific pipe fds, this creates a minimal I/O surface. |
| **E/CapTP mapping** | File descriptors ARE capabilities in Unix. posix_spawn's file_actions implement "capability passing at process birth" — the parent decides exactly which I/O capabilities the child receives. This maps directly to E's "endowment" at vat creation. |
| **Feasibility** | **High**. POSIX-standard, works on macOS and Linux. Zig's `std.posix` wraps posix_spawn. Already used by many programs. |
| **Complexity** | **Low**. ~60 LOC to spawn a child process with restricted fds. |
| **Composes with vat.zig** | **At process boundary**. A confined vat runs as a child process receiving only a pipe fd for Syrup-framed messages. The parent vat uses tcp_transport or message_frame to communicate. |
| **Limitations** | Only restricts fd inheritance, not syscall surface. Child can still open new files, make network connections, etc. Must combine with sandbox-exec or pledge-equivalent for full confinement. |

### 2D. Process-Level Isolation via XPC Services

| Aspect | Detail |
|--------|--------|
| **Mechanism** | XPC (Cross-Process Communication) is Apple's IPC framework. XPC services run in separate processes with their own sandbox. The parent sends structured messages; the service runs isolated. `xpc.h` available in SDK. |
| **E/CapTP mapping** | XPC services are the macOS equivalent of E's "vat in another process". Each XPC service has its own sandbox profile and receives only the messages (capabilities) the parent sends. The XPC connection IS a capability reference. |
| **Feasibility** | **Medium**. XPC requires an app bundle structure and Info.plist for the service. Works well for macOS apps. Less practical for CLI tools or libraries. Zig can call XPC via C ABI. |
| **Complexity** | **Medium-High**. ~300 LOC Zig FFI + app bundle configuration + Info.plist for each service. |
| **Composes with vat.zig** | **Yes, with adaptation**. An XPC service would embed a confined vat. The XPC message format would need a Syrup bridge (similar to jsonrpc_bridge.zig). |
| **Limitations** | macOS-only. Requires app bundle structure. Heavy-weight for per-actor isolation. Better suited for coarse-grained service boundaries (e.g., "BCI processing service" not "per-actor sandbox"). |

### 2E. macOS Alternatives to seccomp/pledge/bwrap

| Mechanism | macOS Equivalent | Status |
|-----------|-----------------|--------|
| Linux `seccomp-bpf` | **No direct equivalent**. Closest: seatbelt SBPL profiles (deprecated API) | macOS doesn't expose syscall filtering |
| OpenBSD `pledge(2)` | **No equivalent**. Seatbelt is coarser-grained | No pledge on macOS |
| Linux `bubblewrap` | **sandbox-exec** (seatbelt CLI) | Works but deprecated |
| Linux `namespaces` | **No equivalent**. macOS has no mount/pid/net namespaces | Fundamental architectural difference |
| Linux `cgroups` | **No equivalent for resource limits** | Use `RLIMIT_*` via setrlimit(2) |
| Linux `seccomp + landlock` | **App Sandbox entitlements** (Xcode-only) | Requires signing + entitlements |

**Bottom line for macOS**: The strongest portable confinement is process-level isolation (posix_spawn + fd restriction) combined with either seatbelt profiles or WASM sandboxing. There is no per-thread syscall filter on macOS.

---

## 3. Cross-Platform Patterns

### 3A. Embedded WASM Runtimes (wasmtime / wasm3)

| Aspect | Detail |
|--------|--------|
| **wasmtime** | Full WASM runtime with Component Model, WIT interfaces, Cranelift JIT. C API (`libwasmtime.a`). ~30MB library. Zig links via C ABI. Planned in `tileable_cc.zig` as Phase 2. |
| **wasm3** | Lightweight interpreted WASM runtime. ~64KB. Pure C. Zero dependencies. Extremely fast instantiation. No JIT — ~10-100x slower than native. |
| **wasm-micro-runtime (WAMR)** | Intel's lightweight WASM runtime. AOT + interpreter. ~100KB. C API. |
| **E/CapTP mapping** | WASM instance = confined vat. Host-provided imports = granted capabilities. Instance linear memory = isolated CSpace. Import table = CNode. This is the exact isomorphism documented in `SEL4_EWIG_EMERGENT_SIMPLICITY.md`. |
| **Feasibility** | **High**. wasm3 can be embedded in ~200 LOC of Zig glue. wasmtime requires linking libwasmtime.a (~30MB but well-documented C API). |
| **Complexity** | **Medium** (wasm3: ~200 LOC) to **Medium-High** (wasmtime: ~1200 LOC as tileable_cc estimates). |
| **Composes with vat.zig** | **Yes, as outer vat hosting inner confined vats**. The host Vat manages WASM instances. Each instance runs a compiled vat.zig module. Messages cross the boundary via Syrup encode/decode (already the wire format). |

### 3B. Membrane Pattern

| Aspect | Detail |
|--------|--------|
| **Mechanism** | An intercepting proxy that wraps every object reference crossing a boundary. Each crossing applies invariants: logging, attenuation, revocation, taint tracking, rate limiting. In E: CapTP handoff does this at network boundaries. |
| **Current implementation** | `cap.zig` already implements the core membrane primitives: `narrow()` (attenuation), `Revoker` (transitive revocation), `expires_at_ms` (time-bounded), `withSender()` (Horton re-stamping), `ExportTable` (reference tracking). `sealer.zig` provides opaque envelopes. |
| **What's missing** | A formal `Membrane` struct that composes all these: wrap-on-cross, log-on-cross, attenuate-on-cross. Currently each invariant is applied ad-hoc at the vat.send() call site. |
| **E/CapTP mapping** | **This IS the CapTP membrane.** Every capability crossing a vat boundary should go through a membrane that: (1) attenuates facets, (2) checks revocation, (3) checks expiry, (4) logs for audit, (5) tracks for distributed GC. |
| **Feasibility** | **High**. All primitives exist. Need ~150 LOC to compose them into a `Membrane` struct. |
| **Complexity** | **Low-Medium**. ~150 LOC for a composable `Membrane` type. |
| **Composes with vat.zig** | **Directly**. Membrane wraps cap.Capability on every cross-vat send. vat.send() already checks facets, revocation, expiry — the membrane formalizes this as a composable type. |

### 3C. Compartment Pattern

| Aspect | Detail |
|--------|--------|
| **Mechanism** | An isolated execution context with explicitly granted capabilities only. No ambient authority. Must receive all resources (memory, I/O, clock) from the compartment creator. Like V8 Isolates or Cloudflare Workers. |
| **E/CapTP mapping** | A compartment = a confined vat. The vat creator decides what the vat can do by controlling: (1) the allocator (memory budget), (2) the imports (I/O capabilities), (3) the clock (virtual time for deterministic replay), (4) the parent hierarchy (who gets terminal notifications). |
| **Current state** | `vat.zig` is 80% there. It already has: custom allocator, virtual clock (`now_ms_fn`), parent hierarchy, budget-limited quiescence, facet-restricted capabilities. Missing: no process/WASM isolation — actors share address space. |
| **Feasibility** | **High** (in-process, software-enforced) to **Medium** (with WASM or process isolation). |
| **Complexity** | **Low** (in-process: ~100 LOC `Compartment` wrapper around Vat) to **Medium-High** (with WASM host: ~1200 LOC). |
| **Composes with vat.zig** | **Is vat.zig, extended**. A `Compartment` wraps a `Vat` + `FixedBufferAllocator` + `Membrane` + optional WASM runtime. |

---

## 4. Comparison Matrix

| Approach | Isolation Level | Ambient Authority Blocked | Performance | macOS | Linux | WASM | Complexity | E/CapTP Fit | Composes w/ vat.zig |
|----------|----------------|--------------------------|-------------|-------|-------|------|------------|-------------|---------------------|
| **1A. Allocator quota** | Memory only | Memory | Native (0%) | ✅ | ✅ | ✅ | **Low** (50 LOC) | Memory caps | Direct (already takes Allocator) |
| **1B. Comptime facets** | Type-level | Selector surface | Native (0%) | ✅ | ✅ | ✅ | **Done** (0 LOC) | Facet narrowing, POLA | IS vat.zig |
| **1C. Import discipline** | Convention | std.os/fs/net (by review) | Native (0%) | ✅ | ✅ | ✅ | **Medium** (100 LOC lint) | Powerbox pattern | Partial (needs tooling) |
| **1D. WASM compilation** | Full sandbox | All I/O, memory, clock | 2-10x overhead | ✅ | ✅ | ✅ | **Medium-High** (1200 LOC host) | CSpace ≡ imports | Wrapper (host vat → WASM vat) |
| **2A. sandbox-exec** | Process + FS/net | File, network, IPC | Native + IPC | ✅ | ❌ | N/A | **Low-Med** (80 LOC + .sb) | OS-level CSpace | Process boundary |
| **2B. Endpoint Security** | Audit only | None (monitoring) | Native | ✅ | ❌ | N/A | **High** (entitlements) | CDT auditor | Audit layer only |
| **2C. posix_spawn + fd** | Process + fd set | Inherited fds only | Native + IPC | ✅ | ✅ | N/A | **Low** (60 LOC) | Endowment at birth | Process boundary |
| **2D. XPC services** | Process + sandbox | Per-service profile | Native + IPC | ✅ | ❌ | N/A | **Med-High** (300 LOC + plist) | Service-level vats | App bundle required |
| **3A-wasm3. wasm3 embed** | Full sandbox | All I/O, memory, clock | 10-100x overhead | ✅ | ✅ | ✅ | **Medium** (200 LOC) | CSpace ≡ imports | Wrapper (lightweight) |
| **3A-wasmtime. wasmtime** | Full sandbox + JIT | All I/O, memory, clock | 2-5x overhead | ✅ | ✅ | ✅ | **Medium-High** (1200 LOC) | CSpace ≡ imports + WIT | Wrapper (full featured) |
| **3B. Membrane** | Logical boundary | Invariant enforcement | Native (0%) | ✅ | ✅ | ✅ | **Low-Med** (150 LOC) | IS CapTP membrane | Direct (wraps Capability) |
| **3C. Compartment** | Composable | Depends on composition | Depends | ✅ | ✅ | ✅ | **Low-Med** (100 LOC wrapper) | IS confined vat | Direct (wraps Vat) |

---

## 5. Recommended Implementation Strategy

### Tier 1: Immediate (composable with current code, zero new dependencies)

1. **Allocator quota wrapper** — `FixedBufferAllocator` or custom quota allocator passed to `Vat.init()`. Caps memory per vat. ~50 LOC.
2. **Membrane struct** — Compose `narrow()`, `Revoker`, `expires_at_ms`, and audit logging into a single `Membrane` type that wraps every cross-vat capability reference. ~150 LOC.
3. **Compartment struct** — `Compartment` = `Vat` + quota allocator + `Membrane` + virtual clock. The in-process software-confined vat. ~100 LOC.

### Tier 2: Near-term (adds process isolation, macOS-specific)

4. **posix_spawn + fd restriction** — Spawn confined vats as child processes with only a pipe fd. Communicate via `message_frame.zig` (4-byte BE length prefix + Syrup). ~60 LOC.
5. **sandbox-exec profile** — SBPL profile that denies default, allows only the pipe fd. Applied to the child process from (4). ~80 LOC + `.sb` file.

### Tier 3: Strategic (full isolation, cross-platform)

6. **wasm3 embedding** — Lightweight WASM host for confined vats. Each vat compiles to `wasm32-freestanding` (already supported). Host exposes only `vat_send`, `vat_spawn`, `allocate` as imports. ~200 LOC.
7. **wasmtime embedding** — Full WASM Component Model host with WIT interfaces. Enables lifting Rust/Java/Unison components into the vat graph. ~1200 LOC. Already planned in `tileable_cc.zig` Phase 2.

### Composition

```
┌─────────────────────────────────────────────────────────────┐
│  Tier 3: WASM sandbox (wasm3 or wasmtime)                   │
│    - Full isolation: memory, I/O, clock                     │
│    - Cross-platform, formally specified                     │
│  ┌────────────────────────────────────────────────────────┐ │
│  │  Tier 2: Process boundary (posix_spawn + seatbelt)     │ │
│  │    - OS-level fd restriction + FS/net deny             │ │
│  │  ┌─────────────────────────────────────────────────┐   │ │
│  │  │  Tier 1: In-process (allocator + membrane)      │   │ │
│  │  │    - Memory quota per vat                        │   │ │
│  │  │    - Facet attenuation on every crossing        │   │ │
│  │  │    - Revocation, expiry, audit logging          │   │ │
│  │  │    - GF(3) conservation check                   │   │ │
│  │  │  ┌──────────────────────────────────────────┐   │   │ │
│  │  │  │  vat.zig + cap.zig (existing)            │   │   │ │
│  │  │  │    - Comptime vtable, POLA defaults      │   │   │ │
│  │  │  │    - Mailbox + turn loop                 │   │   │ │
│  │  │  │    - Virtual clock for replay            │   │   │ │
│  │  │  └──────────────────────────────────────────┘   │   │ │
│  │  └─────────────────────────────────────────────────┘   │ │
│  └────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────┘
```

Each tier composes with those inside it. A WASM-sandboxed vat still uses
allocator quotas internally. A process-isolated vat still has membranes
on its capability references. The tiers are **additive, not exclusive**.

---

## 6. Key Findings

1. **vat.zig is already 80% of a compartment.** It has custom allocators, virtual clocks, POLA defaults, facet narrowing, revocation, expiry, and parent hierarchy. The missing 20% is formalization (Membrane/Compartment structs) and hard isolation (process or WASM boundary).

2. **WASM is the strongest cross-platform confinement primitive available.** It maps perfectly to the E/CapTP model (imports = capabilities), the codebase already compiles multiple modules to wasm32-freestanding, and both lightweight (wasm3, ~200 LOC) and full-featured (wasmtime, ~1200 LOC) embedding paths exist.

3. **macOS has no pledge/seccomp equivalent.** The strongest macOS-specific option is sandbox-exec with SBPL profiles (still functional but deprecated API). For cross-platform code, WASM sandboxing is strictly superior.

4. **The membrane pattern is the highest-leverage next step.** Formalizing the existing `narrow()` + `Revoker` + `expires_at_ms` + audit into a composable `Membrane` type costs ~150 LOC and immediately upgrades every cross-vat reference to be invariant-enforcing.

5. **Process isolation via posix_spawn + fd restriction is the simplest OS-level confinement** that works on both macOS and Linux. Combined with Syrup framing over pipes, it gives hard isolation with zero new dependencies.
