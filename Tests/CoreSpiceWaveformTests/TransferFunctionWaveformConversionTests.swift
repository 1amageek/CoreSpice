import CoreSpiceAnalysis
import CoreSpiceWaveform
import Testing

@Suite(.timeLimit(.minutes(1)))
struct TransferFunctionWaveformConversionTests {
    private final class StorageMarker: Sendable {}

    @Test(arguments: [false, true], [false, true])
    func typedPortsSelectFiniteColumnsAndAlwaysRetainBothClassifications(inputOpen: Bool, outputOpen: Bool) throws {
        let result = try TransferFunctionResult(
            gain: 0.25,
            inputPortImpedance: inputOpen ? .openCircuit : .finite(0),
            outputPortImpedance: outputOpen ? .openCircuit : .finite(-250),
            dcOperatingPoint: DCResult(variables: [], variableMap: [:], iterations: 0),
            variableMap: [:]
        )
        let waveform = WaveformData.from(transferFunctionResult: result, title: "Transfer Function")
        var names = ["gain"]
        var values = [0.25]
        var units: [SIUnit] = [.dimensionless]
        if !inputOpen { names.append("Zin"); values.append(0); units.append(.ohm) }
        if !outputOpen { names.append("Zout"); values.append(-250); units.append(.ohm) }
        #expect(waveform.metadata.title == "Transfer Function")
        #expect(waveform.metadata.analysisType == .transferFunction)
        #expect(waveform.metadata.pointCount == 1)
        #expect(waveform.metadata.variableCount == names.count)
        #expect(waveform.metadata.options == [
            "input_port_impedance": inputOpen ? "open_circuit" : "finite",
            "output_port_impedance": outputOpen ? "open_circuit" : "finite",
        ])
        #expect(!waveform.isComplex)
        #expect(waveform.sweepValues == [0])
        #expect(waveform.variables.map(\.name) == names)
        #expect(waveform.variables.map(\.index) == Array(names.indices))
        #expect(waveform.variables.map(\.unit) == units)
        #expect(waveform.allRealData == [values])
        #expect(values.allSatisfy { $0.isFinite })
    }

    @Test
    func gainOnlyProjectionRetainsExactExistingStorageOwner() throws {
        let owner = StorageMarker()
        let result = try TransferFunctionResult(
            gain: 0, inputPortImpedance: .openCircuit, outputPortImpedance: .openCircuit,
            dcOperatingPoint: DCResult(variables: [], variableMap: [:], iterations: 0), variableMap: [:]
        ).retainingStorage(owner)
        let waveform = WaveformData.from(transferFunctionResult: result)
        #expect((waveform.retainedStorage as? StorageMarker) === owner)
        #expect(waveform.variables.map(\.name) == ["gain"])
        #expect(waveform.allRealData == [[0]])
    }
}
