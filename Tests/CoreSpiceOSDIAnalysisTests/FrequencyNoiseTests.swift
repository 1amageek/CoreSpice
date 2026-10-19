import Testing
import Synchronization
@testable import CoreSpiceAnalysis
import CoreSpiceCompile
import CoreSpiceDevices
import CoreSpiceIR
import CoreSpiceEvent

@Suite("Generic frequency and residual noise", .timeLimit(.minutes(1)))
struct FrequencyNoiseTests {
    private let output = Node(id: 1)
    private let thermal = Node(id: 2)
    private let flow = Branch(id: 7)

    private func fixture(fault: FrequencyProbe.Fault = .none) throws -> (ExecutionPlan, FrequencyProbe, DCEquationPolicy) {
        let instance = Instance(name: "probe", typeName: "test", nodes: [output, thermal], parameters: [:], ownedBranches: [flow])
        let plan = try StandardCompiler().compile(ir: CircuitIR(nodes: [.ground, output, thermal], branches: [flow], instances: [instance]))
        let policy = try DCEquationPolicy(rows: [
            DCEquationRowPolicy(kind: .electricalPotential, variableAbsoluteTolerance: 1e-10, equationAbsoluteTolerance: 1e-10),
            DCEquationRowPolicy(kind: .thermalPotential, variableAbsoluteTolerance: 1e-10, equationAbsoluteTolerance: 1e-10),
            DCEquationRowPolicy(kind: .electricalFlow, variableAbsoluteTolerance: 1e-10, equationAbsoluteTolerance: 1e-10),
        ])
        return (plan, FrequencyProbe(instance: instance, map: plan.topology.variableMap,
            structure: plan.matrixStructure, output: output, thermal: thermal, flow: flow, fault: fault), policy)
    }

    @Test func recoveryGminDoesNotAlterOriginalACOrNoiseMatrices() async throws {
        let (plan, device, policy) = try fixture()
        let ac = try await ACAnalysis(sweep: .single(1000), dcConfig: .init(gmin: 0.5),
            nodeInitialGuess: [thermal: 2], equationPolicy: policy).run(plan: plan, devices: [device],
                solver: SparseLUSolver(), observer: nil, cancellation: .init())
        #expect(ac.operatingPoint?.variables == [0, 0, 0])
        let lease = FrequencyStorageLease()
        let retainedAC = ac.retainingStorage(lease)
        #expect(retainedAC.operatingPoint?.retainedStorage as? FrequencyStorageLease === lease)
        #expect(abs(ac.solutions[0][0].real + 4) < 1e-12)
        #expect(ac.solutions[0][1].real == 1)
        #expect(ac.solutions[0][2].real == 1)
        let noise = try await NoiseAnalysis(outputNode: output, sweep: .linear(start: 1000, stop: 2000, points: 2),
            dcConfig: .init(gmin: 0.5), equationPolicy: policy).run(plan: plan, devices: [device],
                solver: SparseLUSolver(), observer: nil, cancellation: .init())
        #expect(noise.operatingPoint?.variables == [0, 0, 0])
        let retainedNoise = noise.retainingStorage(lease)
        #expect(retainedNoise.operatingPoint?.retainedStorage as? FrequencyStorageLease === lease)
        #expect(noise.deviceContributions.count == 4)
        #expect(noise.deviceContributions.map { $0.residualSource?.index } == [0, 1, 2, 3])
        #expect(noise.deviceContributions.map { $0.sourceSpectralDensity?.first } == [9, 16, 25, 100])
        #expect(noise.deviceContributions[3].spectralDensity == [0, 0])
        // The original noise matrix has output transfer row [1/2, -1/4, -3/10].
        for (contribution, expected) in zip(noise.deviceContributions, [2.25, 1, 2.25, 0]) {
            #expect(abs(contribution.spectralDensity[0] - expected) < 1e-12)
        }
        #expect(abs(noise.outputNoiseDensity[0] - 5.5) < 1e-12)
        #expect(abs(noise.integratedOutputNoise - (5500.0).squareRoot()) < 1e-10)
        #expect(!noise.deviceContributions.contains { $0.noiseName == "must-not-double-count" })
    }

