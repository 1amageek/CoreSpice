import Foundation
import Testing
import CoreSpiceExporterCSV
import CoreSpiceExporterRAW
import CoreSpiceWaveform

@Suite
struct TemperatureRiseExportTests {
    private var waveform: WaveformData {
        WaveformData(
            metadata: SimulationMetadata(analysisType: .operatingPoint, pointCount: 1, variableCount: 3),
            sweepVariable: VariableDescriptor(name: "point", unit: .dimensionless, type: .parameter, index: 0),
            sweepValues: [0],
            variables: [
                .voltage(node: "out", index: 0),
                VariableDescriptor(name: "dT(N1.thermal)", unit: .kelvin, type: .temperature, index: 1),
                .current(device: "V1", index: 2),
            ],
            realRowMajorData: [0.6, 14.5, -0.002],
            pointCount: 1,
            variableCount: 3
        )
    }

    @Test
    func csvPreservesMixedUnitsAndTemperatureRiseAcrossReload() async throws {
        let exported = try await CSVExporter().export(waveform, to: .memory, configuration: .default)
        let data = try #require(exported.data)
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(text.contains("dT(N1.thermal) [K]"))
        let reloaded = try CSVWaveformReader().read(text)
        #expect(reloaded.variables == waveform.variables)
        #expect(reloaded.allRealData == waveform.allRealData)
    }

    @Test
    func csvWithoutUnitSuffixRetainsTemperatureRiseMeaning() async throws {
        let exported = try await CSVExporter(includeUnits: false).export(
            waveform, to: .memory, configuration: .default
        )
        let data = try #require(exported.data)
        let text = try #require(String(data: data, encoding: .utf8))
        let reloaded = try CSVWaveformReader().read(text)
        #expect(reloaded.variables == waveform.variables)
        #expect(reloaded.realValue(variable: 1, point: 0) == 14.5)
    }

    @Test
    func rawExportsExplicitKelvinUnitAtThermalColumn() async throws {
        let exported = try await RAWExporter(useBinaryFormat: false).export(
            waveform, to: .memory, configuration: .default
        )
        let data = try #require(exported.data)
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(text.contains("\t1\tV(out)\tV\n"))
        #expect(text.contains("\t2\tdT(N1.thermal)\tK\n"))
        #expect(text.contains("\t3\tI(V1)\tA\n"))
    }

    @Test
    func kelvinDescriptorCodableRoundtrip() throws {
        let descriptor = waveform.variables[1]
        let decoded = try JSONDecoder().decode(VariableDescriptor.self, from: JSONEncoder().encode(descriptor))
        #expect(decoded == descriptor)
        #expect(SIUnit.kelvin.rawFileString == "K")
        #expect(SIUnit.kelvin.pluralName == "kelvins")
    }
}
