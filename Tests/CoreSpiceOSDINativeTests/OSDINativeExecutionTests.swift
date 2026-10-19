import Foundation
import Darwin
import CoreSpice
import CoreSpiceIO
import CoreSpiceOSDITestSupport
import CoreSpiceParsedIR
import CircuiteFoundation
import OSDIRuntime
import Synchronization
import Testing

@Suite(.timeLimit(.minutes(3)))
struct OSDINativeExecutionTests {
    @Test func originalSourceNativeAPIReplaysEveryAvailableIndependentCircuitAndAllUnknowns() async throws {
        let fixture = try OSDINativeFixture()
        defer { do { try fixture.close() } catch { Issue.record("Fixture cleanup failed: \(error)") } }
        #expect(fixture.manifest.cases.count >= 43)
        let families = Set(fixture.manifest.libraries.map(\.descriptorName))
        #expect(families.isSuperset(of: ["bsimbulk", "bsimcmg_va", "bsimimg", "bsimsoi"]))
        let expectedCompleted = fixture.manifest.cases.filter { $0.reference.status == "converged" }.count
        let expectedCoordinates = fixture.manifest.cases.reduce(0) { $0 + ($1.reference.unknowns?.count ?? 0) }
        var completed = 0, coordinates = 0, refused = 0, thermal = 0
        for point in fixture.manifest.cases {
            let counts = try await replay(point, fixture: fixture)
            completed += counts.completed; coordinates += counts.coordinates
            refused += counts.refused; thermal += counts.thermal
        }
        #expect(completed == expectedCompleted)
        #expect(coordinates == expectedCoordinates)
        #expect(refused == 2)
        #expect(thermal > 0)
    }

