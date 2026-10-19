import CoreSpiceIR
import CoreSpiceParsedIR
import CoreSpiceParserSPICE
import CoreSpiceLowering
import Testing
import CoreSpiceMOSContracts

@Suite("Charge capacitor selected lowering", .timeLimit(.minutes(1)))
struct ChargeCapacitorLoweringTests {
    @Test func unusedChargeBodyRemainsUnevaluatedAndSelectedUnknownScalarFails() async throws {
        let source = """
        selected charge closure
        V1 out 0 1
        R1 out 0 1k
        .subckt varactor a
        .param unused=missing
        Cq a 0 q={unresolved*v(a)}
        .ends
        .end
        """
        let parsed = try await SPICEParser().parse(source: source).get()
        let ir = try FrontendTestLowering().lower(parsed)
        #expect(Set(ir.instances.map(\.name)) == Set(["v1", "r1"]))
        let charge = try await SPICEParser().parse(source: "charge\nCq out 0 q={unresolved*v(out)}\n.end\n").get()
        #expect(throws: (any Error).self) { _ = try FrontendTestLowering().lower(charge) }
    }

    @Test func totalChargeAndDifferentialCapacitanceKeepDistinctKeysAndDependencies() async throws {
        let parsed = try await SPICEParser().parse(source: """
        independent capacitor laws
        Cq out 0 q={1n*v(control)}
        Cc out 0 c={2n+1n*v(control)}
        Cconstant other 0 q={3n}
        .end
        """).get()
        let ir = try FrontendTestLowering().lower(parsed)
        for (name, key) in [("cq", "q"), ("cc", "c")] {
            let instance = try #require(ir.instances.first { $0.name == name })
            guard case .behavioralExpression = instance.parameters[key] else {
                Issue.record("Capacitor law lost its expression role"); return
            }
            #expect(instance.referencedNodes.count == 1)
            #expect(instance.parameters[key == "q" ? "c" : "q"] == nil)
        }
        let constant = try #require(ir.instances.first { $0.name == "cconstant" })
        guard case .behavioralExpression(.constant(let charge)) = constant.parameters["q"] else {
            Issue.record("Constant total charge was interpreted as capacitance"); return
        }
        // SPICE suffixes multiply independently rounded binary64 mantissa and scale values.
        let mantissa = 3.0
        let nanoScale = 1e-9
        #expect(charge.bitPattern == (mantissa * nanoScale).bitPattern)
    }

    @Test func modelCapacitanceRetainsItsSourceAndScaledGeometry() async throws {
        let parsed = try await SPICEParser().parse(source: """
        model capacitor role
        .model cm C cox=1n capsw=2p
        C1 out 0 cm l=2 w=3
        .end
        """).get()
        let ir = try FrontendTestLowering(configuration: .init(geometryScale: 1e-6)).lower(parsed)
        let cap = try #require(ir.instances.first)
        #expect(cap.model?.name == "cm")
        #expect(cap.parameters["cox"] == nil)
        guard case .real(let length) = cap.parameters["l"], case .real(let width) = cap.parameters["w"] else {
            Issue.record("Missing source geometry"); return
        }
        #expect(length == 2e-6)
        #expect(width == 3e-6)
    }

    @Test func runtimeCapacitanceCannotDiscardASelectedModel() async throws {
        let parsed = try await SPICEParser().parse(source:
            "mixed runtime model\n.model cm C cap=1n\nC1 out 0 cm c={1n*v(out)}\n.end\n").get()
        #expect(throws: LoweringError.self) { _ = try FrontendTestLowering().lower(parsed) }
    }
}
