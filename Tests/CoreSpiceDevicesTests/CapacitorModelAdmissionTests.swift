import Testing
import Synchronization
@testable import CoreSpiceDevices
@testable import CoreSpiceIR

@Suite("Capacitor model binding admission")
struct CapacitorModelAdmissionTests {
    @Test("Charge law is numerical and cannot mix capacitance or a model",
          arguments: [ParameterValue.real(1e-6), .behavioralExpression(.constant(1e-6))],
          ["q", "q+c", "q+model"])
    func chargeRoleAdmission(charge: ParameterValue, configuration: String) throws {
        var parameters: [String: ParameterValue] = ["q": charge]
        if configuration == "q+c" { parameters["c"] = .real(1e-6) }
        let model: ResolvedDeviceModel? = configuration == "q+model"
            ? ResolvedDeviceModel(name: "CM", typeName: "capacitor", parameters: [:]) : nil
        let instance = Instance(name: "CQ", typeName: "capacitor", nodes: [Node(id: 1), .ground],
            parameters: parameters, model: model)
        var context = BindingContext(variableMap: [.nodeVoltage(Node(id: 1)): 0], matrixDimension: 1)
        if configuration != "q" {
            #expect(throws: DeviceBindingError.self) { try CapacitorDescriptor().bind(instance: instance, context: &context) }
            return
        }
        let bound = try CapacitorDescriptor().bind(instance: instance, context: &context)
        let session = try #require(bound as? any TransientSessionDevice)
        let state = SolutionState(variables: [1], variableMap: context.variableMap)
        try session.beginTransientSession(initialState: state)
        defer { session.endTransientSession() }
        let current = Mutex(0.0)
        let physical = try #require(bound as? any TransientPhysicalResidualContributing)
        try physical.accumulateTransientPhysicalResidual(state: state,
            integration: IntegrationState(method: .backwardEuler, timeStep: 1, currentTime: 1),
            add: { _, value in current.withLock { $0 += value } })
        #expect(current.withLock { $0 } == 0)
    }

    @Test("Explicit capacitance applies model coefficients and refuses wrong model type", arguments: ["capacitor", "resistor"])
    func physicalModelRole(modelType: String) throws {
        let node = Node(id: 1)
        let instance = Instance(name: "C1", typeName: "capacitor", nodes: [node, .ground],
            parameters: ["c": .real(1e-6)],
            model: ResolvedDeviceModel(name: "CM", typeName: modelType, parameters: ["tc1": .real(0.01), "tnom": .real(17)]))
        var context = BindingContext(variableMap: [.nodeVoltage(node): 0], matrixDimension: 1)
        if modelType != "capacitor" {
            #expect(throws: DeviceBindingError.self) { try CapacitorDescriptor().bind(instance: instance, context: &context) }
            return
        }
        let bound = try CapacitorDescriptor().bind(instance: instance, context: &context)
        let imaginary = Mutex(0.0)
        var ac = ComplexMatrixStamper(variableMap: context.variableMap,
            stampMatrix: { _, _, _, value in imaginary.withLock { $0 += value } }, stampRHS: { _, _, _ in })
        try bound.stampAC(into: &ac, state: SolutionState(variables: [1], variableMap: context.variableMap), omega: 1)
        #expect(abs(imaginary.withLock { $0 } - 1.1e-6) < 1e-20)
    }

    @Test("Ideal capacitors retain their transient companion with URC provenance",
          arguments: [false, true], [false, true])
    func idealTransientStamp(selectedURC: Bool, useCSR: Bool) throws {
        let positive = Node(id: 1)
        let negative = Node(id: 2)
        let sourceModel = ResolvedDeviceModel(name: "LINE", typeName: "urc", parameters: ["cperl": .real(0.5)])
        let instance = Instance(
            name: "U1.lo1.c", typeName: "capacitor", nodes: [positive, negative],
            parameters: ["c": .real(0.5)],
            modelConsumption: selectedURC ? .selected(sourceModel) : .modelFree
        )
        let variableMap: [MNAVariable: Int] = [.nodeVoltage(positive): 0, .nodeVoltage(negative): 1]
        var context = BindingContext(
            variableMap: variableMap, matrixDimension: 2,
            stampIndexResolver: { row, column in useCSR ? row * 2 + column : nil }
        )
        let bound = try CapacitorDescriptor().bind(instance: instance, context: &context)
        let matrix = Mutex([Double](repeating: 0, count: 4))
        let rhs = Mutex([Double](repeating: 0, count: 2))
        var stamper = MatrixStamper(
            variableMap: variableMap,
            stampMatrix: { row, column, value in matrix.withLock { $0[row * 2 + column] += value } },
            stampRHS: { row, value in rhs.withLock { $0[row] += value } },
            stampValue: { index, value in matrix.withLock { $0[index] += value } }
        )
        let state = SolutionState(variables: [5, 2], previousVariables: [3, 1], variableMap: variableMap)
        let integration = IntegrationState(method: .backwardEuler, timeStep: 0.25, currentTime: 0.25)

        try bound.stampTransient(into: &stamper, state: state, integration: integration)

        // C / dt = 2, and the history source is 2 * (3 - 1) = 4.
        #expect(matrix.withLock { $0 } == [2, -2, -2, 2])
        #expect(rhs.withLock { $0 } == [4, -4])
    }
}
