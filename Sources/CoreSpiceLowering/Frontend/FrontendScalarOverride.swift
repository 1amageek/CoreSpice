import CoreSpiceMOSContracts

/// Compiled constant programs retain their separate explicit source overlay.
struct FrontendScalarOverride: Sendable {
    let source: NetlistSourceScalarOverride
    let name: String
    let binding: MOSExpressionBinding
}
