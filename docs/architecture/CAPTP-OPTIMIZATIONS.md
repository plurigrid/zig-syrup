# CapTP/OCapN Syrup Optimization Guide

Based on parallel research into OCapN specifications, CapTP message patterns, and Zig performance analysis.

## Executive Summary

| Category | Current | Optimized | Improvement |
|----------|---------|-----------|-------------|
| Decode | 60 ns | ~15 ns | 4x faster |
| Encode (descriptors) | 104 ns | ~20 ns | 5x faster |
| Message size | 100% | ~50% | 2x smaller |
| CID compute | 129 ns | ~50 ns | 2.5x faster |

## Priority 1: Descriptor Label Interning

**Problem**: Every CapTP message repeats these labels:
```
op:deliver       (10 bytes) - appears in EVERY message
op:deliver-only  (14 bytes)
desc:export      (11 bytes) - appears 1-4x per message
desc:import-object (18 bytes)
desc:answer      (11 bytes)
```

**Solution**: Intern as single-byte opcodes:
```zig
pub const InternedLabels = enum(u8) {
    op_deliver = 0x80,
    op_deliver_only = 0x81,
    op_listen = 0x82,
    desc_export = 0x90,
    desc_import_object = 0x91,
    desc_import_promise = 0x92,
    desc_answer = 0x93,
    // ... etc
};

pub fn encodeDescExportInterned(pos: u16, buf: []u8) []u8 {
    buf[0] = '<';
    buf[1] = @intFromEnum(InternedLabels.desc_export);
    const len = std.fmt.formatIntBuf(buf[2..], pos, 10, .lower, .{});
    buf[2 + len] = '+';
    buf[3 + len] = '>';
    return buf[0..4 + len];
}
```

**Impact**: 8-17 bytes saved per descriptor, 40-50% message size reduction.

## Priority 2: Fast-Path Descriptor Detection

**Problem**: Parser always does full record parsing for common patterns.

**Solution**: Pattern-match common prefixes at parse time:
```zig
pub fn parseDescriptorFast(self: *Parser) !Value {
    // Check for interned label (single byte after '<')
    if (self.input[self.pos + 1] >= 0x80) {
        return self.parseInternedDescriptor();
    }

    // Check common text prefixes with 4-byte comparison
    const prefix = std.mem.readInt(u32, self.input[self.pos..][0..4], .little);
    return switch (prefix) {
        // "<11'" for desc:export, desc:answer
        0x27313131 => self.parseDescExportOrAnswer(),
        // "<14'" for desc:import-object
        0x27343131 => self.parseDescImportObject(),
        else => self.parseRecordGeneric(),
    };
}
```

**Impact**: 5-10x faster descriptor parsing.

## Priority 3: SIMD Length Prefix Parsing

**Problem**: Decimal parsing is serial (each digit depends on previous).

**Solution**: Use SIMD for parallel digit extraction:
```zig
pub fn parseDecimalSIMD(input: []const u8) struct { value: u64, len: usize } {
    // Load 8 bytes, mask digits, compute in parallel
    const chunk = std.mem.readInt(u64, input[0..8], .little);
    const ascii_zeros = 0x3030303030303030;
    const digits = chunk ^ ascii_zeros;

    // Check which bytes are valid digits (0-9)
    const valid_mask = ((digits +% 0x0606060606060606) & 0xF0F0F0F0F0F0F0F0) == 0;

    // Count valid digits and compute value
    const count = @popCount(valid_mask);
    // ... parallel multiply-add
}
```

**Impact**: 3-5x faster length prefix parsing.

## Priority 4: Swiss Number Optimization

**Problem**: Base64 encode/decode happens on every sturdyref.

**Solution**: Single-pass URL-safe base64 with SIMD:
```zig
pub fn urlBase64EncodeFast(input: *const [32]u8, output: *[43]u8) void {
    // Use lookup table for URL-safe alphabet
    const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";

    // Process 3 bytes -> 4 chars at a time (can SIMD with shuffle)
    var i: usize = 0;
    var o: usize = 0;
    while (i + 3 <= 32) : ({i += 3; o += 4;}) {
        const triple = @as(u24, input[i]) << 16 | @as(u24, input[i+1]) << 8 | input[i+2];
        output[o] = alphabet[(triple >> 18) & 0x3F];
        output[o+1] = alphabet[(triple >> 12) & 0x3F];
        output[o+2] = alphabet[(triple >> 6) & 0x3F];
        output[o+3] = alphabet[triple & 0x3F];
    }
    // Handle remaining 2 bytes -> 3 chars (no padding)
}
```

**Impact**: 2-3x faster sturdyref handling.

## Priority 5: Bounds Check Elimination

**Problem**: Multiple bounds checks per parse operation.

**Solution**: Use pointer arithmetic with single check:
```zig
pub fn parseWithPointers(self: *Parser) !Value {
    const end = self.input.ptr + self.input.len;
    var ptr = self.input.ptr + self.pos;

    // Single upfront check for minimum message size
    if (@intFromPtr(end) - @intFromPtr(ptr) < 4) return error.UnexpectedEOF;

    // Now use unchecked pointer arithmetic
    const ch = ptr[0];
    ptr += 1;

    // ... rest of parsing with ptr instead of self.input[self.pos]
}
```

**Impact**: 15-20% faster parsing.

## Priority 6: Comptime Descriptor Tables

