"""Scaffold a real-data quality corpus from a git repo's commit log.

Outputs:
  <out>/memories.jsonl              — one entry per commit
  <out>/queries.template.jsonl      — 60 stratified queries, ungraded
  <out>/entities.json               — extracted entity counts (for review)

The user grades the queries by hand and renames the file to `queries.jsonl`
before running the harness.
"""
import argparse
import json
import os
import re
import subprocess
import sys
from collections import Counter
from datetime import datetime, timezone

# --- conventional-commit-ish prefix → tags ---------------------------------
PREFIX_TAGS = {
    "feat":     ["feature"],
    "fix":      ["bugfix"],
    "refactor": ["refactor"],
    "perf":     ["perf"],
    "docs":     ["docs"],
    "test":     ["test"],
    "chore":    ["chore"],
    "ci":       ["ci"],
    "build":    ["build"],
    "style":    ["style"],
}


def run_git(repo: str, *args: str) -> str:
    return subprocess.run(["git", "-C", repo, *args], capture_output=True, text=True).stdout


def parse_commits(repo: str, since: str = "6 months ago") -> list[dict]:
    """NUL-separated commit records. Inside each: 4 fixed lines (sha, date,
    author, subject) followed by an arbitrary-length body. Files are fetched
    in a second pass per commit (slower but correct)."""
    fmt = "%H%n%aI%n%an%n%s%n%b"
    raw = run_git(repo, "log", f"--since={since}", "--no-merges", "-z", "--pretty=format:" + fmt)
    commits = []
    for blob in raw.split("\x00"):
        if not blob.strip(): continue
        lines = blob.split("\n")
        if len(lines) < 4: continue
        sha = lines[0].strip()
        iso_date = lines[1].strip()
        author = lines[2].strip()
        subject = lines[3].strip()
        body = "\n".join(lines[4:]).strip()
        if not sha or len(sha) < 7: continue
        commits.append({
            "sha": sha, "date": iso_date, "author": author,
            "subject": subject, "body": body, "files": []  # filled later
        })
    # Files per commit, lightweight: top-level dirs only (avoids reading 424 separate processes
    # for full file lists — `git log --name-only` for the subject set, then we partition).
    name_raw = run_git(repo, "log", f"--since={since}", "--no-merges", "--pretty=format:%H@@@", "--name-only")
    files_by_sha = {}
    for chunk in name_raw.split("@@@"):
        chunk = chunk.strip("\n").strip()
        if not chunk: continue
        first, _, rest = chunk.partition("\n")
        sha = first.strip()
        if not sha: continue
        files_by_sha[sha] = [l for l in rest.split("\n") if l.strip() and not l.startswith("commit ")]
    for c in commits:
        c["files"] = files_by_sha.get(c["sha"], [])
    return commits


# --- entity / tag extraction ------------------------------------------------
CAPITALIZED = re.compile(r"\b([A-Z][A-Za-z0-9]+(?:[._-][A-Za-z0-9]+)*)\b")
ACRONYM     = re.compile(r"\b([A-Z]{2,}[0-9]*)\b")
TASK_REF    = re.compile(r"\btask\s+(\d+)\b", re.IGNORECASE)


# Noise filter: tokens that look like entities but aren't useful query targets.
# - Co-Authored-By trailer artifacts
# - Common English words at sentence start
# - LLM identifiers from commit trailers
ENTITY_NOISE = {
    "co-authored-by", "claude", "sonnet", "opus", "haiku", "anthropic",
    "noreply", "the", "a", "an", "i", "no", "yes", "and", "or", "but", "also",
    "new", "old", "all", "any", "one", "two", "three", "four", "five", "six",
    "this", "that", "these", "those", "now", "then", "here", "there",
    "fix", "feat", "task", "todo", "wip", "ci", "added", "adds", "removed",
    "changed", "single", "first", "last", "next", "prev",
    "true", "false", "none", "null",
}

def extract_entities(text: str) -> list[str]:
    out = set()
    for m in CAPITALIZED.findall(text):
        if m.lower() in ENTITY_NOISE: continue
        if len(m) < 3 and not m.isupper(): continue  # drop short title-case noise but keep acronyms
        out.add(m)
    for m in ACRONYM.findall(text):
        if m.lower() in ENTITY_NOISE: continue
        out.add(m)
    for m in TASK_REF.findall(text):
        out.add(f"task {m}")
    return sorted(out)


def derive_tags(subject: str, files: list[str]) -> list[str]:
    tags = set(["git"])
    head = subject.split(":", 1)[0].strip().lower() if ":" in subject else ""
    if head in PREFIX_TAGS:
        tags.update(PREFIX_TAGS[head])
    elif head:
        tags.add(head)  # treat repo-specific prefixes (math, analyzer, engine, ...) as tags
    for path in files:
        # top-level dir as a tag
        parts = path.split("/")
        if parts and parts[0] and parts[0] != ".":
            tags.add(parts[0].lower())
    return sorted(tags)


def commits_to_memories(commits: list[dict]) -> list[dict]:
    out = []
    for c in commits:
        text_parts = [c["subject"]]
        body = c.get("body", "").strip()
        if body:
            text_parts.append(body)
        text = "\n".join(text_parts)[:600]
        entities = extract_entities(text)
        tags = derive_tags(c["subject"], c["files"])
        out.append({
            "id": f"m{c['sha'][:8]}",
            "text": text,
            "created_at": c["date"],
            "occurred_at": c["date"],
            "source": "git",
            "tags": tags,
            "entities": entities,
        })
    return out


