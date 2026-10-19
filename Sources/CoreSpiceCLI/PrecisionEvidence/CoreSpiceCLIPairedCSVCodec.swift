import Foundation

/// Versioned numeric CSV for original high/low components; ordinary display CSV is separate.
enum CoreSpiceCLIPairedCSVCodec {
    enum Error: Swift.Error, Equatable, Sendable {
        case invalidLimits
        case limitExceeded
        case invalidConfiguration
        case invalidCounts
        case invalidRowMap
        case invalidTime(point: Int)
        case invalidPair(sample: Int)
        case invalidUTF8
        case invalidSyntax(line: Int)
        case unsupportedSchema
        case bitPatternMismatch(line: Int)
        case unexpectedRecord(line: Int)
    }

    struct Limits: Sendable {
        let maximumBytes: UInt64
        let maximumPoints: Int
        let maximumColumns: Int
        let maximumScalars: Int

        init(maximumBytes: UInt64, maximumPoints: Int, maximumColumns: Int, maximumScalars: Int) throws {
            guard maximumBytes > 0, maximumBytes <= UInt64(Int.max), maximumPoints > 0,
                  maximumColumns > 0, maximumColumns < Int.max, maximumScalars > 0 else { throw Error.invalidLimits }
            self.maximumBytes = maximumBytes; self.maximumPoints = maximumPoints
            self.maximumColumns = maximumColumns; self.maximumScalars = maximumScalars
        }
    }

    private static let header = ["point_index", "time", "time_bits", "column_index", "compiled_row",
                                 "high", "high_bits", "low", "low_bits"]

    private static func admit(points: Int, sourceRows: Int, columns: Int, limits: Limits,
                              availableBytes: UInt64? = nil) throws -> Int {
        guard points > 0, sourceRows > 0, columns > 0, columns <= sourceRows else { throw Error.invalidCounts }
        guard points <= limits.maximumPoints, sourceRows <= limits.maximumColumns,
              columns <= limits.maximumColumns else { throw Error.limitExceeded }
        let (samples, first) = points.multipliedReportingOverflow(by: columns)
        let (components, second) = samples.multipliedReportingOverflow(by: 2)
        let (scalars, third) = components.addingReportingOverflow(points)
        guard !first, !second, !third, scalars <= limits.maximumScalars else { throw Error.limitExceeded }
        // Each data record needs at least nine one-byte fields, eight commas and LF.
        let (minimumRows, fourth) = UInt64(samples).multipliedReportingOverflow(by: 18)
        let (minimumMap, fifth) = UInt64(columns).multipliedReportingOverflow(by: 2)
        let (minimum, sixth) = minimumRows.addingReportingOverflow(minimumMap)
        guard !fourth, !fifth, !sixth, minimum <= (availableBytes ?? limits.maximumBytes) else { throw Error.limitExceeded }
        return samples
    }

    static func encode(_ record: CoreSpiceCLIPairedCSVRecord, limits: Limits) throws -> Data {
        let samples = try admit(points: record.pointCount, sourceRows: record.sourceRowCount,
            columns: record.compiledRows.count, limits: limits)
        var result = Data()
        func append(_ fields: [String]) throws {
            guard fields.allSatisfy({ $0.utf8.count <= 64 }) else { throw Error.limitExceeded }
            let line = fields.joined(separator: ",") + "\n"
            guard UInt64(line.utf8.count) <= limits.maximumBytes - UInt64(result.count) else { throw Error.limitExceeded }
            result.append(contentsOf: line.utf8)
        }
        try append(["corespice-paired-csv", "1", record.configurationSHA256, String(record.pointCount),
                    String(record.sourceRowCount), String(record.compiledRows.count)])
        var mapBytes = UInt64("compiled_rows".utf8.count + 1)
        for row in record.compiledRows {
            var value = row, digits = 1
            while value >= 10 { value /= 10; digits += 1 }
            let (next, overflow) = mapBytes.addingReportingOverflow(UInt64(digits + 1))
            guard !overflow else { throw Error.limitExceeded }
            mapBytes = next
        }
        guard mapBytes <= limits.maximumBytes - UInt64(result.count) else { throw Error.limitExceeded }
        try append(["compiled_rows"] + record.compiledRows.map(String.init))
        try append(header)
        for sample in 0..<samples {
            let point = sample / record.compiledRows.count, column = sample % record.compiledRows.count
            let time = record.times[point], high = record.high[sample], low = record.low[sample]
            try append([String(point), String(time), String(time.bitPattern), String(column),
                        String(record.compiledRows[column]), String(high), String(high.bitPattern),
                        String(low), String(low.bitPattern)])
        }
        return result
    }

