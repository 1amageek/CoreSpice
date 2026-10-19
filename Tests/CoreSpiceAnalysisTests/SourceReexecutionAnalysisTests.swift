import Testing
import Synchronization
@testable import CoreSpiceAnalysis
import CoreSpiceCompile
import CoreSpiceDevices
import CoreSpiceIR
import CoreSpiceEvent

@Suite("Source reexecution analysis contracts", .timeLimit(.minutes(1)))
struct SourceReexecutionAnalysisTests {
    @Test func dcSensitivityUsesReturnedTopologyAndNamedOutput() async throws {
        let (original, output) = try sourceDivider(resistance: 1000, expanded: false)
        let result = try await SensitivityAnalysis(outputNode: output,
            deviceBinding: RecompilingSourceBinding()).run(plan: original.plan, devices: original.devices,
                solver: SparseLUSolver(), observer: nil, cancellation: CancellationToken())
        let entry = try #require(result.sensitivities.first)
        #expect(result.sensitivities.count == 1)
        #expect(entry.parameterName == "model.r")
        // Vout=1000/(R+1000), hence dVout/dR=-1000/(R+1000)^2.
        #expect(abs(entry.sensitivity + 0.00025) < 2e-10)
    }

    @Test func acSensitivityUsesReturnedTopologyAndNamedOutput() async throws {
        let (original, output) = try sourceDivider(resistance: 1000, expanded: false)
        let result = try await ACSensitivityAnalysis(outputPositiveNode: output, sweep: .single(100),
            deviceBinding: RecompilingSourceBinding()).run(plan: original.plan, devices: original.devices,
                solver: SparseLUSolver(), observer: nil, cancellation: CancellationToken())
        let entry = try #require(result.sensitivities.first)
        #expect(abs(entry.sensitivities[0].real + 0.00025) < 2e-10)
        #expect(abs(entry.sensitivities[0].imag) < 1e-12)
    }

    @Test func monteCarloExecutesReturnedPlanForSourceOnlyParameter() async throws {
        let (original, _) = try sourceDivider(resistance: 1000, expanded: false)
        let result = try await MonteCarloAnalysis<DCAnalysis>(iterations: 2,
            variations: [.init(deviceName: "r1", parameterName: "model.r", nominalValue: 3000,
                distribution: .uniform(range: 0))], analysisFactory: { DCAnalysis() }, seed: 7,
            deviceBinding: RecompilingSourceBinding()).run(plan: original.plan, devices: original.devices,
                solver: SparseLUSolver(), observer: nil, cancellation: CancellationToken())
        for sample in result.results {
            // Fresh output has a different numeric Node ID and an extra MNA coordinate.
            #expect(sample.variables.count == original.plan.topology.dimension + 1)
            #expect(abs(try sample.voltage(at: Node(id: 3)) - 0.25) < 1e-12)
        }
    }

