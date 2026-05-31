import CoreSpiceIR

/// Descriptor for an NMOS Level 1 MOSFET (Shichman-Hodges model).
///
/// Four ports: drain, gate, source, bulk. Body effect is modeled
/// via `gamma` and `phi` parameters using the bulk-source voltage.
public struct NMOSL1Descriptor: DeviceDescriptor, Sendable {

    public let typeName = "nmos_l1"
    public let portNames = ["drain", "gate", "source", "bulk"]
    public let parameterDescriptors = [
        ParameterDescriptor(name: "w", defaultValue: .real(10e-6), description: "Channel width (m)"),
        ParameterDescriptor(name: "l", defaultValue: .real(1e-6), description: "Channel length (m)"),
        ParameterDescriptor(name: "vto", defaultValue: .real(0.0), description: "Threshold voltage (V)"),
        ParameterDescriptor(name: "kp", defaultValue: .real(2e-5), description: "Transconductance parameter (A/V^2)"),
        ParameterDescriptor(name: "gamma", defaultValue: .real(0.0), description: "Body effect coefficient (V^0.5)"),
        ParameterDescriptor(name: "phi", defaultValue: .real(0.6), description: "Surface potential (V)"),
        ParameterDescriptor(name: "lambda", defaultValue: .real(0.0), description: "Channel-length modulation (1/V)"),
        ParameterDescriptor(name: "tox", defaultValue: .real(0), description: "Gate oxide thickness (m); 0 = unspecified, no intrinsic gate capacitance (SPICE convention)"),
        ParameterDescriptor(name: "cgso", defaultValue: .real(0), description: "Gate-source overlap capacitance (F/m)"),
        ParameterDescriptor(name: "cgdo", defaultValue: .real(0), description: "Gate-drain overlap capacitance (F/m)"),
        ParameterDescriptor(name: "cgbo", defaultValue: .real(0), description: "Gate-bulk overlap capacitance (F/m)"),
        ParameterDescriptor(name: "cj", defaultValue: .real(0), description: "Bulk junction bottom capacitance (F/m^2)"),
        ParameterDescriptor(name: "cjsw", defaultValue: .real(0), description: "Bulk junction sidewall capacitance (F/m)"),
        ParameterDescriptor(name: "mj", defaultValue: .real(0.5), description: "Junction grading coefficient"),
        ParameterDescriptor(name: "mjsw", defaultValue: .real(0.33), description: "Sidewall grading coefficient"),
        ParameterDescriptor(name: "pb", defaultValue: .real(0.8), description: "Bulk junction potential (V)"),
        ParameterDescriptor(name: "ad", defaultValue: .real(0), description: "Drain diffusion area (m^2)"),
        ParameterDescriptor(name: "as", defaultValue: .real(0), description: "Source diffusion area (m^2)"),
        ParameterDescriptor(name: "pd", defaultValue: .real(0), description: "Drain diffusion perimeter (m)"),
        ParameterDescriptor(name: "ps", defaultValue: .real(0), description: "Source diffusion perimeter (m)"),
    ]

    public init() {}

    public func bind(instance: Instance, context: inout BindingContext) throws -> any BoundDevice {
        guard instance.nodes.count == 4 else {
            throw DeviceBindingError.portCountMismatch(
                device: instance.name, expected: 4, got: instance.nodes.count
            )
        }

        let params = try extractModelParameters(from: instance)

        let drainNode = instance.nodes[0]
        let gateNode = instance.nodes[1]
        let sourceNode = instance.nodes[2]
        let bulkNode = instance.nodes[3]

        let dIdx = context.nodeIndex(drainNode)
        let gIdx = context.nodeIndex(gateNode)
        let sIdx = context.nodeIndex(sourceNode)
        let bIdx = context.nodeIndex(bulkNode)

        // Pre-resolve CSR value indices for O(1) stamping
        let csrIndices = MOSFETCSRIndices(
            dd: dIdx.flatMap { context.stampIndex(row: $0, col: $0) },
            gg: gIdx.flatMap { context.stampIndex(row: $0, col: $0) },
            ss: sIdx.flatMap { context.stampIndex(row: $0, col: $0) },
            bb: bIdx.flatMap { context.stampIndex(row: $0, col: $0) },
            dg: dIdx.flatMap { d in gIdx.flatMap { context.stampIndex(row: d, col: $0) } },
            ds: dIdx.flatMap { d in sIdx.flatMap { context.stampIndex(row: d, col: $0) } },
            db: dIdx.flatMap { d in bIdx.flatMap { context.stampIndex(row: d, col: $0) } },
            gd: gIdx.flatMap { g in dIdx.flatMap { context.stampIndex(row: g, col: $0) } },
            gs: gIdx.flatMap { g in sIdx.flatMap { context.stampIndex(row: g, col: $0) } },
            gb: gIdx.flatMap { g in bIdx.flatMap { context.stampIndex(row: g, col: $0) } },
            sd: sIdx.flatMap { s in dIdx.flatMap { context.stampIndex(row: s, col: $0) } },
            sg: sIdx.flatMap { s in gIdx.flatMap { context.stampIndex(row: s, col: $0) } },
            sb: sIdx.flatMap { s in bIdx.flatMap { context.stampIndex(row: s, col: $0) } },
            bd: bIdx.flatMap { b in dIdx.flatMap { context.stampIndex(row: b, col: $0) } },
            bg: bIdx.flatMap { b in gIdx.flatMap { context.stampIndex(row: b, col: $0) } },
            bs: bIdx.flatMap { b in sIdx.flatMap { context.stampIndex(row: b, col: $0) } }
        )

        return BoundNMOSL1(
            instance: instance,
            drain: drainNode,
            gate: gateNode,
            source: sourceNode,
            bulk: bulkNode,
            parameters: params,
            drainIdx: dIdx,
            gateIdx: gIdx,
            sourceIdx: sIdx,
            bulkIdx: bIdx,
            csrIndices: csrIndices
        )
    }

    private func extractModelParameters(from instance: Instance) throws -> MOSFETModelParameters {
        var params = MOSFETModelParameters()

        func extractReal(_ name: String) throws -> Double? {
            guard let p = instance.parameters[name] else { return nil }
            guard case .real(let v) = p else {
                throw DeviceBindingError.invalidParameterType(
                    device: instance.name, parameter: name, expected: "real"
                )
            }
            return v
        }

        if let v = try extractReal("w") { params.w = v }
        if let v = try extractReal("l") { params.l = v }
        if let v = try extractReal("vto") { params.vto = v }
        if let v = try extractReal("kp") { params.kp = v }
        if let v = try extractReal("gamma") { params.gamma = v }
        if let v = try extractReal("phi") { params.phi = v }
        if let v = try extractReal("lambda") { params.lambda = v }
        if let v = try extractReal("tox") { params.tox = v }
        if let v = try extractReal("cgso") { params.cgso = v }
        if let v = try extractReal("cgdo") { params.cgdo = v }
        if let v = try extractReal("cgbo") { params.cgbo = v }
        if let v = try extractReal("cj") { params.cj = v }
        if let v = try extractReal("cjsw") { params.cjsw = v }
        if let v = try extractReal("mj") { params.mj = v }
        if let v = try extractReal("mjsw") { params.mjsw = v }
        if let v = try extractReal("pb") { params.pb = v }
        if let v = try extractReal("ad") { params.ad = v }
        if let v = try extractReal("as") { params.asrc = v }
        if let v = try extractReal("pd") { params.pd = v }
        if let v = try extractReal("ps") { params.ps = v }

        try params.validate(device: instance.name)
        return params
    }
}
