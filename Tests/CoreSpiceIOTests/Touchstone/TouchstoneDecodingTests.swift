import CoreSpiceCompile
import CoreSpiceIO
import Foundation
import Testing

@Suite("Touchstone strict decoding")
struct TouchstoneDecodingTests {
    private func deck(_ body: String, kind: String = "S", unit: String = "Hz", format: String = "RI", ports: Int = 2,
                      order: String = "12_21", matrix: String = "Full", references: String = "25 75") -> Data {
        let orderLine = ports == 2 ? "[Two-Port Data Order] \(order)\n" : ""
        return Data("""
        [Version] 2.1
        # \(unit) \(kind) \(format) R 50
        [Number of Ports] \(ports)
        \(orderLine)[Number of Frequencies] 1
        [Reference] \(references)
        [Matrix Format] \(matrix)
        [Network Data]
        \(body)
        [End]
        """.utf8)
    }

    @Test(arguments: ["S", "Y", "Z"])
    func physicalKindsDoNotRescaleYZ(kind: String) throws {
        let data = try TouchstoneDecoder().decode(deck("2 11 -1 12 -2 21 -3 22 -4", kind: kind, unit: "kHz"))
        #expect(data.parameterKind.rawValue == kind)
        #expect(data.referenceResistances == [25, 75])
        #expect(data.points[0].frequencyHz == 2000)
        #expect(data.points[0].matrix.values == [ComplexPair(real: 11, imag: -1), ComplexPair(real: 12, imag: -2), ComplexPair(real: 21, imag: -3), ComplexPair(real: 22, imag: -4)])
    }

    @Test func twoPortLegacyAndRowOrderAreDistinct() throws {
        let row = try TouchstoneDecoder().decode(deck("1 11 0 12 0 21 0 22 0"))
        let column = try TouchstoneDecoder().decode(deck("1 11 0 21 0 12 0 22 0", order: "21_12"))
        #expect(row == column)
        #expect(try column.points[0].matrix.value(row: 0, column: 1).real == 12)
        #expect(try column.points[0].matrix.value(row: 1, column: 0).real == 21)
    }

    @Test(arguments: ["Lower", "Upper"])
    func twoPortTrianglesAlwaysUseElevenTwentyOneTwentyTwo(matrix: String) throws {
        let data = try TouchstoneDecoder().decode(deck("1 1 2 3 4 5 6", order: "21_12", matrix: matrix))
        #expect(data.points[0].matrix.values == [ComplexPair(real: 1, imag: 2), ComplexPair(real: 3, imag: 4), ComplexPair(real: 3, imag: 4), ComplexPair(real: 5, imag: 6)])
    }

    @Test func threePortTrianglesUseTransposeWithoutConjugation() throws {
        let lower = try TouchstoneDecoder().decode(deck("1 11 1 21 2 22 3 31 4 32 5 33 6", ports: 3, matrix: "Lower", references: "10 20 30"))
        let upper = try TouchstoneDecoder().decode(deck("1 11 1 21 2 31 4 22 3 32 5 33 6", ports: 3, matrix: "Upper", references: "10 20 30"))
        #expect(lower == upper)
        #expect(try lower.points[0].matrix.value(row: 0, column: 2) == ComplexPair(real: 31, imag: 4))
        #expect(try lower.points[0].matrix.value(row: 2, column: 0) == ComplexPair(real: 31, imag: 4))
    }

    @Test func fivePortFullRowsHaveIndependentOrder() throws {
        let body = "1 " + (1...25).map { "\($0) \(-$0)" }.joined(separator: " ")
        let data = try TouchstoneDecoder().decode(deck(body, ports: 5, references: "10 20 30 40 50"))
        #expect(try data.points[0].matrix.value(row: 3, column: 1) == ComplexPair(real: 17, imag: -17))
    }

    @Test func defaultsAndCaseInsensitivityAreSpecified() throws {
        let bytes = Data("[version] 2.0\n#\n[number of ports] 1\n[number of frequencies] 1\n[network data]\n2 0.5 0\n[end]\n".utf8)
        let data = try TouchstoneDecoder().decode(bytes)
        #expect(data.parameterKind == .scattering)
        #expect(data.referenceResistances == [50])
        #expect(data.points[0].frequencyHz == 2e9)
        #expect(data.points[0].matrix.values == [ComplexPair(real: 0.5)])
    }

    @Test(arguments: ["MA", "DB"])
    func polarFormatsUseDegreesAndTwentyLogMagnitude(format: String) throws {
        let magnitude = format == "DB" ? "20" : "10"
        let data = try TouchstoneDecoder().decode(deck("2 \(magnitude) 90", unit: "MHz", format: format, ports: 1, references: "75"))
        let pair = data.points[0].matrix.values[0]
        #expect(data.points[0].frequencyHz == 2e6)
        #expect(abs(pair.real) <= 10 * Double.ulpOfOne)
        #expect(pair.imag == 10)
    }

    @Test func legacySRequiresExplicitAuthorityAndPreservesPerPortReferences() throws {
        let bytes = Data("# GHz S RI R 25 75\n1 11 0 21 0 12 0 22 0\n".utf8)
        #expect(throws: TouchstoneError.self) { _ = try TouchstoneDecoder().decode(bytes) }
        let explicit = try TouchstoneDecoder().decode(bytes, configuration: .init(portCountHint: 2))
        let extensionHint = try TouchstoneDecoder().decode(bytes, configuration: .init(fileExtensionHint: ".s2p"))
        #expect(explicit == extensionHint)
        #expect(explicit.referenceResistances == [25, 75])
        #expect(explicit.points[0].frequencyHz == 1e9)
        #expect(try explicit.points[0].matrix.value(row: 0, column: 1).real == 12)
        #expect(throws: TouchstoneError.self) { _ = try TouchstoneDecoder().decode(bytes, configuration: .init(portCountHint: 1, fileExtensionHint: "s2p")) }
    }

