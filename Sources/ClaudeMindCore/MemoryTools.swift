import Foundation
import Logging

public struct RememberArgs: Sendable {
    public let text: String
    public let source: String?
    public let conversationID: String?
    public let occurredAt: Date?
    public let tags: [String]
    public init(text: String, source: String? = nil, conversationID: String? = nil, occurredAt: Date? = nil, tags: [String] = []) {
        self.text = text; self.source = source; self.conversationID = conversationID
        self.occurredAt = occurredAt; self.tags = tags
    }
}

public struct RecallArgs: Sendable {
    public let query: String
    public let from: Date?
    public let to: Date?
    public let source: String?
    public let conversationID: String?
    public let tags: [String]
    public let k: Int
    public init(query: String, from: Date? = nil, to: Date? = nil, source: String? = nil, conversationID: String? = nil, tags: [String] = [], k: Int = 10) {
        self.query = query; self.from = from; self.to = to; self.source = source
        self.conversationID = conversationID; self.tags = tags; self.k = k
    }
}

public enum MemoryHandlers {
    public static func remember(args: RememberArgs, store: MemoryStore, enricher: any Enricher, logger: Logger) async -> String {
        logger.info("remember: enrich start (text len=\(args.text.count))")
        do {
            let signal = try await enricher.enrich(text: args.text)
            logger.info("remember: enrich done (entities=\(signal.entities.count) embed_dim=\(signal.embedding?.count ?? 0))")
            let draft = MemoryDraft(
                text: args.text,
                source: args.source,
                conversationID: args.conversationID,
                occurredAt: args.occurredAt,
                tags: args.tags
            )
            let result = try await store.remember(draft: draft, signal: signal)
            logger.info("remember: stored id=\(result.id)")
            return encodeEncodable(result) ?? errorJSON("encoding failed")
        } catch {
            logger.error("remember failed: \(error)")
            return errorJSON("remember failed: \(error)")
        }
    }

    public struct RecallWeights: Sendable {
        public var semantic: Float
        public var recency: Float
        public var graph: Float
        public var lexical: Float
        public init(semantic: Float = 0.55, recency: Float = 0.20, graph: Float = 0.10, lexical: Float = 0.15) {
            self.semantic = semantic; self.recency = recency
            self.graph = graph; self.lexical = lexical
        }
    }

    /// Resolve per-branch budgets. Env vars override; otherwise scale with k.
    static func recallBudgets(seedOverfetch: Int, k: Int) -> BranchBudgets {
        let env = ProcessInfo.processInfo.environment
        func ev(_ key: String, _ fallback: Int) -> Int {
            if let s = env[key], let n = Int(s), n >= 0 { return n }
            return fallback
        }
        let scaled = max(25, k * seedOverfetch)
        return BranchBudgets(
            vec: ev("CLAUDE_MIND_KVEC", scaled),
            lex: ev("CLAUDE_MIND_KLEX", scaled),
            ent: ev("CLAUDE_MIND_KENT", scaled)
        )
    }

