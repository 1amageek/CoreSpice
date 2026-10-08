import Foundation
import Synchronization
import Testing
@testable import CoreSpiceDevices
import CoreSpiceIR

@Suite("Static semiconductor resistor")
struct StaticResistorTests {
    private let node = Node(id: 1)

    private func bind(_ parameters: [String: ParameterValue], model: [String: ParameterValue] = [:],
                      conditions: OperatingConditions = .nominal) throws -> any BoundDevice {
        let instance = Instance(name: "R1", typeName: "resistor", nodes: [node, .ground],
            parameters: parameters, model: model.isEmpty ? nil :
                ResolvedDeviceModel(name: "sheet", typeName: "resistor", parameters: model))
        var context = BindingContext(variableMap: [.nodeVoltage(node): 0], matrixDimension: 1,
            operatingConditions: conditions)
        return try ResistorDescriptor().bind(instance: instance, context: &context)
    }

    private func conductance(_ bound: any BoundDevice, ac: Bool = false) throws -> Double {
        let sum = Mutex(0.0)
        let map: [MNAVariable: Int] = [.nodeVoltage(node): 0]
        let state = SolutionState(variables: [1], variableMap: map)
        if ac {
            var stamp = ComplexMatrixStamper(variableMap: map,
                stampMatrix: { _, _, real, _ in sum.withLock { $0 += real } },
                stampRHS: { _, _, _ in })
            try bound.stampAC(into: &stamp, state: state, omega: 1)
        } else {
            var stamp = MatrixStamper(variableMap: map,
                stampMatrix: { _, _, value in sum.withLock { $0 += value } }, stampRHS: { _, _ in })
            try bound.stampDC(into: &stamp, state: state)
        }
        return sum.withLock { $0 }
    }

    @Test func temperaturePrecedenceMultiplicityScaleAndAC() throws {
        let bound = try bind(["r": .real(100), "ac": .real(200), "m": .real(3), "scale": .real(2),
            "temp": .real(50), "dtemp": .real(999), "tc1": .real(0.01)],
            model: ["r": .real(999), "tnom": .real(25), "tc1": .real(0.5), "tc2": .real(0.0001)])
        let factor = 1 + 0.01 * 25 + 0.0001 * 25 * 25
        #expect(abs(try conductance(bound) - 3 / (100 * factor * 2)) < 1e-15)
        #expect(abs(try conductance(bound, ac: true) - 3 / (200 * factor * 2)) < 1e-15)
        let noisy = try #require(bound as? any NoisyDevice)
        let noise = try noisy.noiseContributions(state: SolutionState(variables: [1],
            variableMap: [.nodeVoltage(node): 0]), frequency: 10)
        #expect(abs(noise[0].currentSpectralDensity / (4 * 1.380649e-23 * 348.15 * 3 / (100 * factor * 2)) - 1) < 1e-12)
    }

