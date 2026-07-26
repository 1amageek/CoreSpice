import Testing
@testable import CoreSpiceParsedIR
@testable import CoreSpiceParserSPICE

@Suite("Transmission-line parser")
struct TransmissionLineParserTests {
    @Test("Standard lossless T-line syntax preserves four terminals and delay parameters")
    func parsesLosslessTransmissionLine() async throws {
        let source = """
        lossless transmission line
        T1 input 0 output 0 Z0=50 TD=2n
        T2 a b c d Z0=75 F=1G NL=0.5
        .end
        """

        let result = await SPICEParser().parse(source: source)

        #expect(result.isSuccess)
        let netlist = try result.get()
        let first = try #require(netlist.components.first)
        #expect(first.type == .transmissionLine)
        #expect(first.nodes.map(\.name) == ["input", "0", "output", "0"])
        #expect(first.modelName == nil)
        #expect(first.parameters["z0"] == .numeric(50))
        #expect(first.parameters["td"] == .numeric(2e-9))

        let second = try #require(netlist.components.dropFirst().first)
        #expect(second.parameters["z0"] == .numeric(75))
        #expect(second.parameters["f"] == .numeric(1e9))
        #expect(second.parameters["nl"] == .numeric(0.5))
    }
}
