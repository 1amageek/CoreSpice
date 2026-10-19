import CoreSpiceCompile
import CoreSpiceIO
import Foundation
import Testing

@Suite("Touchstone encoding")
struct TouchstoneEncodingTests {
    private func fixture(kind: TouchstoneParameterKind = .scattering, symmetric: Bool = false) throws -> TouchstoneData {
        let values = symmetric
            ? [ComplexPair(real: 0.1, imag: 0.2), ComplexPair(real: 0.3, imag: -0.4), ComplexPair(real: 0.3, imag: -0.4), ComplexPair(real: 0.5, imag: 0.6)]
            : [ComplexPair(real: 0.1, imag: 0.2), ComplexPair(real: 0.3, imag: -0.4), ComplexPair(real: -0.7, imag: 0.8), ComplexPair(real: 0.5, imag: 0.6)]
        let matrix = try NetworkParameterMatrix(portCount: 2, values: values)
        return try TouchstoneData(parameterKind: kind, referenceResistances: [25, 75],
                                  points: [TouchstonePoint(frequencyHz: 1e9, matrix: matrix), TouchstonePoint(frequencyHz: 2e9, matrix: matrix)])
    }

    @Test(arguments: [TouchstoneParameterKind.scattering, .admittance, .impedance])
    func defaultRepresentationRoundTripsEveryBinary64Component(kind: TouchstoneParameterKind) throws {
        let data = try fixture(kind: kind)
        let bytes = try TouchstoneEncoder().encode(data)
        let decoded = try TouchstoneDecoder().decode(bytes)
        #expect(decoded == data)
        #expect(String(decoding: bytes, as: UTF8.self).contains("[Version] 2.1"))
        for (original, restored) in zip(data.points, decoded.points) {
            #expect(original.frequencyHz.bitPattern == restored.frequencyHz.bitPattern)
            for (a, b) in zip(original.matrix.values, restored.matrix.values) {
                #expect(a.real.bitPattern == b.real.bitPattern)
                #expect(a.imag.bitPattern == b.imag.bitPattern)
            }
        }
    }

    @Test func signedZeroAndExtremeFiniteRIRoundTrip() throws {
        let matrix = try NetworkParameterMatrix(portCount: 2, values: [ComplexPair(real: -0.0, imag: 0), ComplexPair(real: .leastNonzeroMagnitude, imag: -.leastNonzeroMagnitude), ComplexPair(real: .greatestFiniteMagnitude, imag: -.greatestFiniteMagnitude), ComplexPair(real: 1, imag: -1)])
        let data = try TouchstoneData(parameterKind: .impedance, referenceResistances: [1, 50], points: [TouchstonePoint(frequencyHz: 0, matrix: matrix)])
        let decoded = try TouchstoneDecoder().decode(TouchstoneEncoder().encode(data))
        for (a, b) in zip(matrix.values, decoded.points[0].matrix.values) {
            #expect(a.real.bitPattern == b.real.bitPattern)
            #expect(a.imag.bitPattern == b.imag.bitPattern)
        }
    }

    @Test func allFormatsUnitsOrdersAndVersionsPreserveSemanticValues() throws {
        let data = try fixture()
        for version in [TouchstoneEncodingConfiguration.Version.twoPointZero, .twoPointOne] {
            for unit in TouchstoneEncodingConfiguration.FrequencyUnit.allCases {
                for format in TouchstoneEncodingConfiguration.DataFormat.allCases {
                    for order in TouchstoneEncodingConfiguration.TwoPortOrder.allCases {
                        let config = TouchstoneEncodingConfiguration(version: version, frequencyUnit: unit, dataFormat: format, twoPortOrder: order)
                        let decoded = try TouchstoneDecoder().decode(TouchstoneEncoder().encode(data, configuration: config))
                        #expect(decoded.referenceResistances == data.referenceResistances)
                        for (a, b) in zip(data.points, decoded.points) {
                            #expect(a.frequencyHz == b.frequencyHz)
                            for (x, y) in zip(a.matrix.values, b.matrix.values) {
                                // Polar trigonometric conversion introduces bounded binary64 rounding.
                                let scale = max(x.magnitude, y.magnitude)
                                #expect(abs(x.real - y.real) <= 32 * Double.ulpOfOne * scale)
                                #expect(abs(x.imag - y.imag) <= 32 * Double.ulpOfOne * scale)
                            }
                        }
                    }
                }
            }
        }
    }

    @Test(arguments: [TouchstoneEncodingConfiguration.MatrixFormat.lower, .upper])
    func triangularEncodingRequiresSymmetryAndPreservesComplexTranspose(matrix: TouchstoneEncodingConfiguration.MatrixFormat) throws {
        let data = try fixture(symmetric: true)
        #expect(try TouchstoneDecoder().decode(TouchstoneEncoder().encode(data, configuration: .init(matrixFormat: matrix))) == data)
        let asymmetric = try fixture()
        #expect(throws: TouchstoneError.self) { _ = try TouchstoneEncoder().encode(asymmetric, configuration: .init(matrixFormat: matrix)) }
    }

    @Test func decibelZeroAndOverflowingMagnitudeRefuseInsteadOfClamping() throws {
        let zero = try TouchstoneData(parameterKind: .scattering, referenceResistances: [50], points: [TouchstonePoint(frequencyHz: 1, matrix: NetworkParameterMatrix(portCount: 1, values: [ComplexPair()]))])
        #expect(throws: TouchstoneError.self) { _ = try TouchstoneEncoder().encode(zero, configuration: .init(dataFormat: .decibelAngle)) }
        let large = try TouchstoneData(parameterKind: .impedance, referenceResistances: [50], points: [TouchstonePoint(frequencyHz: 1, matrix: NetworkParameterMatrix(portCount: 1, values: [ComplexPair(real: .greatestFiniteMagnitude, imag: .greatestFiniteMagnitude)]))])
        #expect(throws: TouchstoneError.self) { _ = try TouchstoneEncoder().encode(large, configuration: .init(dataFormat: .magnitudeAngle)) }
        #expect(try TouchstoneDecoder().decode(TouchstoneEncoder().encode(zero)) == zero)
    }

    @Test func encoderBudgetsBoundOutputAndScratch() throws {
        let data = try fixture()
        for limits in [TouchstoneLimits(maximumOutputBytes: 16), TouchstoneLimits(maximumRetainedBytes: 32), TouchstoneLimits(maximumTokens: 2), TouchstoneLimits(maximumPorts: 1), TouchstoneLimits(maximumFrequencyPoints: 1)] {
            #expect(throws: TouchstoneError.self) { _ = try TouchstoneEncoder().encode(data, limits: limits) }
        }
    }

    @Test func datasetRejectsInvalidReferenceWidthAndOrder() throws {
        let data = try fixture()
        #expect(throws: TouchstoneError.self) { _ = try TouchstoneData(parameterKind: .scattering, referenceResistances: [50], points: data.points) }
        #expect(throws: TouchstoneError.self) { _ = try TouchstoneData(parameterKind: .scattering, referenceResistances: [0, 50], points: data.points) }
        #expect(throws: TouchstoneError.self) { _ = try TouchstoneData(parameterKind: .scattering, referenceResistances: [50, 50], points: Array(data.points.reversed())) }
    }
}
