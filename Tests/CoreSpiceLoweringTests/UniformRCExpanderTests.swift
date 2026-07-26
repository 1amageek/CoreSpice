import Testing
@testable import CoreSpiceIR
@testable import CoreSpiceLowering
@testable import CoreSpiceParsedIR

@Suite("Uniform RC lowering")
struct UniformRCExpanderTests {
    @Test("Geometric ladder conserves declared total resistance and capacitance")
    func geometricLadderConservesTotals() throws {
        let line = ParsedComponent(
            name: "U1",
            type: .uniformRC,
            nodes: ["in", "out", "0"],
            modelName: "urc_model",
            parameters: ["l": .numeric(1), "n": .numeric(2)]
        )
        let model = ParsedModel(
            name: "urc_model",
            type: .urc,
            parameters: [
                "k": .numeric(2),
                "rperl": .numeric(100),
                "cperl": .numeric(10e-12),
            ]
        )

        let circuit = try NetlistLowering().lower(
            ParsedNetlist(components: [line], models: [model])
        )

        let resistors = circuit.instances.filter { $0.typeName == "resistor" }
        let capacitors = circuit.instances.filter { $0.typeName == "capacitor" }
        #expect(resistors.count == 4)
        #expect(capacitors.count == 3)
        #expect(approximately(sum(of: "r", in: resistors), 100))
        #expect(approximately(sum(of: "c", in: capacitors), 10e-12))
        #expect(circuit.instances.allSatisfy { $0.typeName != "urc" })
    }

    @Test("Nonzero junction current expands shunts into explicit diode networks")
    func nonlinearShuntsAreExplicit() throws {
        let line = ParsedComponent(
            name: "U1",
            type: .uniformRC,
            nodes: ["in", "out", "substrate"],
            modelName: "urc_model",
            parameters: ["l": .numeric(2), "n": .numeric(2)]
        )
        let model = ParsedModel(
            name: "urc_model",
            type: .urc,
            parameters: [
                "rperl": .numeric(50),
                "cperl": .numeric(5e-12),
                "isperl": .numeric(2e-12),
                "rsperl": .numeric(3),
            ]
        )

        let circuit = try NetlistLowering().lower(
            ParsedNetlist(components: [line], models: [model])
        )

        let firstDiode = try #require(circuit.instances.first { $0.name == "U1.lo1.d" })
        let secondDiode = try #require(circuit.instances.first { $0.name == "U1.lo2.d" })
        #expect(approximately(real("is", in: secondDiode) / real("is", in: firstDiode), 1.5))
        #expect(approximately(real("cjo", in: secondDiode) / real("cjo", in: firstDiode), 1.5))
        let firstSeries = try #require(circuit.instances.first { $0.name == "U1.lo1.rs" })
        let secondSeries = try #require(circuit.instances.first { $0.name == "U1.lo2.rs" })
        #expect(approximately(real("r", in: firstSeries), 12))
        #expect(approximately(real("r", in: secondSeries), 8))
    }

    @Test("Malformed physical parameters fail with a typed lowering error")
    func invalidPropagationFails() {
        let line = ParsedComponent(
            name: "Ubad",
            type: .uniformRC,
            nodes: ["in", "out", "0"],
            modelName: "urc_model",
            parameters: ["l": .numeric(1)]
        )
        let model = ParsedModel(
            name: "urc_model",
            type: .urc,
            parameters: ["k": .numeric(1)]
        )

        #expect(throws: LoweringError.self) {
            _ = try NetlistLowering().lower(
                ParsedNetlist(components: [line], models: [model])
            )
        }
    }

    @Test("Expansion rejects unbounded explicit lump counts")
    func excessiveLumpCountFails() {
        let line = ParsedComponent(
            name: "Uhuge",
            type: .uniformRC,
            nodes: ["in", "out", "0"],
            modelName: "urc_model",
            parameters: ["l": .numeric(1), "n": .numeric(101)]
        )
        let model = ParsedModel(
            name: "urc_model",
            type: .urc,
            parameters: [:]
        )

        #expect(throws: LoweringError.self) {
            _ = try NetlistLowering().lower(
                ParsedNetlist(components: [line], models: [model])
            )
        }
    }

    private func sum(of parameter: String, in instances: [Instance]) -> Double {
        instances.reduce(0) { $0 + real(parameter, in: $1) }
    }

    private func real(_ parameter: String, in instance: Instance) -> Double {
        guard case .real(let value) = instance.parameters[parameter] else {
            Issue.record("Expected real parameter \(parameter) on \(instance.name)")
            return .nan
        }
        return value
    }

    private func approximately(_ value: Double, _ expected: Double) -> Bool {
        abs(value - expected) <= 1e-12 * max(1, abs(expected))
    }
}
