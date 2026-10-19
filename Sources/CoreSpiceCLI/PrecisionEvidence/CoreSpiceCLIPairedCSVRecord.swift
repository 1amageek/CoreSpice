import CoreSpiceDevices

/// Canonical paired transient coordinates, independent of rounded display projections.
struct CoreSpiceCLIPairedCSVRecord: Sendable {
    let schemaVersion = 1
    let configurationSHA256: String
    let sourceRowCount: Int
    let compiledRows: [Int]
    let times: [Double]
    /// Point-major components in compiledRows order.
    let high: [Double]
    let low: [Double]
    var pointCount: Int { times.count }

    init(configurationSHA256: String, sourceRowCount: Int, compiledRows: [Int],
         times: [Double], high: [Double], low: [Double]) throws {
        guard configurationSHA256.utf8.count == 64,
              configurationSHA256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw CoreSpiceCLIPairedCSVCodec.Error.invalidConfiguration
        }
        guard sourceRowCount > 0, !compiledRows.isEmpty,
              compiledRows.count <= sourceRowCount,
              compiledRows.allSatisfy({ (0..<sourceRowCount).contains($0) }),
              Set(compiledRows).count == compiledRows.count else {
            throw CoreSpiceCLIPairedCSVCodec.Error.invalidRowMap
        }
        let (count, overflow) = times.count.multipliedReportingOverflow(by: compiledRows.count)
        guard !times.isEmpty, !overflow, high.count == count, low.count == count else {
            throw CoreSpiceCLIPairedCSVCodec.Error.invalidCounts
        }
        for index in times.indices {
            guard times[index].isFinite, times[index] >= 0,
                  index == 0 || times[index] > times[index - 1] else {
                throw CoreSpiceCLIPairedCSVCodec.Error.invalidTime(point: index)
            }
        }
        for index in high.indices {
            do { _ = try CompensatedValue(high: high[index], low: low[index]) }
            catch { throw CoreSpiceCLIPairedCSVCodec.Error.invalidPair(sample: index) }
        }
        self.configurationSHA256 = configurationSHA256; self.sourceRowCount = sourceRowCount
        self.compiledRows = compiledRows; self.times = times; self.high = high; self.low = low
    }
}