    @Test func geometryPrecedesModelDefaultAndRetainsSourceNoiseArea() throws {
        let model: [String: ParameterValue] = ["r": .real(999), "rsh": .real(100),
            "l": .real(10e-6), "w": .real(5e-6), "short": .real(1e-6), "narrow": .real(0.5e-6),
            "kf": .real(1e-20), "af": .real(2), "ef": .real(1), "lf": .real(1), "wf": .real(1)]
        let defaultDimensions = try bind([:], model: model)
        #expect(abs(try conductance(defaultDimensions) - 1 / 200.0) < 1e-15)
        let sourceDimensions = try bind(["l": .real(10e-6), "m": .real(2)], model: model)
        let noisy = try #require(sourceDimensions as? any NoisyDevice)
        let values = try noisy.noiseContributions(state: SolutionState(variables: [2],
            variableMap: [.nodeVoltage(node): 0]), frequency: 100)
        let flicker = try #require(values.first { $0.name.hasSuffix("_1overf") })
        #expect(abs(flicker.currentSpectralDensity / (2e-20 * pow(0.01, 2) / (8e-6 * 4e-6 * 100)) - 1) < 1e-12)
        let defaultNoise = try #require(defaultDimensions as? any NoisyDevice).noiseContributions(
            state: SolutionState(variables: [2], variableMap: [.nodeVoltage(node): 0]), frequency: 100)
        #expect(abs(defaultNoise[1].currentSpectralDensity / (1e-20 * pow(0.01, 2) / 100) - 1) < 1e-12)
    }

    @Test func exponentialOverridesQuadraticAndNoiseDisable() throws {
        let bound = try bind(["r": .real(100), "tce": .real(2), "tc1": .real(100), "noise": .real(0)],
            model: ["tnom": .real(25), "tc2": .real(100)])
        #expect(abs(try conductance(bound) - 1 / (100 * pow(1.01, 4))) < 1e-15)
        let values = try #require(bound as? any NoisyDevice).noiseContributions(
            state: SolutionState(variables: [1], variableMap: [.nodeVoltage(node): 0]), frequency: 1)
        #expect(values.isEmpty)
    }

    @Test func circuitNominalTemperatureIsIndependentOfOperatingTemperature() throws {
        let conditions = try OperatingConditions(temperatureCelsius: 50, nominalTemperatureCelsius: 20)
        let bound = try bind(["r": .real(100), "tc1": .real(0.01), "dtemp": .real(10)], conditions: conditions)
        #expect(abs(try conductance(bound) - 1 / 140.0) < 1e-15)
        #expect(throws: OperatingConditionsError.self) {
            _ = try OperatingConditions(temperatureKelvin: 300, nominalTemperatureKelvin: 0)
        }
    }

    @Test func supportedAliasesAndModelDefaultsHaveOriginalRoles() throws {
        let bound = try bind(["resistance": .real(100), "tc": .real(0.01), "noise": .real(0)],
            model: ["res": .real(500), "tc1r": .real(9), "tc2r": .real(0.001), "tnom": .real(25),
                "defw": .real(5e-6), "dlr": .real(1e-6), "dw": .real(0.5e-6)])
        #expect(abs(try conductance(bound) - 1 / 102.4) < 1e-15)
        let defaultR = try bind([:], model: ["res": .real(200)])
        #expect(abs(try conductance(defaultR) - 0.005) < 1e-15)
    }

    @Test func preparedConductanceReachesCSRAndTransientAndRuntimeFailure() throws {
        let instance = Instance(name: "Rcsr", typeName: "resistor", nodes: [node, .ground],
            parameters: ["r": .real(100), "tc1": .real(0.01), "dtemp": .real(10), "m": .real(2)])
        let map: [MNAVariable: Int] = [.nodeVoltage(node): 0]
        var context = BindingContext(variableMap: map, matrixDimension: 1, stampIndexResolver: { _, _ in 0 })
        let bound = try ResistorDescriptor().bind(instance: instance, context: &context)
        let sum = Mutex(0.0)
        var stamp = MatrixStamper(variableMap: map, stampMatrix: { _, _, _ in
            Issue.record("Prepared CSR path unexpectedly used coordinate stamping")
        }, stampRHS: { _, _ in }, stampValue: { _, value in sum.withLock { $0 += value } })
        try bound.stampTransient(into: &stamp, state: SolutionState(variables: [1], variableMap: map),
            integration: .init(method: .trapezoidal, timeStep: 1e-9, currentTime: 1e-9))
        #expect(abs(sum.withLock { $0 } - 2 / 110.0) < 1e-15)
        let large = try bind(["r": .real(0.5)])
        #expect(throws: DeviceBindingError.self) {
            try large.stampDC(into: &stamp, state: SolutionState(variables: [.greatestFiniteMagnitude], variableMap: map))
        }
        let noisy = try #require(bind(["r": .real(1)], model: ["kf": .real(1), "af": .real(1000)]) as? any NoisyDevice)
        #expect(throws: DeviceBindingError.self) {
            _ = try noisy.noiseContributions(state: SolutionState(variables: [10], variableMap: map), frequency: 1)
        }
    }

    @Test func invalidSuppliedAndDerivedDomainsRefuse() throws {
        let invalidParameters: [[String: ParameterValue]] = [
            ["r": .real(0)], ["r": .real(-1)], ["r": .real(.infinity)],
            ["r": .real(Double.leastNonzeroMagnitude)], ["r": .real(1), "m": .real(0)],
            ["r": .real(1), "scale": .real(0)], ["r": .real(1), "temp": .real(-273.15)],
            ["r": .real(1), "tc1": .real(-1)], ["r": .real(1), "ac": .real(0)],
            ["r": .real(1), "noisy": .real(0.5)], ["r": .real(1), "unknown": .real(0)],
            ["r": .real(1), "resistance": .real(2)]
        ]
        for parameters in invalidParameters {
            #expect(throws: DeviceBindingError.self) { _ = try bind(parameters, model: ["tnom": .real(25)]) }
        }
        #expect(throws: DeviceBindingError.self) { _ = try bind([:], model: ["rsh": .real(1), "short": .real(1)]) }
        #expect(throws: DeviceBindingError.self) { _ = try bind(["r": .real(1)], model: ["kf": .real(-1)]) }
        let noisy = try #require(bind(["r": .real(1)], model: ["kf": .real(1)]) as? any NoisyDevice)
        #expect(throws: DeviceBindingError.self) {
            _ = try noisy.noiseContributions(state: SolutionState(variables: [1], variableMap: [.nodeVoltage(node): 0]), frequency: 0)
        }
    }
}
