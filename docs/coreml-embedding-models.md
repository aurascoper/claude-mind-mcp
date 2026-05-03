# Core ML embedding models for the bench harness

`CoreMLEnricher` and the `claude-mind-bench` harness load a Core ML embedding model from disk so we can compare backend latency under different `MLComputeUnits` settings (`.cpuOnly`, `.cpuAndNeuralEngine`, `.all`).

We do not ship a model. You provide one. The expectations:

- Format: `.mlpackage` (preferred), `.mlmodel`, or pre-compiled `.mlmodelc`.
- One input feature of type `String` (Core ML's `MLFeatureType.string`). The harness passes the raw memory text in.
- One output feature of type `MLMultiArray` (the embedding vector). The harness picks the last dimension of the output's shape as the embedding dimension and L2-normalizes the vector.

If the model has multiple string inputs or multiple `MLMultiArray` outputs, the harness picks the first of each. Use the model's input/output names you trust, or rebuild the model with explicit names.

## Conversion path (sentence-transformers → Core ML)

Models that need explicit tokenization (BERT, MiniLM, etc.) require either:

1. A converted `.mlpackage` whose pipeline includes the tokenizer as a stage (so the input can be plain text), or
2. A separate Swift tokenizer that emits the token-id `MLMultiArray` the model expects (not implemented in v1.5).

For (1), `coremltools` plus `transformers` makes this reasonable for a simple sentence-encoder. Outline (run on a Mac with Python 3.11+, `coremltools`, `transformers`, `torch`):

```python
import coremltools as ct
import torch
from transformers import AutoTokenizer, AutoModel

model_id = "sentence-transformers/all-MiniLM-L6-v2"
tok = AutoTokenizer.from_pretrained(model_id)
hf  = AutoModel.from_pretrained(model_id, torchscript=True)
hf.eval()

example = tok("hello world", return_tensors="pt", padding="max_length", truncation=True, max_length=128)
traced = torch.jit.trace(hf, (example["input_ids"], example["attention_mask"]))

mlmodel = ct.convert(
    traced,
    inputs=[
        ct.TensorType(name="input_ids", shape=(1, 128), dtype=int),
        ct.TensorType(name="attention_mask", shape=(1, 128), dtype=int),
    ],
    convert_to="mlprogram",
    compute_units=ct.ComputeUnit.ALL,
)
mlmodel.save("MiniLM-L6-v2.mlpackage")
```

The above gives you a model whose inputs are `input_ids` and `attention_mask` — *not* a single string input, so the bench harness as written will not run end-to-end against it. To use it with the harness, you need to:

- Wrap it in a Core ML pipeline whose first stage tokenizes (Apple's `coremltools.models.utils.make_pipeline` plus a custom tokenization layer is one path), or
- Extend `CoreMLEnricher.embed(text:)` to do tokenization in Swift and provide `input_ids` / `attention_mask` as `MLMultiArray`s.

For the v1.5 spike, the harness gracefully bails on unsupported shapes; the value of the harness right now is in benchmarking the *Apple NaturalLanguage* path under different conditions and providing a clean seam for swapping in a Core ML backend once a single-string-in model is available.

## Running the bench

```sh
swift build -c release

# NL backend (default), serial
.build/release/claude-mind-bench --backend nl --repeats 5 --concurrency 1 --out docs/bench/nl-serial.json

# NL backend, concurrency 4
.build/release/claude-mind-bench --backend nl --repeats 5 --concurrency 4 --out docs/bench/nl-c4.json

# Core ML backend, three compute-unit configs
.build/release/claude-mind-bench --backend coreml --coreml-model /path/to/Embedder.mlpackage --coreml-units cpu     --repeats 5 --out docs/bench/coreml-cpu.json
.build/release/claude-mind-bench --backend coreml --coreml-model /path/to/Embedder.mlpackage --coreml-units cpu+ane --repeats 5 --out docs/bench/coreml-cpu-ane.json
.build/release/claude-mind-bench --backend coreml --coreml-model /path/to/Embedder.mlpackage --coreml-units all     --repeats 5 --out docs/bench/coreml-all.json
```
