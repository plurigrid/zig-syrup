// Syrup JavaScript Benchmark
import { createRequire } from 'module';
import { performance } from 'perf_hooks';
import crypto from 'crypto';

const require = createRequire(import.meta.url);

// Load syrup implementation
const syrupPath = '/Users/bob/i/syrup.mjs';
const { syrupEncode, syrupDecode, sym, syrec } = await import(syrupPath);

const ITERATIONS = 100_000;

function benchmark(name, iterations, fn) {
    // Warmup
    for (let i = 0; i < 1000; i++) fn();

    const start = performance.now();
    for (let i = 0; i < iterations; i++) {
        fn();
    }
    const elapsed = performance.now() - start;
    const perOpNs = (elapsed * 1_000_000) / iterations;
    const opsPerSec = Math.floor(iterations / (elapsed / 1000));
    console.log(`${name}: ${Math.floor(perOpNs)} ns/op (${opsPerSec} ops/sec)`);
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
    crypto.createHash('sha256').update(bytes).digest();
});

// Benchmark 5: Roundtrip (no serde, just encode/decode)
const config = { host: "localhost", port: 8080, enabled: true };
benchmark("Roundtrip struct", ITERATIONS, () => {
    const bytes = syrupEncode(config);
    syrupDecode(bytes);
});
