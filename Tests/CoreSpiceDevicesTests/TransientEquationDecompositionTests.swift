import CoreSpiceIR
import Foundation
import Testing
@testable import CoreSpiceDevices

@Suite("Original transient equation decomposition", .timeLimit(.minutes(1)))
struct TransientEquationDecompositionTests {
    private let positive = Node(id: 1), negative = Node(id: 2), branch = Branch(id: 0)
    private var map: [MNAVariable: Int] {
        [.nodeVoltage(positive): 0, .nodeVoltage(negative): 1, .branchCurrent(branch): 2]
    }
    private struct Terms {
        var f = [Double](repeating: 0, count: 3)
        var q = [Double](repeating: 0, count: 3)
        var differential = [Double](repeating: 0, count: 3)
        var correction = [Double](repeating: 0, count: 3)
        mutating func add(_ row: Int, _ kind: TransientPhysicalEquationTerm, _ value: Double) {
            switch kind {
            case .staticResidual: f[row] += value
            case .chargeDifference: q[row] += value
            case .differentialIncrement: differential[row] += value
            case .differentialHistoryCorrection: correction[row] += value
            }
        }
    }
    private func bind(_ type: String, _ parameters: [String: ParameterValue]) throws -> any BoundDevice {
        var context = BindingContext(variableMap: map, matrixDimension: 3)
        let instance = Instance(name: type, typeName: type, nodes: [positive, negative], parameters: parameters,
            ownedBranches: type == "inductor" || type == "vsource" ? [branch] : [])
        switch type {
        case "resistor": return try ResistorDescriptor().bind(instance: instance, context: &context)
        case "vsource": return try VoltageSourceDescriptor().bind(instance: instance, context: &context)
        case "isource": return try CurrentSourceDescriptor().bind(instance: instance, context: &context)
        case "capacitor": return try CapacitorDescriptor().bind(instance: instance, context: &context)
        case "inductor": return try InductorDescriptor().bind(instance: instance, context: &context)
        default: throw DeviceBindingError.invalidParameterValue(device: type, parameter: "fixture", message: "Unknown fixture device")
        }
    }
    private func state(_ x: [Double], previous: [Double]? = nil, low: [Double]? = nil) -> SolutionState {
        SolutionState(variables: x, previousVariables: previous, variableMap: map, variableLowComponents: low)
    }
    private func terms(_ device: any BoundDevice, _ input: SolutionState, _ integration: IntegrationState) throws -> Terms {
        let original = try #require(device as? any TransientPhysicalEquationDecomposing)
        try original.validateTransientPhysicalEquationDecomposition()
        var result = Terms()
        try original.accumulateTransientPhysicalEquation(state: input, integration: integration) { result.add($0, $1, $2) }
        return result
    }

    @Test
    func resistorAndSourcesUseActualStaticEquationAndTime() throws {
        let input = state([3, 1, 0.5])
        let integration = IntegrationState(method: .trapezoidal, timeStep: 0.25, currentTime: 0.5)
        let resistor = try bind("resistor", ["r": .real(8)])
        let r = try terms(resistor, input, integration)
        #expect(r.f == [0.25, -0.25, 0]); #expect(r.q == [0, 0, 0])
        for type in ["vsource", "isource"] {
            let bound = try bind(type, ["pwl": .realVector([0, 1, 1, 3])])
            let original = try #require(bound as? any TransientPhysicalEquationDecomposing)
            var initial = [Double](repeating: 0, count: 3)
            try original.accumulateTransientStaticResidual(state: input, time: 0) { initial[$0] += $1 }
            let trial = try terms(bound, input, integration)
            #expect(initial == (type == "vsource" ? [0.5, -0.5, 1] : [1, -1, 0]))
            #expect(trial.f == (type == "vsource" ? [0.5, -0.5, 0] : [2, -2, 0]))
            #expect(trial.q == [0, 0, 0])
        }
    }

