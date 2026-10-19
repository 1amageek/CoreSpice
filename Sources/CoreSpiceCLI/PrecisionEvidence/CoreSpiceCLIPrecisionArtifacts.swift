import CoreSpiceIO
import Foundation

extension CoreSpiceCLIOSDIExecutionRecord {
    func pairedCSVRecord() throws -> CoreSpiceCLIPairedCSVRecord {
        guard let precision else { throw CoreSpiceCLIOSDIError.unsupportedAnalysis("paired CSV requires explicit precision transient input") }
        let selected: [Int]
        if projection == nil, !projectedColumns.isEmpty {
            selected = try projectedColumns.map { column in
                guard let row = columns[column].compiledRow else { throw CoreSpiceCLIOSDIError.incompleteReceipt("Canonical projection row is absent") }; return row
            }
        } else { selected = Array(rows.indices) }
        if selected == Array(rows.indices) {
            return try .init(configurationSHA256: precision.configurationSHA256, sourceRowCount: rows.count,
                compiledRows: selected, times: coordinates, high: real, low: precision.solutionLow)
        }
        var high: [Double] = [], low: [Double] = []
        high.reserveCapacity(coordinates.count * selected.count); low.reserveCapacity(coordinates.count * selected.count)
        for point in coordinates.indices {
            try Task.checkCancellation()
            for row in selected { high.append(real[point * rows.count + row]); low.append(precision.solutionLow[point * rows.count + row]) }
        }
        return try .init(configurationSHA256: precision.configurationSHA256, sourceRowCount: rows.count,
            compiledRows: selected, times: coordinates, high: high, low: low)
    }

    func savePairedCSV(path: String) throws {
        guard let precision else { throw CoreSpiceCLIOSDIError.unsupportedAnalysis("paired CSV requires explicit precision transient input") }
        let count = try CoreSpiceCLIPrecisionExecution.multiply(UInt64(coordinates.count), UInt64(rows.count))
        let upper = try CoreSpiceCLIPrecisionExecution.add(65536, CoreSpiceCLIPrecisionExecution.multiply(count, 384))
        try precision.withSerialization(upperBound: upper) {
            let record = try pairedCSVRecord()
            let limits = try CoreSpiceCLIPairedCSVCodec.Limits(maximumBytes: precision.executionBudget.maximumEvidenceBytes,
                maximumPoints: settingsPointLimit(precision), maximumColumns: rows.count,
                maximumScalars: min(3_000_000, Int(precision.executionBudget.maximumEvidenceBytes / 8)))
            let bytes = try CoreSpiceCLIPairedCSVCodec.encode(record, limits: limits)
            try comparePaired(CoreSpiceCLIPairedCSVCodec.decode(bytes, limits: limits), original: record)
            try bytes.write(to: URL(fileURLWithPath: path), options: .atomic)
            do {
                let saved = try LocalSPICESourceReader().read(at: path,
                    maximumByteCount: precision.executionBudget.maximumEvidenceBytes, maximumPageByteCount: 4096)
                try comparePaired(CoreSpiceCLIPairedCSVCodec.decode(saved, limits: limits), original: record)
            } catch {
                do { try FileManager.default.removeItem(atPath: path) }
                catch let cleanup { throw CoreSpiceCLIOSDIError.incompleteReceipt("Paired CSV verification failed: \(error); cleanup failed: \(cleanup)") }
                throw error
            }
        }
    }
    private func settingsPointLimit(_ precision: CoreSpiceCLIPrecisionExecution) -> Int {
        min(999_999, precision.settings.numericalLimits.maximumAcceptedSteps) + 1
    }
    private func comparePaired(_ decoded: CoreSpiceCLIPairedCSVRecord, original: CoreSpiceCLIPairedCSVRecord) throws {
        guard decoded.configurationSHA256 == original.configurationSHA256, decoded.sourceRowCount == original.sourceRowCount,
              decoded.compiledRows == original.compiledRows, decoded.times.map(\.bitPattern) == original.times.map(\.bitPattern),
              decoded.high.map(\.bitPattern) == original.high.map(\.bitPattern), decoded.low.map(\.bitPattern) == original.low.map(\.bitPattern) else {
            throw CoreSpiceCLIOSDIError.incompleteReceipt("Paired CSV differs from authoritative complete JSON coordinates")
        }
    }
}