    @Test func freshTopologyCannotResetOrUnderchargeCumulativeBudget() throws {
        let limits = TransientExecutionLimits(maximumAcceptedSteps: 10, maximumSolveAttempts: 2,
            maximumNewtonIterations: 2, maximumSavedScalars: 100, maximumMatrixDimension: 4,
            maximumWorkUnits: 100, maximumBreakpoints: 10)
        let original = try TransientExecutionBudget(limits: limits, dimension: 1, nonZeroCount: 1, deviceCount: 1)
        try original.beginSolve()
        try original.beginIteration()
        let fresh = try original.rebound(dimension: 4, nonZeroCount: 8, deviceCount: 3)
        try fresh.beginSolve()
        try fresh.beginIteration()
        #expect(original.statistics.matrixDimension == 4)
        #expect(original.statistics.solveAttempts == 2)
        #expect(original.statistics.newtonIterations == 2)
        #expect(original.statistics.workUnits == 12 + 54)
        #expect(fresh.statistics.workUnits == original.statistics.workUnits)
        #expect(throws: TransientExecutionError.limitExceeded(resource: "solveAttempts", limit: 2, requested: 3)) {
            try original.beginSolve()
        }
        #expect(throws: TransientExecutionError.limitExceeded(resource: "newtonIterations", limit: 2, requested: 3)) {
            try fresh.beginIteration()
        }
        #expect(original.statistics.workUnits == 66)
    }

    @Test func invalidReboundPreservesOriginalOwner() throws {
        let limits = TransientExecutionLimits(maximumAcceptedSteps: 10, maximumSolveAttempts: 10,
            maximumNewtonIterations: 10, maximumSavedScalars: 100, maximumMatrixDimension: 4,
            maximumWorkUnits: 100, maximumBreakpoints: 10)
        let original = try TransientExecutionBudget(limits: limits, dimension: 1, nonZeroCount: 1, deviceCount: 1)
        try original.beginIteration()
        #expect(throws: TransientExecutionError.self) {
            _ = try original.rebound(dimension: 5, nonZeroCount: 8, deviceCount: 3)
        }
        #expect(original.dimension == 1)
        #expect(original.statistics.workUnits == 12)
        try original.beginIteration()
        #expect(original.statistics.newtonIterations == 2)
        #expect(original.statistics.workUnits == 24)
    }

    @Test func sourceInventoryCancellationPreventsReexecution() async throws {
        let (original, output) = try sourceDivider(resistance: 1000, expanded: false)
        let token = CancellationToken()
        token.cancel()
        await #expect(throws: AnalysisError.self) {
            _ = try await SensitivityAnalysis(outputNode: output, deviceBinding: RecompilingSourceBinding())
                .run(plan: original.plan, devices: original.devices, solver: SparseLUSolver(),
                    observer: nil, cancellation: token)
        }
    }

    @Test func asynchronousBindingRequirementDispatchesThroughExistential() async throws {
        let (original, output) = try sourceDivider(resistance: 1000, expanded: false)
        let binding: any CircuitDeviceBinding = AsyncSourceBinding()
        let result = try await SensitivityAnalysis(outputNode: output, deviceBinding: binding)
            .run(plan: original.plan, devices: original.devices, solver: SparseLUSolver(),
                observer: nil, cancellation: CancellationToken())
        #expect(abs(try #require(result.sensitivities.first).sensitivity + 0.00025) < 2e-10)
        let samples = try await MonteCarloAnalysis<DCAnalysis>(iterations: 1,
            variations: [.init(deviceName: "R1", parameterName: "model.r", nominalValue: 3000,
                distribution: .uniform(range: 0))], analysisFactory: { DCAnalysis() }, seed: 7,
            deviceBinding: binding).run(plan: original.plan, devices: original.devices,
                solver: SparseLUSolver(), observer: nil, cancellation: CancellationToken())
        #expect(abs(try #require(samples.results.first).voltage(at: Node(id: 3)) - 0.25) < 1e-12)
    }

    @Test func transferAndPencilForwardPhysicalValidationAndFinalizeOnce() async throws {
        let (original, output) = try sourceDivider(resistance: 1000, expanded: false)
        let tfProbe = PreparedAnalysisProbe()
        let tf = try await TransferFunctionAnalysis(outputNode: output, inputSourceName: "V1",
            physicalResidualValidator: tfProbe, completionFinalizer: tfProbe)
            .run(plan: original.plan, devices: original.devices, solver: SparseLUSolver(),
                observer: nil, cancellation: CancellationToken())
        #expect(abs(tf.gain - 0.5) < 1e-12)
        #expect(tfProbe.counts == [1, 1])
        let pzProbe = PreparedAnalysisProbe()
        let pz = try await PoleZeroAnalysis(outputNode: output, inputSourceName: "V1",
            physicalResidualValidator: pzProbe, completionFinalizer: pzProbe)
            .run(plan: original.plan, devices: original.devices, solver: SparseLUSolver(),
                observer: nil, cancellation: CancellationToken())
        #expect(abs(pz.dcGain - 0.5) < 1e-12)
        #expect(pzProbe.counts == [1, 1])
    }

    @Test func transferAndPencilDoNotDiscardEquationPolicy() async throws {
        let (original, output) = try sourceDivider(resistance: 1000, expanded: false)
        let policy = try DCEquationPolicy(rows: [.init(kind: .electricalPotential,
            variableAbsoluteTolerance: 1e-6, equationAbsoluteTolerance: 1e-12)])
        await #expect(throws: DCEquationPolicyError.self) {
            _ = try await TransferFunctionAnalysis(outputNode: output, inputSourceName: "V1", equationPolicy: policy)
                .run(plan: original.plan, devices: original.devices, solver: SparseLUSolver(),
                    observer: nil, cancellation: CancellationToken())
        }
        await #expect(throws: DCEquationPolicyError.self) {
            _ = try await PoleZeroAnalysis(outputNode: output, inputSourceName: "V1", equationPolicy: policy)
                .run(plan: original.plan, devices: original.devices, solver: SparseLUSolver(),
                    observer: nil, cancellation: CancellationToken())
        }
    }

    @Test func finalizerFailureCannotPublishTransferOrPencilCompleted() async throws {
        let (original, output) = try sourceDivider(resistance: 1000, expanded: false)
        for isPencil in [false, true] {
            let probe = PreparedAnalysisProbe(rejectCompletion: true)
            let events = try BufferingObserver(capacity: 100)
            let dispatcher = EventDispatcher(observers: [events])
            await #expect(throws: SourceContractFailure.completion) {
                if isPencil {
                    _ = try await PoleZeroAnalysis(outputNode: output, inputSourceName: "V1", completionFinalizer: probe)
                        .run(plan: original.plan, devices: original.devices, solver: SparseLUSolver(),
                            observer: dispatcher, cancellation: CancellationToken())
                } else {
                    _ = try await TransferFunctionAnalysis(outputNode: output, inputSourceName: "V1", completionFinalizer: probe)
                        .run(plan: original.plan, devices: original.devices, solver: SparseLUSolver(),
                            observer: dispatcher, cancellation: CancellationToken())
                }
            }
            let statuses = events.events.compactMap { event -> AnalysisStatus? in
                guard case .analysisFinished(let info) = event, info.type == (isPencil ? .pz : .tf) else { return nil }
                return info.status
            }
            #expect(statuses == [.failed])
            #expect(probe.counts == [0, 1])
        }
    }

    @Test func fourierExecutesPreparedTransientAndFinalizesWholeOperation() async throws {
        let (original, output) = try sourceDivider(resistance: 1000, expanded: false)
        let config = TransientConfig(stopTime: 1, executionLimits: .validationFixture,
            maxTimeStep: 0.125, initialTimeStep: 0.125)
        let probe = PreparedAnalysisProbe()
        var analysis = FourierAnalysis(fundamentalFrequency: 1, harmonicCount: 2,
            outputNodes: [output], transientConfig: config, completionFinalizer: probe)
        analysis.preparedTransientAnalysis = TransientAnalysis(config: config, operatingPointValidator: probe)
        let result = try await analysis.run(plan: original.plan, devices: original.devices,
            solver: SparseLUSolver(), observer: nil, cancellation: CancellationToken())
        #expect(probe.counts == [1, 1])
        let dc = try #require(result.harmonics["V(2)"]?.first(where: { $0.harmonic == 0 }))
        #expect(abs(dc.magnitude - 0.5) < 1e-12)
        let reject = PreparedAnalysisProbe(rejectPhysical: true)
        analysis.preparedTransientAnalysis = TransientAnalysis(config: config, operatingPointValidator: reject)
        await #expect(throws: SourceContractFailure.physical) {
            _ = try await analysis.run(plan: original.plan, devices: original.devices,
                solver: SparseLUSolver(), observer: nil, cancellation: CancellationToken())
        }
        #expect(reject.counts == [1, 0])
        #expect(probe.counts == [1, 1])
    }


    @Test func electricalTransferPortsCannotSelectThermalRows() async throws {
        let (original, output) = try sourceDivider(resistance: 1000, expanded: false)
        let potential = try DCEquationRowPolicy(kind: .electricalPotential,
            variableAbsoluteTolerance: 1e-6, equationAbsoluteTolerance: 1e-12)
        var rows = Array(repeating: potential, count: original.plan.topology.dimension)
        for (variable, index) in original.plan.topology.variableMap {
            let kind: DCEquationKind
            switch variable {
            case .branchCurrent: kind = .electricalFlow
            case .nodeVoltage(let node): kind = node == output ? .thermalPotential : .electricalPotential
            }
            rows[index] = try .init(kind: kind, variableAbsoluteTolerance: 1e-6, equationAbsoluteTolerance: 1e-12)
        }
        let policy = try DCEquationPolicy(rows: rows)
        let input = try #require(original.plan.ir.nodeNames.first(where: { $0.value == "in" })?.key)
        for operation in 0..<3 {
            do {
                switch operation {
                case 0:
                    _ = try await TransferFunctionAnalysis(outputNode: output, inputSourceName: "V1", equationPolicy: policy)
                        .run(plan: original.plan, devices: original.devices, solver: SparseLUSolver(),
                            observer: nil, cancellation: CancellationToken())
                case 1:
                    _ = try await PoleZeroAnalysis(outputNode: output, inputSourceName: "V1", equationPolicy: policy)
                        .run(plan: original.plan, devices: original.devices, solver: SparseLUSolver(),
                            observer: nil, cancellation: CancellationToken())
                default:
                    _ = try await PoleZeroAnalysis(input: .current(positive: output, reference: .ground),
                        outputPositiveNode: input, equationPolicy: policy)
                        .run(plan: original.plan, devices: original.devices, solver: SparseLUSolver(),
                            observer: nil, cancellation: CancellationToken())
                }
                Issue.record("Thermal rows cannot act as electrical transfer ports")
            } catch AnalysisError.invalidConfiguration(let message) {
                #expect(message.contains("electrical-potential"))
            }
        }
    }


    @Test func completedObservationsRetainActualRoundedPerturbationAndRawOutputs() async throws {
        let resistance = 1e16
        let (original, output) = try sourceDivider(resistance: resistance, expanded: false)
        let result = try await SensitivityAnalysis(outputNode: output, perturbationFraction: 1.1e-16,
            deviceBinding: RecompilingSourceBinding(nominal: resistance))
            .run(plan: original.plan, devices: original.devices, solver: SparseLUSolver(),
                observer: nil, cancellation: CancellationToken())
        let child = try #require(result.sensitivities.first)
        #expect(result.outputNode == output)
        #expect(result.baselineOutput == (try result.dcOperatingPoint.checkedCompensatedVoltage(at: output)))
        #expect(child.outputNode == Node(id: 3))
        #expect(child.perturbedValue == resistance + 2)
        #expect(child.effectiveIncrement == (try CompensatedValue(high: 2)))
        #expect(child.perturbedOutput != nil)
        // The resistor's admitted law uses its rounded binary64 conductance, not an exact reciprocal.
        let nominalConductance = 1 / resistance
        let changedConductance = 1 / (resistance + 2)
        let loadConductance = 1.0 / 1000
        let expected = (changedConductance - nominalConductance) * loadConductance
            / ((nominalConductance + loadConductance) * (changedConductance + loadConductance) * 2)
        #expect(abs(child.sensitivity / expected - 1) < 1e-8)
    }

    @Test func completedACObservationsRetainActualSelectedChildValues() async throws {
        let (original, output) = try sourceDivider(resistance: 1000, expanded: false)
        let result = try await ACSensitivityAnalysis(outputPositiveNode: output, sweep: .single(100),
            deviceBinding: RecompilingSourceBinding())
            .run(plan: original.plan, devices: original.devices, solver: SparseLUSolver(),
                observer: nil, cancellation: CancellationToken())
        let child = try #require(result.sensitivities.first)
        let value = try #require(child.perturbedValue)
        let actual = try #require(child.perturbedValues?.first)
        #expect(child.outputPositiveNode == Node(id: 3))
        #expect(child.outputReferenceNode == .ground)
        #expect(result.outputPositiveNode == output)
        #expect(result.frequencies == [100])
        #expect(child.effectiveIncrement == (try CompensatedValue(high: value).subtracting(CompensatedValue(high: 1000))))
        #expect(abs(actual.real - 1000 / (value + 1000)) < 1e-12)
        #expect(abs(actual.imag) < 1e-12)
    }

    @Test func freshPlanRemapsRequiredInitialGuessesBeforeFirstDeviceStamp() async throws {
        let (original, output) = try sourceDivider(resistance: 1000, expanded: false)
        let result = try await SensitivityAnalysis(outputNode: output, nodeInitialGuess: [output: 0.25],
            deviceBinding: GuessCheckingSourceBinding())
            .run(plan: original.plan, devices: original.devices, solver: SparseLUSolver(),
                observer: nil, cancellation: CancellationToken())
        #expect(abs(try #require(result.sensitivities.first).sensitivity + 0.00025) < 2e-10)
        let (expanded, _) = try sourceDivider(resistance: 1000, expanded: true)
        let extra = try #require(expanded.plan.ir.nodeNames.first(where: { $0.value == "extra" })?.key)
        #expect(throws: AnalysisError.self) {
            _ = try CircuitReexecution.nodeGuesses([extra: 0.25], from: expanded.plan, to: original.plan)
        }
    }


    @Test func sourceConfigurationWitnessesCoverBaselineAndEveryActualChild() async throws {
        let (original, output) = try sourceDivider(resistance: 1000, expanded: false)
        let dcProbe = PreparedAnalysisProbe()
        _ = try await SensitivityAnalysis(outputNode: output, nodeInitialGuess: [output: 0.25],
            deviceBinding: ConfiguringSourceBinding(probe: dcProbe))
            .run(plan: original.plan, devices: original.devices, solver: SparseLUSolver(),
                observer: nil, cancellation: CancellationToken())
        #expect(dcProbe.counts == [2, 2])
        let acProbe = PreparedAnalysisProbe()
        let ac = try await ACSensitivityAnalysis(outputPositiveNode: output, sweep: .single(100),
            nodeInitialGuess: [output: 0.25], deviceBinding: ConfiguringSourceBinding(probe: acProbe))
            .run(plan: original.plan, devices: original.devices, solver: SparseLUSolver(),
                observer: nil, cancellation: CancellationToken())
        #expect(acProbe.counts == [2, 2])
        #expect(abs(try #require(ac.operatingPoint).voltage(at: output) - 0.5) < 1e-12)
    }

}

