import Testing
import Synchronization
@testable import CoreSpiceDevices
@testable import CoreSpiceIR

@Suite("Capacitor model binding admission")
struct CapacitorModelAdmissionTests {
    @Test("Explicit capacitance cannot discard a physical model", arguments: ["capacitor", "resistor"])
    func physicalModelIsRejected(modelType: String) {
        let instance = Instance(
            name: "C1", typeName: "capacitor", nodes: [Node(id: 1), .ground],
            parameters: ["c": .real(1.0e-6)],
            model: ResolvedDeviceModel(name: "CM", typeName: modelType, parameters: ["tc1": .real(0.01)])
        )
        var context = BindingContext(variableMap: [.nodeVoltage(Node(id: 1)): 0], matrixDimension: 1)

        do {
            _ = try CapacitorDescriptor().bind(instance: instance, context: &context)
            Issue.record("Expected physical capacitor model admission to fail")
        } catch let error as DeviceBindingError {
            guard case .invalidParameterValue(let device, let parameter, let message) = error else {
                Issue.record("Unexpected binding failure: \(error)")
                return
            }
            #expect(device == "C1")
            #expect(parameter == "model")
            if modelType == "capacitor" {
                #expect(message == "Model-backed capacitor numerical preparation is not implemented")
            } else {
                #expect(message == "Model type 'resistor' does not match capacitor")
            }
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
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
