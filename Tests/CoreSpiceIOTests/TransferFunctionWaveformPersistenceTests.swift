import Foundation
import CoreSpiceIO
import Testing

@Suite(.timeLimit(.minutes(1)))
struct TransferFunctionWaveformPersistenceTests {
    private struct StoredPoint: Codable {
        let metadata: SimulationMetadata
        let variables: [VariableDescriptor]
        let sweepValues: [Double]
        let values: [[Double]]
    }

    @Test(arguments: [false, true], [false, true])
    func strictJSONRetainsPortClassificationsAndCSVRetainsFiniteColumns(inputOpen: Bool, outputOpen: Bool) async throws {
        let result = try TransferFunctionResult(
            gain: 0.25,
            inputPortImpedance: inputOpen ? .openCircuit : .finite(0),
            outputPortImpedance: outputOpen ? .openCircuit : .finite(-250),
            dcOperatingPoint: DCResult(variables: [], variableMap: [:], iterations: 0), variableMap: [:]
        )
        let waveform = WaveformData.from(transferFunctionResult: result)
        var expected = [0.25]
        if !inputOpen { expected.append(0) }
        if !outputOpen { expected.append(-250) }
        #expect(waveform.allRealData == [expected])

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TransferFunctionWaveformPersistence-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer {
            do { try FileManager.default.removeItem(at: directory) }
            catch { Issue.record(error) }
        }
        let jsonURL = directory.appendingPathComponent("transfer-function.json")
        let values = try #require(waveform.allRealData)
        let point = StoredPoint(metadata: waveform.metadata, variables: waveform.variables,
            sweepValues: waveform.sweepValues, values: values)
        try JSONEncoder().encode(point).write(to: jsonURL)
        let decoded = try JSONDecoder().decode(StoredPoint.self, from: Data(contentsOf: jsonURL))
        #expect(decoded.metadata.analysisType == .transferFunction)
        #expect(decoded.metadata.options == [
            "input_port_impedance": inputOpen ? "open_circuit" : "finite",
            "output_port_impedance": outputOpen ? "open_circuit" : "finite",
        ])
        #expect(decoded.variables == waveform.variables)
        #expect(decoded.sweepValues == [0])
        #expect(decoded.values == [expected])

        let csvURL = directory.appendingPathComponent("transfer-function.csv")
        _ = try await SPICEIO.exportToCSV(waveform, path: csvURL.path)
        let reloaded = try CSVWaveformReader().read(contentsOfFile: csvURL.path)
        #expect(reloaded.pointCount == 1)
        #expect(reloaded.variableCount == expected.count)
        #expect(!reloaded.isComplex)
        #expect(reloaded.variables.map(\.name) == waveform.variables.map(\.name))
        #expect(reloaded.variables.map(\.unit) == waveform.variables.map(\.unit))
        #expect(reloaded.sweepValues == [0])
        #expect(reloaded.allRealData == [expected])
    }
}
