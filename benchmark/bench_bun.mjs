#!/usr/bin/env bun
// Syrup Bun (JavaScriptCore) Benchmark
// Compare against Node.js (V8) using the same syrup.mjs

import { syrupEncode, syrupDecode, syrec, sym } from '/Users/bob/i/syrup.mjs';
import { createHash } from 'crypto';

const ITERATIONS = 100_000;

function benchmark(name, iterations, fn) {
  // Warmup
  for (let i = 0; i < 1000; i++) fn();

  const start = Bun.nanoseconds();
  for (let i = 0; i < iterations; i++) fn();
  const elapsed = Bun.nanoseconds() - start;

  const perOpNs = Math.round(elapsed / iterations);
  const opsPerSec = Math.round((1_000_000_000 * iterations) / elapsed);
  console.log(`${name}: ${perOpNs} ns/op (${opsPerSec} ops/sec)`);
}

// Test data: skill:invoke record
const testValue = syrec("skill:invoke", [
  sym("gay-mcp"),
  sym("palette"),
  { n: 4, seed: 1069 },
  0
]);

// Large list
const largeList = Array.from({ length: 100 }, (_, i) => i * 42);

// Benchmark 1: Encode skill:invoke
benchmark("Encode skill:invoke", ITERATIONS, () => {
  syrupEncode(testValue);
});

// Benchmark 2: Decode skill:invoke
const encoded = syrupEncode(testValue);
benchmark("Decode skill:invoke", ITERATIONS, () => {
  syrupDecode(encoded);
});

// Benchmark 3: Encode large list
benchmark("Encode list[100]", ITERATIONS / 10, () => {
  syrupEncode(largeList);
});

// Benchmark 4: CID computation
benchmark("CID compute", ITERATIONS, () => {
  const bytes = syrupEncode(testValue);
  createHash('sha256').update(bytes).digest();
});

// Benchmark 5: Roundtrip
const config = { host: "localhost", port: 8080, enabled: true };
benchmark("Roundtrip struct", ITERATIONS, () => {
  syrupDecode(syrupEncode(config));
});
