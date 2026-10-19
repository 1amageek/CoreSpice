import CoreSpiceIR
import Foundation
import Synchronization
import Testing
@testable import CoreSpiceDevices

private final class CapacitorLawStamps: Sendable {
    private let storage = Mutex((Array(repeating: 0.0, count: 9), Array(repeating: 0.0, count: 9), Array(repeating: 0.0, count: 3)))
    func real(_ r: Int, _ c: Int, _ value: Double) { storage.withLock { $0.0[r * 3 + c] += value } }
    func complex(_ r: Int, _ c: Int, _ x: Double, _ y: Double) { storage.withLock { $0.0[r * 3 + c] += x; $0.1[r * 3 + c] += y } }
    func rhs(_ r: Int, _ value: Double) { storage.withLock { $0.2[r] += value } }
    func csr(_ index: Int, _ value: Double) { storage.withLock { $0.0[index] += value } }
    var matrix: [Double] { storage.withLock { $0.0 } }
    var imaginary: [Double] { storage.withLock { $0.1 } }
    func current(_ vector: [Double], row: Int = 0) -> Double {
        storage.withLock { s in (0..<3).reduce(-s.2[row]) { $0 + s.0[row * 3 + $1] * vector[$1] } }
    }
}

@Suite("Behavioral capacitor physical laws", .timeLimit(.minutes(1)))
struct BehavioralCapacitorLawTests {
    private let positive = Node(id: 1), negative = Node(id: 2), control = Node(id: 3)
    private var map: [MNAVariable: Int] { [.nodeVoltage(positive): 0, .nodeVoltage(negative): 1, .nodeVoltage(control): 2] }
    private var voltage: BehavioralExpression { .variable(.nodeVoltage(positive: positive, negative: negative)) }
    private var controlVoltage: BehavioralExpression { .variable(.nodeVoltage(positive: control, negative: .ground)) }
    private var qExpression: BehavioralExpression {
        .binary(.add, .binary(.add, .binary(.multiply, .constant(2), voltage),
            .binary(.multiply, .constant(0.5), .binary(.power, voltage, .constant(3)))),
            .binary(.multiply, .constant(0.25), .binary(.power, controlVoltage, .constant(2))))
    }
    private var cExpression: BehavioralExpression {
        .binary(.add, .binary(.add, .constant(2), .binary(.power, voltage, .constant(2))),
            .binary(.multiply, .constant(0.5), controlVoltage))
    }
    private func bind(key: String, expression: BehavioralExpression, csr: Bool = false,
        settings: [String: ParameterValue] = [:], policy: RuntimeCapacitorPolicy = .default) throws -> any BoundDevice {
        var parameters = settings; parameters[key] = .behavioralExpression(expression)
        let resolver: (@Sendable (Int, Int) -> Int?)?
        if csr { resolver = { row, column in row * 3 + column } }
        else { resolver = nil }
        let conditions = try OperatingConditions(temperatureKelvin: 400.15)
        var context = BindingContext(variableMap: map, matrixDimension: 3,
            operatingConditions: conditions, stampIndexResolver: resolver)
        return try CapacitorDescriptor(runtimePolicy: policy).bind(instance: Instance(name: "C", typeName: "capacitor",
            nodes: [positive, negative], parameters: parameters, referencedNodes: [control]), context: &context)
    }
    private func q(_ x: [Double]) -> Double {
        let v = x[0] - x[1]; return 2 * v + 0.5 * v * v * v + 0.25 * x[2] * x[2]
    }
    private func c(_ x: [Double]) -> Double {
        let v = x[0] - x[1]; return 2 + v * v + 0.5 * x[2]
    }
    private func stamps(_ bound: any BoundDevice, vector: [Double], integration: IntegrationState) throws -> CapacitorLawStamps {
        let values = CapacitorLawStamps()
        var stamper = MatrixStamper(variableMap: map, stampMatrix: values.real, stampRHS: values.rhs, stampValue: values.csr)
        try bound.stampTransient(into: &stamper, state: SolutionState(variables: vector, variableMap: map), integration: integration)
        return values
    }

