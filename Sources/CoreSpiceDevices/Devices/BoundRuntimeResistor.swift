import CoreSpiceIR

/// Immutable memoryless resistor with a complete scalar-AD Jacobian and explicit thermal noise.
public struct BoundRuntimeResistor: BoundDevice, NoisyDevice, Sendable {
    public let instance: Instance
    private let evaluator: BehavioralExpressionEvaluator
    private let positiveIndex: Int?
    private let negativeIndex: Int?
    private let dependencies: [Int]
    private let positiveStamps: [Int?]
    private let negativeStamps: [Int?]
    private let mainFactor: Double
    private let auxiliaryFactor: Double
    private let temperatureKelvin: Double
    private let multiplier: Double
    private let noisy: Bool

    init(instance: Instance, expression: BehavioralExpression, parameters: [String: ParameterValue],
         context: BindingContext, policy: RuntimeResistorPolicy) throws {
        func invalid(_ name: String, _ message: String) -> DeviceBindingError {
            .invalidParameterValue(device: instance.name, parameter: name, message: message)
        }
        guard instance.model == nil else { throw invalid("model", "Runtime resistance cannot discard a referenced model") }
        let keys: Set<String> = ["r", "resistance", "tc", "tc1", "tc2", "m", "noisy", "noise"]
        for key in parameters.keys.sorted() where !keys.contains(key) {
            throw invalid(key, "Parameter is outside the admitted runtime resistor profile")
        }
        guard parameters["r"] == nil || parameters["resistance"] == nil else {
            throw invalid("r", "Runtime resistance aliases must have one unambiguous expression")
        }
        func scalar(_ names: [String], default value: Double) throws -> Double {
            var found: Double?
            for name in names {
                guard let supplied = parameters[name] else { continue }
                let number: Double
                if case .real(let value) = supplied { number = value }
                else if (name == "noise" || name == "noisy"), case .integer(let flag) = supplied { number = Double(flag) }
                else { throw DeviceBindingError.invalidParameterType(device: instance.name, parameter: name, expected: "finite real") }
                guard number.isFinite else { throw invalid(name, "Parameter must be finite") }
                if let found, found != number { throw invalid(name, "Conflicting parameter aliases") }
                found = number
            }
            return found ?? value
        }
        let tc1 = try scalar(["tc", "tc1"], default: 0)
        let tc2 = try scalar(["tc2"], default: 0)
        let multiplier = try scalar(["m"], default: 1)
        guard multiplier > 0 else { throw invalid("m", "Multiplicity must be positive") }
        let flag = try scalar(["noisy", "noise"], default: policy.defaultNoisy ? 1 : 0)
        guard flag == 0 || flag == 1 else { throw invalid("noisy", "Noise flag must be zero or one") }
        let temperature = context.operatingConditions.temperatureKelvin
        func factor(nominal: Double) throws -> Double {
            let difference = temperature - nominal
            let factor = (tc2 * difference + tc1) * difference + 1
            guard difference.isFinite, factor.isFinite, factor > 0 else {
                throw invalid("temperatureFactor", "Runtime temperature factor must be finite and positive")
            }
            return factor
        }
        self.mainFactor = try factor(nominal: 300.15)
        // Disabled noise does not admit or consume the reference's auxiliary thermal law.
        self.auxiliaryFactor = flag == 1 ? try factor(nominal: context.operatingConditions.nominalTemperatureKelvin) : 1
        self.temperatureKelvin = temperature
        self.multiplier = multiplier
        self.noisy = flag == 1
        let nodes = try policy.admit(expression, device: instance.name)
        guard instance.referencedBranches.count <= policy.maxDependencies else {
            throw invalid("runtimePolicy", "Branch reference storage exceeds dependency ceiling")
        }
        let evaluator = try BehavioralExpressionEvaluator(expression: expression, instance: instance,
            context: context, dependencyLimit: policy.maxDependencies)
        var indices = Set(evaluator.dependencyIndices)
        func terminal(_ node: Node) throws -> Int? {
            if node == .ground { return nil }
            guard let index = context.nodeIndex(node), index >= 0, index < context.matrixDimension else {
                throw invalid("nodes", "Resistor terminal is absent from the compiled topology")
            }
            indices.insert(index)
            return index
        }
        let positive = try terminal(instance.nodes[0])
        let negative = try terminal(instance.nodes[1])
        try policy.admitWork(nodes: nodes, dependencies: indices.count, device: instance.name)
        let dependencies = indices.sorted()
        self.dependencies = dependencies
        self.positiveStamps = dependencies.map { column in positive.flatMap { context.stampIndex(row: $0, col: column) } }
        self.negativeStamps = dependencies.map { column in negative.flatMap { context.stampIndex(row: $0, col: column) } }
        self.positiveIndex = positive
        self.negativeIndex = negative
        self.evaluator = evaluator
        self.instance = instance
    }

    private func invalid(_ name: String, _ message: String) -> DeviceBindingError {
        .invalidParameterValue(device: instance.name, parameter: name, message: message)
    }

