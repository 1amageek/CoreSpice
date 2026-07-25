import CoreSpiceCompile
import CoreSpiceDevices
import CoreSpiceEvent
import Foundation

/// A compiled plan and its bound devices after identity and topology validation.
///
/// Analyses accept this type as the safe composition boundary between
/// compilation and device execution. The compiler remains independent from
/// concrete device models, while mismatched arrays cannot enter an analysis
/// through this API.
public struct PreparedCircuit: Sendable {
    public let plan: ExecutionPlan
    public let devices: [any BoundDevice]

    public init(
        plan: ExecutionPlan,
        devices: [any BoundDevice]
    ) throws {
        try Self.validate(plan: plan, devices: devices)
        self.plan = plan
        self.devices = devices
    }

    /// Validates legacy split arguments at every existing analysis entry point.
    public static func validate(
        plan: ExecutionPlan,
        devices: [any BoundDevice]
    ) throws {
        let instanceCount = plan.ir.instances.count
        guard plan.deviceNames.count == instanceCount else {
            throw PreparedCircuitError.deviceNameCountMismatch(
                expected: instanceCount,
                actual: plan.deviceNames.count
            )
        }
        guard devices.count == instanceCount else {
            throw PreparedCircuitError.boundDeviceCountMismatch(
                expected: instanceCount,
                actual: devices.count
            )
        }

        for index in 0..<instanceCount {
            let expected = plan.ir.instances[index]
            let name = plan.deviceNames[index]
            let actual = devices[index].instance
            guard name == expected.name else {
                throw PreparedCircuitError.planIdentityMismatch(
                    index: index,
                    expected: expected.name,
                    actual: name
                )
            }
            guard actual.name == expected.name,
                  actual.typeName == expected.typeName,
                  actual.nodes == expected.nodes,
                  actual.opticalNodes == expected.opticalNodes else {
                throw PreparedCircuitError.boundDeviceIdentityMismatch(
                    index: index,
                    expected: expected.name,
                    actual: actual.name
                )
            }
        }

        if let graph = plan.opticalNetwork {
            guard graph.opticalNodeCount >= 0 else {
                throw PreparedCircuitError.invalidOpticalNodeCount(graph.opticalNodeCount)
            }
            for entry in graph.evaluationOrder {
                guard devices.indices.contains(entry.deviceIndex) else {
                    throw PreparedCircuitError.invalidOpticalDeviceIndex(
                        entry.deviceIndex,
                        deviceCount: devices.count
                    )
                }
                for node in entry.inputNodes + entry.outputNodes {
                    guard node.id >= 0, node.id < graph.opticalNodeCount else {
                        throw PreparedCircuitError.invalidOpticalNodeIndex(
                            node.id,
                            nodeCount: graph.opticalNodeCount
                        )
                    }
                }
            }
        }
    }
}

public enum PreparedCircuitError: Error, Sendable, Equatable {
    case deviceNameCountMismatch(expected: Int, actual: Int)
    case boundDeviceCountMismatch(expected: Int, actual: Int)
    case planIdentityMismatch(index: Int, expected: String, actual: String)
    case boundDeviceIdentityMismatch(index: Int, expected: String, actual: String)
    case invalidOpticalNodeCount(Int)
    case invalidOpticalDeviceIndex(Int, deviceCount: Int)
    case invalidOpticalNodeIndex(Int, nodeCount: Int)
}

extension PreparedCircuitError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .deviceNameCountMismatch(let expected, let actual):
            return "Execution plan contains \(actual) device names for \(expected) instances"
        case .boundDeviceCountMismatch(let expected, let actual):
            return "Analysis received \(actual) bound devices for \(expected) instances"
        case .planIdentityMismatch(let index, let expected, let actual):
            return "Execution plan device name mismatch at index \(index): expected \(expected), got \(actual)"
        case .boundDeviceIdentityMismatch(let index, let expected, let actual):
            return "Bound device mismatch at index \(index): expected \(expected), got \(actual)"
        case .invalidOpticalNodeCount(let count):
            return "Optical network node count must be nonnegative, got \(count)"
        case .invalidOpticalDeviceIndex(let index, let count):
            return "Optical network device index \(index) is outside 0..<\(count)"
        case .invalidOpticalNodeIndex(let index, let count):
            return "Optical network node index \(index) is outside 0..<\(count)"
        }
    }
}

extension Analysis {
    /// Executes against a validated circuit composition.
    public func run(
        circuit: PreparedCircuit,
        solver: any LinearSolver,
        observer: EventDispatcher?,
        cancellation: CancellationToken
    ) async throws -> Result {
        try await run(
            plan: circuit.plan,
            devices: circuit.devices,
            solver: solver,
            observer: observer,
            cancellation: cancellation
        )
    }
}
