import CoreData
import Foundation
import Logging

public enum MemoryStoreError: Error, CustomStringConvertible {
    case loadFailed(String)
    case missingEntity(String)
    public var description: String {
        switch self {
        case .loadFailed(let s): return "MemoryStore load failed: \(s)"
        case .missingEntity(let s): return "Missing entity: \(s)"
        }
    }
}

public final class MemoryStore: @unchecked Sendable {
    private let container: NSPersistentContainer
    private let workContext: NSManagedObjectContext
    private let logger: Logger

    public init(settings: Settings, logger: Logger) throws {
        let model = ManagedObjectModelBuilder.make()
        let container = NSPersistentContainer(name: "ClaudeMind", managedObjectModel: model)
        let desc = NSPersistentStoreDescription(url: settings.storeURL)
        desc.type = NSSQLiteStoreType
        desc.shouldAddStoreAsynchronously = false
        desc.shouldMigrateStoreAutomatically = true
        desc.shouldInferMappingModelAutomatically = true
        container.persistentStoreDescriptions = [desc]

        var loadErr: Error?
        container.loadPersistentStores { _, err in loadErr = err }
        if let loadErr { throw MemoryStoreError.loadFailed("\(loadErr)") }

        container.viewContext.automaticallyMergesChangesFromParent = true
        let work = container.newBackgroundContext()
        work.mergePolicy = NSMergePolicy.mergeByPropertyObjectTrump
        self.container = container
        self.workContext = work
        self.logger = logger
    }

    // MARK: remember

    public func remember(draft: MemoryDraft, signal: EnrichedSignal) async throws -> RememberResult {
        let ctx = workContext
        let now = Date()
        let memoryID = UUID()

        return try await ctx.perform {
            guard
                let memoryE  = NSEntityDescription.entity(forEntityName: MemoryEntity.memory,  in: ctx),
                let mentionE = NSEntityDescription.entity(forEntityName: MemoryEntity.mention, in: ctx),
                let entityE  = NSEntityDescription.entity(forEntityName: MemoryEntity.entity,  in: ctx),
                let tagE     = NSEntityDescription.entity(forEntityName: MemoryEntity.tag,     in: ctx),
                let outboxE  = NSEntityDescription.entity(forEntityName: MemoryEntity.outbox,  in: ctx)
            else { throw MemoryStoreError.missingEntity("core entities not registered") }

            let memory = NSManagedObject(entity: memoryE, insertInto: ctx)
            memory.setValue(memoryID, forKey: "id")
            memory.setValue(draft.text, forKey: "text")
            memory.setValue(now, forKey: "createdAt")
            memory.setValue(draft.occurredAt, forKey: "occurredAt")
            memory.setValue(draft.source, forKey: "source")
            memory.setValue(draft.conversationID, forKey: "conversationID")
            memory.setValue(signal.language, forKey: "language")
            memory.setValue(signal.sentiment ?? 0, forKey: "sentiment")
            if let vec = signal.embedding {
                memory.setValue(EmbeddingCodec.encode(vec), forKey: "embeddingBlob")
            }
            memory.setValue(signal.backend, forKey: "embeddingBackend")
            memory.setValue(signal.profile, forKey: "embeddingProfile")
            memory.setValue(Int32(signal.dimension), forKey: "embeddingDim")
            memory.setValue(false, forKey: "tombstoned")

            // Mentions + entities (entity dedup by canonicalName + type)
            for det in signal.entities {
                let entityObj = try Self.upsertEntity(ctx: ctx, entityDesc: entityE, name: det.value, type: det.type)
                let entityID = entityObj.value(forKey: "id") as? UUID ?? UUID()
                let mention = NSManagedObject(entity: mentionE, insertInto: ctx)
                mention.setValue(UUID(), forKey: "id")
                mention.setValue(Int64(det.start), forKey: "startOffset")
                mention.setValue(Int64(det.end), forKey: "endOffset")
                mention.setValue(memory, forKey: "memory")
                mention.setValue(entityObj, forKey: "entity")
                mention.setValue(entityID, forKey: "entityID")  // direct FK to dodge relationship-faulting issues
            }

            // Tags
            for name in draft.tags {
                let tagObj = try Self.upsertTag(ctx: ctx, tagDesc: tagE, name: name)
                let tags = (memory.mutableSetValue(forKey: "tags"))
                tags.add(tagObj)
            }

            // Outbox row (always written; mirror worker drains in milestone 2)
            let outbox = NSManagedObject(entity: outboxE, insertInto: ctx)
            outbox.setValue(UUID(), forKey: "id")
            outbox.setValue("memory", forKey: "recordType")
            outbox.setValue(memoryID, forKey: "recordID")
            outbox.setValue("upsert", forKey: "operation")
            outbox.setValue(now, forKey: "createdAt")
            outbox.setValue(Int32(0), forKey: "attemptCount")

            try ctx.save()

            return RememberResult(
                id: memoryID,
                createdAt: now,
                language: signal.language,
                sentiment: signal.sentiment,
                entities: signal.entities,
                embeddingBackend: signal.backend,
                embeddingProfile: signal.profile,
                embeddingDimension: signal.dimension
            )
        }
    }

