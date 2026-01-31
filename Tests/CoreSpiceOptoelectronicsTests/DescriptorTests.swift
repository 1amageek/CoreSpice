import Testing
import Foundation
import CoreSpiceIR
import CoreSpiceDevices
@testable import CoreSpiceOptoelectronics

@Suite("Optoelectronic Descriptor Tests")
struct DescriptorTests {

    private func makeContext(nodeCount: Int) -> BindingContext {
        var varMap: [MNAVariable: Int] = [:]
        for i in 0..<nodeCount {
            varMap[.nodeVoltage(Node(id: i + 1))] = i
        }
        return BindingContext(variableMap: varMap, matrixDimension: nodeCount)
    }

    @Test("PhotodiodeDescriptor binds correctly with 2 electrical nodes")
    func photodiodeDescriptor() throws {
        let desc = PhotodiodeDescriptor()
        #expect(desc.typeName == "photodiode")
        #expect(desc.portNames.count == 2)

        let instance = Instance(
            name: "PD1", typeName: "photodiode",
            nodes: [Node(id: 1), Node(id: 2)],
            parameters: ["resp": .real(0.9)],
            opticalNodes: [OpticalNode(id: 1)]
        )
        var ctx = makeContext(nodeCount: 2)
        let device = try desc.bind(instance: instance, context: &ctx)
        #expect(device.instance.name == "PD1")
    }

    @Test("LEDDescriptor binds correctly")
    func ledDescriptor() throws {
        let desc = LEDDescriptor()
        #expect(desc.typeName == "led")

        let instance = Instance(
            name: "LED1", typeName: "led",
            nodes: [Node(id: 1), Node(id: 2)],
            parameters: ["eta_ext": .real(0.2)],
            opticalNodes: [OpticalNode(id: 1)]
        )
        var ctx = makeContext(nodeCount: 2)
        let device = try desc.bind(instance: instance, context: &ctx)
        #expect(device.instance.name == "LED1")
    }

    @Test("LaserDiodeDescriptor binds correctly")
    func laserDescriptor() throws {
        let desc = LaserDiodeDescriptor()
        #expect(desc.typeName == "laser")

        let instance = Instance(
            name: "LD1", typeName: "laser",
            nodes: [Node(id: 1), Node(id: 2)],
            parameters: ["ith": .real(15e-3), "slope_eff": .real(0.25)],
            opticalNodes: [OpticalNode(id: 1)]
        )
        var ctx = makeContext(nodeCount: 2)
        let device = try desc.bind(instance: instance, context: &ctx)
        #expect(device.instance.name == "LD1")
    }

    @Test("EOModulatorDescriptor binds correctly with 4 electrical nodes")
    func eoModDescriptor() throws {
        let desc = EOModulatorDescriptor()
        #expect(desc.typeName == "eomod")
        #expect(desc.portNames.count == 4)

        let instance = Instance(
            name: "MZM1", typeName: "eomod",
            nodes: [Node(id: 1), Node(id: 2), Node(id: 3), Node(id: 4)],
            parameters: ["vpi": .real(4.0)],
            opticalNodes: [OpticalNode(id: 1), OpticalNode(id: 2)]
        )
        var ctx = makeContext(nodeCount: 4)
        let device = try desc.bind(instance: instance, context: &ctx)
        #expect(device.instance.name == "MZM1")
    }

    @Test("OpticalWaveguideDescriptor binds correctly with no electrical nodes")
    func waveguideDescriptor() throws {
        let desc = OpticalWaveguideDescriptor()
        #expect(desc.typeName == "waveguide")
        #expect(desc.portNames.isEmpty)

        let instance = Instance(
            name: "WG1", typeName: "waveguide",
            nodes: [],
            parameters: ["length": .real(0.01), "neff": .real(1.45)],
            opticalNodes: [OpticalNode(id: 1), OpticalNode(id: 2)]
        )
        var ctx = makeContext(nodeCount: 0)
        let device = try desc.bind(instance: instance, context: &ctx)
        #expect(device.instance.name == "WG1")
    }

    @Test("OpticalSplitterDescriptor binds correctly")
    func splitterDescriptor() throws {
        let desc = OpticalSplitterDescriptor()
        #expect(desc.typeName == "splitter")
        #expect(desc.portNames.isEmpty)

        let instance = Instance(
            name: "SPL1", typeName: "splitter",
            nodes: [],
            parameters: ["ratio": .real(0.7)],
            opticalNodes: [OpticalNode(id: 1), OpticalNode(id: 2), OpticalNode(id: 3)]
        )
        var ctx = makeContext(nodeCount: 0)
        let device = try desc.bind(instance: instance, context: &ctx)
        #expect(device.instance.name == "SPL1")
    }

    @Test("DeviceRegistry.withOptoelectronics includes all optoelectronic types")
    func registryIntegration() {
        let registry = DeviceRegistry.withOptoelectronics()

        #expect(registry.descriptor(for: "photodiode") != nil)
        #expect(registry.descriptor(for: "led") != nil)
        #expect(registry.descriptor(for: "laser") != nil)
        #expect(registry.descriptor(for: "eomod") != nil)
        #expect(registry.descriptor(for: "waveguide") != nil)
        #expect(registry.descriptor(for: "splitter") != nil)
        // Also still has standard devices
        #expect(registry.descriptor(for: "resistor") != nil)
        #expect(registry.descriptor(for: "capacitor") != nil)
    }

    @Test("Descriptor port count mismatch throws error")
    func portCountMismatch() {
        let desc = PhotodiodeDescriptor()
        let instance = Instance(
            name: "PD_BAD", typeName: "photodiode",
            nodes: [Node(id: 1)],  // Only 1 node, needs 2
            parameters: [:],
            opticalNodes: []
        )
        var ctx = makeContext(nodeCount: 1)
        var didThrow = false
        do {
            _ = try desc.bind(instance: instance, context: &ctx)
        } catch is DeviceBindingError {
            didThrow = true
        } catch {}
        #expect(didThrow, "Should throw DeviceBindingError for insufficient nodes")
    }
}
