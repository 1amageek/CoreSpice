import CoreSpiceIR
import OSDIContracts

/// Active coordinates are mapped once; raw rows/columns may alias those coordinates.
package struct OSDITopologyProjection: Sendable {
    let activeVariables: [MNAVariable?]
    let activeKinds: [OSDIVariableKind]
    let rawActive: [Int?]
    let ownedNodes: [Node]
    let ownedBranches: [Branch]

    init(topology: OSDIPreparedTopology, terminals: [Node], nextNodeID: inout Int,
         nextBranchID: inout Int) throws(OSDIAdapterFailure) {
        guard terminals.count <= topology.nodes.count else { throw .invalidTopology }
        var variables = [MNAVariable?](repeating: nil, count: topology.activeUnknownCount)
        var assigned = [Bool](repeating: false, count: topology.activeUnknownCount)
        var kinds = [OSDIVariableKind?](repeating: nil, count: topology.activeUnknownCount)
        var raw: [Int?] = []; raw.reserveCapacity(topology.nodes.count)
        var nodes: [Node] = [], branches: [Branch] = []
        for node in topology.nodes {
            let kind: OSDIVariableKind
            switch (node.units, node.residualUnits, node.isFlow) {
            case ("V", "A", false): kind = .electricalPotential
            case ("A", "V", true): kind = .electricalFlow
            case ("K", "W", false): kind = .thermalPotential
            default: throw .unsupportedNature(node: node.index, unknown: node.units, residual: node.residualUnits)
            }
            raw.append(node.activeUnknownIndex)
            guard let active = node.activeUnknownIndex else {
                if node.index < terminals.count && terminals[node.index] != .ground {
                    throw .collapsedExternalNets
                }
                continue
            }
            if let previous = kinds[active], previous != kind { throw .invalidTopology }
            kinds[active] = kind
            if node.index < terminals.count {
                guard kind != .electricalFlow else { throw .invalidTopology }
                let variable: MNAVariable? = terminals[node.index] == .ground ? nil : .nodeVoltage(terminals[node.index])
                if assigned[active] && variables[active] != variable { throw .collapsedExternalNets }
                assigned[active] = true; variables[active] = variable
            }
        }
        for active in 0..<topology.activeUnknownCount where !assigned[active] {
            guard let kind = kinds[active] else { throw .invalidTopology }
            switch kind {
            case .electricalFlow:
                let (next, overflow) = nextBranchID.addingReportingOverflow(1)
                guard !overflow, next >= 0 else { throw .capacityExceeded }
                nextBranchID = next; let branch = Branch(id: next)
                branches.append(branch); variables[active] = .branchCurrent(branch)
            case .electricalPotential, .thermalPotential:
                let (next, overflow) = nextNodeID.addingReportingOverflow(1)
                guard !overflow, next > 0 else { throw .capacityExceeded }
                nextNodeID = next; let node = Node(id: next)
                nodes.append(node); variables[active] = .nodeVoltage(node)
            }
        }
        self.activeVariables = variables
        self.activeKinds = try kinds.map { value throws(OSDIAdapterFailure) in
            guard let value else { throw .invalidTopology }; return value
        }
        self.rawActive = raw; self.ownedNodes = nodes; self.ownedBranches = branches
    }
}
