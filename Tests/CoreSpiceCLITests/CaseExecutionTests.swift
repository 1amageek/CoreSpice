@testable import CoreSpiceIO
import CoreSpiceCompile
import CoreSpiceAnalysis
import CoreSpiceParsedIR
import CoreSpiceEvent
import CoreSpiceIR
import CoreSpiceDevices
import ToolQualification
import ToolQualificationCLICore
import Foundation
import Testing
import Synchronization
@testable import CoreSpiceCLICore

@Suite("Ordinary CLI completed case evidence", .timeLimit(.minutes(1)))
struct CaseExecutionTests {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("corespice-case-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }
    private func cleanup(_ url: URL) {
        do { try FileManager.default.removeItem(at: url) }
        catch { Issue.record("Temporary case cleanup failed: \(error)") }
    }
    private func batch(_ text: String, in root: URL, extra: [String] = []) async throws -> (ToolQualificationCaseExecution, [ToolQualificationModelExecutionReceipt], Session) {
        let source = root.appendingPathComponent("deck.cir")
        try text.write(to: source, atomically: true, encoding: .utf8)
        let output = root.appendingPathComponent("case")
        let args = ["-b", source.path, "--case-output", output.path, "--case-id", "actual-case", "--json"] + extra
        var session = Session()
        let record = try await CLI(arguments: args).executeBatch(options: .init(arguments: args), session: &session)
        let execution = try ToolQualificationCaseExecution.decodeCanonical(from: Data(contentsOf: output.appendingPathComponent("execution.json")))
        let receipts = try FileManager.default.contentsOfDirectory(at: output, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("model-receipt-") }.map {
                try ToolQualificationModelExecutionReceipt.decodeCanonical(from: Data(contentsOf: $0))
            }
        #expect(record.outputArtifacts.count == receipts.count + 1)
        let inventory = try JSONDecoder().decode(ToolQualificationCLIArtifactAvailabilityInventory.self,
            from: Data(contentsOf: output.appendingPathComponent("availability.json")))
        for availability in inventory.availabilities {
            guard case .local(let id, _, let relative) = availability else {
                Issue.record("Expected local publication"); continue
            }
            let bytes = try Data(contentsOf: output.appendingPathComponent(relative.stringValue))
            #expect(id.byteCount == UInt64(bytes.count))
        }
        #expect(execution.inputArtifacts.first?.id.byteCount == UInt64(text.utf8.count))
        return (execution, receipts, session)
    }

    @Test func flattenedAndGeneratedModelsRetainActualOriginsAndPhysics() async throws {
        let root = try directory(); defer { cleanup(root) }
        let source = """
        Flattened and generated origins
        .model dm d is=1e-12
        .model jm njf vto=-2 beta=1m rd=100 rs=50
        .model line urc rperl=1000 cperl=1n
        V1 in 0 1
        VG gate 0 -1
        D1 in 0 dm
        J1 in gate 0 jm
        U1 in out 0 line l=1 n=2
        R1 out 0 1000
        .op
        .end
        """
        let (execution, receipts, session) = try await batch(source, in: root)
        #expect(execution.phaseIDs == ["op"])
        #expect(Set(receipts.map(\.selectedModelIdentifier)) == Set(["dm", "jm", "line"]))
        let fet = try #require(receipts.first { $0.selectedModelIdentifier == "jm" })
        #expect(Set(fet.consumedInstances.keys) == Set(["j1", "j1.rd", "j1.rs"]))
        let line = try #require(receipts.first { $0.selectedModelIdentifier == "line" })
        #expect(line.consumedInstances.count == 7)
        #expect(line.consumedInstances.keys.allSatisfy { $0.hasPrefix("u1.") })
        let plan = try #require(session.plan)
        for instance in plan.ir.instances where instance.name.hasPrefix("u1.") || instance.name.hasPrefix("j1.") {
            #expect(instance.model == nil)
            guard case .selected(let model) = instance.modelConsumption else {
                Issue.record("Generated element lost source model"); continue
            }
            #expect(model.declarationID != nil)
        }
        #expect(abs(try #require(execution.observedMetrics["op:last:V(out)"]) - 0.5) < 1e-6)
        #expect(receipts.allSatisfy { $0.sourceArtifact == execution.inputArtifacts.first })
    }

    @Test func dcRebindsAndAggregateMeasurementsHaveActualContributors() async throws {
        let root = try directory(); defer { cleanup(root) }
        let (execution, receipts, session) = try await batch("""
        Actual DC phases
        .model rm r rsh=100
        V1 in 0 0
        R1 in 0 rm l=1u w=1u
        .dc V1 0 2 1
        .meas dc peak max V(in)
        .end
        """, in: root)
        #expect(execution.phaseIDs.count == 3)
        #expect(receipts.count == 3)
        #expect(abs(try #require(execution.observedMetrics["measure:peak"]) - 2) < 1e-9)
        #expect(execution.metricPhaseIDs["measure:peak"] == execution.phaseIDs)
        let phases = try #require(session.phaseCollector).phases
        for (index, phase) in phases.enumerated() {
            let source = try #require(phase.instances.first { $0.name == "v1" })
            guard case .real(let value) = source.parameters["v"] else { Issue.record("Missing rebound value"); continue }
            #expect(value == Double(index))
            #expect(abs(try #require(phase.observations["last:V(in)"]) - Double(index)) < 1e-9)
        }
    }

    @Test func monteCarloRecordsDistinctSeedParametersAndEachMeasurement() async throws {
        let root = try directory(); defer { cleanup(root) }
        let (execution, receipts, _) = try await batch("""
        Actual Monte Carlo phases
        .model rm r rsh=100
        V1 in 0 1
        R1 in out rm l={agauss(1u,0.1u,1)} w=1u
        R2 out 0 100
        .mc 2 dc V1 0 1 1
        .meas dc output max V(out)
        .end
        """, in: root, extra: ["--seed", "42"])
        #expect(execution.phaseIDs.count == 4)
        #expect(Set(execution.phaseIDs.map { $0.components(separatedBy: ":")[1] }) == Set(["42", "43"]))
        #expect(receipts.count == 4)
        let seedReceipts = [try #require(receipts.first { $0.phaseID.hasPrefix("mc-seed:42:") }),
                            try #require(receipts.first { $0.phaseID.hasPrefix("mc-seed:43:") })]
        let lengths = try seedReceipts.map { try #require($0.consumedInstances["r1"]?["l"]) }
        #expect(lengths[0] != lengths[1])
        for phase in execution.phaseIDs {
            #expect(execution.metricPhaseIDs["\(phase):last:V(out)"] == [phase])
            let seedPrefix = "mc-seed:" + phase.components(separatedBy: ":")[1] + ":"
            #expect(execution.metricPhaseIDs["\(seedPrefix)measure:output"] == execution.phaseIDs.filter { $0.hasPrefix(seedPrefix) })
        }
    }

    @Test func capturesArePublishedAfterOriginalPathsDisappear() async throws {
        let root = try directory(); defer { cleanup(root) }
        let file = root.appendingPathComponent("deck.cir")
        let text = "Captured input\n.model rm r rsh=100\nV1 in 0 1\nR1 in 0 rm l=1u w=1u\n.op\n.end\n"
        try text.write(to: file, atomically: true, encoding: .utf8)
        let loaded = try await SPICEDeckLoader.loadFile(at: file.path)
        try FileManager.default.removeItem(at: file)
        var session = Session(); try session.loadNetlist(loaded)
        session.phaseCollector = try CoreSpiceCLIPhaseCollector()
        _ = try await session.run(.op)
        let output = root.appendingPathComponent("case")
        _ = try CoreSpiceCLICasePublisher().publish(directory: output.path, caseID: "capture-case", loadedDeck: loaded,
            phases: try #require(session.phaseCollector), referencer: CoreSpiceCLIArtifactReferencer())
        #expect(try String(contentsOf: output.appendingPathComponent("input-0.spice"), encoding: .utf8) == text)
    }

    @Test func failedAndIncompleteExecutionCannotPublishSuccess() async throws {
        let root = try directory(); defer { cleanup(root) }
        let loaded = try await SPICEDeckLoader.load(source: "Failed\nV1 in 0 1\nR1 in 0 1k\n.dc missing 0 1 1\n.end\n")
        var session = Session(); try session.loadNetlist(loaded)
        session.phaseCollector = try CoreSpiceCLIPhaseCollector()
        await #expect(throws: CLIError.self) { _ = try await session.runParsed(try session.requiredDefaultRunnableAnalysis()) }
        let collector = try #require(session.phaseCollector)
        #expect(!collector.isComplete)
        #expect(collector.phases.isEmpty)
        #expect(throws: CoreSpiceCLICaseError.self) {
            _ = try CoreSpiceCLICasePublisher().publish(directory: root.appendingPathComponent("failed").path,
                caseID: "failed-case", loadedDeck: loaded, phases: collector, referencer: CoreSpiceCLIArtifactReferencer())
        }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("failed").path))
    }

    @Test func publicationRefusesExistingOutputAndPreservesCapturedInputs() async throws {
        let root = try directory(); defer { cleanup(root) }
        let source = "Existing output\nV1 in 0 1\nR1 in 0 1k\n.op\n.end\n"
        _ = try await batch(source, in: root)
        let original = try Data(contentsOf: root.appendingPathComponent("case/execution.json"))
        await #expect(throws: CoreSpiceCLICaseError.self) { _ = try await batch(source, in: root) }
        #expect(try Data(contentsOf: root.appendingPathComponent("case/execution.json")) == original)
    }
    @Test func missingSelectedOriginRefusesAfterActualNumericalSuccess() async throws {
        let root = try directory(); defer { cleanup(root) }
        let loaded = try await SPICEDeckLoader.load(source: "Missing origin\n.model rm r rsh=100\nV1 in 0 1\nR1 in 0 rm l=1u w=1u\n.op\n.end\n")
        let parsed = ParsedNetlist(components: loaded.netlist.components, models: loaded.netlist.models.map {
            ParsedModel(name: $0.name, type: $0.type, level: $0.level, parameters: $0.parameters)
        }, analyses: loaded.netlist.analyses)
        let untracked = LoadedSPICEDeck(source: loaded.source, netlist: parsed, coverage: loaded.coverage,
            captures: loaded.captures, capturePolicy: loaded.capturePolicy)
        var session = Session(); try session.loadNetlist(untracked)
        session.phaseCollector = try CoreSpiceCLIPhaseCollector()
        _ = try await session.run(.op)
        #expect(try #require(session.phaseCollector).isComplete)
        #expect(throws: CoreSpiceCLICaseError.self) {
            _ = try CoreSpiceCLICasePublisher().publish(directory: root.appendingPathComponent("case").path,
                caseID: "missing-origin", loadedDeck: untracked, phases: #require(session.phaseCollector),
                referencer: CoreSpiceCLIArtifactReferencer())
        }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("case").path))
    }

    @Test func unrecordedDirectIRCannotBeInferredModelFree() async throws {
        let root = try directory(); defer { cleanup(root) }
        let loaded = try await SPICEDeckLoader.load(source: "Source input\nV1 in 0 1\nR1 in 0 1k\n.op\n.end\n")
        var netlist = Netlist()
        try netlist.addInstance(name: "v1", typeName: "vsource", nodes: ["in", "0"], parameters: ["v": .real(1)],
            ownedBranches: [netlist.branch(name: "v1")])
        try netlist.addInstance(name: "r1", typeName: "resistor", nodes: ["in", "0"], parameters: ["r": .real(1000)])
        let plan = try StandardCompiler().compile(ir: netlist.build())
        let registry = SPICEAnalysisOptions.default.deviceRegistry()
        let structure = plan.matrixStructure
        var context = BindingContext(variableMap: plan.topology.variableMap, matrixDimension: plan.topology.dimension,
            branchNames: plan.ir.branchNames, stampIndexResolver: { structure.index(row: $0, col: $1) })
        let devices = try plan.ir.instances.map { instance in
            try #require(registry.descriptor(for: instance.typeName)).bind(instance: instance, context: &context)
        }
        let result = try await DCAnalysis().run(plan: plan, devices: devices, solver: SparseLUSolver(),
            observer: nil, cancellation: CancellationToken())
        let collector = try CoreSpiceCLIPhaseCollector()
        try collector.record(id: "op", devices: devices, conditions: .nominal,
            waveform: .from(dcResult: result, topology: plan.topology.circuitTopology))
        collector.finish()
        #expect(throws: CoreSpiceCLICaseError.self) {
            _ = try CoreSpiceCLICasePublisher().publish(directory: root.appendingPathComponent("case").path,
                caseID: "unrecorded", loadedDeck: loaded, phases: collector, referencer: CoreSpiceCLIArtifactReferencer())
        }
    }

    @Test func completedModelFreeCaseClaimsNoUnusedDeclaration() async throws {
        let root = try directory(); defer { cleanup(root) }
        let (execution, receipts, _) = try await batch("Unused declaration\n.model unused r rsh=100\nV1 in 0 1\nR1 in 0 1k\n.op\n.end\n", in: root)
        #expect(execution.phaseIDs == ["op"])
        #expect(receipts.isEmpty)
        #expect(execution.modelReceiptArtifacts.isEmpty)
    }

    @Test func cancelledExecutionCannotPublishAndPhaseBudgetRefusesBeforeLoop() async throws {
        let root = try directory(); defer { cleanup(root) }
        let loaded = try await SPICEDeckLoader.load(source: "Cancelled\nV1 in 0 1\nR1 in 0 1k\n.op\n.end\n")
        var session = Session(); try session.loadNetlist(loaded)
        let collector = try CoreSpiceCLIPhaseCollector()
        session.phaseCollector = collector
        let cancellation = CancellationToken()
        cancellation.cancel()
        await #expect(throws: AnalysisError.self) { _ = try await session.run(.op, cancellation: cancellation) }
        #expect(!collector.isComplete)
        await #expect(throws: CoreSpiceCLICaseError.self) {
            _ = try await batch("Budget\nV1 in 0 1\nR1 in 0 1k\n.dc V1 0 10000 1\n.end\n", in: root)
        }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("case").path))
    }

    @Test func oneDeclarationWithDistinctScopeParametersProducesDistinctReceipts() async throws {
        let root = try directory(); defer { cleanup(root) }
        let (execution, receipts, _) = try await batch("""
        Scope-specific model parameters
        .subckt cell p n sheet=100
        .model rm r rsh={sheet}
        R1 p n rm l=1u w=1u
        .ends cell
        V1 in 0 1
        X1 in 0 cell sheet=100
        X2 in 0 cell sheet=200
        .op
        .end
        """, in: root)
        #expect(execution.phaseIDs == ["op"])
        #expect(receipts.count == 2)
        #expect(Set(receipts.map(\.modelID)).count == 1)
        #expect(Set(receipts.compactMap { $0.resolvedParameters["rsh"] }) == Set([100, 200]))
        #expect(Set(receipts.flatMap { $0.consumedInstances.keys }) == Set(["x1.r1", "x2.r1"]))
    }

    @Test func aggregateContributorExpansionIsAdmittedBeforePublication() async throws {
        let root = try directory(); defer { cleanup(root) }
        let loaded = try await SPICEDeckLoader.load(source: "Small evidence budget\nV1 in 0 1\nR1 in 0 1k\n.dc V1 0 2 1\n.end\n")
        var phaseLimitedSession = Session(); try phaseLimitedSession.loadNetlist(loaded)
        phaseLimitedSession.phaseCollector = try CoreSpiceCLIPhaseCollector(maximumRetainedBytes: 16 * 1024,
            maximumEncodedBytes: 256)
        await #expect(throws: CoreSpiceCLICaseError.self) {
            _ = try await phaseLimitedSession.runParsed(try phaseLimitedSession.requiredDefaultRunnableAnalysis())
        }
        let phaseLimitedCollector = try #require(phaseLimitedSession.phaseCollector)
        #expect(phaseLimitedCollector.phases.isEmpty)
        #expect(!phaseLimitedCollector.isComplete)
        var session = Session(); try session.loadNetlist(loaded)
        session.phaseCollector = try CoreSpiceCLIPhaseCollector(maximumRetainedBytes: 16 * 1024,
            maximumEncodedBytes: 8192)
        _ = try await session.runParsed(try session.requiredDefaultRunnableAnalysis())
        let collector = try #require(session.phaseCollector)
        let measurements = (0..<40).map { index in
            SPICEMeasurementResult(analysisType: .dc, name: "measurement-\(index)", value: 1, unit: "V")
        }
        #expect(throws: CoreSpiceCLICaseError.self) {
            try collector.measurements(measurements, prefix: "", phaseIDs: collector.phases.map(\.id))
        }
        #expect(!collector.isComplete)
        #expect(throws: CoreSpiceCLICaseError.self) {
            _ = try CoreSpiceCLICasePublisher().publish(directory: root.appendingPathComponent("case").path,
                caseID: "budget-case", loadedDeck: loaded, phases: collector, referencer: CoreSpiceCLIArtifactReferencer())
        }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("case").path))
    }

    @Test func duplicateMeasurementIdentityRefusesCanonicalOutput() async throws {
        let root = try directory(); defer { cleanup(root) }
        let text = "Duplicate observations\nV1 in 0 1\nR1 in 0 1k\n.dc V1 0 1 1\n.meas dc same max V(in)\n.meas dc same min V(in)\n.end\n"
        var ordinary = Session(); try await ordinary.loadNetlist(source: text, fileName: nil)
        _ = try await ordinary.runParsed(try ordinary.requiredDefaultRunnableAnalysis())
        #expect(ordinary.lastMeasurements.count == 2)
        await #expect(throws: CoreSpiceCLICaseError.self) { _ = try await batch(text, in: root) }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("case").path))
    }

    @Test func cancellationDuringStagedPublicationRefusesFinalDirectory() async throws {
        let root = try directory(); defer { cleanup(root) }
        let loaded = try await SPICEDeckLoader.load(source: "Cancellation during publication\nV1 in 0 1\nR1 in 0 1k\n.op\n.end\n")
        var session = Session(); try session.loadNetlist(loaded)
        session.phaseCollector = try CoreSpiceCLIPhaseCollector()
        _ = try await session.run(.op)
        let phases = try #require(session.phaseCollector)
        let boundaries = Mutex(0)
        let publisher = CoreSpiceCLICasePublisher(publicationBoundary: {
            let count = boundaries.withLock { count in count += 1; return count }
            if count == 4 { withUnsafeCurrentTask { $0?.cancel() } }
        })
        let task = Task {
            try publisher.publish(directory: root.appendingPathComponent("case").path,
                caseID: "cancelled-publication", loadedDeck: loaded, phases: phases,
                referencer: CoreSpiceCLIArtifactReferencer())
        }
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(boundaries.withLock { $0 } == 4)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

}
