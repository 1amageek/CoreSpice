import Foundation
import Testing
@testable import CoreSpiceCLICore

@Suite(.timeLimit(.minutes(1)))
struct PairedCSVCodecTests {
    private typealias Codec = CoreSpiceCLIPairedCSVCodec
    private let configuration = String(repeating: "a", count: 64)

    private func limits(bytes: UInt64 = 65_536, points: Int = 16, columns: Int = 8,
                        scalars: Int = 256) throws -> Codec.Limits {
        try Codec.Limits(maximumBytes: bytes, maximumPoints: points,
            maximumColumns: columns, maximumScalars: scalars)
    }

    private func record() throws -> CoreSpiceCLIPairedCSVRecord {
        try CoreSpiceCLIPairedCSVRecord(configurationSHA256: configuration, sourceRowCount: 3,
            compiledRows: [0, 1, 2], times: [-0.0, 0x1p-54],
            high: [0.5, -0.0, 1, 0.5, 0.0, -1],
            low: [0x1p-56, -0.0, -0x1p-56, 0x1p-55, -0.0, 0x1p-56])
    }

    private func encoded() throws -> Data { try Codec.encode(record(), limits: limits()) }

    private func replace(_ data: Data, line: Int, field: Int, with replacement: String) throws -> Data {
        let text = try #require(String(data: data, encoding: .utf8))
        var lines = text.components(separatedBy: "\n")
        var fields = lines[line].components(separatedBy: ",")
        fields[field] = replacement; lines[line] = fields.joined(separator: ",")
        return Data(lines.joined(separator: "\n").utf8)
    }

    private func assertSameBits(_ actual: CoreSpiceCLIPairedCSVRecord,
                                _ expected: CoreSpiceCLIPairedCSVRecord) {
        #expect(actual.schemaVersion == 1)
        #expect(actual.configurationSHA256 == expected.configurationSHA256)
        #expect(actual.sourceRowCount == expected.sourceRowCount)
        #expect(actual.compiledRows == expected.compiledRows)
        #expect(actual.times.map(\.bitPattern) == expected.times.map(\.bitPattern))
        #expect(actual.high.map(\.bitPattern) == expected.high.map(\.bitPattern))
        #expect(actual.low.map(\.bitPattern) == expected.low.map(\.bitPattern))
    }

    @Test
    func fullCanonicalTraceRoundtripsSubULPComponentsAndSignedZeros() throws {
        let original = try record()
        let bytes = try Codec.encode(original, limits: limits())
        let decoded = try Codec.decode(bytes, limits: limits())
        assertSameBits(decoded, original)
        #expect(decoded.high[0] + decoded.low[0] == decoded.high[0])
        #expect(decoded.low[0] != 0)
        #expect(decoded.times[0].bitPattern == (-0.0).bitPattern)
        #expect(decoded.low[1].bitPattern == (-0.0).bitPattern)
        let text = try #require(String(data: bytes, encoding: .utf8))
        #expect(text.hasPrefix("corespice-paired-csv,1,\(configuration),2,3,3\ncompiled_rows,0,1,2\n"))
        #expect(try Codec.encode(decoded, limits: limits()) == bytes)
    }

    @Test
    func explicitSubsetAndReorderRetainCanonicalRowNumbers() throws {
        let original = try record()
        for selection in [[2], [2, 0]] {
            var high: [Double] = [], low: [Double] = []
            for point in original.times.indices {
                for row in selection {
                    high.append(original.high[point * 3 + row]); low.append(original.low[point * 3 + row])
                }
            }
            let selected = try CoreSpiceCLIPairedCSVRecord(configurationSHA256: configuration, sourceRowCount: 3,
                compiledRows: selection, times: original.times, high: high, low: low)
            assertSameBits(try Codec.decode(Codec.encode(selected, limits: limits()), limits: limits()), selected)
        }
    }