    private static func upsertEntity(ctx: NSManagedObjectContext, entityDesc: NSEntityDescription, name: String, type: String) throws -> NSManagedObject {
        let req = NSFetchRequest<NSManagedObject>(entityName: MemoryEntity.entity)
        req.predicate = NSPredicate(format: "canonicalName ==[c] %@ AND type == %@", name, type)
        req.fetchLimit = 1
        if let existing = try ctx.fetch(req).first { return existing }
        let obj = NSManagedObject(entity: entityDesc, insertInto: ctx)
        obj.setValue(UUID(), forKey: "id")
        obj.setValue(name, forKey: "canonicalName")
        obj.setValue(type, forKey: "type")
        return obj
    }

    private static func upsertTag(ctx: NSManagedObjectContext, tagDesc: NSEntityDescription, name: String) throws -> NSManagedObject {
        let req = NSFetchRequest<NSManagedObject>(entityName: MemoryEntity.tag)
        req.predicate = NSPredicate(format: "name == %@", name)
        req.fetchLimit = 1
        if let existing = try ctx.fetch(req).first { return existing }
        let obj = NSManagedObject(entity: tagDesc, insertInto: ctx)
        obj.setValue(UUID(), forKey: "id")
        obj.setValue(name, forKey: "name")
        return obj
    }

    // MARK: recall

    public func recall(
        queryEmbedding: [Float]?,
        filters: RecallFilters,
        k: Int,
        prefilterLimit: Int = 5000,
        recencyHalfLifeDays: Double = 30,
        weightSemantic: Float = 0.7,
        weightRecency: Float = 0.3
    ) async throws -> [RecallHit] {
        let ctx = workContext

        return try await ctx.perform {
            let req = NSFetchRequest<NSManagedObject>(entityName: MemoryEntity.memory)
            var predicates: [NSPredicate] = [NSPredicate(format: "tombstoned == NO")]
            if let from = filters.from {
                predicates.append(NSPredicate(format: "(occurredAt >= %@) OR (occurredAt == nil AND createdAt >= %@)", from as NSDate, from as NSDate))
            }
            if let to = filters.to {
                predicates.append(NSPredicate(format: "(occurredAt <= %@) OR (occurredAt == nil AND createdAt <= %@)", to as NSDate, to as NSDate))
            }
            if let source = filters.source {
                predicates.append(NSPredicate(format: "source == %@", source))
            }
            if let conv = filters.conversationID {
                predicates.append(NSPredicate(format: "conversationID == %@", conv))
            }
            if !filters.tags.isEmpty {
                predicates.append(NSPredicate(format: "ANY tags.name IN %@", filters.tags))
            }
            req.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
            req.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: false)]
            req.fetchLimit = prefilterLimit
            req.returnsObjectsAsFaults = false

            let rows = try ctx.fetch(req)
            let now = Date()

            struct Scored {
                let hit: RecallHit
                let combined: Float
            }

            var scored: [Scored] = []
            scored.reserveCapacity(rows.count)

