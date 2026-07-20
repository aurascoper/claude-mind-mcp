import Foundation
import Logging
import ClaudeMindCore

// Lightweight regression runner. CommandLineTools-only macOS setups don't
// have XCTest or swift-testing modules available, so each check is just a
// `require` that exits non-zero on failure. Add a check; run; ship.
//
// Usage: `swift run claude-mind-regression`

final class Tally: @unchecked Sendable {
    var passed = 0
    var failed = 0
}
let tally = Tally()

func require(_ condition: Bool, _ message: @autoclosure () -> String, file: StaticString = #file, line: UInt = #line) {
    if condition {
        tally.passed += 1
    } else {
        tally.failed += 1
        FileHandle.standardError.write(Data("FAIL [\(file):\(line)] \(message())\n".utf8))
    }
}

@main
struct Regression {
    static func main() async throws {
        try await mentionRoundTrip()
        try await metadataSpatialRoundTrip()
        schemaSpatialSqlPresent()
        FileHandle.standardError.write(Data("\nregression: \(tally.passed) passed, \(tally.failed) failed\n".utf8))
        if tally.failed > 0 { exit(1) }
    }

    /// The seed-level spatial pre-filter is exercised only against a live Postgres
    /// mirror (none here), so pin the EMITTED SQL instead: the schema carries the
    /// cube extension / column / GiST index / trigger, and every recall seed query
    /// carries the bounding-box predicate. Catches SQL-generation regressions.
    static func schemaSpatialSqlPresent() {
        let stmts = SchemaGenerator.canonicalStatements.joined(separator: "\n")
        require(stmts.contains("CREATE EXTENSION IF NOT EXISTS cube"), "canonicalStatements missing cube extension")
        require(stmts.contains("metadata_coord cube"), "canonicalStatements missing metadata_coord column")
        require(stmts.contains("ADD COLUMN IF NOT EXISTS metadata_coord cube"), "canonicalStatements missing ALTER for existing mirrors")
        require(stmts.contains("USING gist (metadata_coord)"), "canonicalStatements missing GiST index")
        require(stmts.contains("memories_metadata_coord_trigger"), "canonicalStatements missing coord trigger")
        require(SchemaGenerator.canonicalDDL.contains("CREATE EXTENSION IF NOT EXISTS cube"), "canonicalDDL missing cube extension")
        require(SchemaGenerator.canonicalDDL.contains("metadata_coord cube"), "canonicalDDL missing metadata_coord column")
        require(SchemaGenerator.recallLexicalQuery.contains("m.metadata_coord <@ cube("), "lexical query missing spatial predicate")
        require(SchemaGenerator.recallEntityMentionQuery.contains("m.metadata_coord <@ cube("), "entity query missing spatial predicate")
    }

    /// Continuous-coordinate metadata (the Stage-4 upgrade of categorical
    /// `node:<id>` tags): metadata round-trips through the `metadataJSON` column,
    /// and a `near`/`radius` spatial filter keeps only in-radius coordinates
    /// while excluding far ones AND coordinate-less memories.
    static func metadataSpatialRoundTrip() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmm-spatial-\(UUID().uuidString).sqlite")
        defer {
            try? FileManager.default.removeItem(at: tmp)
            try? FileManager.default.removeItem(at: tmp.appendingPathExtension("shm"))
            try? FileManager.default.removeItem(at: tmp.appendingPathExtension("wal"))
        }
        let settings = Settings(storeURL: tmp, embeddingBackend: "test", embeddingProfile: "test",
                                coreMLUnits: "all", mirrorEnabled: false, pgDSN: nil)
        let store = try MemoryStore(settings: settings, logger: Logger(label: "cmm-regression"))
        let signal = EnrichedSignal(language: "en", sentiment: 0, entities: [], embedding: nil,
                                    backend: "test", profile: "test", dimension: 0)

        let a = try await store.remember(draft: MemoryDraft(text: "node A", tags: ["node:0"],
                                          metadata: ["x": 0, "y": 0, "z": 0]), signal: signal)
        let b = try await store.remember(draft: MemoryDraft(text: "node B", tags: ["node:1"],
                                          metadata: ["x": 1, "y": 0, "z": 0]), signal: signal)
        let c = try await store.remember(draft: MemoryDraft(text: "node C no coord"), signal: signal)

