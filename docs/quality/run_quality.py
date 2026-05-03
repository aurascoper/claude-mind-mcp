"""Recall quality harness.

Pipeline:
  1. Bring up Postgres@17 + pgvector. Create a fresh DB.
  2. Phase A — populate: start the binary with mirror enabled, write the entire
     memories.jsonl into a fresh Core Data store, wait for the mirror to drain.
  3. Phase B — capture: same store, mirror enabled. Run every query with k=25
     and capture each hit's component scores (semantic / recency / graph / lexical).
  4. Phase C — capture local: same store, mirror disabled. Run every query with
     k=25; the response carries semantic + recency only (graph=0, lexical=0).
  5. Score each ablation × each query offline by reranking the captured candidates
     with the appropriate weight zeros. Compute MRR@5 / nDCG@5 / Success@5.
  6. Coarse weight grid (5×5×5 = 125 configs) for the full hybrid. Then a fine
     sweep around the top 10. Best weights reported.
  7. Emit results.json (all numbers) and failure_notebook.md (per-query top-5
     with auto-suggested labels).
"""
from __future__ import annotations
import argparse
import json
import math
import os
import statistics
import subprocess
import sys
import tempfile
import time
from typing import Iterable

PG17_BIN = "/opt/homebrew/opt/postgresql@17/bin"
PG_DATA  = "/opt/homebrew/var/postgresql@17"
PG_PORT  = "5433"
PG_DB    = "claude_mind_quality"
DSN      = f"postgresql://{os.environ['USER']}@localhost:{PG_PORT}/{PG_DB}?sslmode=disable"
BIN      = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".build", "debug", "claude-mind-mcp"))
HERE     = os.path.dirname(os.path.abspath(__file__))


# ----- Postgres helpers -----------------------------------------------------
def pg(sql: str, db: str = PG_DB) -> str:
    return subprocess.run(
        [f"{PG17_BIN}/psql", "-p", PG_PORT, "-d", db, "-tAc", sql],
        capture_output=True, text=True
    ).stdout.strip()

def pg_start():
    subprocess.run([f"{PG17_BIN}/pg_ctl", "-D", PG_DATA, "-o", f"-p {PG_PORT}", "-l", "/tmp/pg17.log", "start"],
                   capture_output=True)
    for _ in range(20):
        if subprocess.run([f"{PG17_BIN}/pg_isready", "-p", PG_PORT], capture_output=True).returncode == 0:
            return
        time.sleep(0.2)


# ----- Binary I/O -----------------------------------------------------------
def run_session(env_extra: dict, store: str, messages: list[dict], stderr_path: str, hold: float = 4.0) -> dict[int, dict]:
    """Stdout goes to a file (not PIPE) — large response payloads can exceed the
    default 64 KB pipe buffer and block the binary waiting for a reader."""
    fp_err = open(stderr_path, "a")
    out_path = stderr_path.replace(".stderr", f".stdout.{int(time.time()*1000)}")
    fp_out = open(out_path, "w")
    proc = subprocess.Popen(
        [BIN],
        env={**os.environ, "CLAUDE_MIND_STORE_URL": store, **env_extra},
        stdin=subprocess.PIPE, stdout=fp_out, stderr=fp_err,
        text=True, bufsize=1
    )
    for m in messages:
        proc.stdin.write(json.dumps(m) + "\n"); proc.stdin.flush()
    time.sleep(hold)
    proc.stdin.close()
    try: proc.wait(timeout=15)
    except subprocess.TimeoutExpired: proc.kill()
    fp_out.close(); fp_err.close()
    by_id = {}
    with open(out_path) as f:
        for line in f:
            line = line.strip()
            if not line: continue
            try: d = json.loads(line)
            except Exception: continue
            if "id" in d and "result" in d:
                by_id[d["id"]] = d["result"]
    return by_id


def parse_payload(result: dict) -> dict | None:
    if not result or "content" not in result: return None
    try:
        return json.loads(result["content"][0]["text"])
    except Exception:
        return None


