import Foundation

public struct Settings: Sendable {
    public let storeURL: URL
    public let embeddingBackend: String   // "coreml" | "nl"
    public let embeddingProfile: String   // model name when coreml; profile id when nl
    public let coreMLUnits: String        // "cpu" | "cpu+ane" | "all"
    public let mirrorEnabled: Bool
    public let pgDSN: String?

    public init(
        storeURL: URL,
        embeddingBackend: String,
        embeddingProfile: String,
        coreMLUnits: String,
        mirrorEnabled: Bool,
        pgDSN: String?
    ) {
        self.storeURL = storeURL
        self.embeddingBackend = embeddingBackend
        self.embeddingProfile = embeddingProfile
        self.coreMLUnits = coreMLUnits
        self.mirrorEnabled = mirrorEnabled
        self.pgDSN = pgDSN
    }

    public static func fromEnvironment(_ env: [String: String] = ProcessInfo.processInfo.environment) -> Settings {
        let defaultStore = defaultStoreURL()
        let storeURL = env["CLAUDE_MIND_STORE_URL"].flatMap { URL(fileURLWithPath: $0) } ?? defaultStore
        return Settings(
            storeURL: storeURL,
            embeddingBackend: env["CLAUDE_MIND_EMBEDDING_BACKEND"] ?? "coreml",
            embeddingProfile: env["CLAUDE_MIND_EMBEDDING_PROFILE"] ?? "minilm-l6-v2",
            coreMLUnits: env["CLAUDE_MIND_COREML_UNITS"] ?? "all",
            mirrorEnabled: (env["CLAUDE_MIND_ENABLE_PGVECTOR_MIRROR"] ?? "false").lowercased() == "true",
            pgDSN: env["CLAUDE_MIND_PG_DSN"]
        )
    }

    private static func defaultStoreURL() -> URL {
        let fm = FileManager.default
        let appSupport = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let dir = appSupport.appendingPathComponent("claude-mind", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("memory.sqlite")
    }
}
