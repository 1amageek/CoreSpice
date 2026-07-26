import Testing
@testable import CoreSpiceParsedIR
@testable import CoreSpiceParserSPICE

@Suite("Signed source waveform parsing")
struct SignedWaveformParserTests {
    @Test("PULSE preserves a negative first level")
    func parsesNegativePulseLevel() async throws {
        let result = await SPICEParser().parse(
            source:
            """
            signed pulse
            V1 out 0 pulse(-2 1 0 1n 1n 2n 5n)
            .end
            """,
            fileName: "signed-pulse.cir"
        )
        let netlist = try result.get()
        let source = try #require(netlist.components.first)

        #expect(numeric("v1", in: source) == -2)
        #expect(numeric("v2", in: source) == 1)
        #expect(abs(numeric("tr", in: source) - 1e-9) < 1e-20)
    }

    @Test("SIN preserves negative offset and phase")
    func parsesSignedSineValues() async throws {
        let result = await SPICEParser().parse(
            source:
            """
            signed sine
            V1 out 0 sin(-1 2 1k 0 -90)
            .end
            """,
            fileName: "signed-sine.cir"
        )
        let netlist = try result.get()
        let source = try #require(netlist.components.first)

        #expect(numeric("vo", in: source) == -1)
        #expect(numeric("va", in: source) == 2)
        #expect(numeric("phase", in: source) == -90)
    }

    private func numeric(_ key: String, in component: ParsedComponent) -> Double {
        guard case .numeric(let value) = component.parameters[key] else {
            Issue.record("Expected numeric parameter \(key)")
            return .nan
        }
        return value
    }
}
