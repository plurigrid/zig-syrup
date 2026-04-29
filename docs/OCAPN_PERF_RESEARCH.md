# OCapN CapTP Performance Optimization Research

**Date**: 2026-04-26
**Context**: zig-syrup CapTP implementation bottleneck analysis

---

## A) Zero-Copy Syrup Parsing

### Finding: Syrup's format is partially zero-copy compatible — the current parser already does this for leaf values but allocates for structural containers.

**Syrup wire format analysis** (from [ocapn/syrup spec](https://github.com/ocapn/syrup)):
- Bytestrings: `<len>:<bytes>` — length-prefixed, contiguous in wire buffer ✅ zero-copy viable
- Strings: `<len>"<bytes>` — length-prefixed, contiguous ✅ zero-copy viable
- Symbols: `<len>'<bytes>` — length-prefixed, contiguous ✅ zero-copy viable
- Records: `<<label><fields>...>` — nested, delimiter-terminated (not offset-based) ⚠️ partial
- Lists: `[<values>]` — delimiter-terminated ⚠️ partial
- Integers: `<digits>+` or `<digits>-` — inline ✅ trivial

**Current state in `src/syrup.zig`**: The parser (line ~966) already returns `[]const u8` slices pointing into the input buffer for bytes/string/symbol values — this IS zero-copy for leaf data. The ~8µs cost comes from:

1. **Container allocation**: `parseRecord()` allocates `label_alloc` (1-element slice for the label Value) + `fields` slice via `collectUntil('>', false)` which uses `ArrayListUnmanaged(Value)` + `toOwnedSlice()`. Every record parse = 2+ allocations.

2. **Value union overhead**: Each field becomes a `Value` union (32 bytes per the tagged union), stored in a heap-allocated slice.

**Cap'n Proto comparison**: Cap'n Proto achieves zero-copy by using a flat layout with fixed-size pointer sections and offset-based field access. The data never needs to be "parsed" into an intermediate representation — you cast the buffer to a struct and read fields at known offsets. This is fundamentally different from Syrup's delimiter-scanned format.

**FlatBuffers comparison**: Similar to Cap'n Proto — flat buffer with vtable offsets. Reading a field is a pointer dereference, not a parse.

**What's achievable for Syrup**:

Syrup's delimiter-scanned format (`<label...>`) cannot be Cap'n Proto-style zero-copy because field boundaries must be discovered by scanning. However, we CAN eliminate allocations:

### Recommended approach: Stack-allocated small-record fast path

For CapTP descriptors (which are all `<label single-integer-field>`), the parse can be specialized:

```zig
/// Fast descriptor parse: no allocation, returns directly from wire buffer.
/// Handles the common case: <N'label M+> where N, M are small integers.
pub fn parseDescriptorFast(input: []const u8) !WireDesc {
    if (input.len < 5 or input[0] != '<') return error.InvalidDescriptor;

    // Parse label length prefix
    const len_result = parseDecimalFast(input[1..]);
    const label_start = 1 + len_result.len + 1; // skip '<', digits, marker
    const marker = input[1 + len_result.len];
    if (marker != '\'') return error.InvalidDescriptor;
    const label_len: usize = @intCast(len_result.value);
    const label = input[label_start..label_start + label_len];

    // Parse position integer that follows label
    const pos_start = label_start + label_len;
    const pos_result = parseDecimalFast(input[pos_start..]);
    if (pos_result.len == 0) return error.InvalidDescriptor;
    const pos: u32 = @intCast(pos_result.value);

    // Match label to descriptor type (no allocation, direct slice comparison)
    if (std.mem.eql(u8, label, "desc:import-object")) return .{ .import_object = pos };
    if (std.mem.eql(u8, label, "desc:import-promise")) return .{ .import_promise = pos };
    if (std.mem.eql(u8, label, "desc:export")) return .{ .@"export" = pos };
    if (std.mem.eql(u8, label, "desc:answer")) return .{ .answer = pos };

    return error.InvalidDescriptor;
}
```

**Expected impact**: Eliminates 100% of allocations for descriptor parsing. The ~8µs/descriptor should drop to sub-microsecond (dominated by `parseDecimalFast` which the codebase already has with SWAR optimization at line ~2520).

**Sources**:
- `src/syrup.zig` lines 966–1330 (Parser implementation)
- `src/wire_desc.zig` (current WireDesc.fromValue)
- Cap'n Proto encoding: https://capnproto.org/encoding.html
- Syrup spec: https://github.com/ocapn/syrup/blob/master/draft-specification.md

---

## B) Arena Allocation for CapTP Message Processing

### Finding: Per-message arena is the correct pattern. The codebase already has `decodeCapTP()` with arena pre-sizing. The gap is that `ocapn_vat.zig` doesn't use it.

**Current state**: `src/syrup.zig` already provides:
- `estimateCapTPArenaSize()` (line ~2591) — message-type-aware size estimation
- `decodeCapTP()` (line ~2620) — creates an ArenaAllocator, pre-allocates estimated capacity, parses into arena

But `src/ocapn_vat.zig` uses `self.allocator` (the Vat's GPA) for all operations, meaning every record field is a separate GPA allocation with individual `free()` calls.

**Zig ArenaAllocator pattern** (from ziggit.dev best practices, zig.guide):
```zig
// Per-message processing pattern
fn processMessage(self: *Vat, raw_bytes: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit(); // ONE free for entire message

    const alloc = arena.allocator();
    const msg = try syrup.decode(raw_bytes, alloc);

    // All intermediate Values, slices, label allocations live in arena.
    // Dispatch, extract what we need (copy to stable storage if needed),
    // then arena.deinit() frees everything.
    const desc = try WireDesc.fromValue(msg);
    // ... dispatch based on desc ...
}
```

**Goblins (Guile) allocation model**: Guile uses a generational garbage collector. CapTP message processing in Goblins creates Scheme values on the GC heap, which are collected in bulk during minor GC cycles. This is effectively region-based — short-lived message values die in the nursery and are collected cheaply. There's no per-field explicit free.

**Agoric/Endo (JavaScript) allocation model**: JavaScript's V8 uses generational GC with a young generation (Scavenger). CapTP messages create small JS objects that are mostly nursery-allocated and collected in ~ms. Again, effectively per-turn region allocation.

**Recommended approach**:

```zig
// In Vat message receive loop:
fn handleIncomingMessage(self: *Vat, raw: []const u8) !void {
    // Use decodeCapTP which already does arena + pre-sizing
    var result = try syrup.decodeCapTP(raw, self.allocator);
    defer result.arena.deinit();

    const msg = result.value;
    try self.dispatch(msg, result.arena.allocator());
}
```

For values that must outlive the message (e.g., listener `resolver_desc_bytes` stored in `Promise.listeners`), copy them out of the arena into stable GPA storage before the arena is freed:

```zig
// In addListener: copy resolver bytes to GPA
const stable_copy = try self.allocator.dupe(u8, resolver_desc_bytes);
try promise.addListener(self.allocator, stable_copy, wants_partial);
```

**Expected impact**: Eliminates per-field free() calls. A typical `op:deliver` with 3-5 fields goes from ~10 alloc/free pairs to 1 arena alloc + 1 arena free. The `estimateCapTPArenaSize` function already handles pre-sizing to avoid arena growth.

**Sources**:
- `src/syrup.zig` lines 2591–2631 (estimateCapTPArenaSize, decodeCapTP)
- `src/ocapn_vat.zig` (current Vat.allocator usage)
- Zig ArenaAllocator docs: https://zig.guide/standard-library/allocators/
- Ziggit best practices: https://ziggit.dev/t/allocators-best-practices-anti-patterns/14043

---

## C) Interned Descriptor Labels

### Finding: Use `std.StaticStringMap` (already used in the codebase) or a comptime-generated discriminator based on string length + first-unique-byte.

**Current state in `wire_desc.zig`**: Four `std.mem.eql` comparisons in sequence (lines 38–42):
```zig
if (std.mem.eql(u8, label, "desc:import-object")) return .{ .import_object = pos };
if (std.mem.eql(u8, label, "desc:import-promise")) return .{ .import_promise = pos };
if (std.mem.eql(u8, label, "desc:export")) return .{ .@"export" = pos };
if (std.mem.eql(u8, label, "desc:answer")) return .{ .answer = pos };
```

This is already quite fast (sub-nanosecond per the benchmark) because Zig's `mem.eql` with known-length comparands is SIMD-optimized. But we can do better with a two-level dispatch:

### Approach 1: Length + single-byte discriminator (simplest, fastest)

The four descriptor labels have distinct lengths:
- `"desc:import-object"` = 18 bytes
- `"desc:import-promise"` = 19 bytes
- `"desc:export"` = 11 bytes
- `"desc:answer"` = 11 bytes

Two have length 11, but differ at byte 5: `'e'` vs `'a'`.

```zig
pub fn fromLabelFast(label: []const u8) !WireDesc.Tag {
    return switch (label.len) {
        18 => .import_object,     // only "desc:import-object" is 18
        19 => .import_promise,    // only "desc:import-promise" is 19
        11 => switch (label[5]) { // "desc:export" vs "desc:answer"
            'e' => .@"export",    // desc:Export
            'a' => .answer,       // desc:Answer
            else => error.InvalidDescriptor,
        },
        else => error.InvalidDescriptor,
    };
}
```

This is **zero-comparison** for the common case — just a `switch` on length (compiled to a jump table) + one byte check for the 11-byte case.

### Approach 2: `std.StaticStringMap` (already in use in the codebase)

```zig
const DescLabelMap = std.StaticStringMap(WireDescTag).initComptime(.{
    .{ "desc:import-object", .import_object },
    .{ "desc:import-promise", .import_promise },
    .{ "desc:export", .@"export" },
    .{ "desc:answer", .answer },
});

pub fn fromLabel(label: []const u8) !WireDescTag {
    return DescLabelMap.get(label) orelse error.InvalidDescriptor;
}
```

The codebase already uses `std.StaticStringMap` in `src/acp.zig` and `src/stellogen/lexer.zig`.

### Approach 3: Comptime perfect hashing (Andrew Kelley's pattern)

Andrew Kelley's blog post demonstrates comptime-generated perfect hash functions that compile down to branchless arithmetic. For 4 strings, this would likely resolve to a single byte lookup + modular arithmetic — no string comparison at all.

**Recommendation**: Approach 1 (length + byte discriminator) is the simplest and fastest — it compiles to a 2-level switch, no memory access beyond the label slice header. Use this in the fast path (`parseDescriptorFast`). Keep `StaticStringMap` for the general record-label dispatch in the full parser.

**Expected impact**: Negligible for this specific bottleneck (the current `mem.eql` chain is already sub-nanosecond per the benchmark data). The real win is combining this with zero-alloc parsing (section A) to eliminate the Value indirection entirely.

**Sources**:
- `src/wire_desc.zig` lines 38–42
- `src/acp.zig` (StaticStringMap usage)
- Andrew Kelley, "String Matching based on Compile Time Perfect Hashing in Zig" (2018): https://andrewkelley.me/post/string-matching-comptime-perfect-hashing-zig.html
- Zig std.StaticStringMap: used in std lib for keyword matching

---

## D) Listener Fan-Out in Other CapTP Implementations

### Finding: All major implementations use event-loop turn batching. Nobody maintains per-listener byte copies.

**Spritely Goblins (Guile/Racket)**: Goblins implements CapTP within its transactional actor model ("vat turns"). Promise resolution happens within a turn, and all listeners are notified within the same turn — but the actual `op:fulfill` / `op:break` messages are buffered until the turn completes, then flushed as a batch to the netlayer. This means:
- Listeners don't store copies of descriptor bytes — they store a resolver object reference
- Notification is a method dispatch to the resolver, not byte manipulation
- All outgoing messages from a turn are coalesced before hitting the wire

**Agoric/Endo CapTP (JavaScript)**: From [@endo/captp](https://www.npmjs.com/package/@endo/captp), Endo uses JavaScript's promise mechanism:
- Resolver callbacks are stored as standard JS closures
- Promise resolution triggers microtask-queued callbacks
- Multiple resolutions within a turn are batched by the event loop
- No byte-level copying; references are held as JS object pointers

**Cap'n Proto (C++ RPC)**: From [capnproto.org/rpc.html](https://capnproto.org/rpc.html):
- Uses KJ event loop with `Promise<T>` continuations
- Promise resolution fires `then()` callbacks via the event loop
- Listener registration stores a `kj::Own<PromiseNode>` (owned pointer to continuation)
- Multiple pending operations are processed within a single event loop turn
- No per-listener data copying — continuations hold a pointer/reference to the resolved value

### Problem with current implementation

`ocapn_session.zig` `Listener` struct (line ~26) stores:
```zig
resolver_desc_bytes: []const u8, // Owned copy, freed via deinit
```

Each listener gets an owned copy of the resolver descriptor bytes. For 1000 listeners resolving to the same promise, this means 1000 separate allocations of the same (or similar) descriptor bytes.

### Recommended approach: Reference-counted or arena-scoped descriptors

**Option 1: Share a single copy with reference counting**
```zig
pub const SharedBytes = struct {
    data: []const u8,
    ref_count: u32,
    allocator: Allocator,

    pub fn retain(self: *SharedBytes) *SharedBytes {
        self.ref_count += 1;
        return self;
    }

    pub fn release(self: *SharedBytes) void {
        self.ref_count -= 1;
        if (self.ref_count == 0) {
            self.allocator.free(self.data);
            self.allocator.destroy(self);
        }
    }
};
```

**Option 2: Store typed WireDesc instead of raw bytes**

Since every listener's `resolver_desc_bytes` is a descriptor, store the parsed `WireDesc` (or `ResolverDesc`) instead of raw bytes. A `ResolverDesc` is just a tagged u32 — 8 bytes vs. ~30+ bytes of Syrup encoding.

```zig
pub const Listener = struct {
    resolver: wire_desc.ResolverDesc, // 8 bytes, no allocation
    wants_partial: bool,
    // No deinit needed!
};
```

Re-encode to Syrup only when actually sending `op:fulfill`/`op:break` on the wire (once per listener notification, not once per storage).

**Expected impact**: Eliminates 1000 allocations for 1000 listeners. The 33µs drain becomes dominated by the actual notification dispatch, not memory management. The `Listener.deinit` call per listener disappears.

**Sources**:
- `src/ocapn_session.zig` lines 21–30 (Listener struct)
- CapTP spec: op:listen section (resolver is a descriptor, always a desc:import-object or desc:import-promise)
- Cap'n Proto RPC: https://capnproto.org/rpc.html (continuation-passing model)

---

## E) Gift Table Data Structures

### Finding: HashMap is better than linear scan, but the expected cardinality is very low (<100 concurrent gifts). Linear scan is fine in practice; HashMap is an easy win if it bothers you.

**Current state**: `GiftTable` (in `src/ocapn_bootstrap.zig`) uses `ArrayListUnmanaged(Slot)` with linear scan `findSlot()`:
```zig
fn findSlot(self: *GiftTable, key: GiftKey) ?*Slot {
    for (self.slots.items) |*s| {
        if (s.key.eql(key)) return s;
    }
    return null;
}
```

`GiftKey` is `{ session_id: [32]u8, gift_id: [32]u8 }` — 64 bytes compared with `eql()` which does two `mem.eql` over 32 bytes each.

**Expected cardinality in practice**:

Third-party handoffs are relatively rare events in CapTP:
- They occur only when a message includes a reference imported from a *different* session
- Each handoff creates exactly one gift slot
- The slot is released as soon as both deposit and withdrawal complete
- Typical concurrent gifts: **1–10** for normal workloads, **maybe 50–100** during burst handoff scenarios

At 10 entries, linear scan costs ~170ns (extrapolating from the 1.7µs/1000 benchmark). This is negligible compared to the cryptographic verification (`Ed25519.verify`) that every handoff requires.

**HashMap approach if desired**:

```zig
const GiftMap = std.HashMap(
    GiftKey,
    Slot,
    struct {
        pub fn hash(_: @This(), key: GiftKey) u64 {
            // Use first 8 bytes of session_id XOR first 8 bytes of gift_id
            const s = std.mem.readInt(u64, key.session_id[0..8], .little);
            const g = std.mem.readInt(u64, key.gift_id[0..8], .little);
            return s ^ g;
        }
        pub fn eql(_: @This(), a: GiftKey, b: GiftKey) bool {
            return a.eql(b);
        }
    },
    80, // max_load_percentage
);
```

**Recommendation**: This is a low-priority optimization. The 1.7µs at 1000 entries is a synthetic worst case — real deployments will have <100 concurrent gifts. If the linear scan bothers you, swap to `std.HashMap` as above — it's a drop-in change. But measure first; the bottleneck is elsewhere.

**Sources**:
- `src/ocapn_bootstrap.zig` lines 119–160 (GiftTable, findSlot)
- CapTP spec, Third Party Handoffs section: gifts are created per-handoff, released on completion
- The spec explicitly notes deposit and withdraw "can happen in any order" — the table is a two-input join, inherently small

---

## F) CapTP Message Batching

### Finding: The spec supports implicit batching via promise pipelining. Goblins explicitly batches per-turn. Listener notifications can be batched.

**From the CapTP specification** ([ocapn/ocapn CapTP Specification.md](https://github.com/ocapn/ocapn/blob/main/draft-specifications/CapTP%20Specification.md)):

The spec does not mandate a "batch" framing, but:
1. **Promise pipelining IS batching**: Multiple `op:deliver` messages referencing `desc:answer` positions can be sent in succession without waiting. The receiver queues them.
2. **Netlayer messages are independent**: Each CapTP op is a separate Syrup record. The netlayer delivers them in order but doesn't define a batch envelope.
3. **Turn-based semantics**: The spec says "Messages can be sent together — there's no need to wait for the first call to actually return."

**How Goblins batches**: Goblins processes actor turns atomically. Within a single turn:
- All outgoing `op:deliver` messages are collected
- All promise resolutions (which trigger `op:fulfill` / `op:break`) are collected
- At turn end, the entire batch is serialized and flushed to the netlayer in one write

This means listener notification for a promise resolution is naturally batched with any other outgoing messages from the same turn.

**Cap'n Proto batching**: Cap'n Proto's RPC batches multiple messages per event loop turn. The `EventLoop::turn()` processes all available I/O, resolves promises, and flushes all outgoing messages in one write.

**Recommended approach for listener notifications**:

Instead of sending one `op:fulfill`/`op:break` per listener immediately, collect all notifications and write them in a single `sendBytes` batch:

```zig
/// Drain listeners and generate batched wire notifications.
fn notifyListeners(
    self: *Vat,
    promise: *session.Promise,
    out: *ByteList,
) !void {
    const listeners = try promise.drainListeners(self.allocator);
    defer self.allocator.free(listeners);

    for (listeners) |l| {
        defer l.deinit(self.allocator);
        // Append notification to output buffer (no send per listener)
        try self.appendNotification(out, l, promise);
    }
    // Caller sends the entire buffer in one write
}
```

Additionally, use Zig's `writev` / gather-write to send multiple messages without copying into a single buffer:

```zig
// Scatter-gather write: send all notifications in one syscall
var iovecs: [MAX_LISTENERS]std.posix.iovec_const = undefined;
for (notifications, 0..) |n, i| {
    iovecs[i] = .{ .base = n.ptr, .len = n.len };
}
try std.posix.writev(fd, iovecs[0..count]);
```

**Expected impact**: Reduces syscall count from N (one per listener) to 1. For 1000 listeners, this could save ~1ms of syscall overhead on top of the 33µs drain time.

**Sources**:
- CapTP Specification, Promise Pipelining section
- Cap'n Proto RPC: https://capnproto.org/rpc.html (turn-based batching)
- Spritely Goblins whitepaper: https://dustycloud.org/tmp/spritely-whitepaper-previews/spritely-core.html (transactional turns)

---

## Summary: Priority-Ordered Action Items

| Priority | Area | Expected Impact | Effort |
|----------|------|----------------|--------|
| **P0** | A+B: Arena allocator + zero-alloc descriptor parsing | ~8µs→<1µs per descriptor | Medium |
| **P1** | D: Store `ResolverDesc` instead of bytes in Listener | Eliminates 1000 allocs on drain | Small |
| **P2** | F: Batch listener notifications into single write | Reduces syscall overhead | Small |
| **P3** | C: Length-based label discriminator | Sub-ns improvement (nice-to-have) | Trivial |
| **P4** | E: Gift table HashMap | 1.7µs→O(1) at 1000 entries | Trivial, but low real-world impact |

The single highest-impact change is **combining A and B**: parse descriptors directly from the wire buffer without constructing `Value` intermediates, using an arena for any needed temporaries. This addresses the root cause (95%+ of descriptor dispatch time is parse+alloc+dealloc) rather than optimizing individual components.
