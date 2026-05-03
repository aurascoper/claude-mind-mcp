import Foundation
import Logging
import ClaudeMindCore

struct BenchOptions {
    var backend: String = "nl"           // nl | coreml
    var coreMLModel: String? = nil
    var coreMLTokenizer: String? = nil
    var coreMLUnits: String = "all"      // cpu | cpu+ane | all
    var repeats: Int = 3
    var concurrency: Int = 1
    var corpusFile: String? = nil
    var outFile: String? = nil
    var skipRemember: Bool = false
}

func parseArgs() -> BenchOptions {
    var o = BenchOptions()
    var args = CommandLine.arguments.dropFirst().makeIterator()
    while let a = args.next() {
        switch a {
        case "--backend":         if let v = args.next() { o.backend = v }
        case "--coreml-model":     if let v = args.next() { o.coreMLModel = v }
        case "--coreml-tokenizer": if let v = args.next() { o.coreMLTokenizer = v }
        case "--coreml-units":     if let v = args.next() { o.coreMLUnits = v }
        case "--repeats":         if let v = args.next(), let n = Int(v) { o.repeats = n }
        case "--concurrency":     if let v = args.next(), let n = Int(v) { o.concurrency = n }
        case "--corpus":          if let v = args.next() { o.corpusFile = v }
        case "--out":             if let v = args.next() { o.outFile = v }
        case "--skip-remember":   o.skipRemember = true
        case "-h", "--help":
            print("""
            claude-mind-bench
              --backend nl|coreml          (default nl)
              --coreml-model PATH          (.mlpackage / .mlmodelc)
              --coreml-tokenizer PATH      (folder with tokenizer.json + vocab.txt; required for token-input models)
              --coreml-units cpu|cpu+ane|all  (default all)
              --repeats N                  (default 3)
              --concurrency N              (default 1, serial)
              --corpus PATH                (newline-delimited; default built-in)
              --out PATH                   (write JSON; default stdout)
              --skip-remember              (only bench embed)
            """)
            exit(0)
        default:
            FileHandle.standardError.write(Data("Unknown arg: \(a)\n".utf8))
            exit(2)
        }
    }
    return o
}

func loadCorpus(_ path: String?) -> [String] {
    guard let path else { return Corpus.default }
    guard let data = try? String(contentsOfFile: path, encoding: .utf8) else {
        FileHandle.standardError.write(Data("Could not read corpus at \(path)\n".utf8))
        exit(2)
    }
    return data.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.isEmpty }
}

func makeStore(at url: URL, logger: Logger) throws -> MemoryStore {
    let s = Settings(
        storeURL: url,
        embeddingBackend: "bench",
        embeddingProfile: "bench",
        coreMLUnits: "all",
        mirrorEnabled: false,
        pgDSN: nil
    )
    return try MemoryStore(settings: s, logger: logger)
}

func makeEnricher(_ o: BenchOptions, logger: Logger) async throws -> any Enricher {
    switch o.backend {
    case "nl":
        return try await AppleNLPEnricher(language: .english, profile: "bench.nl", eagerWarmup: true, logger: logger)
    case "coreml":
        guard let path = o.coreMLModel else {
            FileHandle.standardError.write(Data("--coreml-model is required for backend=coreml\n".utf8))
            exit(2)
        }
        return try await CoreMLEnricher(
            modelPath: path,
            units: o.coreMLUnits,
            profile: "bench.coreml.\(o.coreMLUnits)",
            tokenizerFolder: o.coreMLTokenizer,
            logger: logger
        )
    default:
        FileHandle.standardError.write(Data("Unknown backend: \(o.backend)\n".utf8))
        exit(2)
    }
}