    @Test
    func finiteBinary64ExtremesAndCRLFKeepExactBits() throws {
        let original = try CoreSpiceCLIPairedCSVRecord(configurationSHA256: configuration, sourceRowCount: 3,
            compiledRows: [0, 1, 2], times: [0],
            high: [.greatestFiniteMagnitude, .leastNonzeroMagnitude, -.greatestFiniteMagnitude], low: [0, 0, 0])
        let bytes = try Codec.encode(original, limits: limits())
        let text = try #require(String(data: bytes, encoding: .utf8))
        let crlf = Data(text.replacingOccurrences(of: "\n", with: "\r\n").utf8)
        assertSameBits(try Codec.decode(crlf, limits: limits()), original)
    }

    @Test
    func schemaConfigurationCountsAndHeaderAreStrict() throws {
        let bytes = try encoded()
        for (line, field, value) in [(0, 0, "ordinary-csv"), (0, 1, "2"), (0, 2, "bad-digest"),
                                     (0, 3, "0"), (0, 4, "0"), (0, 5, "0"), (2, 7, "imaginary")] {
            let malformed = try replace(bytes, line: line, field: field, with: value)
            #expect(throws: Codec.Error.self) { _ = try Codec.decode(malformed, limits: limits()) }
        }
        #expect(throws: Codec.Error.invalidUTF8) {
            _ = try Codec.decode(Data([0xff]), limits: limits())
        }
    }

    @Test
    func rowMapDuplicateMissingOutOfRangeAndDataOrderFail() throws {
        let bytes = try encoded()
        for (line, field, value) in [(1, 2, "0"), (1, 1, "3"), (1, 1, "-1"),
                                     (3, 0, "1"), (3, 3, "1"), (3, 4, "2")] {
            let malformed = try replace(bytes, line: line, field: field, with: value)
            #expect(throws: Codec.Error.self) { _ = try Codec.decode(malformed, limits: limits()) }
        }
        let text = try #require(String(data: bytes, encoding: .utf8))
        var lines = text.components(separatedBy: "\n")
        lines[4] = lines[3]
        #expect(throws: Codec.Error.unexpectedRecord(line: 5)) {
            _ = try Codec.decode(Data(lines.joined(separator: "\n").utf8), limits: limits())
        }
    }

    @Test
    func componentAndTimeBitsMustMatchEveryRepeatedCoordinate() throws {
        let bytes = try encoded()
        for field in [2, 6, 8] {
            let malformed = try replace(bytes, line: 3, field: field, with: "1")
            #expect(throws: Codec.Error.bitPatternMismatch(line: 4)) {
                _ = try Codec.decode(malformed, limits: limits())
            }
        }
        var changed = try replace(bytes, line: 4, field: 1, with: "0.0")
        changed = try replace(changed, line: 4, field: 2, with: "0")
        #expect(throws: Codec.Error.bitPatternMismatch(line: 5)) {
            _ = try Codec.decode(changed, limits: limits())
        }
        var nonIncreasing = bytes
        for line in 6...8 {
            nonIncreasing = try replace(nonIncreasing, line: line, field: 1, with: "0.0")
            nonIncreasing = try replace(nonIncreasing, line: line, field: 2, with: "0")
        }
        #expect(throws: Codec.Error.invalidTime(point: 1)) {
            _ = try Codec.decode(nonIncreasing, limits: limits())
        }
    }

    @Test
    func nonnormalizedNaNQuotedMissingAndExtraComponentsFail() throws {
        let bytes = try encoded()
        var overlapping = try replace(bytes, line: 3, field: 7, with: "1.0")
        overlapping = try replace(overlapping, line: 3, field: 8, with: String(1.0.bitPattern))
        #expect(throws: Codec.Error.invalidPair(sample: 0)) {
            _ = try Codec.decode(overlapping, limits: limits())
        }
        for value in ["nan", "inf", "\"0.5\"", "", String(repeating: "0", count: 65)] {
            let malformed = try replace(bytes, line: 3, field: 5, with: value)
            #expect(throws: Codec.Error.invalidSyntax(line: 4)) {
                _ = try Codec.decode(malformed, limits: limits())
            }
        }
        let extra = try replace(bytes, line: 3, field: 8, with: "0,0")
        #expect(throws: Codec.Error.invalidSyntax(line: 4)) {
            _ = try Codec.decode(extra, limits: limits())
        }
        let text = try #require(String(data: bytes, encoding: .utf8))
        let missing = text.components(separatedBy: "\n").dropLast(2).joined(separator: "\n") + "\n"
        #expect(throws: Codec.Error.self) { _ = try Codec.decode(Data(missing.utf8), limits: limits()) }
        #expect(throws: Codec.Error.self) { _ = try Codec.decode(bytes + Data("\n".utf8), limits: limits()) }
    }

    @Test
    func recordConstructionRejectsShapeTimeMapAndPairFailures() throws {
        for rows in [[0, 0], [3], []] {
            #expect(throws: Codec.Error.invalidRowMap) {
                _ = try CoreSpiceCLIPairedCSVRecord(configurationSHA256: configuration, sourceRowCount: 3,
                    compiledRows: rows, times: [0], high: [0, 0], low: [0, 0])
            }
        }
        #expect(throws: Codec.Error.invalidCounts) {
            _ = try CoreSpiceCLIPairedCSVRecord(configurationSHA256: configuration, sourceRowCount: 1,
                compiledRows: [0], times: [0], high: [1], low: [])
        }
        #expect(throws: Codec.Error.invalidTime(point: 0)) {
            _ = try CoreSpiceCLIPairedCSVRecord(configurationSHA256: configuration, sourceRowCount: 1,
                compiledRows: [0], times: [-1], high: [1], low: [0])
        }
        #expect(throws: Codec.Error.invalidPair(sample: 0)) {
            _ = try CoreSpiceCLIPairedCSVRecord(configurationSHA256: configuration, sourceRowCount: 1,
                compiledRows: [0], times: [0], high: [.nan], low: [0])
        }
    }

    @Test
    func explicitBudgetsAndOverflowRefuseBeforeMaterializingOutputOrArrays() throws {
        let bytes = try encoded()
        for policy in [try limits(bytes: UInt64(bytes.count - 1)), try limits(points: 1),
                       try limits(columns: 2), try limits(scalars: 13)] {
            #expect(throws: Codec.Error.limitExceeded) { _ = try Codec.encode(record(), limits: policy) }
            #expect(throws: Codec.Error.limitExceeded) { _ = try Codec.decode(bytes, limits: policy) }
        }
        let count = String(Int.max)
        let overflowing = Data("corespice-paired-csv,1,\(configuration),\(count),3,3\ncompiled_rows,0,1,2\n".utf8)
        let large = try limits(bytes: UInt64(Int.max), points: Int.max, columns: 3, scalars: Int.max)
        #expect(throws: Codec.Error.limitExceeded) { _ = try Codec.decode(overflowing, limits: large) }
        let absent = try replace(bytes, line: 0, field: 3, with: "10000")
        #expect(throws: Codec.Error.limitExceeded) {
            _ = try Codec.decode(absent, limits: limits(bytes: 1_000_000, points: 10_000, scalars: 100_000))
        }
        #expect(throws: Codec.Error.invalidLimits) { _ = try limits(bytes: 0) }
    }

    @Test
    func largeDecimalRowMapIsByteAdmittedBeforeFieldMaterialization() throws {
        let rows = Array(1_000_000_000_000_000_000..<1_000_000_000_000_001_000)
        let original = try CoreSpiceCLIPairedCSVRecord(configurationSHA256: configuration,
            sourceRowCount: Int.max - 1, compiledRows: rows, times: [0],
            high: Array(repeating: 0, count: rows.count), low: Array(repeating: 0, count: rows.count))
        let small = try limits(bytes: 20_000, points: 1, columns: Int.max - 1, scalars: 3000)
        // The general 20,000-byte minimum fits; the actual row-map line alone is 20,014 bytes.
        #expect(throws: Codec.Error.limitExceeded) { _ = try Codec.encode(original, limits: small) }
        let admitted = try limits(bytes: 200_000, points: 1, columns: Int.max - 1, scalars: 3000)
        let bytes = try Codec.encode(original, limits: admitted)
        let text = try #require(String(data: bytes, encoding: .utf8))
        let lines = text.split(separator: "\n")
        #expect(lines[1].utf8.count + 1 == 20_014)
        assertSameBits(try Codec.decode(bytes, limits: admitted), original)
    }
}
