import CoreSpiceIR

/// A constant BJT series resistor with prepared finite conductance and compiled mapping.
struct BJTSeriesElement: Sendable {
    let external: Node
    let intrinsic: Node
    let conductance: Double
    let externalIndex: Int?
    let intrinsicIndex: Int
    let ee: Int?
    let ei: Int?
    let ie: Int?
    let ii: Int?

    init(external: Node, intrinsic: Node, resistance: Double, context: BindingContext, device: String) throws {
        let conductance = 1 / resistance
        guard conductance.isFinite, conductance > 0, let internalIndex = context.nodeIndex(intrinsic) else {
            throw DeviceBindingError.invalidParameterValue(device: device, parameter: "seriesResistance",
                message: "BJT series conductance must be finite and positive with a compiled intrinsic node")
        }
        self.external = external; self.intrinsic = intrinsic; self.conductance = conductance
        externalIndex = context.nodeIndex(external); intrinsicIndex = internalIndex
        func resolve(_ row: Int?, _ column: Int?) throws -> Int? {
            guard let row, let column else { return nil }
            let value = context.stampIndex(row: row, col: column)
            guard !context.hasStampIndexResolver || value != nil else {
                throw DeviceBindingError.invalidParameterValue(device: device, parameter: "matrix",
                    message: "BJT series-resistance matrix entry is absent")
            }
            return value
        }
        ee = try resolve(externalIndex, externalIndex); ei = try resolve(externalIndex, internalIndex)
        ie = try resolve(internalIndex, externalIndex); ii = try resolve(internalIndex, internalIndex)
    }

    func stamp(into stamper: inout MatrixStamper) {
        if let sv = stamper.stampValue, let ii {
            if let ee { sv(ee, conductance) }; if let ei { sv(ei, -conductance) }
            if let ie { sv(ie, -conductance) }; sv(ii, conductance)
        } else {
            stamper.stampConductance(node1: external, node2: intrinsic, conductance: conductance)
        }
    }
}
