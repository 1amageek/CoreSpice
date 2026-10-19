import CoreSpiceOSDITestSupport
import Foundation
import Darwin
import CircuiteFoundation
import CircuiteFoundationCrypto
import CircuiteFoundationFileSystem
import CircuiteFoundationFoundation
import CoreSpiceIR
import CoreSpiceDevices
import OSDIContracts
import OSDIRuntime
import Testing
@testable import CoreSpiceOSDI

@Suite(.timeLimit(.minutes(1)))
struct OSDIDynamicAdapterTests {
    private enum CallbackFailure: Error { case expected }

    @Test func reactiveCapabilityUsesDescriptorMetadataForAlgebraicLatchAndNonlinearCharge() async throws {
        try await withDevice("dynamic_latch", nodes: [Node(id: 1), Node(id: 2)], previous: [0]) { device, _, _ in
            let capability = try #require(device as? any OSDIReactiveResidualProviding)
            #expect(!capability.hasReactiveResidual)
        }
        // The Q derivative vanishes at some biases; descriptor capability must remain true.
        let parameters = [try OSDIParameterAssignment(name: "c", scope: .model, value: .real(0)),
                          try OSDIParameterAssignment(name: "q3", scope: .model, value: .real(2e-9))]
        try await withDevice("dynamic_rc", parameters: parameters) { device, topology, _ in
            let capability = try #require(device as? any OSDIReactiveResidualProviding)
            #expect(capability.hasReactiveResidual)
            let zero = SolutionState(variables: [0], variableMap: topology.variableMap)
            var imaginary = 0.0
            var stamp = ComplexMatrixStamper(variableMap: topology.variableMap,
                stampMatrix: { _, _, _, _ in }, stampRHS: { _, _, _ in }, stampValue: { _, _, im in imaginary += im })
            try device.stampAC(into: &stamp, state: zero, omega: 1)
            #expect(imaginary == 0)
            #expect(capability.hasReactiveResidual)
        }
        try await withDevice("dynamic_rc", nodes: [.ground, .ground]) { device, _, _ in
            let capability = try #require(device as? any OSDIReactiveResidualProviding)
            #expect(capability.hasReactiveResidual)
        }
    }

    @Test func pureACAndNoiseUseDistinctModesAndBorrowedCallerFailuresRestoreOwnership() async throws {
        try await withDevice("dynamic_context") { device, topology, _ in
            let state = SolutionState(variables: [0.4], variableMap: topology.variableMap)
            var real = 0.0, imaginary = 0.0, rhs = 0.0
            var stamp = ComplexMatrixStamper(variableMap: topology.variableMap,
                stampMatrix: { _, _, _, _ in Issue.record("Row lookup used") }, stampRHS: { _, _, _ in rhs += 1 },
                stampValue: { _, re, im in real += re; imaginary += im })
            try device.stampAC(into: &stamp, state: state, omega: 2e6)
            #expect(abs(real - 0.001) < 1e-15)
            #expect(abs(imaginary - 0.002) < 1e-15)
            #expect(rhs == 0)
            real = 0; imaginary = 0
            let noise = try #require(device as? any NoiseMatrixStampingDevice)
            try noise.stampNoiseMatrix(into: &stamp, state: state, omega: 2e6)
            #expect(abs(real - 0.002) < 1e-15)
            #expect(abs(imaginary - 0.002) < 1e-15)
            let noisy = try #require(device as? any ResidualNoisyDevice)
            #expect(noisy.residualNoiseSources.count == 1)
            #expect(noisy.residualNoiseSources[0].name == "context")
            #expect(noisy.residualNoiseSources[0].unit == .ampere)
            var calls = 0, reentryBusy = false
            do {
                try noisy.withNoiseDensities(state: state, frequency: 100) { densities in
                    calls += 1
                    #expect(densities.count == 1)
                    #expect(abs(densities[0] - 4e-24) < 1e-35)
                    var inner = MatrixStamper(variableMap: topology.variableMap,
                        stampMatrix: { _, _, _ in }, stampRHS: { _, _ in }, stampValue: { _, _ in })
                    do { try device.stampDC(into: &inner, state: state) }
                    catch { if case OSDIAdapterFailure.busy = error { reentryBusy = true } else { throw error } }
                    throw CallbackFailure.expected
                }
                Issue.record("Caller failure swallowed")
            } catch CallbackFailure.expected { }
            #expect(calls == 1 && reentryBusy)
            try noisy.withNoiseDensities(state: state, frequency: 100) { _ in calls += 1 }
            #expect(calls == 2)
            do {
                try noisy.withNoiseDensities(state: state, frequency: 0) { _ in Issue.record("Invalid frequency callback") }
                Issue.record("Invalid frequency admitted")
            } catch { }
        }
    }

