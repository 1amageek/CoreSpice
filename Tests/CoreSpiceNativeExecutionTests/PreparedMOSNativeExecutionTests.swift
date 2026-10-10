import CoreSpice
@testable import CoreSpiceIO
import CoreSpiceIR
import CoreSpiceDevices
import CoreSpiceMOSContracts
import CoreSpiceMOSResolution
import Testing

extension PreparedNativeExecutionTests {
    private func mosInput(release: MOSModelRelease = .level1, sweep: Bool = true,
                          resources: SourceBoundaryTestResources = .init()) async throws -> PreparedSPICESimulation {
        let analysis = sweep ? ".dc VG 0 1 0.5" : ".op"
        let retained = try await input("native stage\nVDD d 0 1\nVG g 0 1\nR1 d 0 1k\n.options bsim4stressiterations=128\n\(analysis)\n.end\n", resources: resources)
        let limits = try MOSResolutionLimits(maximumRetainedBytes: 8_000_000, maximumDiagnosticBytes: 4096,
            maximumScopeDepth: 32, maximumSymbols: 256, maximumScopes: 32,
            maximumInvocations: 64, maximumInvocationBindings: 512, maximumDeclarations: 128,
            maximumPrograms: 256, maximumBindings: 256, maximumFunctions: 32, maximumFunctionDepth: 32,
            maximumExpressionNodes: 256, maximumExpressionDepth: 128, maximumCandidates: 128,
            maximumCacheEntries: 256, maximumEvaluationSteps: 1_000_000)
        var builder = MOSDeclarationSnapshotBuilder(limits: limits)
        let scope = try builder.addScope(parent: nil)
        let model = try builder.intern("n")
        let source = MOSSourceOccurrence(captureID: retained.sources[0].binding.key, occurrenceID: 0,
            path: nil, line: 1, column: 1, statementByteOffset: 0, statementOrdinal: 0)
        let physicalParameters: [(String, Double)]
        switch release {
        case .level1, .level2, .level3:
            physicalParameters = [("vto", 0.4), ("kp", 1e-4)]
        case .bsim3_3_3_0:
            physicalParameters = [("tox", 1e-8), ("vth0", 0.4), ("u0", 0.05)]
        case .bsim4_4_5, .bsim4_4_8_3:
            physicalParameters = [("toxe", 1e-8), ("vth0", 0.4), ("u0", 0.05)]
        }
        var coefficients: [MOSExpressionBinding] = []
        for (name, value) in physicalParameters {
            let symbol = try builder.intern(name)
            let program = try builder.addProgram(.literal(value))
            coefficients.append(.init(symbol: symbol, program: program))
        }
        _ = try builder.addModel(name: "n", scope: scope, polarity: .nmos, level: release.level,
            version: release.exactVersion, coefficients: coefficients, source: source)
        let length = try builder.intern("l"), width = try builder.intern("w")
        let lengthProgram = try builder.addProgram(.literal(1e-6))
        let widthProgram = try builder.addProgram(.literal(10e-6))
        let bindings = [MOSExpressionBinding(symbol: length, program: lengthProgram),
                        MOSExpressionBinding(symbol: width, program: widthProgram)]
        let snapshot = try builder.finish()
        let graph = try MOSInvocationGraph(snapshot: snapshot, invocations: [
            try MOSScopeInvocation(id: 1, scope: scope, callerInvocationID: nil, actuals: [], limits: limits)
        ], limits: limits)
        var session = try MOSEvaluationSession(snapshot: snapshot, graph: graph, seed: 42, limits: limits)
        let resolved = try resolveMOS(.init(instance: "M1", scope: scope, scopeInstantiation: 1,
            modelReference: model, profile: .coreStrictV1, bindings: bindings, geometryScale: 1, seed: 42, limits: limits),
            from: snapshot, schemas: StandardMOSModelSchemas(), session: &session)
        let d = try #require(retained.circuit.nodeNames.first(where: { $0.value == "d" })?.key)
        let g = try #require(retained.circuit.nodeNames.first(where: { $0.value == "g" })?.key)
        var instances = retained.circuit.instances
        instances.append(Instance(name: "M1", typeName: "nmos_l\(release.level)", nodes: [d, g, .ground, .ground],
            parameters: [:], mos: .resolved(resolved)))
        let circuit = CircuitIR(nodes: retained.circuit.nodes, branches: retained.circuit.branches,
            instances: instances, nodeNames: retained.circuit.nodeNames, branchNames: retained.circuit.branchNames)
        return PreparedSPICESimulation(parsedResult: retained.parsedResult, sourceOccurrences: retained.sourceOccurrences,
            sources: retained.sources, circuit: circuit, configuration: retained.configuration,
            sourceInputIdentity: retained.sourceInputIdentity, initialConditions: retained.initialConditions,
            nodeSets: retained.nodeSets,
            reservation: try resources.reserveStorage(kind: .liveOwnedBytes, byteCount: 1), resources: resources,
            maximumTransformBytes: retained.maximumTransformBytes)
    }

