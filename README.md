# claude-mind-mcp

Local-first Apple-native MCP server for time-aware persistent memory, with an optional Postgres+pgvector mirror.

[![swift](https://img.shields.io/badge/swift-6.1-orange)](https://swift.org)
[![macOS](https://img.shields.io/badge/macOS-14%2B-lightgrey)](https://www.apple.com/macos/)
[![license](https://img.shields.io/badge/license-MIT-blue)](LICENSE)

License: **MIT** (see [`LICENSE`](LICENSE)). Third-party licenses for the bundled Swift packages and the embedding model are in [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md).

---

## ClaudeMindMCP starter

A local-first Swift MCP server for time-aware persistent memory on Apple platforms.

This starter is designed around:

- **official MCP Swift SDK** for local `stdio` and remote HTTP transports
- **Core Data** as the canonical on-device store
- **NSPersistentCloudKitContainer** for optional iCloud-backed sync across the same user's Apple devices
- **NaturalLanguage** (`NLTagger`, `NLEmbedding` / `NLContextualEmbedding`) and **Foundation** (`NSDataDetector`) for on-device enrichment
- **optional Postgres + pgvector mirror** for filtered semantic retrieval, SQL joins, and larger corpora

## Recommended shape

Use a **two-tier design** rather than choosing only one store:

1. **Canonical store**: Core Data on device
2. **Mirror store**: Postgres/pgvector behind a feature flag or background sync worker

That gets you:

- offline-first writes
- Apple-native persistence and sync
- fast metadata filters and joins once the corpus grows
- a clean failure mode when Postgres is unavailable

## Transport split

- **Local harness / desktop client**: `StdioTransport`
- **Cloud-hosted agent / shared connector**: Streamable HTTP transport

## Tool surface

### Time
- `now`
- `parse_date`
- `relative`
- `calendar_context`

### Memory
- `remember`
- `recall`
- `recall_around`
- `relate`
- `traverse`
- `list_recent`
- `forget`

## Retrieval policy

1. Parse the query for dates, entities, tags, and source hints.
2. Apply **structured filters first**.
3. Retrieve semantic candidates from the vector index.
4. Expand 1-2 hops through mentions / relations.
5. Re-rank by semantic similarity + recency + graph proximity + explicit filter matches.
6. Return provenance and timestamps with every hit.

## Canonical Core Data entities

- `MemoryRecord`
  - `id: UUID`
  - `text: String`
  - `createdAt: Date`
  - `occurredAt: Date?`
  - `source: String?`
  - `conversationID: String?`
  - `language: String?`
  - `sentiment: Double`
  - `embeddingBlob: Data?`
  - `metadataJSON: Data?`
  - `tombstoned: Bool`

- `EntityRecord`
  - `id: UUID`
  - `canonicalName: String`
  - `type: String`
  - `aliasesJSON: Data?`

- `MentionRecord`
  - `id: UUID`
  - `memoryID: UUID`
  - `entityID: UUID`
  - `startOffset: Int64`
  - `endOffset: Int64`

- `RelationRecord`
  - `id: UUID`
  - `subjectEntityID: UUID`
  - `predicate: String`
  - `objectEntityID: UUID`
  - `provenanceMemoryID: UUID`
  - `createdAt: Date`

- `TagRecord`
  - `id: UUID`
  - `name: String`

- `MemoryTagRecord`
  - `memoryID: UUID`
  - `tagID: UUID`

## Postgres mirror

Mirror only the pieces that benefit retrieval:

- memory text
- timestamps
- source / conversation / tags
- entity ids
- embedding vector
- `tsvector`

Keep Core Data as the authoritative store and mirror via an append-only outbox table or durable sync queue. Never make Postgres the only place a memory exists unless you intentionally switch the architecture later.

## Why this staged design is the safest fit

- It preserves the **single-binary local experience** from the original time/date server.
- It gives you Apple-native persistence and optional iCloud sync.
- It avoids turning a simple MCP server into a hard dependency on a database daemon.
- It still leaves room for SQL joins and filtered ANN search once recall quality or corpus size makes them worthwhile.

## Build & smoke-test

```sh
swift build
.build/debug/claude-mind-mcp   # speaks MCP over stdio
```

Run a hand-rolled stdio handshake:

```sh
TMP=$(mktemp -d)/memory.sqlite
{ printf '%s\n' \
    '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"smoke","version":"0.0.1"}}}' \
    '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
    '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
    '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"remember","arguments":{"text":"Coffee with Sarah in Oakland.","tags":["coffee"]}}}' \
    '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"recall","arguments":{"query":"who did I see","k":3}}}'
  sleep 5; } | env CLAUDE_MIND_STORE_URL="$TMP" .build/debug/claude-mind-mcp
```

## Status (milestone 2.5, hybrid candidate selection — accepted on real data)

`recall` no longer relies on a single seed branch. The mirror's seed pool is the **union of three branches**, deduped by `memory_id`:

1. **vector** — cosine over the per-profile pgvector table.
2. **lexical** — `tsvector @@ websearch_to_tsquery` against `memories.search_document`. Query text is OR-tokenized in Swift before binding so multi-word queries don't collapse to AND-joined zero-result tsqueries.
3. **entity** — join through `mentions` and `entities` for any named-entity strings the query's NER pass extracts. NER includes an acronym fallback so technical tokens like `TWAP`, `OBI`, `HIP-3` are picked up; not just `NLTagger`'s `PersonalName`/`PlaceName`/`OrganizationName`.

Each hit carries `seed_source` (`["vector"]`, `["lexical","entity"]`, etc.) and the per-call log emits `vec=N lex=M ent=K unique=U` for branch attribution.

Per-branch budgets via env vars:

| env var | default | meaning |
|---|---:|---|
| `CLAUDE_MIND_KVEC` | `max(25, k*seedOverfetch)` | top-K from vector branch |
| `CLAUDE_MIND_KLEX` | same | top-K from lexical branch |
| `CLAUDE_MIND_KENT` | same | top-K from entity branch |
| `CLAUDE_MIND_QUERY_ENT_FALLBACK` | `false` | **v2.6 experimental.** When true and NER on the query returns no entities, generate lowercase name-like candidates (unigrams + adjacent bigrams, stopwords filtered, capped at 12) and use those for the entity branch. Off by default; enable for journal/notes corpora where queries are casual lowercase. Recall log shows `ner_entities=N fallback_entities=M fallback_tokens=...` so you can see when and what fired. |

### Phase 2 acceptance (real corpus = private trading-engine commit log, 424 commits, 31 hand-curated queries)

| ablation                | Phase 2 (pre-v2.5) MRR | v2.5 MRR | Δ |
|-------------------------|---------------------:|---------:|---:|
| local-only              | 0.451                | 0.451    | — |
| mirror-seeds            | 0.451                | 0.486    | +0.035 |
| mirror + graph          | 0.456                | 0.477    | +0.021 |
| **mirror + graph + lex**| 0.482                | **0.894** | **+0.412** |

Best swept config on v2.5: `α=0.25, β=0.60, γ=0.10, δ=0.05` → MRR 0.940 / nDCG 0.761 / Success@5 1.000.

**Failure modes by stratum (v2.5):**

| stratum  | n | good | partial-top1 | rank-issue | miss | no-truth |
|----------|--:|-----:|-------------:|-----------:|-----:|---------:|
| entity   | 13 | 11   | 1            | 0          | **0**| 0        |
| semantic | 11 | 7    | 2            | 0          | 0    | 0        |
| temporal | 3  | 0    | 1            | 0          | 0    | 2        |
| mixed    | 4  | 1    | 1            | 0          | 0    | 0        |

Zero misses — was 7 entity-name misses in Phase 2 pre-v2.5.

### Calibration that did NOT change

- Default rerank weights stay at `0.55 / 0.20 / 0.10 / 0.15`. Best swept α swings per corpus (synthetic 0.80, Phase 2 commit-log 0.20, v2.5 0.25); env-var override (`CLAUDE_MIND_W_*`) is the right answer until we have a third real corpus.
- Graph weight stays small. Graph contribution is +0.021 MRR on this corpus. Probably more useful on entity-rich (journal/notes) data.
- Local fallback path unchanged.

### Caveat: lexical did most of the work on this corpus

Commits use entity strings literally — `TWAP` appears in TWAP commits — so the lexical branch alone surfaces the right memories. The entity branch is correct and contributing on 14/31 queries but largely redundant with lexical here. **Phase 3 against journal/notes data** is where the entity branch should *uniquely* matter (common names matching many memories regardless of topic). See `docs/quality/findings_v25.md`.

### Known: Core Data programmatic-model relationship-faulting bug

`mention.value(forKey: "entity")` returns nil for persisted FKs in our programmatic model, even with `returnsObjectsAsFaults = false` and `relationshipKeyPathsForPrefetching = ["entity"]`. Worked around by adding a redundant `entityID: UUID` attribute on `MentionRecord` and looking up entities by id directly. Standalone repro (50 lines) at `docs/coredata-bug-repro/`. Regression test at `Sources/ClaudeMindRegressionTest/`; run with `swift run claude-mind-regression`.

## Status (milestone 2.3, hybrid recall through Postgres mirror)

When the mirror is enabled and the active enricher's profile + dimension match the mirrored profile, `recall` runs through Postgres:

1. Embed the query with the active enricher.
2. `RecallService` queries the per-profile pgvector table:  
   `ORDER BY embedding <=> $1::vector` for cosine, plus `ts_rank_cd(search_document, websearch_to_tsquery('english', $2))` for lexical, with all structured filters in the `WHERE` clause.
3. Top `k * seedOverfetch` candidate ids come back from PG with `(semantic_score, lexical_score)`.
4. Core Data does graph expansion: 1-hop entity neighbors via `MemoryStore.expandGraph(seedIDs:filters:)`.
5. Final rerank: `α·cosine + β·recency + γ·graph + δ·lexical` (defaults `0.55/0.20/0.10/0.15`).
6. Top `k` returned with `path: "mirror"`, `candidate_count`, `expanded_count`, per-hit `is_seed`, `shared_entity_count`.

Fallback ladder is strict and boring:
- mirror unavailable / SQL error / profile mismatch / no query embedding → log reason, return local cosine result with `path: "local"` and `fallback_reason`.
- mirror never blocks the tool; local path still works without Postgres.

Logs always emit one line per recall:
- `recall path=mirror profile=<id> candidates=N expanded=M returned=K`
- `recall path=local profile=<id> returned=K reason=<fallback_reason>`

### Parity check on a fixed corpus

`docs/acceptance/test_v23_recall_parity.py` writes the bench corpus (30 sentences) into a fresh store with the mirror enabled, drains, then runs 8 queries through (a) the mirror path and (b) the local path on the same store with mirror disabled.

```
[summary] mean_jaccard=1.000  threshold=0.60  result=pass
```

All 8 queries agreed on top-5 IDs and exact rank order. Expected on a small corpus where the same embeddings live in both stores; the harness exists to catch divergence as the corpus and rerank weights evolve.

## Status (milestone 2.2, runtime-verified against pgvector — Postgres mirror)

### Acceptance run (Apple M4, Postgres 17.9, pgvector 0.8.2, debug build)

```
PG: brew install postgresql@17 pgvector  (separate instance on port 5433)
psql -p 5433 -c "CREATE DATABASE claude_mind_test"
psql -p 5433 -d claude_mind_test -c "CREATE EXTENSION vector"

env CLAUDE_MIND_ENABLE_PGVECTOR_MIRROR=true \
    CLAUDE_MIND_PG_DSN="postgresql://you@localhost:5433/claude_mind_test?sslmode=disable" \
    .build/debug/claude-mind-mcp
```

| acceptance check | result | notes |
|---|---|---|
| 1. mirror enabled doesn't break stdio/MCP | ✅ | `now` / `remember` / `recall` round-trip, ServiceGroup tears down cleanly on EOF |
| 2. schema creation idempotent | ✅ | 8 tables: `memories`, `embedding_profiles`, `entities`, `mentions`, `relations`, `tags`, `memory_tags`, `memory_embeddings_minilm_l6_v2_3786b7`. Re-runs are no-ops. |
| 3a. one `remember` lands a row in `memories` | ✅ | id, text, language all match the local row |
| 3b. ... registers profile in `embedding_profiles` | ✅ | `(minilm-l6-v2, CoreML(all), 384, 256)` |
| 3c. ... lands an embedding row in the active profile table | ✅ | `vector_dims(embedding) = 384` in `memory_embeddings_minilm_l6_v2_3786b7` |
| 3d. ... outbox row marked sent | ✅ | Core Data shows pending=0, sent=1 |
| 4a. local writes during DB outage don't block | ✅ | `remember` returned with `id` while PG was stopped |
| 4b. drainer catches up after PG restart | ✅ | second-run drainer `published 1 rows`, row visible in PG |
| 4c. `attempt_count` / `last_error` increment on live publish failure | ✅ | `docs/acceptance/test_4c_live_failure.py`: transient PG outage publishes transparently after reconnect (postgres-nio handles it, no spurious failure logs); a real SQL-level failure (DROP memories table mid-flight) increments `attemptCount=2`, sets `lastError`, sets `lastAttemptAt`. |
| 5. heterogeneous-profile rows skip embedding, still mirror metadata | ✅ | `docs/acceptance/test_5_heterogeneous_profile.py`: a memory stamped under profile A (CoreML/minilm-l6-v2/384) and drained while profile B is active (NL/nl-512/512) lands in `memories` but is skipped on the embedding axis; B's own memory lands in B's profile-scoped table normally. |

### Build mode policy

- **Release build, mirror disabled** (default): use `.build/release/claude-mind-mcp`. Core Data path only, no Postgres dependency exercised at runtime.
- **Mirror enabled** (`CLAUDE_MIND_ENABLE_PGVECTOR_MIRROR=true`): **use the debug build** (`.build/debug/claude-mind-mcp`). Mirror latency is dominated by Postgres I/O so the optimization gap is immaterial for that path.

The release binary emits a `warning`-level startup log when mirror is enabled, pointing at this section.

### Why the release+mirror combination crashes

A Swift 6.3.1 release-mode codegen issue triggers `freed pointer was not the last allocation` on the second consecutive `PostgresClient.query(...)` *only when* `postgres-nio` and `Tokenizers` (huggingface/swift-transformers) are linked into the same executable. Either dependency on its own works fine in release.

Reduced to a 30-line standalone repro at [`docs/swift-bug-repro/`](docs/swift-bug-repro/) — that project pins `postgres-nio` + `swift-transformers` and shows the crash with two `SELECT N` queries. Removing `import Tokenizers` from `main.swift` (without removing the SPM dep) is enough to make release work.

The diagnosis is "Swift release-mode codegen interaction between two dependencies", not a defect in either dependency or in our code. Possibly related (none exact): [swiftlang/swift#84793](https://github.com/swiftlang/swift/issues/84793), [#81771](https://github.com/swiftlang/swift/issues/81771), [#86204](https://github.com/swiftlang/swift/issues/86204). The repro project's `README.md` is ready to file as an upstream issue.

## Status (milestone 2.2, code-complete — Postgres mirror)

- New `ClaudeMindMirror` library target with `postgres-nio`. `MirrorWorker` actor connects to PG, runs `SchemaGenerator.canonicalStatements` + `SchemaGenerator.profileStatements(descriptor)` on first start, then loops at 500 ms polling the Core Data outbox in batches of 100.
- Per-row failure isolation: successful rows are marked `sent_at`; failed rows record `last_error`, bump `attempt_count`, set `last_attempt_at`. Mirror loop applies exponential backoff (1 s → 30 s) on consecutive batch failures; remember writes are never blocked.
- `outboxStats()` reports pending count, oldest pending timestamp, total attempts; the worker logs threshold warnings (`pending >= 1000` or oldest > 1 h). No silent truncation — backlog grows unbounded by design and is loudly observable.
- Heterogeneous-vector safety: per-row publish skips the embedding upsert if the stored `embeddingProfile`/`embeddingDim` doesn't match the active descriptor. Rows still mirror to `memories`, `tags`, `memory_tags`; the embedding axis stays unmirrored until that profile activates and registers its own table.
- Profile identity is single-source-of-truth (`SchemaGenerator.descriptor(enricher:modelName:seqLen:)` — id, backend, dim all come from the running enricher) and `safeID` is collision-defended (sanitized base + 6-hex-char SHA-256 of `(id, backend, dim)`).
- Manifest sha256 verification before model load. Mismatch fails closed → fall back to NL.
- ServiceGroup is back: when `CLAUDE_MIND_ENABLE_PGVECTOR_MIRROR=true` and `CLAUDE_MIND_PG_DSN` is set, MCP server and mirror run as sibling services under one ServiceGroup with `successTerminationBehavior: .gracefullyShutdownGroup` so EOF on stdio cleanly tears both down.

### Running the mirror

```sh
# 1. Postgres with pgvector (this Mac happens to have postgresql@14 + pgvector
#    targeting postgres@17; if you're on @14 you'll need to compile pgvector
#    against @14 or switch instances). pgvector docs: https://github.com/pgvector/pgvector
psql -d mydb -c "CREATE EXTENSION vector;"

# 2. Run the server with mirror enabled.
env \
  CLAUDE_MIND_ENABLE_PGVECTOR_MIRROR=true \
  CLAUDE_MIND_PG_DSN="postgresql://user@localhost:5432/mydb?sslmode=disable" \
  .build/release/claude-mind-mcp
```

The mirror will bootstrap the canonical schema + `memory_embeddings_<safeID>` table, register the active profile in `embedding_profiles`, and start draining the outbox. Mirror health appears in the server's stderr log.

### v2.2 known limits (deferred to v2.3+)

- TLS Postgres connections (`sslmode=require`) error out for now — the v2.2 path is `sslmode=disable`. Adding NIOSSL config is a small follow-up.
- Hybrid recall through Postgres (`SchemaGenerator.recallQuery`) is wired and ready in SQL but the recall handler still queries Core Data only. v2.3 makes recall route through the mirror when it's enabled and the active profile matches.
- End-to-end mirror runtime hasn't been smoke-tested in this session: the on-machine postgresql@14 didn't have pgvector available (Homebrew's pgvector targets postgres@17). The build, schema, and worker code are complete; the missing step is `psql -c 'CREATE EXTENSION vector'` on a compatible server.

## Status (milestone 2.1, complete — pre-mirror)

- **Default backend is now CoreML(all) + MiniLM-L6-v2.** Settings env defaults to `embedding_backend=coreml` and `embedding_profile=minilm-l6-v2`. NLContextualEmbedding remains as a fallback (set `CLAUDE_MIND_EMBEDDING_BACKEND=nl`, or it kicks in automatically if the sidecar model isn't installed).
- **Sidecar model packaging.** Models live at `~/Library/Application Support/claude-mind/models/<name>/` with `model.mlpackage/`, `tokenizer/`, and `manifest.json` (name, version, backend, profile, dim, seq_len, sha256s). `ModelLocator` searches `CLAUDE_MIND_MODELS_DIR` → app-support → `docs/bench/models` (dev fallback). Install via `scripts/install_model.sh`.
- **Profile-scoped pgvector schema generator** (`SchemaGenerator`) emits a canonical schema (no embedding column on `memories`) plus per-profile `memory_embeddings_<profile>` tables with `vector(<dim>)`. Different backends/dimensions coexist without forcing a single column type. Active profiles registered in `embedding_profiles`.
- **Hygiene.** `.gitignore` excludes `.mlpackage` / tokenizer / `.sqlite` / bench JSON. `.gitattributes` is preset for Git LFS if you opt in. The .mlpackage is ~88 MB — distribute via release asset or LFS, not normal blob.

## Status (milestone 1.5, complete)

- Eager `NLContextualEmbedding.requestAssets()` warm-up; logs first-load vs cached separately. On this Mac: first-load asset download ≈ 17.7s, subsequent loads ≈ 100ms.
- `recall_around` lands on memories within ±window of an anchor (memory id or ISO date), ordered by absolute time delta.
- Single shared `NSManagedObjectContext` per store — read and write operations serialize on its queue. Note: rapid back-to-back writes-then-reads from independent MCP handlers can still race if the read enters the perform queue before the writes finish their pre-NLP work; in real Claude Desktop usage this never manifests because the client awaits each tool result.
- `NSEntityDescription.indexes` replaces deprecated `isIndexed`; single-attribute fetch indexes on hot paths only — compound deferred until profiling justifies it.
- New `claude-mind-bench` executable target measures cold init, cold first embed, warm embed p50/p95/p99/stdev, full-path remember p50/p95/p99/stdev, serial vs limited-concurrency. `CoreMLEnricher` lands as a parallel backend with explicit `MLComputeUnits` (cpu / cpu+ane / all); model is BYO (see `docs/coreml-embedding-models.md`).

### Bench numbers on this machine (Apple M4)

| backend                 | embed p50 (ms) | remember p50 (ms) | dim |
|-------------------------|---------------:|------------------:|----:|
| NLContextualEmbedding   |          14.30 |             18.91 | 512 |
| CoreML(cpu)             |           6.07 |             10.95 | 384 |
| CoreML(cpu+ane)         |           3.03 |              8.60 | 384 |
| **CoreML(all)**         |       **2.95** |          **8.04** | 384 |

Full matrix and findings in [docs/bench/results.md](docs/bench/results.md). MiniLM-L6-v2 on Core ML(all) is **~5× faster** than NLContextualEmbedding for the embed path and ~2.3× faster for the full remember path. ANE startup costs ~1.6 s but amortizes immediately. Concurrency doesn't help any backend — drive embed serially or batch.

## Status (milestone 1, complete)

- Programmatic `NSManagedObjectModel` (no `.xcdatamodeld`, no Xcode project required) — `Sources/ClaudeMindCore/ManagedObjectModel.swift`.
- Plain `NSPersistentContainer` at `CLAUDE_MIND_STORE_URL` (default `~/Library/Application Support/claude-mind/memory.sqlite`).
- `AppleNLPEnricher` (actor; serialized to avoid NLTagger/NLEmbedding thread-safety issues): `NLContextualEmbedding` preferred, `NLEmbedding.sentenceEmbedding` fallback, dimension runtime-discovered, NER + sentiment + language detection, `NSDataDetector` for explicit dates.
- Tools live: `now`, `parse_date`, `remember`, `recall`, `list_recent`, `forget`. `relate`, `traverse`, `recall_around` return planned-for-v2 errors.
- Outbox row written on every `remember` so the milestone-2 mirror can backfill without changing the write path.

### Known caveats
- `NLContextualEmbedding` requires an asset bundle that may not be local on first run; we currently fall back to `NLEmbedding.sentenceEmbedding`. Eager asset download via `requestEmbeddingAssets()` is a small follow-up — flagged but not done in v1 to avoid surprising network calls during startup.
- Recall does an in-process cosine scan over all non-tombstoned matching memories. Adequate for ≤ ~50k memories; pgvector mirror is the v2 fix.
- Programmatic model uses the deprecated `isIndexed` shortcut (still functional). Migration to `NSEntityDescription.indexes` is cosmetic.

## Milestone 2

Knowledge structure + scale:
- `relate`, `traverse`, `recall_around`
- Postgres mirror target (`ClaudeMindMirror`) draining the Core Data outbox
- `pgvector` ANN + `tsvector` lexical, hybrid recall path
- Remote Streamable HTTP transport with origin validation and auth (Anthropic's cloud connects from their network, not the laptop)
- Optional: wrap in `.app` to enable `NSPersistentCloudKitContainer` for cross-device sync
