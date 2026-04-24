# Serialization Interchange Format Comparison

A comprehensive comparison of 12 serialization formats against Syrup/OCapN.

## Quick Reference Matrix

| Format | Canonical | Self-Desc | Binary | Stream | Zero-Copy | OCapN | Schema |
|--------|-----------|-----------|--------|--------|-----------|-------|--------|
| **Syrup** | ✅ | ✅ | Text | ✅ | Partial | ✅ | Optional |
| JSON | ❌ | ✅ | Text | ⚠️ | ❌ | ❌ | Optional |
| MessagePack | ⚠️ | ✅ | Binary | ⚠️ | ❌ | ❌ | None |
| CBOR | ✅ | ✅ | Binary | ⚠️ | Partial | ❌ | Optional |
| Protobuf | ⚠️ | ❌ | Binary | ✅ | Partial | ❌ | Required |
| Cap'n Proto | ✅ | ❌ | Binary | ✅ | ✅ | ✅ | Required |
| FlatBuffers | ❌ | ❌ | Binary | ⚠️ | ✅ | ❌ | Required |
| Preserves | ✅ | ✅ | Both | ✅ | Partial | ⚠️ | Optional |
| S-expressions | ⚠️ | ❌ | Text | ✅ | ❌ | ❌ | None |
| ASN.1/DER | ✅ | ⚠️ | Binary | ⚠️ | ❌ | ❌ | Required |
| Bencode | ✅ | ✅ | Hybrid | ✅ | Partial | ❌ | None |
| BSON | ❌ | ✅ | Binary | ❌ | ❌ | ❌ | Optional |

---

## Detailed Comparison

### 1. Syrup (OCapN)

```
Wire format: <12"skill:invoke[7'gay-mcp7'palette{1"n4+4"seed1069+}0+]>
CID: 06fe1dc709bea744f8a0e1cd767210cd90f2b78200f574497e876c2778fa7ffb
```

| Property | Value |
|----------|-------|
| Canonical | ✅ Deterministic - identical CIDs across all implementations |
| Self-describing | ✅ Type tags embedded (`t`, `f`, `+`, `-`, `"`, `'`, `:`) |
| Format | Text-based (ASCII tags + delimiters) |
| Streaming | ✅ Multiple values concatenatable |
| Zero-copy | ✅ String/binary views into buffer |
| Capability | ✅ Swiss numbers, CapTP, content-addressing |
| Schema | Optional (comptime validation in Zig) |

**Strengths:**
- Cross-runtime canonical encoding (verified: Zig, Rust, Clojure, JS, Python)
- Object capability security model built-in
- Content-addressable (CID = identity)
- Human-debuggable wire format

**Use cases:** OCapN/CapTP, distributed capabilities, skill invocation caching

---

### 2. JSON

```json
{"skill": "gay-mcp", "method": "palette", "args": {"n": 4, "seed": 1069}}
```

| Property | Value |
|----------|-------|
| Canonical | ❌ Key order arbitrary, whitespace varies |
| Self-describing | ✅ Types implicit in syntax |
| Format | Text (UTF-8) |
| Streaming | ⚠️ NDJSON for line-delimited |
| Zero-copy | ❌ Escape sequences require decoding |
| Capability | ❌ None |
| Schema | Optional (JSON Schema separate) |

**Strengths:** Universal support, human-readable, web native

**Weaknesses:** No canonical form, verbose, no binary data

---

### 3. MessagePack

```
Binary: 84 A5 skill A7 gay-mcp A6 method A7 palette ...
```

| Property | Value |
|----------|-------|
| Canonical | ⚠️ Map ordering unspecified |
| Self-describing | ✅ Type byte prefixes |
| Format | Binary (~30-40% smaller than JSON) |
| Streaming | ⚠️ Not designed for it |
| Zero-copy | ❌ Strings copied |
| Capability | ❌ None |
| Schema | None |

**Strengths:** Compact, fast, JSON-compatible types

**Use cases:** Blazor Hub Protocol, Redis variants, real-time comms

---

### 4. CBOR (RFC 8949)

```
Binary: A4 65 skill 67 gay-mcp 66 method 67 palette ...
```

| Property | Value |
|----------|-------|
| Canonical | ✅ RFC 8949 defines deterministic encoding |
| Self-describing | ✅ Major type tags (0-7) |
| Format | Binary |
| Streaming | ⚠️ Indefinite-length available |
| Zero-copy | ✅ Byte strings viewable |
| Capability | ❌ None (tags for extension) |
| Schema | Optional (CDDL) |

