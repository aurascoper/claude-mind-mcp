import Foundation

public enum EmbeddingCodec {
    public static func encode(_ vector: [Float]) -> Data {
        var copy = vector
        return copy.withUnsafeMutableBufferPointer { buf in
            Data(buffer: buf)
        }
    }

    public static func decode(_ data: Data) -> [Float] {
        let count = data.count / MemoryLayout<Float>.size
        guard count > 0 else { return [] }
        return data.withUnsafeBytes { raw -> [Float] in
            guard let base = raw.bindMemory(to: Float.self).baseAddress else { return [] }
            return Array(UnsafeBufferPointer(start: base, count: count))
        }
    }

    public static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0
        var na: Float = 0
        var nb: Float = 0
        for i in 0..<a.count {
            dot += a[i] * b[i]
            na  += a[i] * a[i]
            nb  += b[i] * b[i]
        }
        let denom = (na.squareRoot()) * (nb.squareRoot())
        return denom > 0 ? dot / denom : 0
    }
}
