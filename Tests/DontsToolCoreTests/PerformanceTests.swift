import Foundation
import Testing
@testable import DontsToolCore

@Suite("Performance")
struct PerformanceTests {
    /// 合成基准：5000 个应用名 × 1000 次评分，输出 p50/p95（仅记录，不设硬阈值）。
    @Test func fuzzyMatchingBenchmark() {
        let names = (0..<5000).map { "Application \($0) Studio Pro" }
        let queries = (0..<1000).map { "app\($0 % 97)" }

        var durations: [Double] = []
        durations.reserveCapacity(queries.count)
        for query in queries {
            let start = ContinuousClock.Instant.now
            var total = 0.0
            for name in names {
                total += FuzzyMatcher.score(query: query, candidate: name) ?? 0
            }
            _ = total
            durations.append(Performance.milliseconds(since: start))
        }

        durations.sort()
        let p50 = durations[durations.count / 2]
        let p95 = durations[Int(Double(durations.count) * 0.95)]
        print("benchmark fuzzy: 5000 candidates × 1000 queries, p50=\(p50)ms p95=\(p95)ms")
        #expect(p95 < 500, "模糊评分明显退化，请检查实现")
    }
}