# --- query template generation ---------------------------------------------
def stratified_queries(memories: list[dict], n_entity=20, n_semantic=20, n_temporal=20) -> list[dict]:
    # Entity frequency
    ents = Counter()
    for m in memories:
        for e in m["entities"]: ents[e] += 1
    top_ents = [e for e, c in ents.most_common(40)
                if c >= 2 and not e.lower().startswith("task ")]
    # Tags / topics
    tags = Counter()
    for m in memories:
        for t in m["tags"]: tags[t] += 1
    top_tags = [t for t, c in tags.most_common(15) if t not in {"git", "docs", "feature", "bugfix"}]

    queries = []
    seen = set()

    def add(qid, q):
        if q in seen: return
        seen.add(q)
        queries.append({"id": qid, "query": q, "grades": {}})

    # Entity queries (~1/3)
    for i, e in enumerate(top_ents[:n_entity]):
        add(f"q-ent-{i:02d}", f"what was the work on {e}")

    # Semantic / project queries (~1/3) — driven by tags + manual themes
    seeds = [
        "the quoter design",
        "calibration work",
        "telemetry and shadow plumbing",
        "gate criteria across families",
        "TWAP scheduler revisions",
        "AR(1) and OBI math",
        "microstructure smoke bar",
        "anything related to inventory schedulers",
        "what changed about Gate 3",
        "spec-only commits and design docs",
        "refactors that touched the engine",
        "test additions and removals",
        "perf regressions and fixes",
        "anything about replay-driven analysis",
        "markout family work",
        "9-criterion bar evidence",
        "task 24 follow-ups",
        "task 17 follow-ups",
    ]
    for i, q in enumerate(seeds[:n_semantic]):
        add(f"q-sem-{i:02d}", q)

    # Temporal / mixed (~1/3) — granularity depends on corpus span.
    days = sorted({m["created_at"][:10] for m in memories})
    if days:
        # Week-level buckets if span < 60 days; month-level otherwise.
        first = datetime.fromisoformat(days[0]).date()
        last  = datetime.fromisoformat(days[-1]).date()
        span_days = (last - first).days
        if span_days <= 60:
            # Use last week, prior week, two weeks back, and the earliest week.
            from datetime import timedelta
            buckets = [
                ("the past week",                  timedelta(days=7),  timedelta(days=0)),
                ("the week before that",           timedelta(days=14), timedelta(days=7)),
                ("two weeks back",                 timedelta(days=21), timedelta(days=14)),
                ("the earliest part of this span", timedelta(days=span_days), timedelta(days=max(0, span_days - 7))),
            ]
            for i, (label, start_off, end_off) in enumerate(buckets):
                start = (last - start_off).isoformat()
                end   = (last - end_off).isoformat()
                add(f"q-time-{i:02d}", f"what was I working on {label} (around {start})")
        else:
            months = sorted({m["created_at"][:7] for m in memories})
            for i, ym in enumerate(months[-4:]):
                add(f"q-time-{i:02d}", f"what was I working on in {ym}")
    add("q-mixed-00", "scheduler changes around the family sweeps")
    add("q-mixed-01", "telemetry work that touched the engine layer")
    add("q-mixed-02", "all the math: prefixed commits in the last quarter")
    add("q-mixed-03", "design specs landed before any implementation")
    add("q-mixed-04", "anything that mentions both task and Gate")
    add("q-mixed-05", "calibration and family sweep together")

    return queries


# --- main ------------------------------------------------------------------
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo", required=True, help="path to git repo")
    ap.add_argument("--out",  required=True, help="output dir")
    ap.add_argument("--since", default="6 months ago")
    args = ap.parse_args()

    os.makedirs(args.out, exist_ok=True)
    commits = parse_commits(args.repo, args.since)
    print(f"parsed {len(commits)} commits from {args.repo} since {args.since}")

    memories = commits_to_memories(commits)
    queries  = stratified_queries(memories)

    mp = os.path.join(args.out, "memories.jsonl")
    qp = os.path.join(args.out, "queries.template.jsonl")
    ep = os.path.join(args.out, "entities.json")

    with open(mp, "w") as f:
        for m in memories: f.write(json.dumps(m) + "\n")
    with open(qp, "w") as f:
        for q in queries: f.write(json.dumps(q) + "\n")

    ents = Counter()
    tags = Counter()
    for m in memories:
        for e in m["entities"]: ents[e] += 1
        for t in m["tags"]: tags[t] += 1
    with open(ep, "w") as f:
        json.dump({
            "top_entities": ents.most_common(60),
            "top_tags":     tags.most_common(20),
            "n_memories":   len(memories),
            "n_queries":    len(queries),
            "date_range":   [memories[-1]["created_at"][:10] if memories else None,
                             memories[0]["created_at"][:10]  if memories else None],
        }, f, indent=2)

    print(f"wrote {len(memories)} memories → {mp}")
    print(f"wrote {len(queries)} query templates → {qp}")
    print(f"wrote entity/tag survey → {ep}")
    print(f"\nNext: hand-grade `queries.template.jsonl` (fill in the `grades` dicts),")
    print(f"      rename to `queries.jsonl`, and rerun `python3 docs/quality/run_quality.py --corpus {args.out}`")


if __name__ == "__main__":
    sys.exit(main() or 0)