    @Test func invalidScopedSpectraAndThermalOutputFail() async throws {
        for fault in [FrequencyProbe.Fault.negative, .nonfinite, .width, .missingCallback, .twice, .unit, .unknown, .duplicate] {
            let (plan, device, policy) = try fixture(fault: fault)
            await #expect(throws: AnalysisError.self) {
                _ = try await NoiseAnalysis(outputNode: output, sweep: .single(1000), dcConfig: .init(gmin: 0),
                    equationPolicy: policy).run(plan: plan, devices: [device], solver: SparseLUSolver(), observer: nil, cancellation: .init())
            }
        }
        let (plan, device, policy) = try fixture()
        await #expect(throws: AnalysisError.self) {
            _ = try await NoiseAnalysis(outputNode: thermal, sweep: .single(1000), equationPolicy: policy)
                .run(plan: plan, devices: [device], solver: SparseLUSolver(), observer: nil, cancellation: .init())
        }
    }

    @Test func physicalFailureAndFinalizerFailureCannotPublishOuterCompleted() async throws {
        let (plan, device, policy) = try fixture()
        for noise in [false, true] {
            for physical in [false, true] {
                let observer = try BufferingObserver(capacity: 100)
                let dispatcher = EventDispatcher(observers: [observer])
                let validator = FrequencyFailure(reject: physical)
                do {
                    if noise {
                        _ = try await NoiseAnalysis(outputNode: output, sweep: .single(1000), equationPolicy: policy,
                            physicalResidualValidator: validator, completionFinalizer: FrequencyFailure(reject: true))
                            .run(plan: plan, devices: [device], solver: SparseLUSolver(), observer: dispatcher, cancellation: .init())
                    } else {
                        _ = try await ACAnalysis(sweep: .single(1000), equationPolicy: policy,
                            physicalResidualValidator: validator, completionFinalizer: FrequencyFailure(reject: true))
                            .run(plan: plan, devices: [device], solver: SparseLUSolver(), observer: dispatcher, cancellation: .init())
                    }
                    Issue.record("Rejected physical state or failed close published success")
                } catch FrequencyFailure.Failure.rejected {}
                let statuses = observer.events.compactMap { event -> AnalysisStatus? in
                    guard case .analysisFinished(let info) = event, info.type == (noise ? .noise : .ac) else { return nil }
                    return info.status
                }
                #expect(statuses == [.failed])
            }
        }
    }

    @Test func canonicalInputBranchAndCurrentNormalizationPreserveQuantity() async throws {
        for voltageInput in [false, true] {
            let source = Instance(name: "input", typeName: voltageInput ? "vsource" : "isource", nodes: [output, .ground],
                parameters: voltageInput ? ["v": .real(0)] : ["i": .real(0)], ownedBranches: voltageInput ? [flow] : [])
            let resistor = Instance(name: "R1", typeName: "resistor", nodes: [output, .ground], parameters: ["r": .real(1000)])
            let plan = try StandardCompiler().compile(ir: CircuitIR(nodes: [.ground, output], branches: voltageInput ? [flow] : [], instances: [source, resistor]))
            let structure = plan.matrixStructure
            var context = BindingContext(variableMap: plan.topology.variableMap, matrixDimension: plan.topology.dimension,
                stampIndexResolver: { structure.index(row: $0, col: $1) })
            let boundSource: any BoundDevice
            if voltageInput { boundSource = try VoltageSourceDescriptor().bind(instance: source, context: &context) }
            else { boundSource = try CurrentSourceDescriptor().bind(instance: source, context: &context) }
            let boundResistor = try ResistorDescriptor().bind(instance: resistor, context: &context)
            let result = try await NoiseAnalysis(outputNode: output, inputSourceName: "input", sweep: .single(1000), dcConfig: .init(gmin: 0))
                .run(plan: plan, devices: [boundSource, boundResistor], solver: SparseLUSolver(), observer: nil, cancellation: .init())
            #expect(result.inputQuantity == (voltageInput ? .voltage : .current))
            #expect(result.operatingPoint != nil)
            #expect(result.integratedOutputNoise == 0)
            let resistorChannel = try #require(result.deviceContributions.first { $0.deviceName == "R1" })
            let sourceFact = try #require(resistorChannel.residualSource)
            #expect(sourceFact.index == 0 && sourceFact.name == "R1_thermal" && sourceFact.unit == .ampere)
            #expect(sourceFact.positive == .nodeVoltage(output) && sourceFact.negative == nil)
            let rawPSD = try #require(resistorChannel.sourceSpectralDensity?.first)
            let expectedPSD = 4 * 1.380649e-23 * 300.15 / 1000
            #expect(abs(rawPSD - expectedPSD) <= expectedPSD * 1e-14)
            if voltageInput { #expect(resistorChannel.spectralDensity == [0]) }
            if !voltageInput {
                #expect(abs(result.outputNoiseDensity[0] / result.inputReferredNoiseDensity[0] - 1e6) < 1e-6)
            }
        }
    }

    @Test func frequencyResultsRejectOperatingPointFromDifferentCompiledMap() throws {
        let map: [MNAVariable: Int] = [.nodeVoltage(output): 0, .nodeVoltage(thermal): 1]
        let operatingPoint = try DCResult(variables: [1, 2], variableMap: map, iterations: 1)
        let mismatchedMaps: [[MNAVariable: Int]] = [
            [.nodeVoltage(output): 1, .nodeVoltage(thermal): 0],
            [.nodeVoltage(output): 0, .nodeVoltage(Node(id: 99)): 1],
        ]
        for mismatched in mismatchedMaps {
            #expect(throws: AnalysisResultValidationError.variableMapMismatch) {
                _ = try ACResult(frequencies: [1000], solutions: [[.one, .zero]],
                    variableMap: mismatched, operatingPoint: operatingPoint)
            }
            #expect(throws: AnalysisResultValidationError.variableMapMismatch) {
                _ = try NoiseResult(frequencies: [1000], outputNoiseDensity: [1], inputReferredNoiseDensity: [1],
                    integratedOutputNoise: 0, deviceContributions: [], variableMap: mismatched, operatingPoint: operatingPoint)
            }
        }
        let ac = try ACResult(frequencies: [1000], solutions: [[.one, .zero]],
            variableMap: map, operatingPoint: operatingPoint)
        let noise = try NoiseResult(frequencies: [1000], outputNoiseDensity: [1], inputReferredNoiseDensity: [1],
            integratedOutputNoise: 0, deviceContributions: [], variableMap: map, operatingPoint: operatingPoint)
        #expect(ac.operatingPoint?.variableMap == map)
        #expect(noise.operatingPoint?.variableMap == map)
    }

    @Test func channelCapacityIsAdmittedBeforeDensityConsumption() async throws {
        let (plan, device, policy) = try fixture()
        var analysis = NoiseAnalysis(outputNode: output, sweep: .single(1000), equationPolicy: policy)
        analysis.resultStorage = RefusingFrequencyStorage()
        await #expect(throws: RefusingFrequencyStorage.Failure.self) {
            _ = try await analysis.run(plan: plan, devices: [device], solver: SparseLUSolver(), observer: nil, cancellation: .init())
        }
    }
}

