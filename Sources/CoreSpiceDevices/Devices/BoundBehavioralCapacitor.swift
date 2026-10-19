import CoreSpiceIR
import Foundation

/// Bounded original charge-expression or differential-capacitance law with accepted history.
public struct BoundBehavioralCapacitor: BoundDevice, VoltageInitialConditionDevice,
    TransientSessionDevice, DCPhysicalResidualContributing, TransientPhysicalResidualContributing, Sendable {
    enum Law: Sendable { case charge, differentialCapacitance }
    public let instance: Instance
    public let initialVoltage: Double
    public let hasInitialCondition: Bool
    public var positiveNode: Node { instance.nodes[0] }
    public var negativeNode: Node { instance.nodes[1] }
    public var poleZeroStampApplicability: PoleZeroStampApplicability {
        timeDependent ? .unsupported(reason: "An explicitly time-dependent capacitor is not an LTI pole-zero realization") : .affine
    }
    private let law: Law
    private let evaluator: BehavioralExpressionEvaluator
    private let positiveIndex: Int?
    private let negativeIndex: Int?
    private let dependencies: [Int]
    private let positiveStamps: [Int?]
    private let negativeStamps: [Int?]
    private let scale: Double
    private let timeDependent: Bool
    private let history = BehavioralCapacitorHistory()

    init(instance: Instance, expression: BehavioralExpression, law: Law,
         context: BindingContext, policy: RuntimeCapacitorPolicy) throws {
        func invalid(_ key: String, _ message: String) -> DeviceBindingError {
            .invalidParameterValue(device: instance.name, parameter: key, message: message)
        }
        guard instance.model == nil else { throw invalid("model", "Behavioral capacitor cannot discard a referenced model") }
        let expressionKey = law == .charge ? "q" : "c"
        let supported = CapacitorDescriptor.behavioralInstanceParameterNames.union([expressionKey])
        for key in instance.parameters.keys.sorted() where !supported.contains(key) {
            throw invalid(key, "Parameter is outside the admitted behavioral capacitor profile")
        }
        func scalar(_ names: [String], default defaultValue: Double) throws -> Double {
            var result: Double?
            for name in names {
                guard let value = instance.parameters[name] else { continue }
                guard case .real(let number) = value else {
                    throw DeviceBindingError.invalidParameterType(device: instance.name, parameter: name, expected: "real")
                }
                guard number.isFinite else { throw invalid(name, "Parameter must be finite") }
                if let result, result != number { throw invalid(name, "Conflicting capacitor parameter aliases") }
                result = number
            }
            return result ?? defaultValue
        }
        let multiplier = try scalar(["m"], default: 1)
        let tc1 = try scalar(["tc", "tc1"], default: 0), tc2 = try scalar(["tc2"], default: 0)
        let difference = context.operatingConditions.temperatureKelvin - 300.15
        let factor = 1 + tc1 * difference + tc2 * difference * difference
        let scale = multiplier / factor
        guard multiplier > 0, factor.isFinite, factor > 0, scale.isFinite, scale > 0 else {
            throw invalid("m/temperature", "Behavioral capacitor multiplicity and reciprocal temperature factor must be finite and positive")
        }
        let admitted = try policy.admit(expression, device: instance.name)
        guard instance.referencedBranches.count <= policy.maxDependencies else {
            throw invalid("runtimePolicy", "Branch reference storage exceeds dependency ceiling")
        }
        let evaluator = try BehavioralExpressionEvaluator(expression: expression, instance: instance,
            context: context, dependencyLimit: policy.maxDependencies)
        var indices = Set(evaluator.dependencyIndices)
        func terminal(_ node: Node) throws -> Int? {
            if node == .ground { return nil }
            guard let index = context.nodeIndex(node), (0..<context.matrixDimension).contains(index) else {
                throw invalid("nodes", "Capacitor terminal is absent from the compiled topology")
            }
            indices.insert(index)
            return index
        }
        let positive = try terminal(instance.nodes[0]), negative = try terminal(instance.nodes[1])
        try policy.admitWork(nodes: admitted.nodes, dependencies: indices.count, device: instance.name)
        let dependencies = indices.sorted()
        func stamps(_ row: Int?) throws -> [Int?] {
            try dependencies.map { column in
                guard let row else { return nil }
                let index = context.stampIndex(row: row, col: column)
                guard !context.hasStampIndexResolver || index != nil else {
                    throw invalid("matrix", "Compiled capacitor dependency stamp is absent")
                }
                return index
            }
        }
        self.positiveStamps = try stamps(positive); self.negativeStamps = try stamps(negative)
        self.instance = instance; self.law = law; self.evaluator = evaluator
        self.dependencies = dependencies; self.positiveIndex = positive; self.negativeIndex = negative
        self.scale = scale; self.timeDependent = admitted.timeDependent
        self.initialVoltage = try scalar(["ic"], default: 0)
        self.hasInitialCondition = instance.parameters["ic"] != nil
    }

    private func invalid(_ key: String, _ message: String) -> DeviceBindingError {
        .invalidParameterValue(device: instance.name, parameter: key, message: message)
    }
    private func voltage(_ state: SolutionState) throws -> Double {
        let p = try positiveIndex.map { try state.checkedBoundValue(at: $0, for: .nodeVoltage(positiveNode)) } ?? 0
        let n = try negativeIndex.map { try state.checkedBoundValue(at: $0, for: .nodeVoltage(negativeNode)) } ?? 0
        let value = p - n
        guard value.isFinite else { throw invalid("voltage", "Capacitor terminal voltage must be finite") }
        return value
    }
    private func expression(_ state: SolutionState, time: Double, variable: Int? = nil) throws
        -> BehavioralExpressionEvaluator.Evaluation {
        let result = try evaluator.evaluateChecked(state: state, time: time, differentiating: variable)
        let value = scale * result.value, derivative = scale * result.derivative
        guard value.isFinite, derivative.isFinite, law != .differentialCapacitance || value > 0 else {
            throw invalid("expression", "Capacitor expression or derivative is outside its admitted finite passive domain")
        }
        return .init(value: value, derivative: derivative)
    }
    private func coordinate(_ state: SolutionState, time: Double) throws -> Double {
        law == .charge ? try expression(state, time: time).value : try voltage(state)
    }
    private func checkedHistory(_ integration: IntegrationState) throws -> BehavioralCapacitorHistory.State {
        let snapshot = history.snapshot
        guard snapshot.active else { throw invalid("transientSession", "Capacitor requires an active transient session") }
        let time = integration.currentTime, step = integration.timeStep
        let rounding = 4 * max(time.ulp, snapshot.time.ulp)
        guard time.isFinite, step.isFinite, step > 0, time > snapshot.time,
              integration.coefficient.isFinite,
              abs((time - snapshot.time) - step) <= rounding else {
            throw invalid("timeStep", "Capacitor candidate time does not advance its accepted history by the supplied finite positive step")
        }
        return snapshot
    }
    private func derivative(_ coordinate: Double, old: BehavioralCapacitorHistory.State,
        integration: IntegrationState) throws -> Double {
        let value = try unadjustedDerivative(coordinate, old: old, integration: integration)
            - (integration.method == .trapezoidal ? old.derivative : 0)
        guard value.isFinite else { throw invalid("derivative", "Capacitor integrated derivative overflow") }
        return value
    }
    private func unadjustedDerivative(_ coordinate: Double, old: BehavioralCapacitorHistory.State,
        integration: IntegrationState) throws -> Double {
        let value = integration.coefficient * (coordinate - old.coordinate)
        guard value.isFinite else { throw invalid("derivative", "Capacitor original increment overflow") }
        return value
    }

    public func stampDC(into stamper: inout MatrixStamper, state: SolutionState) throws {
        try evaluator.validateState(state); _ = try voltage(state); _ = try expression(state, time: 0)
    }
    public func stampAC(into stamper: inout ComplexMatrixStamper, state: SolutionState, omega: Double) throws {
        guard !timeDependent else { throw invalid("analysis", "Explicitly time-dependent capacitor requires transient analysis") }
        guard omega.isFinite else { throw invalid("omega", "Capacitor frequency must be finite") }
        try evaluator.validateState(state); _ = try voltage(state)
        let value = try expression(state, time: 0).value
        for dependency in dependencies {
            let gradient: Double
            if law == .charge { gradient = try expression(state, time: 0, variable: dependency).derivative }
            else { gradient = value * terminalDerivative(dependency) }
            let susceptance = omega * gradient
            guard susceptance.isFinite else { throw invalid("admittance", "Capacitor AC admittance overflow") }
            if let positiveIndex { stamper.stampMatrix(positiveIndex, dependency, 0, susceptance) }
            if let negativeIndex { stamper.stampMatrix(negativeIndex, dependency, 0, -susceptance) }
        }
    }
    private func terminalDerivative(_ dependency: Int) -> Double {
        (positiveIndex == dependency ? 1 : 0) - (negativeIndex == dependency ? 1 : 0)
    }
    public func stampTransient(into stamper: inout MatrixStamper, state: SolutionState,
        integration: IntegrationState) throws {
        try evaluator.validateState(state); _ = try voltage(state)
        let old = try checkedHistory(integration)
        let coordinate = try coordinate(state, time: integration.currentTime)
        let rate = try derivative(coordinate, old: old, integration: integration)
        let expressionValue = law == .charge ? 0 : try expression(state, time: integration.currentTime).value
        let current = law == .charge ? rate : expressionValue * rate
        guard current.isFinite else { throw invalid("current", "Capacitor current overflow") }
        var equivalent = current
        for (offset, dependency) in dependencies.enumerated() {
            let expressionGradient = try expression(state, time: integration.currentTime, variable: dependency).derivative
            let gradient = law == .charge ? integration.coefficient * expressionGradient
                : expressionValue * integration.coefficient * terminalDerivative(dependency) + rate * expressionGradient
            let correction = gradient * (try state.checkedValue(at: dependency))
            equivalent -= correction
            guard gradient.isFinite, correction.isFinite, equivalent.isFinite else {
                throw invalid("linearization", "Capacitor complete Newton linearization overflow")
            }
            if let row = positiveIndex {
                if let csr = positiveStamps[offset], let sv = stamper.stampValue { sv(csr, gradient) }
                else { stamper.stampMatrix(row, dependency, gradient) }
            }
            if let row = negativeIndex {
                if let csr = negativeStamps[offset], let sv = stamper.stampValue { sv(csr, -gradient) }
                else { stamper.stampMatrix(row, dependency, -gradient) }
            }
        }
        if let positiveIndex { stamper.stampRHS(positiveIndex, -equivalent) }
        if let negativeIndex { stamper.stampRHS(negativeIndex, equivalent) }
    }

    public func beginTransientSession(initialState: SolutionState) throws {
        try evaluator.validateState(initialState); _ = try voltage(initialState)
        let initialExpression = try expression(initialState, time: 0).value
        let initialCoordinate = law == .charge ? initialExpression : try voltage(initialState)
        try history.begin(coordinate: initialCoordinate,
            capacitance: law == .differentialCapacitance ? initialExpression : nil, device: instance.name)
    }
    public func endTransientSession() { history.end() }
    public func commitTransientStep(state: SolutionState, integration: IntegrationState) throws {
        try evaluator.validateState(state); _ = try voltage(state)
        let old = try checkedHistory(integration)
        let coordinate = try coordinate(state, time: integration.currentTime)
        let rate = try derivative(coordinate, old: old, integration: integration)
        let expressionValue = law == .charge ? 0 : try expression(state, time: integration.currentTime).value
        guard (law == .charge ? rate : expressionValue * rate).isFinite else {
            throw invalid("current", "Capacitor accepted physical current overflow")
        }
        try history.commit(coordinate: coordinate, derivative: rate,
            capacitance: law == .differentialCapacitance ? expressionValue : nil, time: integration.currentTime,
            generation: old.generation, device: instance.name)
    }
    public func accumulatePhysicalResidual(state: SolutionState, add: (Int, Double) -> Void) throws {
        try evaluator.validateState(state); _ = try voltage(state); _ = try expression(state, time: 0)
    }
    public func accumulateTransientPhysicalResidual(state: SolutionState, integration: IntegrationState,
        add: (Int, Double) -> Void) throws {
        try evaluator.validateState(state); _ = try voltage(state)
        let old = try checkedHistory(integration)
        let rate = try derivative(coordinate(state, time: integration.currentTime), old: old, integration: integration)
        let value = law == .charge ? 0 : try expression(state, time: integration.currentTime).value
        let current = law == .charge ? rate : value * rate
        guard current.isFinite else { throw invalid("current", "Capacitor physical current overflow") }
        if let positiveIndex { add(positiveIndex, current) }
        if let negativeIndex { add(negativeIndex, -current) }
    }
    public func checkConvergence(state: SolutionState, previousState: SolutionState) -> ConvergenceResult { .converged }
}