**Strengths:** Standardized canonical form, semantic tags, compact

**Use cases:** Cardano blockchain, FIDO2, IoT, constrained devices

---

### 5. Protocol Buffers

```protobuf
message SkillInvoke {
  string skill = 1;
  string method = 2;
  map<string, int32> args = 3;
}
```

| Property | Value |
|----------|-------|
| Canonical | ⚠️ Deterministic but not guaranteed across impls |
| Self-describing | ❌ Schema required to decode |
| Format | Binary (varint encoding) |
| Streaming | ✅ Repeated fields |
| Zero-copy | ⚠️ Implementation-dependent |
| Capability | ❌ None |
| Schema | ✅ Required (.proto files) |

**Strengths:** Mature tooling, strong types, efficient encoding

**Use cases:** gRPC, microservices, internal APIs

---

### 6. Cap'n Proto

```capnp
struct SkillInvoke {
  skill @0 :Text;
  method @1 :Text;
  args @2 :List(KeyValue);
}
```

| Property | Value |
|----------|-------|
| Canonical | ✅ Wire format is canonical |
| Self-describing | ❌ Schema required |
| Format | Binary (pointer-based) |
| Streaming | ✅ Promise pipelining |
| Zero-copy | ✅ Core design goal |
| Capability | ✅ Promise pipelining, capability passing |
| Schema | ✅ Required (.capnp files) |

**Strengths:** Zero-copy reads, promise pipelining, capability-aware

**Use cases:** Agoric SwingSet, high-performance RPC, Cloudflare Workers

**Comparison to Syrup:**
- Cap'n Proto: Schema-dependent, binary, zero-copy reads
- Syrup: Self-describing, text, zero-copy views, content-addressed

---

### 7. FlatBuffers

| Property | Value |
|----------|-------|
| Canonical | ❌ Padding/alignment varies |
| Self-describing | ❌ Schema required |
| Format | Binary (offset tables) |
| Streaming | ⚠️ Not designed for it |
| Zero-copy | ✅ Primary design goal |
| Capability | ❌ None |
| Schema | ✅ Required (.fbs files) |

**Strengths:** Zero-copy, game engine optimized, mobile-friendly

**Use cases:** Unity, high-frequency trading, Android/iOS apps

---

### 8. Preserves

```
<skill:invoke gay-mcp palette {n: 4 seed: 1069} 0>
```

| Property | Value |
|----------|-------|
| Canonical | ✅ Deterministic encoding standard |
| Self-describing | ✅ Type info in encoding |
| Format | Binary wire + text syntax |
| Streaming | ✅ Streaming-first design |
| Zero-copy | ✅ Binary format allows views |
| Capability | ⚠️ Immutability, Syndicate integration |
| Schema | Optional (pattern matching) |

**Strengths:** Similar to Syrup, record syntax, Syndicate ecosystem

**Comparison to Syrup:**
- Preserves: Syndicate/reactive systems focus
- Syrup: OCapN/CapTP focus, more implementations

---

### 9. S-expressions

```lisp
(skill:invoke gay-mcp palette ((n . 4) (seed . 1069)) 0)
```

| Property | Value |
|----------|-------|
| Canonical | ⚠️ Dialect-dependent |
| Self-describing | ❌ Pure structure, no types |
| Format | Text |
| Streaming | ✅ Natural line-delimited |
| Zero-copy | ❌ Requires parsing |
| Capability | ❌ None |
| Schema | None |

**Strengths:** Code-as-data (homoiconic), Lisp natural

**Use cases:** Lisp/Scheme code, ASTs, configuration

---

### 10. ASN.1 / BER / DER

| Property | Value |
|----------|-------|
| Canonical | ✅ DER is canonical (required for signatures) |
| Self-describing | ⚠️ TLV structure parseable, semantics need schema |
| Format | Binary (TLV encoding) |
| Streaming | ⚠️ BER allows indefinite length |
| Zero-copy | ❌ Limited |
| Capability | ❌ None (PKI adds signatures externally) |
| Schema | ✅ Required (ASN.1 modules) |

**Strengths:** ISO standard, X.509 certificates, crypto containers

**Use cases:** TLS/SSL, SNMP, telecommunications, defense

---

### 11. Bencode

```
d5:skill7:gay-mcp6:method7:palette4:argsd1:ni4e4:seedi1069eee
```

