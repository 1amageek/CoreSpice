/// Explicit source-to-foreign preparation; callbacks are valid only during this call.
public protocol ExternalMOSPreparing: Sendable {
    var identity: String { get }
    func prepare(_ source: ExternalMOSSourceRequest,
                 evaluate: (ExternalMOSScalarAddress) throws -> Double,
                 chargeWork: () throws -> Void) throws -> ExternalMOSPreparation
}