    @Test func legacyFivePortContinuationIsRowBounded() throws {
        var lines = ["# Hz S RI", "1 1 0 2 0 3 0 4 0", "5 0"]
        for row in 1..<5 {
            lines.append((1...4).map { "\(row * 5 + $0) 0" }.joined(separator: " "))
            lines.append("\(row * 5 + 5) 0")
        }
        let data = try TouchstoneDecoder().decode(Data(lines.joined(separator: "\n").utf8), configuration: .init(portCountHint: 5))
        #expect(data.points[0].matrix.values.map(\.real) == (1...25).map(Double.init))
    }

    @Test(arguments: ["Y", "Z", "G", "H"])
    func legacyNormalizedAndHybridParametersAreNotMisread(kind: String) {
        #expect(throws: TouchstoneError.self) { _ = try TouchstoneDecoder().decode(Data("# Hz \(kind) RI R 50\n1 1 0\n".utf8), configuration: .init(portCountHint: 1)) }
    }

    @Test(arguments: ["[Mixed-Mode Order] S1", "[Noise Data]", "[Number of Noise Frequencies] 1", "[Unknown] x", "[Begin Information]"])
    func unsupportedBlocksCannotDisappear(block: String) {
        let text = "[Version] 2.1\n# Hz S RI\n[Number of Ports] 1\n\(block)\n"
        do {
            _ = try TouchstoneDecoder().decode(Data(text.utf8))
            Issue.record("Unsupported data was accepted")
        } catch TouchstoneError.unsupportedFeature(_, let position) {
            #expect(position.line == 4)
            #expect(position.column == 1)
        } catch { Issue.record("Wrong failure: \(error)") }
    }

    @Test(arguments: ["nan", "inf", "0x1p2", "1e999", "1e-999", "not-a-number"])
    func malformedNumericHasPhysicalSourcePosition(token: String) {
        let text = "[Version] 2.1\r\n# Hz S RI\r\n[Number of Ports] 1\r\n[Number of Frequencies] 1\r\n[Network Data]\r\n1 \(token) 0\r\n[End]\r\n"
        do {
            _ = try TouchstoneDecoder().decode(Data(text.utf8), configuration: .init(sourceName: "input.ts"))
            Issue.record("Invalid numeric token was accepted")
        } catch TouchstoneError.syntax(_, let position) {
            #expect(position.sourceName == "input.ts")
            #expect(position.line == 6)
            #expect(position.column == 3)
            #expect(position.byteOffset == UInt64(text.utf8.count - "1 \(token) 0\r\n[End]\r\n".utf8.count + 2))
        } catch { Issue.record("Wrong failure: \(error)") }
    }

    @Test(arguments: ["1 1 0 2 0", "1 1", "-1 1 0", "1 1 0\n1 2 0"])
    func incompleteExtraAndInvalidFrequencyRecordsFail(body: String) {
        #expect(throws: TouchstoneError.self) { _ = try TouchstoneDecoder().decode(deck(body, ports: 1, references: "50")) }
    }

    @Test func nonASCIIAndMissingEndAreRejected() {
        #expect(throws: TouchstoneError.self) { _ = try TouchstoneDecoder().decode(Data("! µ\n".utf8)) }
        let text = "[Version] 2.1\n# Hz S RI\n[Number of Ports] 1\n[Number of Frequencies] 1\n[Network Data]\n1 1 0\n"
        #expect(throws: TouchstoneError.self) { _ = try TouchstoneDecoder().decode(Data(text.utf8)) }
    }

    @Test func additionalOptionLineIsIgnoredBySpecifiedRule() throws {
        let data = try TouchstoneDecoder().decode(deck("# GHz Z MA R 1\n1 2 3", ports: 1, references: "50"))
        #expect(data.parameterKind == .scattering)
        #expect(data.points[0].frequencyHz == 1)
        #expect(data.points[0].matrix.values == [ComplexPair(real: 2, imag: 3)])
    }

    @Test func optionAndKeywordReferenceShareDecimalNumericGrammar() throws {
        let ordinary = String(decoding: deck("1 2 3", ports: 1, references: "4"), as: UTF8.self)
        let hexadecimalOption = ordinary.replacingOccurrences(of: "R 50", with: "R 0x1p2")
        let hexadecimalKeyword = ordinary.replacingOccurrences(of: "[Reference] 4", with: "[Reference] 0x1p2")
        for bytes in [Data(hexadecimalOption.utf8), Data(hexadecimalKeyword.utf8)] {
            do {
                _ = try TouchstoneDecoder().decode(bytes)
                Issue.record("Hexadecimal reference bypassed the numeric grammar")
            } catch TouchstoneError.syntax(_, let position) {
                #expect(position.column == 13)
            }
        }
        let decimal = ordinary.replacingOccurrences(of: "R 50", with: "R 4e0")
        #expect(try TouchstoneDecoder().decode(Data(decimal.utf8)).referenceResistances == [4])
    }
}