| Property | Value |
|----------|-------|
| Canonical | ✅ Inherently canonical (only one encoding) |
| Self-describing | ✅ Type markers (i, d, l, e, :) |
| Format | Hybrid (text markers, binary-safe strings) |
| Streaming | ✅ Natural format |
| Zero-copy | ✅ Strings length-prefixed, no escaping |
| Capability | ❌ None |
| Schema | None |

**Strengths:** Simple, canonical, binary-safe strings

**Comparison to Syrup:**
- Bencode: Simpler (4 types), BitTorrent legacy
- Syrup: 11 types, floats, records, OCapN integration

---

### 12. BSON

| Property | Value |
|----------|-------|
| Canonical | ❌ Field ordering varies |
| Self-describing | ✅ Type bytes for 20+ types |
| Format | Binary (size-prefixed documents) |
| Streaming | ❌ Document-oriented |
| Zero-copy | ❌ Strings require decoding |
| Capability | ❌ None |
| Schema | Optional (MongoDB validation) |

**Strengths:** Rich types (ObjectId, Binary, Timestamp)

**Use cases:** MongoDB only (not recommended for new projects)

---

## Decision Matrix by Use Case

### Content-Addressed Systems
| Rank | Format | Why |
|------|--------|-----|
| 1 | **Syrup** | Canonical + OCapN + verified CIDs |
| 2 | CBOR | RFC canonical form |
| 3 | Bencode | Inherently canonical |

### Distributed Capabilities
| Rank | Format | Why |
|------|--------|-----|
| 1 | **Syrup** | OCapN native, Swiss numbers, CapTP |
| 2 | Cap'n Proto | Promise pipelining, capability passing |
| 3 | Preserves | Syndicate integration |

### Zero-Copy Performance
| Rank | Format | Why |
|------|--------|-----|
| 1 | Cap'n Proto | Pointer-based, core design |
| 2 | FlatBuffers | Offset tables, game engines |
| 3 | **Syrup/Zig** | String views, no-alloc encoding |

### Schema Enforcement
| Rank | Format | Why |
|------|--------|-----|
| 1 | Protobuf | Mature, code generation |
| 2 | Cap'n Proto | Expressive, capability-aware |
| 3 | ASN.1 | Formal specification |

### Human Debugging
| Rank | Format | Why |
|------|--------|-----|
| 1 | JSON | Universal tooling |
| 2 | **Syrup** | Text-based, readable tags |
| 3 | S-expressions | Lisp tooling |

### Cross-Runtime Interop
| Rank | Format | Why |
|------|--------|-----|
| 1 | JSON | Universal support |
| 2 | **Syrup** | Verified: Zig, Rust, Clojure, JS, Python |
| 3 | CBOR | Standardized |

---

## Syrup Unique Advantages

### vs JSON
- Canonical encoding (deterministic CIDs)
- Binary data support
- Symbols (interned strings)
- Records with labels
- Sets as first-class type

### vs MessagePack/CBOR
- Object capability integration
- Content-addressing built-in
- Text-based (debuggable)
- OCapN ecosystem (CapTP, Goblins, Agoric)

### vs Protobuf/Cap'n Proto
- Self-describing (no schema required)
- Content-addressable
- Simpler wire format
- Cross-runtime CID verification

### vs Preserves
- More implementations (5+ languages verified)
- OCapN focus (vs Syndicate focus)
- Established ecosystem (Spritely, Agoric)

---

## Zig Implementation Unique Features

| Feature | Syrup General | Zig Syrup Specific |
|---------|---------------|-------------------|
| Canonical encoding | ✅ | ✅ |
| Value comparison | Some impls | ✅ compare/eql/hash |
| Zero-copy decode | Some impls | ✅ String views |
| No-alloc encode | Rust only | ✅ Fixed buffer |
| Comptime CID | ❌ | ✅ `comptimeCid()` |
| Comptime schema | ❌ | ✅ `Schema` union |
| Generic traits | Rust serde | ✅ `Serializable(T)` |
| Embedded ready | Limited | ✅ No-std core |

---

## Conclusion

**Syrup is optimal when you need:**
1. Canonical encoding with verified cross-runtime CIDs
2. Object capability security (OCapN/CapTP)
3. Content-addressable data structures
4. Self-describing format without mandatory schemas
5. Human-debuggable wire format

**Consider alternatives when:**
- Zero-copy reads are critical → Cap'n Proto
- Schema enforcement required → Protobuf
- Maximum compactness needed → CBOR/MessagePack
- Universal tooling essential → JSON
- Blockchain/crypto context → CBOR (established) or DER (signatures)

The Zig implementation adds comptime features unavailable in any other format's implementations.
