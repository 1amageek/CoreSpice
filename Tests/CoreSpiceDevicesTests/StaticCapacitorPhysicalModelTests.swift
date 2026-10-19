import CoreSpiceIR
import Foundation
import Synchronization
import Testing
@testable import CoreSpiceDevices

@Suite("Static capacitor physical model", .timeLimit(.minutes(1)))
struct StaticCapacitorPhysicalModelTests {
    private func total(instance: [String: ParameterValue], model: [String: ParameterValue] = [:],
        temperature: Double = 300.15, nominal: Double = 300.15) throws -> Double {
        let node = Node(id: 1)
        var context = BindingContext(variableMap: [.nodeVoltage(node): 0], matrixDimension: 1,
            operatingConditions: try OperatingConditions(temperatureKelvin: temperature, nominalTemperatureKelvin: nominal))
        let bound = try CapacitorDescriptor().bind(instance: Instance(name: "C", typeName: "capacitor",
            nodes: [node, .ground], parameters: instance,
            model: model.isEmpty ? nil : ResolvedDeviceModel(name: "CM", typeName: "capacitor", parameters: model)), context: &context)
        let imaginary = Mutex(0.0)
        var ac = ComplexMatrixStamper(variableMap: context.variableMap,
            stampMatrix: { _, _, _, v in imaginary.withLock { $0 += v } }, stampRHS: { _, _, _ in })
        try bound.stampAC(into: &ac, state: SolutionState(variables: [0], variableMap: context.variableMap), omega: 1)
        return imaginary.withLock { $0 }
    }
    @Test func geometryTemperatureAndPrecedence() throws {
        let model: [String: ParameterValue] = ["cox": .real(2e-3), "capsw": .real(1e-10),
            "w": .real(5e-6), "narrow": .real(1e-6), "short": .real(2e-6), "tnom": .real(25),
            "tc1": .real(0.01), "tc2": .real(0.001)]
        let geometry = 2e-3 * 4e-6 * 8e-6 + 2 * 1e-10 * (4e-6 + 8e-6)
        let expected = geometry * (1 + 0.02 * 10 + 0.001 * 100) * 3 * 2
        let actual = try total(instance: ["l": .real(10e-6), "tc1": .real(0.02), "m": .real(3), "scale": .real(2)],
            model: model, temperature: 308.15)
        #expect(abs(actual / expected - 1) < 1e-14)
        var withCap = model; withCap["cap"] = .real(1e-9)
        let modelValue = try total(instance: [:], model: withCap)
        #expect(abs(modelValue / (1e-9 * (1 + 0.01 * 2 + 0.001 * 4)) - 1) < 1e-14)
        let explicit = try total(instance: ["c": .real(2e-9), "temp": .real(25), "dtemp": .real(100)], model: withCap)
        #expect(explicit == 2e-9)
    }
    @Test func dielectricAndDelDefaults() throws {
        let epsilon = 1 / (4 * Double.pi * 1e-7 * 299_792_458 * 299_792_458)
        let actual = try total(instance: ["l": .real(4e-6)],
            model: ["thick": .real(1e-7), "di": .real(4), "del": .real(1e-6)])
        let expected = 4 * epsilon / 1e-7 * 8e-6 * 2e-6
        #expect(abs(actual / expected - 1) < 1e-14)
    }
    @Test func strictRolesAndDerivedFailure() {
        for (instance, model) in [
            (["c": ParameterValue.real(1)], ["defl": ParameterValue.real(1)]),
            (["c": .real(1)], ["cox": .real(1), "cj": .real(2)]),
            (["c": .real(1), "m": .real(.infinity)], [:]),
            (["c": .real(1), "tc1": .real(-1), "temp": .real(100)], [:]),
            (["c": .real(1), "temp": .real(-300)], [:]),
            (["l": .real(1e-6)], ["cox": .real(1), "narrow": .real(20e-6)]),
            (["l": .real(1e-6)], ["thick": .real(0)]),
        ] {
            #expect(throws: DeviceBindingError.self) { try total(instance: instance, model: model) }
        }
    }
    @Test func explicitZeroInitialConditionIsRetained() throws {
        let node = Node(id: 1)
        var context = BindingContext(variableMap: [.nodeVoltage(node): 0], matrixDimension: 1)
        let bound = try CapacitorDescriptor().bind(instance: Instance(name: "C", typeName: "capacitor",
            nodes: [node, .ground], parameters: ["c": .real(1), "ic": .real(0)]), context: &context)
        let initial = try #require(bound as? any VoltageInitialConditionDevice)
        #expect(initial.hasInitialCondition)
        #expect(initial.initialVoltage == 0)
    }
}
