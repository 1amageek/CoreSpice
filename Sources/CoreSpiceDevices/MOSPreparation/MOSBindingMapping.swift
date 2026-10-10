import CoreSpiceIR
import CoreSpiceMOSContracts

/// Exact four-terminal indices and every required active CSR entry.
struct MOSBindingMapping {
    let drain: Int?
    let gate: Int?
    let source: Int?
    let bulk: Int?
    let csr: MOSFETCSRIndices

    init(instance: Instance, context: BindingContext) throws(MOSBindingFailure) {
        func index(_ node: Node) throws(MOSBindingFailure) -> Int? {
            if node == .ground { return nil }
            guard let value = context.nodeIndex(node), (0..<context.matrixDimension).contains(value) else {
                throw .invalidMatrixMapping
            }
            return value
        }
        drain = try index(instance.nodes[0]); gate = try index(instance.nodes[1])
        source = try index(instance.nodes[2]); bulk = try index(instance.nodes[3])
        func slot(_ row: Int?, _ column: Int?) throws(MOSBindingFailure) -> Int? {
            guard let row, let column else { return nil }
            guard let value = context.stampIndex(row: row, col: column), value >= 0 else { throw .invalidMatrixMapping }
            return value
        }
        csr = try MOSFETCSRIndices(dd: slot(drain, drain), gg: slot(gate, gate),
            ss: slot(source, source), bb: slot(bulk, bulk), dg: slot(drain, gate),
            ds: slot(drain, source), db: slot(drain, bulk), gd: slot(gate, drain),
            gs: slot(gate, source), gb: slot(gate, bulk), sd: slot(source, drain),
            sg: slot(source, gate), sb: slot(source, bulk), bd: slot(bulk, drain),
            bg: slot(bulk, gate), bs: slot(bulk, source))
    }
}