extension BoundBehavioralCapacitor: TransientPhysicalEquationDecomposing {
    public var transientPhysicalEquationForm: TransientPhysicalEquationForm {
        law == .charge ? .chargeDifference : .differentialCapacitance
    }
    public func validateTransientPhysicalEquationDecomposition() throws {
        // Binding admits both explicit Q and differential C; their terms remain distinct.
    }
    public func accumulateTransientStaticResidual(state: SolutionState, time: Double,
        add: (Int, Double) -> Void) throws {
        try PhysicalResidualState.validate(time)
        try evaluator.validateState(state); _ = try voltage(state); _ = try expression(state, time: time)
        // Both admitted capacitor laws have identically zero static F.
    }
    public func accumulateTransientPhysicalEquation(state: SolutionState, integration: IntegrationState,
        add: (Int, TransientPhysicalEquationTerm, Double) -> Void) throws {
        try evaluator.validateState(state); _ = try voltage(state)
        let old = try checkedHistory(integration)
        let candidate = try coordinate(state, time: integration.currentTime)
        let difference = try unadjustedDerivative(candidate, old: old, integration: integration)
        let increment: Double
        let correction: Double
        if law == .charge {
            guard old.capacitance == nil else { throw invalid("transientSession", "Charge-law history contains a differential coefficient") }
            increment = difference; correction = 0
        } else {
            guard let acceptedCapacitance = old.capacitance else {
                throw invalid("transientSession", "Differential law requires its actual accepted coefficient")
            }
            let candidateCapacitance = try expression(state, time: integration.currentTime).value
            increment = candidateCapacitance * difference
            correction = integration.method == .trapezoidal ? (acceptedCapacitance - candidateCapacitance) * old.derivative : 0
        }
        guard increment.isFinite, correction.isFinite else { throw invalid("current", "Capacitor original constitutive terms overflow") }
        let kind: TransientPhysicalEquationTerm = law == .charge ? .chargeDifference : .differentialIncrement
        if let positiveIndex { add(positiveIndex, kind, increment) }
        if let negativeIndex { add(negativeIndex, kind, -increment) }
        if law == .differentialCapacitance, integration.method == .trapezoidal {
            if let positiveIndex { add(positiveIndex, .differentialHistoryCorrection, correction) }
            if let negativeIndex { add(negativeIndex, .differentialHistoryCorrection, -correction) }
        }
    }
}