    private func resistance(state: SolutionState, time: Double, variable: Int? = nil) throws -> BehavioralExpressionEvaluator.Evaluation {
        let result = try evaluator.evaluateChecked(state: state, time: time, differentiating: variable)
        guard result.value > 0 else { throw invalid("r", "Runtime resistance must be positive") }
        return result
    }

    private func terminalVoltage(state: SolutionState) throws -> Double {
        let positive = try positiveIndex.map { try state.checkedBoundValue(at: $0, for: .nodeVoltage(instance.nodes[0])) } ?? 0
        let negative = try negativeIndex.map { try state.checkedBoundValue(at: $0, for: .nodeVoltage(instance.nodes[1])) } ?? 0
        let voltage = positive - negative
        guard positive.isFinite, negative.isFinite, voltage.isFinite else {
            throw invalid("voltage", "Runtime terminal voltage must be finite")
        }
        return voltage
    }

    private func current(state: SolutionState, time: Double, variable: Int? = nil) throws -> BehavioralExpressionEvaluator.Evaluation {
        let resistance = try resistance(state: state, time: time, variable: variable)
        let voltage = try terminalVoltage(state: state)
        let denominator = resistance.value * mainFactor
        guard voltage.isFinite, denominator.isFinite, denominator > 0 else {
            throw invalid("r", "Effective resistance or terminal voltage overflow")
        }
        let conductance = multiplier / denominator
        let value = conductance * voltage
        var voltageDerivative = 0.0
        if let variable {
            if positiveIndex == variable { voltageDerivative += 1 }
            if negativeIndex == variable { voltageDerivative -= 1 }
        }
        let derivative = variable == nil ? 0
            : conductance * voltageDerivative - value * (resistance.derivative / resistance.value)
        guard conductance.isFinite, conductance > 0, value.isFinite, derivative.isFinite else {
            throw invalid("current", "Runtime current or derivative is outside its finite domain")
        }
        return .init(value: value, derivative: derivative)
    }

    public func stampDC(into stamper: inout MatrixStamper, state: SolutionState) throws {
        try stamp(into: &stamper, state: state, time: 0)
    }

    public func stampTransient(into stamper: inout MatrixStamper, state: SolutionState, integration: IntegrationState) throws {
        try stamp(into: &stamper, state: state, time: integration.currentTime)
    }

    private func stamp(into stamper: inout MatrixStamper, state: SolutionState, time: Double) throws {
        try evaluator.validateState(state)
        var equivalent = try current(state: state, time: time).value
        for (offset, dependency) in dependencies.enumerated() {
            let derivative = try current(state: state, time: time, variable: dependency).derivative
            let correction = derivative * (try state.checkedValue(at: dependency))
            equivalent -= correction
            guard correction.isFinite, equivalent.isFinite else { throw invalid("equivalentCurrent", "Linearized current overflow") }
            if let row = positiveIndex {
                if let stamp = positiveStamps[offset], let direct = stamper.stampValue { direct(stamp, derivative) }
                else { stamper.stampMatrix(row, dependency, derivative) }
            }
            if let row = negativeIndex {
                if let stamp = negativeStamps[offset], let direct = stamper.stampValue { direct(stamp, -derivative) }
                else { stamper.stampMatrix(row, dependency, -derivative) }
            }
        }
        if let positiveIndex { stamper.stampRHS(positiveIndex, -equivalent) }
        if let negativeIndex { stamper.stampRHS(negativeIndex, equivalent) }
    }

    public func stampAC(into stamper: inout ComplexMatrixStamper, state: SolutionState, omega: Double) throws {
        try evaluator.validateState(state)
        _ = try current(state: state, time: 0)
        for dependency in dependencies {
            let derivative = try current(state: state, time: 0, variable: dependency).derivative
            if let positiveIndex { stamper.stampMatrix(positiveIndex, dependency, derivative, 0) }
            if let negativeIndex { stamper.stampMatrix(negativeIndex, dependency, -derivative, 0) }
        }
    }

    public func checkConvergence(state: SolutionState, previousState: SolutionState) -> ConvergenceResult {
        // The solver owns the physical residual at the actual analysis time.
        .converged
    }

    public func noiseContributions(state: SolutionState, frequency: Double) throws -> [NoiseSource] {
        guard noisy else { return [] }
        guard frequency.isFinite, frequency > 0 else { throw invalid("frequency", "Noise frequency must be finite and positive") }
        try evaluator.validateState(state)
        _ = try terminalVoltage(state: state)
        let resistance = try resistance(state: state, time: 0).value
        let denominator = resistance * auxiliaryFactor
        let spectrum = 4 * 1.380649e-23 * temperatureKelvin / denominator
        guard denominator.isFinite, denominator > 0, spectrum.isFinite, spectrum >= 0 else {
            throw invalid("thermalNoise", "Runtime thermal spectrum is outside the finite nonnegative domain")
        }
        return [NoiseSource(name: "\(instance.name)_thermal", positiveNode: instance.nodes[0],
            negativeNode: instance.nodes[1], currentSpectralDensity: spectrum)]
    }
}
