import Testing
@testable import CoreSpiceParserSPICE
@testable import CoreSpiceParser
@testable import CoreSpiceParsedIR

/// Regression for the current-source value-key bug. The parser previously stored
/// a current source's DC value under "v" (like a voltage source), but
/// CurrentSourceDescriptor reads it from "i", so every plain DC current source
/// silently became 0 A. The value must land under "i".
@Suite("Current source value parsing")
struct CurrentSourceValueTests {

    private func dcCurrent(_ source: String) async -> Double? {
        let result = await SPICEParser().parse(source: source)
        guard let comp = result.netlist?.components.first(where: { $0.type == .currentSource }) else {
            return nil
        }
        if case .numeric(let v)? = comp.parameters["i"] {
            return v
        }
        return nil
    }

    @Test("Bare positional current value maps to the i parameter")
    func bareValueMapsToI() async {
        let v = await dcCurrent("isrc\nI1 a 0 1m\n.end\n")
        #expect(v != nil)
        #expect(abs((v ?? 0) - 1e-3) <= 1e-12)
    }

    @Test("dc-keyword current value maps to the i parameter")
    func dcKeywordMapsToI() async {
        let v = await dcCurrent("isrc\nI1 a 0 dc 20u\n.end\n")
        #expect(v != nil)
        #expect(abs((v ?? 0) - 20e-6) <= 1e-15)
    }

    private func voltageValue(_ source: String) async -> Double? {
        let result = await SPICEParser().parse(source: source)
        guard let comp = result.netlist?.components.first(where: { $0.type == .voltageSource }) else {
            return nil
        }
        if case .numeric(let v)? = comp.parameters["v"] {
            return v
        }
        return nil
    }

    @Test("Negative DC source value parses (dc keyword)")
    func negativeDcKeyword() async {
        let v = await voltageValue("neg\nV1 a 0 dc -2\n.end\n")
        #expect(v != nil)
        #expect(abs((v ?? 0) - (-2.0)) <= 1e-12)
    }

    @Test("Negative bare positional source value parses")
    func negativeBarePositional() async {
        let v = await voltageValue("neg\nV1 a 0 -2\n.end\n")
        #expect(v != nil)
        #expect(abs((v ?? 0) - (-2.0)) <= 1e-12)
    }
}