    public static func recall(
        args: RecallArgs,
        store: MemoryStore,
        enricher: any Enricher,
        seeder: (any RecallSeeder)? = nil,
        weights: RecallWeights = RecallWeights(),
        recencyHalfLifeDays: Double = 30,
        seedOverfetch: Int    = 3,
        logger: Logger
    ) async -> String {
        let weightSemantic = weights.semantic
        let weightRecency = weights.recency
        let weightGraph = weights.graph
        let weightLexical = weights.lexical
        do {
            // v2.5: enrich the query — gives us embedding AND extracted entity
            // names (for the entity-mention seed branch) in one pass.
            let querySignal = try await enricher.enrich(text: args.query)
            let queryEmbedding = querySignal.embedding
            let nerEntities = querySignal.entities.map { $0.value }

            // v2.6 (off by default): when NER returns nothing, generate
            // lowercase name-like candidates from the query so casual
            // lowercase queries can still hit the entity branch.
            let env = ProcessInfo.processInfo.environment
            let fallbackEnabled = (env["CLAUDE_MIND_QUERY_ENT_FALLBACK"] ?? "false").lowercased() == "true"
            let fallbackEntities: [String] = (fallbackEnabled && nerEntities.isEmpty)
                ? QueryEntityFallback.candidates(from: args.query)
                : []
            let queryEntities = nerEntities + fallbackEntities
            let filters = RecallFilters(
                from: args.from,
                to: args.to,
                source: args.source,
                conversationID: args.conversationID,
                tags: args.tags
            )
            let k = max(1, args.k)

            // 1) Try mirror seed if available, profile/dim match, and we have an embedding.
            var path = "local"
            var fallbackReason: String? = nil
            var seeds: [RecallSeed] = []
            var branchCounts: BranchCounts? = nil

            if let seeder, let qe = queryEmbedding {
                let budgets = recallBudgets(seedOverfetch: seedOverfetch, k: k)
                do {
                    let result = try await seeder.seedFromPostgres(
                        queryEmbedding: qe,
                        queryText: args.query,
                        entityNames: queryEntities,
                        filters: filters,
                        requestedProfile: enricher.profile,
                        requestedDim: enricher.dimension,
                        budgets: budgets
                    )
                    seeds = result.seeds
                    branchCounts = result.counts
                    path = "mirror"
                } catch {
                    fallbackReason = "seed: \(error)"
                    logger.warning("recall: mirror seed failed (\(error)); falling back to local")
                }
            } else if seeder == nil {
                fallbackReason = "no seeder configured"
            } else {
                fallbackReason = "no query embedding"
            }

            // 2) Mirror path → graph expand + rerank.
            if path == "mirror", !seeds.isEmpty {
                let seedIDs = seeds.map { $0.id }
                let pgScores = Dictionary(uniqueKeysWithValues: seeds.map { ($0.id, ($0.semanticScore, $0.lexicalScore)) })
                let pgBranches = Dictionary(uniqueKeysWithValues: seeds.map { ($0.id, $0.sourceBranches) })
                let expanded = try await store.expandGraph(seedIDs: seedIDs, filters: filters)

                let now = Date()
                struct Scored {
                    let hit: RecallHit
                    let combined: Float
                    let isSeed: Bool
                    let sharedEntityCount: Int
                }
                var scored: [Scored] = []
                for ex in expanded {
                    let m = ex.memory
                    let sem: Float
                    let lex: Float
                    if let pg = pgScores[m.id] {
                        sem = max(0, pg.0); lex = max(0, pg.1)
                    } else {
                        // Neighbor not in mirror's seed set: re-score against query embedding locally.
                        if let qe = queryEmbedding, !m.embedding.isEmpty, qe.count == m.embedding.count {
                            sem = max(0, EmbeddingCodec.cosineSimilarity(qe, m.embedding))
                        } else { sem = 0 }
                        lex = 0
                    }
                    let anchor = m.occurredAt ?? m.createdAt
                    let age = max(0, now.timeIntervalSince(anchor) / 86_400)
                    let rec = Float(pow(0.5, age / max(0.001, recencyHalfLifeDays)))
                    let graph: Float = ex.isSeed ? 1.0 : Float(min(1, Double(ex.sharedEntityCount) / 3.0))
                    let combined = weightSemantic * sem + weightRecency * rec
                                 + weightGraph * graph + weightLexical * lex

                    let hit = RecallHit(
                        id: m.id,
                        text: m.text,
                        createdAt: m.createdAt,
                        occurredAt: m.occurredAt,
                        source: m.source,
                        conversationID: m.conversationID,
                        language: m.language,
                        semanticScore: sem,
                        recencyScore: rec,
                        combinedScore: combined,
                        tags: m.tags
                    )
                    scored.append(.init(hit: hit, combined: combined, isSeed: ex.isSeed, sharedEntityCount: ex.sharedEntityCount))
                }
                scored.sort { $0.combined > $1.combined }
                let top = Array(scored.prefix(k))
                let bc = branchCounts ?? BranchCounts(vec: 0, lex: 0, ent: 0, unique: seeds.count)
                let fallbackPart: String = fallbackEntities.isEmpty
                    ? ""
                    : " fallback_tokens=" + fallbackEntities.joined(separator: ",")
                logger.info("recall path=mirror profile=\(enricher.profile) vec=\(bc.vec) lex=\(bc.lex) ent=\(bc.ent) unique=\(bc.unique) expanded=\(expanded.count) returned=\(top.count) ner_entities=\(nerEntities.count) fallback_entities=\(fallbackEntities.count)\(fallbackPart)")
                return encodeFoundation([
                    "query": args.query,
                    "k": args.k,
                    "path": "mirror",
                    "embedding_backend": enricher.backend,
                    "embedding_profile": enricher.profile,
                    "embedding_dimension": enricher.dimension,
                    "candidate_count": seeds.count,
                    "expanded_count": expanded.count,
                    "query_entities": queryEntities,
                    "ner_entities": nerEntities,
                    "fallback_entities": fallbackEntities,
                    "branch_counts": [
                        "vec": bc.vec,
                        "lex": bc.lex,
                        "ent": bc.ent,
                        "unique": bc.unique
                    ] as [String: Any],
                    "weights": [
                        "semantic": weightSemantic,
                        "recency": weightRecency,
                        "graph": weightGraph,
                        "lexical": weightLexical
                    ] as [String: Any],
                    "hits": top.map { s in
                        var d = hitDict(s.hit)
                        d["is_seed"] = s.isSeed
                        d["shared_entity_count"] = s.sharedEntityCount
                        d["lexical_score"] = pgScores[s.hit.id]?.1 ?? 0
                        d["graph_score"] = s.isSeed ? 1.0 : Double(min(1, Double(s.sharedEntityCount) / 3.0))
                        d["seed_source"] = pgBranches[s.hit.id] ?? []
                        return d
                    }
                ] as [String: Any]) ?? errorJSON("encoding failed")
            }

            // 3) Local fallback path.
            let hits = try await store.recall(
                queryEmbedding: queryEmbedding,
                filters: filters,
                k: k,
                weightSemantic: weightSemantic,
                weightRecency: weightRecency
            )
            logger.info("recall path=local profile=\(enricher.profile) returned=\(hits.count) reason=\(fallbackReason ?? "no mirror configured")")
            var payload: [String: Any] = [
                "query": args.query,
                "k": args.k,
                "path": "local",
                "embedding_backend": enricher.backend,
                "embedding_profile": enricher.profile,
                "embedding_dimension": enricher.dimension,
                "weights": [
                    "semantic": weightSemantic,
                    "recency": weightRecency,
                    "graph": weightGraph,
                    "lexical": weightLexical
                ] as [String: Any],
                "hits": hits.map { h -> [String: Any] in
                    var d = hitDict(h)
                    d["lexical_score"] = 0.0
                    d["graph_score"] = 0.0
                    d["is_seed"] = false
                    d["shared_entity_count"] = 0
                    return d
                }
            ]
            if let fallbackReason { payload["fallback_reason"] = fallbackReason }
            return encodeFoundation(payload) ?? errorJSON("encoding failed")
        } catch {
            logger.error("recall failed: \(error)")
            return errorJSON("recall failed: \(error)")
        }
    }

