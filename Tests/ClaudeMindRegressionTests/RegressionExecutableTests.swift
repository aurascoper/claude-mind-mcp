import Foundation
import XCTest

final class RegressionExecutableTests: XCTestCase {
    func testRegressionExecutable() throws {
        let executable = try regressionExecutableURL()
        let process = Process()
        let output = Pipe()
        process.executableURL = executable
        process.standardOutput = output
        process.standardError = output

        try process.run()
        process.waitUntilExit()
        let transcript = String(
            data: output.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""

        XCTAssertEqual(
            process.terminationStatus,
            0,
            "claude-mind-regression failed:\n\(transcript)"
        )
        let actualCount = try regressionPassCount(in: transcript)
        let expectedCount = try expectedRegressionCount()
        XCTAssertEqual(
            actualCount,
            expectedCount,
            "regression suite count changed from the \(expectedCount)-check fixture:\n\(transcript)"
        )
    }

    private func regressionPassCount(in transcript: String) throws -> Int {
        let expression = try NSRegularExpression(
            pattern: #"regression: ([0-9]+) passed, 0 failed"#
        )
        let fullRange = NSRange(transcript.startIndex..., in: transcript)
        guard
            let match = expression.firstMatch(in: transcript, range: fullRange),
            let countRange = Range(match.range(at: 1), in: transcript),
            let count = Int(transcript[countRange])
        else {
            throw RegressionHarnessError.invalidSummary
        }
        return count
    }

    private func expectedRegressionCount() throws -> Int {
        guard
            let fixture = Bundle.module.url(
                forResource: "expected-regression-count",
                withExtension: "txt",
                subdirectory: "Fixtures"
            ),
            let count = Int(try String(contentsOf: fixture, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)),
            count > 0
        else {
            throw RegressionHarnessError.invalidExpectedCountFixture
        }
        return count
    }

    private func regressionExecutableURL() throws -> URL {
        let fileManager = FileManager.default
        let names = ["claude-mind-regression", "claude-mind-regression.exe"]
        var directory = Bundle(for: RegressionExecutableTests.self).bundleURL

        for _ in 0..<6 {
            directory.deleteLastPathComponent()
            for name in names {
                let candidate = directory.appendingPathComponent(name)
                if fileManager.isExecutableFile(atPath: candidate.path) {
                    return candidate
                }
            }
        }

        throw RegressionHarnessError.executableNotFound
    }
}

private enum RegressionHarnessError: Error {
    case executableNotFound
    case invalidExpectedCountFixture
    case invalidSummary
}
