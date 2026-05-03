"""Acceptance #5: heterogeneous-profile rows skip embedding, still mirror metadata.

Setup:
  Run 1 — CoreML(all) profile=minilm-l6-v2, PG DOWN:
          one remember stamps a Core Data row with embeddingProfile=minilm-l6-v2,
          embeddingDim=384, and queues an outbox row that never publishes.
  Run 2 — NL backend forced with profile=nl-512, PG UP:
          mirror's active descriptor is (nl-512, NLContextualEmbedding, 512).
          Drainer picks up the pending outbox row from Run 1.
          publishMemory should mirror canonical metadata + tags but skip the
          embedding upsert because the row's stored profile (minilm-l6-v2/384)
          doesn't match the active descriptor (nl-512/512).

Verifies:
  - row lands in `memories`
  - row NOT in any per-profile embedding table
  - a fresh remember in Run 2 (whose stored profile matches the active one)
    DOES land in the active profile's embedding table
"""
import json
import os
import subprocess
import sqlite3
import sys
import tempfile
import time

PG17_BIN = "/opt/homebrew/opt/postgresql@17/bin"
PG_DATA  = "/opt/homebrew/var/postgresql@17"
PG_PORT  = "5433"
PG_DB    = "claude_mind_test"
DSN      = f"postgresql://{os.environ['USER']}@localhost:{PG_PORT}/{PG_DB}?sslmode=disable"
BIN      = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".build", "debug", "claude-mind-mcp"))


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


def pg_stop():
    subprocess.run([f"{PG17_BIN}/pg_ctl", "-D", PG_DATA, "stop", "-m", "fast"], capture_output=True)


def run_server(env_extra: dict, store_path: str, stderr_path: str, messages: list[dict], hold_seconds: float = 6.0):
    fp = open(stderr_path, "w")
    proc = subprocess.Popen(
        [BIN],
        env={
            **os.environ,
            "CLAUDE_MIND_STORE_URL": store_path,
            "CLAUDE_MIND_ENABLE_PGVECTOR_MIRROR": "true",
            "CLAUDE_MIND_PG_DSN": DSN,
            **env_extra,
        },
        stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=fp,
        text=True, bufsize=1
    )
    for m in messages:
        proc.stdin.write(json.dumps(m) + "\n"); proc.stdin.flush()
    time.sleep(hold_seconds)
    proc.stdin.close()
    try:
        proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        proc.kill()
    fp.close()


def main() -> int:
    work = tempfile.mkdtemp()
    store = os.path.join(work, "memory.sqlite")

    # ----- Run 1: CoreML active, PG DOWN; stamp memory A with profile=minilm-l6-v2 -----
    pg_start()
    pg("DROP SCHEMA public CASCADE; CREATE SCHEMA public; CREATE EXTENSION vector;")
    pg_stop()  # mirror will fail to connect; outbox holds the row

    init = {"jsonrpc":"2.0","id":1,"method":"initialize","params":{
        "protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"smoke","version":"0.0.1"}}}
    initialized = {"jsonrpc":"2.0","method":"notifications/initialized"}
    rememberA = {"jsonrpc":"2.0","id":5,"method":"tools/call","params":{
        "name":"remember","arguments":{"text":"memory A under CoreML/minilm-l6-v2"}}}

    run_server({}, store, os.path.join(work, "run1.stderr"),
               [init, initialized, rememberA], hold_seconds=4)

    db = sqlite3.connect(store)
    a = db.execute("SELECT ZID, ZEMBEDDINGPROFILE, ZEMBEDDINGDIM FROM ZMEMORYRECORD").fetchall()
    out1 = db.execute("SELECT ZSENTAT IS NULL pending, ZRECORDID FROM ZOUTBOXRECORD").fetchall()
    db.close()
    print(f"[run1] memory A stamped: {a}")
    print(f"[run1] outbox: {out1}")
    if not (a and a[0][1] == "minilm-l6-v2" and a[0][2] == 384 and out1 and out1[0][0] == 1):
        print("[fail] Run 1 prerequisites not met")
        return 1

    # ----- Run 2: NL forced with a distinct profile, PG UP -----
    pg_start()
    pg("DROP SCHEMA public CASCADE; CREATE SCHEMA public; CREATE EXTENSION vector;")
    rememberB = {"jsonrpc":"2.0","id":6,"method":"tools/call","params":{
        "name":"remember","arguments":{"text":"memory B under NL/nl-512"}}}

    run_server(
        {"CLAUDE_MIND_EMBEDDING_BACKEND": "nl",
         "CLAUDE_MIND_EMBEDDING_PROFILE": "nl-512"},
        store, os.path.join(work, "run2.stderr"),
        [init, initialized, rememberB], hold_seconds=8
    )

    # Verify Postgres state.
    profiles = pg("SELECT id, dim FROM embedding_profiles ORDER BY id;")
    memories_count = pg("SELECT count(*) FROM memories;")
    nl_rows = pg("SELECT count(*) FROM memory_embeddings_nl_512_2cb3a8;")  # safeID computed below
    # We don't know the exact safeID hex; query by table name pattern instead.
    table_names = pg("SELECT tablename FROM pg_tables WHERE tablename LIKE 'memory_embeddings_%' ORDER BY tablename;")
    print(f"[run2] embedding_profiles: {profiles}")
    print(f"[run2] memories rows: {memories_count}")
    print(f"[run2] per-profile tables: {table_names}")
    nl_table = None
    minilm_table = None
    for t in table_names.split("\n"):
        t = t.strip()
        if t.startswith("memory_embeddings_nl_512"): nl_table = t
        if t.startswith("memory_embeddings_minilm"):  minilm_table = t
    nl_count = pg(f"SELECT count(*) FROM {nl_table};") if nl_table else "0"
    print(f"[run2] {nl_table}: {nl_count} rows")
    print(f"[run2] minilm table present: {minilm_table is not None}")

    db = sqlite3.connect(store)
    final_outbox = db.execute(
        "SELECT ZSENTAT IS NULL pending, ZATTEMPTCOUNT FROM ZOUTBOXRECORD"
    ).fetchall()
    db.close()
    print(f"[run2] final outbox: {final_outbox}")

    # Acceptance criteria.
    pass_canonical = memories_count == "2"
    pass_skip      = nl_count == "1" and minilm_table is None
    pass_drain     = all(p == 0 for p, _ in final_outbox)

    print(f"\n[summary] canonical_metadata_mirrored={pass_canonical}  embedding_skip_for_old_profile={pass_skip}  outbox_drained={pass_drain}")
    return 0 if (pass_canonical and pass_skip and pass_drain) else 1


if __name__ == "__main__":
    sys.exit(main())
