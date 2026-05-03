"""v2.3 parity harness: local vs mirror top-K on a fixed corpus.

Run 1 (PG up, mirror on):
  - write the bench corpus (30 sentences) into a fresh store
  - wait for mirror to drain
  - issue the parity query set; collect top-5 hit ids per query
  - this is the MIRROR result

Run 2 (PG down, mirror off — same store):
  - reopen the store with mirror disabled
  - issue the same query set; collect top-5 hit ids per query
  - this is the LOCAL result

Compare per query:
  - Jaccard(top5_mirror, top5_local)
  - rank correlation (Spearman) on the intersection
Pass criterion: mean Jaccard >= 0.6 across the query set.

The mirror's vector path is approximate (HNSW) and uses a slightly different
scoring blend (graph proximity + lexical), so 100% agreement isn't expected.
What we care about is that the top-K sets overlap heavily and ranks track.
"""
import json
import os
import statistics
import subprocess
import sys
import tempfile
import time

PG17_BIN = "/opt/homebrew/opt/postgresql@17/bin"
PG_DATA  = "/opt/homebrew/var/postgresql@17"
PG_PORT  = "5433"
PG_DB    = "claude_mind_test"
DSN      = f"postgresql://{os.environ['USER']}@localhost:{PG_PORT}/{PG_DB}?sslmode=disable"
BIN      = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".build", "debug", "claude-mind-mcp"))

CORPUS = [
    "Had coffee with Sarah at Blue Bottle in Oakland to plan the Q3 release.",
    "Met Carlos for lunch in Brooklyn; we discussed the new pgvector schema.",
    "Bought new running shoes at the REI in Berkeley.",
    "Called Mom about the Thanksgiving travel plans.",
    "Reviewed the architecture doc for the auth migration with Priya.",
    "Watched the WWDC session on NLContextualEmbedding and async assets.",
    "Picked up a new book at City Lights in San Francisco.",
    "Long run along the Embarcadero, twelve miles, felt great.",
    "Pair-programmed with Jordan on the outbox drainer in Swift.",
    "Lunch leftovers from the new Thai place near the office.",
    "Filed the bug for the recall_around timezone edge case.",
    "Coffee chat with a recruiter about a Core ML role at a startup.",
    "Helped Em debug a Core Data merge policy issue.",
    "Read the Apple docs for NLTagger sentiment scoring.",
    "Bench experiment: cpuOnly vs cpuAndNeuralEngine vs all.",
    "Walk in Tilden Park, saw a barred owl on the fire road.",
    "Notes from the standup: the mirror worker design is unblocked.",
    "Tea with Ana at Saul's deli, talked about her PhD defense.",
    "Set up the Postgres development DB on the new laptop.",
    "Refactored the ManagedObjectModelBuilder to use NSEntityDescription.indexes.",
    "Sketched the Core ML embedding backend interface during the bus ride.",
    "Watched a documentary on the Pixar render farm history.",
    "Bought groceries: oat milk, sourdough, persimmons, kale.",
    "Met a friend at the Berkeley Marina to fly kites.",
    "Tracked down a flaky test in the recall pipeline.",
    "Read a paper on hybrid retrieval combining BM25 and dense vectors.",
    "Coffee at home, journaled about the v1.5 sequencing decision.",
    "Booked a dentist appointment for next month.",
    "Played piano for an hour, working through Debussy's Reverie.",
    "Wrote a postmortem for the asset-download timeout incident."
]

QUERIES = [
    "who did I meet for food",
    "running and exercise",
    "machine learning and embeddings",
    "phone calls with family",
    "Postgres / database work",
    "outdoor walks and parks",
    "writing and journaling",
    "musical practice"
]

K = 5


def pg(sql: str) -> str:
    return subprocess.run(
        [f"{PG17_BIN}/psql", "-p", PG_PORT, "-d", PG_DB, "-tAc", sql],
        capture_output=True, text=True
    ).stdout.strip()


def pg_start():
    subprocess.run([f"{PG17_BIN}/pg_ctl", "-D", PG_DATA, "-o", f"-p {PG_PORT}", "-l", "/tmp/pg17.log", "start"],
                   capture_output=True)
    for _ in range(20):
        if subprocess.run([f"{PG17_BIN}/pg_isready", "-p", PG_PORT], capture_output=True).returncode == 0:
            return
        time.sleep(0.2)


def jaccard(a, b):
    a, b = set(a), set(b)
    return len(a & b) / max(1, len(a | b))


def spearman(a, b):
    """Rank correlation on the intersection of a, b. Returns nan if intersection < 2."""
    common = [x for x in a if x in b]
    if len(common) < 2:
        return float("nan")
    rank_a = {x: i for i, x in enumerate(a) if x in common}
    rank_b = {x: i for i, x in enumerate(b) if x in common}
    n = len(common)
    d2 = sum((rank_a[x] - rank_b[x]) ** 2 for x in common)
    return 1 - (6 * d2) / (n * (n * n - 1))


