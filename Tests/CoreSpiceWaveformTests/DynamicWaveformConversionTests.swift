import Testing
import CoreSpiceAnalysis
import CoreSpiceCompile
import CoreSpiceIR
import CoreSpiceWaveform

@Suite
struct DynamicWaveformConversionTests {
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

    private func layout() throws -> WaveformVariableLayout {
        try WaveformVariableLayout(
            validatingVariableMap: variableMap,
            topology: topology,
            temperatureRiseNodes: [thermal]
        )
    }

    @Test
    func acPreservesComplexCompiledRowsAndThermalUnits() throws {
        let values = [
            [ComplexPair(real: 14, imag: -2), ComplexPair(real: -0.002, imag: 0.001), ComplexPair(real: 0.6, imag: -0.1)],
            [ComplexPair(real: 7, imag: -4), ComplexPair(real: -0.001, imag: 0.002), ComplexPair(real: 0.3, imag: -0.2)],
        ]
        let result = try ACResult(frequencies: [1e3, 2e3], solutions: values, variableMap: variableMap)
        let waveform = try WaveformData.from(acResult: result, variableLayout: layout())
        #expect(waveform.metadata.analysisType == .ac)
        #expect(waveform.isComplex)
        #expect(waveform.sweepValues == result.frequencies)
        #expect(waveform.variables.map(\.name) == ["dT(N1.thermal)", "I(V1)", "V(out)"])
        #expect(waveform.variables.map(\.unit) == [.kelvin, .ampere, .volt])
        #expect(waveform.variables.map(\.index) == [0, 1, 2])
        for point in values.indices {
            for column in values[point].indices {
                let value = try #require(waveform.complexValue(variable: column, point: point))
                #expect(value.real == values[point][column].real)
                #expect(value.imag == values[point][column].imag)
            }
        }
    }

    @Test
    func acAndTransientRejectSameWidthDifferentCompiledMap() throws {
        let changed: [MNAVariable: Int] = [
            .nodeVoltage(voltage): 0, .branchCurrent(branch): 1, .nodeVoltage(thermal): 2,
        ]
        let ac = try ACResult(
            frequencies: [1e3],
            solutions: [[ComplexPair(real: 1, imag: 2), ComplexPair(real: 3, imag: 4), ComplexPair(real: 5, imag: 6)]],
            variableMap: changed
        )
        let transient = try TransientResult(
            timePoints: [0, 1],
            solutionTrace: SolutionTrace(variableCount: 3, rowMajorValues: [1, 2, 3, 4, 5, 6]),
            variableMap: changed,
            timeSteps: 1,
            rejectedSteps: 0
        )
        #expect(throws: WaveformValidationError.variableLayoutMapMismatch) {
            _ = try WaveformData.from(acResult: ac, variableLayout: layout())
        }
        #expect(throws: WaveformValidationError.variableLayoutMapMismatch) {
            _ = try WaveformData.from(transientResult: transient, variableLayout: layout())
        }
    }

    @Test
    func acAndTransientRejectUnmappedSolutionColumns() throws {
        let map: [MNAVariable: Int] = [.nodeVoltage(voltage): 0]
        let incomplete = try WaveformVariableLayout(validatingVariableMap: map, topology: topology)
        let ac = try ACResult(
            frequencies: [1e3],
            solutions: [[ComplexPair(real: 1, imag: 2), ComplexPair(real: 3, imag: 4)]],
            variableMap: map
        )
        let transient = try TransientResult(
            timePoints: [0],
            solutionTrace: SolutionTrace(variableCount: 2, rowMajorValues: [1, 2]),
            variableMap: map,
            timeSteps: 0,
            rejectedSteps: 0
        )
        #expect(throws: WaveformValidationError.variableLayoutWidthMismatch(expected: 2, actual: 1)) {
            _ = try WaveformData.from(acResult: ac, variableLayout: incomplete)
        }
        #expect(throws: WaveformValidationError.variableLayoutWidthMismatch(expected: 2, actual: 1)) {
            _ = try WaveformData.from(transientResult: transient, variableLayout: incomplete)
        }
    }

    @Test
    func transientPreservesThermalRowsAndSharedTraceStorage() throws {
        let result = try TransientResult(
            timePoints: [0, 1],
            solutionTrace: SolutionTrace(variableCount: 3, rowMajorValues: [14, -0.002, 0.6, 15, -0.003, 0.7]),
            variableMap: variableMap,
            timeSteps: 1,
            rejectedSteps: 0
        )
        let waveform = try WaveformData.from(transientResult: result, variableLayout: layout())
        #expect(waveform.metadata.analysisType == .transient)
        #expect(waveform.variables.map(\.unit) == [.kelvin, .ampere, .volt])
        #expect(waveform.realRowMajorValues?.values == result.solutionTrace.rowMajorValues)
        let sharesStorage = waveform.withRealRowMajorValues { values, _, _ in
            result.solutionTrace.rowMajorValues.withUnsafeBufferPointer { source in
                source.baseAddress == values.baseAddress
            }
        }
        #expect(sharesStorage == true)
    }

    @Test(arguments: [NoiseInputQuantity.voltage, .current])
    func noisePreservesPSDScaleAndInputQuantity(quantity: NoiseInputQuantity) throws {
        let result = try NoiseResult(
            frequencies: [1e3, 2e3],
            outputNoiseDensity: [1e-18, 2e-18],
            inputReferredNoiseDensity: [4e-20, 8e-20],
            integratedOutputNoise: 1.5e-9,
            deviceContributions: [],
            variableMap: [:],
            inputQuantity: quantity
        )
        let waveform = WaveformData.from(noiseResult: result)
        let inputUnit: SIUnit = quantity == .current ? .ampereSquaredPerHertz : .voltSquaredPerHertz
        #expect(waveform.variables.map(\.unit) == [.voltSquaredPerHertz, inputUnit, .volt])
        #expect(waveform.variables.map(\.type) == [.noiseDensity, .noiseDensity, .voltage])
        #expect(waveform.allRealData == [[1e-18, 4e-20, 1.5e-9], [2e-18, 8e-20, 1.5e-9]])
    }
}