    public static func listRecent(limit: Int, store: MemoryStore, logger: Logger) async -> String {
        do {
            let hits = try await store.listRecent(limit: max(1, limit))
            return encodeFoundation(["limit": limit, "hits": hits.map(hitDict)] as [String: Any]) ?? errorJSON("encoding failed")
        } catch {
            logger.error("list_recent failed: \(error)")
            return errorJSON("list_recent failed: \(error)")
        }
    }

    public static func recallAround(
        anchorID: UUID?,
        anchorDate: Date?,
        windowSeconds: TimeInterval,
        k: Int,
        store: MemoryStore,
        logger: Logger
    ) async -> String {
        do {
            let hits = try await store.recallAround(anchorID: anchorID, anchorDate: anchorDate, windowSeconds: windowSeconds, k: max(1, k))
            return encodeFoundation([
                "anchor_id": anchorID?.uuidString as Any,
                "anchor_date": anchorDate.map { ISO8601DateFormatter().string(from: $0) } as Any,
                "window_seconds": windowSeconds,
                "k": k,
                "hits": hits.map(hitDict)
            ] as [String: Any]) ?? errorJSON("encoding failed")
        } catch {
            logger.error("recall_around failed: \(error)")
            return errorJSON("recall_around failed: \(error)")
        }
    }

    public static func forget(id: UUID, store: MemoryStore, logger: Logger) async -> String {
        do {
            let ok = try await store.forget(id: id)
            return encodeFoundation(["id": id.uuidString, "tombstoned": ok] as [String: Any]) ?? errorJSON("encoding failed")
        } catch {
            logger.error("forget failed: \(error)")
            return errorJSON("forget failed: \(error)")
        }
    }

    static func hitDict(_ h: RecallHit) -> [String: Any] {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var d: [String: Any] = [
            "id": h.id.uuidString,
            "text": h.text,
            "created_at": iso.string(from: h.createdAt),
            "semantic_score": h.semanticScore,
            "recency_score": h.recencyScore,
            "combined_score": h.combinedScore,
            "tags": h.tags
        ]
        if let occurredAt = h.occurredAt { d["occurred_at"] = iso.string(from: occurredAt) }
        if let source = h.source { d["source"] = source }
        if let conv = h.conversationID { d["conversation_id"] = conv }
        if let lang = h.language { d["language"] = lang }
        return d
    }

    private static func encodeFoundation(_ obj: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(obj),
              let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
              let s = String(data: data, encoding: .utf8) else { return nil }
        return s
    }

    private static func encodeEncodable<T: Encodable>(_ obj: T) -> String? {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        guard let data = try? enc.encode(obj), let s = String(data: data, encoding: .utf8) else { return nil }
        return s
    }

    private static func errorJSON(_ msg: String) -> String {
        return "{\n  \"error\": \(JSONSerialization.escape(msg))\n}"
    }
}

extension JSONSerialization {
    static func escape(_ s: String) -> String {
        if let d = try? JSONSerialization.data(withJSONObject: [s], options: []),
           let raw = String(data: d, encoding: .utf8) {
            // raw is like ["..."]; strip outer brackets
            let trimmed = raw.dropFirst().dropLast()
            return String(trimmed)
        }
        return "\"\(s)\""
    }
}
