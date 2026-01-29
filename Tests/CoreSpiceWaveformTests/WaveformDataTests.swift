import Testing
@testable import CoreSpiceWaveform

@Suite
struct WaveformDataTests {

    @Test
    func realWaveformCreation() {
        let metadata = SimulationMetadata(
            title: "Test",
            analysisType: .transient,
            pointCount: 3,
            variableCount: 2
        )

        let sweepVar = VariableDescriptor.time()
        let vars = [
            VariableDescriptor.voltage(node: "out", index: 0),
            VariableDescriptor.current(device: "R1", index: 1)
        ]

        let data: [[Double]] = [
            [1.0, 0.001],
            [2.0, 0.002],
            [3.0, 0.003]
        ]

        let waveform = WaveformData(
            metadata: metadata,
            sweepVariable: sweepVar,
            sweepValues: [0.0, 1e-9, 2e-9],
            variables: vars,
            realData: data
        )

        #expect(waveform.pointCount == 3)
        #expect(waveform.variableCount == 2)
        #expect(!waveform.isComplex)

        let value = waveform.realValue(variable: 0, point: 1)
        #expect(value == 2.0)
    }

    @Test
    func complexWaveformCreation() {
        let metadata = SimulationMetadata(
            title: "AC Test",
            analysisType: .ac,
            pointCount: 2,
            variableCount: 1,
            isComplex: true
        )

        let sweepVar = VariableDescriptor.frequency()
        let vars = [VariableDescriptor.voltage(node: "out", index: 0)]

        let data: [[(real: Double, imag: Double)]] = [
            [(real: 1.0, imag: 0.5)],
            [(real: 0.5, imag: 0.25)]
        ]

        let waveform = WaveformData(
            metadata: metadata,
            sweepVariable: sweepVar,
            sweepValues: [1e3, 1e4],
            variables: vars,
            complexData: data
        )

        #expect(waveform.isComplex)

        let complex = waveform.complexValue(variable: 0, point: 0)
        #expect(complex?.real == 1.0)
        #expect(complex?.imag == 0.5)

        let mag = waveform.magnitude(variable: 0, point: 0)
        #expect(mag != nil)
        #expect(abs(mag! - 1.118) < 0.01)
    }

    @Test
    func waveformExtraction() {
        let metadata = SimulationMetadata(
            analysisType: .transient,
            pointCount: 3,
            variableCount: 1
        )

        let sweepVar = VariableDescriptor.time()
        let vars = [VariableDescriptor.voltage(node: "out", index: 0)]
        let data: [[Double]] = [[1.0], [2.0], [3.0]]

        let waveform = WaveformData(
            metadata: metadata,
            sweepVariable: sweepVar,
            sweepValues: [0.0, 1.0, 2.0],
            variables: vars,
            realData: data
        )

        let extracted = waveform.realWaveform(named: "V(out)")
        #expect(extracted != nil)
        #expect(extracted?.count == 3)
        #expect(extracted?[1] == 2.0)
    }
}

@Suite
struct ParametricWaveformDataTests {

    @Test
    func createParametricData() {
        let runs = (0..<5).map { i in
            let metadata = SimulationMetadata(
                analysisType: .transient,
                pointCount: 3,
                variableCount: 1
            )
            let waveform = WaveformData(
                metadata: metadata,
                sweepVariable: .time(),
                sweepValues: [0.0, 1.0, 2.0],
                variables: [.voltage(node: "out", index: 0)],
                realData: [[Double(i) + 1.0], [Double(i) + 2.0], [Double(i) + 3.0]]
            )
            return ParametricWaveformData.Run(
                index: i,
                parameters: ["vdd": 1.8 + Double(i) * 0.1],
                waveform: waveform
            )
        }

        let parametric = ParametricWaveformData(
            runs: runs,
            analysisType: .transient,
            title: "Monte Carlo",
            parameterNames: ["vdd"]
        )

        #expect(parametric.runCount == 5)
        #expect(parametric.analysisType == .transient)
        #expect(parametric.parameterNames == ["vdd"])
    }

