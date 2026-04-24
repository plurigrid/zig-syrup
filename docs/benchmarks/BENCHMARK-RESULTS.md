# Syrup Implementation Benchmark Results

**Date**: 2026-01-27
**Test Case**: `skill:invoke` record (canonical OCapN test)
**Iterations**: 100,000 per benchmark

## Summary Table (ns/op, lower is better)

| Operation | Zig | Rust | Bun | Node.js | Python | Babashka |
|-----------|-----|------|-----|---------|--------|----------|
| **Encode skill:invoke** | **104 ns** | 620 ns | 1,342 ns | 3,370 ns | 2,896 ns | 21,829 ns |
| **Decode skill:invoke** | **60 ns** | 939 ns | 875 ns | 607 ns | 7,067 ns | 89,914 ns |
| **Encode list[100]** | **1,053 ns** | 6,876 ns | 10,694 ns | 17,381 ns | 15,842 ns | 108,185 ns |
| **CID compute** | **129 ns** | 883 ns | 1,721 ns | 3,722 ns | 3,165 ns | 23,509 ns |
| **Roundtrip** | **128 ns** | 1,114 ns | 1,601 ns | 2,543 ns | 7,415 ns | 69,969 ns |

## Ops/Second (Higher is Better)

| Operation | Zig | Rust | Bun | Node.js | Python | Babashka |
|-----------|-----|------|-----|---------|--------|----------|
| Encode skill:invoke | **9.6M** | 1.61M | 745K | 297K | 345K | 46K |
| Decode skill:invoke | **16.6M** | 1.06M | 1.14M | 1.65M | 142K | 11K |
| Encode list[100] | **949K** | 145K | 94K | 58K | 63K | 9K |
| CID compute | **7.7M** | 1.13M | 581K | 269K | 316K | 43K |
| Roundtrip | **7.8M** | 897K | 625K | 393K | 135K | 14K |

## Analysis

### Encoding Performance
**Winner: Zig** (6x faster than Rust, 32x faster than Node.js)

Zig's encoding is exceptionally fast due to:
- Zero-allocation encoding to fixed buffers
- No runtime dispatch overhead
- Direct memory writes with `std.mem.writeInt`
- Comptime-optimized type handling

### Decoding Performance
**Winner: Zig** (10x faster than Node.js, 16x faster than Rust)

After optimization, Zig now dominates decoding:
- **Before**: 9,364 ns (re-encoded every key for canonical validation)
- **After**: 60 ns (uses original input bytes for validation)
- Arena reuse with `.reset(.retain_capacity)` eliminates alloc overhead

### Bun vs Node.js (JavaScript Engine Comparison)
| Metric | Bun (JSC) | Node.js (V8) | Winner |
|--------|-----------|--------------|--------|
| Encode | 1,342 ns | 3,370 ns | **Bun 2.5x** |
| Decode | 875 ns | 607 ns | **Node 1.4x** |
| CID | 1,721 ns | 3,722 ns | **Bun 2.2x** |
| Roundtrip | 1,601 ns | 2,543 ns | **Bun 1.6x** |

JavaScriptCore (Bun) excels at encoding due to better string handling, while V8 (Node.js)
has superior JIT optimization for the parsing hot loops.

### CID Computation
**Winner: Zig** (7x faster than Rust)

Zig wins because CID = encode + SHA256, and encoding is where Zig dominates.
The fixed-buffer encoding means no allocation before hashing.

### Overall Roundtrip
**Winner: Zig** (9x faster than Rust)

After fixing the decoder, Zig dominates roundtrip performance:
- 128 ns total for serialize → encode → decode → deserialize
- Arena reuse eliminates allocation overhead between operations

## Relative Performance (Zig = 1.0x baseline)

| Implementation | Encode | Decode | CID | Roundtrip |
|----------------|--------|--------|-----|-----------|
| **Zig** | 1.0x | 1.0x | 1.0x | 1.0x |
| Rust | 6x slower | 16x slower | 7x slower | 9x slower |
| Bun | 13x slower | 15x slower | 13x slower | 13x slower |
| Node.js | 32x slower | 10x slower | 29x slower | 20x slower |
| Python | 28x slower | 118x slower | 25x slower | 58x slower |
| Babashka | 210x slower | 1,499x slower | 182x slower | 547x slower |

## Platform Notes

- **Hardware**: Apple Silicon (aarch64-darwin)
- **Zig**: 0.15.2, ReleaseFast optimization
- **Rust**: ocapn-syrup 0.2.0, release profile
- **Bun**: 1.3.0 (JavaScriptCore engine)
- **Node.js**: v22.x (V8 engine) with native crypto
- **Python**: 3.12
- **Babashka**: 1.x (JVM-based Clojure)

## Spritely Reference (Guile/Racket)

**Status**: Unable to benchmark due to nix daemon unavailability

### Attempted Installation Methods
1. `flox install guile` - nix daemon socket connection refused
2. `nix-shell -p guile` - daemon not running
3. `nix run nixpkgs#guile` - same issue
4. Homebrew - not available on this system
5. Racket (alternative Scheme) - same nix daemon issue

### Estimated Performance

Based on benchmarks of similar Scheme implementations and the structure of
`/Users/bob/i/ocapn-syrup-ref/impls/guile/syrup.scm` (641 lines, recursive descent):

