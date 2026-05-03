import Foundation
import CoreML
import NaturalLanguage
import Logging
import Tokenizers

@available(macOS 14.0, *)
public actor CoreMLEnricher: Enricher {
    public nonisolated let backend: String
    public nonisolated let profile: String
    public nonisolated let dimension: Int

    private nonisolated(unsafe) let model: MLModel
    private let mode: InputMode
    private let outputName: String
    private let outputIsSequence: Bool
    private let language: NLLanguage
    private let logger: Logger

    enum InputMode {
        case singleString(name: String)
        case tokenized(idsName: String, maskName: String, seqLen: Int, tokenizer: any Tokenizer, padTokenId: Int)
    }

    public init(
        modelPath: String,
        units: String,
        profile: String,
        tokenizerFolder: String? = nil,
        language: NLLanguage = .english,
        logger: Logger
    ) async throws {
        let config = MLModelConfiguration()
        switch units {
        case "cpu":     config.computeUnits = .cpuOnly
        case "cpu+ane": config.computeUnits = .cpuAndNeuralEngine
        case "all":     config.computeUnits = .all
        default:        config.computeUnits = .all
        }

        let url = URL(fileURLWithPath: modelPath)
        let modelURL: URL
        if modelPath.hasSuffix(".mlmodelc") {
            modelURL = url
        } else {
            modelURL = try await MLModel.compileModel(at: url)
        }
        let model = try MLModel(contentsOf: modelURL, configuration: config)
        let desc = model.modelDescription

        // Decide input mode.
        let inputs = desc.inputDescriptionsByName
        let mode: InputMode
        if let ids = inputs["input_ids"], let mask = inputs["attention_mask"],
           ids.type == .multiArray, mask.type == .multiArray {
            guard let folder = tokenizerFolder else {
                throw NSError(domain: "CoreMLEnricher", code: 10,
                              userInfo: [NSLocalizedDescriptionKey: "Model has token inputs but no tokenizerFolder was provided"])
            }
            let seqLen = ids.multiArrayConstraint?.shape.last?.intValue ?? 0
            guard seqLen > 0 else {
                throw NSError(domain: "CoreMLEnricher", code: 11,
                              userInfo: [NSLocalizedDescriptionKey: "Could not determine seq_len from input_ids shape"])
            }
            let tokenizer = try await AutoTokenizer.from(modelFolder: URL(fileURLWithPath: folder))
            let pad = tokenizer.eosTokenId ?? 0
            mode = .tokenized(idsName: "input_ids", maskName: "attention_mask", seqLen: seqLen, tokenizer: tokenizer, padTokenId: pad)
            logger.info("CoreMLEnricher: token-input mode seq_len=\(seqLen) tokenizer=\(folder)")
        } else if let stringInput = inputs.first(where: { $0.value.type == .string })?.key {
            mode = .singleString(name: stringInput)
            logger.info("CoreMLEnricher: single-string-input mode input=\(stringInput)")
        } else {
            throw NSError(domain: "CoreMLEnricher", code: 12,
                          userInfo: [NSLocalizedDescriptionKey: "Unsupported input shape; expected string OR (input_ids+attention_mask)"])
        }

        // Pick output. Prefer multiArray outputs.
        let outputs = desc.outputDescriptionsByName
        let outName: String
        if let arrayOutput = outputs.first(where: { $0.value.type == .multiArray })?.key {
            outName = arrayOutput
        } else if let first = outputs.keys.first {
            outName = first
        } else {
            throw NSError(domain: "CoreMLEnricher", code: 13,
                          userInfo: [NSLocalizedDescriptionKey: "Model has no outputs"])
        }

        let outShape = outputs[outName]?.multiArrayConstraint?.shape.map { $0.intValue } ?? []
        // Conventions:
        //   shape (1, hidden)        -> already-pooled embedding; use as-is
        //   shape (1, seq, hidden)   -> per-token; mean-pool with attention_mask
        let isSequence = outShape.count >= 3
        let dim: Int
        if isSequence {
            dim = outShape.last ?? 0
        } else {
            dim = outShape.last ?? 0
        }

        let devices = MLModel.availableComputeDevices
        logger.info("CoreMLEnricher: units=\(units) model=\(modelPath) out=\(outName) shape=\(outShape) seq_pooled=\(isSequence) dim=\(dim) devices=\(devices.map { String(describing: $0) })")

        self.model = model
        self.mode = mode
        self.outputName = outName
        self.outputIsSequence = isSequence
        self.profile = profile
        self.dimension = dim
        self.backend = "CoreML(\(units))"
        self.language = language
        self.logger = logger
    }

    public func embed(text: String) async throws -> [Float]? {
        switch mode {
        case .singleString(let name):
            let provider = try MLDictionaryFeatureProvider(dictionary: [name: text])
            let result = try await model.prediction(from: provider)
            guard let arr = result.featureValue(for: outputName)?.multiArrayValue else { return nil }
            return Self.flatten(multiArray: arr, isSequence: outputIsSequence, mask: nil, dim: dimension)

        case .tokenized(let idsName, let maskName, let seqLen, let tokenizer, let padTokenId):
            let raw = tokenizer.encode(text: text)
            let truncated = Array(raw.prefix(seqLen))
            let padded   = truncated + Array(repeating: padTokenId, count: max(0, seqLen - truncated.count))
            let mask     = Array(repeating: Int32(1), count: truncated.count) + Array(repeating: Int32(0), count: max(0, seqLen - truncated.count))
            let ids32    = padded.map { Int32($0) }

            let idsArr = try MLMultiArray(shape: [1, NSNumber(value: seqLen)], dataType: .int32)
            let maskArr = try MLMultiArray(shape: [1, NSNumber(value: seqLen)], dataType: .int32)
            ids32.withUnsafeBufferPointer { src in
                let dst = idsArr.dataPointer.bindMemory(to: Int32.self, capacity: seqLen)
                for i in 0..<seqLen { dst[i] = src[i] }
            }
            mask.withUnsafeBufferPointer { src in
                let dst = maskArr.dataPointer.bindMemory(to: Int32.self, capacity: seqLen)
                for i in 0..<seqLen { dst[i] = src[i] }
            }

            let provider = try MLDictionaryFeatureProvider(dictionary: [
                idsName: MLFeatureValue(multiArray: idsArr),
                maskName: MLFeatureValue(multiArray: maskArr)
            ])
            let result = try await model.prediction(from: provider)
            guard let arr = result.featureValue(for: outputName)?.multiArrayValue else { return nil }
            return Self.flatten(multiArray: arr, isSequence: outputIsSequence, mask: mask, dim: dimension)
        }
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

    /// Flatten an MLMultiArray to a Float32 vector.
    /// - For pooled outputs (shape ~ [B, H]): copy as-is.
    /// - For per-token outputs (shape ~ [B, S, H]): mean-pool over S using `mask` (1/0 per token).
    /// L2-normalizes the result.
    private static func flatten(multiArray arr: MLMultiArray, isSequence: Bool, mask: [Int32]?, dim: Int) -> [Float] {
        let shape = arr.shape.map { $0.intValue }
        if !isSequence {
            // Just copy.
            let count = arr.count
            var out = [Float](repeating: 0, count: count)
            switch arr.dataType {
            case .float32:
                let p = arr.dataPointer.bindMemory(to: Float.self, capacity: count)
                out = Array(UnsafeBufferPointer(start: p, count: count))
            case .float64:
                let p = arr.dataPointer.bindMemory(to: Double.self, capacity: count)
                for i in 0..<count { out[i] = Float(p[i]) }
            default:
                for i in 0..<count { out[i] = Float(truncating: arr[i]) }
            }
            return l2Normalize(&out)
        }

        // Sequence output: shape = [B, S, H], assume B=1.
        guard shape.count >= 3 else { return [] }
        let seq = shape[shape.count - 2]
        let hidden = shape[shape.count - 1]

        var sum = [Double](repeating: 0, count: hidden)
        var count: Double = 0

        // Strides via row-major. For float32 with B=1, byte offset = (s * hidden + h) * 4.
        switch arr.dataType {
        case .float32:
            let p = arr.dataPointer.bindMemory(to: Float.self, capacity: seq * hidden)
            for s in 0..<seq {
                let m = mask?[s] ?? 1
                if m == 0 { continue }
                let base = s * hidden
                for h in 0..<hidden { sum[h] += Double(p[base + h]) }
                count += 1
            }
        case .float64:
            let p = arr.dataPointer.bindMemory(to: Double.self, capacity: seq * hidden)
            for s in 0..<seq {
                let m = mask?[s] ?? 1
                if m == 0 { continue }
                let base = s * hidden
                for h in 0..<hidden { sum[h] += p[base + h] }
                count += 1
            }
        default:
            for s in 0..<seq {
                let m = mask?[s] ?? 1
                if m == 0 { continue }
                for h in 0..<hidden {
                    sum[h] += Double(truncating: arr[[0, NSNumber(value: s), NSNumber(value: h)]])
                }
                count += 1
            }
        }

        if count == 0 { return [] }
        let inv = 1.0 / count
        var out = sum.map { Float($0 * inv) }
        return l2Normalize(&out)
    }

    private static func l2Normalize(_ v: inout [Float]) -> [Float] {
        var n: Float = 0
        for x in v { n += x * x }
        let nrm = n.squareRoot()
        if nrm > 0 { for i in 0..<v.count { v[i] /= nrm } }
        return v
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
