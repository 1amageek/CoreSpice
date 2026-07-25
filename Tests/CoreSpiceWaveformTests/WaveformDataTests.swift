import Foundation
import Testing
import CoreSpiceAnalysis
import CoreSpiceCompile
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
    func transientConversionPreservesRowMajorStorageSharing() throws {
        let node = Node(id: 1)
        let branch = Branch(id: 1)
        let trace = try SolutionTrace(
            variableCount: 2,
            rowMajorValues: [
                1.0, 0.1,
                2.0, 0.2,
                3.0, 0.3
            ]
        )
        let result = try TransientResult(
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

        let waveform = try WaveformData.from(
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
    func transientResultCheckedAccessRejectsUnknownNode() throws {
        let known = Node(id: 1)
        let missing = Node(id: 2)
        let trace = try SolutionTrace(variableCount: 1, rowMajorValues: [1.0])
        let result = try TransientResult(
            timePoints: [0.0],
            solutionTrace: trace,
            variableMap: [.nodeVoltage(known): 0],
            timeSteps: 1,
            rejectedSteps: 0
        )

        #expect(throws: TransientResultError.unknownNode(missing)) {
            _ = try result.checkedVoltage(at: missing, timeIndex: 0)
        }
        #expect(throws: TransientResultError.unknownNode(missing)) {
            _ = try result.checkedVoltageWaveform(at: missing)
        }
    }

    @Test
    func transientConversionPreservesSemanticVariableNames() throws {
        let vdd = Node(id: 1)
        let out = Node(id: 2)
        let sourceBranch = Branch(id: 0)
        let trace = try SolutionTrace(
            variableCount: 3,
            rowMajorValues: [
                1.8, 0.0, -0.001,
                1.8, 0.9, -0.0005
            ]
        )
        let result = try TransientResult(
            timePoints: [0.0, 1.0e-9],
            solutionTrace: trace,
            variableMap: [
                .nodeVoltage(vdd): 0,
                .nodeVoltage(out): 1,
                .branchCurrent(sourceBranch): 2
            ],
            timeSteps: 1,
            rejectedSteps: 0
        )
        let topology = CircuitTopology(ir: CircuitIR(
            nodes: [.ground, vdd, out],
            branches: [sourceBranch],
            instances: [],
            nodeNames: [.ground: "0", vdd: "vdd", out: "out"],
            branchNames: [sourceBranch: "VDD"]
        ))

        let waveform = try WaveformData.from(
            transientResult: result,
            topology: topology,
            title: "Converted"
        )

        #expect(waveform.variables.map(\.name) == ["V(vdd)", "V(out)", "I(VDD)"])
    }

    @Test
    func transientConversionUsesPrecomputedVariableLayout() throws {
        let node = Node(id: 1)
        let trace = try SolutionTrace(
            variableCount: 1,
            rowMajorValues: [1.0, 2.0]
        )
        let result = try TransientResult(
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
        let waveform = try WaveformData.from(
            transientResult: result,
            variableLayout: layout,
            title: "Converted"
        )

        #expect(waveform.variables.map(\.name) == ["V(1)"])
        #expect(waveform.realValue(variable: 0, point: 1) == 2.0)
    }

    @Test
    func acConversionPreservesTopologyNodeAndBranchNames() throws {
        let input = Node(id: 1)
        let output = Node(id: 2)
        let sourceBranch = Branch(id: 0)
        let result = try ACResult(
            frequencies: [1.0, 10.0],
            solutions: [
                [
                    ComplexPair(real: 1.0, imag: 0.0),
                    ComplexPair(real: 2.0, imag: 1.0),
                    ComplexPair(real: 0.001, imag: 0.0),
                ],
                [
                    ComplexPair(real: 0.5, imag: 0.0),
                    ComplexPair(real: 1.0, imag: -1.0),
                    ComplexPair(real: 0.002, imag: 0.0),
                ],
            ],
            variableMap: [
                .nodeVoltage(input): 0,
                .nodeVoltage(output): 1,
                .branchCurrent(sourceBranch): 2,
            ]
        )
        let topology = CircuitTopology(ir: CircuitIR(
            nodes: [.ground, input, output],
            branches: [sourceBranch],
            instances: [],
            nodeNames: [.ground: "0", input: "vin", output: "vout"],
            branchNames: [sourceBranch: "VIN"]
        ))

        let waveform = WaveformData.from(
            acResult: result,
            topology: topology,
            title: "AC"
        )

        #expect(waveform.variables.map(\.name) == ["V(vin)", "V(vout)", "I(VIN)"])
        #expect(waveform.complexValue(variable: 1, point: 1)?.real == 1.0)
        #expect(waveform.complexValue(variable: 1, point: 1)?.imag == -1.0)
    }

    @Test
    func transientResultRejectsTraceTimePointMismatchBeforeConversion() throws {
        let node = Node(id: 1)
        let trace = try SolutionTrace(
            variableCount: 1,
            rowMajorValues: [1.0, 2.0]
        )
        #expect(throws: AnalysisResultValidationError.self) {
            _ = try TransientResult(
                timePoints: [0.0],
                solutionTrace: trace,
                variableMap: [.nodeVoltage(node): 0],
                timeSteps: 1,
                rejectedSteps: 0
            )
        }
    }

    @Test
    func transientResultRejectsMalformedParametricInputAtCreation() throws {
        let node = Node(id: 1)
        let trace = try SolutionTrace(
            variableCount: 1,
            rowMajorValues: [1.0, 2.0]
        )
        #expect(throws: AnalysisResultValidationError.self) {
            _ = try TransientResult(
                timePoints: [0.0],
                solutionTrace: trace,
                variableMap: [.nodeVoltage(node): 0],
                timeSteps: 1,
                rejectedSteps: 0
            )
        }
    }

    @Test
    func noiseConversionPreservesSpectralDensityChannels() throws {
        let result = try NoiseResult(
            frequencies: [1_000.0, 2_000.0],
            outputNoiseDensity: [1.0e-18, 2.0e-18],
            inputReferredNoiseDensity: [4.0e-18, 8.0e-18],
            integratedOutputNoise: 1.5e-9,
            deviceContributions: [],
            variableMap: [:]
        )

        let waveform = WaveformData.from(noiseResult: result, title: "Noise")

        #expect(waveform.metadata.analysisType == .noise)
        #expect(waveform.sweepVariable.name == "frequency")
        #expect(waveform.sweepValues == [1_000.0, 2_000.0])
        #expect(waveform.variables.map(\.name) == [
            "output_noise_density",
            "input_referred_noise_density",
            "integrated_output_noise",
        ])
        #expect(waveform.realValue(variable: 0, point: 1) == 2.0e-18)
        #expect(waveform.realValue(variable: 2, point: 0) == 1.5e-9)
    }

    @Test
    func poleZeroConversionPreservesComplexPairsAndDCGain() throws {
        let result = try PoleZeroResult(
            poles: [
                ComplexPair(real: -1_000.0, imag: 10.0),
                ComplexPair(real: -2_000.0, imag: -20.0),
            ],
            zeros: [
                ComplexPair(real: -500.0, imag: 0.0),
            ],
            dcGain: 0.5,
            variableMap: [:]
        )

        let waveform = WaveformData.from(poleZeroResult: result, title: "Pole-Zero")

        #expect(waveform.metadata.analysisType == .poleZero)
        #expect(waveform.isComplex)
        #expect(waveform.sweepVariable.name == "index")
        #expect(waveform.variables.map(\.name) == ["pole", "zero", "dc_gain"])
        let firstPole = try #require(waveform.complexValue(variable: 0, point: 0))
        let firstZero = try #require(waveform.complexValue(variable: 1, point: 0))
        let firstGain = try #require(waveform.complexValue(variable: 2, point: 0))
        let missingZero = try #require(waveform.complexValue(variable: 1, point: 1))
        #expect(firstPole.real == -1_000.0)
        #expect(firstPole.imag == 10.0)
        #expect(firstZero.real == -500.0)
        #expect(firstGain.real == 0.5)
        #expect(missingZero.real.isNaN)
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
    func complexWaveformCreation() throws {
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
        let magnitude = try #require(mag)
        #expect(abs(magnitude - 1.118) < 0.01)
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
    func checkedSeriesAccessReturnsTypedErrors() throws {
        let waveform = WaveformData(
            metadata: SimulationMetadata(analysisType: .transient, pointCount: 2, variableCount: 1),
            sweepVariable: .time(),
            sweepValues: [0.0, 1.0],
            variables: [.voltage(node: "out", index: 0)],
            realData: [[1.0], [2.0]]
        )
        let series = try #require(waveform.realSeries(named: "V(out)"))

        #expect(try series.checkedValue(at: 1) == 2.0)
        do {
            _ = try series.checkedValue(at: 2)
            Issue.record("Expected checked value access to reject an out-of-range point.")
        } catch let error as WaveformAccessError {
            #expect(error == .pointOutOfRange(point: 2, pointCount: 2))
        }

        do {
            _ = try series.checkedSweepValue(at: -1)
            Issue.record("Expected checked sweep access to reject an out-of-range point.")
        } catch let error as WaveformAccessError {
            #expect(error == .pointOutOfRange(point: -1, pointCount: 2))
        }
    }

    @Test
    func checkedMaterializationReportsUnreadableWaveformSource() {
        let realView = WaveformDataView(base: UnreadableWaveformSource(isComplex: false))
        #expect(throws: WaveformAccessError.self) {
            _ = try realView.checkedMaterialized()
        }
        #expect(throws: WaveformAccessError.self) {
            _ = try realView.materialized()
        }

        let complexView = WaveformDataView(base: UnreadableWaveformSource(isComplex: true))
        #expect(throws: WaveformAccessError.self) {
            _ = try complexView.checkedMaterialized()
        }
        #expect(throws: WaveformAccessError.self) {
            _ = try complexView.materialized()
        }
    }

    @Test
    func waveformProjectionRejectsInvalidIndices() {
        #expect(throws: WaveformValidationError.pointProjectionOutOfRange(index: 3, pointCount: 2)) {
            _ = try WaveformProjection(
                validatingBasePointCount: 2,
                baseVariableCount: 1,
                pointIndices: [0, 3]
            )
        }

        #expect(throws: WaveformValidationError.variableProjectionOutOfRange(index: -1, variableCount: 1)) {
            _ = try WaveformProjection(
                validatingBasePointCount: 2,
                baseVariableCount: 1,
                variableIndices: [-1]
            )
        }
    }

    @Test
    func waveformViewLayoutRejectsShapeMismatch() throws {
        let waveform = WaveformData(
            metadata: SimulationMetadata(analysisType: .transient, pointCount: 1, variableCount: 1),
            sweepVariable: .time(),
            sweepValues: [0.0],
            variables: [.voltage(node: "out", index: 0)],
            realData: [[1.0]]
        )
        let projection = try WaveformProjection(
            validatingBasePointCount: 2,
            baseVariableCount: 1
        )

        #expect(throws: WaveformValidationError.projectionPointShapeMismatch(projectionPointCount: 2, basePointCount: 1)) {
            _ = try WaveformViewLayout(validatingBase: waveform, projection: projection)
        }
        #expect(throws: WaveformValidationError.projectionPointShapeMismatch(projectionPointCount: 2, basePointCount: 1)) {
            _ = try WaveformDataView(validatingBase: waveform, projection: projection)
        }
    }

    @Test
    func rowMajorWaveformRejectsInvalidShape() {
        #expect(throws: WaveformValidationError.rowMajorValueCountMismatch(expected: 2, actual: 1)) {
            _ = try WaveformData(
                validatingMetadata: SimulationMetadata(analysisType: .transient, pointCount: 2, variableCount: 1),
                sweepVariable: .time(),
                sweepValues: [0.0, 1.0],
                variables: [.voltage(node: "out", index: 0)],
                realRowMajorData: [1.0],
                pointCount: 2,
                variableCount: 1
            )
        }
    }

    @Test
    func rowMajorWaveformRejectsMetadataPointCountMismatch() {
        #expect(throws: WaveformValidationError.metadataPointCountMismatch(expected: 2, actual: 1)) {
            _ = try WaveformData(
                validatingMetadata: SimulationMetadata(analysisType: .transient, pointCount: 1, variableCount: 1),
                sweepVariable: .time(),
                sweepValues: [0.0, 1.0],
                variables: [.voltage(node: "out", index: 0)],
                realRowMajorData: [1.0, 2.0],
                pointCount: 2,
                variableCount: 1
            )
        }
    }

    @Test
    func rowMajorWaveformRejectsOverflowingValueCount() {
        #expect(throws: WaveformValidationError.rowMajorValueCountOverflow(pointCount: Int.max, variableCount: 2, actual: 0)) {
            _ = try WaveformData(
                validatingMetadata: SimulationMetadata(analysisType: .transient, pointCount: Int.max, variableCount: 2),
                sweepVariable: .time(),
                sweepValues: [],
                variables: [
                    .voltage(node: "out", index: 0),
                    .current(device: "V1", index: 1),
                ],
                realRowMajorData: [],
                pointCount: Int.max,
                variableCount: 2
            )
        }
    }

    @Test
    func realWaveformValidatingInitializerRejectsJaggedRows() {
        #expect(throws: WaveformValidationError.sampleDataVariableCountMismatch(point: 1, expected: 2, actual: 1)) {
            _ = try WaveformData(
                validatingMetadata: SimulationMetadata(analysisType: .transient, pointCount: 2, variableCount: 2),
                sweepVariable: .time(),
                sweepValues: [0.0, 1.0],
                variables: [
                    .voltage(node: "out", index: 0),
                    .current(device: "V1", index: 1),
                ],
                realData: [
                    [1.0, 0.1],
                    [2.0],
                ]
            )
        }
    }

    @Test
    func complexWaveformValidatingInitializerRejectsMetadataComplexityMismatch() {
        #expect(throws: WaveformValidationError.metadataComplexityMismatch(expected: true, actual: false)) {
            _ = try WaveformData(
                validatingMetadata: SimulationMetadata(analysisType: .ac, pointCount: 1, variableCount: 1),
                sweepVariable: .frequency(),
                sweepValues: [1.0],
                variables: [.voltage(node: "out", index: 0)],
                complexData: [[(real: 1.0, imag: 0.0)]]
            )
        }
    }

    @Test
    func uncheckedRowMajorWaveformPreservesInvalidShapeForDiagnostics() {
        let waveform = WaveformData(
            metadata: SimulationMetadata(analysisType: .transient, pointCount: 2, variableCount: 1),
            sweepVariable: .time(),
            sweepValues: [0.0, 1.0],
            variables: [.voltage(node: "out", index: 0)],
            realRowMajorData: [1.0],
            pointCount: 2,
            variableCount: 1
        )

        #expect(waveform.pointCount == 2)
        #expect(waveform.variableCount == 1)
        #expect(waveform.realValue(variable: 0, point: 1) == nil)
        if waveform.realRowMajorValues != nil {
            Issue.record("Invalid unchecked row-major waveform should not expose row-major values.")
        }
    }

    @Test
    func publicRowMajorStorageRejectsInvalidShapeWithoutTrapping() {
        let storage = WaveformStorage.realRowMajor(values: [1.0], pointCount: 2, variableCount: 1)

        #expect(storage.realValue(point: 1, variable: 0) == nil)
        #expect(storage.complexValue(point: 1, variable: 0) == nil)
        #expect(storage.materializedRealRows == nil)
        #expect(storage.withRealValues(point: 1) { _ in true } == nil)

        if storage.realRowMajorValues != nil {
            Issue.record("Invalid row-major storage should not expose a borrowed buffer.")
        }
    }

    @Test
    func publicNestedRealStorageRejectsJaggedRowMajorProjection() {
        let storage = WaveformStorage.real([
            [1.0, 0.1],
            [2.0],
        ])

        if storage.realRowMajorValues != nil {
            Issue.record("Jagged nested real storage should not expose flattened row-major values.")
        }
    }

    @Test
    func rowMajorWaveformMaterializesZeroVariableRows() throws {
        let waveform = try WaveformData(
            validatingMetadata: SimulationMetadata(analysisType: .transient, pointCount: 2, variableCount: 0),
            sweepVariable: .time(),
            sweepValues: [0.0, 1.0],
            variables: [],
            realRowMajorData: [],
            pointCount: 2,
            variableCount: 0
        )

        #expect(waveform.allRealData == [[], []])
        #expect(waveform.realRowMajorValues?.pointCount == 2)
        #expect(waveform.realRowMajorValues?.variableCount == 0)
    }

    @Test
    func publicRowMajorBufferRejectsInvalidBoundsWithoutTrapping() {
        let values = [1.0]
        let rowResult = values.withUnsafeBufferPointer { buffer in
            let rowMajor = RealRowMajorBuffer(
                values: buffer,
                pointCount: 2,
                variableCount: 1,
                rowStride: 1
            )

            #expect(rowMajor.value(point: 1, variable: 0) == nil)
            return rowMajor.withRow(at: 1) { _ in true }
        }

        #expect(rowResult == nil)
    }

    @Test
    func invalidSeriesViewReportsTypedError() {
        let waveform = WaveformData(
            metadata: SimulationMetadata(analysisType: .transient, pointCount: 1, variableCount: 1),
            sweepVariable: .time(),
            sweepValues: [0.0],
            variables: [.voltage(node: "out", index: 0)],
            realData: [[1.0]]
        )
        let view = RealWaveformView(source: waveform, variableIndex: 2)

        #expect(view[0].isNaN)
        #expect(throws: WaveformAccessError.variableOutOfRange(variable: 2, variableCount: 1)) {
            _ = try view.checkedValue(at: 0)
        }
    }

    @Test
    func waveformVariableLayoutRejectsInvalidMNAIndices() {
        let node = Node(id: 1)
        let branch = Branch(id: 0)
        let topology = CircuitTopology(ir: CircuitIR(
            nodes: [.ground, node],
            branches: [branch],
            instances: []
        ))

        #expect(throws: WaveformValidationError.mnaVariableIndexOutOfRange(index: 2, variableCount: 1)) {
            _ = try WaveformVariableLayout(
                validatingVariableMap: [.nodeVoltage(node): 2],
                topology: topology
            )
        }

        #expect(throws: WaveformValidationError.mnaVariableIndicesNotContiguous(missingIndex: 0)) {
            _ = try WaveformVariableLayout(
                validatingVariableMap: [
                    .nodeVoltage(node): 1,
                    .branchCurrent(branch): 1,
                ],
                topology: topology
            )
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
    func validatingParametricDataAcceptsComparableRuns() throws {
        let runs = [
            try ParametricWaveformData.Run(
                validatingIndex: 0,
                parameters: ["vdd": 1.8],
                waveform: transientWaveform(values: [1.0, 2.0])
            ),
            try ParametricWaveformData.Run(
                validatingIndex: 1,
                parameters: ["vdd": 1.9],
                waveform: transientWaveform(values: [3.0, 4.0])
            ),
        ]

        let parametric = try ParametricWaveformData(
            validatingRuns: runs,
            analysisType: .transient,
            parameterNames: ["vdd"]
        )

        let stats = try parametric.checkedStatistics(forVariable: "V(out)")
        #expect(stats.mean == [2.0, 3.0])
        #expect(stats.runCount == 2)
    }

    @Test
    func validatingParametricRunRejectsNonFiniteParameter() {
        #expect(throws: ParametricWaveformValidationError.nonFiniteParameterValue(runIndex: 0, name: "vdd", value: .infinity)) {
            _ = try ParametricWaveformData.Run(
                validatingIndex: 0,
                parameters: ["vdd": .infinity],
                waveform: transientWaveform(values: [1.0])
            )
        }
    }

    @Test
    func validatingParametricDataRejectsMismatchedWaveformShape() throws {
        let runs = [
            ParametricWaveformData.Run(
                index: 0,
                parameters: ["vdd": 1.8],
                waveform: transientWaveform(values: [1.0, 2.0])
            ),
            ParametricWaveformData.Run(
                index: 1,
                parameters: ["vdd": 1.9],
                waveform: transientWaveform(values: [3.0], sweepValues: [0.0])
            ),
        ]

        #expect(throws: ParametricWaveformValidationError.pointCountMismatch(runIndex: 1, expected: 2, actual: 1)) {
            _ = try ParametricWaveformData(
                validatingRuns: runs,
                analysisType: .transient,
                parameterNames: ["vdd"]
            )
        }
    }

    @Test
    func checkedParametricStatisticsRejectsOutOfRangeSweepIndex() throws {
        let parametric = try ParametricWaveformData(
            validatingRuns: [
                ParametricWaveformData.Run(
                    index: 0,
                    parameters: [:],
                    waveform: transientWaveform(values: [1.0, 2.0])
                ),
            ],
            analysisType: .transient,
            parameterNames: []
        )

        #expect(throws: ParametricWaveformValidationError.sweepIndexOutOfRange(index: -1, pointCount: 2)) {
            _ = try parametric.checkedStatistics(forVariable: "V(out)", atSweepIndex: -1)
        }
    }

    @Test
    func checkedParametricStatisticsRejectsNonFiniteWaveformValue() throws {
        let parametric = try ParametricWaveformData(
            validatingRuns: [
                ParametricWaveformData.Run(
                    index: 0,
                    parameters: [:],
                    waveform: transientWaveform(values: [.infinity])
                ),
            ],
            analysisType: .transient,
            parameterNames: []
        )

        #expect(
            throws: ParametricWaveformValidationError.nonFiniteWaveformValue(
                runIndex: 0,
                variable: "V(out)",
                sweepIndex: 0,
                value: .infinity
            )
        ) {
            _ = try parametric.checkedStatistics(forVariable: "V(out)")
        }
    }

    @Test
    func pointStatistics() throws {
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

        let stats = try parametric.checkedStatistics(forVariable: "V(out)", atSweepIndex: 0)
        #expect(stats.mean == 3.0)
        #expect(stats.minimum == 1.0)
        #expect(stats.maximum == 5.0)
        #expect(stats.sampleCount == 5)
        #expect(abs(stats.standardDeviation - 1.5811) < 0.01)
    }

    @Test
    func waveformStatistics() throws {
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

        let stats = try parametric.checkedStatistics(forVariable: "V(out)")
        #expect(stats.pointCount == 3)
        #expect(stats.runCount == 10)

        // Point 0: values 0-9, mean = 4.5
        #expect(abs(stats.mean[0] - 4.5) < 0.01)
        // Point 1: values 10-19, mean = 14.5
        #expect(abs(stats.mean[1] - 14.5) < 0.01)
    }

    @Test
    func runWithMinMax() throws {
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

        let minRun = try parametric.checkedRunWithMinimum(of: "V(out)", at: 0)
        let maxRun = try parametric.checkedRunWithMaximum(of: "V(out)", at: 0)

        #expect(minRun.index == 0)
        #expect(maxRun.index == 2)
    }

    private func transientWaveform(
        values: [Double],
        sweepValues: [Double]? = nil
    ) -> WaveformData {
        let resolvedSweepValues = sweepValues ?? values.indices.map { Double($0) }
        return WaveformData(
            metadata: SimulationMetadata(
                analysisType: .transient,
                pointCount: values.count,
                variableCount: 1
            ),
            sweepVariable: .time(),
            sweepValues: resolvedSweepValues,
            variables: [.voltage(node: "out", index: 0)],
            realData: values.map { [$0] }
        )
    }
}

