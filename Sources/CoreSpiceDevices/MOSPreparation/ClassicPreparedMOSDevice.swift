import CoreSpiceIR
import CoreSpiceMOSContracts

/// Admitted classic parameters without a second interpretation at binding.
public struct ClassicPreparedMOSDevice: ~Copyable, Sendable {
    package let identity: MOSPreparationIdentity
    private let parameters: MOSFETModelParameters

    package init(identity: MOSPreparationIdentity, parameters: MOSFETModelParameters) {
        self.identity = identity
        self.parameters = parameters
    }

    consuming func bind(instance: Instance, context: inout BindingContext, control: any MOSPreparationControlling) throws -> any BoundDevice {
        guard instance.nodes.count == 4, instance.ownedNodes.isEmpty else {
            throw MOSBindingFailure.topologyMismatch
        }
        let mapping = try MOSBindingMapping(instance: instance, context: context)
        try control.checkCancellation()
        let d = instance.nodes[0], g = instance.nodes[1], s = instance.nodes[2], b = instance.nodes[3]
        switch (identity.resolved.release, identity.resolved.polarity) {
        case (.level1, .nmos):
            return BoundNMOSL1(instance: instance, drain: d, gate: g, source: s, bulk: b,
                parameters: parameters, drainIdx: mapping.drain, gateIdx: mapping.gate,
                sourceIdx: mapping.source, bulkIdx: mapping.bulk, csrIndices: mapping.csr)
        case (.level1, .pmos):
            return BoundPMOSL1(instance: instance, drain: d, gate: g, source: s, bulk: b,
                parameters: parameters, drainIdx: mapping.drain, gateIdx: mapping.gate,
                sourceIdx: mapping.source, bulkIdx: mapping.bulk, csrIndices: mapping.csr)
        case (.level2, .nmos):
            return BoundNMOSL2(instance: instance, drain: d, gate: g, source: s, bulk: b,
                parameters: parameters, drainIdx: mapping.drain, gateIdx: mapping.gate,
                sourceIdx: mapping.source, bulkIdx: mapping.bulk, csrIndices: mapping.csr)
        case (.level2, .pmos):
            return BoundPMOSL2(instance: instance, drain: d, gate: g, source: s, bulk: b,
                parameters: parameters, drainIdx: mapping.drain, gateIdx: mapping.gate,
                sourceIdx: mapping.source, bulkIdx: mapping.bulk, csrIndices: mapping.csr)
        case (.level3, .nmos):
            return BoundNMOSL3(instance: instance, drain: d, gate: g, source: s, bulk: b,
                parameters: parameters, drainIdx: mapping.drain, gateIdx: mapping.gate,
                sourceIdx: mapping.source, bulkIdx: mapping.bulk, csrIndices: mapping.csr)
        case (.level3, .pmos):
            return BoundPMOSL3(instance: instance, drain: d, gate: g, source: s, bulk: b,
                parameters: parameters, drainIdx: mapping.drain, gateIdx: mapping.gate,
                sourceIdx: mapping.source, bulkIdx: mapping.bulk, csrIndices: mapping.csr)
        default: throw MOSBindingFailure.identityMismatch
        }
    }
}