| Operation | Estimated Guile | Reasoning |
|-----------|-----------------|-----------|
| Encode | ~4,000-6,000 ns | `bytes-append` allocations per element |
| Decode | ~3,000-5,000 ns | Match-based parsing, reasonable |
| CID | ~5,000-8,000 ns | GC pressure from bytevector creation |
| Roundtrip | ~7,000-10,000 ns | Between Python and Node.js |

Guile 3.x with JIT would likely perform between Python (interpreted) and Node.js (V8 JIT).
The reference implementation uses `vhash` (functional hash tables) which adds overhead
compared to mutable structures.

### To Run When Available

```bash
# Install Guile
flox install guile  # or brew install guile

# Create benchmark file
cat > /tmp/bench_guile.scm << 'EOF'
(add-to-load-path "/Users/bob/i/ocapn-syrup-ref/impls/guile")
(use-modules (syrup) (srfi srfi-19))

(define ITERATIONS 100000)
(define test-value
  (make-syrec* "skill:invoke"
    (list 'gay-mcp 'palette
          (alist->hash-table '((n . 4) (seed . 1069)))
          0)))

;; Warmup and benchmark
(let* ((start (current-time))
       (_ (do ((i 0 (1+ i))) ((= i ITERATIONS)) (syrup-encode test-value)))
       (elapsed (time-difference (current-time) start)))
  (format #t "Encode: ~a ns/op~%"
          (/ (* 1e9 (+ (time-second elapsed)
                       (/ (time-nanosecond elapsed) 1e9)))
             ITERATIONS)))
EOF
guile /tmp/bench_guile.scm
```

## CapTP-Optimized Benchmarks (Zig only)

These benchmarks specifically target OCapN/CapTP message patterns:

| Operation | ns/op | ops/sec | Notes |
|-----------|-------|---------|-------|
| **CapTP desc:export** | 3 ns | 332M | Pre-computed descriptor labels |
| **Fast decimal parse** | 1 ns | 763M | Unrolled digit extraction |
| **CapTP decode** | 73 ns | 13.5M | Arena pre-sizing by message type |

### Optimization Techniques Applied

1. **Comptime descriptor tables** - Common CapTP labels pre-encoded at compile time
2. **Fast decimal parsing** - Unrolled loop for 1-4 digit numbers (most common)
3. **Arena pre-sizing** - Estimate allocation needs from message type prefix
4. **Zero-copy validation** - Compare original input bytes, not re-encoded values

### Message Type Detection

The parser recognizes common CapTP messages by label length prefix:
- `10'` = op:deliver (medium: 256 bytes)
- `14'` = op:deliver-only (small: 128 bytes)
- `7'` = op:pick (tiny: 64 bytes)
- `11'` = desc:export/answer (small: 128 bytes)
- `12'` = op:gc-export/answer (large: 512 bytes)

## Key Takeaways

1. **Zig dominates everything** - 6-16x faster than all competitors in every category
2. **Zero-copy validation is key** - Using input bytes directly (not re-encoding) for canonical checks
3. **Arena reuse matters** - `.reset(.retain_capacity)` vs init/deinit = 100x difference
4. **JIT can't beat zero-alloc** - After optimization, native code beats JIT
5. **Bun beats Node.js for encode-heavy workloads** - JSC string handling is faster
6. **CapTP-specific paths are 30x faster** - Descriptor encoding at 332M ops/sec

## Recommendations by Use Case

| Use Case | Recommended | Why |
|----------|-------------|-----|
| **Maximum throughput** | Zig | 16M decode/sec, 10M encode/sec |
| Embedded/WASM | Zig | Zero-alloc, ~70KB binary |
| High-throughput services | Zig or Rust | Native performance |
| Content-addressed storage | Zig | 7.7M CID/sec |
| Web applications | Bun | Best JS performance |
| Scripting/prototyping | Python | Good balance |
| REPL exploration | Babashka | Lisp ergonomics |

## How to Run Benchmarks

```bash
# All benchmarks
./benchmark/run_all.sh

# Individual benchmarks
zig build bench                           # Zig
cd ../syrup-verify && cargo run --release --bin bench  # Rust
bun benchmark/bench_bun.mjs               # Bun (JavaScriptCore)
node benchmark/bench_node.mjs             # Node.js (V8)
python3 benchmark/bench_python.py         # Python
bb benchmark/bench_bb.clj                 # Babashka
```

## Implementation Details

| Implementation | Source | Engine/Runtime | CID Hash |
|----------------|--------|----------------|----------|
| Zig | `src/syrup.zig` (1948 lines) | Native (ReleaseFast) | std.crypto.Sha256 |
| Rust | ocapn-syrup 0.2.0 | Native (release) | sha2 crate |
| Bun | `syrup.mjs` | JavaScriptCore | crypto.createHash |
| Node.js | `syrup.mjs` | V8 | crypto.createHash |
| Python | `syrup_py.py` | CPython 3.12 | hashlib.sha256 |
| Babashka | `syrup.clj` | GraalVM/JVM | MessageDigest |
| Guile (ref) | `syrup.scm` (641 lines) | Guile 3.x JIT | N/A (unavailable) |

## Additional Implementations (Not Benchmarked)

| Implementation | Source | Notes |
|----------------|--------|-------|
| Hy (Python Lisp) | `syrup.hy` | Wraps Python impl, same perf |
| ClojureScript/nbb | `syrup_nbb.cljs` | Wraps syrup.mjs via Node |
| TypeScript | `agent/.topos/syrup/syrup.ts` | Simplified CapTP variant |
| Racket | `ocapn-syrup-ref/.../syrup.rkt` | Reference impl |
| Haskell | `haskell-preserves/` | GHC compat issues |
