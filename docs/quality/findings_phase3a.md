# Phase 3a — prose-shaped, lexically literal (private jobs/writing corpus)

Phase 3a is an intermediate validation pass between commit logs (Phase 2 v2.5) and journal/notes (Phase 3b, queued). The corpus is real prose (74 markdown files from a private writing-and-job-applications directory; 15 voice/style files + 59 application reports) but **structurally similar to commit logs in one important way**: company names appear literally in the report bodies, so lexical match is rich.

## Scaffold

- 74 memories (one per file, head-of-file truncated to ~1800 chars)
- 38 queries stratified across people / topics / temporal / event-place / sentiment / mixed
- Auto-graded via filename slug match (companies) + entity overlap + date window + sentiment heuristics
- Date range: 2026-04-12 → 2026-05-03
- Apple Notes was attempted first (only 4 notes total — too thin); jobs is the fallback per pre-arranged plan

Apple Notes survey output is in `scripts/notes/survey.applescript` for reference; the 4-note count is what triggered the fallback.

## Ablation table

| ablation                | MRR@5 | nDCG@5 | Success@5 | weights (α,β,γ,δ) |
|-------------------------|------:|-------:|----------:|-------------------|
| 1. local-only           | 0.435 | 0.274  | 0.528     | (0.70, 0.30, 0.0, 0.0) |
| 2. mirror-seeds         | 0.506 | 0.345  | 0.611     | (0.70, 0.30, 0.0, 0.0) |
| 3. mirror + graph       | 0.506 | 0.348  | 0.611     | (0.60, 0.20, 0.20, 0.0) |
| 4. mirror + graph + lex | 0.588 | 0.495  | 0.778     | (0.55, 0.20, 0.10, 0.15) |

Best swept: `α=0.75, β=0, γ=0.10, δ=0.15` → MRR 0.607, Success 0.778. Recency weight collapses to 0 — the corpus is too date-clustered (3 weeks total) for recency to discriminate.

## Failure-mode breakdown

| stratum  | n | good | partial-top1 | lexical-hit | miss | no-truth |
|----------|--:|-----:|-------------:|------------:|-----:|---------:|
| people   | 10 | 0    | 0            | 4           | **6**| 0        |
| topic    | 8  | 3    | 3            | 1           | 0    | 1        |
| time     | 6  | 1    | 1            | 3           | 1    | 0        |
| event    | 5  | 1    | 3            | 1           | 0    | 0        |
| feel     | 5  | 1    | 4            | 0           | 0    | 0        |
| mixed    | 4  | 0    | 1            | 1           | 1    | 1        |

## The actual generalization signal Phase 3a surfaced

**The entity branch fired zero times across all 38 queries.** Per-call logs show `ent=0` everywhere, and the cause is upstream: `query_entities=0`. NLTagger + my acronym fallback don't extract "company name a" or "company name b" because those tokens are lowercase. NLTagger only tags `PersonalName`/`PlaceName`/`OrganizationName` for properly-capitalized strings; the acronym regex only fires for ALL-CAPS sequences.

So v2.5's entity branch is **case-sensitive at the query side** — it works well for capitalized acronyms ("TWAP", "OBI", "Sarah") and fails for casual lowercase queries (a lowercase compound noun, "did I see sarah at lunch"). On commit-log data (Phase 2) this was invisible because queries we wrote used proper case. On real journal data (Phase 3b) it will likely be a problem because people write queries casually.

## Compare to Phase 2 v2.5 (commit-log)

| signal | Phase 2 v2.5 | Phase 3a |
|---|---:|---:|
| MRR@5 best swept | 0.940 | 0.607 |
| entity branch contributes | 14/31 queries | **0/38 queries** |
| lexical branch contributes | 28/31 queries | 38/38 queries |
| graph adds | +0.021 MRR | +0.000 MRR |
| recency in best swept | β=0.60 | β=0 |
| people-stratum misses | 0 | **6** |

The 6 people-stratum misses are the smoking gun: those are queries that explicitly named a corpus entity ("&lt;company&gt;", "&lt;company-with-bigram&gt;", etc.), and v2.5's seed-selection didn't surface the right report — because the entity branch never fired.

## What this means for v2.5

The architecture is correct. The implementation has a brittle assumption: **NER on the query expects proper case.** Two non-disruptive fixes worth queuing as v2.6 candidates:

1. **Case-insensitive entity-name matching.** When the query NER returns nothing, fall back to scanning the query against the `entities.canonical_name` set with case-insensitive matching. This is a small SQL change in the entity branch (`lower(canonical_name) = ANY(query_tokens)`) plus a Swift-side query-tokenizer that just emits all 3+ char alphanumeric runs.
2. **Lemmatize/normalize stored entities.** Store both the original case ("Pearl Health") and a lowercased canonical form. The entity branch then queries against the lowercase form using lowercased query tokens. Slightly more storage; cleaner match.

Either fix would have closed the 6 people-stratum misses on this corpus. Neither is needed if queries are always entered with proper case (which is unrealistic).

**Decision for now (per the locked-in v2.5 → Phase 3b sequencing):** don't change defaults or wire v2.6 yet. Phase 3b (real journal/notes) is the corpus that should drive that decision — if it shows the same pattern, v2.6 is justified; if journal queries are naturally proper-case (unlikely but possible), the v2.5 architecture is sufficient as-is.

## Caveats

- **Corpus is not journal-shaped.** Reports use canonical company names literally; almost no first-person reflection or social entities. Sentiment-stratum queries auto-graded loosely. Treat absolute MRR numbers as anchored-to-this-corpus only.
- **Auto-graded with strict heuristics** (filename slug for companies; entity overlap + date window for others). 207 grade-2 cells across 38 queries → ~5 per query on average. Hand grading would shift numbers slightly but not the qualitative finding above.
- **No real "people" entities.** The "people" stratum here is actually company-name queries; real social-entity queries are queued for Phase 3b.

## Reproduce

```sh
python3 scripts/scaffold_from_jobs.py
$PG17_BIN/pg_ctl -D /opt/homebrew/var/postgresql@17 -o "-p 5433" -l /tmp/pg17.log start
python3 docs/quality/run_quality.py \
    --corpus docs/quality/jobs-prose \
    --out    docs/quality/jobs-prose/results
```
