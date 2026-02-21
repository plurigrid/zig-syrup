# Local Model Weights Inventory

Generated: 2026-02-20

## Summary

| Runtime | Size | Models | Status |
|---------|------|--------|--------|
| Ollama | 6.0 GB | 3 | Active |
| LFM/MLX Audio | ~1.5 GB | 2 | Active |
| PyTorch (proof_chain) | ~0.5 GB | 12 checkpoints | Archive |
| ONNX (EZKL ZK) | ~0.2 GB | 11 models | Archive |
| VulnBERT | ~0.4 GB | 2 copies | Archive |
| **Total** | **~8.6 GB** | **30 artifacts** | |

## 1. Ollama (6.0 GB)

Location: `~/.ollama/models/`

| Model | Purpose |
|-------|---------|
| `llama3.2` | General-purpose LLM |
| `lojban-ablative` | Custom ablative case linguistic model |
| `mistral` | General-purpose LLM |

## 2. LFM / MLX Audio (1.5 GB)

Location: `~/i/mlx-audio-lfm/`

| File | Format | Purpose |
|------|--------|---------|
| `kokoro-v1.0.onnx` | ONNX | Text-to-speech |
| `models/LFM2.5-Audio-1.5B/model.safetensors` | SafeTensors | Audio LLM (MLX 8-bit) |
| `models/LFM2.5-Audio-1.5B/tokenizer-e351c8d8-checkpoint125.safetensors` | SafeTensors | Audio tokenizer |

## 3. PyTorch - proof_chain CIFAR GANs

Location: `~/worlds/l/proof_chain/` (mirrored at `~/i/bmorphism/lpscrypt-proof_chain/`)

| File | Purpose |
|------|---------|
| `checkpoints/epoch_50.pth` | Training checkpoint |
| `checkpoints/epoch_100.pth` | Training checkpoint |
| `checkpoints/last_good.pth` | Best training checkpoint |
| `checkpoints/final_model.pth` | Final trained model |
| `cifar_gan_training/tiny_discriminator.pth` | Tiny discriminator |
| `cifar_gan_training/tiny_generator.pth` | Tiny generator |
| `cifar_gan_training/tiny_classifier.pth` | Tiny classifier |
| `cifar_gan_training/final_discriminator.pth` | Full discriminator |
| `cifar_gan_training/final_generator.pth` | Full generator |
| `cifar_gan_training/zk_discriminator_v2_final.pth` | ZK-provable discriminator |
| `cifar_gan_training/zk_conditional_gan_v2_final.pth` | ZK-provable conditional GAN |
| `cifar_gan_training/zk_classifier_avgpool.pth` | ZK-provable classifier |

**Note**: Two identical copies exist. Deduplicate to external volume.

## 4. ONNX - EZKL ZK Prover Models

These models are exported for zero-knowledge proof generation via EZKL.

Location: `~/i/bmorphism/ezkl-ethglobal2025/ezkl_workspace/`

| Model | Architecture | Purpose |
|-------|-------------|---------|
| `mamba/model.onnx` | Mamba SSM | Full Mamba for ZK |
| `mamba_simple/model.onnx` | Mamba SSM (simplified) | Simplified for ZK circuit |
| `rwkv/model.onnx` | RWKV | Full RWKV for ZK |
| `rwkv_simple/model.onnx` | RWKV (simplified) | Simplified for ZK circuit |
| `xlstm/model.onnx` | xLSTM | Full xLSTM for ZK |
| `xlstm_simple/model.onnx` | xLSTM (simplified) | Simplified for ZK circuit |

Also at: `~/i/bmorphism/zk-haiku-nanogpt/ezkl_workspace/` (3 simple variants)
Also at: `~/i/bmorphism/lpscrypt-Redfish/ezkl/artifacts/network.onnx`

## 5. VulnBERT

Location: `~/worlds/q/pebblebed/vulnbert-v8/` and `~/i/quguanni/vulnbert-v8/`

| File | Purpose |
|------|---------|
| `pytorch_model.pt` | Vulnerability detection BERT |

**Note**: Two identical copies. Deduplicate to external volume.

## External Volume Migration Plan

When external volume is connected:

1. **Keep local** (hot): Ollama models, LFM Audio (actively used)
2. **Move to volume** (cold): proof_chain checkpoints (deduplicated), EZKL ONNX models, VulnBERT
3. **Symlink back**: Create symlinks from original paths to volume for toolchain compatibility
4. **Expected savings**: ~1.1 GB freed locally (proof_chain dupes + VulnBERT dupe)

## Cross-References

- DuckDB asset inventory: `docs/DUCKDB_DATASHEET.md` (90 databases, 1.73 GB, 492 tables)
- AM beacon infrastructure: `src/am_beacon.zig`
- Identity protocol: `src/passport.zig`
