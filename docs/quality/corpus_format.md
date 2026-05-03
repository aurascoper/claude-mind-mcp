# Quality corpus format

A single canonical format used by both the synthetic generator (Phase 1) and the user's real export (Phase 2). Two newline-delimited JSON files per dataset, sitting in one directory:

```
docs/quality/<dataset>/
  memories.jsonl
  queries.jsonl
```

## `memories.jsonl`

One memory per line. All fields except `id` and `text` are optional.

```json
{
  "id": "m001",
  "text": "Coffee with Sarah at Blue Bottle in Oakland; we discussed the auth migration.",
  "created_at": "2026-04-12T09:14:00Z",
  "occurred_at": "2026-04-12T08:45:00Z",
  "source": "note",
  "tags": ["work", "coffee"],
  "entities": ["Sarah", "Blue Bottle", "Oakland", "auth migration"]
}
```

`entities` is a hint for graders and the failure-notebook auto-labeler — the runtime NL pipeline still does its own NER. Keep entries in this list aligned with how a human would label the memory ("Blue Bottle" not "Blue Bottle Coffee Co. of Oakland").

## `queries.jsonl`

One query per line. `grades` maps memory id → relevance grade:

- `0` not relevant
- `1` partially useful / adjacent
- `2` clearly relevant

```json
{
  "id": "q01",
  "query": "what did I decide about the pgvector schema?",
  "grades": {"m003": 2, "m017": 1, "m042": 1}
}
```

Memories not listed in `grades` are treated as `0`. Only positive grades need to be enumerated.

## Auto-grading rule (synthetic corpus only)

For Phase 1 the grader runs over the synthetic memories and annotates:

- `2` if the query's primary entity OR primary topic appears in the memory's `entities` list.
- `1` if the query's topic-cluster (a small set of co-occurring topics) overlaps with the memory's `entities`/`tags`.
- `0` otherwise.

The Phase 2 (real-data) pass overrides this — you grade a sample by hand and the harness uses your grades verbatim.

## Why this shape

- **JSONL** keeps the format streamable and concatenation-safe.
- **Sparse `grades`** means a 300-memory corpus with 50 queries doesn't need 15k cells; only the relevant ones get explicit grades.
- **Entities as a hint, not a contract**: the runtime NER may extract a slightly different set, and that's fine — the failure notebook surfaces those mismatches as a labeled axis.
- **No scoring fields here** — the harness writes its own `results.json` per run; the corpus stays a static input.
