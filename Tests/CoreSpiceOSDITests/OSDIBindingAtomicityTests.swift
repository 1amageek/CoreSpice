import CoreSpiceOSDITestSupport
import CoreSpiceIR
import CoreSpiceDevices
import Darwin
import Foundation
import OSDIContracts
import Synchronization
import Testing
@testable import CoreSpiceOSDI

@Suite(.timeLimit(.minutes(1)))
struct OSDIBindingAtomicityTests {
    @Test(arguments: ["dynamic_rc", "dynamic_context", "dynamic_flow_thermal"])
    func declaredPoleZeroRealizationMatchesActualAffineACStamps(_ descriptor: String) async throws {
        let fixture = try analysisFixture(descriptor)
        var prepared = try await fixture.prepare([fixture.instance("N1", nodes: [Node(id: 1), .ground])])
        do {
            let topology = CircuitTopology(ir: prepared.circuit)
            var context = fixture.context(topology)
            guard let source = try prepared.takeDevice(at: 0) else {
                throw OSDIAdapterFixture.FixtureFailure.missingOwner
            }
            let device = try source.bind(context: &context)
            switch device.poleZeroStampApplicability {
            case .affine: break
            case .unsupported: Issue.record("OSDI affine realization was not declared")
            }
            let dimension = topology.matrixSize
            let state = SolutionState(variables: [Double](repeating: 0.3, count: dimension), variableMap: topology.variableMap)
            var baselineReal: [Double] = [], baselineImaginary: [Double] = []
            for omega in [0.0, 2.0, 5e6] {
                var real = [Double](repeating: 0, count: dimension * dimension)
                var imaginary = real
                var stamp = ComplexMatrixStamper(variableMap: topology.variableMap,
                    stampMatrix: { _, _, _, _ in Issue.record("Pre-resolved mapping was lost") },
                    stampRHS: { _, _, _ in Issue.record("AC emitted a device excitation") },
                    stampValue: { slot, re, im in real[slot] += re; imaginary[slot] += im })
                try device.stampAC(into: &stamp, state: state, omega: omega)
                if omega == 0 {
                    baselineReal = real
                    #expect(imaginary.allSatisfy { $0 == 0 })
                } else if omega == 2 {
                    #expect(real == baselineReal)
                    baselineImaginary = imaginary
                } else {
                    #expect(real == baselineReal)
                    for index in imaginary.indices {
                        let expected = baselineImaginary[index] * (omega / 2)
                        #expect(abs(imaginary[index] - expected) <= max(1e-15, abs(expected) * 1e-13))
                    }
                }
            }
            try prepared.close()
        } catch {
            do { try prepared.close() } catch { Issue.record("Prepared owner cleanup failed: \(error)") }
            do { try await fixture.close() } catch { Issue.record("Fixture cleanup failed: \(error)") }
            throw error
        }
        try await fixture.close()
    }

