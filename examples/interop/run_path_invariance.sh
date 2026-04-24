#!/usr/bin/env bash
# run_path_invariance.sh — drive the 70-color CGT corpus through a peer
# (racket or guile) and assert byte-identity round-trip.
#
# Squares:
#   A — guile peer  (Zig⇄Guile)
#   B — racket peer (Zig⇄Racket)
#   D — local Zig roundtrip (control, no peer)
#
# Usage:
#   ./examples/interop/run_path_invariance.sh racket
#   ./examples/interop/run_path_invariance.sh guile
#   ./examples/interop/run_path_invariance.sh local

set -euo pipefail

PEER="${1:-local}"
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
HARNESS="$ROOT/zig-out/bin/path_invariance"
CORPUS="$(mktemp -t corpus.XXXXXX.bin)"
ECHO="$(mktemp -t echo.XXXXXX.bin)"
trap 'rm -f "$CORPUS" "$ECHO"' EXIT

if [[ ! -x "$HARNESS" ]]; then
  echo "building path-invariance harness..." >&2
  (cd "$ROOT" && zig build path-invariance)
fi

case "$PEER" in
  local)
    "$HARNESS" roundtrip "$CORPUS"
    ;;
  racket)
    "$HARNESS" emit "$CORPUS"
    racket "$HERE/racket_echo.rkt" "$CORPUS" "$ECHO"
    "$HARNESS" verify "$CORPUS" "$ECHO"
    ;;
  guile)
    "$HARNESS" emit "$CORPUS"
    guile --no-auto-compile "$HERE/guile_echo.scm" "$CORPUS" "$ECHO"
    "$HARNESS" verify "$CORPUS" "$ECHO"
    ;;
  *)
    echo "usage: $0 {local|racket|guile}" >&2
    exit 2
    ;;
esac
