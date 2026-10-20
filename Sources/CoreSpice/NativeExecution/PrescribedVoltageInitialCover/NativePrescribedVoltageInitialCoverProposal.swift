import CoreSpiceDevices

/// Finite untrusted proof topology and existing actual-owner witness references.
package struct NativePrescribedVoltageInitialCoverProposal: Sendable {
    package enum Node: Sendable {
        case split(axis: Int, at: CompensatedValue, left: Int, right: Int)
        case excluded(values: NativePrescribedVoltageValues, component: Int)
        case included(NativePrescribedVoltageInitialRoot)
        case unresolved
    }
    package let nodes: [Node]
    package init(nodes: [Node]) { self.nodes = nodes }
}