    @Test func nonlinearChargeUsesAcceptedBEThenVariableStepTRAndRejectsTrialPublication() async throws {
        let assignments = [try OSDIParameterAssignment(name: "q3", scope: .model, value: .real(2e-9))]
        try await withDevice("dynamic_rc", parameters: assignments) { device, topology, _ in
            let session = try #require(device as? any TransientSessionDevice)
            let physical = try #require(device as? any TransientPhysicalResidualContributing)
            let initial = SolutionState(variables: [0.5], variableMap: topology.variableMap)
            try session.beginTransientSession(initialState: initial, initialization: .initialConditions)
            defer { session.endTransientSession() }
            let be = IntegrationState(method: .backwardEuler, timeStep: 2e-8, currentTime: 2e-8)
            let prematureTR = IntegrationState(method: .trapezoidal, timeStep: 2e-8, currentTime: 2e-8)
            var dummy = MatrixStamper(variableMap: topology.variableMap,
                stampMatrix: { _, _, _ in }, stampRHS: { _, _ in }, stampValue: { _, _ in })
            do { try device.stampTransient(into: &dummy, state: initial, integration: prematureTR); Issue.record("TR before derivative admitted") }
            catch { guard case OSDIAdapterFailure.invalidIntegration = error else { throw error } }
            func charge(_ voltage: Double) -> Double { 1e-9 * voltage + 2e-9 * voltage * voltage * voltage }
            func check(_ voltage: Double, previousCharge: Double, previousCurrent: Double,
                       integration: IntegrationState) throws -> Double {
                let state = SolutionState(variables: [voltage], variableMap: topology.variableMap)
                let iq = integration.coefficient * (charge(voltage) - previousCharge)
                    - (integration.method == .trapezoidal ? previousCurrent : 0)
                let derivative = 1e-9 + 6e-9 * voltage * voltage
                let expectedG = 0.001 + integration.coefficient * derivative
                var matrix = 0.0, rhs = 0.0, residual = 0.0
                var stamp = MatrixStamper(variableMap: topology.variableMap,
                    stampMatrix: { _, _, _ in Issue.record("Row lookup used") }, stampRHS: { _, value in rhs += value },
                    stampValue: { _, value in matrix += value })
                try device.stampTransient(into: &stamp, state: state, integration: integration)
                try physical.accumulateTransientPhysicalResidual(state: state, integration: integration) { _, value in residual += value }
                #expect(abs(matrix - expectedG) < 1e-13)
                #expect(abs(residual - (0.001 * voltage + iq)) < 1e-13)
                #expect(abs(matrix * voltage - rhs - residual) < 1e-13)
                return iq
            }
            _ = try check(0.9, previousCharge: charge(0.5), previousCurrent: 0, integration: be)
            let firstCurrent = try check(0.4, previousCharge: charge(0.5), previousCurrent: 0, integration: be)
            _ = try check(0.4, previousCharge: charge(0.5), previousCurrent: 0, integration: be)
            try session.commitTransientStep(state: SolutionState(variables: [0.4], variableMap: topology.variableMap), integration: be)
            let tr = IntegrationState(method: .trapezoidal, timeStep: 3e-8, currentTime: 5e-8, previousTimeStep: 2e-8)
            _ = try check(0.45, previousCharge: charge(0.4), previousCurrent: firstCurrent, integration: tr)
            session.endTransientSession()
            try session.beginTransientSession(initialState: initial, initialization: .operatingPoint)
            _ = try check(0.4, previousCharge: charge(0.5), previousCurrent: 0, integration: be)
        }
    }

