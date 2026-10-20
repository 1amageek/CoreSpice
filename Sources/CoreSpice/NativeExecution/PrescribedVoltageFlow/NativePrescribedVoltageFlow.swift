import CoreSpiceAnalysis
import CoreSpiceDevices
import CoreSpiceEvent
import CoreSpiceOSDI
import CoreSpiceParsedIR
import OSDIContracts

/// A finite conditional numerical flow; no common-family, initial-cover or history authority.
public final class NativePrescribedVoltageFlow: Sendable {
    private let payload: Payload
    private init(_ payload: Payload) { self.payload = payload }
    public var dimension: Int { payload.preparation.plan.topology.dimension }
    public var chargeCoordinateCount: Int { payload.initialRoot.chargeCoordinateCount }
    public var selectedSourceCount: Int { payload.sources.count }
    public var duration: CompensatedValue { payload.request.duration }
    public var contractionUpperBound: Double { payload.picard.contractionUpperBound }
    public func endpointCharge(at index: Int) throws(NativePrescribedVoltageFlowFailure) -> CompensatedEnclosure {
        guard (0..<chargeCoordinateCount).contains(index) else { throw .invalidInput }
        do { return try payload.picard.endpoint(at: index) } catch { throw .phase(.picard, cause: error) }
    }
    /// Window enclosure; selected-current coordinates are qualified almost everywhere.
    public func coordinate(at row: Int) throws(NativePrescribedVoltageFlowFailure) -> CompensatedEnclosure {
        guard (0..<dimension).contains(row) else { throw .invalidInput }
        do { return try payload.evolution.coordinate(at: row, side: .left) } catch { throw .phase(.evolution, cause: error) }
    }
    public func chargeRateAlmostEverywhere(at index: Int) throws(NativePrescribedVoltageFlowFailure) -> CompensatedEnclosure {
        guard (0..<chargeCoordinateCount).contains(index) else { throw .invalidInput }
        do { return try payload.evolution.chargeRate(at: index) } catch { throw .phase(.evolution, cause: error) }
    }
    public func selectedCurrentAlmostEverywhere(at index: Int) throws(NativePrescribedVoltageFlowFailure) -> CompensatedEnclosure {
        guard (0..<selectedSourceCount).contains(index) else { throw .invalidInput }
        do { return try payload.evolution.selectedCurrent(at: index, side: .left) } catch { throw .phase(.evolution, cause: error) }
    }
    public func observeVoltages(pairs: borrowing Span<NativePrescribedVoltageFlowVoltagePair>,
        limits: NativePrescribedVoltageFlowObservationLimits, cancellation: CancellationToken)
        throws(NativePrescribedVoltageFlowObservationFailure) -> NativePrescribedVoltageFlowVoltageObservations {
        try NativePrescribedVoltageFlowVoltageObservations.observe(flow: self, payload: payload,
            pairs: pairs, limits: limits, cancellation: cancellation)
    }
    public func withScope<Result>(_ body: (borrowing NativePrescribedVoltageFlowScopeView) throws -> Result) rethrows -> Result {
        let owner = payload
        defer { withExtendedLifetime(owner) {} }
        let view = NativePrescribedVoltageFlowScopeView(payload: owner)
        return try body(view)
    }
    // Compose only matched actual owners; the result retains its conditional source assumptions.
    internal static func certify(record: NativeCircuitPreparationRecord, devices: [any BoundDevice],
        request: NativePrescribedVoltageFlowRequest, capture: OSDIConstitutiveCaptureInputs?,
        range: OSDISmoothRangeCaptureInputs?, limits: NativePrescribedVoltageFlowLimits,
        cancellation: CancellationToken) async throws(NativePrescribedVoltageFlowFailure) -> NativePrescribedVoltageFlow {
        Self(try await NativePrescribedVoltageFlowAssembly.certify(record: record, devices: devices,
            request: request, capture: capture, range: range, limits: limits, cancellation: cancellation))
    }
    internal struct Payload: Sendable {
        let preparation: NativeCircuitPreparationRecord
        let request: NativePrescribedVoltageFlowRequest
        let sources: [NativePrescribedVoltageFlowSourceScope]
        let models: [NativePrescribedVoltageFlowModelScope]
        let initialContext: OSDIPrecisionContext
        let windowLowerContext: OSDIPrecisionContext
        let windowUpperContext: OSDIPrecisionContext
        let initialRoot: NativePrescribedVoltageInitialRoot
        let initial: NativePrescribedVoltageInitialRoot.Payload
        let chart: NativePrescribedVoltageChart
        let window: NativePrescribedVoltageChart.Payload
        let evolution: NativePrescribedVoltageEvolution
        let picard: ValidatedPicardSlab.Result
        let chargeLower: [CompensatedValue]
        let chargeUpper: [CompensatedValue]
        let lease: SPICESourceStorageReservation
    }
}