def run_session(env_extra: dict, store: str, messages: list[dict], hold: float) -> dict[int, dict]:
    fp = open(os.path.join(os.path.dirname(store), "server.stderr"), "a")
    proc = subprocess.Popen(
        [BIN],
        env={**os.environ, "CLAUDE_MIND_STORE_URL": store, **env_extra},
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=fp,
        text=True, bufsize=1
    )
    for m in messages:
        proc.stdin.write(json.dumps(m) + "\n"); proc.stdin.flush()
    time.sleep(hold)
    proc.stdin.close()
    out = proc.stdout.read()
    proc.wait(timeout=5)
    fp.close()
    by_id = {}
    for line in out.splitlines():
        line = line.strip()
        if not line: continue
        try:
            d = json.loads(line)
        except Exception:
            continue
        if "id" in d and "result" in d:
            by_id[d["id"]] = d["result"]
    return by_id


def main() -> int:
    pg_start()
    pg("DROP SCHEMA public CASCADE; CREATE SCHEMA public; CREATE EXTENSION vector;")
    work = tempfile.mkdtemp()
    store = os.path.join(work, "memory.sqlite")

    init = {"jsonrpc":"2.0","id":1,"method":"initialize","params":{
        "protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"parity","version":"0.0.1"}}}
    initialized = {"jsonrpc":"2.0","method":"notifications/initialized"}

    # Phase 1: write corpus + run queries with mirror enabled.
    msgs = [init, initialized]
    for i, text in enumerate(CORPUS):
        msgs.append({"jsonrpc":"2.0","id":100+i,"method":"tools/call","params":{
            "name":"remember","arguments":{"text":text}}})
    msgs.append({"jsonrpc":"2.0","id":1000,"method":"tools/call","params":{"name":"list_recent","arguments":{"limit":2}}})
    # Phase 1 doesn't need recall yet; we want all writes + drain to land first.
    print(f"[phase 1] writing {len(CORPUS)} memories with mirror enabled")
    run_session({"CLAUDE_MIND_ENABLE_PGVECTOR_MIRROR":"true", "CLAUDE_MIND_PG_DSN": DSN},
                store, msgs, hold=8)
    print(f"[phase 1] memories in PG: {pg('SELECT count(*) FROM memories;')}")

    # Phase 2: same store, mirror enabled — recall set. (mirror path)
    print(f"[phase 2] mirror recall set")
    msgs = [init, initialized]
    for i, q in enumerate(QUERIES):
        msgs.append({"jsonrpc":"2.0","id":2000+i,"method":"tools/call","params":{
            "name":"recall","arguments":{"query":q,"k":K}}})
    mirror_results = run_session({"CLAUDE_MIND_ENABLE_PGVECTOR_MIRROR":"true", "CLAUDE_MIND_PG_DSN": DSN},
                                 store, msgs, hold=4)

    # Phase 3: same store, mirror DISABLED — local recall set.
    print(f"[phase 3] local recall set")
    msgs = [init, initialized]
    for i, q in enumerate(QUERIES):
        msgs.append({"jsonrpc":"2.0","id":3000+i,"method":"tools/call","params":{
            "name":"recall","arguments":{"query":q,"k":K}}})
    local_results = run_session({}, store, msgs, hold=4)

    # Compare top-K id sets per query.
    print()
    print(f"{'query':<42} jaccard   spearman   path_m   path_l")
    jaccards = []
    for i, q in enumerate(QUERIES):
        m_res = mirror_results.get(2000+i, {})
        l_res = local_results.get(3000+i, {})
        m_payload = json.loads(m_res["content"][0]["text"]) if m_res.get("content") else {}
        l_payload = json.loads(l_res["content"][0]["text"]) if l_res.get("content") else {}
        m_ids = [h["id"] for h in m_payload.get("hits", [])]
        l_ids = [h["id"] for h in l_payload.get("hits", [])]
        j = jaccard(m_ids, l_ids)
        s = spearman(m_ids, l_ids)
        jaccards.append(j)
        print(f"  {q[:40]:<40} {j:.2f}      {s:.2f}      {m_payload.get('path','?'):<8}{l_payload.get('path','?')}")

    mean_j = statistics.mean(jaccards) if jaccards else 0
    print()
    print(f"[summary] mean_jaccard={mean_j:.3f}  threshold=0.60  result={'pass' if mean_j >= 0.60 else 'fail'}")
    return 0 if mean_j >= 0.60 else 1


if __name__ == "__main__":
    sys.exit(main())
