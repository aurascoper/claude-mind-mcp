"""Acceptance #4c: mid-flight publish failure increments attempt fields.

Three phases:
  Phase 1 — PG up: write remember; mirror publishes.
  Phase 2 — PG bounced (down → up briefly): postgres-nio reconnects transparently;
            backlog clears once PG is back. Local writes never block.
            (Transient outage is intentionally invisible to attempt fields —
            that's correct behavior; otherwise every blip would be logged.)
  Phase 3 — Force a SQL-level failure (DROP memories table while mirror runs)
            so the next publish actually errors. attemptCount / lastError /
            lastAttemptAt should increment on the row that fails.
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
        r = subprocess.run([f"{PG17_BIN}/pg_isready", "-p", PG_PORT], capture_output=True)
        if r.returncode == 0:
            return
        time.sleep(0.2)
    raise RuntimeError("postgres did not become ready")


def pg_stop():
    subprocess.run([f"{PG17_BIN}/pg_ctl", "-D", PG_DATA, "stop", "-m", "fast"], capture_output=True)


def main() -> int:
    pg_start()
    pg("DROP SCHEMA public CASCADE; CREATE SCHEMA public; CREATE EXTENSION vector;")

    store = os.path.join(tempfile.mkdtemp(), "memory.sqlite")

    stderr_path = os.path.join(os.path.dirname(store), "server.stderr")
    stderr_fp = open(stderr_path, "w")
    proc = subprocess.Popen(
        [BIN],
        env={
            **os.environ,
            "CLAUDE_MIND_STORE_URL": store,
            "CLAUDE_MIND_ENABLE_PGVECTOR_MIRROR": "true",
            "CLAUDE_MIND_PG_DSN": DSN,
        },
        stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=stderr_fp,
        text=True, bufsize=1
    )
    print(f"[server stderr → {stderr_path}]")

    def send(o: dict):
        proc.stdin.write(json.dumps(o) + "\n"); proc.stdin.flush()

    # Phase 1: initialize, remember while PG is up.
    send({"jsonrpc":"2.0","id":1,"method":"initialize","params":{
        "protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"smoke","version":"0.0.1"}}})
    send({"jsonrpc":"2.0","method":"notifications/initialized"})
    send({"jsonrpc":"2.0","id":5,"method":"tools/call","params":{
        "name":"remember","arguments":{"text":"first remember (PG up)"}}})
    time.sleep(3)
    print(f"[PG up]   memories in postgres: {pg('SELECT count(*) FROM memories;')}")

    # Phase 2: take PG down, write second remember. Drainer next poll should fail.
    pg_stop()
    print("[stopped postgres]")
    send({"jsonrpc":"2.0","id":6,"method":"tools/call","params":{
        "name":"remember","arguments":{"text":"second remember (PG down)"}}})
    # postgres-nio's default connect timeout is ~10 s; the drainer's first
    # publish attempt waits that long before erroring, so wait > 10 s.
    time.sleep(13)

    # Phase 3: bring PG back; transient outage publishes transparently.
    pg_start()
    time.sleep(8)
    db = sqlite3.connect(store)
    rows2 = db.execute("SELECT ZSENTAT IS NULL pending FROM ZOUTBOXRECORD").fetchall()
    pg_count = pg("SELECT count(*) FROM memories;")
    print(f"[after PG restart] outbox pending: {sum(p for p, in rows2)}  postgres rows: {pg_count}")
    transient_ok = pg_count == "2" and all(p == 0 for p, in rows2)

    # Phase 4: force a SQL-level failure (drop the memories table) and write again.
    pg("DROP TABLE memories CASCADE;")
    print("[dropped memories table mid-flight]")
    send({"jsonrpc":"2.0","id":7,"method":"tools/call","params":{
        "name":"remember","arguments":{"text":"third remember (memories table dropped)"}}})
    time.sleep(3)

    rows3 = db.execute(
        "SELECT ZSENTAT IS NULL pending, ZATTEMPTCOUNT, substr(ZLASTERROR, 1, 80), ZLASTATTEMPTAT FROM ZOUTBOXRECORD ORDER BY ZCREATEDAT"
    ).fetchall()
    print(f"[after SQL failure] outbox rows: {rows3}")
    failed_ok = any(r[0] == 1 and r[1] >= 1 and r[2] is not None and r[3] is not None for r in rows3)
    if failed_ok:
        print("[pass] SQL-level publish failure incremented attemptCount/lastError/lastAttemptAt")
    else:
        print("[fail] expected at least one pending row with attemptCount>=1 + lastError + lastAttemptAt")

    db.close()
    proc.stdin.close()
    try:
        proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        proc.kill()

    print(f"\n[summary] transient_outage={'pass' if transient_ok else 'fail'}  hard_failure={'pass' if failed_ok else 'fail'}")
    return 0 if (transient_ok and failed_ok) else 1


if __name__ == "__main__":
    sys.exit(main())
