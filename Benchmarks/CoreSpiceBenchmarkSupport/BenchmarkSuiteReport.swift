public struct BenchmarkSuiteReport: Sendable {
    public let comparisons: [BenchmarkComparison]

    public var passed: Bool {
        comparisons.allSatisfy(\.passed)
    }

    public var failureMessages: [String] {
        comparisons.filter { !$0.passed }.map(\.failureMessage)
    }
}