    @Test(arguments: [false, true])
    func nonlinearChargeFullGradientAndAcceptedHistory(csr: Bool) throws {
        // m=2 divided by F=1+.01*100 gives one; no model/circuit nominal substitution is allowed.
        let bound = try bind(key: "q", expression: qExpression, csr: csr,
            settings: ["m": .real(2), "tc1": .real(0.01), "ic": .real(0)])
        let session = try #require(bound as? any TransientSessionDevice)
        let initial = [1.0, 0, 0.5], first = [2.0, 0.25, 1.0]
        try session.beginTransientSession(initialState: SolutionState(variables: initial, variableMap: map))
        defer { session.endTransientSession() }
        let be = IntegrationState(method: .backwardEuler, timeStep: 0.25, currentTime: 0.25)
        let values = try stamps(bound, vector: first, integration: be)
        let expected = (q(first) - q(initial)) * 4
        #expect(abs(values.current(first) - expected) < 1e-12)
        #expect(abs(values.current(first, row: 1) + expected) < 1e-12)
        for column in 0..<3 {
            var hi = first, lo = first; hi[column] += 1e-5; lo[column] -= 1e-5
            let gradient = (q(hi) - q(lo)) * 4 / 2e-5
            #expect(abs(values.matrix[column] - gradient) < 1e-8)
            #expect(abs(values.matrix[3 + column] + gradient) < 1e-8)
        }
        let acValues = CapacitorLawStamps()
        var ac = ComplexMatrixStamper(variableMap: map, stampMatrix: acValues.complex, stampRHS: { _, _, _ in })
        try bound.stampAC(into: &ac, state: SolutionState(variables: first, variableMap: map), omega: 4)
        for index in 0..<9 { #expect(abs(acValues.imaginary[index] - values.matrix[index]) < 1e-12) }
        try session.commitTransientStep(state: SolutionState(variables: first, variableMap: map), integration: be)
        let trapezoidal = IntegrationState(method: .trapezoidal, timeStep: 0.5, currentTime: 0.75)
        for candidate in [[4.0, 0.5, 2], [2.5, 0.25, 1], [2.5, 0.25, 1]] {
            let trial = try stamps(bound, vector: candidate, integration: trapezoidal)
            let expected = 4 * (q(candidate) - q(first)) - expected
            #expect(abs(trial.current(candidate) - expected) < 1e-10)
        }
        #expect((bound as? any VoltageInitialConditionDevice)?.hasInitialCondition == true)
    }

    @Test(arguments: [false, true])
    func differentialCapacitanceIsNotDerivativeOfCV(csr: Bool) throws {
        let bound = try bind(key: "c", expression: cExpression, csr: csr)
        let session = try #require(bound as? any TransientSessionDevice)
        let old = [1.0, 0, 0], first = [2.0, 0, 0], next = [2.5, 0, 1]
        try session.beginTransientSession(initialState: SolutionState(variables: old, variableMap: map))
        defer { session.endTransientSession() }
        let be = IntegrationState(method: .backwardEuler, timeStep: 0.25, currentTime: 0.25)
        let stamped = try stamps(bound, vector: first, integration: be)
        let current = c(first) * 4 * (first[0] - old[0])
        #expect(abs(stamped.current(first) - current) < 1e-12)
        #expect(abs(current - 4 * (c(first) * first[0] - c(old) * old[0])) > 1)
        #expect(stamped.matrix[2] == 2) // dI/dcontrol = D(V)*dC/dcontrol.
        #expect(stamped.matrix[0] == 40) // C/dt + D(V)*dC/dV.
        try session.commitTransientStep(state: SolutionState(variables: first, variableMap: map), integration: be)
        let trap = IntegrationState(method: .trapezoidal, timeStep: 0.5, currentTime: 0.75)
        let nextStamp = try stamps(bound, vector: next, integration: trap)
        let rate = 4 * (next[0] - first[0]) - 4
        #expect(abs(nextStamp.current(next) - c(next) * rate) < 1e-12)
        let acValues = CapacitorLawStamps()
        var ac = ComplexMatrixStamper(variableMap: map, stampMatrix: acValues.complex, stampRHS: { _, _, _ in })
        try bound.stampAC(into: &ac, state: SolutionState(variables: next, variableMap: map), omega: 1)
        #expect(acValues.imaginary[0] == c(next))
        #expect(acValues.imaginary[2] == 0)
    }

    @Test func explicitTimeIsTransientOnlyAndFailedTrialPreservesHistory() throws {
        let expression = BehavioralExpression.binary(.add, qExpression, .variable(.time))
        let bound = try bind(key: "q", expression: expression)
        guard case .unsupported = bound.poleZeroStampApplicability else { Issue.record("Time law cannot be an LTI realization"); return }
        let initial = [1.0, 0, 0], next = [2.0, 0, 0]
        let session = try #require(bound as? any TransientSessionDevice)
        try session.beginTransientSession(initialState: SolutionState(variables: initial, variableMap: map))
        #expect(throws: DeviceBindingError.self) { try session.beginTransientSession(initialState: SolutionState(variables: initial, variableMap: map)) }
        let values = CapacitorLawStamps()
        var ac = ComplexMatrixStamper(variableMap: map, stampMatrix: values.complex, stampRHS: { _, _, _ in })
        #expect(throws: DeviceBindingError.self) { try bound.stampAC(into: &ac, state: SolutionState(variables: initial, variableMap: map), omega: 1) }
        let step = IntegrationState(method: .backwardEuler, timeStep: 0.25, currentTime: 0.25)
        #expect(throws: (any Error).self) { try stamps(bound, vector: [.infinity, 0, 0], integration: step) }
        #expect(throws: (any Error).self) { try session.commitTransientStep(
            state: SolutionState(variables: [.infinity, 0, 0], variableMap: map), integration: step) }
        let accepted = try stamps(bound, vector: next, integration: step)
        #expect(abs(accepted.current(next) - 4 * (q(next) + 0.25 - q(initial))) < 1e-12)
        try session.commitTransientStep(state: SolutionState(variables: next, variableMap: map), integration: step)
        #expect(throws: DeviceBindingError.self) { try session.commitTransientStep(state: SolutionState(variables: next, variableMap: map), integration: step) }
        session.endTransientSession()
        try session.beginTransientSession(initialState: SolutionState(variables: initial, variableMap: map))
        session.endTransientSession()
    }

    @Test func concurrentBeginHasExactlyOneOwnerAndShutdownAllowsReuse() async throws {
        let bound = try bind(key: "q", expression: qExpression)
        let session = try #require(bound as? any TransientSessionDevice)
        let initial = SolutionState(variables: [0, 0, 0], variableMap: map)
        let admitted = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    do { try session.beginTransientSession(initialState: initial); return true }
                    catch { return false }
                }
            }
            var successes = 0
            for await result in group { if result { successes += 1 } }
            return successes
        }
        #expect(admitted == 1)
        session.endTransientSession()
        try session.beginTransientSession(initialState: initial)
        session.endTransientSession()
    }

    @Test func boundedAdmissionAndMalformedRolesFailBeforePublication() throws {
        let small = try RuntimeCapacitorPolicy(maxASTNodes: 3)
        #expect(throws: DeviceBindingError.self) { try bind(key: "q", expression: qExpression, policy: small) }
        #expect(throws: RuntimeCapacitorPolicyError.self) { try RuntimeCapacitorPolicy(maxDependencies: Int.max) }
        #expect(throws: DeviceBindingError.self) { try bind(key: "q", expression: qExpression, settings: ["c": .real(1)]) }
        #expect(throws: DeviceBindingError.self) { try bind(key: "q", expression: qExpression, settings: ["m": .real(0)]) }
        #expect(throws: DeviceBindingError.self) { try bind(key: "q", expression: qExpression, settings: ["ic": .string("0")]) }
        #expect(throws: DeviceBindingError.self) { try bind(key: "c", expression: cExpression, settings: ["unknown": .real(0)]) }
        let bound = try bind(key: "c", expression: .constant(-1))
        let session = try #require(bound as? any TransientSessionDevice)
        #expect(throws: DeviceBindingError.self) { try session.beginTransientSession(initialState: SolutionState(variables: [0, 0, 0], variableMap: map)) }
    }
}
