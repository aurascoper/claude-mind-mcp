#!/usr/bin/env bash
# install_skills.sh — symlink claude-mind-skills/ into the user's Claude Code skills dir.
#
# Idempotent: re-running replaces existing symlinks created by this script.
# Safe: refuses to overwrite a target that exists and is NOT a symlink, so
# hand-rolled skills at the same path are never silently clobbered.
#
# Usage:
#   scripts/install_skills.sh             # install (or refresh) symlinks
#   scripts/install_skills.sh --dry-run   # show what would happen, change nothing
#   scripts/install_skills.sh --uninstall # remove only the symlinks we own
#
# Override the destination:
#   CLAUDE_SKILLS_DIR=/some/path scripts/install_skills.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SRC="$REPO_DIR/claude-mind-skills"
DEST="${CLAUDE_SKILLS_DIR:-$HOME/.claude/skills}"

DRY_RUN=0
UNINSTALL=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --uninstall) UNINSTALL=1 ;;
    -h|--help)
      sed -n '2,18p' "$0"
      exit 0
      ;;
    *)
      echo "unknown arg: $arg" >&2
      exit 2
      ;;
  esac
done

if [[ ! -d "$SRC" ]]; then
  echo "error: skills source not found at $SRC" >&2
  exit 1
fi

run() {
  if [[ $DRY_RUN -eq 1 ]]; then
    echo "would: $*"
  else
    "$@"
  fi
}

note() {
  if [[ $DRY_RUN -eq 1 ]]; then
    echo "would $1"
  else
    echo "$1"
  fi
}

if [[ $DRY_RUN -eq 0 && $UNINSTALL -eq 0 ]]; then
  mkdir -p "$DEST"
fi

linked=0
skipped=0
removed=0

for entry in "$SRC"/*/; do
  [[ -d "$entry" ]] || continue
  name="$(basename "$entry")"
  src_dir="${entry%/}"
  target="$DEST/$name"

  if [[ $UNINSTALL -eq 1 ]]; then
    if [[ -L "$target" ]]; then
      # Only remove if it points into our repo — never delete a symlink we don't own.
      link_dest="$(readlink "$target")"
      if [[ "$link_dest" == "$src_dir" || "$link_dest" == "$SRC"/* ]]; then
        run rm "$target"
        note "removed: $target"
        removed=$((removed + 1))
      else
        echo "skip: $target is a symlink but does not point into this repo (leaving it)"
        skipped=$((skipped + 1))
      fi
    else
      [[ -e "$target" ]] && { echo "skip: $target is not a symlink (leaving it)"; skipped=$((skipped + 1)); }
    fi
    continue
  fi

  if [[ -L "$target" ]]; then
    link_dest="$(readlink "$target")"
    if [[ "$link_dest" == "$src_dir" ]]; then
      echo "ok: $target already linked"
      continue
    fi
    run rm "$target"
  elif [[ -e "$target" ]]; then
    echo "skip: $target exists and is not a symlink (refusing to overwrite)" >&2
    skipped=$((skipped + 1))
    continue
  fi

  run ln -s "$src_dir" "$target"
  note "linked: $target -> $src_dir"
  linked=$((linked + 1))
done

if [[ $UNINSTALL -eq 1 ]]; then
  echo "summary: removed=$removed skipped=$skipped"
else
  echo "summary: linked=$linked skipped=$skipped dest=$DEST"
fi