    private func mosLimits(ambient: Double = 300.15, nominal: Double = 300.15,
                           capabilities: MOSAnalysisCapabilities = [.dc], stress: UInt32 = 128,
                           allocation: UInt64 = 32 * 1024 * 1024) throws -> SPICENativeExecutionLimits {
        .init(maximumDeviceCount: 100, maximumMatrixDimension: 32, maximumAllocationBytes: allocation,
            mosPreparationLimits: try .init(maximumRetainedBytes: 1024 * 1024,
                maximumTemporaryBytes: 1024 * 1024, maximumDiagnosticBytes: 4096, maximumWorkUnits: 1_000_000),
            mosPreparationConditions: try .init(ambientKelvin: ambient, nominalKelvin: nominal,
                analysisCapabilities: capabilities, maximumStressIterations: stress))
    }

    @Test func mosPreparationRunsOnceAcrossSweepAndFreshRerun() async throws {
        for release in [MOSModelRelease.level1, .bsim3_3_3_0, .bsim4_4_8_3] {
            let resources = SourceBoundaryTestResources()
            let input = try await mosInput(release: release, resources: resources)
            let prepared = try SPICENativeSimulation().prepare(input, limits: mosLimits())
            #expect(prepared.record.mosPreparationReceipts.count == 1)
            #expect(prepared.record.mosPreparationReceipts[0].coldSetupCount == 1)
            let preparedWork = resources.work(.retainedElements)
            let output = try await SPICENativeSimulation().execute(prepared, cancellation: .init())
            #expect(output.waveform.pointCount == 3)
            let gate = try #require(output.waveform.variables.firstIndex { $0.name.lowercased() == "v(g)" })
            let drainCurrent = try #require(output.waveform.variables.firstIndex { $0.name.lowercased() == "i(vdd)" })
            for point in 0..<3 {
                #expect(abs(try #require(output.waveform.realValue(variable: gate, point: point)) - Double(point) * 0.5) < 1e-8)
            }
            let firstCurrent = try #require(output.waveform.realValue(variable: drainCurrent, point: 0))
            let lastCurrent = try #require(output.waveform.realValue(variable: drainCurrent, point: 2))
            print("native-mos-sweep release=\(release.rawValue) firstCurrent=\(firstCurrent) lastCurrent=\(lastCurrent)")
            #expect(abs(lastCurrent - firstCurrent) > 1e-9,
                "Release \(release.rawValue): current must respond to gate sweep; first=\(firstCurrent), last=\(lastCurrent)")
            #expect(resources.work(.retainedElements) == preparedWork)
            let model = try #require(output.executedModels.first(where: { $0.instanceName == "M1" }))
            #expect(model.mosPreparation?.identity.resolved.release == release)
            #expect(model.mosPreparation?.coldSetupCount == 1 && model.completedPointCount == 3)
            let fresh = try SPICENativeSimulation().prepare(output.prepared.input, limits: output.prepared.limits)
            #expect(resources.work(.retainedElements) > preparedWork)
            let repeated = try await SPICENativeSimulation().execute(fresh, cancellation: .init())
            #expect(output.configurationIdentity == repeated.configurationIdentity)
            #expect(output.waveform.sweepValues == repeated.waveform.sweepValues)
            for variable in output.waveform.variables.indices {
                for point in 0..<output.waveform.pointCount {
                    #expect(output.waveform.realValue(variable: variable, point: point) ==
                        repeated.waveform.realValue(variable: variable, point: point))
                }
            }
        }
    }

    @Test func mosConditionsAndCapacityFailBeforePublicationAndReleaseReservations() async throws {
        let resources = SourceBoundaryTestResources()
        let input = try await mosInput(release: .bsim4_4_8_3, resources: resources)
        let baseline = resources.used(.liveOwnedBytes)
        for limits in [try mosLimits(ambient: 301.15), try mosLimits(nominal: 301.15),
                       try mosLimits(capabilities: [.dc, .noise]), try mosLimits(stress: 127)] {
            do {
                _ = try SPICENativeSimulation().prepare(input, limits: limits)
                Issue.record("Mismatched MOS conditions accepted")
            } catch SPICENativePreparationError.mosPreparation(.invalidConditions) {}
            #expect(resources.used(.liveOwnedBytes) == baseline)
        }
        #expect(throws: SPICENativePreparationError.self) {
            _ = try SPICENativeSimulation().prepare(input, limits: mosLimits(allocation: 1))
        }
        #expect(resources.used(.liveOwnedBytes) == baseline)
        do {
            let prepared = try SPICENativeSimulation().prepare(input, limits: mosLimits())
            #expect(resources.used(.liveOwnedBytes) > baseline)
            withExtendedLifetime(prepared) {}
        }
        #expect(resources.used(.liveOwnedBytes) == baseline)
        resources.setCancelled(true)
        #expect(throws: SPICENativePreparationError.self) {
            _ = try SPICENativeSimulation().prepare(input, limits: mosLimits())
        }
        #expect(resources.used(.liveOwnedBytes) == baseline)
    }
}