        // No spatial filter: all three, and metadata round-trips (nil for C).
        let all = try await store.recall(queryEmbedding: nil, filters: RecallFilters(), k: 10,
                                         weightSemantic: 0, weightRecency: 1)
        require(all.count == 3, "expected 3 memories, got \(all.count)")
        let hitA = all.first { $0.id == a.id }
        require(hitA?.metadata?["x"] == 0 && hitA?.metadata?["y"] == 0,
                "metadata did not round-trip for A: \(String(describing: hitA?.metadata))")
        require(all.first { $0.text == "node C no coord" }?.metadata == nil,
                "expected nil metadata for coordinate-less C")

        // Tight radius near A: only A (B is 1.0 away; C has no coordinate).
        let near = try await store.recall(queryEmbedding: nil,
                    filters: RecallFilters(spatial: SpatialFilter(center: [0, 0, 0], radius: 0.1)),
                    k: 10, weightSemantic: 0, weightRecency: 1)
        require(near.count == 1 && near.first?.id == a.id,
                "spatial recall near origin (r=0.1) should return only A, got \(near.map { $0.text })")

        // Wider radius catches B too, still excludes coordinate-less C.
        let wide = try await store.recall(queryEmbedding: nil,
                    filters: RecallFilters(spatial: SpatialFilter(center: [0, 0, 0], radius: 1.5)),
                    k: 10, weightSemantic: 0, weightRecency: 1)
        require(Set(wide.map { $0.id }) == [a.id, b.id],
                "spatial recall near origin (r=1.5) should return A and B only, got \(wide.map { $0.text })")

        // Write-path (Postgres v2): loadMemoryFull surfaces metadata — the exact
        // value MirrorWorker serializes into the Postgres `metadata` JSONB (was
        // hardcoded "{}"). Can't test the mirror INSERT without a live Postgres,
        // but this covers its testable input.
        let full = try await store.loadMemoryFull(id: a.id)   // A was stored at [0,0,0]
        require(full?.metadata?["x"] == 0 && full?.metadata?["y"] == 0 && full?.metadata?["z"] == 0,
                "loadMemoryFull metadata did not round-trip: \(String(describing: full?.metadata))")
        let fullC = try await store.loadMemoryFull(id: c.id)
        require(fullC?.metadata == nil, "coordinate-less memory should have nil metadata, got \(String(describing: fullC?.metadata))")
    }

    /// Catches regressions on the entity-FK workaround (Core Data
    /// programmatic-model relationship-faulting bug — see docs/coredata-bug-repro/).
    /// If `MemoryStore.loadMemoryFull` reverts to traversing `mention.entity`
    /// directly, mentions come back empty.
    static func mentionRoundTrip() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmm-regression-\(UUID().uuidString).sqlite")
        defer {
            try? FileManager.default.removeItem(at: tmp)
            try? FileManager.default.removeItem(at: tmp.appendingPathExtension("shm"))
            try? FileManager.default.removeItem(at: tmp.appendingPathExtension("wal"))
        }

        let settings = Settings(
            storeURL: tmp,
            embeddingBackend: "test",
            embeddingProfile: "test",
            coreMLUnits: "all",
            mirrorEnabled: false,
            pgDSN: nil
        )
        let logger = Logger(label: "cmm-regression")
        let store = try MemoryStore(settings: settings, logger: logger)

        let signal = EnrichedSignal(
            language: "en",
            sentiment: 0.0,
            entities: [
                DetectedEntity(value: "Sarah",   type: "PersonalName", start: 0,  end: 5),
                DetectedEntity(value: "Oakland", type: "PlaceName",    start: 17, end: 24)
            ],
            embedding: nil,
            backend: "test",
            profile: "test",
            dimension: 0
        )
        let draft = MemoryDraft(text: "Sarah lives in Oakland.")
        let result = try await store.remember(draft: draft, signal: signal)

        let loaded = try await store.loadMemoryFull(id: result.id)
        require(loaded != nil, "loadMemoryFull returned nil for just-stored memory")
        guard let memory = loaded else { return }

        require(memory.mentions.count == 2,
                "expected 2 mentions, got \(memory.mentions.count) — entity-FK workaround likely undone (see docs/coredata-bug-repro/)")

        let names = Set(memory.mentions.map { $0.canonicalName })
        require(names == ["Sarah", "Oakland"],
                "mention names round-trip mismatch: got \(names)")

        let types = Set(memory.mentions.map { $0.entityType })
        require(types == ["PersonalName", "PlaceName"],
                "mention types round-trip mismatch: got \(types)")
    }
}
