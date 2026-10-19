import CoreSpiceIR
import CoreSpiceCompile
import CoreSpiceOSDI
import CoreSpiceOSDIContracts
import CoreSpiceDevices

/// Exact setup evidence and the actual raw-descriptor-row to compiled-equation join.
public struct NativeOSDIPreparationRecord: Sendable {
    public let instanceName: String
    public let receipt: OSDIPreparationReceipt
    public let rawNodeGlobalRows: [Int?]
    public let transientPrecision: OSDITransientPrecisionReceipt?

    internal static func records(plan: ExecutionPlan, devices: [any BoundDevice]) throws -> [Self] {
        guard devices.count == plan.ir.instances.count else { throw OSDIAdapterFailure.invalidTopology }
        var result: [Self] = []
        for (instanceIndex, instance) in plan.ir.instances.enumerated() {
            guard case .prepared(let receipt) = instance.osdi else { continue }
            guard devices[instanceIndex].instance.name == instance.name else { throw OSDIAdapterFailure.invalidTopology }
            let precision = (devices[instanceIndex] as? any OSDITransientPrecisionProviding)?.transientPrecisionReceipt
            if let precision {
                guard precision.program.modelReference == receipt.resolved.binding.artifact,
                      Int(precision.program.descriptorIndex) == receipt.resolved.binding.descriptorIndex,
                      precision.program.topology == receipt.topology else { throw OSDIAdapterFailure.identityMismatch }
            }
            let topology = receipt.topology
            guard instance.nodes.count <= topology.nodes.count else { throw OSDIAdapterFailure.invalidTopology }
            var active = [MNAVariable?](repeating: nil, count: topology.activeUnknownCount)
            var assigned = [Bool](repeating: false, count: topology.activeUnknownCount)
            for index in instance.nodes.indices {
                guard let coordinate = topology.nodes[index].activeUnknownIndex else { continue }
                let node = instance.nodes[index]
                let variable: MNAVariable? = node == plan.ir.groundNode ? nil : .nodeVoltage(node)
                guard !assigned[coordinate] || active[coordinate] == variable else { throw OSDIAdapterFailure.invalidTopology }
                assigned[coordinate] = true; active[coordinate] = variable
            }
            var nodeOffset = 0, branchOffset = 0
            for coordinate in active.indices where !assigned[coordinate] {
                guard let raw = topology.nodes.first(where: { $0.activeUnknownIndex == coordinate }) else { throw OSDIAdapterFailure.invalidTopology }
                if raw.isFlow {
                    guard instance.ownedBranches.indices.contains(branchOffset) else { throw OSDIAdapterFailure.invalidTopology }
                    active[coordinate] = .branchCurrent(instance.ownedBranches[branchOffset]); branchOffset += 1
                } else {
                    guard instance.ownedNodes.indices.contains(nodeOffset) else { throw OSDIAdapterFailure.invalidTopology }
                    active[coordinate] = .nodeVoltage(instance.ownedNodes[nodeOffset]); nodeOffset += 1
                }
            }
            guard nodeOffset == instance.ownedNodes.count, branchOffset == instance.ownedBranches.count else { throw OSDIAdapterFailure.invalidTopology }
            let rows = try topology.nodes.map { node throws -> Int? in
                guard let coordinate = node.activeUnknownIndex, let variable = active[coordinate] else { return nil }
                guard let row = plan.topology.variableMap[variable] else { throw OSDIAdapterFailure.invalidMatrixMapping }
                return row
            }
            result.append(.init(instanceName: instance.name, receipt: receipt, rawNodeGlobalRows: rows,
                transientPrecision: precision))
        }
        return result
    }
}
