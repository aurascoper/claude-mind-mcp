# Core Data model (programmatic)

The model is built in code by `ManagedObjectModelBuilder.make()` in `Sources/ClaudeMindCore/ManagedObjectModel.swift`. **There is no `.xcdatamodeld` and no Xcode project required** — `swift build` produces the executable directly.

This document is the schema spec the builder implements. Edit both together.

## Storage identity

Each memory persists which embedding produced its vector:

- `embeddingBackend` — e.g., `NLContextualEmbedding`, `NLEmbedding.sentenceEmbedding`
- `embeddingProfile` — e.g., `multilingual.default` (free-form profile id we control)
- `embeddingDim` — runtime-discovered from the embedding API at startup

Recall only computes semantic similarity when the query embedding's dimension matches the stored vector's dimension, so heterogeneous backends coexist safely (older vectors are simply skipped on the semantic axis until re-embedded).

## Entities

### MemoryRecord
- `id` UUID, indexed, required
- `text` String, required
- `createdAt` Date, indexed, required
- `occurredAt` Date, optional, indexed
- `source` String, optional, indexed
- `conversationID` String, optional, indexed
- `language` String, optional
- `sentiment` Double, default `0`
- `embeddingBlob` Binary Data, optional (packed Float32, length = `embeddingDim * 4`)
- `embeddingBackend` String, optional
- `embeddingProfile` String, optional
- `embeddingDim` Int32, default `0`
- `metadataJSON` Binary Data, optional
- `tombstoned` Bool, default `false`

Relationships: `mentions →* MentionRecord`, `tags →* TagRecord`, `provenanceRelations →* RelationRecord`.

### EntityRecord
- `id` UUID, indexed
- `canonicalName` String, indexed
- `type` String, indexed (e.g., `PersonalName`, `PlaceName`, `OrganizationName`)
- `aliasesJSON` Binary Data, optional

Relationships: `mentions →* MentionRecord`, `outgoingRelations →* RelationRecord`, `incomingRelations →* RelationRecord`.

### MentionRecord
- `id` UUID, indexed
- `startOffset` Int64
- `endOffset` Int64

Relationships: `memory →1 MemoryRecord`, `entity →1 EntityRecord`.

### RelationRecord
- `id` UUID, indexed
- `predicate` String, indexed
- `createdAt` Date, indexed

Relationships: `subject →1 EntityRecord`, `object →1 EntityRecord`, `provenanceMemory →1 MemoryRecord`.

### TagRecord
- `id` UUID, indexed
- `name` String, indexed

Relationships: `memories →* MemoryRecord` (many-to-many with `MemoryRecord.tags`).

### OutboxRecord
Always written on every `remember`. Drained by the milestone-2 mirror worker into Postgres+pgvector. Decouples local writes from mirror availability.

- `id` UUID, indexed
- `recordType` String (`memory`, `entity`, `mention`, `relation`, `tag`)
- `recordID` UUID, indexed
- `operation` String (`upsert` / `delete`)
- `payloadJSON` Binary Data, optional
- `createdAt` Date, indexed
- `sentAt` Date, optional
- `attemptCount` Int32, default `0`

## Container

v1 uses plain `NSPersistentContainer` backed by SQLite at `CLAUDE_MIND_STORE_URL` (default `~/Library/Application Support/claude-mind/memory.sqlite`).

`NSPersistentCloudKitContainer` is intentionally **not** used in v1. CloudKit sync requires entitlements and a CloudKit container ID, which a CLI launched directly by Claude Desktop does not have. Migration path: wrap the binary in a signed `.app` with a CloudKit entitlement and swap the container type — the schema is unchanged.

## Why programmatic and not `.xcdatamodeld`

- The repo is an SPM package, not an Xcode project. `.xcdatamodeld` requires an Xcode build phase to compile to `.momd`.
- Programmatic models are diffable in git as Swift source.
- Schema changes can be reviewed in the same pull request as the code that uses them.
