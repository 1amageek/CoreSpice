@testable import CoreSpiceIO
import Testing

@Suite("Frontend source-accounting bridge", .timeLimit(.minutes(1)))
struct SPICEFrontendControlTests {
    private final class Marker: Error, Sendable {}
    private struct FailingResources: SPICESourceResourceAccounting {
        let marker: Marker
        let cancelled: Bool
        func checkCancellation() throws { if cancelled { throw marker } }
        func charge(_ kind: SPICESourceWorkKind, units: UInt64) throws { throw marker }
        func chargeHashedBytes(_ byteCount: UInt64) throws { throw marker }
        func reserveStorage(kind: SPICESourceStorageKind, byteCount: UInt64) throws -> SPICESourceStorageReservation { throw marker }
    }
    @Test(arguments: [false, true])
    func actualFrontendFailureRetainsExactInjectedCause(cancelled: Bool) throws {
        let marker = Marker()
        let control = SPICEFrontendControl(resources: FailingResources(marker: marker, cancelled: cancelled))
        do {
            _ = try NetlistLowering.compile(.init(parameters: ["value": .literal(1)]),
                limits: IOTestFrontend.limits, control: control)
            Issue.record("Compilation ignored source-accounting refusal")
        } catch let error as MOSResolutionFailure {
            #expect(error == (cancelled ? .cancelled : .invalidRequest))
        }
        #expect((control.firstFailure as? Marker) === marker)
    }
}
