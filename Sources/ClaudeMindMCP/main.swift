import Foundation
import MCP
import Logging
import ServiceLifecycle
import ClaudeMindCore
import ClaudeMindMirror

/// Holder so the MCP CallTool closure (registered before mirror services start)
/// can find the RecallService once it exists. Mutated only on the main task at
/// startup; sendable via @unchecked Sendable wrapper.
final class RecallSeederBox: @unchecked Sendable {
    var value: (any RecallSeeder)?
}
let recallSeederBox = RecallSeederBox()

@main
struct ClaudeMindMCPApp {
    static func main() async throws {
        let logger = Logger(label: "claude-mind-mcp")

        if CommandLine.arguments.contains("--probe") {
            let dsn = ProcessInfo.processInfo.environment["CLAUDE_MIND_PG_DSN"] ?? ""
            try await MirrorProbe.runProbe(dsn: dsn, logger: logger)
            return
        }

        let settings = Settings.fromEnvironment()
        logger.info("store=\(settings.storeURL.path) embedding=\(settings.embeddingBackend) profile=\(settings.embeddingProfile) mirror=\(settings.mirrorEnabled)")

        let store = try MemoryStore(settings: settings, logger: logger)
        let setup = try await Self.makeEnricher(settings: settings, logger: logger)
        let enricher = setup.enricher
        logger.info("enricher backend=\(enricher.backend) profile=\(enricher.profile) dim=\(enricher.dimension) model=\(setup.modelName) seq_len=\(setup.seqLen)")

        let server = Server(
            name: "ClaudeMindMCP",
            version: "0.1.0",
            capabilities: .init(tools: .init(listChanged: false))
        )

        await server.withMethodHandler(ListTools.self) { _ in
            .init(tools: ToolCatalog.all)
        }

        await server.withMethodHandler(CallTool.self) { params in
            let args = params.arguments ?? [:]
            switch params.name {
            case "now":
                return .init(content: [.text(text:DateTimeTool.nowJSON())], isError: false)

            case "parse_date":
                let text = args["text"]?.stringValue ?? ""
                return .init(content: [.text(text:DateTimeTool.parseDateJSON(text: text))], isError: false)

            case "remember":
                let r = RememberArgs(
                    text: args["text"]?.stringValue ?? "",
                    source: args["source"]?.stringValue,
                    conversationID: args["conversation_id"]?.stringValue,
                    occurredAt: parseISO8601(args["occurred_at"]?.stringValue),
                    tags: stringArray(args["tags"])
                )
                if r.text.isEmpty {
                    return .init(content: [.text(text:"{\"error\": \"text is required\"}")], isError: true)
                }
                let json = await MemoryHandlers.remember(args: r, store: store, enricher: enricher, logger: logger)
                return .init(content: [.text(text:json)], isError: false)

            case "recall":
                let r = RecallArgs(
                    query: args["query"]?.stringValue ?? "",
                    from: parseISO8601(args["from"]?.stringValue),
                    to: parseISO8601(args["to"]?.stringValue),
                    source: args["source"]?.stringValue,
                    conversationID: args["conversation_id"]?.stringValue,
                    tags: stringArray(args["tags"]),
                    k: args["k"]?.intValue ?? 10
                )
                if r.query.isEmpty {
                    return .init(content: [.text(text:"{\"error\": \"query is required\"}")], isError: true)
                }
                let s = recallSeederBox.value
                logger.info("recall dispatch: seeder=\(s == nil ? "nil" : "present") box=\(ObjectIdentifier(recallSeederBox))")
                let json = await MemoryHandlers.recall(args: r, store: store, enricher: enricher, seeder: s, weights: recallWeights(), logger: logger)
                return .init(content: [.text(text:json)], isError: false)

            case "list_recent":
                let limit = args["limit"]?.intValue ?? 25
                let json = await MemoryHandlers.listRecent(limit: limit, store: store, logger: logger)
                return .init(content: [.text(text:json)], isError: false)

            case "forget":
                guard let idStr = args["id"]?.stringValue, let id = UUID(uuidString: idStr) else {
                    return .init(content: [.text(text:"{\"error\": \"id (UUID) is required\"}")], isError: true)
                }
                let json = await MemoryHandlers.forget(id: id, store: store, logger: logger)
                return .init(content: [.text(text:json)], isError: false)

            case "recall_around":
                let aid = (args["anchor_id"]?.stringValue).flatMap(UUID.init(uuidString:))
                let adate = parseISO8601(args["anchor_date"]?.stringValue)
                let win = args["window_seconds"]?.intValue.map(TimeInterval.init) ?? 86400
                let k = args["k"]?.intValue ?? 10
                if aid == nil && adate == nil {
                    return .init(content: [.text(text:"{\"error\": \"anchor_id or anchor_date is required\"}")], isError: true)
                }
                let json = await MemoryHandlers.recallAround(anchorID: aid, anchorDate: adate, windowSeconds: win, k: k, store: store, logger: logger)
                return .init(content: [.text(text:json)], isError: false)

            case "traverse", "relate":
                return .init(content: [.text(text:"{\"error\": \"\(params.name) is planned for v2.\"}")], isError: true)

            default:
                return .init(content: [.text(text:"{\"error\": \"Unknown tool: \(params.name)\"}")], isError: true)
            }
        }

        let transport = StdioTransport(logger: logger)

        // One canonical startup log line for the active descriptor — anyone reading
        // the logs can verify which profile is being mirrored / queried without
        // fishing through per-call lines.
        let activeDescriptor = SchemaGenerator.descriptor(enricher: enricher, modelName: setup.modelName, seqLen: setup.seqLen)
        logger.info("active profile: id=\(activeDescriptor.id) safeID=\(activeDescriptor.safeID) backend=\(activeDescriptor.backend) dim=\(activeDescriptor.dim) seq_len=\(activeDescriptor.seqLen) model=\(activeDescriptor.modelName)")

        if settings.mirrorEnabled, let dsn = settings.pgDSN, !dsn.isEmpty {
            let mirrorCfg = try MirrorConfig.parseDSN(dsn)
            let descriptor = activeDescriptor
            logger.info("mirror enabled: profile=\(descriptor.id) host=\(mirrorCfg.host) db=\(mirrorCfg.database)")
            #if !DEBUG
            logger.warning("""
            mirror is enabled but this is a release build. A Swift 6.3.1 release-mode \
            optimizer issue triggers `freed pointer was not the last allocation` when \
            postgres-nio and swift-transformers (Tokenizers) are linked in the same \
            binary and run two consecutive queries. If you hit it, rebuild with \
            `swift build -c debug` and re-run. See docs/swift-bug-repro/.
            """)
            #endif
            let worker = MirrorWorker(config: mirrorCfg, store: store, descriptor: descriptor, logger: logger)
            let recall = try RecallService(config: mirrorCfg, descriptor: descriptor, logger: logger)
            recallSeederBox.value = recall
            logger.info("recall seeder set: box=\(ObjectIdentifier(recallSeederBox))")

            let mcp = MCPService(server: server, transport: transport)
            let mirror = MirrorService(worker: worker, logger: logger)

            let group = ServiceGroup(
                configuration: .init(
                    services: [
                        .init(service: mcp,    successTerminationBehavior: .gracefullyShutdownGroup, failureTerminationBehavior: .gracefullyShutdownGroup),
                        .init(service: mirror, successTerminationBehavior: .gracefullyShutdownGroup, failureTerminationBehavior: .gracefullyShutdownGroup),
                        .init(service: recall, successTerminationBehavior: .gracefullyShutdownGroup, failureTerminationBehavior: .gracefullyShutdownGroup)
                    ],
                    gracefulShutdownSignals: [.sigterm, .sigint],
                    logger: logger
                )
            )
            try await group.run()
        } else {
            // No mirror: stdio server runs alone and exits cleanly on EOF.
            try await server.start(transport: transport)
            await server.waitUntilCompleted()
        }
    }