**Problem**: Common descriptors encoded at runtime.

**Solution**: Precompute at comptime:
```zig
const DescExportTable = comptime blk: {
    var table: [256][20]u8 = undefined;
    for (0..256) |i| {
        var buf: [20]u8 = undefined;
        const encoded = encodeDescExport(@intCast(i), &buf);
        table[i] = buf;
    }
    break :blk table;
};

pub fn encodeDescExportFast(pos: u8) []const u8 {
    return &DescExportTable[pos];  // Zero-cost lookup
}
```

**Impact**: Near-zero encoding cost for common positions.

## Priority 7: Arena Batch Allocation

**Problem**: Individual allocations for each parsed value.

**Solution**: Pre-size arena based on message type:
```zig
pub fn parseCapTPMessage(input: []const u8, base_alloc: Allocator) !Value {
    // Estimate arena size from message type
    const estimated_size = switch (input[1]) {
        0x80 => 256,   // op:deliver - medium
        0x81 => 128,   // op:deliver-only - small
        0x82 => 64,    // op:listen - tiny
        else => 512,   // unknown - generous
    };

    var arena = std.heap.ArenaAllocator.initWithCapacity(base_alloc, estimated_size);
    defer arena.deinit();

    return parseMessage(input, arena.allocator());
}
```

**Impact**: 30-50% reduction in allocation overhead.

## Priority 8: GC Message Compression

**Problem**: `op:gc-exports` sends paired integer lists inefficiently.

**Solution**: Delta + varint encoding:
```zig
// Before: [1+, 2+, 3+, 5+, 8+] = 15 bytes
// After:  [1, 1, 1, 2, 3] as varints = 5 bytes

pub fn encodeGCExportsDelta(positions: []const u32, buf: []u8) []u8 {
    var prev: u32 = 0;
    var pos: usize = 0;
    for (positions) |p| {
        const delta = p - prev;
        pos += encodeVarint(delta, buf[pos..]);
        prev = p;
    }
    return buf[0..pos];
}
```

**Impact**: 60-70% smaller GC messages.

## Priority 9: Promise Pipeline Batching

**Problem**: Each pipelined call is a separate message.

**Solution**: Aggregate pending calls:
```zig
pub const PipelineBatch = struct {
    calls: std.ArrayList(PipelinedCall),

    pub fn flush(self: *PipelineBatch, buf: []u8) []u8 {
        // Encode all calls in single <op:batch ...> record
        // Reduces per-message overhead from 20 bytes to 5 bytes amortized
    }
};
```

**Impact**: 4x fewer bytes for pipelined chains.

## Priority 10: Handoff Certificate Caching

**Problem**: Signature verification on every handoff.

**Solution**: Cache verified certificates by session:
```zig
pub const HandoffCache = struct {
    verified: std.AutoHashMap(SessionKey, CertInfo),

    pub fn verifyOrCache(self: *HandoffCache, cert: []const u8) !bool {
        const key = computeSessionKey(cert);
        if (self.verified.get(key)) |cached| {
            return cached.valid;  // Skip expensive verify
        }
        const valid = try verifyCertificate(cert);
        try self.verified.put(key, .{ .valid = valid });
        return valid;
    }
};
```

**Impact**: Amortize signature verification across handoffs.

## Implementation Roadmap

### Phase 1: Quick Wins ✅ COMPLETE
- [x] Comptime descriptor tables (Priority 6) - `CapTPDescriptors` module
- [x] Fast decimal parsing (Priority 5) - `parseDecimalFast()` unrolled loop
- [x] Arena pre-sizing (Priority 7) - `estimateCapTPArenaSize()` + `decodeCapTP()`

**Results:**
- CapTP desc:export: 3 ns/op (332M ops/sec)
- Fast decimal parse: 1 ns/op (763M ops/sec)
- CapTP decode: 73 ns/op (13.5M ops/sec)

### Phase 2: Core Optimizations (3-5 days)
- [ ] Descriptor label interning (Priority 1)
- [ ] Fast-path descriptor detection (Priority 2)
- [ ] Swiss number SIMD (Priority 4)

### Phase 3: Advanced (1 week)
- [ ] SIMD length parsing (Priority 3)
- [ ] GC message compression (Priority 8)
- [ ] Pipeline batching (Priority 9)
- [ ] Handoff caching (Priority 10)

## Performance Summary

| Metric | Baseline | After Phase 1 | Target Phase 2 | Target Phase 3 |
|--------|----------|---------------|----------------|----------------|
| Decode | 60 ns | 63 ns | 20 ns | 15 ns |
| Encode | 104 ns | 95 ns | 30 ns | 20 ns |
| CID | 129 ns | 120 ns | 60 ns | 50 ns |
| desc:export | N/A | 3 ns | 2 ns | 1 ns |
| Decimal parse | N/A | 1 ns | 1 ns | 1 ns |

## Benchmark Commands

```bash
# Current baseline
zig build bench

# After each phase
zig build bench -Doptimize=ReleaseFast

# Profile hotspots
zig build bench -Doptimize=ReleaseSafe -- --profile
```

## Sources

- [CapTP Specification](https://github.com/ocapn/ocapn/blob/main/draft-specifications/CapTP%20Specification.md)
- [Syrup Draft Specification](https://github.com/ocapn/syrup/blob/master/draft-specification.md)
- [Spritely Goblins Implementation](https://gitlab.com/spritely/goblins)
