import Foundation
import PostgresNIO
import Logging
import ServiceLifecycle
import ClaudeMindCore

public enum RecallError: Error, CustomStringConvertible {
    case profileMismatch(active: String, requested: String)
    case dimensionMismatch(active: Int, requested: Int)
    case unreachable(String)
    case sqlError(String)
    public var description: String {
        switch self {
        case .profileMismatch(let a, let r): return "profile mismatch: active=\(a) requested=\(r)"
        case .dimensionMismatch(let a, let r): return "dim mismatch: active=\(a) requested=\(r)"
        case .unreachable(let s): return "postgres unreachable: \(s)"
        case .sqlError(let s): return "sql error: \(s)"
        }
    }
}

/// Owns its own PostgresClient. Wrapped as a Service so ServiceGroup can run
/// `client.run()` alongside the MCP server and the mirror drainer.
/// Sharing the mirror's client would cross actor boundaries cleanly; one extra
/// pooled client to the same DB is the simpler trade for now.
public final class RecallService: Service, RecallSeeder, @unchecked Sendable {
    public let descriptor: SchemaGenerator.ProfileDescriptor
    public var profile: String { descriptor.id }
    public var dim: Int { descriptor.dim }

    private let client: PostgresClient
    private let logger: Logger

    public init(
        config: MirrorConfig,
        descriptor: SchemaGenerator.ProfileDescriptor,
        logger: Logger
    ) throws {
        let pgConfig = try config.postgresClientConfig()
        self.client = PostgresClient(configuration: pgConfig, backgroundLogger: logger)
        self.descriptor = descriptor
        self.logger = logger
    }

    public func run() async throws {
        try await cancelWhenGracefulShutdown {
            await self.client.run()
        }
    }

    /// Hybrid seed query — runs vector / lexical / entity-mention branches in
    /// parallel, dedupes by memory_id, attributes `sourceBranches` per hit.
    /// Returns the union plus per-branch counts for diagnostics.
    public func seedFromPostgres(
        queryEmbedding: [Float],
        queryText: String,
        entityNames: [String],
        filters: RecallFilters,
        requestedProfile: String,
        requestedDim: Int,
        budgets: BranchBudgets
    ) async throws -> (seeds: [RecallSeed], counts: BranchCounts) {
        guard requestedProfile == descriptor.id else {
            throw RecallError.profileMismatch(active: descriptor.id, requested: requestedProfile)
        }
        guard requestedDim == descriptor.dim else {
            throw RecallError.dimensionMismatch(active: descriptor.dim, requested: requestedDim)
        }

        // Run the three branches concurrently. Each branch isolates its own
        // failures so a misconfigured tsvector or empty entity set doesn't
        // tank the whole seed.
        async let vec = vectorBranch(queryEmbedding: queryEmbedding, filters: filters, k: budgets.vec)
        async let lex = lexicalBranch(queryText: queryText, filters: filters, k: budgets.lex)
        async let ent = entityBranch(entityNames: entityNames, filters: filters, k: budgets.ent)

        let vRows = (try? await vec) ?? []
        let lRows = (try? await lex) ?? []
        let eRows = (try? await ent) ?? []

        // Dedupe by memory id. When the same memory shows up in multiple
        // branches, keep the highest score per axis and accumulate the
        // sourceBranches list.
        struct Acc {
            var seed: RecallSeed
            var branches: Set<String>
        }
        var acc: [UUID: Acc] = [:]

        func merge(_ row: RecallSeed, branch: String) {
            if var existing = acc[row.id] {
                let sem = max(existing.seed.semanticScore, row.semanticScore)
                let lex = max(existing.seed.lexicalScore, row.lexicalScore)
                existing.branches.insert(branch)
                existing.seed = RecallSeed(
                    id: existing.seed.id, text: existing.seed.text,
                    createdAt: existing.seed.createdAt, occurredAt: existing.seed.occurredAt,
                    source: existing.seed.source, conversationID: existing.seed.conversationID,
                    language: existing.seed.language,
                    semanticScore: sem, lexicalScore: lex,
                    sourceBranches: existing.branches.sorted()
                )
                acc[row.id] = existing
            } else {
                var branches: Set<String> = [branch]
                let s = RecallSeed(
                    id: row.id, text: row.text, createdAt: row.createdAt,
                    occurredAt: row.occurredAt, source: row.source,
                    conversationID: row.conversationID, language: row.language,
                    semanticScore: row.semanticScore, lexicalScore: row.lexicalScore,
                    sourceBranches: Array(branches).sorted()
                )
                acc[row.id] = Acc(seed: s, branches: branches)
            }
        }
        for r in vRows { merge(r, branch: "vector") }
        for r in lRows { merge(r, branch: "lexical") }
        for r in eRows { merge(r, branch: "entity") }

        let seeds = acc.values.map { $0.seed }
        let counts = BranchCounts(vec: vRows.count, lex: lRows.count, ent: eRows.count, unique: seeds.count)
        return (seeds, counts)
    }