private struct RecompilingSourceBinding: SourceResolvingCircuitDeviceBinding {
    var nominal: Double = 1000
    func sensitivityParameters(in plan: ExecutionPlan, cancellation: CancellationToken) throws -> [CircuitSensitivityParameter] {
        if cancellation.isCancelled { throw AnalysisError.cancelled }
        return [.init(deviceName: "R1", parameterName: "model.r", nominalValue: nominal)]
    }

    func bind(plan: ExecutionPlan, instances: [Instance]) throws -> PreparedCircuit {
        guard let resistor = instances.first(where: { $0.name == "R1" }),
              case .real(let resistance)? = resistor.parameters["model.r"] else {
            throw AnalysisError.invalidConfiguration("Expected an explicit source replacement")
        }
        return try sourceDivider(resistance: resistance, expanded: true).0
    }
}

private func sourceDivider(resistance: Double, expanded: Bool) throws -> (PreparedCircuit, Node) {
    var netlist = Netlist()
    if expanded {
        try netlist.addInstance(name: "Rextra", typeName: "resistor", nodes: ["extra", "0"],
            parameters: ["r": .real(1000)])
    }
    let _ = netlist.node("in")
    let output = netlist.node("out")
    let branch = netlist.branch()
    try netlist.addInstance(name: "V1", typeName: "vsource", nodes: ["in", "0"],
        parameters: ["v": .real(1), "ac": .real(1)], ownedBranches: [branch])
    try netlist.addInstance(name: "R1", typeName: "resistor", nodes: ["in", "out"],
        parameters: ["r": .real(resistance)])
    try netlist.addInstance(name: "R2", typeName: "resistor", nodes: ["out", "0"],
        parameters: ["r": .real(1000)])
    let plan = try StandardCompiler().compile(ir: netlist.build())
    return (try StandardCircuitDeviceBinding().bind(plan: plan, instances: plan.ir.instances), output)
}