    struct EnricherSetup {
        let enricher: any Enricher
        let modelName: String
        let seqLen: Int
    }

    /// Resolve the enricher per settings, with NL as a graceful fallback when the
    /// Core ML model is unavailable or `CLAUDE_MIND_EMBEDDING_BACKEND=nl` is set.
    static func makeEnricher(settings: Settings, logger: Logger) async throws -> EnricherSetup {
        let eager = (ProcessInfo.processInfo.environment["CLAUDE_MIND_EAGER_WARMUP"] ?? "true").lowercased() != "false"

        if settings.embeddingBackend.lowercased() == "nl" {
            logger.info("Backend forced to NL via CLAUDE_MIND_EMBEDDING_BACKEND=nl")
            let e = try await AppleNLPEnricher(language: .english, profile: settings.embeddingProfile, eagerWarmup: eager, logger: logger)
            return EnricherSetup(enricher: e, modelName: e.backend, seqLen: 0)
        }

        if let resolved = ModelLocator.locate(name: settings.embeddingProfile, logger: logger) {
            do {
                let m = resolved.manifest
                logger.info("Using Core ML model \(m.name) v\(m.version) dim=\(m.dim) seq_len=\(m.seq_len) units=\(settings.coreMLUnits)")
                let e = try await CoreMLEnricher(
                    modelPath: resolved.modelPath,
                    units: settings.coreMLUnits,
                    profile: m.profile,
                    tokenizerFolder: resolved.tokenizerPath,
                    logger: logger
                )
                return EnricherSetup(enricher: e, modelName: m.name, seqLen: m.seq_len)
            } catch {
                logger.warning("CoreMLEnricher failed to initialize (\(error)); falling back to NL.")
            }
        } else {
            logger.warning("No Core ML model installed for profile=\(settings.embeddingProfile); falling back to NL. Install with scripts/install_model.sh")
        }
        let e = try await AppleNLPEnricher(language: .english, profile: "nl.fallback", eagerWarmup: eager, logger: logger)
        return EnricherSetup(enricher: e, modelName: e.backend, seqLen: 0)
    }

