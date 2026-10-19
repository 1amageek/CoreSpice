import Foundation
import Testing
import CoreSpiceExporterCSV
import CoreSpiceWaveform

@Suite
struct DynamicWaveformExportTests {
    private let variables: [VariableDescriptor] = [
        VariableDescriptor(name: "dT(N1.thermal)", unit: .kelvin, type: .temperature, index: 0),
        .current(device: "V1", index: 1),
        .voltage(node: "out", index: 2),
    ]

    private func reload(_ waveform: any WaveformReadable) async throws -> WaveformData {
        let exported = try await CSVExporter().export(waveform, to: .memory, configuration: .highPrecision)
        let bytes = try #require(exported.data)
        let text = try #require(String(data: bytes, encoding: .utf8))
        return try CSVWaveformReader().read(text)
    }

    @Test
    func complexThermalElectricalRowsAndReorderedProjectionRoundtrip() async throws {
        let waveform = WaveformData(
            metadata: SimulationMetadata(analysisType: .ac, pointCount: 2, variableCount: 3, isComplex: true),
            sweepVariable: .frequency(),
            sweepValues: [1e3, 2e3],
            variables: variables,
            complexData: [[(14, -2), (-0.002, 0.001), (0.6, -0.1)], [(7, -4), (-0.001, 0.002), (0.3, -0.2)]]
        )
        let reloaded = try await reload(waveform)
        #expect(reloaded.metadata.analysisType == .ac)
        #expect(reloaded.variables == waveform.variables)
        #expect(reloaded.sweepValues == waveform.sweepValues)
        for point in 0..<waveform.pointCount {
            for column in 0..<waveform.variableCount {
                let expected = try #require(waveform.complexValue(variable: column, point: point))
                let actual = try #require(reloaded.complexValue(variable: column, point: point))
                #expect(actual.real == expected.real)
                #expect(actual.imag == expected.imag)
            }
        }
        let projection = try WaveformDataView(validatingBase: waveform, pointIndices: [1], variableIndices: [2, 0])
        let projected = try await reload(projection)
        #expect(projected.variables == projection.variables)
        #expect(projected.sweepValues == [2e3])
        #expect(projected.variables.map(\.unit) == [.volt, .kelvin])
        #expect(projected.complexValue(variable: 0, point: 0)?.imag == -0.2)
        #expect(projected.complexValue(variable: 1, point: 0)?.real == 7)
    }

    @Test
    func transientMixedPhysicalUnitsRoundtrip() async throws {
        let waveform = WaveformData(
            metadata: SimulationMetadata(analysisType: .transient, pointCount: 2, variableCount: 3),
            sweepVariable: .time(),
            sweepValues: [0, 1e-9],
            variables: variables,
            realRowMajorData: [14, -0.002, 0.6, 15, -0.003, 0.7],
            pointCount: 2,
            variableCount: 3
        )
        let reloaded = try await reload(waveform)
        #expect(reloaded.metadata.analysisType == .transient)
        #expect(reloaded.variables == waveform.variables)
        #expect(reloaded.sweepValues == waveform.sweepValues)
        #expect(reloaded.allRealData == waveform.allRealData)
    }

    @Test(arguments: [SIUnit.voltSquaredPerHertz, .ampereSquaredPerHertz])
    func noisePhysicalUnitsAndPSDValuesRoundtrip(inputUnit: SIUnit) async throws {
        let waveform = WaveformData(
            metadata: SimulationMetadata(analysisType: .noise, pointCount: 2, variableCount: 3),
            sweepVariable: .frequency(),
            sweepValues: [1e3, 2e3],
            variables: [
                VariableDescriptor(name: "output_noise_density", unit: .voltSquaredPerHertz, type: .noiseDensity, index: 0),
                VariableDescriptor(name: "input_referred_noise_density", unit: inputUnit, type: .noiseDensity, index: 1),
                VariableDescriptor(name: "integrated_output_noise", unit: .volt, type: .voltage, index: 2),
            ],
            realData: [[1e-18, 4e-20, 1.5e-9], [2e-18, 8e-20, 1.5e-9]]
        )
        let reloaded = try await reload(waveform)
        #expect(reloaded.metadata.analysisType == .noise)
        #expect(reloaded.variables == waveform.variables)
        #expect(reloaded.allRealData == waveform.allRealData)
        let descriptors = try JSONDecoder().decode(
            [VariableDescriptor].self, from: JSONEncoder().encode(waveform.variables)
        )
        #expect(descriptors == waveform.variables)
        #expect(inputUnit.rawFileString == inputUnit.rawValue)
        let projected = try WaveformDataView(validatingBase: waveform, variableIndices: [1])
        let reloadedProjection = try await reload(projected)
        #expect(reloadedProjection.metadata.analysisType == .noise)
        #expect(reloadedProjection.variables == projected.variables)
        #expect(reloadedProjection.realValue(variable: 0, point: 1) == 8e-20)
    }

    @Test
    func complexPartnersRequireIdenticalDeclaredUnits() {
        for header in ["V(out)_real [V],V(out)_imag [A]", "V(out)_real [V],V(out)_imag"] {
            #expect(throws: CSVWaveformReadError.complexUnitMismatch(name: "V(out)")) {
                _ = try CSVWaveformReader().read("frequency [Hz],\(header)\n1000,1,2\n")
            }
        }
    }

    @Test
    func unitlessNoiseDoesNotInventInputQuantity() throws {
        let waveform = try CSVWaveformReader().read(
            "frequency,output_noise_density,input_referred_noise_density,integrated_output_noise\n1000,1e-18,4e-20,1e-9\n"
        )
        #expect(waveform.metadata.analysisType == .noise)
        #expect(waveform.variables.map(\.unit) == [.dimensionless, .dimensionless, .volt])
        #expect(waveform.variables.map(\.type) == [.noiseDensity, .noiseDensity, .voltage])
    }
}
