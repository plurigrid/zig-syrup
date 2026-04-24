# OpenGame Benchmark Topology: The Reafferent Loop

**CCL Context:** Uncommons (Symplectomorphic Cobordism)
**Logic:** `A ⊗ (B ⅋ C) = (A ⊗ B) ⅋ C ∩ (A ⊗ C) ⅋ B`

We define the **Syrup Benchmark** as an `OpenGame` where agents (implementations) compete to minimize entropy (time/space) while maximizing fidelity (correctness).

## The Game Definition

```haskell
-- | The Benchmark Game
-- a: Input Value (Syrup AST)
-- b: Utility (Latency, Throughput, Memory)
-- x: Serialized Bytes
-- s: Internal State (Allocator/Arena)
-- y: Deserialized Value (Verification)
-- r: Co-utility (Context match)

data BenchmarkGame = OpenGame {
    play :: InputValue -> (SerializedBytes, Metrics),
    evaluate :: InputValue -> (DeserializedValue, Metrics) -> Utility
}
```

## The Players (Strategies)

1. **Zig-Syrup** (The Challenger)
   - Strategy: `ArenaAllocator` + `ZeroCopy`
   - Torus Phase: 0 (Pure Structure)

2. **Rust-Syrup** (The Reference)
   - Strategy: `serde` + `Vec<u8>`
   - Torus Phase: 1 (Safety/Borrowing)

3. **OxCaml-Syrup** (The Oracle)
   - Strategy: `flambda2` + `GC Control`
   - Torus Phase: 2 (Functional Optimization)

## The Arena (N-Torus)

The distribution is defined on the 3-torus (Zig, Rust, OCaml). We will measure:
1. **Encode Time** (Forward Pass / `play`)
2. **Decode Time** (Backward Pass / `evaluate`)
3. **CID Consensus** (Intersection)
