import CoreSpiceDevices
import OSDIContracts

/// Prepared canonical residual endpoints; no raw index lookup occurs during a sweep.
package enum OSDINoiseProjection {
    static func project(sources: [OSDINoiseSourceInfo], topology: OSDIPreparedTopology,
                        projection: OSDITopologyProjection) throws(OSDIAdapterFailure) -> [ResidualNoiseSource] {
        var result: [ResidualNoiseSource] = []
        result.reserveCapacity(sources.count)
        var indices = Set<Int>()
        for source in sources {
            guard indices.insert(source.index).inserted,
                  topology.nodes.indices.contains(source.positiveNodeIndex),
                  source.negativeNodeIndex.map({ topology.nodes.indices.contains($0) }) ?? true else {
                throw .invalidNoiseSources
            }
            let positive = topology.nodes[source.positiveNodeIndex]
            let unit: ResidualNoiseUnit
            switch (positive.units, positive.residualUnits, positive.isFlow) {
            case ("V", "A", false): unit = .ampere
            case ("A", "V", true): unit = .volt
            case ("K", "W", false): unit = .watt
            default: throw .invalidNoiseSources
            }
            if let negative = source.negativeNodeIndex {
                let node = topology.nodes[negative]
                guard node.residualUnits == positive.residualUnits,
                      node.units == positive.units, node.isFlow == positive.isFlow else { throw .invalidNoiseSources }
            }
            let p = projection.rawActive[source.positiveNodeIndex].flatMap { projection.activeVariables[$0] }
            let n = source.negativeNodeIndex.flatMap { projection.rawActive[$0] }.flatMap { projection.activeVariables[$0] }
            result.append(ResidualNoiseSource(index: source.index, name: source.name,
                positive: p, negative: n, unit: unit))
        }
        return result
    }
}
