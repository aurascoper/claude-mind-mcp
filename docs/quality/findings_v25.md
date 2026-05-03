# v2.5 results: hybrid candidate selection

Same real-trading corpus (424 commits, 31 queries auto-graded). v2.5 changes:
seed pool is now `vector ∪ lexical ∪ entity-mention`, deduped by `memory_id`,
with `seed_source` attribution per hit and per-branch contribution counts.

## Ablation table — v2.5 vs Phase 2 (pre-v2.5)

| ablation                | Phase 2 MRR | v2.5 MRR | Δ MRR  | v2.5 nDCG | v2.5 Success@5 |
|-------------------------|------------:|---------:|-------:|----------:|---------------:|
| 1. local-only           | 0.451       | 0.451    | —      | 0.259     | 0.724          |
| 2. mirror-seeds         | 0.451       | 0.486    | +0.035 | 0.294     | 0.724          |
| 3. mirror + graph       | 0.456       | 0.477    | +0.021 | 0.299     | 0.724          |
| 4. mirror + graph + lex | 0.482       | **0.894**| **+0.412** | **0.808** | **1.000**  |

Best swept weights, v2.5: `α=0.25, β=0.60, γ=0.10, δ=0.05` → **MRR@5 = 0.940, nDCG@5 = 0.761, Success@5 = 1.000**.

## Failure-mode breakdown by stratum

| stratum  | Phase 2: miss | v2.5: miss | Phase 2: rank-issue | v2.5: rank-issue | Phase 2: good | v2.5: good |
|----------|--------------:|-----------:|--------------------:|-----------------:|--------------:|-----------:|
| entity   | **7**         | **0**      | 5                   | 0                | 1             | 11         |
| semantic | 1             | 0          | 4                   | 0                | 3             | 7          |
| temporal | 0             | 0          | 0                   | 0                | 0             | 1 (+ 2 no-truth) |
| mixed    | 0             | 0          | 2                   | 0                | 1             | 1          |

**0 misses anywhere on v2.5.** All 7 entity-name misses from Phase 2 became `good` or `partial-top1`.

## Branch-contribution breakdown

Per-recall log emits `vec=N lex=M ent=K unique=U`. Sample:

```
recall path=mirror profile=minilm-l6-v2 vec=75 lex=18 ent=15 unique=78 ...
recall path=mirror profile=minilm-l6-v2 vec=75 lex=44 ent=0  unique=83 ...
recall path=mirror profile=minilm-l6-v2 vec=75 lex=75 ent=17 unique=140 ...
```

Across 31 queries:
- **vector** branch always saturates at K=75 (the per-branch budget for k=25 with seedOverfetch=3).
- **lexical** branch contributes meaningfully for 28 of 31 queries (range 0–75, median ~18).
- **entity** branch contributes for 14 of 31 queries (range 0–17), gated by NLTagger + acronym fallback finding entities in the query string.
- The dedupe shrinks the pool noticeably when branches overlap (vec=75, lex=75, ent=17 → unique=140, not 167).

## What actually moved the needle

Lexical was the dominant fix: even before the entity branch was repaired (a Core Data programmatic-model relationship-faulting quirk; worked around with a redundant `entityID` attribute on Mention), the harness already showed MRR 0.482 → 0.894. On this commit-log corpus, "TWAP" / "Alpaca" / "OBI" appear lexically in the right commits, so `tsvector + websearch_to_tsquery` (with Swift-side OR-tokenization to dodge the AND-by-default trap) was sufficient.

The entity branch is correct and now contributing — but redundant on this corpus because lexical already finds the same memories. **The entity branch is the more important fix on a corpus where entities aren't lexically distinctive** (e.g., a common first name that matches many memories regardless of topic). Phase 3 against journal/notes data is where I expect the entity-branch contribution to actually beat the lexical branch.

## Decision-rule check (locked in pre-v2.5)

> entity-name misses drop materially on the real-trading corpus
✅ 7 → 0 misses; 0 → 11 `good`.

> semantic queries do not regress badly
✅ semantic stratum went 3 → 7 `good`, 1 → 0 `miss`. No regression.

> mirror fallback behavior stays boring and correct
✅ all 31 queries took the mirror path, no fallbacks fired during the run.

## What did NOT change

- **Default rerank weights** stay at `0.55 / 0.20 / 0.10 / 0.15`. Best swept config keeps shifting per corpus (synthetic α=0.80, Phase 2 α=0.20, v2.5 α=0.25). One default for all corpora is still wrong.
- **Graph weight** still small. v2.5 didn't make graph more useful on this corpus.
- **Local fallback path** unchanged. Continues to fire on missing seeder / no embedding / SQL error.

## Two notes worth flagging

1. **A subtle Core Data bug surfaced.** In our programmatic-model setup, `mention.value(forKey: "entity")` returns nil even when the foreign key is persisted in SQLite — `prefetchKeyPaths` and `returnsObjectsAsFaults = false` don't help. Worked around by adding a redundant `entityID: UUID` attribute on Mention and looking up entities by id directly. Worth filing as a tracked issue if we keep the programmatic model long-term.

2. **Auto-graded with grep heuristics, not hand-labeled.** The numbers will move with hand grading. The qualitative result (architecture, not weights, was the bottleneck) is robust.

## Reproduce

```sh
$PG17_BIN/pg_ctl -D /opt/homebrew/var/postgresql@17 -o "-p 5433" -l /tmp/pg17.log start
swift build
python3 docs/quality/run_quality.py \
    --corpus docs/quality/real-trading \
    --out    docs/quality/real-trading/results-v25-final
```