    private func replay(_ point: OSDIDCManifest.Case, fixture: OSDINativeFixture)
        async throws -> (completed: Int, coordinates: Int, refused: Int, thermal: Int) {
        var thermal = 0
        let input = try await fixture.input(point)
        let runtime = try fixture.runtime(point)
        let native = SPICENativeSimulation()
        let prepared = try await native.prepare(input, limits: fixture.limits, osdi: runtime)
        #expect(prepared.record.osdiPreparationRecords.count == point.input.devices.count)
        do {
            let output = try await native.execute(prepared, cancellation: CancellationToken())
            #expect(point.reference.status == "converged", "\(point.id) must not complete")
            let joined = try candidates(point, output: output)
            try await validateWithOracle(point, candidates: joined)
            #expect(joined.count == output.waveform.variables.count)
            #expect(output.executedModels.compactMap(\.osdiPreparation).count == point.input.devices.count)
            for model in output.executedModels {
                if let osdi = model.osdiPreparation { #expect(model.selectedModelIdentifier == osdi.receipt.resolved.binding.modelName) }
            }
            #expect(output.executedModels.allSatisfy { $0.completedPointCount == 1 })
            for record in output.prepared.osdiPreparationRecords {
                let device = try #require(point.input.devices.first { OSDINativeFixture.sourceName($0.id) == record.instanceName })
                #expect(record.receipt.effectiveTemperatureKelvin == device.temperatureKelvin)
                #expect(record.receipt.resolved.previousState == device.previousState)
                #expect(record.receipt.resolved.binding.artifact == fixture.references[device.library])
                #expect(record.rawNodeGlobalRows.count == record.receipt.topology.nodes.count)
            }
            for (row, variable) in output.waveform.variables.enumerated() where variable.unit == .kelvin {
                #expect(variable.name.hasPrefix("dT(") && variable.type == .temperature)
                #expect(output.waveform.realValue(variable: row, point: 0) != point.input.devices.first?.temperatureKelvin)
                thermal += 1
            }
            if point.id == "linear-current" {
                let again = try await native.prepare(output.prepared.input, limits: output.prepared.limits,
                    osdi: try #require(output.prepared.osdiRuntimeInputs))
                let repeated = try await native.execute(again, cancellation: CancellationToken())
                #expect(repeated.configurationIdentity == output.configurationIdentity)
                let repeatedCandidates = try candidates(point, output: repeated)
                #expect(repeatedCandidates == joined)
            }
            print("Native OSDI \(point.id): \(joined.count) coordinates independently validated")
            return (1, joined.count, 0, thermal)
        } catch let error as SPICENativeExecutionError {
            guard point.reference.status != "converged" else { throw error }
            guard case .numerical(let diagnostic) = error, let numerical = diagnostic as? AnalysisError else { throw error }
            switch numerical { case .singularMatrix, .convergenceFailure: break; default: throw error }
            return (0, 0, 1, 0)
        }
    }

    @Test func missingRuntimeIdentityCapacityCancellationAndCleanupAreExplicit() async throws {
        let fixture = try OSDINativeFixture()
        defer { do { try fixture.close() } catch { Issue.record("Fixture cleanup failed") } }
        let point = try #require(fixture.manifest.cases.first { $0.id == "linear-current" })
        let input = try await fixture.input(point)
        #expect(throws: SPICENativePreparationError.self) { _ = try SPICENativeSimulation().prepare(input, limits: fixture.limits) }
        #expect(throws: CompileError.self) { _ = try StandardCompiler().compile(ir: input.circuit) }
        let tracked = TrackingProvider(base: fixture.provider)
        let runtime = try fixture.runtime(point, provider: tracked)
        do {
            _ = try await SPICENativeSimulation().prepare(input,
                limits: .init(maximumDeviceCount: 256, maximumMatrixDimension: 256, maximumAllocationBytes: 1), osdi: runtime)
            Issue.record("Capacity refusal was not enforced")
        } catch SPICENativePreparationError.capacityExceeded {}
        #expect(tracked.count == 0)
        let originalCatalog = try fixture.catalog(point)
        let wrong = try #require(originalCatalog[OSDINativeFixture.sourceName("N1")])
        let binding = try OSDIModelBinding(modelName: wrong.binding.modelName, artifact: wrong.binding.artifact,
            descriptorIndex: wrong.binding.descriptorIndex, expectedDescriptorName: "wrong-descriptor", modelParameters: wrong.binding.modelParameters)
        let wrongInput = try await fixture.input(point, catalog: [OSDINativeFixture.sourceName("N1"): OSDIResolvedInstance(binding: binding,
            instanceParameters: wrong.instanceParameters, previousState: wrong.previousState)])
        do { _ = try await SPICENativeSimulation().prepare(wrongInput, limits: fixture.limits, osdi: runtime); Issue.record("Wrong identity accepted") }
        catch SPICENativePreparationError.osdi(.identityMismatch) {}
        try tracked.expectClosed()
        let prepared = try await SPICENativeSimulation().prepare(input, limits: fixture.limits, osdi: runtime)
        let cancellation = CancellationToken(); cancellation.cancel()
        do { _ = try await SPICENativeSimulation().execute(prepared, cancellation: cancellation); Issue.record("Cancelled run completed") }
        catch SPICENativeExecutionError.cancelled {}
        try tracked.expectClosed()
        let direct = try await NativeCircuitPreparer().prepare(ir: input.circuit, registry: .standard(),
            operatingConditions: input.configuration.options.operatingConditions(), limits: fixture.limits,
            numericalLimits: input.configuration.numericalLimits, resources: input.resources, osdi: runtime)
        let directSweep = try await DCAnalysis(config: input.configuration.options.convergence).runSweep(circuit: direct,
            source: "VREF", values: [0, 1], solver: SparseLUSolver(), observer: nil, cancellation: .init())
        #expect(directSweep.result.results.count == 2)
        try tracked.expectClosed()
        let sweepInput = try await fixture.input(point, analysis: ".dc VREF 0 1 0.1")
        guard case .dc(_, let values, _) = sweepInput.configuration.analysis else {
            Issue.record("Source sweep configuration was lost"); throw OSDIDCManifest.Failure.invalidManifest
        }
        #expect(values.count == 11)
        let auxiliaryPoint = try #require(fixture.manifest.cases.first { $0.id == "mixed-collapse-private" })
        let auxiliaryInput = try await fixture.input(auxiliaryPoint)
        let baseDimension = auxiliaryInput.circuit.nodes.filter { $0 != auxiliaryInput.circuit.groundNode }.count
            + auxiliaryInput.circuit.branches.count
        do {
            _ = try await SPICENativeSimulation().prepare(auxiliaryInput,
                limits: .init(maximumDeviceCount: 256, maximumMatrixDimension: baseDimension,
                    maximumAllocationBytes: fixture.limits.maximumAllocationBytes),
                osdi: fixture.runtime(auxiliaryPoint, provider: tracked))
            Issue.record("Setup-created private coordinates bypassed matrix capacity")
        } catch SPICENativePreparationError.capacityExceeded {}
        try tracked.expectClosed()
        do {
            _ = try await SPICENativeSimulation().prepare(input, limits: fixture.limits,
                osdi: fixture.runtime(point, provider: tracked, maximumAdapterBytes: 1))
            Issue.record("Adapter capacity bypassed")
        } catch SPICENativePreparationError.osdi(.capacityExceeded) {}
        try tracked.expectClosed()
        let blocked = TrackingProvider(base: fixture.provider, holdStorage: true)
        let owner = try await SPICENativeSimulation().prepare(input, limits: fixture.limits,
            osdi: fixture.runtime(point, provider: blocked))
        do { _ = try await SPICENativeSimulation().execute(owner, cancellation: .init()); Issue.record("Failed cleanup published completed output") }
        catch SPICENativeExecutionError.osdiCleanup(let cleanup) {
            guard case OSDIAdapterFailure.runtime(.libraryInUse) = cleanup.secondary else { throw cleanup }
            blocked.releaseStorage()
            try cleanup.retryClose()
            try blocked.expectClosed()
        }
    }

    @Test func ordinaryPreparedSourcePathRemainsExecutableAndRerunnable() async throws {
        let fixture = try OSDINativeFixture()
        defer { do { try fixture.close() } catch { Issue.record("Fixture cleanup failed") } }
        let input = try await fixture.source("Ordinary divider\nV1 in 0 2\nR1 in out 1000\nR2 out 0 1000\n.op\n.end\n", catalog: [:])
        let native = SPICENativeSimulation()
        let output = try await native.execute(native.prepare(input, limits: fixture.limits), cancellation: .init())
        #expect(output.prepared.osdiPreparationRecords.isEmpty && output.prepared.osdiRuntimeInputs == nil)
        let index = try #require(output.waveform.variables.firstIndex { $0.name.lowercased() == "v(out)" })
        #expect(abs(try #require(output.waveform.realValue(variable: index, point: 0)) - 1) < 1e-8)
        let repeated = try await native.execute(native.prepare(output.prepared.input, limits: output.prepared.limits), cancellation: .init())
        #expect(repeated.configurationIdentity == output.configurationIdentity)
    }

    private func candidates(_ point: OSDIDCManifest.Case, output: SPICENativeSimulationOutput) throws -> [String: Double] {
        let plan = output.prepared.plan
        var mapping: [String: Int] = [:]
        for (node, name) in plan.ir.nodeNames {
            if let row = plan.topology.variableMap[.nodeVoltage(node)] { mapping["net:" + name] = row }
        }
        for source in point.input.voltageSources {
            let branch = try #require(plan.ir.branchNames.first { $0.value.lowercased() == source.id.lowercased() }?.key)
            let row: Int = try #require(plan.topology.variableMap[.branchCurrent(branch)])
            mapping["branch:" + source.id] = row
        }
        for record in output.prepared.osdiPreparationRecords {
            let raw = try #require(point.reference.devices.first { OSDINativeFixture.sourceName($0.id) == record.instanceName }).rawNodes
            for node in raw {
                if let id = node.unknownID {
                    let row = try #require(record.rawNodeGlobalRows[node.index])
                    if let previous = mapping[id] { #expect(previous == row) }
                    mapping[id] = row
                }
            }
        }
        var result: [String: Double] = [:]
        for unknown in try #require(point.reference.unknowns) {
            let row = try #require(mapping[unknown.id])
            let value = try #require(output.waveform.realValue(variable: row, point: 0))
            let tolerance = try #require(point.input.policy.unknownAbsoluteTolerances[unknown.unit]) + point.input.policy.relativeTolerance * abs(unknown.value)
            #expect(abs(value - unknown.value) <= tolerance, "\(point.id):\(unknown.id): \(value) vs \(unknown.value)")
            result[unknown.id] = value
        }
        return result
    }

    private func validateWithOracle(_ point: OSDIDCManifest.Case, candidates: [String: Double]) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: try #require(point.validationBaseCommand.first))
        var arguments = Array(point.validationBaseCommand.dropFirst())
        for name in candidates.keys.sorted() { arguments += ["--candidate", name, String(try #require(candidates[name]))] }
        process.arguments = arguments
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("native-osdi-validation-\(UUID().uuidString).json")
        guard FileManager.default.createFile(atPath: file.path, contents: nil) else { throw OSDIDCManifest.Failure.invalidManifest }
        let handle = try FileHandle(forWritingTo: file)
        defer { handle.closeFile(); do { try FileManager.default.removeItem(at: file) } catch { Issue.record("Oracle cleanup failed") } }
        process.standardOutput = handle; process.standardError = handle
        try process.run()
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        do {
            while process.isRunning {
                guard ContinuousClock.now < deadline else { throw OSDIDCManifest.Failure.oracleFailure("timeout") }
                try await Task.sleep(for: .milliseconds(5))
            }
        } catch { if process.isRunning { kill(process.processIdentifier, SIGKILL) }; throw error }
        let text = String(decoding: try Data(contentsOf: file), as: UTF8.self)
        guard process.terminationStatus == 0 else { throw OSDIDCManifest.Failure.oracleFailure(text) }
    }

    final class TrackingProvider: OSDILibraryProviding {
        private struct State: ~Copyable { var libraries: [OSDILibrary] = []; var storage: OSDIStorage? }
        private let state = Mutex(State())
        let base: SPICEOSDILocalLibraryProvider
        let holdStorage: Bool
        init(base: SPICEOSDILocalLibraryProvider, holdStorage: Bool = false) { self.base = base; self.holdStorage = holdStorage }
        var count: Int { state.withLock { $0.libraries.count } }
        func load(reference: ArtifactReference, limits: OSDILoadLimits) async throws(OSDIError) -> OSDILibrary {
            let library = try await base.load(reference: reference, limits: limits)
            try state.withLock { state throws(OSDIError) in
                state.libraries.append(library)
                if holdStorage { state.storage = try library.makeStorage(descriptorIndex: 0) }
            }
            return library
        }
        func releaseStorage() { state.withLock { $0.storage = nil } }
        func expectClosed() throws {
            let libraries = state.withLock { $0.libraries }
            for library in libraries {
                do { _ = try library.makeStorage(descriptorIndex: 0); Issue.record("Library remained open after cleanup") }
                catch OSDIError.closed {}
            }
        }
    }
}
