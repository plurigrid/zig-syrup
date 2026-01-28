#!/bin/bash
# Run all Syrup benchmarks
set -e

echo "=============================================="
echo "Syrup Cross-Implementation Benchmark Suite"
echo "=============================================="
echo ""

echo "=== ZIG (ReleaseFast) ==="
cd /Users/bob/i/zig-syrup && zig build bench
echo ""

cd /Users/bob/i/syrup-verify
echo "=== RUST (Release) ==="
cargo build --release --bin bench 2>/dev/null
./target/release/bench
echo ""

echo "=== BUN (JavaScriptCore) ==="
bun /Users/bob/i/zig-syrup/benchmark/bench_bun.mjs
echo ""

echo "=== NODE.JS (V8) ==="
node /Users/bob/i/zig-syrup/benchmark/bench_node.mjs
echo ""

echo "=== PYTHON ==="
python3 /Users/bob/i/zig-syrup/benchmark/bench_python.py
echo ""

echo "=== BABASHKA (Clojure) ==="
bb /Users/bob/i/zig-syrup/benchmark/bench_bb.clj
echo ""

echo "=============================================="
echo "Benchmark complete. See BENCHMARK-RESULTS.md"
echo "=============================================="
