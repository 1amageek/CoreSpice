import Testing
@testable import CoreSpiceIR
@testable import CoreSpiceLowering
@testable import CoreSpiceParsedIR

@Suite("Transmission-line lowering")
struct TransmissionLineLoweringTests {
    @Test("Lossless T-line lowers with one owned current branch per port")
    func lowersLosslessTransmissionLine() throws {
        let component = ParsedComponent(
            name: "T1",
            type: .transmissionLine,
            nodes: ["input", "0", "output", "0"],
            parameters: ["z0": .numeric(50), "td": .numeric(1e-9)]
        )

        let circuit = try NetlistLowering().lower(
            ParsedNetlist(components: [component])
        )
        let instance = try #require(circuit.instances.first)

        #expect(instance.typeName == "tline")
        #expect(instance.nodes.count == 4)
        #expect(instance.ownedBranches.count == 2)
        #expect(circuit.branches.count == 2)
        #expect(real("z0", in: instance) == 50)
        #expect(real("td", in: instance) == 1e-9)
    }

    @Test("Unsupported lossless-line parameters fail explicitly")
    func rejectsUnsupportedParameter() {
        let component = ParsedComponent(
            name: "Tbad",
            type: .transmissionLine,
            nodes: ["a", "0", "b", "0"],
            parameters: [
                "z0": .numeric(50),
                "td": .numeric(1e-9),
                "ic": .numeric(1),
            ]
        )

        #expect(throws: LoweringError.self) {
            _ = try NetlistLowering().lower(
                ParsedNetlist(components: [component])
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
