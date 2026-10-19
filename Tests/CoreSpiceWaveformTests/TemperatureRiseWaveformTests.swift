import Testing
import CoreSpiceAnalysis
import CoreSpiceIR
import CoreSpiceWaveform

@Suite
struct TemperatureRiseWaveformTests {
    private let voltage = Node(id: 1)
    private let thermal = Node(id: 2)
    private let branch = Branch(id: 0)

    private var topology: CircuitTopology {
        CircuitTopology(ir: CircuitIR(
            nodes: [.ground, voltage, thermal],
            branches: [branch],
            instances: [],
            nodeNames: [voltage: "out", thermal: "N1.thermal"],
            branchNames: [branch: "V1"]
        ))
    }

    private var variableMap: [MNAVariable: Int] {
        [.nodeVoltage(thermal): 0, .branchCurrent(branch): 1, .nodeVoltage(voltage): 2]
    }

    @Test
    func mixedDescriptorsPreserveCompiledRowsAndSharedNumericalStorage() throws {
        let layout = try WaveformVariableLayout(
            validatingVariableMap: variableMap,
            topology: topology,
            temperatureRiseNodes: [thermal]
        )
        let result = try DCResult(variables: [14.5, -0.002, 0.6], variableMap: variableMap, iterations: 3)
        let waveform = try WaveformData.from(dcResult: result, variableLayout: layout)

        #expect(waveform.variables.map(\.name) == ["dT(N1.thermal)", "I(V1)", "V(out)"])
        #expect(waveform.variables.map(\.unit) == [.kelvin, .ampere, .volt])
        #expect(waveform.variables.map(\.type) == [.temperature, .current, .voltage])
        #expect(waveform.variables.map(\.index) == [0, 1, 2])
        #expect(waveform.realValue(variable: 0, point: 0) == 14.5)
        #expect(waveform.realValue(variable: 1, point: 0) == -0.002)
        #expect(waveform.realValue(variable: 2, point: 0) == 0.6)
        let sharesStorage = waveform.withRealRowMajorValues { values, points, columns in
            #expect(points == 1)
            #expect(columns == 3)
            return result.variables.withUnsafeBufferPointer { source in
                source.baseAddress == values.baseAddress
            }
        }
        #expect(sharesStorage == true)
    }

    @Test
    func thermalIdentityMustExistAndCannotBeGround() {
        for node in [Node(id: 99), .ground] {
            #expect(throws: WaveformValidationError.unknownTemperatureRiseNode(nodeID: node.id)) {
                _ = try WaveformVariableLayout(
                    validatingVariableMap: variableMap,
                    topology: topology,
                    temperatureRiseNodes: [node]
                )
            }
        }
    }

    @Test
    func rejectsSameWidthDifferentCompiledMap() throws {
        let layout = try WaveformVariableLayout(validatingVariableMap: variableMap, topology: topology)
        let result = try DCResult(
            variables: [1, 2, 3],
            variableMap: [.nodeVoltage(voltage): 0, .branchCurrent(branch): 1, .nodeVoltage(thermal): 2],
            iterations: 1
        )
        #expect(throws: WaveformValidationError.variableLayoutMapMismatch) {
            _ = try WaveformData.from(dcResult: result, variableLayout: layout)
        }
    }

    @Test
    func rejectsSolutionWidthNotCoveredByMap() throws {
        let map: [MNAVariable: Int] = [.nodeVoltage(thermal): 0]
        let layout = try WaveformVariableLayout(
            validatingVariableMap: map,
            topology: topology,
            temperatureRiseNodes: [thermal]
        )
        let result = try DCResult(variables: [1, 2], variableMap: map, iterations: 1)
        #expect(throws: WaveformValidationError.variableLayoutWidthMismatch(expected: 2, actual: 1)) {
            _ = try WaveformData.from(dcResult: result, variableLayout: layout)
        }
    }

    @Test
    func thermalLayoutRejectsInvalidCompiledIndex() {
        #expect(throws: WaveformValidationError.mnaVariableIndexOutOfRange(index: 1, variableCount: 1)) {
            _ = try WaveformVariableLayout(
                validatingVariableMap: [.nodeVoltage(thermal): 1],
                topology: topology,
                temperatureRiseNodes: [thermal]
            )
        }
    }

    @Test
    func defaultElectricalConversionRemainsUnchanged() throws {
        let map: [MNAVariable: Int] = [.nodeVoltage(voltage): 0, .branchCurrent(branch): 1]
        let result = try DCResult(variables: [0.6, -0.002], variableMap: map, iterations: 1)
        let waveform = WaveformData.from(dcResult: result, topology: topology)
        #expect(waveform.variables.map(\.name) == ["V(out)", "I(V1)"])
        #expect(waveform.variables.map(\.unit) == [.volt, .ampere])
        #expect(waveform.allRealData == [[0.6, -0.002]])
        #expect(VariableType.temperature.defaultUnit == .kelvin)
    }
}
