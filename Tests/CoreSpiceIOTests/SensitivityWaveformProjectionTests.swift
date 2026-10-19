import Foundation
import Testing
import CoreSpiceCompile
import CoreSpiceIO

@Suite(.timeLimit(.minutes(1)))
struct SensitivityWaveformProjectionTests {
    private func dcResult(
        baseline: Double,
        normalized: [Double?]
    ) throws -> SensitivityResult {
        try SensitivityResult(
            outputVariable: "V(out)",
            baselineValue: baseline,
            sensitivities: normalized.enumerated().map { index, value in
                SensitivityResult.ParameterSensitivity(
                    deviceName: "R\(index + 1)", parameterName: "r",
                    nominalValue: Double(index + 1),
                    sensitivity: Double(index + 1) * 0.25,
                    normalizedSensitivity: value
                )
            },
            dcOperatingPoint: DCResult(variables: [], variableMap: [:], iterations: 0)
        )
    }

    /// Uses strict JSON number encoding and the public CSV file path, then
    /// compares sample values without relying on CSV analysis-kind inference.
    private func verifyPersistence(_ waveform: WaveformData) async throws {
        var samples = waveform.sweepValues
        for point in 0..<waveform.pointCount {
            for column in 0..<waveform.variableCount {
                if waveform.isComplex {
                    let value = try #require(waveform.complexValue(variable: column, point: point))
                    samples.append(value.real)
                    samples.append(value.imag)
                } else {
                    samples.append(try #require(waveform.realValue(variable: column, point: point)))
                }
            }
        }
        let json = try JSONEncoder().encode(samples)
        #expect(try JSONDecoder().decode([Double].self, from: json) == samples)
        #expect(samples.allSatisfy { $0.isFinite })

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SensitivityWaveformProjection-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer {
            do { try FileManager.default.removeItem(at: directory) }
            catch { Issue.record(error) }
        }
        let destination = directory.appendingPathComponent("sensitivity.csv")
        _ = try await SPICEIO.exportToCSV(waveform, path: destination.path)
        let reloaded = try CSVWaveformReader().read(contentsOfFile: destination.path)
        #expect(reloaded.variables.map(\.name) == waveform.variables.map(\.name))
        #expect(reloaded.sweepValues == waveform.sweepValues)
        #expect(reloaded.pointCount == waveform.pointCount)
        #expect(reloaded.variableCount == waveform.variableCount)
        #expect(reloaded.isComplex == waveform.isComplex)
        for point in 0..<waveform.pointCount {
            for column in 0..<waveform.variableCount {
                if waveform.isComplex {
                    let expected = try #require(waveform.complexValue(variable: column, point: point))
                    let actual = try #require(reloaded.complexValue(variable: column, point: point))
                    #expect(actual.real == expected.real)
                    #expect(actual.imag == expected.imag)
                } else {
                    #expect(reloaded.realValue(variable: column, point: point)
                        == waveform.realValue(variable: column, point: point))
                }
            }
        }
    }

    @Test
    func zeroBaselineDCKeepsAllAbsoluteRowsWithoutNormalizedColumn() async throws {
        let result = try dcResult(baseline: 0, normalized: [nil, nil])
        let waveform = WaveformData.from(sensitivityResult: result)
        #expect(waveform.variables.map(\.name) == ["sensitivity"])
        #expect(waveform.variables.map(\.index) == [0])
        #expect(waveform.metadata.variableCount == 1)
        #expect(waveform.sweepValues == [0, 1])
        #expect(waveform.allRealData == [[0.25], [0.5]])
        try await verifyPersistence(waveform)
        #expect(result.sensitivities.allSatisfy { $0.normalizedSensitivity == nil })
    }

    @Test
    func mixedDCAvailabilityOmitsSharedColumnAndPreservesTypedValues() async throws {
        let result = try dcResult(baseline: 1, normalized: [nil, 1])
        let waveform = WaveformData.from(sensitivityResult: result)
        #expect(waveform.variables.map(\.name) == ["sensitivity"])
        #expect(waveform.allRealData == [[0.25], [0.5]])
        try await verifyPersistence(waveform)
        #expect(result.sensitivities[0].normalizedSensitivity == nil)
        #expect(result.sensitivities[1].normalizedSensitivity == 1)
    }

    @Test
    func fullyDefinedDCRetainsExistingColumnsAndValues() async throws {
        let result = try dcResult(baseline: 1, normalized: [0.25, 1])
        let waveform = WaveformData.from(sensitivityResult: result)
        #expect(waveform.variables.map(\.name) == ["sensitivity", "normalized_sensitivity"])
        #expect(waveform.variables.map(\.index) == [0, 1])
        #expect(waveform.metadata.variableCount == 2)
        #expect(waveform.allRealData == [[0.25, 0.25], [0.5, 1]])
        try await verifyPersistence(waveform)
    }

