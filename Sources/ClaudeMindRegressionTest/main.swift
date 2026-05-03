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
        FileHandle.standardError.write(Data("\nregression: \(tally.passed) passed, \(tally.failed) failed\n".utf8))
        if tally.failed > 0 { exit(1) }
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