# ----- Metric definitions ---------------------------------------------------
def reciprocal_rank_at_k(ranked_ids: list[str], grades: dict[str, int], k: int = 5) -> float:
    for i, mid in enumerate(ranked_ids[:k]):
        if grades.get(mid, 0) >= 1:
            return 1.0 / (i + 1)
    return 0.0

def success_at_k(ranked_ids: list[str], grades: dict[str, int], k: int = 5) -> float:
    return 1.0 if any(grades.get(mid, 0) >= 1 for mid in ranked_ids[:k]) else 0.0

def ndcg_at_k(ranked_ids: list[str], grades: dict[str, int], k: int = 5) -> float:
    def dcg(items):
        s = 0.0
        for i, g in enumerate(items):
            s += (2**g - 1) / math.log2(i + 2)
        return s
    actual = [grades.get(mid, 0) for mid in ranked_ids[:k]]
    ideal = sorted(grades.values(), reverse=True)[:k]
    if not ideal or sum(ideal) == 0:
        return 0.0
    d_actual = dcg(actual)
    d_ideal  = dcg(ideal)
    return d_actual / d_ideal if d_ideal > 0 else 0.0


# ----- Reranking with arbitrary weights --------------------------------------
def rerank(hits: list[dict], w: tuple[float, float, float, float]) -> list[dict]:
    a, b, g, l = w
    scored = []
    for h in hits:
        s = a * h.get("semantic_score", 0.0) \
          + b * h.get("recency_score",  0.0) \
          + g * h.get("graph_score",    0.0) \
          + l * h.get("lexical_score",  0.0)
        scored.append((s, h))
    scored.sort(key=lambda kv: kv[0], reverse=True)
    return [h for _, h in scored]


def aggregate(rankings: dict[str, list[str]], queries: list[dict], k: int = 5) -> dict[str, float]:
    mrr = []; ndcg = []; succ = []
    for q in queries:
        ranked = rankings.get(q["id"], [])
        grades = q.get("grades", {})
        if not grades:  # skip queries with no relevant memory
            continue
        mrr.append(reciprocal_rank_at_k(ranked, grades, k))
        ndcg.append(ndcg_at_k(ranked, grades, k))
        succ.append(success_at_k(ranked, grades, k))
    return {
        "mrr@5":     statistics.mean(mrr) if mrr else 0,
        "ndcg@5":    statistics.mean(ndcg) if ndcg else 0,
        "success@5": statistics.mean(succ) if succ else 0,
        "n_queries_scored": len(mrr),
    }


# ----- Failure-notebook label suggestions ------------------------------------
def suggest_label(q: dict, ranked: list[dict]) -> str:
    """Auto-suggested, not auto-final. Reviewer should override on the real-data pass.
    Looks up grades by `corpus_id` (the static corpus key), not `id` (the runtime UUID).
    """
    grades = q.get("grades", {})
    if not grades: return "no-truth"
    top = ranked[:5]
    top_grades = [grades.get(h.get("corpus_id"), 0) for h in top]
    if not top_grades: return "no-results"
    if max(top_grades) == 0:
        return "miss"          # nothing relevant in top-5; ground truth exists somewhere outside
    if top_grades[0] == 0:
        # Top hit irrelevant but a relevant memory is in top-5.
        if top[0].get("lexical_score", 0) > 0.3:
            return "lexical-hit"
        return "rank-issue"
    if top_grades[0] == 2:
        return "good"
    if top_grades[0] == 1:
        return "partial-top1"
    return "unclassified"


# ----- Phases ----------------------------------------------------------------
def load_corpus(path: str) -> tuple[list[dict], list[dict]]:
    mem = [json.loads(l) for l in open(os.path.join(path, "memories.jsonl")) if l.strip()]
    qs  = [json.loads(l) for l in open(os.path.join(path, "queries.jsonl"))  if l.strip()]
    return mem, qs


