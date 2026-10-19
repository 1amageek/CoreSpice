@testable import CoreSpice
@testable import CoreSpiceIO
import CoreSpiceOSDI
import CoreSpiceOSDIContracts
import CoreSpiceOSDITestSupport
import OSDIContracts
import Testing

@Suite("OSDI fresh source sensitivity", .timeLimit(.minutes(3)))
struct ReleaseOSDISourceReexecutionTests {
    @Test func suppliedModelAndInstanceScalarsUseFreshPhysicalOwnersAndExactChildJoin() async throws {
        let fixture = try OSDINativeFixture()
        defer { do { try fixture.close() } catch { Issue.record("Fixture cleanup failed: \(error)") } }
        let point = try #require(fixture.manifest.cases.first { $0.id == "bsim-p-selfheat-loaded" })
        let input = try await fixture.input(point, analysis: ".sens V(d)")
        let tracked = OSDINativeExecutionTests.TrackingProvider(base: fixture.provider)
        let prepared = try await SPICENativeSimulation().prepare(input, limits: fixture.limits,
            osdi: fixture.runtime(point, provider: tracked))
        let output = try await SPICENativeSimulation().execute(prepared, cancellation: .init())
        let result = try #require(output.sensitivityResult)
        let ledger = try #require(output.phases.compactMap(\.sourceReexecutionLedger).first)
        #expect(ledger.records.count == result.sensitivities.count)
        #expect(output.phases.map(\.analysis) == ["op", "sens"])
        #expect(output.phases[0].equationPolicy != nil)
        for device in point.input.devices {
            let name = OSDINativeFixture.sourceName(device.id)
            for parameter in device.parameters {
                let assignment = try parameter.assignment()
                guard case .real(let nominal) = assignment.value else { continue }
                let role = assignment.scope == .model ? "model." : "instance."
                let child = try #require(ledger.records.first { $0.deviceName == name && $0.parameterName == role + assignment.name })
                #expect(child.nominalValue == nominal)
                #expect(child.perturbedValue != nominal)
                #expect(child.completedPhase.analysis == "op")
                #expect(child.completedPhase.equationPolicy != nil)
                #expect(child.sourceInputIdentity == input.sourceInputIdentity)
                #expect(child.configurationIdentity != output.configurationIdentity)
                let resolved = try #require(child.preparation.osdiPreparationRecords.first { $0.instanceName == name }).receipt.resolved
                let actual = assignment.scope == .model ? resolved.binding.modelParameters : resolved.instanceParameters
                #expect(actual.contains { $0.name == assignment.name && $0.value == .real(child.perturbedValue) })
            }
        }
        try tracked.expectClosed()

        let selected = try #require(ledger.records.first { $0.parameterName == "instance.W" })
        let repeatedInput = try SPICESimulationPreparer().reprepare(input, osdiInstances: selected.osdiInstances)
        let owner = try await NativeCircuitPreparer().prepare(ir: repeatedInput.circuit, registry: .standard(),
            operatingConditions: repeatedInput.configuration.options.operatingConditions(), limits: fixture.limits,
            numericalLimits: repeatedInput.configuration.numericalLimits, resources: repeatedInput.resources,
            osdi: fixture.runtime(point))
        let node = try #require(owner.plan.ir.nodeNames.first { $0.value == "d" }?.key)
        var guesses: [Node: Double] = [:]
        for guess in repeatedInput.nodeSets.bindings { guesses[guess.node] = guess.voltage }
        let repeated = try await DCAnalysis(config: repeatedInput.configuration.options.convergence, nodeInitialGuess: guesses)
            .run(circuit: owner, solver: SparseLUSolver(), observer: nil, cancellation: .init())
        guard case .dc(let observed, _) = selected.observation else { Issue.record("Expected DC child observation"); return }
        #expect(try repeated.result.checkedCompensatedVoltage(at: node) == observed)
    }
}
