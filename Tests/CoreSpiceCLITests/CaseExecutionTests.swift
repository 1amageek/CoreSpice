@testable import CoreSpiceIO
import CoreSpice
import CoreSpiceCompile
import CoreSpiceLowering
import CoreSpiceMOSContracts
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
    @Test(arguments: [MOSInputProfile.coreStrictV1, .pinnedNgspiceNormalV1])
    func exactReleaseSpellingReachesProfileAdmissionAndNativeExecution(profile: MOSInputProfile) async throws {
        for version in ["4.5", "4.5.0", "4.500000e+0", "4.500000E+0", "4.50", "4.5k", "4.62"] {
            let root = try directory(); defer { cleanup(root) }
            let source = root.appendingPathComponent("deck.cir")
            try "Exact version\n.options bsim4stressiterations=8\n.model n nmos level=54 version=\(version)\nVD d 0 1\nVG g 0 1\nM1 d g 0 0 n l=1u w=2u\n.op\n.end\n"
                .write(to: source, atomically: true, encoding: .utf8)
            let output = root.appendingPathComponent("case")
            let args = ["-b", source.path, "--mos-profile", profile.rawValue,
                "--case-output", output.path, "--case-id", "exact-version", "--json"]
            let admitted = version == "4.5" || version == "4.5.0" ||
                (version == "4.500000e+0" && profile == .pinnedNgspiceNormalV1)
            var session = try Session(policy: .developerV1(profile: profile))
            do {
                _ = try await CLI(arguments: args).executeBatch(options: .init(arguments: args), session: &session)
                #expect(admitted)
                #expect(session.completedBSIM45Models.count == 1)
                #expect(session.completedBSIM45Models[0].implementationIdentity.contains("BSIM45-4.5.0"))
            } catch let failure as MOSResolutionFailure {
                #expect(!admitted)
                #expect(failure == .schema(.unsupportedRelease(level: 54, version: version)))
            }
            #expect(FileManager.default.fileExists(atPath: output.appendingPathComponent("execution.json").path) == admitted)
            #expect(FileManager.default.fileExists(atPath: output.appendingPathComponent("model-receipt-0.json").path) == admitted)
        }
    }

    @Test func exactMOSMatrixCeilingReachesNativePreparation() async throws {
        for dimension in [3, 4] {
            let root = try directory(); defer { cleanup(root) }
            let text = """
            Exact MOS rows
            .options tranmaxaccepted=100 tranmaxattempts=1000 tranmaxiterations=10000 tranmaxscalars=1000 tranmaxdimension=\(dimension) tranmaxwork=100000000 tranmaxbreakpoints=100
            .model n nmos level=1 vto=.5 kp=1m
            VD d 0 1
            VG g 0 1
            M1 d g 0 0 n l=1u w=2u
            .op
            .end
            """
            do {
                let (execution, receipts, _) = try await batch(text, in: root)
                #expect(dimension == 4)
                #expect(receipts.count == 1)
                #expect(abs(try #require(execution.observedMetrics["op:last:I(vd)"]) + 0.00025031240346563) < 1e-12)
            } catch {
                guard dimension == 3 else { throw error }
                #expect(CoreSpiceCLIFailure(error: error).code == "preparation.capacity")
                #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("case/execution.json").path))
            }
        }
    }

    @Test(arguments: ["coreStrictV1", "pinnedNgspiceNormalV1"])
    func malformedMOSModelNeverPublishesCompletedCase(profile: String) async throws {
        for field in ["vto", "level", "version", "unknown", "0.5", "=0.5"] {
            let root = try directory(); defer { cleanup(root) }
            let source = root.appendingPathComponent("deck.cir")
            try "Invalid model\n.model n nmos kp=1m \(field)\nVD d 0 1\nVG g 0 1\nM1 d g 0 0 n l=1u w=2u\n.op\n.end\n"
                .write(to: source, atomically: true, encoding: .utf8)
            let output = root.appendingPathComponent("case")
            let args = ["-b", source.path, "--mos-profile", profile,
                "--case-output", output.path, "--case-id", "rejected-model", "--json"]
            var session = try Session(policy: .developerV1(profile: try #require(MOSInputProfile(rawValue: profile))))
            do {
                _ = try await CLI(arguments: args).executeBatch(options: .init(arguments: args), session: &session)
                Issue.record("Malformed MOS input published completed execution")
            } catch {
                #expect(!FileManager.default.fileExists(atPath: output.appendingPathComponent("execution.json").path))
                #expect(!FileManager.default.fileExists(atPath: output.appendingPathComponent("model-receipt-0.json").path))
            }
        }
    }

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
        var session = try Session(policy: .developerV1())
        let record = try await CLI(arguments: args).executeBatch(options: .init(arguments: args), session: &session)
        let execution = try ToolQualificationCaseExecution.decodeCanonical(from: Data(contentsOf: output.appendingPathComponent("execution.json")))
        let receipts = try FileManager.default.contentsOfDirectory(at: output, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("model-receipt-") }.map {
                try ToolQualificationModelExecutionReceipt.decodeCanonical(from: Data(contentsOf: $0))
            }
        #expect(record.outputArtifacts.count == receipts.count + 1)
        #expect(record.schemaVersion == .v2)
        let persisted = try JSONDecoder().decode(CoreSpiceCLIBatchRunRecord.self, from: JSONEncoder().encode(record))
        #expect(persisted.bsim45Models == record.bsim45Models)
        #expect(persisted.bsim45Models.map(\.device) == session.completedBSIM45Models.map(\.device))
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


    @Test func exact45PreparationFailureKeepsOriginalDiagnosticAndSource() async throws {
        let root = try directory(); defer { cleanup(root) }
        do {
            _ = try await batch("""
            Invalid oxide
            .options bsim4stressiterations=8
            .model n nmos level=54 version=4.5.0 toxe=-1
            VD d 0 1
            VG g 0 1
            M7 d g 0 0 n l=1u w=10u
            .op
            .end
            """, in: root)
            Issue.record("Failed physical preparation published execution")
        } catch SPICENativePreparationError.mosPreparation(.kernelRejected(let diagnostic)) {
            #expect(diagnostic.contains("m7") && diagnostic.contains("Toxe") && diagnostic.contains("deck.cir"))
        }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("case/execution.json").path))
    }

    @Test func exact45CLICompletesDCACTransientAndNoiseWithExecutionEvidence() async throws {
        for (analysis, command) in [("dc", ".dc VG 1 1.2 .1"), ("ac", ".ac lin 3 1k 10k"),
            ("tran", ".tran 10p 100p"), ("noise", ".noise V(d) VG lin 3 1k 10k")] {
            let root = try directory(); defer { cleanup(root) }
            let (execution, receipts, session) = try await batch("""
            Exact 4.5 CLI phase
            .options bsim4stressiterations=8
            .model n nmos level=54 version=4.5 toxe=10n vth0=.7 u0=.05 tnoimod=1 fnoimod=0 kf=1e-25
            VD supply 0 2
            RL supply d 1k
            VG g 0 \(analysis == "tran" ? "sin(1.2 .01 10Meg)" : "1.2") ac 1
            M1 d g 0 0 n l=1u w=10u nf=2 m=3 trnqsmod=1
            \(command)
            .end
            """, in: root)
            let phases = try #require(session.phaseCollector).phases
            #expect(!phases.isEmpty && phases.allSatisfy { $0.facts.analysis == analysis && $0.facts.completedPointCount > 0 })
            #expect(Set(execution.phaseIDs) == Set(phases.map(\.id)))
            #expect(receipts.allSatisfy { $0.modelVersion == "4.5.0" && $0.selectedModelIdentifier == "n" })
            #expect(receipts.count == phases.count)
            #expect(session.completedBSIM45Models.count == phases.count)
            for phase in phases {
                let receipt = try #require(phase.facts.mosPreparationReceipts.first)
                #expect(receipt.identity.resolved.release == .bsim4_4_5 && receipt.coldSetupCount == 1)
                #expect(receipt.identity.conditions.analysisCapabilities.contains(analysis == "noise" ? .noise : analysis == "ac" ? .ac : analysis == "tran" ? .transient : .dc))
            }
        }
    }

    @Test func sourceWidthFlagChangesExecutedModelReceiptAndCurrent() async throws {
        var currents: [Double] = []
        for flag in [0, 1] {
            let root = try directory(); defer { cleanup(root) }
            let source = """
            Actual MOS width selection
            .options bsim4stressiterations=128 wnflag=\(flag)
            .model n.1 nmos level=54 version=4.8.3 toxe=1e-8 vth0=.4 u0=.05 lmin=.1u lmax=2u wmin=.1u wmax=1.5u
            .model n.2 nmos level=54 version=4.8.3 toxe=1e-8 vth0=.8 u0=.05 lmin=.1u lmax=2u wmin=2u wmax=5u
            VD d 0 1
            VG g 0 1
            M1 d g 0 0 n l=1u w=4u nf=4
            .op
            .end
            """
            let (execution, receipts, _) = try await batch(source, in: root)
            let receipt = try #require(receipts.first)
            #expect(receipts.count == 1 && receipt.selectedModelIdentifier == (flag == 1 ? "n.1" : "n.2"))
            #expect(receipt.consumedInstances["m1"]?["w"] == 4e-6)
            #expect(receipt.consumedInstances["m1"]?["nf"] == 4)
            currents.append(abs(try #require(execution.observedMetrics["op:last:I(vd)"])))
        }
        #expect(currents[1] > currents[0] * 2)
    }

    @Test func nonScalarMOSCoefficientNeverReachesExecution() async throws {
        var session = try Session(policy: .developerV1())
        do {
            try await session.loadNetlist(source: """
            Invalid MOS coefficient
            VD d 0 1
            VG g 0 1
            M1 d g 0 0 n l=1u w=1u
            .model n nmos level=1 kp="bad"
            .op
            .end
            """, fileName: "invalid-model.cir")
            Issue.record("Invalid coefficient reached numerical preparation")
        } catch {
            #expect(CoreSpiceCLIFailure(error: error).code == "mos.resolution")
        }
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

    @Test func dcSourceUpdatesAndAggregateMeasurementsHaveActualContributors() async throws {
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
            guard case .real(let value) = source.parameters["v"] else { Issue.record("Missing actual source value"); continue }
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

    @Test func mosSweepKeepsOnePreparationPerSeedAndPublishesFinalSourceValues() async throws {
        let root = try directory(); defer { cleanup(root) }
        let (execution, receipts, session) = try await batch("""
        Actual MOS final values
        .param length=agauss(1u,0.1u,1)
        .model process nmos level=1 vto=.5 kp=1m
        VD d 0 1
        VG g 0 .7
        M1 d g 0 0 process l={length} w=2u
        .mc 2 dc VG .7 1 .3
        .end
        """, in: root, extra: ["--seed", "42"])
        #expect(execution.phaseIDs.count == 4)
        #expect(receipts.count == 4)
        let phases = try #require(session.phaseCollector).phases
        #expect(phases.allSatisfy { $0.facts.mosPreparationReceipts.count == 1 })
        let selected = try phases.map { try #require($0.facts.mosPreparationReceipts.first) }
        #expect(selected.allSatisfy { $0.coldSetupCount == 1 })
        #expect(selected[0].identity == selected[1].identity)
        #expect(selected[2].identity == selected[3].identity)
        #expect(selected[0].identity != selected[2].identity)
        for (index, phase) in phases.enumerated() {
            #expect(phase.facts.sourceName?.lowercased() == "vg")
            #expect(abs(try #require(phase.facts.sourceValue) - (index % 2 == 0 ? 0.7 : 1)) < 1e-12)
            let receipt = try #require(receipts.first { $0.phaseID == phase.id })
            #expect(receipt.selectedModelIdentifier == "process")
            #expect(receipt.sourceArtifact == execution.inputArtifacts.first)
            #expect(receipt.consumedInstances["m1"]?["l"] == selected[index].identity.resolved.normalizedGeometry.length)
        }
    }

    @Test func capturesArePublishedAfterOriginalPathsDisappear() async throws {
        let root = try directory(); defer { cleanup(root) }
        let file = root.appendingPathComponent("deck.cir")
        let text = "Captured input\n.model rm r rsh=100\nV1 in 0 1\nR1 in 0 rm l=1u w=1u\n.op\n.end\n"
        try text.write(to: file, atomically: true, encoding: .utf8)
        let loaded = try await SPICEDeckLoader.loadFile(at: file.path)
        try FileManager.default.removeItem(at: file)
        var session = try Session(policy: .developerV1()); try session.loadNetlist(loaded)
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
        var session = try Session(policy: .developerV1()); try session.loadNetlist(loaded)
        session.phaseCollector = try CoreSpiceCLIPhaseCollector()
        await #expect(throws: SPICENativeExecutionError.self) { _ = try await session.runParsed(try session.requiredDefaultRunnableAnalysis()) }
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
        var session = try Session(policy: .developerV1()); try session.loadNetlist(untracked)
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
        let policy = try CoreSpiceCLIExecutionPolicy.developerV1()
        let owner = try NativeCircuitPreparer().prepare(ir: netlist.build(), registry: .standard(),
            operatingConditions: .nominal, limits: .init(maximumDeviceCount: 16,
                maximumMatrixDimension: 256, maximumAllocationBytes: policy.maximumAllocationBytes),
            numericalLimits: policy.numericalLimits, resources: policy.resources())
        let plan = owner.plan
        let run = try await DCAnalysis().run(circuit: owner, solver: SparseLUSolver(),
            observer: nil, cancellation: CancellationToken())
        let compiled = try NetlistLowering.compile(loaded.netlist, limits: policy.resolutionLimits)
        let collector = try CoreSpiceCLIPhaseCollector()
        try collector.record(id: "op", facts: #require(run.phases.first), compiled: compiled,
            waveform: .from(dcResult: run.result, topology: plan.topology.circuitTopology))
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
        var session = try Session(policy: .developerV1()); try session.loadNetlist(loaded)
        let collector = try CoreSpiceCLIPhaseCollector()
        session.phaseCollector = collector
        let cancellation = CancellationToken()
        cancellation.cancel()
        await #expect(throws: MOSResolutionFailure.self) { _ = try await session.run(.op, cancellation: cancellation) }
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
        var phaseLimitedSession = try Session(policy: .developerV1()); try phaseLimitedSession.loadNetlist(loaded)
        phaseLimitedSession.phaseCollector = try CoreSpiceCLIPhaseCollector(maximumRetainedBytes: 16 * 1024,
            maximumEncodedBytes: 256)
        do {
            _ = try await phaseLimitedSession.runParsed(try phaseLimitedSession.requiredDefaultRunnableAnalysis())
            Issue.record("Phase evidence exceeded its encoded budget")
        } catch {
            #expect(CoreSpiceCLIFailure(error: error).code == "case.incomplete-output")
        }
        let phaseLimitedCollector = try #require(phaseLimitedSession.phaseCollector)
        #expect(phaseLimitedCollector.phases.isEmpty)
        #expect(!phaseLimitedCollector.isComplete)
        var session = try Session(policy: .developerV1()); try session.loadNetlist(loaded)
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
        var ordinary = try Session(policy: .developerV1()); try await ordinary.loadNetlist(source: text, fileName: nil)
        _ = try await ordinary.runParsed(try ordinary.requiredDefaultRunnableAnalysis())
        #expect(ordinary.lastMeasurements.count == 2)
        await #expect(throws: CoreSpiceCLICaseError.self) { _ = try await batch(text, in: root) }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("case").path))
    }

    @Test func cancellationDuringStagedPublicationRefusesFinalDirectory() async throws {
        let root = try directory(); defer { cleanup(root) }
        let loaded = try await SPICEDeckLoader.load(source: "Cancellation during publication\nV1 in 0 1\nR1 in 0 1k\n.op\n.end\n")
        var session = try Session(policy: .developerV1()); try session.loadNetlist(loaded)
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

    @Test func unusedUnsupportedSourceNeverCreatesExecutedModelReceipts() async throws {
        let root = try directory(); defer { cleanup(root) }
        let (execution, receipts, session) = try await batch("""
        Ideal execution with retained unsupported source
        .param cv=1n
        V1 out 0 1
        R1 out 0 1k
        C1 out 0 c=cv*2
        .model unused C cox={missing}
        .subckt unselected a
        .param impossible=missing
        Cq a 0 q={missing*v(a)}
        .ends
        .op
        .end
        """, in: root)
        #expect(execution.phaseIDs == ["op"])
        #expect(receipts.isEmpty)
        #expect(abs(try #require(execution.observedMetrics["op:last:V(out)"]) - 1) < 1e-9)
        #expect(session.plan?.ir.instances.count == 3)
    }

    @Test func selectedChargeAndPhysicalCapacitorPublishNoCompletedCase() async throws {
        for component in ["Cq out 0 q={missing*v(out)}", "C1 out 0 cm\n.model cm C cap=1n"] {
            let root = try directory(); defer { cleanup(root) }
            do {
                _ = try await batch("unsupported selected capacitor\nV1 out 0 1\nR1 out 0 1k\n\(component)\n.op\n.end\n", in: root)
                Issue.record("Unsupported capacitor published success")
            } catch {
                let failure = CoreSpiceCLIFailure(error: error)
                #expect(failure.code == "deck.lower")
                #expect(failure.stage == "lower")
            }
            #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("case").path))
        }
    }

}