@main
struct ClaudeMindBenchApp {
    static func main() async throws {
        let o = parseArgs()
        let logger = Logger(label: "claude-mind-bench")

        let corpus = loadCorpus(o.corpusFile)
        FileHandle.standardError.write(Data("corpus_size=\(corpus.count)\n".utf8))

        // Cold init.
        let initStart = Date()
        let enricher = try await makeEnricher(o, logger: logger)
        let initMs = Date().timeIntervalSince(initStart) * 1000
        FileHandle.standardError.write(Data("init_ms=\(Int(initMs)) backend=\(enricher.backend) dim=\(enricher.dimension)\n".utf8))

        let storeURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("bench-\(UUID().uuidString).sqlite")
        let store = try makeStore(at: storeURL, logger: logger)

        // Cold first embed.
        let coldStart = Date()
        _ = try await enricher.embed(text: corpus[0])
        let coldMs = Date().timeIntervalSince(coldStart) * 1000

        // Warm embed loop.
        var embedSamples: [Double] = []
        for _ in 0..<o.repeats {
            let chunkSamples = await runEmbed(enricher: enricher, corpus: corpus, concurrency: o.concurrency)
            embedSamples.append(contentsOf: chunkSamples)
        }

        // Remember loop (full path).
        var rememberSamples: [Double] = []
        if !o.skipRemember {
            for _ in 0..<o.repeats {
                let chunkSamples = await runRemember(store: store, enricher: enricher, corpus: corpus, concurrency: o.concurrency)
                rememberSamples.append(contentsOf: chunkSamples)
            }
        }

        let report = Report(
            backend: enricher.backend,
            profile: enricher.profile,
            dimension: enricher.dimension,
            corpus_size: corpus.count,
            repeats: o.repeats,
            concurrency: o.concurrency,
            init_ms: initMs,
            cold_first_embed_ms: coldMs,
            embed: LatencyStats.from(embedSamples),
            remember: o.skipRemember ? nil : LatencyStats.from(rememberSamples)
        )

        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try enc.encode(report)
        if let outPath = o.outFile {
            try data.write(to: URL(fileURLWithPath: outPath))
            FileHandle.standardError.write(Data("wrote \(outPath)\n".utf8))
        } else {
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
        }

        try? FileManager.default.removeItem(at: storeURL)
        try? FileManager.default.removeItem(at: storeURL.appendingPathExtension("shm"))
        try? FileManager.default.removeItem(at: storeURL.appendingPathExtension("wal"))
    }

    static func runEmbed(enricher: any Enricher, corpus: [String], concurrency: Int) async -> [Double] {
        if concurrency <= 1 {
            var samples: [Double] = []
            for text in corpus {
                let t0 = Date()
                _ = try? await enricher.embed(text: text)
                samples.append(Date().timeIntervalSince(t0) * 1000)
            }
            return samples
        }
        // Limited-concurrency batches.
        var samples: [Double] = []
        var index = 0
        while index < corpus.count {
            let end = min(index + concurrency, corpus.count)
            let slice = Array(corpus[index..<end])
            let chunk = await withTaskGroup(of: Double.self) { group in
                for text in slice {
                    group.addTask {
                        let t0 = Date()
                        _ = try? await enricher.embed(text: text)
                        return Date().timeIntervalSince(t0) * 1000
                    }
                }
                var out: [Double] = []
                for await ms in group { out.append(ms) }
                return out
            }
            samples.append(contentsOf: chunk)
            index = end
        }
        return samples
    }

    static func runRemember(store: MemoryStore, enricher: any Enricher, corpus: [String], concurrency: Int) async -> [Double] {
        if concurrency <= 1 {
            var samples: [Double] = []
            for text in corpus {
                let t0 = Date()
                do {
                    let signal = try await enricher.enrich(text: text)
                    _ = try await store.remember(draft: MemoryDraft(text: text), signal: signal)
                } catch {
                    // skip on error
                }
                samples.append(Date().timeIntervalSince(t0) * 1000)
            }
            return samples
        }
        var samples: [Double] = []
        var index = 0
        while index < corpus.count {
            let end = min(index + concurrency, corpus.count)
            let slice = Array(corpus[index..<end])
            let chunk = await withTaskGroup(of: Double.self) { group in
                for text in slice {
                    group.addTask {
                        let t0 = Date()
                        do {
                            let signal = try await enricher.enrich(text: text)
                            _ = try await store.remember(draft: MemoryDraft(text: text), signal: signal)
                        } catch { }
                        return Date().timeIntervalSince(t0) * 1000
                    }
                }
                var out: [Double] = []
                for await ms in group { out.append(ms) }
                return out
            }
            samples.append(contentsOf: chunk)
            index = end
        }
        return samples
    }
}

struct Report: Codable {
    let backend: String
    let profile: String
    let dimension: Int
    let corpus_size: Int
    let repeats: Int
    let concurrency: Int
    let init_ms: Double
    let cold_first_embed_ms: Double
    let embed: LatencyStats
    let remember: LatencyStats?
}
