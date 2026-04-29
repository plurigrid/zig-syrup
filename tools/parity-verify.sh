#!/usr/bin/env bash
# zigbjj ↔ lazybjj-unison cross-language parity check.
#
# Generates N test cases from the Zig side, then asks UCM (running with
# the lazybjj-unison codebase) to recompute each case and assert match.
#
# Both sides MUST agree on:
#   plasticHue(idx, seed)       → f64 hue ∈ [0, 360)
#   tritFromHue(hue)            → trit ∈ {-1, 0, +1}
#   colorFromChangeId(id, seed) → (hue, r, g, b, trit)
#
# Usage:
#   tools/parity-verify.sh [N] [SEED_BASE]
#   N defaults to 1000, SEED_BASE to 0xCAFE.

set -e
N="${1:-1000}"
SEED_BASE="${2:-51966}"      # 0xCAFE
OUT="${OUT:-/tmp/zigbjj-parity.jsonl}"

REPO="$(cd "$(dirname "$0")/.." && pwd)"
LAZYBJJ_UNISON="${LAZYBJJ_UNISON:-/Users/bob/i/lazybjj-unison}"

cd "$REPO"

echo "step 1: build emit tool"
zig build emit-parity 2>&1 | tail -5

echo "step 2: emit ${N} cases (seed_base=${SEED_BASE}) → ${OUT}"
zig-out/bin/zigbjj-emit-parity "$N" "$SEED_BASE" > "$OUT"
wc -l "$OUT"

echo "step 3: hand off to UCM (lazybjj-unison)"
if [ ! -d "$LAZYBJJ_UNISON" ]; then
  echo "  ⚠  ${LAZYBJJ_UNISON} not found — skipping UCM verification."
  echo "  The JSONL is at ${OUT}; supply it to UCM manually."
  exit 0
fi

if ! command -v ucm >/dev/null 2>&1; then
  echo "  ⚠  ucm not on PATH — skipping UCM verification."
  exit 0
fi

# UCM runs the parity check in the lazybjj-unison codebase.
# The Unison side is expected to define `bjj.parityVerify : Text -> {IO} Nat`
# returning the count of mismatches (0 = full parity).
echo "  invoking ucm run lazybjj.bjj.parityVerify '${OUT}'"
cd "$LAZYBJJ_UNISON"
ucm run lazybjj.bjj.parityVerify "$OUT" 2>&1 | tail -10
