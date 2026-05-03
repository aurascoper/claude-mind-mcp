import Foundation

struct LatencyStats: Codable {
    let count: Int
    let mean_ms: Double
    let p50_ms: Double
    let p95_ms: Double
    let p99_ms: Double
    let max_ms: Double
    let min_ms: Double
    let stdev_ms: Double

    static func from(_ samples: [Double]) -> LatencyStats {
        guard !samples.isEmpty else {
            return .init(count: 0, mean_ms: 0, p50_ms: 0, p95_ms: 0, p99_ms: 0, max_ms: 0, min_ms: 0, stdev_ms: 0)
        }
        let sorted = samples.sorted()
        let n = sorted.count
        let mean = sorted.reduce(0, +) / Double(n)
        let variance = sorted.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(n)
        func pct(_ p: Double) -> Double {
            let idx = min(n - 1, max(0, Int((Double(n - 1) * p).rounded())))
            return sorted[idx]
        }
        return .init(
            count: n,
            mean_ms: mean,
            p50_ms: pct(0.50),
            p95_ms: pct(0.95),
            p99_ms: pct(0.99),
            max_ms: sorted.last!,
            min_ms: sorted.first!,
            stdev_ms: variance.squareRoot()
        )
    }
}

func timeMillis(_ block: () async throws -> Void) async rethrows -> Double {
    let t0 = Date()
    try await block()
    return Date().timeIntervalSince(t0) * 1000
}
