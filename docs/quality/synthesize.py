"""Generate a synthetic memory corpus + query set for the quality harness.

Output:
  docs/quality/synthetic/memories.jsonl
  docs/quality/synthetic/queries.jsonl

~300 memories spanning work / social / errands / health / hobbies, with
entity reuse so graph expansion has something to do, temporal spread of ~200
days, and 50 queries auto-graded against the corpus.
"""
import json
import os
import random
from datetime import datetime, timedelta, timezone

random.seed(42)

OUT_DIR = os.path.join(os.path.dirname(__file__), "synthetic")
os.makedirs(OUT_DIR, exist_ok=True)

# ----- Entity pool. Reuse counts roughly geometric so a few names dominate. -----
PEOPLE   = ["Sarah", "Carlos", "Priya", "Jordan", "Em", "Ana", "Mom", "Dad",
            "Alex", "Maya", "Diego", "Yuki", "Nico", "Ravi"]
PLACES   = ["Oakland", "Brooklyn", "Berkeley", "San Francisco", "Tilden Park",
            "the Embarcadero", "REI", "Blue Bottle", "Saul's Deli", "Tartine",
            "Half Moon Bay", "Tilden", "City Lights"]
PROJECTS = ["pgvector schema", "auth migration", "Q3 release", "recall pipeline",
            "Core ML embedding", "outbox drainer", "mirror worker",
            "NLContextualEmbedding", "MiniLM model", "tokenizer pipeline"]
TOPICS   = ["sleep tracking", "marathon training", "espresso brewing",
            "piano practice", "Debussy", "linear algebra", "graph theory",
            "BERT fine-tuning", "vector quantization"]
ITEMS    = ["running shoes", "oat milk", "sourdough", "kale", "persimmons",
            "coffee beans", "a notebook", "headphones"]

TAG_BY_DOMAIN = {
    "work":    ["work"],
    "social":  ["social"],
    "errand":  ["errand"],
    "health":  ["health"],
    "hobby":   ["hobby"],
    "travel":  ["travel"],
}

# ----- Memory templates. Each returns (text, entities, tags). -----
def t_coffee(rng):
    p, place, proj = rng.choice(PEOPLE), rng.choice(PLACES[:8]), rng.choice(PROJECTS)
    return (f"Coffee with {p} at {place}; we discussed the {proj}.",
            [p, place, proj], ["work", "coffee"])

def t_lunch(rng):
    p, place = rng.choice(PEOPLE), rng.choice(PLACES)
    proj = rng.choice(PROJECTS) if rng.random() < 0.6 else None
    text = f"Lunch with {p} in {place}"
    ents = [p, place]
    tags = ["social"]
    if proj:
        text += f"; we sketched the {proj}."
        ents.append(proj)
        tags.append("work")
    else:
        text += "."
    return (text, ents, tags)

def t_ping(rng):
    p, proj = rng.choice(PEOPLE), rng.choice(PROJECTS)
    return (f"{p} pinged about the {proj}.",
            [p, proj], ["work"])

def t_review(rng):
    proj, p = rng.choice(PROJECTS), rng.choice(PEOPLE)
    return (f"Reviewed the {proj} with {p}.",
            [proj, p], ["work"])

def t_run(rng):
    place = rng.choice([p for p in PLACES if "Park" in p or "Embarcadero" in p or "Bay" in p])
    miles = rng.choice([3, 5, 8, 10, 12, 15])
    return (f"{miles}-mile run along {place}; felt {rng.choice(['great','sluggish','strong','tired'])}.",
            [place], ["health", "exercise"])

def t_walk(rng):
    place = rng.choice([p for p in PLACES if "Park" in p or "Tilden" in p or "Bay" in p])
    return (f"Walk in {place}; saw {rng.choice(['a barred owl','deer','a hawk','wildflowers'])}.",
            [place], ["hobby", "outdoor"])

def t_buy(rng):
    item, place = rng.choice(ITEMS), rng.choice([p for p in PLACES if p in ("REI", "Blue Bottle", "Tartine", "City Lights")])
    return (f"Bought {item} at {place}.",
            [item, place], ["errand"])

def t_call(rng):
    p = rng.choice(["Mom", "Dad"])
    topic = rng.choice(["the Thanksgiving travel plans", "the home repair", "the dentist appointment"])
    return (f"Called {p} about {topic}.",
            [p], ["social"])

def t_paper(rng):
    topic = rng.choice(TOPICS)
    return (f"Read a paper on {topic}.",
            [topic], ["work", "reading"])

def t_practice(rng):
    return (f"Played piano for an hour, working through Debussy's Reverie.",
            ["Debussy"], ["hobby"])

def t_bug(rng):
    proj = rng.choice(PROJECTS)
    return (f"Filed a bug for the {proj}; tracked down a flaky test.",
            [proj], ["work"])

def t_design(rng):
    proj, p = rng.choice(PROJECTS), rng.choice(PEOPLE)
    return (f"Pair-programmed with {p} on the {proj}.",
            [proj, p], ["work"])

def t_journal(rng):
    decision = rng.choice(["the v1.5 sequencing", "the mirror policy", "the embedding backend choice"])
    return (f"Coffee at home, journaled about {decision}.",
            [], ["hobby", "writing"])