    @Test func realLatchCandidateStateCommitsOnlyAcceptedCandidatesAndNewRunsReset() async throws {
        try await withDevice("dynamic_latch", nodes: [Node(id: 1), Node(id: 2)], previous: [0]) { device, topology, _ in
            let session = try #require(device as? any TransientSessionDevice)
            let physical = try #require(device as? any TransientPhysicalResidualContributing)
            func state(_ drive: Double, _ output: Double) -> SolutionState {
                SolutionState(variables: [drive, output], variableMap: topology.variableMap)
            }
            func residual(_ drive: Double, _ output: Double, time: Double) throws -> Double {
                var values = [Double](repeating: 0, count: 2)
                try physical.accumulateTransientPhysicalResidual(state: state(drive, output),
                    integration: IntegrationState(method: .backwardEuler, timeStep: 1e-9, currentTime: time)) { values[$0] += $1 }
                return values[try #require(topology.variableMap[.nodeVoltage(Node(id: 2))])]
            }
            try session.beginTransientSession(initialState: state(0, 0), initialization: .initialConditions)
            defer { session.endTransientSession() }
            #expect(abs(try residual(1, 0, time: 1e-9) + 1) < 1e-15)
            #expect(abs(try residual(0.5, 0, time: 1e-9)) < 1e-15)
            try session.commitTransientStep(state: state(1, 1),
                integration: IntegrationState(method: .backwardEuler, timeStep: 1e-9, currentTime: 1e-9))
            #expect(abs(try residual(0, 0, time: 2e-9)) < 1e-15)
            #expect(abs(try residual(0.5, 1, time: 2e-9)) < 1e-15)
            session.endTransientSession()
            try session.beginTransientSession(initialState: state(0.5, 0), initialization: .initialConditions)
            #expect(abs(try residual(0.5, 0, time: 1e-9)) < 1e-15)
        }
    }

    @Test func endDuringForeignStampDrainsSessionWithoutLosingBusyOrCloseGuards() async throws {
        try await withDevice("dynamic_rc") { device, topology, _ in
            let session = try #require(device as? any TransientSessionDevice)
            let state = SolutionState(variables: [0.5], variableMap: topology.variableMap)
            try session.beginTransientSession(initialState: state, initialization: .initialConditions)
            var ended = false, busy = false
            var stamp = MatrixStamper(variableMap: topology.variableMap,
                stampMatrix: { _, _, _ in }, stampRHS: { _, _ in }, stampValue: { _, _ in
                    if !ended {
                        ended = true
                        session.endTransientSession()
                        do { try session.beginTransientSession(initialState: state); Issue.record("Reentrant begin admitted") }
                        catch { if case OSDIAdapterFailure.busy = error { busy = true } else { Issue.record("Wrong busy error") } }
                    }
                })
            let integration = IntegrationState(method: .backwardEuler, timeStep: 1e-8, currentTime: 1e-8)
            try device.stampTransient(into: &stamp, state: state, integration: integration)
            #expect(ended && busy)
            do { try device.stampTransient(into: &stamp, state: state, integration: integration); Issue.record("Ended run survived restore") }
            catch { guard case OSDIAdapterFailure.transientSessionRequired = error else { throw error } }
            try session.beginTransientSession(initialState: state, initialization: .operatingPoint)
            session.endTransientSession()
        }
    }

    @Test func allFourActualFamiliesProjectComplexMatricesAndBorrowExactDescriptorNoise() async throws {
        let manifest = try Self.manifest()
        for family in ["BULK", "CMG", "IMG", "SOI"] {
            let point = try #require(manifest.cases.first { $0.family == family && $0.kind == "noise" && $0.expectedOutcome == "passed" })
            let input = try #require(point.input.circuit.devices.first)
            let fixture = try OSDIAdapterFixture(library: try #require(manifest.libraries.first { $0.id == input.library }))
            do {
                let library = try await fixture.provider.load(reference: fixture.reference,
                    limits: OSDILoadLimits(maximumDescriptors: 16, maximumMetadataBytes: 16_777_216, maximumStorageBytes: 16_777_216))
                do {
                    let parameters = try input.parameters.map { try $0.assignment() }
                    var native = try OSDINativeModelPreparer().prepare(library: library, descriptorIndex: input.descriptorIndex,
                        options: OSDIPreparationOptions(parameters: parameters, simulationParameters: [],
                            temperatureKelvin: input.temperatureKelvin, connectedTerminalCount: input.connectedTerminalCount,
                            limits: OSDIEvaluationLimits(maximumWorkspaceBytes: 16_777_216, maximumDiagnosticCount: 256,
                                maximumDiagnosticBytes: 65_536, maximumStringBytes: 65_536)))
                    defer { native.close() }
                    var nets: [String: Node] = ["0": .ground]
                    for name in Set(input.terminals.values).sorted() where name != "0" { nets[name] = Node(id: nets.count) }
                    var terminals: [Node] = []
                    for index in 0..<input.connectedTerminalCount {
                        let netName = try #require(input.terminals[native.topology.nodes[index].name])
                        let node = try #require(nets[netName])
                        terminals.append(node)
                    }
                    let instance = try fixture.instance(input.id, nodes: terminals,
                        parameters: parameters.filter { $0.scope == .instance }, modelParameters: parameters.filter { $0.scope == .model },
                        previousState: input.previousState)
                    #expect(input.temperatureKelvin == OperatingConditions.nominal.temperatureKelvin)
                    var prepared = try await fixture.prepare([instance])
                    do {
                        let topology = CircuitTopology(ir: prepared.circuit)
                        var context = fixture.context(topology)
                        guard let preparedDevice = try prepared.takeDevice(at: 0) else { throw OSDIAdapterFixture.FixtureFailure.missingOwner }
                        let projection = preparedDevice.projection
                        let device = try preparedDevice.bind(context: &context)
                        let values = Dictionary(uniqueKeysWithValues: try #require(point.reference.operatingPoint).map { ($0.id, $0.value) })
                        var x = [Double](repeating: 0, count: topology.matrixSize)
                        var active = [Double](repeating: 0, count: native.topology.activeUnknownCount)
                        for coordinate in active.indices {
                            guard let variable = projection.activeVariables[coordinate] else { continue }
                            let raw = try #require(native.topology.nodes.first { $0.activeUnknownIndex == coordinate })
                            let semantic: String
                            if raw.index < input.connectedTerminalCount {
                                let net = try #require(input.terminals[raw.name])
                                semantic = "net:" + net
                            } else { semantic = "device:" + input.id + ":node:" + raw.name }
                            let value = try #require(values[semantic])
                            active[coordinate] = value
                            x[try #require(topology.variableMap[variable])] = value
                        }
                        let state = SolutionState(variables: x, variableMap: topology.variableMap)
                        let noisy = try #require(device as? any ResidualNoisyDevice)
                        #expect(noisy.residualNoiseSources.map(\.index) == native.noiseSources.map(\.index))
                        #expect(noisy.residualNoiseSources.map(\.name) == native.noiseSources.map(\.name))
                        #expect(!noisy.residualNoiseSources.isEmpty)
                        let count = native.topology.nodes.count, dimension = x.count
                        let rawGlobal = native.topology.nodes.map { node in
                            node.activeUnknownIndex.flatMap { projection.activeVariables[$0] }.flatMap { topology.variableMap[$0] }
                        }
                        for frequency in try #require(point.input.analysis.frequenciesHz) {
                            let omega = 2 * Double.pi * frequency
                            var expectedReal = [Double](repeating: 0, count: dimension * dimension)
                            var expectedImaginary = expectedReal
                            try OSDINativeModelEvaluator().evaluate(model: &native,
                                context: OSDIEvaluationContext(mode: .ac, timeSeconds: 0),
                                unknowns: active.span, previousState: input.previousState.span) { view in
                                for row in 0..<count { for col in 0..<count {
                                    if let r = rawGlobal[row], let c = rawGlobal[col] {
                                        expectedReal[r * dimension + c] += view.g[row * count + col]
                                        expectedImaginary[r * dimension + c] += omega * view.c[row * count + col]
                                    }
                                } }
                            }
                            var real = [Double](repeating: 0, count: dimension * dimension), imaginary = real
                            var stamp = ComplexMatrixStamper(variableMap: topology.variableMap,
                                stampMatrix: { _, _, _, _ in Issue.record("Unbound complex path") }, stampRHS: { _, _, _ in Issue.record("OSDI AC excitation") },
                                stampValue: { index, re, im in real[index] += re; imaginary[index] += im })
                            try device.stampAC(into: &stamp, state: state, omega: omega)
                            for index in real.indices {
                                #expect(abs(real[index] - expectedReal[index]) <= max(1e-18, abs(expectedReal[index]) * 2e-12))
                                #expect(abs(imaginary[index] - expectedImaginary[index]) <= max(1e-18, abs(expectedImaginary[index]) * 2e-12))
                            }
                            var densities: [Double] = []
                            try OSDINativeModelEvaluator().evaluate(model: &native,
                                context: OSDIEvaluationContext(mode: .noise, timeSeconds: 0, noiseFrequencyHz: frequency),
                                unknowns: active.span, previousState: input.previousState.span) { view in
                                for index in 0..<view.noiseDensities.count { densities.append(view.noiseDensities[index]) }
                            }
                            try noisy.withNoiseDensities(state: state, frequency: frequency) { span in
                                #expect(span.count == densities.count)
                                for index in 0..<span.count { #expect(abs(span[index] - densities[index]) <= max(1e-300, abs(densities[index]) * 2e-12)) }
                            }
                        }
                        try prepared.close()
                    } catch { do { try prepared.close() } catch { Issue.record("Prepared cleanup failed") }; throw error }
                    native.close()
                    try library.close()
                } catch { do { try library.close() } catch { Issue.record("Native image cleanup failed") }; throw error }
                try await fixture.close()
            } catch { do { try await fixture.close() } catch { Issue.record("Fixture cleanup failed") }; throw error }
        }
    }

    @Test func freshCandidateBoundsDoNotPublishAndAcceptedBoundsCanClear() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("corespice-osdi-bound-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { do { try FileManager.default.removeItem(at: directory) } catch { Issue.record("Bound fixture cleanup failed") } }
        let compiler = ProcessInfo.processInfo.environment["OSDI_OPENVAF_COMPILER"]
            ?? root.deletingLastPathComponent().appendingPathComponent("swift-osdi/.verification/s2-compiler/build-attempt-4-release/products/openvaf-r").path
        let source = root.appendingPathComponent(".build/checkouts/swift-osdi/Tests/OSDIEvaluationTests/Fixtures/dynamic_profile.va")
        let output = directory.appendingPathComponent("bound.osdi")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: compiler)
        process.arguments = ["--full-residuals", "-O", "1", "--target", "aarch64-apple-darwin", source.path, "-o", output.path]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run()
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        do {
            while process.isRunning {
                guard ContinuousClock.now < deadline else { throw OSDIDCManifest.Failure.oracleFailure("Bound fixture compilation timeout") }
                try await Task.sleep(for: .milliseconds(5))
            }
        } catch { if process.isRunning { kill(process.processIdentifier, SIGKILL) }; throw error }
        guard process.terminationStatus == 0 else { throw OSDIDCManifest.Failure.oracleFailure("Bound fixture compilation failed") }
        let reference = try LocalArtifactReferencer(digester: SHA256ContentDigester()).reference(
            ArtifactLocator(location: ArtifactLocation(workspaceRelativePath: "bound.osdi"), role: .input, kind: .model, format: .raw), relativeTo: directory)
        let fixture = try OSDIAdapterFixture(library: .init(id: "bound", path: output.path,
            sha256: reference.digest.hexadecimalValue, descriptorIndex: 0, descriptorName: "dynamic_profile"))
        do {
            var prepared = try await fixture.prepare([fixture.instance("N1", nodes: [Node(id: 1), .ground])])
            do {
                let topology = CircuitTopology(ir: prepared.circuit)
                var context = fixture.context(topology)
                guard let owner = try prepared.takeDevice(at: 0) else { throw OSDIAdapterFixture.FixtureFailure.missingOwner }
                let device = try owner.bind(context: &context)
                let session = try #require(device as? any TransientSessionDevice)
                let query = try #require(device as? any TransientTrialTimeStepConstraintDevice)
                let accepted = try #require(device as? any TransientTimeStepConstraintDevice)
                let positive = SolutionState(variables: [1], variableMap: topology.variableMap)
                let zero = SolutionState(variables: [0], variableMap: topology.variableMap)
                try session.beginTransientSession(initialState: positive, initialization: .initialConditions)
                #expect(accepted.maximumTransientTimeStep == 0.25)
                let first = IntegrationState(method: .backwardEuler, timeStep: 0.1, currentTime: 0.1)
                #expect(try query.maximumTransientTimeStep(state: positive, integration: first) == 0.35)
                #expect(accepted.maximumTransientTimeStep == 0.25)
                try session.commitTransientStep(state: positive, integration: first)
                #expect(accepted.maximumTransientTimeStep == 0.35)
                let second = IntegrationState(method: .backwardEuler, timeStep: 0.1, currentTime: 0.2)
                #expect(try query.maximumTransientTimeStep(state: zero, integration: second) == nil)
                #expect(accepted.maximumTransientTimeStep == 0.35)
                let negative = SolutionState(variables: [-1], variableMap: topology.variableMap)
                do {
                    _ = try query.maximumTransientTimeStep(state: negative, integration: second)
                    Issue.record("Invalid native bound admitted")
                } catch { }
                #expect(accepted.maximumTransientTimeStep == 0.35)
                try session.commitTransientStep(state: zero, integration: second)
                #expect(accepted.maximumTransientTimeStep == .infinity)
                session.endTransientSession()
                try prepared.close()
            } catch { do { try prepared.close() } catch { Issue.record("Prepared cleanup failed") }; throw error }
            try await fixture.close()
        } catch { do { try await fixture.close() } catch { Issue.record("Fixture cleanup failed") }; throw error }
    }

    @Test func retainedNoiseNameAdmissionRefusesBeforeProjectionAndFreshPreparationStillWorks() async throws {
        let manifest = try Self.manifest()
        let fixture = try OSDIAdapterFixture(library: try #require(manifest.libraries.first { $0.descriptorName == "dynamic_rc" }))
        do {
            let instance = try fixture.instance("N1", nodes: [Node(id: 1), .ground])
            let ir = CircuitIR(nodes: [.ground, Node(id: 1)], branches: [], instances: [instance])
            let metadataOnly = try OSDIAdapterCapacity.initial(ir: ir)
                + OSDIAdapterCapacity.instance(nodeCount: 2, stateCount: 0, noiseSourceCount: 2)
            do {
                let unexpected = try await fixture.prepareCircuit(ir, maximumAdapterBytes: metadataOnly)
                try unexpected.close()
                Issue.record("Retained descriptor names escaped admission")
            } catch { guard case OSDIAdapterFailure.capacityExceeded = error else { throw error } }
            let valid = try await fixture.prepareCircuit(ir)
            try valid.close()
            try await fixture.close()
        } catch { do { try await fixture.close() } catch { Issue.record("Fixture cleanup failed") }; throw error }
    }

    private func withDevice(_ descriptor: String, nodes: [Node] = [Node(id: 1), .ground],
        parameters: [OSDIParameterAssignment] = [], previous: [Double] = [],
        _ body: (any BoundDevice, CircuitTopology, Instance) throws -> Void) async throws {
        let manifest = try Self.manifest()
        let fixture = try OSDIAdapterFixture(library: try #require(manifest.libraries.first { $0.descriptorName == descriptor }))
        do {
            var prepared = try await fixture.prepare([fixture.instance("N1", nodes: nodes,
                modelParameters: parameters, previousState: previous)])
            do {
                let topology = CircuitTopology(ir: prepared.circuit)
                var context = fixture.context(topology)
                guard let owner = try prepared.takeDevice(at: 0) else { throw OSDIAdapterFixture.FixtureFailure.missingOwner }
                let device = try owner.bind(context: &context)
                try body(device, topology, prepared.circuit.instances[0])
                try prepared.close()
            } catch { do { try prepared.close() } catch { Issue.record("Prepared cleanup failed") }; throw error }
            try await fixture.close()
        } catch { do { try await fixture.close() } catch { Issue.record("Fixture cleanup failed") }; throw error }
    }
    private static func manifest() throws -> OSDIAnalysisManifest {
        guard let path = ProcessInfo.processInfo.environment["CORESPICE_OSDI_ANALYSIS_MANIFEST"] else { throw OSDIDCManifest.Failure.invalidManifest }
        return try JSONDecoder().decode(OSDIAnalysisManifest.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    }
}