private enum SourceContractFailure: Error, Equatable {
    case synchronousPath
    case physical
    case completion
}

private struct AsyncSourceBinding: SourceResolvingCircuitDeviceBinding {
    func sensitivityParameters(in plan: ExecutionPlan, cancellation: CancellationToken) throws -> [CircuitSensitivityParameter] {
        try RecompilingSourceBinding().sensitivityParameters(in: plan, cancellation: cancellation)
    }
    func bind(plan: ExecutionPlan, instances: [Instance]) throws -> PreparedCircuit {
        throw SourceContractFailure.synchronousPath
    }
    func bind(plan: ExecutionPlan, instances: [Instance], cancellation: CancellationToken) async throws -> PreparedCircuit {
        await Task.yield()
        if cancellation.isCancelled || Task.isCancelled { throw AnalysisError.cancelled }
        return try RecompilingSourceBinding().bind(plan: plan, instances: instances)
    }
}

private final class PreparedAnalysisProbe: DCPhysicalResidualValidating, AnalysisCompletionFinalizing {
    private let state = Mutex([0, 0])
    let rejectPhysical: Bool
    let rejectCompletion: Bool
    init(rejectPhysical: Bool = false, rejectCompletion: Bool = false) {
        self.rejectPhysical = rejectPhysical
        self.rejectCompletion = rejectCompletion
    }
    var counts: [Int] { state.withLock { $0 } }
    func validate(state: SolutionState) throws {
        self.state.withLock { $0[0] += 1 }
        if rejectPhysical { throw SourceContractFailure.physical }
    }
    func finalizeCompletion() throws {
        state.withLock { $0[1] += 1 }
        if rejectCompletion { throw SourceContractFailure.completion }
    }
}


