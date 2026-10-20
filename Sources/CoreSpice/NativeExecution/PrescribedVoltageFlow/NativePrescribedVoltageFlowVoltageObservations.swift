import CoreSpiceEvent
import CoreSpiceParsedIR

/// Same-flow electrical observations; the retained actual flow owns their conditional scope.
public final class NativePrescribedVoltageFlowVoltageObservations: Sendable {
    public let flow: NativePrescribedVoltageFlow
    private let storage: Storage
    private init(flow: NativePrescribedVoltageFlow, storage: Storage) { self.flow = flow; self.storage = storage }
    public var count: Int { storage.observations.count }
    public func observation(at index: Int)
        throws(NativePrescribedVoltageFlowObservationFailure) -> NativePrescribedVoltageFlowVoltageObservation {
        guard storage.observations.indices.contains(index) else { throw .invalidInput }
        return storage.observations[index]
    }
    public func withObservations<Result>(
        _ body: (borrowing Span<NativePrescribedVoltageFlowVoltageObservation>) throws -> Result
    ) rethrows -> Result {
        let owner = storage
        defer { withExtendedLifetime(owner) {} }
        let view = owner.observations.span
        return try body(view)
    }
    internal static func observe(flow: NativePrescribedVoltageFlow,
        payload: borrowing NativePrescribedVoltageFlow.Payload,
        pairs: borrowing Span<NativePrescribedVoltageFlowVoltagePair>,
        limits: NativePrescribedVoltageFlowObservationLimits, cancellation: CancellationToken)
        throws(NativePrescribedVoltageFlowObservationFailure) -> NativePrescribedVoltageFlowVoltageObservations {
        Self(flow: flow, storage: try NativePrescribedVoltageFlowObservationAssembly.observe(payload: payload,
            pairs: pairs, limits: limits, cancellation: cancellation))
    }
    internal struct Storage: Sendable {
        let observations: [NativePrescribedVoltageFlowVoltageObservation]
        let lease: SPICESourceStorageReservation
    }
}