    /// Read recall weights from environment so the quality harness can sweep them
    /// without rebuilding. Defaults match `MemoryHandlers.RecallWeights()`.
    static func recallWeights() -> MemoryHandlers.RecallWeights {
        let env = ProcessInfo.processInfo.environment
        func f(_ key: String, _ fallback: Float) -> Float {
            if let s = env[key], let v = Float(s) { return v }
            return fallback
        }
        return MemoryHandlers.RecallWeights(
            semantic: f("CLAUDE_MIND_W_SEMANTIC", 0.55),
            recency:  f("CLAUDE_MIND_W_RECENCY",  0.20),
            graph:    f("CLAUDE_MIND_W_GRAPH",    0.10),
            lexical:  f("CLAUDE_MIND_W_LEXICAL",  0.15)
        )
    }

    static func parseISO8601(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    static func stringArray(_ v: Value?) -> [String] {
        guard case .array(let arr)? = v else { return [] }
        return arr.compactMap { $0.stringValue }
    }
}

struct MCPService: Service {
    let server: Server
    let transport: any Transport
    func run() async throws {
        try await server.start(transport: transport)
        await server.waitUntilCompleted()
    }
}

enum ToolCatalog {
    private static func str(_ desc: String) -> Value {
        .object(["type": .string("string"), "description": .string(desc)])
    }
    private static func int(_ desc: String) -> Value {
        .object(["type": .string("integer"), "description": .string(desc)])
    }
    private static func arrOfStr(_ desc: String) -> Value {
        .object([
            "type": .string("array"),
            "items": .object(["type": .string("string")]),
            "description": .string(desc)
        ])
    }
    private static func schema(properties: [String: Value], required: [String] = []) -> Value {
        var obj: [String: Value] = [
            "type": .string("object"),
            "properties": .object(properties)
        ]
        if !required.isEmpty {
            obj["required"] = .array(required.map { .string($0) })
        }
        return .object(obj)
    }

    static let all: [Tool] = [
        Tool(
            name: "now",
            description: "Return the current local date, time, timezone, weekday, quarter, and Unix timestamp.",
            inputSchema: schema(properties: [:])
        ),
        Tool(
            name: "parse_date",
            description: "Detect explicit dates in a phrase via NSDataDetector. Relative-phrase resolver lands in v2.",
            inputSchema: schema(
                properties: ["text": str("Natural-language phrase containing a date")],
                required: ["text"]
            )
        ),
        Tool(
            name: "remember",
            description: "Persist a memory entry. Enriches with Apple NLP (NER, sentiment, language, embedding) and writes to Core Data with an outbox row for the future Postgres mirror.",
            inputSchema: schema(
                properties: [
                    "text": str("Memory text"),
                    "source": str("Source or app name"),
                    "conversation_id": str("Conversation identifier"),
                    "occurred_at": str("Optional ISO8601 datetime"),
                    "tags": arrOfStr("Tags")
                ],
                required: ["text"]
            )
        ),
        Tool(
            name: "recall",
            description: "Retrieve memories using structured filters plus semantic similarity (cosine over Apple embeddings) blended with recency. v1 runs against Core Data only; pgvector mirror lands in v2.",
            inputSchema: schema(
                properties: [
                    "query": str("What to recall"),
                    "from": str("Optional ISO8601 start"),
                    "to": str("Optional ISO8601 end"),
                    "source": str("Optional source filter"),
                    "conversation_id": str("Optional conversation filter"),
                    "tags": arrOfStr("Tag filter"),
                    "k": int("Maximum results (default 10)")
                ],
                required: ["query"]
            )
        ),
        Tool(
            name: "recall_around",
            description: "Return memories temporally adjacent to an anchor (memory id OR ISO8601 date), within ±window_seconds, sorted by absolute time delta.",
            inputSchema: schema(
                properties: [
                    "anchor_id": str("Memory UUID to anchor on"),
                    "anchor_date": str("ISO8601 datetime to anchor on (used if anchor_id absent)"),
                    "window_seconds": int("± window in seconds (default 86400)"),
                    "k": int("Maximum results (default 10)")
                ]
            )
        ),
        Tool(
            name: "list_recent",
            description: "Return the N most recently created memories.",
            inputSchema: schema(properties: ["limit": int("Maximum results (default 25)")])
        ),
        Tool(
            name: "forget",
            description: "Soft-delete a memory by id (sets tombstoned).",
            inputSchema: schema(properties: ["id": str("Memory UUID")], required: ["id"])
        )
    ]
}
