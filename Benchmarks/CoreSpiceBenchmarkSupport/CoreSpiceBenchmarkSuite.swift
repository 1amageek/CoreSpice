public enum CoreSpiceBenchmarkSuite {
    public static func run() throws -> BenchmarkSuiteReport {
        let comparisons = [
            try WaveformBenchmarkOperations.lazyProjectionComparison(),
            try WaveformBenchmarkOperations.borrowedPointScanComparison(),
            try WaveformBenchmarkOperations.transientConversionComparison()
        ]
        return BenchmarkSuiteReport(comparisons: comparisons)
    }
}