def populate_store(memories: list[dict], store: str, stderr_path: str):
    init = {"jsonrpc":"2.0","id":1,"method":"initialize","params":{
        "protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"quality","version":"0.0.1"}}}
    initialized = {"jsonrpc":"2.0","method":"notifications/initialized"}
    msgs = [init, initialized]
    for i, m in enumerate(memories):
        msgs.append({"jsonrpc":"2.0","id":1000+i,"method":"tools/call","params":{
            "name":"remember","arguments":{
                "text": m["text"],
                "source": m.get("source", "synthetic"),
                "tags": m.get("tags", []),
                "occurred_at": m.get("occurred_at"),
            }}})
    # Write + give the mirror generous time to drain.
    print(f"  populating store with {len(memories)} memories…", flush=True)
    res = run_session(
        {"CLAUDE_MIND_ENABLE_PGVECTOR_MIRROR": "true", "CLAUDE_MIND_PG_DSN": DSN},
        store, msgs, stderr_path, hold=18,
    )
    # Build a corpus_id → server_uuid map by scanning the stored responses.
    id_map = {}
    for i, m in enumerate(memories):
        rid = 1000 + i
        payload = parse_payload(res.get(rid, {}))
        if payload and "id" in payload:
            id_map[m["id"]] = payload["id"]
    print(f"  mapped {len(id_map)}/{len(memories)} corpus ids → server UUIDs")
    return id_map


def run_queries(queries: list[dict], store: str, env_extra: dict, stderr_path: str, k: int = 25) -> dict[str, dict]:
    init = {"jsonrpc":"2.0","id":1,"method":"initialize","params":{
        "protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"quality","version":"0.0.1"}}}
    initialized = {"jsonrpc":"2.0","method":"notifications/initialized"}
    msgs = [init, initialized]
    for i, q in enumerate(queries):
        msgs.append({"jsonrpc":"2.0","id":2000+i,"method":"tools/call","params":{
            "name":"recall","arguments":{"query": q["query"], "k": k}}})
    res = run_session(env_extra, store, msgs, stderr_path, hold=8)
    out = {}
    for i, q in enumerate(queries):
        payload = parse_payload(res.get(2000+i, {}))
        out[q["id"]] = payload or {"hits": [], "path": "error"}
    return out


# ----- Top-level orchestration ----------------------------------------------
def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--corpus", default=os.path.join(HERE, "synthetic"))
    ap.add_argument("--out",    default=os.path.join(HERE, "results"))
    args = ap.parse_args()

    os.makedirs(args.out, exist_ok=True)
    stderr_path = os.path.join(args.out, "server.stderr")
    open(stderr_path, "w").close()

    pg_start()
    pg("DROP DATABASE IF EXISTS claude_mind_quality;", db="postgres")
    pg("CREATE DATABASE claude_mind_quality;", db="postgres")
    pg("CREATE EXTENSION vector;", db=PG_DB)

    memories, queries = load_corpus(args.corpus)
    print(f"corpus: {len(memories)} memories, {len(queries)} queries → {args.out}")

    work = tempfile.mkdtemp()
    store = os.path.join(work, "memory.sqlite")

    # ---- Phase A: populate ----
    id_map = populate_store(memories, store, stderr_path)
    pg_count = pg("SELECT count(*) FROM memories;")
    pg_emb   = pg("SELECT count(*) FROM memory_embeddings_minilm_l6_v2_3786b7;")
    print(f"  postgres: {pg_count} memories, {pg_emb} embeddings")
    pct = int(pg_count) / max(1, len(memories))
    if pct < 0.95:
        raise SystemExit(f"populate fail: only {pg_count}/{len(memories)} memories ({pct:.1%}) in PG")
    if int(pg_count) != len(memories):
        print(f"  warn: {len(memories) - int(pg_count)} memories missing in PG ({pct:.2%}); continuing")

    # Reverse: server uuid → corpus id (for grading lookup)
    uuid_to_corpus = {v.lower(): k for k, v in id_map.items()}

    def map_payload(payload: dict) -> list[dict]:
        # tag each hit with its corpus id for grade lookup
        hits = payload.get("hits", [])
        for h in hits:
            sid = (h.get("id") or "").lower()
            h["corpus_id"] = uuid_to_corpus.get(sid)
        return hits

    # ---- Phase B: mirror responses ----
    print("phase B: capturing mirror responses (full candidate scores)…", flush=True)
    mirror_responses = run_queries(queries, store,
        {"CLAUDE_MIND_ENABLE_PGVECTOR_MIRROR": "true", "CLAUDE_MIND_PG_DSN": DSN},
        stderr_path, k=25)
    mirror_paths = {qid: r.get("path", "?") for qid, r in mirror_responses.items()}
    print(f"  paths taken: {dict((p, list(mirror_paths.values()).count(p)) for p in set(mirror_paths.values()))}")

    # ---- Phase C: local responses ----
    print("phase C: capturing local responses…", flush=True)
    local_responses = run_queries(queries, store, {}, stderr_path, k=25)

    # Re-key by corpus id for both runs.
    mirror_hits = {qid: map_payload(r) for qid, r in mirror_responses.items()}
    local_hits  = {qid: map_payload(r) for qid, r in local_responses.items()}

    # Drop hits without a corpus_id mapping (shouldn't happen, but safe).
    for d in (mirror_hits, local_hits):
        for qid in list(d.keys()):
            d[qid] = [h for h in d[qid] if h.get("corpus_id")]

    # Translate query grades to use server uuids? No — we kept corpus_ids on hits.
    queries_by_id = {q["id"]: q for q in queries}

    # ---- Score each ablation -----------------------------------------------
    def rankings_with_weights(hits_by_query: dict[str, list[dict]], w: tuple[float, float, float, float]) -> dict[str, list[str]]:
        out = {}
        for qid, hits in hits_by_query.items():
            ranked = rerank(hits, w)
            out[qid] = [h["corpus_id"] for h in ranked]
        return out

    DEFAULT_W = (0.55, 0.20, 0.10, 0.15)
    ablations = {
        "1_local-only":             ("local",  (0.70, 0.30, 0.0, 0.0)),
        "2_mirror-seeds":           ("mirror", (0.70, 0.30, 0.0, 0.0)),
        "3_mirror-graph":           ("mirror", (0.60, 0.20, 0.20, 0.0)),
        "4_mirror-graph-lexical":   ("mirror", DEFAULT_W),
    }

    ablation_metrics = {}
    ablation_rankings = {}
    for name, (source, w) in ablations.items():
        hits = local_hits if source == "local" else mirror_hits
        rankings = rankings_with_weights(hits, w)
        ablation_metrics[name] = aggregate(rankings, queries, k=5) | {"weights": w, "source": source}
        ablation_rankings[name] = rankings

    print("\nablation metrics @k=5:")
    print(f"  {'ablation':<28} {'MRR':>6}  {'nDCG':>6}  {'Succ':>6}  weights (α,β,γ,δ)")
    for name, m in ablation_metrics.items():
        print(f"  {name:<28} {m['mrr@5']:>6.3f}  {m['ndcg@5']:>6.3f}  {m['success@5']:>6.3f}  {m['weights']}")

    # ---- Coarse weight sweep on full hybrid (mirror_hits) ------------------
    print("\nweight sweep (coarse 5×5×5)…", flush=True)
    grid = [0.10, 0.30, 0.50, 0.70, 0.90]
    coarse = []
    for a in grid:
        for b in grid:
            for g in grid:
                d = 1.0 - a - b - g
                if d < 0 or d > 1.0: continue
                w = (a, b, g, d)
                rankings = rankings_with_weights(mirror_hits, w)
                m = aggregate(rankings, queries, k=5)
                coarse.append((m["mrr@5"], m["ndcg@5"], w))
    coarse.sort(reverse=True)
    print(f"  coarse best 5: {[(f'mrr={c[0]:.3f}', f'w={c[2]}') for c in coarse[:5]]}")

    # ---- Fine sweep around top 10 -----------------------------------------
    fine = []
    for _, _, w0 in coarse[:10]:
        for da in (-0.1, -0.05, 0, 0.05, 0.1):
            for db in (-0.1, -0.05, 0, 0.05, 0.1):
                for dg in (-0.05, 0, 0.05):
                    a = max(0, min(1, w0[0] + da))
                    b = max(0, min(1, w0[1] + db))
                    g = max(0, min(1, w0[2] + dg))
                    d = 1.0 - a - b - g
                    if d < 0 or d > 1.0: continue
                    w = (round(a, 3), round(b, 3), round(g, 3), round(d, 3))
                    rankings = rankings_with_weights(mirror_hits, w)
                    m = aggregate(rankings, queries, k=5)
                    fine.append((m["mrr@5"], m["ndcg@5"], w, m["success@5"]))
    fine.sort(reverse=True)
    fine_uniq = []
    seen = set()
    for entry in fine:
        if entry[2] in seen: continue
        seen.add(entry[2])
        fine_uniq.append(entry)
        if len(fine_uniq) >= 10: break
    print(f"  fine best 5:")
    for mrr, ndcg, w, succ in fine_uniq[:5]:
        print(f"    mrr={mrr:.3f}  ndcg={ndcg:.3f}  succ={succ:.3f}  w={w}")
    best = fine_uniq[0]

    # ---- Failure notebook -------------------------------------------------
    nb_path = os.path.join(args.out, "failure_notebook.md")
    with open(nb_path, "w") as f:
        f.write(f"# Failure notebook\n\n")
        f.write(f"_Default ablation: 4_mirror-graph-lexical, weights={DEFAULT_W}_\n\n")
        rankings = rankings_with_weights(mirror_hits, DEFAULT_W)
        for q in queries:
            qid = q["id"]
            ranked_ids = rankings.get(qid, [])
            ranked_hits = [h for cid in ranked_ids[:5] for h in mirror_hits[qid] if h["corpus_id"] == cid][:5]
            grades = q.get("grades", {})
            label = suggest_label(q, ranked_hits)
            f.write(f"## `{qid}` — {q['query']}\n\n")
            f.write(f"_suggested label: **{label}**_   ")
            f.write(f"path: `{mirror_paths.get(qid, '?')}`   ")
            mrr = reciprocal_rank_at_k(ranked_ids, grades, 5)
            f.write(f"MRR@5={mrr:.3f}   nDCG@5={ndcg_at_k(ranked_ids, grades, 5):.3f}\n\n")
            f.write("| rank | id | grade | sem | rec | graph | lex | text |\n")
            f.write("|---|---|---|---|---|---|---|---|\n")
            for i, h in enumerate(ranked_hits):
                cid = h["corpus_id"]
                g = grades.get(cid, 0)
                f.write(f"| {i+1} | `{cid}` | {g} | "
                        f"{h.get('semantic_score',0):.3f} | "
                        f"{h.get('recency_score',0):.3f} | "
                        f"{h.get('graph_score',0):.3f} | "
                        f"{h.get('lexical_score',0):.3f} | "
                        f"{h.get('text','')[:60]} |\n")
            f.write("\n")

    # ---- Results.json ------------------------------------------------------
    results = {
        "corpus": {
            "memories": len(memories),
            "queries": len(queries),
            "graded_queries": sum(1 for q in queries if q.get("grades")),
        },
        "default_weights": DEFAULT_W,
        "ablations": ablation_metrics,
        "coarse_top10": [{"mrr@5": m, "ndcg@5": n, "weights": list(w)} for m, n, w in coarse[:10]],
        "fine_top10":   [{"mrr@5": m, "ndcg@5": n, "success@5": s, "weights": list(w)} for m, n, w, s in fine_uniq],
        "best_weights": list(best[2]),
        "best_metrics": {"mrr@5": best[0], "ndcg@5": best[1], "success@5": best[3]},
    }
    with open(os.path.join(args.out, "results.json"), "w") as f:
        json.dump(results, f, indent=2)
    print(f"\nresults → {os.path.join(args.out, 'results.json')}")
    print(f"failure notebook → {nb_path}")

    print(f"\nbest fine config: weights={best[2]}  mrr={best[0]:.3f}  ndcg={best[1]:.3f}  succ={best[3]:.3f}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
