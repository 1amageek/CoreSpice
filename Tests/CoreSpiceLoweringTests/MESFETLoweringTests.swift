import Testing
@testable import CoreSpiceIR
@testable import CoreSpiceLowering
@testable import CoreSpiceParsedIR

@Suite("MESFET lowering")
struct MESFETLoweringTests {
    @Test("NMF model lowers to a native device with area-scaled series resistances")
    func lowersNMFWithSeriesResistanceScaling() throws {
        let component = ParsedComponent(
            name: "Z1",
            type: .mesfet,
            nodes: ["drain", "gate", "source"],
            modelName: "model",
            parameters: ["area": .numeric(2), "m": .numeric(4)]
        )
        let model = ParsedModel(
            name: "model",
            type: .nmf,
            parameters: [
                "beta": .numeric(1e-3),
                "rd": .numeric(80),
                "rs": .numeric(40),
            ]
        )

        let circuit = try NetlistLowering().lower(
            ParsedNetlist(components: [component], models: [model])
        )
        let core = try #require(circuit.instances.first { $0.name == "Z1" })
        let drainResistance = try #require(
            circuit.instances.first { $0.name == "Z1.rd" }
        )
        let sourceResistance = try #require(
            circuit.instances.first { $0.name == "Z1.rs" }
        )

        #expect(core.typeName == "nmesfet")
        #expect(real("r", in: drainResistance) == 10)
        #expect(real("r", in: sourceResistance) == 5)
        #expect(core.parameters["rd"] == nil)
        #expect(core.parameters["rs"] == nil)
    }

    @Test("PMF model selects the P-channel descriptor")
    func lowersPMF() throws {
        let component = ParsedComponent(
            name: "ZP",
            type: .mesfet,
            nodes: ["drain", "gate", "source"],
            modelName: "model"
        )
        let model = ParsedModel(name: "model", type: .pmf)

        let circuit = try NetlistLowering().lower(
            ParsedNetlist(components: [component], models: [model])
        )

        #expect(circuit.instances.first?.typeName == "pmesfet")
    }

    @Test("Unsupported MESFET model parameters fail during lowering")
    func unsupportedModelParameterFails() {
        let component = ParsedComponent(
            name: "Zbad",
            type: .mesfet,
            nodes: ["drain", "gate", "source"],
            modelName: "model"
        )
        let model = ParsedModel(
            name: "model",
            type: .nmf,
            parameters: ["unsupported": .numeric(1)]
        )

        #expect(throws: LoweringError.self) {
            _ = try NetlistLowering().lower(
                ParsedNetlist(components: [component], models: [model])
            )
        }
    }

    private func real(_ parameter: String, in instance: Instance) -> Double? {
        guard case .real(let value) = instance.parameters[parameter] else {
            return nil
        }
        return value
    }
}
