public enum CoreSpiceBenchmarkSuite {
    public static func run() throws -> BenchmarkSuiteReport {
        let comparisons = [
            try WaveformBenchmarkOperations.lazyProjectionComparison(),
            try WaveformBenchmarkOperations.projectedRowMajorScanComparison(),
            try WaveformBenchmarkOperations.borrowedPointScanComparison(),
            try WaveformBenchmarkOperations.transientConversionComparison(),
            try BehavioralSourceBenchmarkOperations.linearStampComparison()
        ]
        return BenchmarkSuiteReport(comparisons: comparisons)
    }
}
