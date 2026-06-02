import Foundation

public struct BenchmarkComparison: Sendable {
    public let name: String
    public let measured: BenchmarkResult
    public let baseline: BenchmarkResult
    public let maximumRatio: Double
    public let requirement: String

    public var ratio: Double {
        measured.medianSecondsPerIteration / baseline.medianSecondsPerIteration
    }

    public var passed: Bool {
        ratio < maximumRatio
    }

    public var summary: String {
        let status = passed ? "PASS" : "FAIL"
        return "\(status) \(name): ratio=\(format(ratio)) limit=\(format(maximumRatio))"
    }

    public var failureMessage: String {
        "\(name) ratio \(format(ratio)) exceeded limit \(format(maximumRatio)): \(requirement)"
    }

    private func format(_ value: Double) -> String {
        String(format: "%.3f", value)
    }
}
