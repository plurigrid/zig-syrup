# esyrup — EDN projection of Syrup (v0.1)

A human-readable text format for OCapN Syrup, as EDN. Sibling of
[jsyrup](https://codeberg.org/vivicat/zig-syrup) with the inverse design
priority: jsyrup is wire-faithful and accepts unreadability (bytes as
base32 in `|…|` — alphabet inherited from Goblins — and symbols
backtick-quoted); esyrup is readable EDN and pays with explicit escape
tags where EDN lacks a syrup type. jsyrup is also emit-only (a debug
projection: nothing reads it back); esyrup is bidirectional and
law-checked. Both project the same canonical binary.

```
       esyrup text ──parse──▶ syrup Value ──encode──▶ canonical wire
       esyrup text ◀──emit─── syrup Value ◀──decode── canonical wire
```

## Laws (both measured, not asserted)

1. `parse ∘ emit ∘ parse = parse` — EDN side. Checked over the vendored
   edn.c corpus (15/15 files) by `tools/edn_roundtrip.zig`, equality judged
   on canonical syrup wire bytes.
2. `parse ∘ emit = id` — syrup side. Every syrup Value survives
   emit→parse exactly (unit tests in `src/edn_bridge.zig`).
3. Cross-implementation: `encode(parse(emit(decode(w)))) = w` for canonical
   wire `w` produced by an independent implementation — verified
   byte-identically against vivicat/zig-syrup's `zoo.bin`
   (`vendor/vivicat-zoo/`, Apache-2.0, see NOTICE.md).

## Mapping

| syrup            | esyrup                                  | notes |
|------------------|-----------------------------------------|-------|
| null             | `nil`                                   | |
| undefined        | `#syrup/undefined nil`                  | distinct from null |
| bool             | `true` / `false`                        | |
| integer (i64)    | `42`                                    | |
| bigint           | `#syrup/bigint [neg? #syrup/bytes "…"]` | sign + exact magnitude bytes |
| float (f64)      | `2.5`, `1.5e10`, `##Inf ##-Inf ##NaN`   | always carries `.`/`e` marker |
| float non-canon. | `#syrup/f64-bits "7ff8000000000001"`    | any NaN whose bits ≠ `##NaN`'s |
| float32          | `#syrup/f32 1.5`                        | f64-only in every EDN reader surveyed |
| float32 non-can. | `#syrup/f32-bits "7fc00001"`            | same, 32-bit |
| string           | `"…"`                                   | `\" \\ \n \t \r` escapes |
| bytes            | `#syrup/bytes "<base64>"`               | |
| symbol           | `name` or `ns/name`                     | bare only if valid EDN identifier |
| symbol (invalid) | `#syrup/symbol "…"`                     | incl. text `nil`/`true`/`false` |
| symbol `:…`      | `:kw` keyword                           | keyword⇄symbol quotient by sigil |
| list             | `[…]`                                   | EDN vector is the canonical seq |
| set              | `#{…}`                                  | |
| dictionary       | `{k v, …}`                              | |
| dict w/ dup keys | `#syrup/dict [[k v] …]`                 | EDN readers split error/last-wins/preserve on dups; a plain map would self-reject |
| record           | `#syrup/record [label field …]`         | |
| tagged           | `#tag payload`                          | tag must be a valid EDN symbol |
| tagged (invalid) | `#syrup/tagged ["tag" payload]`         | |
| error            | `#syrup/error [msg id data]`            | |

EDN-native values with no syrup type map inward as tagged values on the
wire: EDN list `(…)` → `tagged{"edn:list"}`, char → `edn:char` codepoint,
`N`/`M` literals → `edn:bigint`/`edn:bigdec` decimal strings, ratio →
`edn:ratio [num den]`. They emit back as native EDN literals.

## Deliberate losses (content, preserved as residue — not silently dropped)

- EDN metadata `^{…}` is parsed and discarded (no syrup slot). If you need
  it, it is the natural carrier for a future `#syrup/meta`.
- The keyword/symbol distinction is quotiented into the `:` sigil on syrup
  symbols; a genuine syrup symbol beginning with `:` re-emits as a keyword.

## Float bit-exactness

Syrup orders and compares floats **by bits**, and readers accept arbitrary
NaN payloads from untrusted input, so a text projection that renders every
NaN as `##NaN` silently rewrites the wire. esyrup emits `##NaN` only for the
one payload `##NaN` reads back as; every other NaN takes `#syrup/f64-bits` /
`#syrup/f32-bits` (hex, exact). All other finite doubles survive via
shortest-round-trippable printing + correctly-rounded parsing — verified over
4000 randomized bit patterns plus the subnormal/±0/±Inf edges. Laws 1 and 2
as originally written did not cover NaN payloads; the gap was found by
cross-implementation probing (see below).

## Float correctness note

Text→double must be correctly rounded. Law 1 alone cannot detect a stable
mis-rounding (the wrong double round-trips consistently); law 3's foreign
oracle can, and did: vendored edn.c rounds `"8.2"` to `0x…667` (nearest is
`0x…666`). The reference implementation therefore re-parses float source
spans with a correctly-rounded parser (`std.fmt.parseFloat`); implementers
must use a correctly-rounded decimal→binary conversion (Eisel-Lemire,
Ryū-compatible strtod, …).

## Mutual behaviors (measured against vivicat/zig-syrup, n=5 impl study)

Acceptance sets of the two Zig syrup readers are **incomparable** — neither
contains the other, so interop hazards run in both directions:

| wire | plurigrid | vivicat |
|---|---|---|
| dict/set in non-memcmp order | reject `NotCanonicalOrder` | accept |
| `07+`, `0-`, trailing bytes | reject | accept |
| string/symbol with invalid UTF-8 | accept | reject `InvalidUtf8` |
| bare `+`, int > u128 | reject | reject |
| canonical core, records, NaN payloads, −0.0 | accept | accept |

Both **writers** agree: canonical order is memcmp of the *encoded* key/element
bytes (plurigrid's decoder check and `Value.compare` agree by construction —
it compares the decimal length *strings*, so `"9"` > `"10"`), and each impl's
writer output is accepted by the other's reader. The hazard is entirely at the
edges, and the safe interop fragment is exactly `accept(plurigrid) ∩
accept(vivicat)` = canonical order **and** valid UTF-8 in strings/symbols.

## Reference implementation

`src/edn_bridge.zig` (reader edn.c vendored under `vendor/edn.c/`).
CLI: `zig build esyrup` → `zig-out/bin/esyrup [encode|decode]`
(EDN text ⇄ canonical syrup bytes on stdin/stdout).
E2E incl. laws and the zoo oracle: `bb tools/edn_syrup_e2e.bb`.
