#!/usr/bin/env python3
"""Emit a Syrup corpus encoded by an INDEPENDENT implementation.

The question this answers: does this decoder reject bytes that another
conforming implementation still emits? Only ocapn-test-suite's
contrib/syrup.py decides what goes on the wire here — nothing Zig-shaped
touches the encoding side, so a rejection is a real interop failure rather
than a self-consistency check.

Point OCAPN_TEST_SUITE at a checkout of https://github.com/ocapn/ocapn-test-suite
(defaults to ../ocapn-test-suite), then:

    python3 benchmarks/gen_peer_corpus.py | zig-out/bin/interop-strictness

Output: one `<name>\t<hex>` line per case on stdout.
"""
import os
import sys

_default = os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..", "..", "ocapn-test-suite")
_suite = os.environ.get("OCAPN_TEST_SUITE", _default)
_contrib = os.path.join(_suite, "contrib")
if not os.path.isfile(os.path.join(_contrib, "syrup.py")):
    sys.exit(
        f"no contrib/syrup.py under {_suite!r}.\n"
        "Clone https://github.com/ocapn/ocapn-test-suite and set "
        "OCAPN_TEST_SUITE to it.")
sys.path.insert(0, _contrib)
from syrup import syrup_encode, Record, Symbol  # noqa: E402

cases = []


def add(name, obj):
    cases.append((name, syrup_encode(obj)))


# ── integers: the exact territory `NonCanonical` polices ──────────────
add("int-zero", 0)
add("int-one", 1)
add("int-neg-one", -1)
add("int-i64-max", 2**63 - 1)
add("int-i64-min", -(2**63))
add("int-u64-max", 2**64 - 1)
add("int-big-pos", 2**200 + 7)
add("int-big-neg", -(2**200 + 7))
add("int-9", 9)
add("int-10", 10)
add("int-100", 100)

# ── strings / symbols / bytes, incl. empties and non-ASCII ────────────
add("str-empty", "")
add("str-ascii", "hello")
add("str-utf8", "éà你好")
add("sym-empty", Symbol(""))
add("sym-plain", Symbol("gay-mcp"))
add("bytes-empty", b"")
add("bytes-nul", b"\x00\x01\xff")

add("bool-true", True)
add("bool-false", False)
add("float-zero", 0.0)
add("float-neg", -1.5)
add("float-inf", float("inf"))
add("float-nan", float("nan"))

# ── containers ────────────────────────────────────────────────────────
add("list-empty", [])
add("list-flat", [1, 2, 3])
add("list-mixed", [0, "", Symbol("s"), b"", True, []])
add("list-nested-8", [[[[[[[[1]]]]]]]])

# ── dictionaries: Python sorts by the FULLY ENCODED key. If Zig orders
# differently, these decode as NotCanonicalOrder even though both sides
# believe they are canonical. This is the highest-risk family here.
add("dict-empty", {})
add("dict-str-keys", {"b": 2, "a": 1, "c": 3})
add("dict-int-keys", {3: "c", 1: "a", 2: "b"})
add("dict-mixed-keys", {1: "int", "1": "str", Symbol("1"): "sym"})
add("dict-len-order", {"z": 1, "aa": 2, "b": 3})
add("dict-nested", {"outer": {"inner": [1, 2]}})

# Sets carry the same ordering hazard as dicts.
add("set-empty", set())
add("set-ints", {3, 1, 2})
add("set-strs", {"b", "a", "c"})
add("set-mixed", {1, "1", Symbol("1")})  # syrup.py handles set, not frozenset

# ── records ───────────────────────────────────────────────────────────
add("rec-empty-args", Record(Symbol("tag"), []))
add("rec-skill-invoke", Record(
    Symbol("skill:invoke"),
    [[Symbol("gay-mcp"), Symbol("palette"), {"n": 4, "seed": 1069}, 0]]))
add("rec-nested", Record(Symbol("a"), [Record(Symbol("b"), [1])]))

for name, blob in cases:
    print(f"{name}\t{blob.hex()}")