private struct UnreadableWaveformSource: WaveformReadable {
    let metadata: SimulationMetadata
    let sweepVariable: VariableDescriptor
    let variables: [VariableDescriptor]
    let isComplex: Bool
    let pointCount: Int
    let variableCount: Int

    init(isComplex: Bool) {
        self.metadata = SimulationMetadata(
            analysisType: isComplex ? .ac : .transient,
            pointCount: 1,
            variableCount: 1,
            isComplex: isComplex
        )
        self.sweepVariable = isComplex ? .frequency() : .time()
        self.variables = [.voltage(node: "out", index: 0)]
        self.isComplex = isComplex
        self.pointCount = 1
        self.variableCount = 1
    }

    func sweepValue(at point: Int) -> Double? {
        0.0
    }

    func realValue(variable: Int, point: Int) -> Double? {
        nil
    }

    func complexValue(variable: Int, point: Int) -> (real: Double, imag: Double)? {
        nil
    }

    func withRealValues<R>(
        at point: Int,
        _ body: (UnsafeBufferPointer<Double>) throws -> R
    ) rethrows -> R? {
        nil
    }

    func withComplexValues<R>(
        at point: Int,
        _ body: (UnsafeBufferPointer<(real: Double, imag: Double)>) throws -> R
    ) rethrows -> R? {
        nil
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