def t_book(rng):
    place = "City Lights"
    return (f"Picked up a new book at {place} in San Francisco.",
            [place, "San Francisco"], ["hobby"])

def t_appt(rng):
    kind = rng.choice(["dentist", "doctor", "PT"])
    return (f"Booked a {kind} appointment for next month.",
            [], ["errand", "health"])

def t_groceries(rng):
    items = rng.sample(ITEMS, 3)
    return (f"Bought groceries: {', '.join(items)}.",
            items, ["errand"])

TEMPLATES = [t_coffee, t_lunch, t_ping, t_review, t_run, t_walk, t_buy,
             t_call, t_paper, t_practice, t_bug, t_design, t_journal,
             t_book, t_appt, t_groceries]

# ----- Generate memories -----
def synthesize_memories(n=300, days=200, seed=42):
    rng = random.Random(seed)
    now = datetime(2026, 5, 1, tzinfo=timezone.utc)
    rows = []
    for i in range(n):
        tpl = rng.choice(TEMPLATES)
        text, entities, tags = tpl(rng)
        offset_days = rng.uniform(0, days)
        ts = now - timedelta(days=offset_days)
        occurred = ts - timedelta(hours=rng.uniform(0, 6))
        rows.append({
            "id": f"m{i:03d}",
            "text": text,
            "created_at": ts.isoformat().replace("+00:00", "Z"),
            "occurred_at": occurred.isoformat().replace("+00:00", "Z"),
            "source": "synthetic",
            "tags": tags,
            "entities": entities,
        })
    return rows

# ----- Query templates with auto-grading -----
def query_set():
    rng = random.Random(123)
    queries = []

    def add(qid, q, primary_ents, secondary_topics=None):
        queries.append({
            "id": qid,
            "query": q,
            "_primary_entities": primary_ents,
            "_secondary_topics": secondary_topics or [],
        })

    # Entity-driven: who/where
    for p in rng.sample(PEOPLE, 8):
        add(f"q-who-{p.lower()}", f"who did I meet involving {p}", [p])
    for place in rng.sample(PLACES, 6):
        clean = place.replace("the ", "").replace("'", "")
        add(f"q-where-{clean.lower().replace(' ', '-')}",
            f"who or what did I see at {place}", [place])

    # Topic-driven
    for proj in rng.sample(PROJECTS, 8):
        add(f"q-topic-{proj.split()[0].lower()}",
            f"what did I decide about the {proj}", [proj])

    # Domain-driven (broader, more partial matches)
    add("q-runs", "summary of my runs lately", ["the Embarcadero", "Half Moon Bay"], ["exercise", "hobby"])
    add("q-meetings", "this period's meetings with collaborators", PEOPLE[:4])
    add("q-coffee", "my coffee chats", ["Blue Bottle", "Tartine"])
    add("q-errands", "errands I ran", ITEMS[:4])
    add("q-walks-parks", "walks in parks", ["Tilden Park", "Tilden", "Half Moon Bay"])
    add("q-piano", "piano practice", ["Debussy"])
    add("q-papers", "papers I read", TOPICS)
    add("q-mom", "calls with Mom", ["Mom"])
    add("q-design-discussions", "design discussions", PROJECTS, ["work"])

    # Compositional / harder
    add("q-sarah-q3", "what Sarah said about the Q3 release", ["Sarah", "Q3 release"])
    add("q-carlos-pgvector", "Carlos and pgvector", ["Carlos", "pgvector schema"])
    add("q-priya-auth", "Priya on the auth migration", ["Priya", "auth migration"])

    return queries

def grade_query(q, memories):
    primary = set(q.pop("_primary_entities", []))
    secondary = set(q.pop("_secondary_topics", []))
    grades = {}
    for m in memories:
        ents = set(m["entities"])
        tags = set(m["tags"])
        if ents & primary:
            grades[m["id"]] = 2
        elif (ents & secondary) or (tags & secondary):
            grades[m["id"]] = 1
    q["grades"] = grades

def main():
    memories = synthesize_memories(n=300)
    queries = query_set()
    for q in queries:
        grade_query(q, memories)

    mp = os.path.join(OUT_DIR, "memories.jsonl")
    qp = os.path.join(OUT_DIR, "queries.jsonl")
    with open(mp, "w") as f:
        for m in memories: f.write(json.dumps(m) + "\n")
    with open(qp, "w") as f:
        for q in queries: f.write(json.dumps(q) + "\n")

    n_grade2 = sum(sum(1 for v in q["grades"].values() if v == 2) for q in queries)
    n_grade1 = sum(sum(1 for v in q["grades"].values() if v == 1) for q in queries)
    no_relevant = sum(1 for q in queries if not q["grades"])
    print(f"wrote {len(memories)} memories → {mp}")
    print(f"wrote {len(queries)} queries  → {qp}")
    print(f"  grade-2 cells: {n_grade2}")
    print(f"  grade-1 cells: {n_grade1}")
    print(f"  queries with no graded relevant memory: {no_relevant}")

if __name__ == "__main__":
    main()
