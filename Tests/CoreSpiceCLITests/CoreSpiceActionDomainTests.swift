import Testing
import CoreSpice
@testable import CoreSpiceCLICore

@Suite("CoreSpice action-domain")
struct CoreSpiceActionDomainTests {

    @Test
    func exporterDeclaresSimulationPlanningOperations() throws {
        let snapshot = CoreSpiceActionDomainExporter().snapshot()

        #expect(snapshot.schemaVersion == 1)
        #expect(snapshot.domainID == "simulation-analysis")
        #expect(snapshot.ownerPackages == ["CoreSpice"])

        let operationIDs = Set(snapshot.operations.map(\.operationID))
        #expect(operationIDs.contains("simulation.import-spice"))
        #expect(operationIDs.contains("simulation.load-netlist"))
        #expect(operationIDs.contains("simulation.run-analysis"))
        #expect(operationIDs.contains("simulation.run-op"))
        #expect(operationIDs.contains("simulation.run-tran"))
        #expect(operationIDs.contains("simulation.run-ac"))
        #expect(operationIDs.contains("simulation.run-dc"))
        #expect(operationIDs.contains("simulation.run-monte-carlo"))
        #expect(operationIDs.contains("simulation.export-waveform"))
        #expect(operationIDs.contains("simulation.export-metric-report"))
        #expect(operationIDs.contains("simulation.summarize-run"))
        #expect(operationIDs.contains("simulation.export-deck-coverage"))
        #expect(operationIDs.contains("simulation.set-netlist-parameters"))
        #expect(operationIDs.contains("simulation.metric-improvement-objective"))
        #expect(operationIDs.contains("simulation.convergence-recovery-objective"))

        let importSPICE = try #require(snapshot.operations.first { $0.operationID == "simulation.import-spice" })
        #expect(importSPICE.maturity == "implemented")
        #expect(importSPICE.producedArtifacts.contains("simulation-netlist"))
        #expect(importSPICE.verificationGates.contains("parser-diagnostics"))

        let loadNetlist = try #require(snapshot.operations.first { $0.operationID == "simulation.load-netlist" })
        #expect(loadNetlist.producedArtifacts.contains("coverage-report"))
        #expect(loadNetlist.verificationGates.contains("artifact-integrity"))

        let runAnalysis = try #require(snapshot.operations.first { $0.operationID == "simulation.run-analysis" })
        #expect(runAnalysis.maturity == "implemented")
        #expect(runAnalysis.producedArtifacts.contains("simulation-summary"))
        #expect(runAnalysis.verificationGates.contains("simulation-summary"))

        let transient = try #require(snapshot.operations.first { $0.operationID == "simulation.run-tran" })
        #expect(transient.maturity == "implemented")
        #expect(transient.preconditions.contains("positive-stop-time"))
        #expect(transient.verificationGates.contains("simulation-completed"))

        let metricReport = try #require(snapshot.operations.first { $0.operationID == "simulation.export-metric-report" })
        #expect(metricReport.maturity == "implemented")
        #expect(metricReport.producedArtifacts == ["simulation-metric-report"])
        #expect(metricReport.verificationGates.contains("simulation-metric-gate"))

        let summary = try #require(snapshot.operations.first { $0.operationID == "simulation.summarize-run" })
        #expect(summary.maturity == "implemented")
        #expect(summary.producedArtifacts == ["simulation-summary"])
        #expect(summary.verificationGates.contains("human-review"))

        let coverage = try #require(snapshot.operations.first { $0.operationID == "simulation.export-deck-coverage" })
        #expect(coverage.producedArtifacts == ["coverage-report"])
        #expect(coverage.verificationGates.contains("schema-validation"))
        #expect(coverage.verificationGates.contains("artifact-integrity"))

        let objective = try #require(snapshot.operations.first { $0.operationID == "simulation.metric-improvement-objective" })
        #expect(objective.maturity == "implemented")
        #expect(objective.producedArtifacts.contains("planning-problem"))
        #expect(objective.producedArtifacts.contains("metric-improvement-planning-problem"))
        #expect(objective.verificationGates.contains("simulation-metric-gate"))
        #expect(objective.verificationGates.contains("artifact-integrity"))

        let edit = try #require(snapshot.operations.first { $0.operationID == "simulation.set-netlist-parameters" })
        #expect(edit.maturity == "implemented")
        #expect(edit.producedArtifacts.contains("spice-netlist"))
        #expect(edit.verificationGates.contains("simulation-metric-gate"))

        let convergence = try #require(snapshot.operations.first {
            $0.operationID == "simulation.convergence-recovery-objective"
        })
        #expect(convergence.maturity == "implemented")
        #expect(convergence.producedArtifacts.contains("convergence-recovery-planning-problem"))
        #expect(convergence.verificationGates.contains("simulation-completed"))
        #expect(convergence.verificationGates.contains("artifact-integrity"))
    }

    @Test
    func actionDomainSnapshotPinsEveryOperationContract() throws {
        let snapshot = CoreSpiceActionDomainExporter().snapshot()
        let operationIDs = snapshot.operations.map(\.operationID)

        #expect(operationIDs.count == Set(operationIDs).count)
        #expect(Set(operationIDs) == Set([
            "simulation.import-spice",
            "simulation.load-netlist",
            "simulation.run-analysis",
            "simulation.run-op",
            "simulation.run-tran",
            "simulation.run-ac",
            "simulation.run-dc",
            "simulation.run-monte-carlo",
            "simulation.export-waveform",
            "simulation.export-metric-report",
            "simulation.summarize-run",
            "simulation.export-deck-coverage",
            "simulation.set-netlist-parameters",
            "simulation.metric-improvement-objective",
            "simulation.convergence-recovery-objective",
        ]))

        for operation in snapshot.operations {
            #expect(!operation.maturity.isEmpty, "\(operation.operationID) must expose maturity")
            #expect(["implemented", "planned"].contains(operation.maturity))
            #expect(!operation.inputRefs.isEmpty, "\(operation.operationID) must expose input references")
            #expect(!operation.preconditions.isEmpty, "\(operation.operationID) must expose preconditions")
            #expect(!operation.effects.isEmpty, "\(operation.operationID) must expose effects")
            #expect(!operation.producedArtifacts.isEmpty, "\(operation.operationID) must expose produced artifacts")
            #expect(!operation.verificationGates.isEmpty, "\(operation.operationID) must expose verification gates")
            #expect(operation.inputRefs.count == Set(operation.inputRefs).count)
            #expect(operation.preconditions.count == Set(operation.preconditions).count)
            #expect(operation.effects.count == Set(operation.effects).count)
            #expect(operation.producedArtifacts.count == Set(operation.producedArtifacts).count)
            #expect(operation.verificationGates.count == Set(operation.verificationGates).count)
            #expect(
                operation.verificationGates.contains("artifact-integrity"),
                "\(operation.operationID) produces artifacts and must expose artifact-integrity"
            )
        }

        let implemented = snapshot.operations.filter { $0.maturity == "implemented" }
        #expect(implemented.count == 15)
        for operation in implemented {
            let gates = Set(operation.verificationGates)
            #expect(
                !gates.intersection([
                    "artifact-integrity",
                    "schema-validation",
                    "simulation-completed",
                    "simulation-summary",
                    "simulation-metric-gate",
                ]).isEmpty,
                "\(operation.operationID) must expose a machine-checkable gate"
            )
        }
    }

    @Test
    func commandParsesJSONFlag() throws {
        let command = try CoreSpiceActionDomainCommand(arguments: ["--json"])

        #expect(command.jsonOutput)
    }

    @Test
    func commandRejectsUnknownArgument() throws {
        #expect(throws: CLIError.self) {
            _ = try CoreSpiceActionDomainCommand(arguments: ["--unknown"])
        }
    }
}
