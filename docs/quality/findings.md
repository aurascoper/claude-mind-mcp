# Recall quality — Phase 1 findings (synthetic corpus)

**Corpus:** 300 synthetic memories spanning work / social / errands / health / hobbies, with entity reuse and 200-day temporal spread.
**Queries:** 34 templated queries auto-graded against entity overlap.
**Hardware:** Apple M4, debug build (release crashes on the postgres-nio + Tokenizers interaction).

## Ablation table (default weights)

| ablation                  | MRR@5 | nDCG@5 | Success@5 | weights (α,β,γ,δ) |
|---------------------------|------:|-------:|----------:|-------------------|
| 1. local-only             | 0.581 | 0.352  | 0.727     | (0.70, 0.30, 0.0, 0.0) |
| 2. mirror-seeds           | 0.587 | 0.369  | 0.758     | (0.70, 0.30, 0.0, 0.0) |
| 3. mirror + graph         | 0.669 | 0.440  | 0.727     | (0.60, 0.20, 0.20, 0.0) |
| 4. mirror + graph + lex   | 0.632 | 0.443  | 0.758     | (0.55, 0.20, 0.10, 0.15) |

## Best weights from coarse → fine sweep

```
α (semantic)  0.80
β (recency)   0.05
γ (graph)     0.15
δ (lexical)   0.00
→ MRR@5 = 0.785, nDCG@5 = 0.693, Success@5 = 0.848
```

The +33% MRR jump from default to swept weights suggests the hardcoded defaults (`0.55 / 0.20 / 0.10 / 0.15`) aren't well-tuned for this corpus shape.

## Findings worth flagging

1. **Mirror-seeds ≈ local-only on this corpus.** With identical embeddings on both sides and a small enough corpus that HNSW returns exact NN, the mirror's vector path doesn't add seed-quality. It only earns its keep with graph + (carefully-tuned) lexical.

2. **Graph expansion clearly helps.** Ablation 3 vs 2: MRR 0.587 → 0.669 (+14% relative). The 1-hop entity-neighbor expansion surfaces relevant memories that the seed query missed. This is consistent with the user's earlier instinct that "graph expansion is local and cheap".

3. **Lexical (tsvector) regresses MRR at the default weight.** Ablation 4 vs 3: MRR 0.669 → 0.632. The lexical signal is more noise than signal on entity-name queries, where any memory mentioning the name (regardless of topic) gets scored up. Best swept weight for δ = 0.00. **Recommendation:** keep lexical wired but ship with `δ ≈ 0.0` until real-data evidence justifies it.

4. **Recency weight should be smaller.** Best swept β = 0.05 vs default 0.20. With a uniform 200-day temporal spread, recency is a weak feature — and overweighting it actively pushes irrelevant-but-recent memories into the top-K.

5. **Entity-name queries are the dominant failure mode.** Of 34 queries, 8 are full misses (`miss`) and 7 are top-K presences ranked outside top-1 (`rank-issue`). All of the misses are entity-name queries (`q-who-carlos`, `q-who-yuki`, `q-who-ravi`, etc.) where the embedding alone doesn't isolate the named-entity dimension well. **This is a real architectural insight:** pure vector seed selection misses entity-name queries. Adding a lexical/named-entity branch to candidate *selection* (not just rerank) would likely fix this.

6. **No-truth degenerate case spotted.** `q-where-oakland` has zero graded memories — the auto-grader didn't find any memory whose `entities` listed "Oakland" exactly (template variations like "in Oakland" sometimes don't carry Oakland into the entities array). Phase-2 real data won't have this issue but the grader needs hardening either way.

## Caveats

- **Synthetic-corpus circularity:** the auto-grader uses entity overlap; the graph expansion uses entity edges. Graph appearing helpful is partly tautological. The Phase 2 real-data run is what tells us whether it generalizes.
- **Graded-relevance density:** the synthetic corpus has 537 grade-2 cells across 34 queries — much higher than real memory data would have. Real data will have fewer relevants per query and the metrics will look harsher.
- **MiniLM-L6-v2 on entity names:** the named-entity weakness shown above is a known property of small sentence-encoders. Switching to a model with explicit entity awareness or augmenting candidate selection with lexical hits would address it.

## What I'd change in v2.4 based on this

1. **Update default rerank weights** in `MemoryHandlers.RecallWeights()` to `α=0.8, β=0.05, γ=0.15, δ=0.0` (the swept best). Keep the env-var override `CLAUDE_MIND_W_*` so users can tune for their corpus.
2. **Hybrid candidate selection.** When a query's top-K from vector seed has low avg semantic_score, fall back to (or union with) a tsvector / entity-name seed query. Not in v2.4 — flag it as v2.5.
3. **Recency half-life knob.** With β=0.05 dominant, the `recencyHalfLifeDays=30` default barely matters. Defer.

## Reproduce

```sh
# 1. start a postgres@17 instance with pgvector on port 5433, db=claude_mind_quality
$PG17_BIN/pg_ctl -D $PG17_DATA -o "-p 5433" -l /tmp/pg17.log start
createdb -p 5433 claude_mind_quality
psql -p 5433 -d claude_mind_quality -c "CREATE EXTENSION vector;"

# 2. generate the synthetic corpus (idempotent, seeded)
python3 docs/quality/synthesize.py

# 3. run the harness
swift build  # debug build is required while the postgres-nio + Tokenizers crash is open
python3 docs/quality/run_quality.py
# → docs/quality/results/results.json
# → docs/quality/results/failure_notebook.md
```

To swap in your own data (Phase 2):
- replace `docs/quality/synthetic/memories.jsonl` and `queries.jsonl` (same format, see `docs/quality/corpus_format.md`)
- run `python3 docs/quality/run_quality.py --corpus <your-dir> --out <your-out>`
