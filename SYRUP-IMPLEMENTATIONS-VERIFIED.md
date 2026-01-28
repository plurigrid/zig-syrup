# Syrup Implementations - Compilation & Verification Report

**Date:** 2026-01-27
**Canonical CID:** `06fe1dc709bea744f8a0e1cd767210cd90f2b78200f574497e876c2778fa7ffb`

## Summary

All 6 implementations produce identical CIDs for the canonical test record.

## Implementations Tested

| Language | File | LOC | CID Match | Status |
|----------|------|-----|-----------|--------|
| **Zig** | `zig-syrup/src/syrup.zig` | 1518 | ✅ | 66 tests pass |
| **Rust** | `syrup-verify/` (ocapn-syrup) | 175+ | ✅ | Cargo build pass |
| **Clojure** | `syrup.clj` (Babashka) | 429 | ✅ | 47/48 tests pass |
| **JavaScript** | `syrup.mjs` (Node.js) | 411 | ✅ | All types work |
| **Python** | `syrup_py.py` | 278 | ✅ | All types work |
| **ClojureScript** | `syrup_nbb.cljs` (nbb) | 210 | ✅ | Round-trip works |
| **TypeScript** | `agent/.topos/syrup/syrup.ts` | 551 | ✅ | Bun compatible |

**Total LOC:** 3,572

## Canonical Test Record

```
Record: skill:invoke
Fields: [
  Symbol("gay-mcp"),
  Symbol("palette"),
  Dict { "n": 4, "seed": 1069 },
  Integer(0)
]
```

**Wire format:**
```
<12"skill:invoke[7'gay-mcp7'palette{1"n4+4"seed1069+}0+]>
```

**SHA-256 CID:**
```
06fe1dc709bea744f8a0e1cd767210cd90f2b78200f574497e876c2778fa7ffb
```

## Verification Commands

### Zig
```bash
cd /Users/bob/i/zig-syrup && zig build run
# Output: ✓ CID MATCH - Zig implementation verified!
```

### Rust
```bash
cd /Users/bob/i/syrup-verify && cargo run --bin ocapn
# Output: ✓ CID MATCHES expected value!
```

### Babashka (Clojure)
```bash
cd /Users/bob/i && bb -e '
(load-file "syrup.clj")
(def r (syrup/syrec "skill:invoke" [(symbol "gay-mcp") (symbol "palette") {"n" 4 "seed" 1069} 0]))
(def cid (-> (syrup/syrup-encode r) (java.security.MessageDigest/getInstance "SHA-256") .digest (#(apply str (map (fn [b] (format "%02x" (bit-and b 0xff))) %)))))
(println cid)'
# Output: 06fe1dc709bea744f8a0e1cd767210cd90f2b78200f574497e876c2778fa7ffb
```

### JavaScript (Node.js)
```bash
cd /Users/bob/i && node -e '
const { syrupEncode, sym, syrec } = require("./syrup.mjs");
const crypto = require("crypto");
const r = syrec("skill:invoke", [sym("gay-mcp"), sym("palette"), {n:4,seed:1069}, 0]);
console.log(crypto.createHash("sha256").update(syrupEncode(r)).digest("hex"));'
# Output: 06fe1dc709bea744f8a0e1cd767210cd90f2b78200f574497e876c2778fa7ffb
```

### Python
```bash
cd /Users/bob/i && python3 -c '
import syrup_py as s, hashlib
r = s.Record("skill:invoke", [[s.Symbol("gay-mcp"), s.Symbol("palette"), {"n":4,"seed":1069}, 0]])
print(hashlib.sha256(s.syrup_encode(r)).hexdigest())'
# Output: 06fe1dc709bea744f8a0e1cd767210cd90f2b78200f574497e876c2778fa7ffb
```

## Cross-Implementation Test Results

From `syrup_compare.clj`:

