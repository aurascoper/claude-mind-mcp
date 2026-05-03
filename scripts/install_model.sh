#!/usr/bin/env bash
# Install a converted Core ML embedding model into the runtime sidecar location.
#
# Usage:
#   scripts/install_model.sh
#       (defaults: name=minilm-l6-v2, source=docs/bench/models, dim=384, seq_len=256)
#   CLAUDE_MIND_MODELS_DIR=/custom/dir scripts/install_model.sh
#
# Layout produced:
#   <models_dir>/<name>/
#     model.mlpackage/        (copied from <src>/MiniLM-L6-v2.mlpackage)
#     tokenizer/              (copied from <src>/MiniLM-L6-v2-tokenizer)
#     manifest.json
set -euo pipefail

NAME="${NAME:-minilm-l6-v2}"
VERSION="${VERSION:-1.0.0}"
PROFILE="${PROFILE:-minilm-l6-v2}"
DIM="${DIM:-384}"
SEQ_LEN="${SEQ_LEN:-256}"
SRC_MLPACKAGE="${SRC_MLPACKAGE:-docs/bench/models/MiniLM-L6-v2.mlpackage}"
SRC_TOKENIZER="${SRC_TOKENIZER:-docs/bench/models/MiniLM-L6-v2-tokenizer}"

DEFAULT_DIR="${HOME}/Library/Application Support/claude-mind/models"
TARGET_BASE="${CLAUDE_MIND_MODELS_DIR:-$DEFAULT_DIR}"
TARGET="${TARGET_BASE}/${NAME}"

if [[ ! -d "$SRC_MLPACKAGE" ]]; then
  echo "Source mlpackage not found: $SRC_MLPACKAGE" >&2
  exit 2
fi
if [[ ! -d "$SRC_TOKENIZER" ]]; then
  echo "Source tokenizer not found: $SRC_TOKENIZER" >&2
  exit 2
fi

echo "Installing $NAME → $TARGET"
mkdir -p "$TARGET"
rm -rf "$TARGET/model.mlpackage" "$TARGET/tokenizer"
cp -R "$SRC_MLPACKAGE" "$TARGET/model.mlpackage"
cp -R "$SRC_TOKENIZER" "$TARGET/tokenizer"

# sha256 of representative files (covers bit-rot and accidental edits without hashing the entire mlpackage tree).
hash_file() {
  local rel="$1"
  if [[ -f "$TARGET/$rel" ]]; then
    shasum -a 256 "$TARGET/$rel" | awk '{print $1}'
  else
    echo "missing"
  fi
}

ML_INNER_MODEL="$(find "$TARGET/model.mlpackage" -name "model.mlmodel" -type f 2>/dev/null | head -1 | sed "s|^$TARGET/||")"
ML_INNER_WEIGHTS="$(find "$TARGET/model.mlpackage" -name "weight.bin" -type f 2>/dev/null | head -1 | sed "s|^$TARGET/||")"
TOK_JSON="tokenizer/tokenizer.json"
TOK_VOCAB="tokenizer/vocab.txt"
TOK_CONFIG="tokenizer/tokenizer_config.json"

H_MODEL="$(hash_file "$ML_INNER_MODEL")"
H_WEIGHTS="$(hash_file "$ML_INNER_WEIGHTS")"
H_TOK_JSON="$(hash_file "$TOK_JSON")"
H_TOK_VOCAB="$(hash_file "$TOK_VOCAB")"
H_TOK_CFG="$(hash_file "$TOK_CONFIG")"

cat > "$TARGET/manifest.json" <<EOF
{
  "name": "$NAME",
  "version": "$VERSION",
  "backend": "coreml",
  "profile": "$PROFILE",
  "dim": $DIM,
  "seq_len": $SEQ_LEN,
  "mlpackage": "model.mlpackage",
  "tokenizer": "tokenizer",
  "sha256": {
    "$ML_INNER_MODEL": "$H_MODEL",
    "$ML_INNER_WEIGHTS": "$H_WEIGHTS",
    "$TOK_JSON": "$H_TOK_JSON",
    "$TOK_VOCAB": "$H_TOK_VOCAB",
    "$TOK_CONFIG": "$H_TOK_CFG"
  },
  "notes": "Converted from sentence-transformers/all-MiniLM-L6-v2 via scripts/convert_minilm.py"
}
EOF

echo "Wrote $TARGET/manifest.json"
echo "Done."
