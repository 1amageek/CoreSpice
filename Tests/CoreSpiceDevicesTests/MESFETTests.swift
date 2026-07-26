import Testing
import Synchronization
@testable import CoreSpiceDevices
@testable import CoreSpiceIR

@Suite("MESFET device tests")
struct MESFETTests {
    @Test("Standard registry exposes both MESFET polarities")
    func standardRegistryContainsMESFETDescriptors() {
        let registry = DeviceRegistry.standard()

        #expect(registry.descriptor(for: "nmesfet") != nil)
        #expect(registry.descriptor(for: "pmesfet") != nil)
    }

    @Test("MESFET rejects nonphysical Curtice parameters before stamping")
    func rejectsInvalidPhysicalParameters() {
        let instance = Instance(
            name: "Zbad",
            typeName: "nmesfet",
            nodes: [Node(id: 1), Node(id: 2), .ground],
            parameters: ["alpha": .real(0)]
        )
        var context = BindingContext(variableMap: [:], matrixDimension: 0)

        #expect(throws: DeviceBindingError.self) {
            _ = try NMESFETDescriptor().bind(instance: instance, context: &context)
        }
    }

    @Test("Area and parallel multiplier scale the Curtice channel together")
    func areaAndMultiplierScaleChannel() throws {
        let drain = Node(id: 1)
        let gate = Node(id: 2)
        let source = Node(id: 3)
        let variableMap: [MNAVariable: Int] = [
            .nodeVoltage(drain): 0,
            .nodeVoltage(gate): 1,
            .nodeVoltage(source): 2,
        ]
        var context = BindingContext(variableMap: variableMap, matrixDimension: 3)
        let instance = Instance(
            name: "Zscaled",
            typeName: "nmesfet",
            nodes: [drain, gate, source],
            parameters: [
                "vto": .real(-1),
                "alpha": .real(2),
                "beta": .real(1e-3),
                "b": .real(0),
                "area": .real(2),
                "m": .real(3),
            ]
        )
        let device = try NMESFETDescriptor().bind(instance: instance, context: &context)
        let state = SolutionState(
            variables: [4, 0, 0],
            variableMap: variableMap
        )
        let drainGateTransconductance = Mutex(0.0)
        var stamper = MatrixStamper(
            variableMap: variableMap,
            stampMatrix: { row, column, value in
                if row == 0, column == 1 {
                    drainGateTransconductance.withLock { $0 += value }
                }
            },
            stampRHS: { _, _ in }
        )

        device.stampDC(into: &stamper, state: state)

        #expect(
            abs(drainGateTransconductance.withLock { $0 } - 0.012) < 1e-9
        )
    }
}
