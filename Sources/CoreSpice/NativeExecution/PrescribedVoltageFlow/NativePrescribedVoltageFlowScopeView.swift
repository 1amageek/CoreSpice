import CoreSpiceDevices
import OSDIContracts

/// A lexical borrow of the sealed result's actual assumptions and circuit/source identities.
public struct NativePrescribedVoltageFlowScopeView: ~Escapable {
    public let preparation: NativeCircuitPreparationRecord
    public let sources: Span<NativePrescribedVoltageFlowSourceScope>
    public let models: Span<NativePrescribedVoltageFlowModelScope>
    public let originalLower: Span<CompensatedValue>
    public let originalUpper: Span<CompensatedValue>
    public let startTime: CompensatedValue
    public let duration: CompensatedValue
    public let initialContext: OSDIPrecisionContext
    public let windowLowerContext: OSDIPrecisionContext
    public let windowUpperContext: OSDIPrecisionContext
    public let algebraicRows: Span<Int>
    public let chargeRows: Span<Int>
    public let dynamicInitialCoordinates: Span<CompensatedEnclosure>
    public let initialCharge: Span<CompensatedEnclosure>
    public let initialReducedLower: Span<CompensatedValue>
    public let initialReducedUpper: Span<CompensatedValue>
    public let windowReducedLower: Span<CompensatedValue>
    public let windowReducedUpper: Span<CompensatedValue>
    public let chargeLower: Span<CompensatedValue>
    public let chargeUpper: Span<CompensatedValue>
    @_lifetime(borrow payload)
    internal init(payload: borrowing NativePrescribedVoltageFlow.Payload) {
        preparation = payload.preparation; sources = payload.sources.span; models = payload.models.span
        originalLower = payload.request.originalLower.span; originalUpper = payload.request.originalUpper.span
        startTime = payload.request.startTime; duration = payload.request.duration
        initialContext = payload.initialContext; windowLowerContext = payload.windowLowerContext
        windowUpperContext = payload.windowUpperContext
        algebraicRows = payload.window.algebraic.span; chargeRows = payload.window.dynamic.span
        dynamicInitialCoordinates = payload.initial.dynamicInitialCoordinates.span; initialCharge = payload.initial.initialCharge.span
        initialReducedLower = payload.initial.checkedLower.span; initialReducedUpper = payload.initial.checkedUpper.span
        windowReducedLower = payload.window.checkedLower.span; windowReducedUpper = payload.window.checkedUpper.span
        chargeLower = payload.chargeLower.span; chargeUpper = payload.chargeUpper.span
    }
}