    static func decode(_ bytes: Data, limits: Limits) throws -> CoreSpiceCLIPairedCSVRecord {
        guard UInt64(bytes.count) <= limits.maximumBytes else { throw Error.limitExceeded }
        guard let text = String(data: bytes, encoding: .utf8) else { throw Error.invalidUTF8 }
        var remaining = text[...], lineNumber = 0
        func nextLine() -> Substring? {
            guard !remaining.isEmpty else { return nil }
            let line: Substring
            // CRLF is one Character; find its LF code unit and slice outside the complete grapheme.
            if let end = remaining.utf8.firstIndex(of: 10) {
                var contentEnd = end
                if end != remaining.startIndex {
                    let prior = remaining.utf8.index(before: end)
                    if remaining.utf8[prior] == 13 { contentEnd = prior }
                }
                line = remaining[..<contentEnd]
                remaining = remaining[remaining.utf8.index(after: end)...]
            } else {
                line = remaining.hasSuffix("\r") ? remaining.dropLast() : remaining
                remaining = remaining[remaining.endIndex...]
            }
            lineNumber += 1
            return line
        }
        func fields(_ expected: Int) throws -> [Substring] {
            guard var line = nextLine() else { throw Error.unexpectedRecord(line: lineNumber + 1) }
            var fields: [Substring] = []; fields.reserveCapacity(expected)
            while true {
                guard fields.count < expected else { throw Error.invalidSyntax(line: lineNumber) }
                let end = line.firstIndex(of: ",") ?? line.endIndex
                let field = line[..<end]
                guard !field.isEmpty, field.utf8.count <= 64 else { throw Error.invalidSyntax(line: lineNumber) }
                fields.append(field)
                if end == line.endIndex { break }
                line = line[line.index(after: end)...]
            }
            guard fields.count == expected else { throw Error.invalidSyntax(line: lineNumber) }
            return fields
        }
        func integer(_ text: Substring) throws -> Int {
            guard text.utf8.allSatisfy({ (48...57).contains($0) }), let value = Int(text) else {
                throw Error.invalidSyntax(line: lineNumber)
            }
            return value
        }
        func number(_ text: Substring, bits: Substring) throws -> Double {
            guard let value = Double(text), value.isFinite, bits.utf8.allSatisfy({ (48...57).contains($0) }),
                  let bitPattern = UInt64(bits) else { throw Error.invalidSyntax(line: lineNumber) }
            guard value.bitPattern == bitPattern else { throw Error.bitPatternMismatch(line: lineNumber) }
            return value
        }
        let preamble = try fields(6)
        guard preamble[0] == "corespice-paired-csv", preamble[1] == "1" else { throw Error.unsupportedSchema }
        let configuration = String(preamble[2])
        let points = try integer(preamble[3]), sourceRows = try integer(preamble[4]), columns = try integer(preamble[5])
        let samples = try admit(points: points, sourceRows: sourceRows, columns: columns, limits: limits,
            availableBytes: UInt64(bytes.count))
        let map = try fields(columns + 1)
        guard map[0] == "compiled_rows" else { throw Error.invalidRowMap }
        let compiledRows = try map.dropFirst().map { try integer($0) }
        guard compiledRows.allSatisfy({ (0..<sourceRows).contains($0) }), Set(compiledRows).count == columns else {
            throw Error.invalidRowMap
        }
        let columnsHeader = try fields(header.count)
        guard zip(columnsHeader, header).allSatisfy({ $0 == $1 }) else { throw Error.invalidSyntax(line: lineNumber) }
        var times: [Double] = [], high: [Double] = [], low: [Double] = []
        times.reserveCapacity(points); high.reserveCapacity(samples); low.reserveCapacity(samples)
        for sample in 0..<samples {
            let row = try fields(9), point = sample / columns, column = sample % columns
            guard try integer(row[0]) == point, try integer(row[3]) == column,
                  try integer(row[4]) == compiledRows[column] else { throw Error.unexpectedRecord(line: lineNumber) }
            let time = try number(row[1], bits: row[2])
            if column == 0 { times.append(time) }
            else if time.bitPattern != times[point].bitPattern { throw Error.bitPatternMismatch(line: lineNumber) }
            high.append(try number(row[5], bits: row[6])); low.append(try number(row[7], bits: row[8]))
        }
        guard nextLine() == nil else { throw Error.unexpectedRecord(line: lineNumber) }
        return try CoreSpiceCLIPairedCSVRecord(configurationSHA256: configuration, sourceRowCount: sourceRows,
            compiledRows: compiledRows, times: times, high: high, low: low)
    }
}
