import Foundation
import CoreSpiceCompile
import CoreSpiceIO
import Testing

@Suite(.timeLimit(.minutes(1)))
struct PoleZeroWaveformPersistenceTests {
    private struct StoredPoint: Codable {
        let metadata: SimulationMetadata
        let variables: [VariableDescriptor]
        let sweepValues: [Double]
        let real: [Double]
        let imaginary: [Double]
    }

    @Test(arguments: [0, 2], [0, 1])
    func strictJSONAndCSVRoundTripActualRootsAndUnits(poleCount: Int, zeroCount: Int) async throws {
        let poles = (0..<poleCount).map { ComplexPair(real: -Double($0 + 1), imag: Double($0 + 1) * 0.25) }
        let zeros = (0..<zeroCount).map { ComplexPair(real: Double($0), imag: Double($0) * 0.5) }
        let result = try PoleZeroResult(poles: poles, zeros: zeros, dcGain: -0.75, variableMap: [:])
        let waveform = WaveformData.from(poleZeroResult: result)
        let expected = poles + zeros + [ComplexPair(real: result.dcGain)]
        var real: [Double] = []
        var imaginary: [Double] = []
        for column in waveform.variables.indices {
            let sample = try #require(waveform.complexValue(variable: column, point: 0))
            real.append(sample.real)
            imaginary.append(sample.imag)
        }
        #expect(waveform.pointCount == 1)
        #expect(real == expected.map(\.real))
        #expect(imaginary == expected.map(\.imag))

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PoleZeroWaveformPersistence-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer {
            do { try FileManager.default.removeItem(at: directory) }
            catch { Issue.record(error) }
        }
        let jsonURL = directory.appendingPathComponent("pole-zero.json")
        let point = StoredPoint(metadata: waveform.metadata, variables: waveform.variables,
            sweepValues: waveform.sweepValues, real: real, imaginary: imaginary)
        try JSONEncoder().encode(point).write(to: jsonURL)
        let decoded = try JSONDecoder().decode(StoredPoint.self, from: Data(contentsOf: jsonURL))
        #expect(decoded.metadata.analysisType == .poleZero)
        #expect(decoded.metadata.pointCount == 1)
        #expect(decoded.metadata.isComplex)
        #expect(decoded.variables == waveform.variables)
        #expect(decoded.sweepValues == [0])
        #expect(decoded.real == expected.map(\.real))
        #expect(decoded.imaginary == expected.map(\.imag))

        let csvURL = directory.appendingPathComponent("pole-zero.csv")
        _ = try await SPICEIO.exportToCSV(waveform, path: csvURL.path)
        let reloaded = try CSVWaveformReader().read(contentsOfFile: csvURL.path)
        #expect(reloaded.pointCount == 1)
        #expect(reloaded.variableCount == expected.count)
        #expect(reloaded.isComplex)
        #expect(reloaded.sweepValues == [0])
        #expect(reloaded.variables.map(\.name) == waveform.variables.map(\.name))
        #expect(reloaded.variables.map(\.unit) == waveform.variables.map(\.unit))
        for (column, value) in expected.enumerated() {
            let actual = try #require(reloaded.complexValue(variable: column, point: 0))
            #expect(actual.real == value.real)
            #expect(actual.imag == value.imag)
            #expect(actual.real.isFinite && actual.imag.isFinite)
        }
    }
}