    @Test
    func pointStatistics() {
        // Create 5 runs with known values at each point
        // Point 0: values [1, 2, 3, 4, 5] -> mean=3, stddev=√2.5
        let runs = (0..<5).map { i in
            let metadata = SimulationMetadata(
                analysisType: .transient,
                pointCount: 1,
                variableCount: 1
            )
            let waveform = WaveformData(
                metadata: metadata,
                sweepVariable: .time(),
                sweepValues: [0.0],
                variables: [.voltage(node: "out", index: 0)],
                realData: [[Double(i + 1)]]
            )
            return ParametricWaveformData.Run(
                index: i,
                parameters: [:],
                waveform: waveform
            )
        }

        let parametric = ParametricWaveformData(
            runs: runs,
            analysisType: .transient,
            parameterNames: []
        )

        let stats = parametric.statistics(forVariable: "V(out)", atSweepIndex: 0)
        #expect(stats != nil)
        #expect(stats?.mean == 3.0)
        #expect(stats?.minimum == 1.0)
        #expect(stats?.maximum == 5.0)
        #expect(stats?.sampleCount == 5)
        #expect(abs((stats?.standardDeviation ?? 0) - 1.5811) < 0.01)
    }

    @Test
    func waveformStatistics() {
        let runs = (0..<10).map { i in
            let metadata = SimulationMetadata(
                analysisType: .transient,
                pointCount: 3,
                variableCount: 1
            )
            // Each run has values that vary by index
            let baseValue = Double(i)
            let waveform = WaveformData(
                metadata: metadata,
                sweepVariable: .time(),
                sweepValues: [0.0, 1.0, 2.0],
                variables: [.voltage(node: "out", index: 0)],
                realData: [[baseValue], [baseValue + 10.0], [baseValue + 20.0]]
            )
            return ParametricWaveformData.Run(
                index: i,
                parameters: [:],
                waveform: waveform
            )
        }

        let parametric = ParametricWaveformData(
            runs: runs,
            analysisType: .transient,
            parameterNames: []
        )

        let stats = parametric.statistics(forVariable: "V(out)")
        #expect(stats != nil)
        #expect(stats?.pointCount == 3)
        #expect(stats?.runCount == 10)

        // Point 0: values 0-9, mean = 4.5
        #expect(abs((stats?.mean[0] ?? 0) - 4.5) < 0.01)
        // Point 1: values 10-19, mean = 14.5
        #expect(abs((stats?.mean[1] ?? 0) - 14.5) < 0.01)
    }

    @Test
    func runWithMinMax() {
        let runs = (0..<3).map { i in
            let metadata = SimulationMetadata(
                analysisType: .transient,
                pointCount: 1,
                variableCount: 1
            )
            let waveform = WaveformData(
                metadata: metadata,
                sweepVariable: .time(),
                sweepValues: [0.0],
                variables: [.voltage(node: "out", index: 0)],
                realData: [[Double(i) * 10.0]]  // 0, 10, 20
            )
            return ParametricWaveformData.Run(
                index: i,
                parameters: [:],
                waveform: waveform
            )
        }

        let parametric = ParametricWaveformData(
            runs: runs,
            analysisType: .transient,
            parameterNames: []
        )

        let minRun = parametric.runWithMinimum(of: "V(out)", at: 0)
        let maxRun = parametric.runWithMaximum(of: "V(out)", at: 0)

        #expect(minRun?.index == 0)
        #expect(maxRun?.index == 2)
    }
}

@Suite
struct VariableDescriptorTests {

    @Test
    func voltageDescriptor() {
        let desc = VariableDescriptor.voltage(node: "vdd", index: 0)
        #expect(desc.name == "V(vdd)")
        #expect(desc.unit == .volt)
        #expect(desc.type == .voltage)
    }

    @Test
    func currentDescriptor() {
        let desc = VariableDescriptor.current(device: "R1", index: 1)
        #expect(desc.name == "I(R1)")
        #expect(desc.unit == .ampere)
        #expect(desc.type == .current)
    }

    @Test
    func timeDescriptor() {
        let desc = VariableDescriptor.time()
        #expect(desc.name == "time")
        #expect(desc.unit == .second)
        #expect(desc.type == .time)
    }

    @Test
    func frequencyDescriptor() {
        let desc = VariableDescriptor.frequency()
        #expect(desc.name == "frequency")
        #expect(desc.unit == .hertz)
        #expect(desc.type == .frequency)
    }
}