    @Test
    func acZeroAtOneFrequencyOmitsWholeNormalizedColumnWithoutLosingDerivatives() async throws {
        let derivatives = [
            ComplexPair(real: 0.25, imag: -0.5),
            ComplexPair(real: -0.75, imag: 1),
            ComplexPair(real: 1.25, imag: -1.5),
        ]
        let normalized: [ComplexPair?] = [derivatives[0], nil, derivatives[2]]
        let result = try ACSensitivityResult(
            outputVariable: "V(out)", frequencies: [10, 20, 30],
            baselineValues: [.init(real: 1), .init(real: 0), .init(real: 1)],
            sensitivities: [ACSensitivityResult.ParameterSensitivity(
                deviceName: "R1", parameterName: "r", nominalValue: 1,
                sensitivities: derivatives, normalizedSensitivities: normalized
            )]
        )
        let waveform = WaveformData.from(acSensitivityResult: result)
        #expect(waveform.variables.map(\.name) == ["dV(out)/dR1.r"])
        #expect(waveform.metadata.variableCount == 1)
        #expect(waveform.sweepValues == result.frequencies)
        for point in derivatives.indices {
            let actual = try #require(waveform.complexValue(variable: 0, point: point))
            #expect(actual.real == derivatives[point].real)
            #expect(actual.imag == derivatives[point].imag)
        }
        try await verifyPersistence(waveform)
        #expect(result.sensitivities[0].normalizedSensitivities == normalized)
    }

    @Test
    func mixedACAvailabilitySelectsColumnsPerParameter() async throws {
        let derivative = [ComplexPair(real: 0.25, imag: -0.5), .init(real: 0.75, imag: -1)]
        let normalized = derivative.map { Optional($0) }
        let result = try ACSensitivityResult(
            outputVariable: "V(out)", frequencies: [10, 20],
            baselineValues: [.init(real: 1), .init(real: 1)],
            sensitivities: [
                .init(deviceName: "R1", parameterName: "r", nominalValue: 1,
                    sensitivities: derivative, normalizedSensitivities: [nil, derivative[1]]),
                .init(deviceName: "R2", parameterName: "r", nominalValue: 1,
                    sensitivities: derivative, normalizedSensitivities: normalized),
            ]
        )
        let waveform = WaveformData.from(acSensitivityResult: result)
        #expect(waveform.variables.map(\.name) == [
            "dV(out)/dR1.r", "dV(out)/dR2.r", "normalized_R2.r",
        ])
        #expect(waveform.variables.map(\.index) == [0, 1, 2])
        #expect(waveform.metadata.variableCount == 3)
        for point in derivative.indices {
            for column in 0..<3 {
                let actual = try #require(waveform.complexValue(variable: column, point: point))
                #expect(actual.real == derivative[point].real)
                #expect(actual.imag == derivative[point].imag)
            }
        }
        try await verifyPersistence(waveform)
        #expect(result.sensitivities[0].normalizedSensitivities == [nil, derivative[1]])
        #expect(result.sensitivities[1].normalizedSensitivities == normalized)
    }

    @Test
    func fullyDefinedACRetainsEachPairedColumnAndValues() async throws {
        let first = [ComplexPair(real: 0.25, imag: -0.5), .init(real: 0.75, imag: -1)]
        let second = [ComplexPair(real: 1.25, imag: -1.5), .init(real: 1.75, imag: -2)]
        let result = try ACSensitivityResult(
            outputVariable: "V(out)", frequencies: [10, 20],
            baselineValues: [.init(real: 1), .init(real: 1)],
            sensitivities: [
                .init(deviceName: "R1", parameterName: "r", nominalValue: 1,
                    sensitivities: first, normalizedSensitivities: first.map { $0 }),
                .init(deviceName: "R2", parameterName: "r", nominalValue: 1,
                    sensitivities: second, normalizedSensitivities: second.map { $0 }),
            ]
        )
        let waveform = WaveformData.from(acSensitivityResult: result)
        #expect(waveform.variables.map(\.name) == [
            "dV(out)/dR1.r", "normalized_R1.r", "dV(out)/dR2.r", "normalized_R2.r",
        ])
        #expect(waveform.variables.map(\.index) == [0, 1, 2, 3])
        #expect(waveform.metadata.variableCount == 4)
        for point in result.frequencies.indices {
            for (column, expected) in [first[point], first[point], second[point], second[point]].enumerated() {
                let actual = try #require(waveform.complexValue(variable: column, point: point))
                #expect(actual.real == expected.real)
                #expect(actual.imag == expected.imag)
            }
        }
        try await verifyPersistence(waveform)
    }
}
