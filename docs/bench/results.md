# v1.5 embedding-backend benchmark

Hardware: Apple M4. Swift 6.3.1, macOS 26.4.1. 30-sentence corpus, repeats=3 (or 2 for the first cpu+ane warm-up). Per-call latency in milliseconds.

| backend                | init  | cold₁ | embed p50 | embed p95 | remember p50 | remember p95 |
|------------------------|------:|------:|----------:|----------:|-------------:|-------------:|
| NL (NLContextual) c=1  |   925 |  22.9 |     14.30 |     15.60 |        18.91 |        22.06 |
| NL c=4                 |   153 |  21.6 |     30.25 |     57.83 |        39.50 |        74.82 |
| CoreML(cpu) c=1        |   301 |  16.8 |      6.07 |      6.55 |        10.95 |        12.01 |
| CoreML(cpu) c=4        |   298 |  14.4 |     12.89 |     13.41 |        20.93 |        31.96 |
| CoreML(cpu+ane) c=1    |  1946 |   9.6 |      3.03 |      3.24 |         8.60 |        10.28 |
| CoreML(cpu+ane) c=4    |  1947 |  10.5 |      5.72 |     10.91 |        17.86 |        26.49 |
| **CoreML(all) c=1**    |  1911 |  10.1 |  **2.95** |  **3.13** |     **8.04** |     **9.72** |
| CoreML(all) c=4        |  1918 |   9.8 |      5.77 |     10.94 |        17.93 |        29.15 |

Backend: `sentence-transformers/all-MiniLM-L6-v2` converted to Core ML mlprogram (FP16, seq_len=256, FP32 token output, mean-pooled with attention mask + L2 normalized).

`MLModel.availableComputeDevices` on this machine: `NeuralEngine`, `GPU (Apple M4)`, `CPU`.

## Findings

1. **CoreML(all) and CoreML(cpu+ane) are tied at ~3 ms p50 — ~5× faster than NLContextualEmbedding (14.3 ms p50)** for embed-only and ~2.3× faster for the full `remember` path (8.0 ms vs 18.9 ms).
2. **ANE startup tax**: enabling ANE adds ~1.6 s to first-init time (specialization/asset prep). CPU-only inits in ~300 ms. The cost amortizes immediately for any serving workload.
3. **Concurrency doesn't help** any backend's throughput. c=4 doubles per-call latency across the board because the bottleneck is single-model inference saturating the accelerator (ANE/GPU) or the actor lock (NL). Drive embed serially; if you need throughput, batch instead of fan out.
4. **Embedding dimension shifts**: NLContextualEmbedding produced 512-d vectors; MiniLM-L6-v2 is 384-d. v2 pgvector schema must be generated from the chosen production backend's runtime-discovered dimension — do not hard-code 384 or 512.
5. **CoreML(cpu)** is still ~2× faster than NLContextualEmbedding at this corpus shape (sentence-scale text). Even without ANE, swapping in a Core ML embedding model is a win; ANE makes it 5×.

## Recommendation

Make CoreML(all) with the bundled MiniLM model the **default production backend**, with NLContextualEmbedding kept as a configurable fallback (`CLAUDE_MIND_EMBEDDING_BACKEND=nl`). Generate the pgvector schema from the chosen backend's `dimension` at runtime. Defer the serial tool dispatcher to v2.

## Reproduce

```sh
swift build -c release

# NL
.build/release/claude-mind-bench --backend nl --repeats 3 --out docs/bench/nl-serial.json

# CoreML, three compute-unit settings
for U in cpu cpu+ane all; do
  SAFE=${U//+/-}
  .build/release/claude-mind-bench \
    --backend coreml \
    --coreml-model docs/bench/models/MiniLM-L6-v2.mlpackage \
    --coreml-tokenizer docs/bench/models/MiniLM-L6-v2-tokenizer \
    --coreml-units "$U" \
    --repeats 3 \
    --out "docs/bench/coreml-${SAFE}.json"
done
```

For cross-validation against Apple's tooling, generate Core ML performance reports in Xcode 16+ (Product ▸ Profile ▸ Core ML / Neural Engine instruments) — see `docs/coreml-embedding-models.md`.
