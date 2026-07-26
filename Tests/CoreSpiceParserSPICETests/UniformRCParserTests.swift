import Testing
@testable import CoreSpiceParsedIR
@testable import CoreSpiceParserSPICE

@Suite("Uniform RC parser")
struct UniformRCParserTests {
    @Test("Standard three-terminal URC syntax preserves model and instance parameters")
    func parsesStandardURCLine() async throws {
        let source = """
        uniform rc parser fixture
        U1 input output substrate urc_model L=50u N=6
        .model urc_model URC K=1.2 FMAX=6.5Meg RPERL=10 CPERL=1p
        .end
        """

        let result = await SPICEParser().parse(source: source)

        #expect(result.isSuccess)
        let netlist = try result.get()
        let line = try #require(netlist.components.first)
        #expect(line.type == .uniformRC)
        #expect(line.nodes.map(\.name) == ["input", "output", "substrate"])
        #expect(line.modelName == "urc_model")
        guard case .numeric(let length) = line.parameters["l"] else {
            Issue.record("Expected a numeric URC length")
            return
        }
        #expect(abs(length - 50e-6) < 1e-18)
        #expect(line.parameters["n"] == .numeric(6))
        let model = try #require(netlist.models.first)
        #expect(model.type == .urc)
        #expect(model.parameters["k"] == .numeric(1.2))
        #expect(model.parameters["fmax"] == .numeric(6.5e6))
        #expect(model.parameters["rperl"] == .numeric(10))
        #expect(model.parameters["cperl"] == .numeric(1e-12))
    }
}
