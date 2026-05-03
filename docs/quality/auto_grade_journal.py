"""Auto-grading template for journal / notes corpora.

Companion to `auto_grade.py` (which is tuned for commit-log shape). The rule
shapes here match the kinds of queries you actually ask of personal memory:

  - "what did <person> say about <topic>"   → person + topic both required
  - "where was I when <event>"              → event/place match
  - "how did I feel about <event>"          → topic match + sentiment cue
  - "what did I read about <X>"             → topic match
  - "who was at <event>"                    → event match → list mentions

Like the commit-log grader, this is heuristic and meant as a starting point.
You'll want to customize per-query rules when you have your real corpus.

Usage:
    1. Put memories.jsonl + queries.jsonl in docs/quality/<your-name>/.
       Format spec at docs/quality/corpus_format.md.
    2. Edit the rules below to match your queries.
    3. python3 docs/quality/auto_grade_journal.py --corpus docs/quality/<your-name>
    4. Run docs/quality/run_quality.py against the same dir.
"""
from __future__ import annotations
import argparse
import json
import os
import re
import sys
from datetime import date


# ----- Regex helpers --------------------------------------------------------
def whole_word(text: str, term: str, flags=re.IGNORECASE) -> bool:
    return bool(re.search(rf"\b{re.escape(term)}\b", text, flags=flags))


def text_contains_all(text: str, terms: list[str]) -> bool:
    t = text.lower()
    return all(term.lower() in t for term in terms)


def text_contains_any(text: str, terms: list[str]) -> bool:
    t = text.lower()
    return any(term.lower() in t for term in terms)


def memory_dates_in_window(m: dict, start: str, end: str) -> bool:
    """ISO date string comparisons (YYYY-MM-DD) — works for journal-shaped
    `created_at` / `occurred_at` since both are ISO."""
    d = (m.get("occurred_at") or m.get("created_at") or "")[:10]
    return start <= d <= end


# ----- Rule shapes ---------------------------------------------------------
# Each rule is a function (query_dict, memory_dict) → grade_int_or_None.
# Highest grade wins across rules that match. None = no opinion.

def rule_who_said_what(q: dict, m: dict) -> int | None:
    """'what did <person> say about <topic>' → both must appear."""
    qt = q["query"].lower()
    match = re.search(r"what did (\w+) say about (.+?)(\?|$)", qt)
    if not match: return None
    person, topic = match.group(1), match.group(2).strip()
    text = m["text"].lower()
    ents = [e.lower() for e in m.get("entities", [])]
    has_person = (person in ents) or whole_word(m["text"], person)
    has_topic = (topic in text) or any(t in text for t in topic.split() if len(t) >= 3)
    if has_person and has_topic: return 2
    if has_person or has_topic: return 1
    return None


def rule_where_was_i(q: dict, m: dict) -> int | None:
    """'where was I when <event>' → memory mentions the event."""
    qt = q["query"].lower()
    match = re.search(r"where was i (?:when |during )?(.+?)(\?|$)", qt)
    if not match: return None
    event = match.group(1).strip()
    if event in m["text"].lower(): return 2
    if any(t in m["text"].lower() for t in event.split() if len(t) >= 4): return 1
    return None


def rule_how_did_i_feel(q: dict, m: dict) -> int | None:
    """'how did I feel about <X>' → topic match plus a sentiment hint."""
    qt = q["query"].lower()
    match = re.search(r"how did i feel about (.+?)(\?|$)", qt)
    if not match: return None
    topic = match.group(1).strip()
    text = m["text"].lower()
    if topic not in text and not any(t in text for t in topic.split() if len(t) >= 4):
        return None
    sentiment_words = ["happy", "sad", "anxious", "tired", "excited",
                       "disappointed", "great", "rough", "ok", "fine",
                       "loved", "hated", "felt"]
    if any(w in text for w in sentiment_words): return 2
    return 1


