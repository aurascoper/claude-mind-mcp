# Recall quality — Phase 2 (real corpus: trading-engine commit log)

**Corpus:** 424 commits from a private trading-engine repo, 2026-04-09 → 2026-04-29 (20-day span, very dense). Auto-graded with grep-based per-query rules guided by the user's priority hints.
**Queries:** 31 hand-curated (13 entity / 11 semantic / 3 temporal / 4 mixed). Two temporal queries marked no-truth (`{0}` hint).
**Hardware:** Apple M4, debug build.

## Ablation table (default weights)

| ablation                  | MRR@5 | nDCG@5 | Success@5 |
|---------------------------|------:|-------:|----------:|
| 1. local-only             | 0.451 | 0.259  | 0.724     |
| 2. mirror-seeds           | 0.451 | 0.259  | 0.724     |
| 3. mirror + graph         | 0.456 | 0.262  | 0.724     |
| 4. mirror + graph + lex   | 0.482 | 0.284  | 0.724     |

## Best swept weights

```
α (semantic)  0.20
β (recency)   0.50
γ (graph)     0.15
δ (lexical)   0.15
→ MRR@5 = 0.533, nDCG@5 = 0.337, Success@5 = 0.724
```

## Failure-mode breakdown by stratum

| stratum  | queries | good | partial-top1 | rank-issue | miss | no-truth |
|----------|--------:|-----:|-------------:|-----------:|-----:|---------:|
| entity   | 13      | 1    | 0            | 5          | **7**| 0        |
| semantic | 11      | 3    | 3            | 4          | 1    | 0        |
| temporal | 3       | 0    | 1            | 0          | 0    | 2        |
| mixed    | 4       | 1    | 1            | 2          | 0    | 0        |

**Entity-name failures are dominant.** 7 of 13 entity queries are full misses (top-5 contains zero relevant memories) — and the misses include real, multi-commit threads:

| query        | grade-2 cells in corpus | top-5 hits |
|--------------|------------------------:|-----------:|
| q-ent-03 Alpaca | 12 | 0 |
| q-ent-06 HIP    |  8 | 0 |
| q-ent-07 HIP-3  |  8 | 0 |
| q-ent-09 OFI    |  6 | 0 |
| q-ent-11 PnL    |  8 | 0 |
| q-ent-13 AR(1)  |  5 | 0 |
| q-ent-14 TWAP   |  6 | 0 |

The system has 5–12 directly-relevant memories for each of these queries and surfaces zero of them in top-5. That is not a tuning problem.

## What Phase 2 confirmed vs. Phase 1

| Phase 1 claim                                | Phase 2 says |
|----------------------------------------------|--------------|
| "Graph expansion clearly helps (+15% MRR)"   | **Recanted.** Graph adds +1% MRR on real data. |
| "Lexical regresses MRR at default weight"    | **Recanted.** Lexical adds +6% on real data. |
| "Best β (recency) ≈ 0.05"                    | **Recanted.** Best β = 0.50. |
| "Best α (semantic) ≈ 0.80"                   | **Recanted.** Best α = 0.20. |
| "Entity-name queries are the dominant failure mode" | **Confirmed and stronger.** 7/13 misses on real data; the misses involve real entities with 5–12 relevant memories each. |

The synthetic corpus's circularity (graph expansion exploiting the same entity overlap the grader used) inflated graph's apparent value and made lexical look bad. Real data inverted both.

The one finding that survived contact with reality is the architectural one: **the seed-selection stage doesn't surface named entities, regardless of how the rerank weights are set**. No weight combination in our 125+ coarse + ~250 fine configs gets entity-name MRR meaningfully above the current default — because the relevant memories are not in the candidate set to begin with.

## Decision

Per the user's pre-stated rule:

> If Phase 2 still shows entity-name misses as the main failure mode, go straight to v2.5 hybrid candidate selection.

→ **v2.5 hybrid candidate selection is justified.** Specifically:

1. The mirror's seed query should `UNION` (or otherwise blend) two candidate sources:
   - top-K vector cosine over `memory_embeddings_<profile>` (current).
   - top-K lexical hits from `memories.search_document` via `websearch_to_tsquery`.
2. Optionally a third source: an entity-mention join (`mentions.entity_id` matching the query's NER-extracted entities).
3. Final candidate set is deduplicated by `memory_id`. Rerank as before.

This addresses the failure mode directly: entity-name memories will now appear in the candidate set via the lexical or NER branch even when the embedding cosine ranks them low, and the rerank gets the chance to promote them.

## Decision NOT made

- **Don't change default rerank weights yet.** The optimal weights swing wildly between corpora (synthetic α=0.80 vs real α=0.20). A single fixed default would be wrong for at least one of those workloads. Ship the `CLAUDE_MIND_W_*` env-var override and document tuning. Defer the default-update conversation until v2.5 lands and we re-bench.
- **Don't fix the harness's entity-name grader heuristics.** The auto-grading worked well enough to surface the real signal. When you do Phase 3 with truly hand-graded data, the metric numbers may shift but the qualitative finding (architecture, not weights) is robust.

## Caveats

- Auto-graded against a heuristic, not hand-labeled. The misses are real — those memories really do exist with the right entities — so the signal stands. Numbers may shift slightly with hand grading.
- 20-day corpus span is short; temporal queries had limited stratification.
- Commit-log corpus is technical / terse, not journal-flavored. Phase 3 (real journal/notes) might surface additional failure modes (e.g., "what did <person> say" queries against social entries).