private struct FrequencyFailure: DCPhysicalResidualValidating, AnalysisCompletionFinalizing {
    enum Failure: Error { case rejected }
    let reject: Bool
    func validate(state: SolutionState) throws { if reject { throw Failure.rejected } }
    func finalizeCompletion() throws { if reject { throw Failure.rejected } }
}

private struct RefusingFrequencyStorage: AnalysisResultStorageAccounting {
    enum Failure: Error { case capacity }
    func reserveResultScalars(_ capacity: Int) throws { throw Failure.capacity }
    func reserveTemporaryBytes(_ byteCount: UInt64) throws -> any Sendable { throw Failure.capacity }
}

private struct FrequencyProbe: ResidualNoisyDevice, NoisyDevice, NoiseMatrixStampingDevice {
    enum Fault: Sendable { case none, negative, nonfinite, width, missingCallback, twice, unit, unknown, duplicate }
    let instance: Instance
    let map: [MNAVariable: Int]
    let structure: SparseStructure
    let output: Node
    let thermal: Node
    let flow: Branch
    let fault: Fault
    var residualNoiseSources: [ResidualNoiseSource] {
        [ResidualNoiseSource(index: 0, name: "current", positive: .nodeVoltage(output), negative: nil, unit: .ampere),
         ResidualNoiseSource(index: fault == .duplicate ? 0 : 1, name: "thermal", positive: .nodeVoltage(fault == .unknown ? Node(id: 999) : thermal), negative: nil, unit: fault == .unit ? .ampere : .watt),
         ResidualNoiseSource(index: 2, name: "flow", positive: .branchCurrent(flow), negative: nil, unit: .volt),
         ResidualNoiseSource(index: 3, name: "collapsed", positive: .nodeVoltage(output), negative: .nodeVoltage(output), unit: .ampere)]
    }
    func withNoiseDensities(state: SolutionState, frequency: Double, _ body: (borrowing Span<Double>) throws -> Void) throws {
        if fault == .missingCallback { return }
        let values = fault == .width ? [9.0] : [fault == .negative ? -1 : fault == .nonfinite ? Double.nan : 9, 16, 25, 100]
        try body(values.span)
        if fault == .twice { try body(values.span) }
    }
    func noiseContributions(state: SolutionState, frequency: Double) throws -> [NoiseSource] {
        [NoiseSource(name: "must-not-double-count", positiveNode: output, negativeNode: .ground, currentSpectralDensity: 1e99)]
    }
    func stampDC(into stamper: inout MatrixStamper, state: SolutionState) throws {
        for row in 0..<map.count { stamper.stampMatrix(row, row, 1) }
    }
    func stampAC(into stamper: inout ComplexMatrixStamper, state: SolutionState, omega: Double) throws {
        stamp(into: &stamper, diagonal: 1)
        stamper.stampRHS(map[.nodeVoltage(output)]!, 1, 0)
        stamper.stampRHS(map[.nodeVoltage(thermal)]!, 4, 0)
        stamper.stampRHS(map[.branchCurrent(flow)]!, 5, 0)
    }
    func stampNoiseMatrix(into stamper: inout ComplexMatrixStamper, state: SolutionState, omega: Double) throws { stamp(into: &stamper, diagonal: 2) }
    private func stamp(into stamper: inout ComplexMatrixStamper, diagonal: Double) {
        let out = map[.nodeVoltage(output)]!, heat = map[.nodeVoltage(thermal)]!, branch = map[.branchCurrent(flow)]!
        for (row, col, value) in [(out, out, diagonal), (out, heat, 2), (out, branch, 3), (heat, heat, 4), (branch, branch, 5)] {
            if let direct = stamper.stampValue { direct(structure.index(row: row, col: col)!, value, 0) }
            else { stamper.stampMatrix(row, col, value, 0) }
        }
    }
    func stampTransient(into stamper: inout MatrixStamper, state: SolutionState, integration: IntegrationState) throws {}
    func checkConvergence(state: SolutionState, previousState: SolutionState) -> ConvergenceResult { .converged }
}

private final class FrequencyStorageLease: Sendable {}
