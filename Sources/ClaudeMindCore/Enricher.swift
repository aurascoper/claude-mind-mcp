import Foundation
import NaturalLanguage
import Logging

public protocol Enricher: Sendable {
    var backend: String { get }
    var profile: String { get }
    var dimension: Int { get }
    func enrich(text: String) async throws -> EnrichedSignal
    func embed(text: String) async throws -> [Float]?
}

@available(macOS 14.0, *)
public actor AppleNLPEnricher: Enricher {
    public nonisolated let backend: String
    public nonisolated let profile: String
    public nonisolated let dimension: Int

    private let language: NLLanguage
    private let contextual: NLContextualEmbedding?
    private let sentenceFallback: NLEmbedding?
    private let logger: Logger

    private struct Resolved {
        let contextual: NLContextualEmbedding?
        let sentenceFallback: NLEmbedding?
        let backend: String
        let dimension: Int
    }

    public init(
        language: NLLanguage = .english,
        profile: String = "multilingual.default",
        eagerWarmup: Bool = true,
        logger: Logger
    ) async throws {
        let resolved = await Self.resolveBackend(language: language, eagerWarmup: eagerWarmup, logger: logger)
        self.language = language
        self.logger = logger
        self.contextual = resolved.contextual
        self.sentenceFallback = resolved.sentenceFallback
        self.backend = resolved.backend
        self.profile = profile
        self.dimension = resolved.dimension
    }

    private static func resolveBackend(language: NLLanguage, eagerWarmup: Bool, logger: Logger) async -> Resolved {
        if let ctx = NLContextualEmbedding(language: language) {
            var assetMode = "cached"
            let assetStart = Date()
            if !ctx.hasAvailableAssets {
                if eagerWarmup {
                    logger.info("NLContextualEmbedding: assets not local; requesting (first-load)…")
                    do {
                        _ = try await ctx.requestAssets()
                        assetMode = "downloaded"
                    } catch {
                        logger.warning("NLContextualEmbedding requestAssets failed: \(error). Falling back.")
                        return makeFallback(language: language, logger: logger)
                    }
                } else {
                    logger.info("NLContextualEmbedding assets not local and eagerWarmup=false; falling back.")
                    return makeFallback(language: language, logger: logger)
                }
            }
            let assetMs = Int(Date().timeIntervalSince(assetStart) * 1000)
            let loadStart = Date()
            do {
                try ctx.load()
                let loadMs = Int(Date().timeIntervalSince(loadStart) * 1000)
                logger.info("NLContextualEmbedding ready: dim=\(ctx.dimension) asset=\(assetMode) asset_ms=\(assetMs) load_ms=\(loadMs)")
                return Resolved(contextual: ctx, sentenceFallback: nil, backend: "NLContextualEmbedding", dimension: ctx.dimension)
            } catch {
                logger.warning("NLContextualEmbedding.load() failed: \(error). Falling back.")
            }
        }
        return makeFallback(language: language, logger: logger)
    }

    private static func makeFallback(language: NLLanguage, logger: Logger) -> Resolved {
        if let s = NLEmbedding.sentenceEmbedding(for: language) {
            logger.info("Fallback: NLEmbedding.sentenceEmbedding dim=\(s.dimension)")
            return Resolved(contextual: nil, sentenceFallback: s, backend: "NLEmbedding.sentenceEmbedding", dimension: s.dimension)
        }
        logger.warning("No embedding backend available; embeddings will be nil.")
        return Resolved(contextual: nil, sentenceFallback: nil, backend: "none", dimension: 0)
    }

    public func enrich(text: String) async throws -> EnrichedSignal {
        let lang = NLLanguageRecognizer.dominantLanguage(for: text)?.rawValue
        let entities = extractEntities(text: text)
        let sentiment = extractSentiment(text: text)
        let vec = try await embed(text: text)
        return EnrichedSignal(
            language: lang,
            sentiment: sentiment,
            entities: entities,
            embedding: vec,
            backend: backend,
            profile: profile,
            dimension: dimension
        )
    }

    public func embed(text: String) async throws -> [Float]? {
        if let ctx = contextual {
            let result = try ctx.embeddingResult(for: text, language: language)
            return Self.meanPool(result: result, dim: ctx.dimension)
        }
        if let s = sentenceFallback {
            guard let v = s.vector(for: text) else { return nil }
            return v.map { Float($0) }
        }
        return nil
    }

    private static func meanPool(result: NLContextualEmbeddingResult, dim: Int) -> [Float]? {
        var sum = [Double](repeating: 0, count: dim)
        var count = 0
        result.enumerateTokenVectors(in: result.string.startIndex..<result.string.endIndex) { vector, _ in
            guard vector.count == dim else { return true }
            for i in 0..<dim { sum[i] += vector[i] }
            count += 1
            return true
        }
        guard count > 0 else { return nil }
        let inv = 1.0 / Double(count)
        var pooled = sum.map { Float($0 * inv) }
        var norm: Float = 0
        for v in pooled { norm += v * v }
        let n = norm.squareRoot()
        if n > 0 { for i in 0..<pooled.count { pooled[i] /= n } }
        return pooled
    }

    private func extractEntities(text: String) -> [DetectedEntity] {
        return EntityExtractor.extract(text: text)
    }

    private func extractSentiment(text: String) -> Double? {
        let tagger = NLTagger(tagSchemes: [.sentimentScore])
        tagger.string = text
        let (tag, _) = tagger.tag(at: text.startIndex, unit: .paragraph, scheme: .sentimentScore)
        guard let raw = tag?.rawValue, let v = Double(raw) else { return nil }
        return v
    }
}
