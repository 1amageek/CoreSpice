import CoreSpiceCompile
import CoreSpiceIR

/// Maps public source identities across a freshly compiled circuit topology.
struct CircuitReexecution {
    static func outputNode(_ node: Node, from original: ExecutionPlan, to prepared: ExecutionPlan) throws -> Node {
        if node == .ground { return .ground }
        guard let name = original.ir.name(for: node) else {
            throw AnalysisError.invalidConfiguration("Source reexecution requires a named output node")
        }
        let matches = prepared.ir.nodeNames.filter { $0.value == name }.map(\.key)
        guard matches.count == 1, let mapped = matches.first,
              prepared.topology.variableMap[.nodeVoltage(mapped)] != nil else {
            throw AnalysisError.invalidConfiguration("Source reexecution lost or aliased output node '\(name)'")
        }
        return mapped
    }

    static func nodeGuesses(_ guesses: [Node: Double], from original: ExecutionPlan,
                           to prepared: ExecutionPlan) throws -> [Node: Double] {
        var mapped: [Node: Double] = [:]
        mapped.reserveCapacity(guesses.count)
        for (node, value) in guesses {
            let target = try outputNode(node, from: original, to: prepared)
            guard mapped.updateValue(value, forKey: target) == nil else {
                throw AnalysisError.invalidConfiguration("Source reexecution aliases required initial guesses")
            }
        }
        return mapped
    }

}
