import Foundation
import Testing
import CoreSpiceAnalysis
import CoreSpiceIR
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
    func rowMajorWaveformCreation() {
        let metadata = SimulationMetadata(
            title: "Row Major Test",
            analysisType: .transient,
            pointCount: 3,
            variableCount: 2
        )

        let waveform = WaveformData(
            metadata: metadata,
            sweepVariable: .time(),
            sweepValues: [0.0, 1.0, 2.0],
            variables: [
                .voltage(node: "1", index: 0),
                .current(device: "V1", index: 1)
            ],
            realRowMajorData: [
                1.0, 0.1,
                2.0, 0.2,
                3.0, 0.3
            ],
            pointCount: 3,
            variableCount: 2
        )

        #expect(waveform.pointCount == 3)
        #expect(waveform.variableCount == 2)
        #expect(!waveform.isComplex)
        #expect(waveform.realValue(variable: 1, point: 2) == 0.3)
        #expect(waveform.allRealData == [[1.0, 0.1], [2.0, 0.2], [3.0, 0.3]])
    }

    @Test
    func realSeriesViewReadsLazyProjection() {
        let waveform = WaveformData(
            metadata: SimulationMetadata(
                title: "Series View",
                analysisType: .transient,
                pointCount: 3,
                variableCount: 2
            ),
            sweepVariable: .time(),
            sweepValues: [0.0, 1.0, 2.0],
            variables: [
                .voltage(node: "1", index: 0),
                .current(device: "V1", index: 1)
            ],
            realRowMajorData: [
                1.0, 0.1,
                2.0, 0.2,
                3.0, 0.3
            ],
            pointCount: 3,
            variableCount: 2
        )
        let view = WaveformDataView(
            base: waveform,
            pointIndices: [1, 2],
            variableIndices: [1]
        )

        guard let series = view.realSeries(named: "I(V1)") else {
            Issue.record("Expected lazy series view")
            return
        }

        #expect(series.count == 2)
        #expect(series.sweepValue(at: 0) == 1.0)
        #expect(series[0] == 0.2)
        #expect(series[1] == 0.3)
        #expect(series.materialized().values == [0.2, 0.3])
    }

    @Test
    func prevalidatedProjectionCanBeReusedForViews() {
        let waveform = WaveformData(
            metadata: SimulationMetadata(
                title: "Projection Reuse",
                analysisType: .transient,
                pointCount: 4,
                variableCount: 3
            ),
            sweepVariable: .time(),
            sweepValues: [0.0, 1.0, 2.0, 3.0],
            variables: [
                .voltage(node: "1", index: 0),
                .voltage(node: "2", index: 1),
                .current(device: "V1", index: 2)
            ],
            realRowMajorData: [
                1.0, 10.0, 100.0,
                2.0, 20.0, 200.0,
                3.0, 30.0, 300.0,
                4.0, 40.0, 400.0
            ],
            pointCount: 4,
            variableCount: 3
        )
        let projection = WaveformProjection(
            basePointCount: waveform.pointCount,
            baseVariableCount: waveform.variableCount,
            pointIndices: [1, 3],
            variableIndices: [1, 2]
        )

        let first = WaveformDataView(base: waveform, projection: projection)
        let second = WaveformDataView(base: waveform, projection: projection)

        #expect(first.pointCount == 2)
        #expect(first.variableCount == 2)
        #expect(first.realValue(variable: 0, point: 0) == 20.0)
        #expect(first.realValue(variable: 1, point: 1) == 400.0)
        #expect(second.variables.map(\.name) == ["V(2)", "I(V1)"])
    }

    @Test
    func precomputedViewLayoutCanBeReusedForViews() {
        let date = Date(timeIntervalSince1970: 1_234)
        let waveform = WaveformData(
            metadata: SimulationMetadata(
                title: "Projection Layout",
                date: date,
                tool: "FixtureSpice",
                toolVersion: "1.0",
                analysisType: .transient,
                temperature: 27.0,
                pointCount: 5,
                variableCount: 3,
                options: ["mode": "test"]
            ),
            sweepVariable: .time(),
            sweepValues: [0.0, 1.0, 2.0, 3.0, 4.0],
            variables: [
                .voltage(node: "1", index: 0),
                .voltage(node: "2", index: 1),
                .current(device: "V1", index: 2)
            ],
            realRowMajorData: [
                1.0, 10.0, 100.0,
                2.0, 20.0, 200.0,
                3.0, 30.0, 300.0,
                4.0, 40.0, 400.0,
                5.0, 50.0, 500.0
            ],
            pointCount: 5,
            variableCount: 3
        )
        let projection = WaveformProjection(
            basePointCount: waveform.pointCount,
            baseVariableCount: waveform.variableCount,
            pointIndices: [0, 2, 4],
            variableIndices: [1, 2]
        )
        let layout = WaveformViewLayout(base: waveform, projection: projection)

        let first = WaveformDataView(base: waveform, layout: layout)
        let second = WaveformDataView(base: waveform, layout: layout)

        #expect(layout.projection.regularPointPattern?.start == 0)
        #expect(layout.projection.regularPointPattern?.stride == 2)
        #expect(first.metadata.date == date)
        #expect(first.metadata.tool == "FixtureSpice")
        #expect(first.metadata.toolVersion == "1.0")
        #expect(first.metadata.temperature == 27.0)
        #expect(first.metadata.options == ["mode": "test"])
        #expect(first.metadata.pointCount == 3)
        #expect(first.metadata.variableCount == 2)
        #expect(first.variables.map(\.name) == ["V(2)", "I(V1)"])
        #expect(second.realValue(variable: 0, point: 2) == 50.0)
    }

    @Test
    func projectedViewExposesStridedRowMajorBuffer() {
        let waveform = WaveformData(
            metadata: SimulationMetadata(
                title: "Projected Buffer",
                analysisType: .transient,
                pointCount: 5,
                variableCount: 3
            ),
            sweepVariable: .time(),
            sweepValues: [0.0, 1.0, 2.0, 3.0, 4.0],
            variables: [
                .voltage(node: "1", index: 0),
                .voltage(node: "2", index: 1),
                .current(device: "V1", index: 2)
            ],
            realRowMajorData: [
                1.0, 10.0, 100.0,
                2.0, 20.0, 200.0,
                3.0, 30.0, 300.0,
                4.0, 40.0, 400.0,
                5.0, 50.0, 500.0
            ],
            pointCount: 5,
            variableCount: 3
        )
        let view = WaveformDataView(
            base: waveform,
            pointIndices: [0, 2, 4],
            variableIndices: [1, 2]
        )

        let values = view.withRealRowMajorBuffer { buffer in
            #expect(buffer.pointCount == 3)
            #expect(buffer.variableCount == 2)
            #expect(buffer.rowStride == 6)
            #expect(buffer.startOffset == 1)
            #expect(buffer.value(point: 0, variable: 0) == 10.0)
            #expect(buffer.value(point: 1, variable: 1) == 300.0)
            #expect(buffer.value(point: 2, variable: 0) == 50.0)
            return (0..<buffer.pointCount).flatMap { point in
                (0..<buffer.variableCount).map { variable in
                    buffer.value(point: point, variable: variable) ?? .nan
                }
            }
        }

        #expect(values == [10.0, 100.0, 30.0, 300.0, 50.0, 500.0])
    }

    @Test
    func transientConversionPreservesRowMajorStorageSharing() {
        let node = Node(id: 1)
        let branch = Branch(id: 1)
        let trace = SolutionTrace(
            variableCount: 2,
            rowMajorValues: [
                1.0, 0.1,
                2.0, 0.2,
                3.0, 0.3
            ]
        )
        let result = TransientResult(
            timePoints: [0.0, 1.0, 2.0],
            solutionTrace: trace,
            variableMap: [
                .nodeVoltage(node): 0,
                .branchCurrent(branch): 1
            ],
            timeSteps: 2,
            rejectedSteps: 0
        )
        let topology = CircuitTopology(ir: CircuitIR(
            nodes: [.ground, node],
            branches: [branch],
            instances: []
        ))

        let waveform = WaveformData.from(
            transientResult: result,
            topology: topology,
            title: "Converted"
        )

        guard let rowMajor = waveform.realRowMajorValues else {
            Issue.record("Converted transient waveform should expose row-major storage")
            return
        }

        let source = result.solutionTrace.rowMajorValues
        let sharesStorage = source.withUnsafeBufferPointer { sourceBuffer in
            rowMajor.values.withUnsafeBufferPointer { rowMajorBuffer in
                sourceBuffer.baseAddress == rowMajorBuffer.baseAddress
            }
        }

        #expect(sharesStorage)
        #expect(waveform.variables.map(\.name) == ["V(1)", "I(1)"])
        #expect(waveform.realValue(variable: 0, point: 2) == 3.0)
    }

    @Test
    func transientConversionUsesPrecomputedVariableLayout() {
        let node = Node(id: 1)
        let trace = SolutionTrace(
            variableCount: 1,
            rowMajorValues: [1.0, 2.0]
        )
        let result = TransientResult(
            timePoints: [0.0, 1.0],
            solutionTrace: trace,
            variableMap: [.nodeVoltage(node): 0],
            timeSteps: 1,
            rejectedSteps: 0
        )
        let topology = CircuitTopology(ir: CircuitIR(
            nodes: [.ground, node],
            branches: [],
            instances: []
        ))
        let layout = WaveformVariableLayout(variableMap: result.variableMap, topology: topology)
        let waveform = WaveformData.from(
            transientResult: result,
            variableLayout: layout,
            title: "Converted"
        )

        #expect(waveform.variables.map(\.name) == ["V(1)"])
        #expect(waveform.realValue(variable: 0, point: 1) == 2.0)
    }

    @Test
    func rowMajorPointBufferBorrowsStorage() {
        let waveform = WaveformData(
            metadata: SimulationMetadata(
                title: "Point Buffer",
                analysisType: .transient,
                pointCount: 3,
                variableCount: 2
            ),
            sweepVariable: .time(),
            sweepValues: [0.0, 1.0, 2.0],
            variables: [
                .voltage(node: "1", index: 0),
                .current(device: "V1", index: 1)
            ],
            realRowMajorData: [
                1.0, 0.1,
                2.0, 0.2,
                3.0, 0.3
            ],
            pointCount: 3,
            variableCount: 2
        )

        guard let rowMajor = waveform.realRowMajorValues else {
            Issue.record("Row-major waveform should expose row-major storage")
            return
        }

        let sharesStorage = rowMajor.values.withUnsafeBufferPointer { storage in
            waveform.withRealValues(at: 1) { point in
                #expect(Array(point) == [2.0, 0.2])
                return point.baseAddress == storage.baseAddress.map { $0 + 2 }
            } ?? false
        }

        #expect(sharesStorage)
    }

    @Test
    func rowMajorWholeBufferBorrowsStorage() {
        let waveform = WaveformData(
            metadata: SimulationMetadata(
                title: "Whole Buffer",
                analysisType: .transient,
                pointCount: 2,
                variableCount: 2
            ),
            sweepVariable: .time(),
            sweepValues: [0.0, 1.0],
            variables: [
                .voltage(node: "1", index: 0),
                .current(device: "V1", index: 1)
            ],
            realRowMajorData: [
                1.0, 0.1,
                2.0, 0.2
            ],
            pointCount: 2,
            variableCount: 2
        )

        guard let rowMajor = waveform.realRowMajorValues else {
            Issue.record("Row-major waveform should expose storage")
            return
        }

        let sharesStorage = rowMajor.values.withUnsafeBufferPointer { storage in
            waveform.withRealRowMajorValues { values, pointCount, variableCount in
                #expect(pointCount == 2)
                #expect(variableCount == 2)
                #expect(Array(values) == [1.0, 0.1, 2.0, 0.2])
                return values.baseAddress == storage.baseAddress
            } ?? false
        }

        #expect(sharesStorage)
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
    func valueAccessRejectsNegativeIndices() {
        let realWaveform = WaveformData(
            metadata: SimulationMetadata(analysisType: .transient, pointCount: 1, variableCount: 1),
            sweepVariable: .time(),
            sweepValues: [0.0],
            variables: [.voltage(node: "out", index: 0)],
            realData: [[1.0]]
        )
        let rowMajorWaveform = WaveformData(
            metadata: SimulationMetadata(analysisType: .transient, pointCount: 1, variableCount: 1),
            sweepVariable: .time(),
            sweepValues: [0.0],
            variables: [.voltage(node: "out", index: 0)],
            realRowMajorData: [1.0],
            pointCount: 1,
            variableCount: 1
        )
        let complexWaveform = WaveformData(
            metadata: SimulationMetadata(analysisType: .ac, pointCount: 1, variableCount: 1, isComplex: true),
            sweepVariable: .frequency(),
            sweepValues: [1.0],
            variables: [.voltage(node: "out", index: 0)],
            complexData: [[(real: 1.0, imag: 0.5)]]
        )

        for waveform in [realWaveform, rowMajorWaveform, complexWaveform] {
            #expect(waveform.realValue(variable: -1, point: 0) == nil)
            #expect(waveform.realValue(variable: 0, point: -1) == nil)
            #expect(waveform.complexValue(variable: -1, point: 0) == nil)
            #expect(waveform.complexValue(variable: 0, point: -1) == nil)
        }
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
