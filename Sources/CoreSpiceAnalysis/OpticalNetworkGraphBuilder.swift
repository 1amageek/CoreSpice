import CoreSpiceCompile
import CoreSpiceDevices
import CoreSpiceIR

/// Builds an `OpticalNetworkGraph` from bound devices by inspecting
/// their optical port declarations.
///
/// This builder operates after device binding, when the concrete device
/// types are known. It examines each bound device for `OpticalEmitter`,
/// `OptoelectronicDevice`, or `OpticalDevice` conformance, extracts
/// input/output optical nodes, and topologically sorts them into a DAG.
///
/// The resulting graph is used by `OpticalNetworkEvaluator` to propagate
/// optical signals and sensitivities at each NR iteration.
public struct OpticalNetworkGraphBuilder {

    public init() {}

    /// Builds an optical network graph from the circuit IR and bound devices.
    ///
    /// Returns `nil` if the circuit has no optical nodes or no optical devices.
    public func build(
        from ir: CircuitIR,
        devices: [any BoundDevice]
    ) -> OpticalNetworkGraph? {
        guard !ir.opticalNodes.isEmpty else { return nil }

        // Collect optical port info from each device
        struct DeviceOpticalInfo {
            let deviceIndex: Int
            let inputNodes: [OpticalNode]
            let outputNodes: [OpticalNode]
        }

        var deviceInfos: [DeviceOpticalInfo] = []

        for (index, device) in devices.enumerated() {
            if let emitter = device as? OpticalEmitter {
                deviceInfos.append(DeviceOpticalInfo(
                    deviceIndex: index,
                    inputNodes: emitter.opticalInputNodes,
                    outputNodes: emitter.opticalOutputNodes
                ))
            } else if let optoDevice = device as? OptoelectronicDevice {
                deviceInfos.append(DeviceOpticalInfo(
                    deviceIndex: index,
                    inputNodes: optoDevice.opticalInputNodes,
                    outputNodes: optoDevice.opticalOutputNodes
                ))
            } else if let opticalDevice = device as? OpticalDevice {
                deviceInfos.append(DeviceOpticalInfo(
                    deviceIndex: index,
                    inputNodes: opticalDevice.opticalInputNodes,
                    outputNodes: opticalDevice.opticalOutputNodes
                ))
            }
        }

        guard !deviceInfos.isEmpty else { return nil }

        // Build dependency graph: optical node → index into deviceInfos that produces it
        var nodeProducer: [Int: Int] = [:]  // opticalNode.id → deviceInfos index
        for (i, info) in deviceInfos.enumerated() {
            for node in info.outputNodes {
                nodeProducer[node.id] = i
            }
        }

        // Topological sort using Kahn's algorithm
        let count = deviceInfos.count
        var inDegree = [Int](repeating: 0, count: count)
        var adjacency = [[Int]](repeating: [], count: count)

        for (i, info) in deviceInfos.enumerated() {
            for inputNode in info.inputNodes where inputNode.id > 0 {
                if let producerIdx = nodeProducer[inputNode.id] {
                    adjacency[producerIdx].append(i)
                    inDegree[i] += 1
                }
            }
        }

        // Seed with devices that have no dependencies (emitters)
        var queue: [Int] = []
        for i in 0..<count {
            if inDegree[i] == 0 {
                queue.append(i)
            }
        }

        var sorted: [DeviceOpticalInfo] = []
        var queueIdx = 0
        while queueIdx < queue.count {
            let current = queue[queueIdx]
            queueIdx += 1
            sorted.append(deviceInfos[current])
            for neighbor in adjacency[current] {
                inDegree[neighbor] -= 1
                if inDegree[neighbor] == 0 {
                    queue.append(neighbor)
                }
            }
        }

        // Build evaluation entries
        let evaluationOrder = sorted.map { info in
            OpticalNetworkGraph.EvaluationEntry(
                deviceIndex: info.deviceIndex,
                inputNodes: info.inputNodes,
                outputNodes: info.outputNodes
            )
        }

        // Optical node count = max ID + 1
        let maxID = ir.opticalNodes.map(\.id).max() ?? 0

        return OpticalNetworkGraph(
            evaluationOrder: evaluationOrder,
            opticalNodeCount: maxID + 1
        )
    }
}
