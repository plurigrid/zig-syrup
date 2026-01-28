#!/usr/bin/env python3
"""Syrup Python Benchmark"""
import sys
import time
import hashlib
sys.path.insert(0, '/Users/bob/i')
import syrup_py as syrup

ITERATIONS = 100_000

def benchmark(name, iterations, fn):
    # Warmup
    for _ in range(1000):
        fn()

    start = time.perf_counter_ns()
    for _ in range(iterations):
        fn()
    elapsed = time.perf_counter_ns() - start
    per_op_ns = elapsed // iterations
    ops_per_sec = int(1_000_000_000 * iterations / elapsed)
    print(f"{name}: {per_op_ns} ns/op ({ops_per_sec} ops/sec)")

# Test data: skill:invoke record
test_value = syrup.Record("skill:invoke", [
    syrup.Symbol("gay-mcp"),
    syrup.Symbol("palette"),
    {"n": 4, "seed": 1069},
    0
])

# Large list
large_list = [i * 42 for i in range(100)]

# Benchmark 1: Encode skill:invoke
benchmark("Encode skill:invoke", ITERATIONS, lambda: syrup.syrup_encode(test_value))

# Benchmark 2: Decode skill:invoke
encoded = syrup.syrup_encode(test_value)
benchmark("Decode skill:invoke", ITERATIONS, lambda: syrup.syrup_decode(encoded))

# Benchmark 3: Encode large list
benchmark("Encode list[100]", ITERATIONS // 10, lambda: syrup.syrup_encode(large_list))

# Benchmark 4: CID computation
def compute_cid():
    data = syrup.syrup_encode(test_value)
    hashlib.sha256(data).digest()

benchmark("CID compute", ITERATIONS, compute_cid)

# Benchmark 5: Roundtrip
config = {"host": "localhost", "port": 8080, "enabled": True}
def roundtrip():
    data = syrup.syrup_encode(config)
    syrup.syrup_decode(data)

benchmark("Roundtrip struct", ITERATIONS, roundtrip)
