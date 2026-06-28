import Testing
import CoreSpice
@testable import CoreSpiceCLI

@Suite("CoreSpice action-domain")
struct CoreSpiceActionDomainTests {

    @Test
    func exporterDeclaresSimulationPlanningOperations() throws {
        let snapshot = CoreSpiceActionDomainExporter().snapshot()

        #expect(snapshot.schemaVersion == 1)
        #expect(snapshot.domainID == "simulation-analysis")
        #expect(snapshot.ownerPackages == ["CoreSpice"])

        let operationIDs = Set(snapshot.operations.map(\.operationID))
        #expect(operationIDs.contains("simulation.load-netlist"))
        #expect(operationIDs.contains("simulation.run-op"))
        #expect(operationIDs.contains("simulation.run-tran"))
        #expect(operationIDs.contains("simulation.run-ac"))
        #expect(operationIDs.contains("simulation.run-dc"))
        #expect(operationIDs.contains("simulation.run-monte-carlo"))
        #expect(operationIDs.contains("simulation.export-waveform"))
        #expect(operationIDs.contains("simulation.export-deck-coverage"))
        #expect(operationIDs.contains("simulation.set-netlist-parameters"))
        #expect(operationIDs.contains("simulation.metric-improvement-objective"))
        #expect(operationIDs.contains("simulation.convergence-recovery-objective"))

        let transient = try #require(snapshot.operations.first { $0.operationID == "simulation.run-tran" })
        #expect(transient.maturity == "implemented")
        #expect(transient.preconditions.contains("positive-stop-time"))
        #expect(transient.verificationGates.contains("simulation-completed"))

        let objective = try #require(snapshot.operations.first { $0.operationID == "simulation.metric-improvement-objective" })
        #expect(objective.maturity == "planned")
        #expect(objective.producedArtifacts.contains("planning-problem"))
        #expect(objective.verificationGates.contains("simulation-metric-gate"))

        let edit = try #require(snapshot.operations.first { $0.operationID == "simulation.set-netlist-parameters" })
        #expect(edit.maturity == "implemented")
        #expect(edit.producedArtifacts.contains("spice-netlist"))
        #expect(edit.verificationGates.contains("simulation-metric-gate"))
    }

    @Test
    func commandParsesJSONFlag() throws {
        let command = try CoreSpiceActionDomainCommand(arguments: ["--json"])

        #expect(command.jsonOutput)
    }
}