```
47/48 tests match across all implementations

Test Categories:
  ✅ Booleans (2/2)
  ✅ Integers (5/5) - including large/negative
  ✅ Strings (7/7) - including unicode, emoji, escapes
  ✅ Bytes (3/3)
  ✅ Floats (6/6)
  ✅ Lists (5/5) - including nested/deep
  ✅ Dictionaries (6/6) - including ordering tests
  ✅ Records (4/4)
  ✅ Sets (4/4)
  ✅ Symbols (3/3)
  ⚠️ Null (0/1) - BB/JS encode as 'f', Python errors

Note: Syrup has no native null type. Implementations differ on handling.
```

## Feature Matrix

| Feature | Zig | Rust | Clojure | JS | Python | TS |
|---------|-----|------|---------|----|---------|----|
| Encode all 11 types | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Decode all 11 types | ✅ | ✅ | ✅ | ✅ | ✅ | ⚠️ |
| Canonical ordering | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Value comparison | ✅ | ✅ | ✅ | ❌ | ❌ | ❌ |
| Zero-copy decode | ✅ | ✅ | ❌ | ❌ | ❌ | ❌ |
| No-alloc encode | ✅ | ✅ | ❌ | ❌ | ❌ | ❌ |
| Comptime CID | ✅ | ❌ | ❌ | ❌ | ❌ | ❌ |
| Schema validation | ✅ | ❌ | ❌ | ❌ | ❌ | ❌ |
| Stream decode | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ |
| Serde integration | ❌ | ✅ | ❌ | ❌ | ❌ | ❌ |

## Zig-Unique Features

The Zig implementation has capabilities not found in any other:

1. **Comptime CID computation** - Zero runtime cost
   ```zig
   const cid = comptimeCid(value);  // Computed at compile time
   ```

2. **No-allocation encoding** - Fixed buffer output
   ```zig
   var buf: [1024]u8 = undefined;
   const encoded = try value.encodeBuf(&buf);  // Zero heap allocs
   ```

3. **Value comparison traits** - For use in hash maps
   ```zig
   const order = v1.compare(v2);  // .lt, .eq, .gt
   const h = v.hash();            // u64 for HashMap
   ```

4. **Schema validation** - Comptime type checking
   ```zig
   const valid = validateSchema(value, schema);
   ```

5. **Explicit allocator control** - Any allocator
   ```zig
   var arena = std.heap.ArenaAllocator.init(alloc);
   const v = try decode(bytes, arena.allocator());
   ```

## Build Commands

```bash
# Zig - build and test
cd /Users/bob/i/zig-syrup
zig build test           # 66 tests
zig build run            # CID verification

# Rust - build and run
cd /Users/bob/i/syrup-verify
cargo build
cargo run --bin ocapn    # CID verification

# Babashka - run tests
cd /Users/bob/i
bb syrup.clj             # Unit tests
bb syrup_compare.clj     # Cross-impl comparison

# JavaScript - run tests
node syrup.mjs           # Unit tests

# Python - run tests (module only, no main)
python3 -c "import syrup_py; print('OK')"

# nbb (ClojureScript on Node)
nbb syrup_nbb.cljs       # Unit tests

# TypeScript (via Bun)
cd /Users/bob/i/agent/.topos/syrup
bun syrup.ts             # Demo
```

## Ecosystem Integration

| Implementation | Primary Use Case |
|----------------|------------------|
| Zig | Embedded, WASM, performance-critical |
| Rust | Production services, ocapn-syrup crate |
| Clojure | REPL exploration, scripting |
| JavaScript | Browser, Deno, Node.js |
| Python | Data science, prototyping |
| TypeScript | Agent/CapTP protocols |

## Conclusion

All 6 implementations produce byte-identical encodings and matching CIDs for the canonical test case. The Zig implementation leads in features with comptime capabilities unique to the language.

The cross-implementation test suite (`syrup_compare.clj`) validates 47/48 edge cases across Babashka, JavaScript, and Python, with the only discrepancy being null handling (not part of Syrup spec).
