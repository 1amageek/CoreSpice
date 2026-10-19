import CoreSpiceIR
import Foundation
import Synchronization
import Testing
@testable import CoreSpiceDevices

private final class BJTPhysicalStamps: Sendable {
    let dimension: Int
    private let values: Mutex<([Double], [Double], [Double])>
    init(_ dimension: Int) {
        self.dimension = dimension
        values = Mutex((Array(repeating: 0, count: dimension * dimension),
            Array(repeating: 0, count: dimension * dimension), Array(repeating: 0, count: dimension)))
    }
    func real(_ r: Int, _ c: Int, _ v: Double) { values.withLock { $0.0[r * dimension + c] += v } }
    func complex(_ r: Int, _ c: Int, _ x: Double, _ y: Double) {
        values.withLock { $0.0[r * dimension + c] += x; $0.1[r * dimension + c] += y }
    }
    func rhs(_ r: Int, _ v: Double) { values.withLock { $0.2[r] += v } }
    func csr(_ i: Int, _ v: Double) { values.withLock { $0.0[i] += v } }
    var matrix: [Double] { values.withLock { $0.0 } }
    var imaginary: [Double] { values.withLock { $0.1 } }
    func residual(_ x: [Double]) -> [Double] {
        values.withLock { data in (0..<dimension).map { r in
            (0..<dimension).reduce(-data.2[r]) { $0 + data.0[r * dimension + $1] * x[$1] }
        } }
    }
}

@Suite("BJT physical parameter ownership", .timeLimit(.minutes(1)))
struct BJTPhysicalParameterOwnershipTests {
    private let k = 1.38064852e-23, charge = 1.6021766208e-19
    private let parameters: [String: ParameterValue] = ["is": .real(1e-15), "bf": .real(80), "br": .real(3),
        "vaf": .real(60), "var": .real(20), "cje": .real(1e-12), "cjc": .real(2e-12),
        "tf": .real(3e-9), "tr": .real(2e-9)]

    // Independent closed-form SPICE3 subset; derivatives below use symmetric numerical differences.
    private func reference(_ voltages: [Double], sign: Double, series: Bool) -> (current: [Double], charge: [Double]) {
        let offset = series ? 3 : 0
        let u = sign * (voltages[offset + 1] - voltages[offset + 2])
        let v = sign * (voltages[offset + 1] - voltages[offset])
        let thermal = k * 300.15 / charge
        func diode(_ voltage: Double) -> Double {
            if voltage >= -3 * thermal { return 1e-15 * expm1(voltage / thermal) }
            return -1e-15 * (1 + pow(3 * thermal / (voltage * exp(1.0)), 3))
        }
        let f = diode(u), r = diode(v), width = 1 - v / 60 - u / 20
        let ic = (f - r) * width - r / 3
        let ib = f / 80 + r / 3
        func depletion(_ voltage: Double, _ capacitance: Double) -> Double {
            let potential = 0.75, grading = 0.33, boundary = 0.375
            if voltage < boundary {
                return potential * capacitance / (1 - grading) * (1 - pow(1 - voltage / potential, 1 - grading))
            }
            let baseline = potential * capacitance / (1 - grading) * (1 - pow(0.5, 1 - grading))
            let c = capacitance * pow(2, grading), d = voltage - boundary
            return baseline + c * d + grading * c / potential * d * d
        }
        let qbe = depletion(u, 1e-12) + 3e-9 * f * (u > 0 ? width : 1)
        let qbc = depletion(v, 2e-12) + 2e-9 * r
        var currents = Array(repeating: 0.0, count: voltages.count)
        var charges = currents
        currents[offset] = sign * ic; currents[offset + 1] = sign * ib; currents[offset + 2] = -sign * (ic + ib)
        charges[offset] = -sign * qbc; charges[offset + 1] = sign * (qbe + qbc); charges[offset + 2] = -sign * qbe
        if series {
            for (terminal, resistance) in [20.0, 100.0, 10.0].enumerated() {
                let i = (voltages[terminal] - voltages[terminal + 3]) / resistance
                currents[terminal] += i; currents[terminal + 3] -= i
            }
        }
        return (currents, charges)
    }

