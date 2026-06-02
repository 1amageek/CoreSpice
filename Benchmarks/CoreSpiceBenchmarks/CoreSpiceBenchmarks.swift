import CoreSpiceBenchmarkSupport

@main
enum CoreSpiceBenchmarks {
    static func main() throws {
        let enforcePerformanceThresholds = CommandLine.arguments.dropFirst().contains("--enforce")
        let report = try CoreSpiceBenchmarkSuite.run()
        print("")
        for comparison in report.comparisons {
            print(comparison.summary)
        }

        if !enforcePerformanceThresholds, !report.passed {
            print("")
            print("Performance thresholds were not enforced. Re-run with --enforce to return a non-zero status for threshold failures.")
        }

        guard !enforcePerformanceThresholds || report.passed else {
            throw BenchmarkFailure(messages: report.failureMessages)
        }
    }
}

struct BenchmarkFailure: Error, CustomStringConvertible {
    let messages: [String]

    var description: String {
        messages.joined(separator: "\n")
    }
}