private struct GuessCheckingSourceBinding: SourceResolvingCircuitDeviceBinding {
    func sensitivityParameters(in plan: ExecutionPlan, cancellation: CancellationToken) throws -> [CircuitSensitivityParameter] {
        try RecompilingSourceBinding().sensitivityParameters(in: plan, cancellation: cancellation)
    }
    func bind(plan: ExecutionPlan, instances: [Instance]) throws -> PreparedCircuit {
        let prepared = try RecompilingSourceBinding().bind(plan: plan, instances: instances)
        let output = try #require(prepared.plan.ir.nodeNames.first(where: { $0.value == "out" })?.key)
        let devices = prepared.devices.map { device -> any BoundDevice in
            if device.instance.name == "R1" { return GuessCheckingDevice(original: device, output: output) }
            return device
        }
        return try PreparedCircuit(plan: prepared.plan, devices: devices)
    }
}

private final class GuessCheckingDevice: BoundDevice {
    let original: any BoundDevice
    let output: Node
    private let firstStamp = Mutex(true)
    var instance: Instance { original.instance }
    init(original: any BoundDevice, output: Node) { self.original = original; self.output = output }
    func stampDC(into stamper: inout MatrixStamper, state: SolutionState) throws {
        let check = firstStamp.withLock { first in let result = first; first = false; return result }
        if check, try state.checkedVoltage(at: output) != 0.25 {
            throw AnalysisError.invalidConfiguration("Fresh initial guess was not mapped by source name")
        }
        try original.stampDC(into: &stamper, state: state)
    }
    func stampAC(into stamper: inout ComplexMatrixStamper, state: SolutionState, omega: Double) throws {
        try original.stampAC(into: &stamper, state: state, omega: omega)
    }
    func stampTransient(into stamper: inout MatrixStamper, state: SolutionState, integration: IntegrationState) throws {
        try original.stampTransient(into: &stamper, state: state, integration: integration)
    }
    func checkConvergence(state: SolutionState, previousState: SolutionState) -> ConvergenceResult {
        original.checkConvergence(state: state, previousState: previousState)
    }
}