    private func fixture(sign: Double, withSeries: Bool, csr: Bool = false) throws
        -> (any BoundDevice, [MNAVariable: Int]) {
        let count = withSeries ? 6 : 3
        let nodes = (1...count).map { Node(id: $0) }
        let map = Dictionary(uniqueKeysWithValues: nodes.enumerated().map { (MNAVariable.nodeVoltage($0.element), $0.offset) })
        let resolver: (@Sendable (Int, Int) -> Int?)?
        if csr { resolver = { row, column in row * count + column } }
        else { resolver = nil }
        var context = BindingContext(variableMap: map, matrixDimension: count, stampIndexResolver: resolver)
        var inputs = parameters
        if withSeries { inputs["rc"] = .real(20); inputs["rb"] = .real(100); inputs["re"] = .real(10) }
        let instance = Instance(name: "Q", typeName: sign > 0 ? "npn" : "pnp", nodes: Array(nodes.prefix(3)),
            parameters: inputs, ownedNodes: withSeries ? Array(nodes.suffix(3)) : [])
        let bound = try (sign > 0 ? NPNDescriptor().bind(instance: instance, context: &context)
            : PNPDescriptor().bind(instance: instance, context: &context))
        return (bound, map)
    }

    @Test(arguments: [1.0, -1.0], [false, true])
    func currentsAndFullCurrentChargeJacobians(sign: Double, withSeries: Bool) throws {
        for csr in [false, true] {
            let (bound, map) = try fixture(sign: sign, withSeries: withSeries, csr: csr)
            for intrinsic in [[2.0, 0.62, 0.0], [0.0, 0.62, 2.0], [0.2, 0.62, 0.0], [2.0, 0.0, 0.5], [0.1, 0.5, 0.0]] {
                let x = (withSeries ? [intrinsic[0] + 0.02, intrinsic[1] + 0.01, intrinsic[2] - 0.01] + intrinsic : intrinsic).map { sign * $0 }
                let expected = reference(x, sign: sign, series: withSeries)
                let collector = BJTPhysicalStamps(x.count)
                var dc = MatrixStamper(variableMap: map, stampMatrix: collector.real,
                    stampRHS: collector.rhs, stampValue: collector.csr)
                let state = SolutionState(variables: x, variableMap: map)
                try bound.stampDC(into: &dc, state: state)
                let residual = collector.residual(x)
                for r in x.indices { #expect(abs(residual[r] - expected.current[r]) < 1e-12 + abs(expected.current[r]) * 1e-10) }
                #expect(abs(residual.reduce(0, +)) < 1e-12)
                let acValues = BJTPhysicalStamps(x.count)
                var ac = ComplexMatrixStamper(variableMap: map, stampMatrix: acValues.complex, stampRHS: { _, _, _ in })
                try bound.stampAC(into: &ac, state: state, omega: 2)
                for c in x.indices {
                    let h = 1e-6
                    var upper = x, lower = x; upper[c] += h; lower[c] -= h
                    let hi = reference(upper, sign: sign, series: withSeries), lo = reference(lower, sign: sign, series: withSeries)
                    for r in x.indices {
                        let position = r * x.count + c
                        let g = (hi.current[r] - lo.current[r]) / (2 * h)
                        let capacitance = (hi.charge[r] - lo.charge[r]) / (2 * h)
                        #expect(abs(collector.matrix[position] - g) < 2e-10 + abs(g) * 2e-7)
                        #expect(abs(acValues.matrix[position] - collector.matrix[position]) < 1e-14)
                        #expect(abs(acValues.imaginary[position] / 2 - capacitance) < 1e-20 + abs(capacitance) * 2e-7)
                    }
                }
            }
        }
    }

    @Test(arguments: [1.0, -1.0])
    func chargeHistoryUsesAcceptedChargeAndSessionReset(sign: Double) throws {
        let (bound, map) = try fixture(sign: sign, withSeries: true)
        let session = try #require(bound as? any TransientSessionDevice)
        let old = [1.0, 0.55, 0.0, 1.0, 0.55, 0.0].map { sign * $0 }
        let first = [1.0, 0.65, 0.0, 1.0, 0.65, 0.0].map { sign * $0 }
        let second = [0.1, 0.5, 0.0, 0.1, 0.5, 0.0].map { sign * $0 }
        try session.beginTransientSession(initialState: SolutionState(variables: old, variableMap: map))
        #expect(throws: DeviceBindingError.self) { try session.beginTransientSession(initialState: SolutionState(variables: old, variableMap: map)) }
        let be = IntegrationState(method: .backwardEuler, timeStep: 1e-8, currentTime: 1e-8)
        let firstState = SolutionState(variables: first, previousVariables: old, variableMap: map)
        let qOld = reference(old, sign: sign, series: true).charge
        let qFirst = reference(first, sign: sign, series: true).charge
        let firstI = zip(qFirst, qOld).map { ($0 - $1) / 1e-8 }
        try session.commitTransientStep(state: firstState, integration: be)
        let trap = IntegrationState(method: .trapezoidal, timeStep: 2e-8, currentTime: 3e-8)
        for candidate in [old, second, second] {
            let values = BJTPhysicalStamps(6)
            var stamp = MatrixStamper(variableMap: map, stampMatrix: values.real, stampRHS: values.rhs, stampValue: values.csr)
            try bound.stampTransient(into: &stamp,
                state: SolutionState(variables: candidate, previousVariables: first, variableMap: map), integration: trap)
            let expected = reference(candidate, sign: sign, series: true)
            let actual = values.residual(candidate)
            for r in 0..<6 {
                let current = expected.current[r] + (expected.charge[r] - qFirst[r]) * trap.coefficient - firstI[r]
                #expect(abs(actual[r] - current) < 1e-12 + abs(current) * 1e-10)
            }
        }
        session.endTransientSession()
        try session.beginTransientSession(initialState: SolutionState(variables: old, variableMap: map))
        defer { session.endTransientSession() }
        let values = BJTPhysicalStamps(6)
        var stamp = MatrixStamper(variableMap: map, stampMatrix: values.real, stampRHS: values.rhs)
        try bound.stampTransient(into: &stamp, state: firstState, integration: be)
        for r in 0..<6 {
            #expect(abs(values.residual(first)[r] - reference(first, sign: sign, series: true).current[r] - firstI[r]) < 1e-11)
        }
    }

    @Test(arguments: [1.0, -1.0])
    func seriesThermalNoiseUsesIntrinsicConnections(sign: Double) throws {
        let (bound, map) = try fixture(sign: sign, withSeries: true)
        let noisy = try #require(bound as? any NoisyDevice)
        let sources = try noisy.noiseContributions(state: SolutionState(variables: [2, 0.62, 0, 2, 0.62, 0].map { sign * $0 }, variableMap: map), frequency: 1000)
        let thermal = sources.filter { $0.name.contains("thermal") }
        #expect(thermal.count == 3)
        for (offset, resistance) in [20.0, 100.0, 10.0].enumerated() {
            let source = thermal[offset]
            #expect(source.positiveNode == Node(id: offset + 1))
            #expect(source.negativeNode == Node(id: offset + 4))
            #expect(abs(source.currentSpectralDensity / (4 * k * 300.15 / resistance) - 1) < 1e-14)
        }
        #expect(throws: DeviceBindingError.self) { try noisy.noiseContributions(state: SolutionState(variables: Array(repeating: 0, count: 6), variableMap: map), frequency: .infinity) }
    }

    @Test func temperatureUsesNominalRoleAndPhysicalJunctionCorrection() throws {
        let source = BJTModelParameters(forwardEarlyVoltage: 60, reverseEarlyVoltage: 20,
            baseEmitterCapacitance: 1e-12, baseCollectorCapacitance: 2e-12,
            nominalTemperature: 313.15, operatingTemperature: 353.15)
        let prepared = try BJTTemperaturePreparation.prepare(source, device: "Q")
        let ratio = 353.15 / 313.15
        let vt = k * 353.15 / charge
        let expectedIS = source.saturationCurrent * pow(ratio, 3) * exp(1.11 / vt * (ratio - 1))
        #expect(abs(prepared.saturationCurrent / expectedIS - 1) < 1e-14)
        #expect(prepared.baseEmitterPotential < source.baseEmitterPotential)
        #expect(prepared.baseEmitterCapacitance > source.baseEmitterCapacitance)
        #expect(prepared.forwardBeta == source.forwardBeta)
        #expect(prepared.reverseEarlyVoltage == source.reverseEarlyVoltage)
        let nodes = [Node(id: 1), Node(id: 2), Node(id: 3)]
        let map = Dictionary(uniqueKeysWithValues: nodes.enumerated().map { (MNAVariable.nodeVoltage($0.element), $0.offset) })
        var context = BindingContext(variableMap: map, matrixDimension: 3,
            operatingConditions: try OperatingConditions(temperatureKelvin: 353.15, nominalTemperatureKelvin: 323.15))
        let model = ResolvedDeviceModel(name: "QB", typeName: "npn", parameters: ["tnom_k": .real(333.15), "is": .real(1e-15)])
        let overridden = try NPNDescriptor().bind(instance: Instance(name: "Q", typeName: "npn", nodes: nodes,
            parameters: ["tnom": .real(40)], model: model), context: &context)
        let currents = BJTPhysicalStamps(3)
        var stamper = MatrixStamper(variableMap: map, stampMatrix: currents.real, stampRHS: currents.rhs)
        let x = [2.0, 0.6, 0.0]
        try overridden.stampDC(into: &stamper, state: SolutionState(variables: x, variableMap: map))
        let expectedForward = 1e-15 * pow(ratio, 3) * exp(1.11 / vt * (ratio - 1)) * expm1(0.6 / vt)
        let expectedBase = expectedForward / 100 - 1e-15 * pow(ratio, 3) * exp(1.11 / vt * (ratio - 1))
        #expect(abs(currents.residual(x)[1] - expectedBase) < 1e-12)
        let invalid = BJTModelParameters(forwardEarlyVoltage: 60, reverseEarlyVoltage: 20,
            nominalTemperature: 1, operatingTemperature: 10000)
        #expect(throws: DeviceBindingError.self) { try BJTTemperaturePreparation.prepare(invalid, device: "Q") }
    }

    @Test func invalidIntrinsicDomainAndHistoryFailExplicitly() throws {
        let (bound, map) = try fixture(sign: 1, withSeries: false)
        let values = BJTPhysicalStamps(3)
        var stamp = MatrixStamper(variableMap: map, stampMatrix: values.real, stampRHS: values.rhs)
        #expect(throws: DeviceBindingError.self) { try bound.stampDC(into: &stamp,
            state: SolutionState(variables: [0, 30, 0], variableMap: map)) }
        #expect(throws: (any Error).self) { try bound.stampTransient(into: &stamp,
            state: SolutionState(variables: [2, 0.6, 0], variableMap: map),
            integration: IntegrationState(method: .backwardEuler, timeStep: 1e-9, currentTime: 1e-9)) }
        #expect(throws: DeviceBindingError.self) { try bound.stampTransient(into: &stamp,
            state: SolutionState(variables: [2, 0.6, 0], previousVariables: [2, 0.5, 0], variableMap: map),
            integration: IntegrationState(method: .backwardEuler, timeStep: 0, currentTime: 1e-9)) }
    }

    @Test(arguments: [1.0, -1.0], [false, true])
    func originalStaticAndChargeTermsUseIndependentPhysicalReference(sign: Double, withSeries: Bool) throws {
        let (bound, map) = try fixture(sign: sign, withSeries: withSeries)
        let original = try #require(bound as? any TransientPhysicalEquationDecomposing)
        try original.validateTransientPhysicalEquationDecomposition()
        #expect(!(bound is any TransientPhysicalEquationEnclosureDecomposing))
        func vector(_ intrinsic: [Double]) -> [Double] {
            (withSeries ? [intrinsic[0] + 0.02, intrinsic[1] + 0.01, intrinsic[2] - 0.01] + intrinsic : intrinsic)
                .map { sign * $0 }
        }
        let initial = vector([1, 0.55, 0]), first = vector([1, 0.6, 0])
        let session = try #require(bound as? any TransientSessionDevice)
        try session.beginTransientSession(initialState: SolutionState(variables: initial, variableMap: map))
        defer { session.endTransientSession() }
        try session.commitTransientStep(state: SolutionState(variables: first, previousVariables: initial, variableMap: map),
            integration: IntegrationState(method: .backwardEuler, timeStep: 1e-8, currentTime: 1e-8))
        let tr = IntegrationState(method: .trapezoidal, timeStep: 2e-8, currentTime: 3e-8)
        for intrinsic in [[2.0, 0.62, 0], [0, 0.62, 2.0]] {
            let x = vector(intrinsic)
            let expected = reference(x, sign: sign, series: withSeries)
            let oldQ = reference(first, sign: sign, series: withSeries).charge
            var f = [Double](repeating: 0, count: x.count), q = f
            try original.accumulateTransientPhysicalEquation(
                state: SolutionState(variables: x, previousVariables: first, variableMap: map), integration: tr) {
                switch $1 {
                case .staticResidual: f[$0] += $2
                case .chargeDifference: q[$0] += $2
                case .differentialIncrement, .differentialHistoryCorrection: Issue.record("BJT emitted differential C terms")
                }
            }
            for row in x.indices {
                let difference = (expected.charge[row] - oldQ[row]) * 1e8
                #expect(abs(f[row] - expected.current[row]) < 1e-12 + abs(expected.current[row]) * 1e-10)
                #expect(abs(q[row] - difference) < 1e-15 + abs(difference) * 1e-10)
            }
        }
    }

    @Test func failedBindingDoesNotClaimPrivateNodesAndStrictParametersFail() throws {
        let ports = [Node(id: 1), Node(id: 2), Node(id: 3)], internalNode = Node(id: 4)
        let map = Dictionary(uniqueKeysWithValues: (ports + [internalNode]).enumerated().map { (MNAVariable.nodeVoltage($0.element), $0.offset) })
        var context = BindingContext(variableMap: map, matrixDimension: 4)
        for value in [Double.leastNonzeroMagnitude, -1, Double.infinity] {
            #expect(throws: DeviceBindingError.self) {
                try NPNDescriptor().bind(instance: Instance(name: "bad", typeName: "npn", nodes: ports,
                    parameters: ["rb": .real(value)], ownedNodes: [internalNode]), context: &context)
            }
        }
        for bad in [["unknown": ParameterValue.real(0)], ["bf": .string("80")], ["var": .real(.nan)]] {
            #expect(throws: DeviceBindingError.self) {
                try NPNDescriptor().bind(instance: Instance(name: "bad", typeName: "npn", nodes: ports,
                    parameters: bad), context: &context)
            }
        }
        _ = try NPNDescriptor().bind(instance: Instance(name: "good", typeName: "npn", nodes: ports,
            parameters: ["rb": .real(100)], ownedNodes: [internalNode]), context: &context)
        #expect(throws: DeviceBindingError.self) {
            try NPNDescriptor().bind(instance: Instance(name: "duplicate", typeName: "npn", nodes: ports,
                parameters: ["rb": .real(100)], ownedNodes: [internalNode]), context: &context)
        }
    }
}
