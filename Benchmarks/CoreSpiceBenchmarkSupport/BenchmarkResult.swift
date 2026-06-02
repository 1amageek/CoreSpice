import Foundation

public struct BenchmarkResult: Sendable, CustomStringConvertible {
    public let name: String
    public let iterationsPerSample: Int
    public let sampleSeconds: [Double]
    public let checksum: Double

    public var minimumSecondsPerIteration: Double {
        (sampleSeconds.min() ?? 0.0) / Double(iterationsPerSample)
    }

    public var medianSecondsPerIteration: Double {
        median(sampleSeconds) / Double(iterationsPerSample)
    }

    public var maximumSecondsPerIteration: Double {
        (sampleSeconds.max() ?? 0.0) / Double(iterationsPerSample)
    }

    public var description: String {
        let medianMicroseconds = medianSecondsPerIteration * 1_000_000.0
        let minimumMicroseconds = minimumSecondsPerIteration * 1_000_000.0
        let maximumMicroseconds = maximumSecondsPerIteration * 1_000_000.0
        return "\(name): median=\(format(medianMicroseconds))us/op min=\(format(minimumMicroseconds))us/op max=\(format(maximumMicroseconds))us/op checksum=\(format(checksum))"
    }

    private func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0.0 }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) / 2.0
        }
        return sorted[middle]
    }

    private func format(_ value: Double) -> String {
        String(format: "%.3f", value)
    }
}