            for row in rows {
                guard
                    let id = row.value(forKey: "id") as? UUID,
                    let text = row.value(forKey: "text") as? String,
                    let createdAt = row.value(forKey: "createdAt") as? Date
                else { continue }

                let occurredAt = row.value(forKey: "occurredAt") as? Date
                let source = row.value(forKey: "source") as? String
                let convID = row.value(forKey: "conversationID") as? String
                let language = row.value(forKey: "language") as? String
                let blob = row.value(forKey: "embeddingBlob") as? Data
                let stored = blob.map(EmbeddingCodec.decode) ?? []

                let sem: Float
                if let q = queryEmbedding, !q.isEmpty, !stored.isEmpty, q.count == stored.count {
                    sem = max(0, EmbeddingCodec.cosineSimilarity(q, stored))
                } else {
                    sem = 0
                }

                let anchor = occurredAt ?? createdAt
                let ageDays = max(0, now.timeIntervalSince(anchor) / 86_400)
                let rec = Float(pow(0.5, ageDays / max(0.001, recencyHalfLifeDays)))

                let combined = weightSemantic * sem + weightRecency * rec

                let tagNames: [String]
                if let set = row.value(forKey: "tags") as? Set<NSManagedObject> {
                    tagNames = set.compactMap { $0.value(forKey: "name") as? String }.sorted()
                } else {
                    tagNames = []
                }

                let hit = RecallHit(
                    id: id,
                    text: text,
                    createdAt: createdAt,
                    occurredAt: occurredAt,
                    source: source,
                    conversationID: convID,
                    language: language,
                    semanticScore: sem,
                    recencyScore: rec,
                    combinedScore: combined,
                    tags: tagNames
                )
                scored.append(.init(hit: hit, combined: combined))
            }