private struct ConfiguringSourceBinding: SourceResolvingCircuitDeviceBinding {
    let probe: PreparedAnalysisProbe
    func sensitivityParameters(in plan: ExecutionPlan, cancellation: CancellationToken) throws -> [CircuitSensitivityParameter] {
        try RecompilingSourceBinding().sensitivityParameters(in: plan, cancellation: cancellation)
    }
    func bind(plan: ExecutionPlan, instances: [Instance]) throws -> PreparedCircuit {
        try RecompilingSourceBinding().bind(plan: plan, instances: instances)
    }
    func configureDCAnalysis(_ analysis: DCAnalysis, plan: ExecutionPlan, devices: [any BoundDevice],
                             cancellation: CancellationToken) throws -> DCAnalysis {
        var configured = DCAnalysis(config: analysis.config, gminStepping: analysis.gminStepping,
            sourceStepping: analysis.sourceStepping, nodeInitialGuess: analysis.nodeInitialGuess,
            equationPolicy: analysis.equationPolicy, physicalResidualValidator: probe,
            completionFinalizer: probe, precisionMode: analysis.precisionMode)
        configured.executionBudget = analysis.executionBudget
        configured.resultStorage = analysis.resultStorage
        return configured
    }
    func configureACAnalysis(_ analysis: ACAnalysis, plan: ExecutionPlan, devices: [any BoundDevice],
                             cancellation: CancellationToken) throws -> ACAnalysis {
        var configured = ACAnalysis(sweep: analysis.sweep, dcConfig: analysis.dcConfig,
            nodeInitialGuess: analysis.nodeInitialGuess, equationPolicy: analysis.equationPolicy,
            physicalResidualValidator: probe, completionFinalizer: probe)
        configured.executionBudget = analysis.executionBudget
        configured.resultStorage = analysis.resultStorage
        return configured
    }
}
