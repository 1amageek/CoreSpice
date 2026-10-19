import CoreSpiceIR

/// Descriptor for static/model capacitance and bounded behavioral C/Q laws.
public struct CapacitorDescriptor: DeviceDescriptor, Sendable {

    public let typeName = "capacitor"
    public let portNames = ["pos", "neg"]
    public let parameterDescriptors = [
        ParameterDescriptor(name: "c", defaultValue: nil, description: "Capacitance in farads"),
        ParameterDescriptor(name: "ic", defaultValue: .real(0.0), description: "Initial voltage across capacitor"),
        ParameterDescriptor(name: "m", defaultValue: .real(1.0), description: "Parallel device multiplicity"),
        ParameterDescriptor(name: "q", defaultValue: nil, description: "Canonical stored-charge expression"),
        ParameterDescriptor(name: "l", defaultValue: nil, description: "Instance length in meters after document scale"),
        ParameterDescriptor(name: "w", defaultValue: nil, description: "Instance width in meters after document scale"),
        ParameterDescriptor(name: "temp", defaultValue: nil, description: "Static capacitor absolute temperature in Celsius"),
        ParameterDescriptor(name: "dtemp", defaultValue: nil, description: "Static capacitor temperature offset in Kelvin"),
        ParameterDescriptor(name: "tc1", defaultValue: nil, description: "Linear temperature coefficient"),
        ParameterDescriptor(name: "tc2", defaultValue: nil, description: "Quadratic temperature coefficient"),
        ParameterDescriptor(name: "scale", defaultValue: nil, description: "Positive static capacitance scale"),
    ]

    /// Complete static instance admission profile; numeric domains remain preparation-owned.
    public static let staticInstanceParameterNames: Set<String> = [
        "c", "ic", "m", "l", "w", "scale", "temp", "dtemp", "tc1", "tc2",
    ]
    /// Complete static model admission profile, including source-role aliases.
    public static let staticModelParameterNames: Set<String> = [
        "cap", "cj", "cox", "cjsw", "capsw", "defw", "w", "narrow", "short", "del", "di", "thick", "tnom", "tc1", "tc2",
    ]
    /// Common behavioral settings; the exclusive c or q expression is admitted separately.
    public static let behavioralInstanceParameterNames: Set<String> = ["ic", "m", "tc", "tc1", "tc2"]

    private let runtimePolicy: RuntimeCapacitorPolicy

    public init(runtimePolicy: RuntimeCapacitorPolicy = .default) { self.runtimePolicy = runtimePolicy }

    public func bind(instance: Instance, context: inout BindingContext) throws -> any BoundDevice {
        guard instance.nodes.count == 2 else {
            throw DeviceBindingError.portCountMismatch(
                device: instance.name, expected: 2, got: instance.nodes.count
            )
        }

        if let charge = instance.parameters["q"] {
            let expression: BehavioralExpression
            switch charge {
            case .behavioralExpression(let value): expression = value
            case .real(let value): expression = .constant(value)
            default:
                throw DeviceBindingError.invalidParameterType(device: instance.name, parameter: "q",
                    expected: "finite charge or canonical behavioral expression")
            }
            return try BoundBehavioralCapacitor(instance: instance, expression: expression, law: .charge,
                context: context, policy: runtimePolicy)
        }
        if case .behavioralExpression(let expression) = instance.parameters["c"] {
            return try BoundBehavioralCapacitor(instance: instance, expression: expression, law: .differentialCapacitance,
                context: context, policy: runtimePolicy)
        }
        let prepared = try StaticCapacitorPreparation.prepare(instance, conditions: context.operatingConditions)
        let capacitance = prepared.capacitance
        let initialVoltage = prepared.initialVoltage

        let posNode = instance.nodes[0]
        let negNode = instance.nodes[1]
        for node in [posNode, negNode] where node != .ground {
            guard let index = context.nodeIndex(node), (0..<context.matrixDimension).contains(index) else {
                throw DeviceBindingError.invalidParameterValue(device: instance.name, parameter: "nodes",
                    message: "Capacitor terminal is absent from the compiled topology")
            }
        }
        let posIdx = context.nodeIndex(posNode)
        let negIdx = context.nodeIndex(negNode)

        // Pre-resolve CSR value indices for O(1) stamping
        let stampPP = posIdx.flatMap { i in context.stampIndex(row: i, col: i) }
        let stampNN = negIdx.flatMap { i in context.stampIndex(row: i, col: i) }
        let stampPN: Int? = if let i = posIdx, let j = negIdx { context.stampIndex(row: i, col: j) } else { nil }
        let stampNP: Int? = if let i = negIdx, let j = posIdx { context.stampIndex(row: i, col: j) } else { nil }

        return BoundCapacitor(
            instance: instance,
            posNode: posNode,
            negNode: negNode,
            capacitance: capacitance,
            initialVoltage: initialVoltage,
            hasExplicitInitialCondition: prepared.hasInitialCondition,
            posIdx: posIdx,
            negIdx: negIdx,
            stampPP: stampPP,
            stampNN: stampNN,
            stampPN: stampPN,
            stampNP: stampNP
        )
    }
}
