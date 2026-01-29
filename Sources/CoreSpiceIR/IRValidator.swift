/// Validation errors that can occur during IR analysis.
public enum IRValidationError: Error, Sendable, Equatable {
    /// No node is connected to ground reference.
    case noGroundConnection

    /// Multiple disconnected subnetworks exist.
    case floatingSubcircuit(componentCount: Int)

    /// A device has both terminals connected to the same node.
    case selfLoop(device: String)

    /// A required parameter is missing or invalid.
    case invalidParameter(device: String, parameter: String, message: String)

    /// A node is defined but has no devices connected.
    case orphanedNode(nodeId: Int)

    /// Device type is not recognized.
    case unknownDeviceType(device: String, typeName: String)
}

/// Warnings that don't prevent simulation but may indicate problems.
public enum IRValidationWarning: Sendable, Equatable {
    /// Node defined but connected to only one terminal.
    case danglingNode(nodeId: Int)

    /// Branch variable defined but never used.
    case unusedBranch(branchId: Int)

    /// Parameter value may cause numerical issues.
    case suspiciousParameter(device: String, parameter: String, message: String)
}

/// Result of validating a circuit IR.
public struct IRValidationResult: Sendable {
    /// Errors that prevent simulation.
    public let errors: [IRValidationError]

    /// Warnings that don't prevent simulation.
    public let warnings: [IRValidationWarning]

    /// Returns true if no validation errors were found.
    public var isValid: Bool { errors.isEmpty }

    public init(errors: [IRValidationError] = [], warnings: [IRValidationWarning] = []) {
        self.errors = errors
        self.warnings = warnings
    }
}

/// Validates circuit IR for common issues before simulation.
///
/// The validator checks for:
/// - Ground connectivity (at least one node must be grounded)
/// - Connected components (no floating subcircuits)
/// - Self-loops (same node on both terminals)
/// - Orphaned nodes (defined but not used)
public struct IRValidator: Sendable {

    public init() {}

    /// Validates the given circuit IR.
    ///
    /// - Parameter ir: The circuit intermediate representation to validate.
    /// - Returns: A validation result with any errors and warnings found.
    public func validate(_ ir: CircuitIR) -> IRValidationResult {
        var errors: [IRValidationError] = []
        var warnings: [IRValidationWarning] = []

        // Collect all nodes actually used by devices
        var usedNodes = Set<Node>()
        var nodeConnectionCount: [Node: Int] = [:]

        for instance in ir.instances {
            for node in instance.nodes {
                usedNodes.insert(node)
                nodeConnectionCount[node, default: 0] += 1
            }
        }

        // Check 1: Ground connection
        if !usedNodes.contains(.ground) {
            errors.append(.noGroundConnection)
        }

        // Check 2: Self-loops (same node on both terminals for 2-terminal devices)
        for instance in ir.instances {
            let uniqueNodes = Set(instance.nodes)
            if uniqueNodes.count < instance.nodes.count && instance.nodes.count >= 2 {
                // At least two terminals connect to the same node
                errors.append(.selfLoop(device: instance.name))
            }
        }

        // Check 3: Connected components (no floating subcircuits)
        let componentCount = countConnectedComponents(ir: ir)
        if componentCount > 1 {
            errors.append(.floatingSubcircuit(componentCount: componentCount))
        }

        // Check 4: Orphaned nodes (defined but not used)
        let definedNodes = Set(ir.nodes)
        let orphaned = definedNodes.subtracting(usedNodes).subtracting([.ground])
        for node in orphaned {
            warnings.append(.danglingNode(nodeId: node.id))
        }

        // Check 5: Dangling nodes (connected to only one terminal)
        for (node, count) in nodeConnectionCount {
            if count == 1 && node != .ground {
                // Only warn - single connection might be intentional (e.g., output node)
                // Don't add warning here as it's too common and often intentional
            }
        }

        // Check 6: Unused branches
        // Note: Branches are allocated by voltage sources/inductors, so unused branches
        // would indicate a bug in branch allocation, not a user error

        return IRValidationResult(errors: errors, warnings: warnings)
    }

    /// Counts the number of connected components in the circuit.
    ///
    /// Uses union-find to efficiently determine connectivity.
    private func countConnectedComponents(ir: CircuitIR) -> Int {
        // Collect all nodes used by devices
        var nodeSet = Set<Node>()
        for instance in ir.instances {
            for node in instance.nodes {
                nodeSet.insert(node)
            }
        }

        guard !nodeSet.isEmpty else { return 0 }

        // Map nodes to indices for union-find
        let nodeArray = Array(nodeSet)
        var nodeIndex: [Node: Int] = [:]
        for (idx, node) in nodeArray.enumerated() {
            nodeIndex[node] = idx
        }

        // Union-Find data structure
        var parent = Array(0..<nodeArray.count)
        var rank = Array(repeating: 0, count: nodeArray.count)

        func find(_ x: Int) -> Int {
            if parent[x] != x {
                parent[x] = find(parent[x])  // Path compression
            }
            return parent[x]
        }

        func union(_ x: Int, _ y: Int) {
            let px = find(x)
            let py = find(y)
            if px == py { return }

            // Union by rank
            if rank[px] < rank[py] {
                parent[px] = py
            } else if rank[px] > rank[py] {
                parent[py] = px
            } else {
                parent[py] = px
                rank[px] += 1
            }
        }

        // Union nodes connected by each device
        for instance in ir.instances {
            guard let firstIdx = nodeIndex[instance.nodes[0]] else { continue }
            for node in instance.nodes.dropFirst() {
                guard let idx = nodeIndex[node] else { continue }
                union(firstIdx, idx)
            }
        }

        // Count unique roots
        var roots = Set<Int>()
        for i in 0..<nodeArray.count {
            roots.insert(find(i))
        }

        return roots.count
    }
}

// MARK: - Netlist Integration

extension Netlist {

    /// Builds and validates the circuit IR.
    ///
    /// - Returns: A tuple containing the IR and any validation warnings.
    /// - Throws: `NetlistError` if the netlist is invalid, or aggregated
    ///           validation errors if the IR fails validation.
    public func buildAndValidate() throws -> (ir: CircuitIR, warnings: [IRValidationWarning]) {
        let ir = try build()

        let validator = IRValidator()
        let result = validator.validate(ir)

        if !result.isValid {
            throw NetlistError.validationFailed(errors: result.errors)
        }

        return (ir, result.warnings)
    }
}

// MARK: - Extended NetlistError

extension NetlistError {
    /// Validation of the circuit IR failed.
    public static func validationFailed(errors: [IRValidationError]) -> NetlistError {
        // Return the first error for simplicity; could be extended to aggregate
        if let first = errors.first {
            switch first {
            case .noGroundConnection:
                return .invalidParameterValue(instance: "", parameter: "", message: "No ground connection in circuit")
            case .floatingSubcircuit(let count):
                return .invalidParameterValue(instance: "", parameter: "", message: "Circuit has \(count) disconnected subcircuits")
            case .selfLoop(let device):
                return .invalidParameterValue(instance: device, parameter: "", message: "Device has terminals connected to same node")
            case .invalidParameter(let device, let param, let msg):
                return .invalidParameterValue(instance: device, parameter: param, message: msg)
            case .orphanedNode(let id):
                return .invalidParameterValue(instance: "", parameter: "", message: "Node \(id) is defined but not used")
            case .unknownDeviceType(let device, let typeName):
                return .invalidParameterValue(instance: device, parameter: "", message: "Unknown device type: \(typeName)")
            }
        }
        return .emptyNetlist
    }
}
