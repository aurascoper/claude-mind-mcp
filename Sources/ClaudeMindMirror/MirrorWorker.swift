import Foundation
import CryptoKit
import PostgresNIO
import Logging
import ServiceLifecycle
import ClaudeMindCore

public actor MirrorWorker {
    private let config: MirrorConfig
    private let store: MemoryStore
    private let descriptor: SchemaGenerator.ProfileDescriptor
    private let logger: Logger

    public init(
        config: MirrorConfig,
        store: MemoryStore,
        descriptor: SchemaGenerator.ProfileDescriptor,
        logger: Logger
    ) {
        self.config = config
        self.store = store
        self.descriptor = descriptor
        self.logger = logger
    }

    /// Long-running mirror loop. Hands control to PostgresClient.run() in one
    /// child task and the polling drainer in another; cancellation of either
    /// shuts the worker down.
    public func run() async throws {
        let pgConfig = try config.postgresClientConfig()
        let client = PostgresClient(configuration: pgConfig, backgroundLogger: logger)

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { await client.run() }
            group.addTask { try await self.drainLoop(client: client) }

            // First failure (or graceful shutdown) propagates and cancels siblings.
            do {
                try await group.next()
            } catch {
                logger.error("mirror: terminating due to error: \(error)")
            }
            group.cancelAll()
        }
    }

    private func drainLoop(client: PostgresClient) async throws {
        try await ensureSchema(client: client)
        var backoff = config.backoffMin
        var consecutiveFailures = 0
        var ticks = 0

        while !Task.isCancelled {
            do {
                let drained = try await drainOnce(client: client)
                consecutiveFailures = 0
                backoff = config.backoffMin
                ticks &+= 1

                // Periodic outbox health check (every ~10 ticks). Threshold-only logging.
                if ticks % 10 == 0 {
                    if let stats = try? await store.outboxStats() {
                        let oldestAgeSec = stats.oldestCreatedAt.map { Date().timeIntervalSince($0) } ?? 0
                        let warn = stats.pending >= config.warnAtPending || oldestAgeSec >= config.warnAtOldestSeconds
                        if warn {
                            logger.warning("mirror: outbox backlog pending=\(stats.pending) oldest_age_s=\(Int(oldestAgeSec)) total_attempts=\(stats.totalAttempts) last_error=\(stats.oldestLastError ?? "-")")
                        } else {
                            logger.debug("mirror: outbox ok pending=\(stats.pending)")
                        }
                    }
                }

                // If nothing to do, sleep the configured poll interval. If we
                // drained a full batch, immediately try again to clear backlog.
                if drained < config.batchSize {
                    try await Task.sleep(for: config.pollInterval)
                }
            } catch is CancellationError {
                break
            } catch {
                consecutiveFailures += 1
                logger.warning("mirror: drain failure #\(consecutiveFailures): \(error)")
                try? await Task.sleep(for: backoff)
                backoff = min(config.backoffMax, backoff + backoff) // simple doubling
            }
        }
    }

    /// One drain pass. Returns the number of rows successfully published.
    private func drainOnce(client: PostgresClient) async throws -> Int {
        let batch = try await store.nextOutboxBatch(limit: config.batchSize)
        if batch.isEmpty { return 0 }

        var published: [UUID] = []
        var failedIDs: [UUID] = []
        var firstError: String?

        for item in batch {
            do {
                switch (item.recordType, item.operation) {
                case ("memory", "upsert"):
                    try await publishMemory(client: client, memoryID: item.recordID)
                case ("memory", "delete"):
                    try await publishMemoryDelete(client: client, memoryID: item.recordID)
                default:
                    // Other record types (entity/mention/relation) are derivable from memory rows
                    // via Core Data, so we treat them as already covered. Mark them sent.
                    break
                }
                published.append(item.id)
            } catch {
                failedIDs.append(item.id)
                if firstError == nil { firstError = "\(error)" }
            }
        }

        if !published.isEmpty {
            try await store.markOutboxSent(ids: published)
            logger.info("mirror: published \(published.count) rows (batch=\(batch.count))")
        }
        if !failedIDs.isEmpty, let firstError {
            try await store.markOutboxFailed(ids: failedIDs, error: firstError)
            throw MirrorError.publishFailed(firstError)
        }
        return published.count
    }

    private func ensureSchema(client: PostgresClient) async throws {
        for (i, stmt) in SchemaGenerator.canonicalStatements.enumerated() {
            do {
                try await runDDL(client: client, sql: stmt)
            } catch {
                logger.error("mirror: schema init failed at canonical step \(i): \(error)\n--- SQL ---\n\(stmt)\n-----------")
                throw MirrorError.schemaInit("canonical step \(i): \(error)")
            }
        }
        for (i, stmt) in SchemaGenerator.profileStatements(descriptor).enumerated() {
            do {
                try await runDDL(client: client, sql: stmt)
            } catch {
                logger.error("mirror: schema init failed at profile step \(i): \(error)\n--- SQL ---\n\(stmt)\n-----------")
                throw MirrorError.schemaInit("profile step \(i): \(error)")
            }
        }
        logger.info("mirror: schema ready (profile=\(descriptor.id) safeID=\(descriptor.safeID) dim=\(descriptor.dim))")
    }

    /// Run a parameterless DDL/DML statement and fully drain the row sequence
    /// before returning. postgres-nio leaves the connection in an indeterminate
    /// state if the row sequence is dropped without iteration.
    private func runDDL(client: PostgresClient, sql: String) async throws {
        let preview = sql.split(separator: "\n").first.map(String.init) ?? sql
        logger.info("mirror DDL → \(preview.prefix(80))")
        let rows = try await client.query(PostgresQuery(unsafeSQL: sql))
        for try await _ in rows {}
        logger.info("mirror DDL ✓ \(preview.prefix(80))")
    }

    private func publishMemory(client: PostgresClient, memoryID: UUID) async throws {
        guard let m = try await store.loadMemoryFull(id: memoryID) else {
            // Memory was deleted before mirror caught up — treat as no-op.
            return
        }
        if m.tombstoned {
            try await publishMemoryDelete(client: client, memoryID: memoryID)
            return
        }

        // Upsert into memories. search_document is regenerated by the trigger.
        let metadataJSON = "{}"
        try await client.query(
            """
            INSERT INTO memories
                (id, text, created_at, occurred_at, source, conversation_id, language, sentiment, metadata, tombstoned)
            VALUES (\(m.id), \(m.text), \(m.createdAt), \(m.occurredAt), \(m.source), \(m.conversationID),
                    \(m.language), \(m.sentiment), \(metadataJSON)::jsonb, \(m.tombstoned))
            ON CONFLICT (id) DO UPDATE SET
                text             = EXCLUDED.text,
                occurred_at      = EXCLUDED.occurred_at,
                source           = EXCLUDED.source,
                conversation_id  = EXCLUDED.conversation_id,
                language         = EXCLUDED.language,
                sentiment        = EXCLUDED.sentiment,
                tombstoned       = EXCLUDED.tombstoned
            """
        )

        logger.debug("publishMemory \(m.id): mentions=\(m.mentions.count) tags=\(m.tags.count)")

        // Entity/mention fan-out for the v2.5 entity-mention seed branch.
        // Upsert entities by id (already deterministic from Core Data), then
        // insert mention rows. Each (memory, entity, span) becomes one row.
        for mention in m.mentions {
            try await client.query("""
                INSERT INTO entities (id, canonical_name, entity_type)
                VALUES (\(mention.entityID), \(mention.canonicalName), \(mention.entityType))
                ON CONFLICT (id) DO UPDATE SET
                    canonical_name = EXCLUDED.canonical_name,
                    entity_type    = EXCLUDED.entity_type
                """)
            // Mentions are write-once-per-(memory,entity,span); regenerate
            // by clearing this memory's mentions first to keep upserts simple.
        }
        if !m.mentions.isEmpty {
            try await client.query("DELETE FROM mentions WHERE memory_id = \(m.id)")
            for mention in m.mentions {
                let mentionID = UUID()
                let startInt = mention.startOffset
                let endInt = mention.endOffset
                try await client.query("""
                    INSERT INTO mentions (id, memory_id, entity_id, start_offset, end_offset)
                    VALUES (\(mentionID), \(m.id), \(mention.entityID), \(startInt), \(endInt))
                    """)
            }
        }

        // Tag fan-out: ensure tags exist, link.
        for name in m.tags {
            let tagID = deterministicUUID(forTag: name)
            try await client.query(
                """
                INSERT INTO tags (id, name) VALUES (\(tagID), \(name))
                ON CONFLICT (name) DO NOTHING
                """
            )
            try await client.query(
                """
                INSERT INTO memory_tags (memory_id, tag_id)
                VALUES (\(m.id), (SELECT id FROM tags WHERE name = \(name)))
                ON CONFLICT DO NOTHING
                """
            )
        }

        // Embedding upsert into the per-profile table — only when the stored
        // vector matches the active profile (dim + profile id). Heterogeneous
        // rows (e.g., NL fallback writes while Core ML profile is active) are
        // simply skipped here; they live as an unmirrored axis until that
        // profile is activated and registers its own table.
        guard m.embeddingDim == descriptor.dim,
              (m.embeddingProfile ?? "") == descriptor.id,
              !m.embedding.isEmpty
        else {
            logger.debug("mirror: skipping embedding for \(m.id) (profile mismatch: stored=\(m.embeddingProfile ?? "?")/\(m.embeddingDim) active=\(descriptor.id)/\(descriptor.dim))")
            return
        }

        let vectorLiteral = vectorString(m.embedding)
        let table = descriptor.embeddingsTable
        try await client.query(
            try PostgresQuery(unsafeSQL: """
            INSERT INTO \(table) (memory_id, embedding, updated_at)
            VALUES ($1, $2::vector, now())
            ON CONFLICT (memory_id) DO UPDATE SET
                embedding  = EXCLUDED.embedding,
                updated_at = EXCLUDED.updated_at
            """, binds: [m.id, vectorLiteral])
        )
    }

    private func publishMemoryDelete(client: PostgresClient, memoryID: UUID) async throws {
        // Cascades remove from memory_tags and per-profile embedding tables.
        try await client.query("DELETE FROM memories WHERE id = \(memoryID)")
    }

    /// Build a pgvector text literal `[v0,v1,...]`.
    private func vectorString(_ v: [Float]) -> String {
        var s = "["
        for i in 0..<v.count {
            if i > 0 { s += "," }
            s += String(v[i])
        }
        s += "]"
        return s
    }

    /// Stable UUID derived from tag name so concurrent mirror instances don't
    /// produce duplicate rows. Postgres still uniques by name, but reusing the
    /// same id avoids unnecessary churn on `ON CONFLICT`.
    private func deterministicUUID(forTag name: String) -> UUID {
        let key = "claude-mind:tag:\(name)"
        let digest = CryptoKit.SHA256.hash(data: Data(key.utf8))
        var u = Array(digest.prefix(16))
        // Force version 5 / RFC 4122 variant.
        u[6] = (u[6] & 0x0F) | 0x50
        u[8] = (u[8] & 0x3F) | 0x80
        return UUID(uuid: (
            u[0], u[1], u[2], u[3], u[4], u[5], u[6], u[7],
            u[8], u[9], u[10], u[11], u[12], u[13], u[14], u[15]
        ))
    }
}

/// PostgresQuery extension: build with explicit raw SQL + binds when string
/// interpolation isn't expressive enough (e.g., dynamic table name).
extension PostgresQuery {
    init(unsafeSQL sql: String, binds: [any PostgresEncodable & Sendable]) throws {
        var bindings = PostgresBindings(capacity: binds.count)
        for v in binds { try bindings.append(v) }
        self.init(unsafeSQL: sql, binds: bindings)
    }
}
