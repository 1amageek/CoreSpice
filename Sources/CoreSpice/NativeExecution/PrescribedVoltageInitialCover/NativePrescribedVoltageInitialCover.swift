import CoreSpiceDevices
import CoreSpiceEvent

/// All roots covered only within the retained explicit finite domain and source assumptions.
package final class NativePrescribedVoltageInitialCover: Sendable {
    package enum Classification: Sendable, Equatable { case excluded, included, unresolved }
    package struct Leaf: Sendable {
        package let nodeIndex: Int
        package let classification: Classification
        package let excludedComponent: Int?
        package let residual: CompensatedEnclosure?
    }
    package let dimension: Int
    package let sourceCount: Int
    package let includedLeafCount: Int
    package let excludedLeafCount: Int
    package let unresolvedLeafCount: Int
    package var isComplete: Bool { unresolvedLeafCount == 0 }
    package var isProvedEmpty: Bool { isComplete && includedLeafCount == 0 }
    package var leafCount: Int { leaves.count }
    private let structure: NativePrescribedVoltageInitialStructure
    private let lower: [CompensatedValue]
    private let upper: [CompensatedValue]
    private let initialNormalized: [ClosedRange<Double>]
    private let nodes: [NativePrescribedVoltageInitialCoverProposal.Node]
    private let leaves: [Leaf]
    private let lease: any Sendable
    internal struct Payload: Sendable {
        let structure: NativePrescribedVoltageInitialStructure
        let lower: [CompensatedValue]
        let upper: [CompensatedValue]
        let initialNormalized: [ClosedRange<Double>]
        let nodes: [NativePrescribedVoltageInitialCoverProposal.Node]
        let leaves: [Leaf]
        let included: Int
        let excluded: Int
        let unresolved: Int
        let lease: any Sendable
    }
    private init(_ p: Payload) {
        structure = p.structure; lower = p.lower; upper = p.upper
        initialNormalized = p.initialNormalized; nodes = p.nodes; leaves = p.leaves
        dimension = p.lower.count; sourceCount = p.initialNormalized.count
        includedLeafCount = p.included; excludedLeafCount = p.excluded; unresolvedLeafCount = p.unresolved
        lease = p.lease
    }
    internal static func check(record: NativeCircuitPreparationRecord, structure: NativePrescribedVoltageInitialStructure,
        lower: [CompensatedValue], upper: [CompensatedValue], initialNormalized: [ClosedRange<Double>],
        proposal: NativePrescribedVoltageInitialCoverProposal, limits: NativePrescribedVoltageInitialCoverLimits,
        cancellation: CancellationToken) throws -> NativePrescribedVoltageInitialCover {
        Self(try NativePrescribedVoltageInitialCoverAssembly.check(record: record, structure: structure,
            lower: lower, upper: upper, initialNormalized: initialNormalized, proposal: proposal,
            limits: limits, cancellation: cancellation))
    }
    package func leaf(at index: Int) throws -> Leaf {
        guard leaves.indices.contains(index) else { throw NativePrescribedVoltageInitialCoverFailure.invalidInput }
        return leaves[index]
    }
    package func coordinateLower(at index: Int) throws -> CompensatedValue {
        guard lower.indices.contains(index) else { throw NativePrescribedVoltageInitialCoverFailure.invalidInput }
        return lower[index]
    }
    package func coordinateUpper(at index: Int) throws -> CompensatedValue {
        guard upper.indices.contains(index) else { throw NativePrescribedVoltageInitialCoverFailure.invalidInput }
        return upper[index]
    }
    package func sourceRange(at index: Int) throws -> ClosedRange<Double> {
        guard initialNormalized.indices.contains(index) else { throw NativePrescribedVoltageInitialCoverFailure.invalidInput }
        return initialNormalized[index]
    }
}

extension PreparedNativeCircuit {
    // Finite initial-cover verification is qualified on the pinned actual-source,
    // missing-branch/boundary and resource/lifetime fixtures. The supplied finite
    // target remains conditional; global initial-set inclusion is not established.
    package borrowing func checkPrescribedVoltageInitialCover(structure: NativePrescribedVoltageInitialStructure,
        originalLower: [CompensatedValue], originalUpper: [CompensatedValue],
        initialNormalized: [ClosedRange<Double>], proposal: NativePrescribedVoltageInitialCoverProposal,
        limits: NativePrescribedVoltageInitialCoverLimits, cancellation: CancellationToken)
        throws -> NativePrescribedVoltageInitialCover {
        try NativePrescribedVoltageInitialCover.check(record: record, structure: structure,
            lower: originalLower, upper: originalUpper, initialNormalized: initialNormalized,
            proposal: proposal, limits: limits, cancellation: cancellation)
    }
}
