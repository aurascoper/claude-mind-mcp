"""Convert sentence-transformers/all-MiniLM-L6-v2 to a Core ML .mlpackage.

Inputs:  input_ids (1x256 int32), attention_mask (1x256 int32)
Outputs: token_embeddings (1x256x384 float32)  -- raw last_hidden_state.
         The Swift bench mean-pools using attention_mask + L2-normalizes.

Run:
    python scripts/convert_minilm.py --out docs/bench/models/MiniLM-L6-v2.mlpackage
"""
import argparse
import os
import sys
import numpy as np
import torch
from transformers import AutoModel, AutoTokenizer
import coremltools as ct


class STMiniLM(torch.nn.Module):
    """Wraps the HF model so the traced graph has exactly 2 inputs and 1 output.

    We return only `last_hidden_state`; the bench does mean-pool + normalize.
    """
    def __init__(self, base):
        super().__init__()
        self.base = base
    def forward(self, input_ids, attention_mask):
        out = self.base(input_ids=input_ids, attention_mask=attention_mask, return_dict=True)
        return out.last_hidden_state


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model-id", default="sentence-transformers/all-MiniLM-L6-v2")
    ap.add_argument("--seq-len", type=int, default=256)
    ap.add_argument("--out", required=True, help="output .mlpackage path")
    args = ap.parse_args()

    print(f"[convert] loading {args.model_id} from HF…", flush=True)
    tok = AutoTokenizer.from_pretrained(args.model_id)
    base = AutoModel.from_pretrained(args.model_id)
    base.eval()

    wrapper = STMiniLM(base).eval()

    enc = tok("hello world",
              return_tensors="pt", padding="max_length", truncation=True, max_length=args.seq_len)
    example_ids  = enc["input_ids"].to(torch.int32)
    example_mask = enc["attention_mask"].to(torch.int32)

    print("[convert] tracing…", flush=True)
    traced = torch.jit.trace(wrapper, (example_ids, example_mask), strict=False)

    print("[convert] coremltools.convert…", flush=True)
    mlmodel = ct.convert(
        traced,
        inputs=[
            ct.TensorType(name="input_ids",      shape=(1, args.seq_len), dtype=np.int32),
            ct.TensorType(name="attention_mask", shape=(1, args.seq_len), dtype=np.int32),
        ],
        outputs=[ct.TensorType(name="token_embeddings", dtype=np.float32)],
        convert_to="mlprogram",
        compute_precision=ct.precision.FLOAT16,
        minimum_deployment_target=ct.target.macOS14,
    )

    mlmodel.short_description = "all-MiniLM-L6-v2 sentence encoder, last_hidden_state output (mean-pool downstream)."
    mlmodel.author = "claude-mind-mcp bench"
    mlmodel.version = args.model_id

    out = os.path.abspath(args.out)
    os.makedirs(os.path.dirname(out), exist_ok=True)
    mlmodel.save(out)
    print(f"[convert] wrote {out}", flush=True)

    # Save tokenizer assets too, so the Swift side can load vocab.
    vocab_dir = os.path.join(os.path.dirname(out), "MiniLM-L6-v2-tokenizer")
    os.makedirs(vocab_dir, exist_ok=True)
    tok.save_pretrained(vocab_dir)
    print(f"[convert] tokenizer saved to {vocab_dir}", flush=True)


if __name__ == "__main__":
    sys.exit(main() or 0)