            scored.sort { $0.combined > $1.combined }
            return scored.prefix(k).map { $0.hit }
        }
    }

    // MARK: forget / list_recent

    public func forget(id: UUID) async throws -> Bool {
        let ctx = workContext
        return try await ctx.perform {
            let req = NSFetchRequest<NSManagedObject>(entityName: MemoryEntity.memory)
            req.predicate = NSPredicate(format: "id == %@", id as CVarArg)
            req.fetchLimit = 1
            guard let row = try ctx.fetch(req).first else { return false }
            row.setValue(true, forKey: "tombstoned")
            try ctx.save()
            return true
        }
    }

    public func listRecent(limit: Int) async throws -> [RecallHit] {
        try await recall(queryEmbedding: nil, filters: RecallFilters(), k: limit, weightSemantic: 0, weightRecency: 1)
    }

    // MARK: graph expansion (1-hop entity neighbors)

    public struct ExpandedHit: Sendable {
        public let memory: MemoryFull
        public let isSeed: Bool
        public let sharedEntityCount: Int
    }

    /// Returns seeds + memories that share at least one entity mention with any seed.
    /// Tombstoned rows are excluded. Same date/source filters as recall apply, so the
    /// caller can keep the same scoping the seed query used.
    public func expandGraph(seedIDs: [UUID], filters: RecallFilters) async throws -> [ExpandedHit] {
        guard !seedIDs.isEmpty else { return [] }
        let ctx = workContext
        return try await ctx.perform {
            // Step 1: collect entity ids referenced by any seed via Mention.
            let mentionReq = NSFetchRequest<NSManagedObject>(entityName: MemoryEntity.mention)
            mentionReq.predicate = NSPredicate(format: "memory.id IN %@", seedIDs as CVarArg)
            mentionReq.returnsObjectsAsFaults = false
            let seedMentions = try ctx.fetch(mentionReq)
            var seedEntityIDs = Set<UUID>()
            for m in seedMentions {
                if let e = m.value(forKey: "entity") as? NSManagedObject,
                   let id = e.value(forKey: "id") as? UUID {
                    seedEntityIDs.insert(id)
                }
            }

            // Step 2: collect 1-hop neighbor memory ids whose mentions hit those entities.
            var neighborSharedCount: [UUID: Int] = [:]
            if !seedEntityIDs.isEmpty {
                let nReq = NSFetchRequest<NSManagedObject>(entityName: MemoryEntity.mention)
                nReq.predicate = NSPredicate(format: "entity.id IN %@", Array(seedEntityIDs) as CVarArg)
                nReq.returnsObjectsAsFaults = false
                let neighborMentions = try ctx.fetch(nReq)
                for m in neighborMentions {
                    if let mem = m.value(forKey: "memory") as? NSManagedObject,
                       let id = mem.value(forKey: "id") as? UUID,
                       !seedIDs.contains(id) {
                        neighborSharedCount[id, default: 0] += 1
                    }
                }
            }

            // Step 3: load full rows for seeds + neighbors, applying tombstone + scope filter.
            let allIDs = Array(Set(seedIDs).union(neighborSharedCount.keys))
            var predicates: [NSPredicate] = [
                NSPredicate(format: "tombstoned == NO"),
                NSPredicate(format: "id IN %@", allIDs as CVarArg)
            ]
            if let from = filters.from {
                predicates.append(NSPredicate(format: "(occurredAt >= %@) OR (createdAt >= %@)", from as NSDate, from as NSDate))
            }
            if let to = filters.to {
                predicates.append(NSPredicate(format: "(occurredAt <= %@) OR (createdAt <= %@)", to as NSDate, to as NSDate))
            }
            if let source = filters.source {
                predicates.append(NSPredicate(format: "source == %@", source))
            }
            if let conv = filters.conversationID {
                predicates.append(NSPredicate(format: "conversationID == %@", conv))
            }
            if !filters.tags.isEmpty {
                predicates.append(NSPredicate(format: "ANY tags.name IN %@", filters.tags))
            }
            let req = NSFetchRequest<NSManagedObject>(entityName: MemoryEntity.memory)
            req.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
            req.returnsObjectsAsFaults = false
            let rows = try ctx.fetch(req)

            let seedSet = Set(seedIDs)
            var out: [ExpandedHit] = []
            for row in rows {
                guard
                    let id = row.value(forKey: "id") as? UUID,
                    let text = row.value(forKey: "text") as? String,
                    let createdAt = row.value(forKey: "createdAt") as? Date
                else { continue }
                let blob = row.value(forKey: "embeddingBlob") as? Data
                let stored = blob.map(EmbeddingCodec.decode) ?? []
                let tagSet = (row.value(forKey: "tags") as? Set<NSManagedObject>) ?? []
                let tagNames = tagSet.compactMap { $0.value(forKey: "name") as? String }.sorted()
                let mem = MemoryFull(
                    id: id,
                    text: text,
                    createdAt: createdAt,
                    occurredAt: row.value(forKey: "occurredAt") as? Date,
                    source: row.value(forKey: "source") as? String,
                    conversationID: row.value(forKey: "conversationID") as? String,
                    language: row.value(forKey: "language") as? String,
                    sentiment: row.value(forKey: "sentiment") as? Double,
                    embedding: stored,
                    embeddingBackend: row.value(forKey: "embeddingBackend") as? String,
                    embeddingProfile: row.value(forKey: "embeddingProfile") as? String,
                    embeddingDim: Int((row.value(forKey: "embeddingDim") as? Int32) ?? 0),
                    tombstoned: (row.value(forKey: "tombstoned") as? Bool) ?? false,
                    tags: tagNames,
                    mentions: []  // expandGraph doesn't need mentions; mirror loadMemoryFull does
                )
                out.append(ExpandedHit(
                    memory: mem,
                    isSeed: seedSet.contains(id),
                    sharedEntityCount: neighborSharedCount[id] ?? 0
                ))
            }
            return out
        }
    }

    // MARK: outbox

    public struct OutboxStats: Sendable {
        public let pending: Int
        public let oldestCreatedAt: Date?
        public let oldestLastError: String?
        public let totalAttempts: Int
    }

    public struct OutboxBatchItem: Sendable {
        public let id: UUID
        public let recordType: String
        public let recordID: UUID
        public let operation: String
        public let payloadJSON: Data?
        public let createdAt: Date
        public let attemptCount: Int32
    }

    /// Snapshot of the outbox for observability. Logs threshold warnings should
    /// be driven from this rather than ad-hoc fetches.
    public func outboxStats() async throws -> OutboxStats {
        let ctx = workContext
        return try await ctx.perform {
            let req = NSFetchRequest<NSManagedObject>(entityName: MemoryEntity.outbox)
            req.predicate = NSPredicate(format: "sentAt == nil")
            req.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: true)]
            req.returnsObjectsAsFaults = false
            let rows = try ctx.fetch(req)
            var totalAttempts = 0
            for r in rows {
                if let n = r.value(forKey: "attemptCount") as? Int32 { totalAttempts += Int(n) }
            }
            let oldest = rows.first
            return OutboxStats(
                pending: rows.count,
                oldestCreatedAt: oldest?.value(forKey: "createdAt") as? Date,
                oldestLastError: oldest?.value(forKey: "lastError") as? String,
                totalAttempts: totalAttempts
            )
        }
    }

    /// Fetch up to `limit` pending outbox rows, oldest first. Used by the mirror drainer.
    public func nextOutboxBatch(limit: Int) async throws -> [OutboxBatchItem] {
        let ctx = workContext
        return try await ctx.perform {
            let req = NSFetchRequest<NSManagedObject>(entityName: MemoryEntity.outbox)
            req.predicate = NSPredicate(format: "sentAt == nil")
            req.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: true)]
            req.fetchLimit = max(1, limit)
            req.returnsObjectsAsFaults = false
            let rows = try ctx.fetch(req)
            return rows.compactMap { r -> OutboxBatchItem? in
                guard
                    let id = r.value(forKey: "id") as? UUID,
                    let rType = r.value(forKey: "recordType") as? String,
                    let rID = r.value(forKey: "recordID") as? UUID,
                    let op = r.value(forKey: "operation") as? String,
                    let createdAt = r.value(forKey: "createdAt") as? Date
                else { return nil }
                return OutboxBatchItem(
                    id: id,
                    recordType: rType,
                    recordID: rID,
                    operation: op,
                    payloadJSON: r.value(forKey: "payloadJSON") as? Data,
                    createdAt: createdAt,
                    attemptCount: (r.value(forKey: "attemptCount") as? Int32) ?? 0
                )
            }
        }
    }

    /// Mark a set of outbox rows as successfully sent.
    public func markOutboxSent(ids: [UUID], at: Date = Date()) async throws {
        guard !ids.isEmpty else { return }
        let ctx = workContext
        try await ctx.perform {
            let req = NSFetchRequest<NSManagedObject>(entityName: MemoryEntity.outbox)
            req.predicate = NSPredicate(format: "id IN %@", ids as CVarArg)
            for row in try ctx.fetch(req) {
                row.setValue(at, forKey: "sentAt")
                row.setValue(at, forKey: "lastAttemptAt")
                row.setValue(nil, forKey: "lastError")
            }
            try ctx.save()
        }
    }

    /// Record a failed attempt: bumps attemptCount, stores lastError, lastAttemptAt.
    public func markOutboxFailed(ids: [UUID], error: String, at: Date = Date()) async throws {
        guard !ids.isEmpty else { return }
        let ctx = workContext
        try await ctx.perform {
            let req = NSFetchRequest<NSManagedObject>(entityName: MemoryEntity.outbox)
            req.predicate = NSPredicate(format: "id IN %@", ids as CVarArg)
            for row in try ctx.fetch(req) {
                let prev = (row.value(forKey: "attemptCount") as? Int32) ?? 0
                row.setValue(prev + 1, forKey: "attemptCount")
                row.setValue(at, forKey: "lastAttemptAt")
                row.setValue(error, forKey: "lastError")
            }
            try ctx.save()
        }
    }

    /// Resolve a memory id to its current row (used by the mirror to assemble payloads).
    public func loadMemoryFull(id: UUID) async throws -> MemoryFull? {
        let ctx = workContext
        return try await ctx.perform {
            let req = NSFetchRequest<NSManagedObject>(entityName: MemoryEntity.memory)
            req.predicate = NSPredicate(format: "id == %@", id as CVarArg)
            req.fetchLimit = 1
            req.returnsObjectsAsFaults = false
            guard let row = try ctx.fetch(req).first else { return nil }
            let tagSet = (row.value(forKey: "tags") as? Set<NSManagedObject>) ?? []
            let tagNames = tagSet.compactMap { $0.value(forKey: "name") as? String }.sorted()

            // Mentions / entities for the mirror's entity-mention branch.
            // Use the redundant entityID attribute on Mention rather than the
            // `entity` relationship: programmatic-model relationship faulting
            // can return nil for the related object even though the FK is
            // persisted in SQLite. The entityID lookup + a separate entity
            // fetch is reliable and roughly the same cost.
            var mentions: [MentionInfo] = []
            let mentionReq = NSFetchRequest<NSManagedObject>(entityName: MemoryEntity.mention)
            mentionReq.predicate = NSPredicate(format: "memory == %@", row)
            mentionReq.returnsObjectsAsFaults = false
            let fetchedMentions = (try? ctx.fetch(mentionReq)) ?? []

            // Collect the entity ids referenced by these mentions and fetch
            // them in one query.
            let entityIDs: [UUID] = fetchedMentions.compactMap { $0.value(forKey: "entityID") as? UUID }
            var entityByID: [UUID: NSManagedObject] = [:]
            if !entityIDs.isEmpty {
                let entReq = NSFetchRequest<NSManagedObject>(entityName: MemoryEntity.entity)
                entReq.predicate = NSPredicate(format: "id IN %@", entityIDs as CVarArg)
                entReq.returnsObjectsAsFaults = false
                for e in (try? ctx.fetch(entReq)) ?? [] {
                    if let eid = e.value(forKey: "id") as? UUID { entityByID[eid] = e }
                }
            }

            for m in fetchedMentions {
                guard
                    let eid = m.value(forKey: "entityID") as? UUID,
                    let entity = entityByID[eid],
                    let name = entity.value(forKey: "canonicalName") as? String,
                    let etype = entity.value(forKey: "type") as? String
                else { continue }
                let start = (m.value(forKey: "startOffset") as? Int64).map(Int.init) ?? 0
                let end   = (m.value(forKey: "endOffset")   as? Int64).map(Int.init) ?? 0
                mentions.append(MentionInfo(
                    entityID: eid, canonicalName: name, entityType: etype,
                    startOffset: start, endOffset: end
                ))
            }

            return MemoryFull(
                id: row.value(forKey: "id") as? UUID ?? id,
                text: row.value(forKey: "text") as? String ?? "",
                createdAt: row.value(forKey: "createdAt") as? Date ?? Date(),
                occurredAt: row.value(forKey: "occurredAt") as? Date,
                source: row.value(forKey: "source") as? String,
                conversationID: row.value(forKey: "conversationID") as? String,
                language: row.value(forKey: "language") as? String,
                sentiment: row.value(forKey: "sentiment") as? Double,
                embedding: (row.value(forKey: "embeddingBlob") as? Data).map(EmbeddingCodec.decode) ?? [],
                embeddingBackend: row.value(forKey: "embeddingBackend") as? String,
                embeddingProfile: row.value(forKey: "embeddingProfile") as? String,
                embeddingDim: Int((row.value(forKey: "embeddingDim") as? Int32) ?? 0),
                tombstoned: (row.value(forKey: "tombstoned") as? Bool) ?? false,
                tags: tagNames,
                mentions: mentions
            )
        }
    }

    // MARK: recall_around

    public func recallAround(
        anchorID: UUID?,
        anchorDate: Date?,
        windowSeconds: TimeInterval,
        k: Int
    ) async throws -> [RecallHit] {
        let ctx = workContext
        return try await ctx.perform {
            var anchor: Date?
            if let id = anchorID {
                let req = NSFetchRequest<NSManagedObject>(entityName: MemoryEntity.memory)
                req.predicate = NSPredicate(format: "id == %@", id as CVarArg)
                req.fetchLimit = 1
                if let row = try ctx.fetch(req).first {
                    anchor = (row.value(forKey: "occurredAt") as? Date) ?? (row.value(forKey: "createdAt") as? Date)
                }
            }
            if anchor == nil { anchor = anchorDate }
            guard let anchor else { return [] }

            let from = anchor.addingTimeInterval(-windowSeconds)
            let to   = anchor.addingTimeInterval(windowSeconds)

            let req = NSFetchRequest<NSManagedObject>(entityName: MemoryEntity.memory)
            req.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
                NSPredicate(format: "tombstoned == NO"),
                NSPredicate(format: "(occurredAt >= %@ AND occurredAt <= %@) OR (createdAt >= %@ AND createdAt <= %@)",
                            from as NSDate, to as NSDate, from as NSDate, to as NSDate)
            ])
            req.returnsObjectsAsFaults = false
            let rows = try ctx.fetch(req)
            self.logger.info("recallAround: anchor=\(anchor) window=\(windowSeconds)s rows=\(rows.count)")

            struct Scored { let hit: RecallHit; let delta: TimeInterval }
            var scored: [Scored] = []
            scored.reserveCapacity(rows.count)
            for row in rows {
                guard
                    let id = row.value(forKey: "id") as? UUID,
                    let text = row.value(forKey: "text") as? String,
                    let createdAt = row.value(forKey: "createdAt") as? Date
                else { continue }
                let occurredAt = row.value(forKey: "occurredAt") as? Date
                let when = occurredAt ?? createdAt
                let delta = abs(when.timeIntervalSince(anchor))
                let tagNames: [String] = (row.value(forKey: "tags") as? Set<NSManagedObject>)?
                    .compactMap { $0.value(forKey: "name") as? String }.sorted() ?? []
                let hit = RecallHit(
                    id: id,
                    text: text,
                    createdAt: createdAt,
                    occurredAt: occurredAt,
                    source: row.value(forKey: "source") as? String,
                    conversationID: row.value(forKey: "conversationID") as? String,
                    language: row.value(forKey: "language") as? String,
                    semanticScore: 0,
                    recencyScore: Float(1.0 - min(1.0, delta / max(windowSeconds, 1))),
                    combinedScore: Float(1.0 - min(1.0, delta / max(windowSeconds, 1))),
                    tags: tagNames
                )
                scored.append(.init(hit: hit, delta: delta))
            }
            scored.sort { $0.delta < $1.delta }
            return scored.prefix(k).map { $0.hit }
        }
    }
}