    // MARK: per-branch executors

    private func vectorBranch(queryEmbedding: [Float], filters: RecallFilters, k: Int) async throws -> [RecallSeed] {
        guard k > 0 else { return [] }
        let sql = SchemaGenerator.recallVectorQuery(descriptor)
        var b = PostgresBindings(capacity: 6)
        do {
            try b.append(vectorString(queryEmbedding))
            try b.append(filters.from)
            try b.append(filters.to)
            try b.append(filters.source)
            try b.append(filters.conversationID)
            try b.append(max(1, k))
        } catch { throw RecallError.sqlError("bind/vec: \(error)") }
        return try await runRowsAsSeeds(PostgresQuery(unsafeSQL: sql, binds: b))
    }

    private func lexicalBranch(queryText: String, filters: RecallFilters, k: Int) async throws -> [RecallSeed] {
        guard k > 0 else { return [] }
        // websearch_to_tsquery treats whitespace as AND; for memory recall we
        // want any-term match. Tokenize, drop short/stopword-ish terms, and
        // OR-join. Empty result → skip the query entirely.
        let stop: Set<String> = [
            "the","a","an","and","or","is","of","to","on","at","in","for","with",
            "what","was","were","did","do","does","i","my","me","we","our","you",
            "any","anything","about","that","this","those","these","be","been",
            "around","change","changed","changes","changed?","work","work?","work."
        ]
        let tokens = queryText
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty && $0.count >= 2 && !stop.contains($0) }
        guard !tokens.isEmpty else { return [] }
        let tsQuery = tokens.joined(separator: " OR ")
        let sql = SchemaGenerator.recallLexicalQuery
        var b = PostgresBindings(capacity: 6)
        do {
            try b.append(tsQuery)
            try b.append(filters.from)
            try b.append(filters.to)
            try b.append(filters.source)
            try b.append(filters.conversationID)
            try b.append(max(1, k))
        } catch { throw RecallError.sqlError("bind/lex: \(error)") }
        return try await runRowsAsSeeds(PostgresQuery(unsafeSQL: sql, binds: b))
    }

    private func entityBranch(entityNames: [String], filters: RecallFilters, k: Int) async throws -> [RecallSeed] {
        guard k > 0, !entityNames.isEmpty else { return [] }
        let normalized = entityNames.map { $0.lowercased() }
        let sql = SchemaGenerator.recallEntityMentionQuery
        var b = PostgresBindings(capacity: 6)
        do {
            try b.append(normalized)
            try b.append(filters.from)
            try b.append(filters.to)
            try b.append(filters.source)
            try b.append(filters.conversationID)
            try b.append(max(1, k))
        } catch { throw RecallError.sqlError("bind/ent: \(error)") }
        return try await runRowsAsSeeds(PostgresQuery(unsafeSQL: sql, binds: b))
    }

    private func runRowsAsSeeds(_ q: PostgresQuery) async throws -> [RecallSeed] {
        do {
            let rows = try await client.query(q)
            var out: [RecallSeed] = []
            for try await row in rows {
                let decoded = try row.decode(
                    (UUID, String, Date, Date?, String?, String?, String?, Double?, Double, Double).self
                )
                out.append(RecallSeed(
                    id: decoded.0, text: decoded.1, createdAt: decoded.2, occurredAt: decoded.3,
                    source: decoded.4, conversationID: decoded.5, language: decoded.6,
                    semanticScore: Float(decoded.8), lexicalScore: Float(decoded.9),
                    sourceBranches: []
                ))
            }
            return out
        } catch {
            let s = "\(error)"
            if s.contains("ConnectionPool") || s.contains("connectionError") || s.contains("Connect timeout") {
                throw RecallError.unreachable(s)
            }
            throw RecallError.sqlError(s)
        }
    }

    private func vectorString(_ v: [Float]) -> String {
        var s = "["
        for i in 0..<v.count {
            if i > 0 { s += "," }
            s += String(v[i])
        }
        s += "]"
        return s
    }
}
