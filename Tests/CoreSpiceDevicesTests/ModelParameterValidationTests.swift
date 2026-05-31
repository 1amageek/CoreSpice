import CoreSpiceIR
@testable import CoreSpiceDevices
import Testing

@Suite("Model parameter validation")
struct ModelParameterValidationTests {

    private func emptyContext() -> BindingContext {
        BindingContext(variableMap: [:], matrixDimension: 0)
    }

    @Test("MOSFET rejects non-physical geometry")
    func mosfetRejectsNonPhysicalGeometry() throws {
        let instance = Instance(
            name: "Mbad",
            typeName: "nmos_l1",
            nodes: [Node(id: 1), Node(id: 2), Node.ground, Node.ground],
            parameters: ["w": .real(-1e-6), "l": .real(1e-6)]
        )
        var context = emptyContext()

        #expect(throws: DeviceBindingError.self) {
            _ = try NMOSL1Descriptor().bind(instance: instance, context: &context)
        }
    }

    @Test("Diode rejects invalid junction parameters")
    func diodeRejectsInvalidJunctionParameters() throws {
        let instance = Instance(
            name: "Dbad",
            typeName: "diode",
            nodes: [Node(id: 1), Node.ground],
            parameters: ["is": .real(0)]
        )
        var context = emptyContext()

        #expect(throws: DeviceBindingError.self) {
            _ = try DiodeDescriptor().bind(instance: instance, context: &context)
        }
    }

    @Test("BJT rejects invalid transport parameters")
    func bjtRejectsInvalidTransportParameters() throws {
        let instance = Instance(
            name: "Qbad",
            typeName: "npn",
            nodes: [Node(id: 1), Node(id: 2), Node.ground],
            parameters: ["bf": .real(0)]
        )
        var context = emptyContext()

        #expect(throws: DeviceBindingError.self) {
            _ = try NPNDescriptor().bind(instance: instance, context: &context)
        }
    }
}
