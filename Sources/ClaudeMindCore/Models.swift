import Foundation

public struct DetectedEntity: Sendable, Codable, Equatable {
    public let value: String
    public let type: String
    public let start: Int
    public let end: Int
    public init(value: String, type: String, start: Int, end: Int) {
        self.value = value; self.type = type; self.start = start; self.end = end
    }
}

public struct EnrichedSignal: Sendable {
    public let language: String?
    public let sentiment: Double?
    public let entities: [DetectedEntity]
    public let embedding: [Float]?
    public let backend: String
    public let profile: String
    public let dimension: Int
    public init(
        language: String?,
        sentiment: Double?,
        entities: [DetectedEntity],
        embedding: [Float]?,
        backend: String,
        profile: String,
        dimension: Int
    ) {
        self.language = language; self.sentiment = sentiment; self.entities = entities
        self.embedding = embedding; self.backend = backend; self.profile = profile; self.dimension = dimension
    }
}

public struct MemoryDraft: Sendable {
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

public struct RecallFilters: Sendable {
    public let from: Date?
    public let to: Date?
    public let source: String?
    public let conversationID: String?
    public let tags: [String]
    public init(from: Date? = nil, to: Date? = nil, source: String? = nil, conversationID: String? = nil, tags: [String] = []) {
        self.from = from; self.to = to; self.source = source; self.conversationID = conversationID; self.tags = tags
    }
}

public struct RecallHit: Sendable, Codable {
    public let id: UUID
    public let text: String
    public let createdAt: Date
    public let occurredAt: Date?
    public let source: String?
    public let conversationID: String?
    public let language: String?
    public let semanticScore: Float
    public let recencyScore: Float
    public let combinedScore: Float
    public let tags: [String]
}

public struct RecallSeed: Sendable {
    public let id: UUID
    public let text: String
    public let createdAt: Date
    public let occurredAt: Date?
    public let source: String?
    public let conversationID: String?
    public let language: String?
    public let semanticScore: Float
    public let lexicalScore: Float
    /// Which seed branches surfaced this memory. v2.5 values: "vector",
    /// "lexical", "entity". Multiple if more than one branch returned the row.
    public let sourceBranches: [String]
    public init(
        id: UUID, text: String, createdAt: Date, occurredAt: Date?, source: String?,
        conversationID: String?, language: String?, semanticScore: Float, lexicalScore: Float,
        sourceBranches: [String]
    ) {
        self.id = id; self.text = text; self.createdAt = createdAt; self.occurredAt = occurredAt
        self.source = source; self.conversationID = conversationID; self.language = language
        self.semanticScore = semanticScore; self.lexicalScore = lexicalScore
        self.sourceBranches = sourceBranches
    }
}

/// Per-branch top-K budgets. Total seed pool is bounded above by
/// `vec + lex + ent` (less after dedupe). Override via env vars
/// `CLAUDE_MIND_KVEC`, `CLAUDE_MIND_KLEX`, `CLAUDE_MIND_KENT`.
public struct BranchBudgets: Sendable, Equatable {
    public var vec: Int
    public var lex: Int
    public var ent: Int
    public init(vec: Int = 25, lex: Int = 25, ent: Int = 25) {
        self.vec = vec; self.lex = lex; self.ent = ent
    }
    public static let `default` = BranchBudgets()
}

public struct BranchCounts: Sendable, Codable {
    public let vec: Int
    public let lex: Int
    public let ent: Int
    public let unique: Int
    public init(vec: Int, lex: Int, ent: Int, unique: Int) {
        self.vec = vec; self.lex = lex; self.ent = ent; self.unique = unique
    }
}

public protocol RecallSeeder: Sendable {
    var profile: String { get }
    var dim: Int { get }
    func seedFromPostgres(
        queryEmbedding: [Float],
        queryText: String,
        entityNames: [String],
        filters: RecallFilters,
        requestedProfile: String,
        requestedDim: Int,
        budgets: BranchBudgets
    ) async throws -> (seeds: [RecallSeed], counts: BranchCounts)
}

public struct MentionInfo: Sendable, Codable, Equatable {
    public let entityID: UUID
    public let canonicalName: String
    public let entityType: String
    public let startOffset: Int
    public let endOffset: Int
    public init(entityID: UUID, canonicalName: String, entityType: String, startOffset: Int, endOffset: Int) {
        self.entityID = entityID; self.canonicalName = canonicalName; self.entityType = entityType
        self.startOffset = startOffset; self.endOffset = endOffset
    }
}

public struct MemoryFull: Sendable, Codable {
    public let id: UUID
    public let text: String
    public let createdAt: Date
    public let occurredAt: Date?
    public let source: String?
    public let conversationID: String?
    public let language: String?
    public let sentiment: Double?
    public let embedding: [Float]
    public let embeddingBackend: String?
    public let embeddingProfile: String?
    public let embeddingDim: Int
    public let tombstoned: Bool
    public let tags: [String]
    public let mentions: [MentionInfo]
}

public struct RememberResult: Sendable, Codable {
    public let id: UUID
    public let createdAt: Date
    public let language: String?
    public let sentiment: Double?
    public let entities: [DetectedEntity]
    public let embeddingBackend: String
    public let embeddingProfile: String
    public let embeddingDimension: Int
}