    @Test
    func conservativeReactiveTermsExcludeAcceptedDerivative() throws {
        let initial = [1.0, 0, 1], first = [2.0, 0, 2], next = [3.0, 0, 3]
        let be = IntegrationState(method: .backwardEuler, timeStep: 0.25, currentTime: 0.25)
        let tr = IntegrationState(method: .trapezoidal, timeStep: 0.5, currentTime: 0.75)
        for type in ["capacitor", "inductor"] {
            let bound = try bind(type, [type == "capacitor" ? "c" : "l": .real(2)])
            let session = try #require(bound as? any TransientSessionDevice)
            try session.beginTransientSession(initialState: state(initial))
            defer { session.endTransientSession() }
            try session.commitTransientStep(state: state(first, previous: initial), integration: be)
            let candidate = state(next, previous: first)
            let trial = try terms(bound, candidate, tr)
            if type == "capacitor" {
                #expect(trial.f == [0, 0, 0]); #expect(trial.q == [8, -8, 0])
            } else {
                #expect(trial.f == [3, -3, 3]); #expect(trial.q == [0, 0, -8])
            }
            let repeated = try terms(bound, candidate, tr)
            #expect(repeated.f == trial.f && repeated.q == trial.q)
        }
    }

    @Test
    func pairedStaticTermsRetainRepresentedCoordinates() throws {
        let integration = IntegrationState(method: .backwardEuler, timeStep: 1, currentTime: 0.5)
        let input = state([0.5, 0.5, 1], low: [0x1p-56, 0, 0x1p-56])
        for type in ["resistor", "vsource", "isource"] {
            let parameters: [String: ParameterValue] = type == "resistor"
                ? ["r": .real(8)] : ["pwl": .realVector([0, 1, 1, 3])]
            let bound = try bind(type, parameters)
            let original = try #require(bound as? any TransientPhysicalEquationEnclosureDecomposing)
            try original.validateTransientPhysicalEquationDecomposition()
            var terms: [(Int, CompensatedValue, Double)] = []
            try original.accumulateTransientPhysicalEquationEnclosure(state: input, integration: integration) {
                #expect($1 == .staticResidual)
                terms.append(($0, $2, $3))
            }
            let positive = try #require(terms.first { $0.0 == 0 })
            if type == "resistor" { #expect(positive.1.high == 0x1p-59) }
            else if type == "vsource" {
                #expect(positive.1.high == 1 && positive.1.low == 0x1p-56)
                let branchTerm = try #require(terms.first { $0.0 == 2 })
                #expect(branchTerm.1.high == -2 && branchTerm.1.low == 0x1p-56)
            } else { #expect(positive.1.high == 2 && positive.1.low == 0) }
        }
    }

    @Test
    func pairedChargeDifferencePreservesSubULPInputAndSignedInductorCharge() throws {
        let integration = IntegrationState(method: .trapezoidal, timeStep: 0x1p-53, currentTime: 1)
        for type in ["capacitor", "inductor"] {
            let bound = try bind(type, [type == "capacitor" ? "c" : "l": .real(0x1p-37)])
            let original = try #require(bound as? any TransientPhysicalEquationEnclosureDecomposing)
            let input = state([0.5, 0, 0.5], previous: [0.5, 0, 0.5], low: [0x1p-56, 0, 0x1p-56])
            var values: [(Int, CompensatedValue, Double)] = []
            try original.accumulateTransientPhysicalEquationEnclosure(state: input, integration: integration) {
                if $1 == .chargeDifference { values.append(($0, $2, $3)) }
            }
            let row = type == "capacitor" ? 0 : 2
            let term = try #require(values.first { $0.0 == row })
            #expect(term.1.high == (type == "capacitor" ? 0x1p-39 : -0x1p-39))
            #expect(term.1.low == 0); #expect(term.2 < 1e-25)
        }
    }

    @Test(arguments: [false, true])
    func behavioralChargeAndDifferentialCoefficientHistoryRemainDistinct(differential: Bool) throws {
        let voltage = BehavioralExpression.variable(.nodeVoltage(positive: positive, negative: negative))
        let expression: BehavioralExpression = differential
            ? .binary(.add, .constant(2), .binary(.power, voltage, .constant(2)))
            : .binary(.add, .binary(.multiply, .constant(2), voltage), .binary(.power, voltage, .constant(3)))
        let bound = try bind("capacitor", [differential ? "c" : "q": .behavioralExpression(expression)])
        let original = try #require(bound as? any TransientPhysicalEquationDecomposing)
        #expect(original.transientPhysicalEquationForm == (differential ? .differentialCapacitance : .chargeDifference))
        #expect(!(bound is any TransientPhysicalEquationEnclosureDecomposing))
        let session = try #require(bound as? any TransientSessionDevice)
        let initial = [1.0, 0, 0], first = [2.0, 0, 0], next = [3.0, 0, 0]
        try session.beginTransientSession(initialState: state(initial))
        defer { session.endTransientSession() }
        let be = IntegrationState(method: .backwardEuler, timeStep: 0.25, currentTime: 0.25)
        try session.commitTransientStep(state: state(first, previous: initial), integration: be)
        let tr = IntegrationState(method: .trapezoidal, timeStep: 0.5, currentTime: 0.75)
        let candidate = state(next, previous: first)
        let result = try terms(bound, candidate, tr)
        #expect(result.f == [0, 0, 0])
        if differential {
            // Cprev=6, Cn=11, Dprev=4. Conservative Q=C*V would incorrectly give 84.
            #expect(result.q == [0, 0, 0]); #expect(result.differential == [44, -44, 0])
            #expect(result.correction == [-20, 20, 0])
            #expect(result.differential[0] + result.correction[0] - 24 == 0)
        } else {
            // Q(1)=3, Q(2)=12, Q(3)=33; the prior BE derivative is 36.
            #expect(result.q == [84, -84, 0]); #expect(result.differential == [0, 0, 0])
            #expect(result.correction == [0, 0, 0])
        }
        do {
            _ = try terms(bound, state([1e308, 0, 0], previous: first), tr)
            Issue.record("Overflowing constitutive trial unexpectedly succeeded")
        } catch is DeviceBindingError { }
        let repeated = try terms(bound, candidate, tr)
        #expect(repeated.q == result.q && repeated.differential == result.differential && repeated.correction == result.correction)
    }

    @Test
    func acceptedDifferentialCoefficientRejectsStaleOrInvalidPublication() throws {
        let history = BehavioralCapacitorHistory()
        try history.begin(coordinate: 1, capacitance: 3, device: "C")
        let first = history.snapshot
        try history.commit(coordinate: 2, derivative: 4, capacitance: 6, time: 0.25,
            generation: first.generation, device: "C")
        let accepted = history.snapshot
        for invalid in [false, true] {
            do {
                try history.commit(coordinate: 3, derivative: 8, capacitance: invalid ? .infinity : 11, time: 0.75,
                    generation: invalid ? accepted.generation : first.generation, device: "C")
                Issue.record("Invalid or stale accepted coefficient publication succeeded")
            } catch is DeviceBindingError { }
            let actual = history.snapshot
            #expect(actual.coordinate == 2 && actual.derivative == 4 && actual.capacitance == 6)
            #expect(actual.time == 0.25 && actual.generation == accepted.generation)
        }
        history.end()
        try history.begin(coordinate: 7, capacitance: 51, device: "C")
        do {
            try history.commit(coordinate: 3, derivative: 8, capacitance: 11, time: 0.75,
                generation: accepted.generation, device: "C")
            Issue.record("Previous-session coefficient publication succeeded")
        } catch is DeviceBindingError { }
        #expect(history.snapshot.capacitance == 51)
        history.end()
    }
}
