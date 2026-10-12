import CoreSpiceDiodeContracts
@testable import CoreSpice
import CoreSpiceIO
import CoreSpiceLowering
import Testing

extension PreparedNativeExecutionTests {
    @Test func resolvedDiodeRefusesNativeBeforeAllocation() async throws {
        let resources = SourceBoundaryTestResources()
        let retained = try await input("D3\n.temp 42\n.model dm D(m=.4)\nV1 a 0 1\nD1 a 0 dm area=3 m=2\n.op\n.end\n",
                                       resources: resources, diodeProfile: .coreDiodeV1)
        let baseline = resources.used(.liveOwnedBytes)
        #expect(retained.circuit.instances.first { $0.name == "d1" }?.diode?.resolved.input.multiplicity.value == 2)
        do {
            _ = try SPICENativeSimulation().prepare(retained,
                limits: .init(maximumDeviceCount: 100, maximumMatrixDimension: 32, maximumAllocationBytes: 16_000_000))
            Issue.record("Numerically prepared unresolved diode")
        } catch let failure as SPICENativePreparationError {
            guard case .unsupportedCapability(let detail) = failure else { Issue.record("Wrong refusal"); return }
            #expect(detail == "Resolved diode numerical preparation requires D4")
        }
        #expect(resources.used(.liveOwnedBytes) == baseline)
    }
    @Test func diodeDiagnosticRetainsAndReleasesFrontendAccounting() async throws {
        let resources = SourceBoundaryTestResources()
        try await inspectDiagnostic(resources)
        #expect(resources.used(.liveOwnedBytes) == 0)
        #expect(resources.used(.temporaryBytes) == 0)
    }
    private func inspectDiagnostic(_ resources: SourceBoundaryTestResources) async throws {
        var retainedError: SPICESimulationPreparationError?
        do { _ = try await input("D3\n.model dm D(js=0)\nD1 a 0 dm\n.op\n.end\n", resources: resources, diodeProfile: .coreDiodeV1) }
        catch let failure as SPICESimulationPreparationError { retainedError = failure }
        guard case .diodeResolution(let diagnostic, _, let reservation) = retainedError else {
            Issue.record("Lost structured diagnostic and owner"); return
        }
        #expect(diagnostic.cause == .schema(.unsupportedParameter(name: "js", role: .model)))
        #expect(diagnostic.assignment?.location?.line == 2)
        let held = try #require(reservation)
        #expect(resources.used(.liveOwnedBytes) >= held.byteCount)
        withExtendedLifetime(retainedError) { }
    }
}