def rule_what_did_i_read(q: dict, m: dict) -> int | None:
    """'what did I read about <X>' → topic match in a reading-flavored memory."""
    qt = q["query"].lower()
    match = re.search(r"what did i read (?:about )?(.+?)(\?|$)", qt)
    if not match: return None
    topic = match.group(1).strip()
    text = m["text"].lower()
    reading = any(w in text for w in ["read", "book", "article", "paper", "essay"])
    has_topic = topic in text or any(t in text for t in topic.split() if len(t) >= 4)
    if reading and has_topic: return 2
    if has_topic: return 1
    return None


def rule_who_was_at(q: dict, m: dict) -> int | None:
    """'who was at <event>' → memory mentions the event AND has people."""
    qt = q["query"].lower()
    match = re.search(r"who was at (.+?)(\?|$)", qt)
    if not match: return None
    event = match.group(1).strip()
    text = m["text"].lower()
    if event not in text: return None
    has_people = any(
        e for e in m.get("entities", [])
        if any(c.isupper() for c in e) and len(e) > 2
    )
    return 2 if has_people else 1


def rule_around_date(q: dict, m: dict) -> int | None:
    """'what did I do around <date>' or 'last <weekday>' style → temporal match.
    The query date should be present in the query string as YYYY-MM-DD."""
    iso = re.search(r"(\d{4}-\d{2}-\d{2})", q["query"])
    if not iso: return None
    target = iso.group(1)
    mdate = (m.get("occurred_at") or m.get("created_at") or "")[:10]
    if not mdate: return None
    if mdate == target: return 2
    # adjacent days = grade 1
    try:
        d_target = date.fromisoformat(target)
        d_mem    = date.fromisoformat(mdate)
        if abs((d_target - d_mem).days) <= 2: return 1
    except ValueError:
        pass
    return None


def rule_explicit_grades(q: dict, m: dict) -> int | None:
    """If the query came in pre-graded (user provided grades dict), respect it."""
    grades = q.get("grades") or {}
    if not grades or not isinstance(grades, dict): return None
    return grades.get(m["id"])


# Order matters: rule_explicit_grades wins so user-supplied grades aren't overridden.
RULES = [
    rule_explicit_grades,
    rule_who_said_what,
    rule_where_was_i,
    rule_how_did_i_feel,
    rule_what_did_i_read,
    rule_who_was_at,
    rule_around_date,
]


# ----- Top-level loop ------------------------------------------------------
def grade_query(q: dict, memories: list[dict]) -> dict[str, int]:
    out: dict[str, int] = {}
    for m in memories:
        best = None
        for rule in RULES:
            g = rule(q, m)
            if g is None: continue
            if best is None or g > best:
                best = g
        if best is not None and best > 0:
            out[m["id"]] = best
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--corpus", required=True, help="dir containing memories.jsonl + queries.jsonl")
    args = ap.parse_args()

    mp = os.path.join(args.corpus, "memories.jsonl")
    qp = os.path.join(args.corpus, "queries.jsonl")

    memories = [json.loads(l) for l in open(mp) if l.strip()]
    queries  = [json.loads(l) for l in open(qp) if l.strip()]

    print(f"loaded {len(memories)} memories, {len(queries)} queries")

    out_lines = []
    for q in queries:
        # Preserve any pre-existing grades; let rules add to them.
        existing = q.get("grades") or {}
        if not isinstance(existing, dict): existing = {}
        grades = grade_query(q, memories)
        merged = dict(existing)
        for mid, g in grades.items():
            merged[mid] = max(merged.get(mid, 0), g)
        out_lines.append(json.dumps({"id": q["id"], "query": q["query"], "grades": merged}))
        n2 = sum(1 for v in merged.values() if v == 2)
        n1 = sum(1 for v in merged.values() if v == 1)
        print(f"  {q['id']:<14} g2={n2:<3} g1={n1:<3} {q['query'][:60]}")

    with open(qp, "w") as f:
        f.write("\n".join(out_lines) + "\n")
    print(f"\nwrote {qp}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