    @Test func sameTrialOriginalGatesUseOneActualEvaluationAndExactMismatchesUseFreshFacts() async throws {
        let fixture = try analysisFixture("dynamic_context")
        var prepared = try await fixture.prepare([fixture.instance("N1", nodes: [Node(id: 1), .ground])])
        do {
            guard let source = try prepared.takeDevice(at: 0) else { throw OSDIAdapterFixture.FixtureFailure.missingOwner }
            let topology = CircuitTopology(ir: prepared.circuit)
            var context = fixture.context(topology)
            let bound = try source.bind(context: &context)
            let device = try #require(bound as? BoundOSDIDevice)
            let initial = SolutionState(variables: [0.4], variableMap: topology.variableMap)
            let candidate = SolutionState(variables: [0.8], previousVariables: [0.4], variableMap: topology.variableMap)
            let step = IntegrationState(method: .backwardEuler, timeStep: 0.5, currentTime: 0.5)
            try device.beginTransientSession(initialState: initial)
            defer { device.endTransientSession() }
            func count() throws -> UInt64 { try #require(device.owner.transientSourceFactEvaluationCount) }
            func companion(_ state: SolutionState, _ integration: IntegrationState) throws {
                try device.accumulateTransientPhysicalResidual(state: state, integration: integration) { _, _ in }
            }
            func companion() throws { try companion(candidate, step) }
            func terms(_ state: SolutionState, _ integration: IntegrationState) throws -> [Double] {
                var result = [0.0, 0.0]
                try device.accumulateTransientPhysicalEquation(state: state, integration: integration) { _, term, value in
                    switch term {
                    case .staticResidual: result[0] += value
                    case .chargeDifference: result[1] += value
                    default: Issue.record("Unexpected nonconservative source")
                    }
                }
                return result
            }
            func terms() throws -> [Double] { try terms(candidate, step) }
            let fresh = try terms()
            let before = try count()
            try companion()
            // Initial F uses different input scratch; it must preserve the trial's independent key.
            try device.accumulateTransientStaticResidual(state: initial, time: 0) { _, value in #expect(abs(value - 0.00041) < 1e-16) }
            #expect(try terms() == fresh)
            #expect(try count() - before == 1, "Companion plus canonical must cross the real evaluator once")
            #expect(try terms() == fresh)
            #expect(try count() - before == 2, "A consumed record cannot be reused twice")
            for changed in [SolutionState(variables: [0.9], variableMap: topology.variableMap),
                            SolutionState(variables: [Double(0.8).nextUp], variableMap: topology.variableMap)] {
                let start = try count()
                try companion()
                _ = try terms(changed, step)
                #expect(try count() - start == 2, "Different represented coordinates require fresh evaluation")
            }
            let later = IntegrationState(method: .backwardEuler, timeStep: 0.75, currentTime: 0.75)
            var start = try count()
            try companion()
            let laterTerms = try terms(candidate, later)
            #expect(try count() - start == 2)
            #expect(abs(laterTerms[0] - 0.00155) < 1e-16, "Actual current TRAN time must change F")
            start = try count()
            try companion()
            _ = try terms(candidate, .init(method: .backwardEuler, timeStep: 0.5, currentTime: 0.5, previousTimeStep: 0.25))
            #expect(try count() - start == 2, "Previous-step context also belongs to the exact integration key")
            try companion()
            let afterCompanion = try count()
            #expect(throws: OSDIAdapterFailure.self) {
                try companion(.init(variables: [.nan], variableMap: topology.variableMap), step)
            }
            #expect(try terms() == fresh)
            #expect(try count() == afterCompanion + 1, "Failed query invalidates the successful old record")
            try companion()
            let beforeRestart = try count()
            device.endTransientSession()
            try device.beginTransientSession(initialState: initial)
            #expect(try terms() == fresh)
            #expect(try count() == beforeRestart + 1, "A new accepted generation cannot reuse a previous run's record")
            try device.commitTransientStep(state: candidate, integration: step)
            let next = SolutionState(variables: [1], previousVariables: [0.8], variableMap: topology.variableMap)
            let tr = IntegrationState(method: .trapezoidal, timeStep: 0.25, currentTime: 0.75, previousTimeStep: 0.5)
            start = try count()
            try companion(next, tr)
            _ = try terms(next, .init(method: .backwardEuler, timeStep: 0.25, currentTime: 0.75, previousTimeStep: 0.5))
            #expect(try count() - start == 2, "BE and TR never share an integration key")
            try prepared.close()
        } catch {
            do { try prepared.close() } catch { Issue.record("Prepared owner cleanup failed: \(error)") }
            do { try await fixture.close() } catch { Issue.record("Fixture cleanup failed: \(error)") }
            throw error
        }
        try await fixture.close()
    }

    @Test func cancelledCompanionDoesNotPublishFactsAndCleanRetryReevaluates() async throws {
        let fixture = try analysisFixture("dynamic_context")
        var prepared = try await fixture.prepare([fixture.instance("N1", nodes: [Node(id: 1), .ground])])
        do {
            guard let source = try prepared.takeDevice(at: 0) else { throw OSDIAdapterFixture.FixtureFailure.missingOwner }
            let topology = CircuitTopology(ir: prepared.circuit)
            var context = fixture.context(topology)
            let bound = try source.bind(context: &context)
            let device = try #require(bound as? BoundOSDIDevice)
            let initial = SolutionState(variables: [0.4], variableMap: topology.variableMap)
            let candidate = SolutionState(variables: [0.8], previousVariables: [0.4], variableMap: topology.variableMap)
            let step = IntegrationState(method: .backwardEuler, timeStep: 0.5, currentTime: 0.5)
            try device.beginTransientSession(initialState: initial)
            defer { device.endTransientSession() }
            let cancelled = Task.detached {
                do {
                    try device.accumulateTransientPhysicalResidual(state: candidate, integration: step) { _, _ in
                        withUnsafeCurrentTask { $0?.cancel() }
                    }
                    return false
                } catch OSDIAdapterFailure.cancelled { return true }
            }
            #expect(try await cancelled.value)
            let before = try #require(device.owner.transientSourceFactEvaluationCount)
            var f = 0.0
            try device.accumulateTransientPhysicalEquation(state: candidate, integration: step) { _, term, value in
                if case .staticResidual = term { f += value }
            }
            #expect(abs(f - 0.0013) < 1e-16)
            #expect(device.owner.transientSourceFactEvaluationCount == before + 1)
            try device.accumulateTransientPhysicalResidual(state: candidate, integration: step) { _, _ in }
            let afterRetry = try #require(device.owner.transientSourceFactEvaluationCount)
            try device.accumulateTransientPhysicalEquation(state: candidate, integration: step) { _, _, _ in }
            #expect(device.owner.transientSourceFactEvaluationCount == afterRetry)
            try prepared.close()
        } catch {
            do { try prepared.close() } catch { Issue.record("Prepared owner cleanup failed: \(error)") }
            do { try await fixture.close() } catch { Issue.record("Fixture cleanup failed: \(error)") }
            throw error
        }
        try await fixture.close()
    }

    @Test func originalEquationDecompositionRetainsActualInitialModeAndRejectedTrialHistory() async throws {
        let fixture = try analysisFixture("dynamic_context")
        var prepared = try await fixture.prepare([fixture.instance("N1", nodes: [Node(id: 1), .ground])])
        do {
            guard let owner = try prepared.takeDevice(at: 0) else { throw OSDIAdapterFixture.FixtureFailure.missingOwner }
            let topology = CircuitTopology(ir: prepared.circuit)
            var context = fixture.context(topology)
            let device = try owner.bind(context: &context)
            let session = try #require(device as? any TransientSessionDevice)
            let committing = try #require(device as? any TransientStateCommittingDevice)
            let equations = try #require(device as? any TransientPhysicalEquationDecomposing)
            let physical = try #require(device as? any TransientPhysicalResidualContributing)
            let initial = SolutionState(variables: [0.4], variableMap: topology.variableMap)
            try session.beginTransientSession(initialState: initial, initialization: .operatingPoint)
            defer { session.endTransientSession() }
            var initialF = 0.0
            try equations.accumulateTransientStaticResidual(state: initial, time: 0) { _, value in initialF += value }
            // The IC-mode source is present only in actual TRAN initialization, not DC or a later trial.
            #expect(abs(initialF - 0.00041) < 1e-16)
            let candidate = SolutionState(variables: [0.8], previousVariables: [0.4], variableMap: topology.variableMap)
            let be = IntegrationState(method: .backwardEuler, timeStep: 0.5, currentTime: 0.5)
            var f = 0.0, increment = 0.0
            try equations.accumulateTransientPhysicalEquation(state: candidate, integration: be) { _, term, value in
                switch term { case .staticResidual: f += value; case .chargeDifference: increment += value; default: Issue.record("Unexpected differential law") }
            }
            #expect(abs(f - 0.0013) < 1e-16)
            #expect(abs(increment - 0.8e-9) < 1e-20)
            var cached = 0.0
            try equations.accumulateTransientStaticResidual(state: initial, time: 0) { _, value in cached += value }
            #expect(cached == initialF)
            #expect(throws: (any Error).self) {
                try equations.accumulateTransientStaticResidual(
                    state: .init(variables: [0.5], variableMap: topology.variableMap), time: 0) { _, _ in }
            }
            #expect(throws: (any Error).self) {
                try equations.accumulateTransientPhysicalEquation(state: candidate,
                    integration: .init(method: .backwardEuler, timeStep: -1, currentTime: 0.5)) { _, _, _ in }
            }
            cached = 0
            try equations.accumulateTransientStaticResidual(state: initial, time: 0) { _, value in cached += value }
            #expect(cached == initialF)
            try committing.commitTransientStep(state: candidate, integration: be)
            #expect(throws: (any Error).self) { try equations.accumulateTransientStaticResidual(state: initial, time: 0) { _, _ in } }
            let next = SolutionState(variables: [1], previousVariables: [0.8], variableMap: topology.variableMap)
            let tr = IntegrationState(method: .trapezoidal, timeStep: 0.25, currentTime: 0.75)
            f = 0; increment = 0
            try equations.accumulateTransientPhysicalEquation(state: next, integration: tr) { _, term, value in
                switch term { case .staticResidual: f += value; case .chargeDifference: increment += value; default: Issue.record("Unexpected differential law") }
            }
            #expect(abs(f - 0.00175) < 1e-16)
            #expect(abs(increment - 1.6e-9) < 1e-20)
            var companion = 0.0
            try physical.accumulateTransientPhysicalResidual(state: next, integration: tr) { _, value in companion += value }
            #expect(abs(companion - (f + increment - 0.8e-9)) < 1e-16)
            session.endTransientSession()
            try prepared.close()
        } catch {
            do { try prepared.close() } catch { Issue.record("Prepared owner cleanup failed: \(error)") }
            do { try await fixture.close() } catch { Issue.record("Fixture cleanup failed: \(error)") }
            throw error
        }
        try await fixture.close()
    }

    @Test func failedProposalsAndCSRLeaveBothClaimSetsUnchangedForRetry() async throws {
        let fixture = try analysisFixture("dynamic_flow_thermal")
        var prepared = try await fixture.prepare([fixture.instance("N1", nodes: [Node(id: 1), .ground])])
        do {
            guard let source = try prepared.takeDevice(at: 0) else {
                throw OSDIAdapterFixture.FixtureFailure.missingOwner
            }
            #expect(source.instance.ownedNodes.count == 1)
            #expect(source.instance.ownedBranches.count == 1)
            let topology = CircuitTopology(ir: prepared.circuit)
            let priorNode = Node(id: 100), priorBranch = Branch(id: 100), prefixBranch = Branch(id: 101)
            var variables = topology.variableMap
            variables[.nodeVoltage(priorNode)] = variables.count
            variables[.branchCurrent(priorBranch)] = variables.count
            variables[.branchCurrent(prefixBranch)] = variables.count
            let dimension = variables.count
            let prior = Instance(name: "prior", typeName: "test", nodes: [], parameters: [:],
                ownedNodes: [priorNode], ownedBranches: [priorBranch])
            let proposals = [
                instance(source.instance, nodes: source.instance.ownedNodes + [.ground]),
                instance(source.instance, nodes: source.instance.ownedNodes + source.instance.ownedNodes),
                instance(source.instance, branches: source.instance.ownedBranches + [prefixBranch, Branch(id: 102)]),
                instance(source.instance, branches: source.instance.ownedBranches + [prefixBranch, prefixBranch]),
                instance(source.instance, branches: source.instance.ownedBranches + [priorBranch]),
                source.instance
            ]
            for (index, proposal) in proposals.enumerated() {
                let gate = ResolverGate()
                gate.reject.store(index == proposals.count - 1, ordering: .relaxed)
                var context = BindingContext(variableMap: variables, matrixDimension: dimension,
                    stampIndexResolver: { row, col in
                        gate.reject.load(ordering: .relaxed) ? nil : row * dimension + col
                    })
                try context.claimOwnedNodes(for: prior)
                _ = try context.claimBranch(for: prior)
                do {
                    _ = try replica(source, instance: proposal).bind(context: &context)
                    Issue.record("Invalid proposal or CSR mapping admitted at case \(index)")
                } catch { guard case OSDIAdapterFailure.invalidMatrixMapping = error else { throw error } }
                gate.reject.store(false, ordering: .relaxed)
                let bound = try replica(source).bind(context: &context)
                // A failed late branch must not claim its valid prefix either.
                let prefix = Instance(name: "prefix", typeName: "test", nodes: [], parameters: [:], ownedBranches: [prefixBranch])
                #expect(try context.claimBranch(for: prefix) == prefixBranch)
                do {
                    try context.claimOwnedNodes(for: prior)
                    Issue.record("Failed bind removed a previous node claim")
                } catch { guard case DeviceBindingError.invalidParameterValue = error else { throw error } }
                do {
                    _ = try context.claimBranch(for: prior)
                    Issue.record("Failed bind removed a previous branch claim")
                } catch { guard case DeviceBindingError.duplicateBranchOwnership = error else { throw error } }
                do {
                    _ = try replica(source).bind(context: &context)
                    Issue.record("Successful bind did not retain its ownership claims")
                } catch { guard case OSDIAdapterFailure.invalidMatrixMapping = error else { throw error } }
                let state = SolutionState(variables: [Double](repeating: 0, count: dimension), variableMap: variables)
                var calls = 0
                var stamp = MatrixStamper(variableMap: variables,
                    stampMatrix: { _, _, _ in Issue.record("Pre-resolved mapping was lost") },
                    stampRHS: { _, value in #expect(value.isFinite) },
                    stampValue: { _, value in #expect(value.isFinite); calls += 1 })
                try bound.stampDC(into: &stamp, state: state)
                #expect(calls > 0)
            }
            try prepared.close()
        } catch {
            do { try prepared.close() } catch { Issue.record("Prepared owner cleanup failed: \(error)") }
            do { try await fixture.close() } catch { Issue.record("Fixture cleanup failed: \(error)") }
            throw error
        }
        try await fixture.close()
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CORESPICE_OSDI_BINDING_SCALING"] == "1"))
    func bindingOnlyCPUScaling() async throws {
        let fixture = try analysisFixture("dynamic_flow_thermal")
        var prepared = try await fixture.prepare([fixture.instance("N1", nodes: [Node(id: 1), .ground])])
        do {
            guard let source = try prepared.takeDevice(at: 0) else {
                throw OSDIAdapterFixture.FixtureFailure.missingOwner
            }
            print("OSDI binding CPU: count,repetition,cpu_seconds,nanoseconds_per_bind")
            for count in [256, 1024, 4096] {
                for repetition in 0..<3 {
                    var holders = UniqueArray<OSDIPreparedDevice?>()
                    var variables: [MNAVariable: Int] = [.nodeVoltage(Node(id: 1)): 0]
                    for index in 0..<count {
                        var nodeID = index + 1, branchID = index
                        let projection = try OSDITopologyProjection(topology: source.receipt.topology,
                            terminals: [Node(id: 1), .ground], nextNodeID: &nodeID, nextBranchID: &branchID)
                        for variable in projection.activeVariables {
                            if let variable, variables[variable] == nil { variables[variable] = variables.count }
                        }
                        let input = Instance(name: "N\(index)", typeName: "osdi", nodes: source.instance.nodes,
                            parameters: [:], osdi: source.instance.osdi, ownedNodes: projection.ownedNodes,
                            ownedBranches: projection.ownedBranches)
                        holders.append(replica(source, instance: input, projection: projection))
                    }
                    let dimension = variables.count
                    var context = BindingContext(variableMap: variables, matrixDimension: dimension,
                        stampIndexResolver: { row, col in row * dimension + col })
                    var bound: [any BoundDevice] = []
                    bound.reserveCapacity(count)
                    let started = clock()
                    for index in 0..<count {
                        guard let device = holders[index].take() else {
                            throw OSDIAdapterFixture.FixtureFailure.missingOwner
                        }
                        bound.append(try device.bind(context: &context))
                    }
                    let ended = clock()
                    // Darwin's unsigned clock_t represents the C failure sentinel as all one bits.
                    try #require(started != clock_t.max && ended != clock_t.max && ended >= started)
                    let seconds = Double(ended - started) / Double(CLOCKS_PER_SEC)
                    #expect(bound.count == count)
                    print("OSDI binding CPU: \(count),\(repetition),\(seconds),\(seconds * 1e9 / Double(count))")
                }
            }
            try prepared.close()
        } catch {
            do { try prepared.close() } catch { Issue.record("Prepared owner cleanup failed: \(error)") }
            do { try await fixture.close() } catch { Issue.record("Fixture cleanup failed: \(error)") }
            throw error
        }
        try await fixture.close()
    }

    private func instance(_ original: Instance, nodes: [Node]? = nil, branches: [Branch]? = nil) -> Instance {
        Instance(name: original.name, typeName: original.typeName, nodes: original.nodes, parameters: original.parameters,
            osdi: original.osdi, ownedNodes: nodes ?? original.ownedNodes, ownedBranches: branches ?? original.ownedBranches)
    }

    private func analysisFixture(_ descriptor: String) throws -> OSDIAdapterFixture {
        let path = try #require(ProcessInfo.processInfo.environment["CORESPICE_OSDI_ANALYSIS_MANIFEST"])
        let manifest = try JSONDecoder().decode(OSDIAnalysisManifest.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let library = try #require(manifest.libraries.first { $0.descriptorName == descriptor })
        return try OSDIAdapterFixture(library: library)
    }

    // Fault injection shares one real owner without reloading a library for each failed bind.
    private func replica(_ source: borrowing OSDIPreparedDevice, instance: Instance? = nil,
                         projection: OSDITopologyProjection? = nil) -> OSDIPreparedDevice {
        OSDIPreparedDevice(instance: instance ?? source.instance, receipt: source.receipt, owner: source.owner,
            projection: projection ?? source.projection, noiseSources: source.noiseSources,
            hasReactiveResidual: source.hasReactiveResidual, transientPrecisionReceipt: source.transientPrecisionReceipt)
    }

    private final class ResolverGate: Sendable {
        let reject = Atomic(false)
    }
}
