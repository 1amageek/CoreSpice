import Testing
import CoreSpiceIO
import CoreSpiceCompactModels

@Suite("Quoted SPICE values through public lowering", .timeLimit(.minutes(1)))
struct SPICEQuotedValueExecutionTests {
    @Test
    func quotedNumericValuesLowerAndRoundTripAcrossTheirConsumers() async throws {
        let source = """
        Quoted numeric values retain their executable meaning
        .func twice(x) {x*2}
        .param base='1000' product='base*2' function_value='twice(product)'
        .model process nmos level=1 kp='product' vto='twice(1)'
        .subckt cell p n r='product'
        .param body='r*3'
        R1 p n 'body'
        .ends cell
        V1 source 0 1
        Rreference source 0 'base'
        Rproduct source 0 'base*2'
        Rfunction source 0 'twice(base)'
        Rglobal source 0 'function_value'
        Xdefault source 0 cell
        Xoverride source 0 cell r='twice(product)'
        M1 drain gate 0 0 process w=1u l=1u
        .end
        """
        let parsed = try await SPICEIO.parse(source).get()
        let serialized = SPICESerializer().serialize(parsed, options: .default)
        for text in [source, serialized] {
            let inputKind = text == source ? "original" : "roundtrip"
            let ir = try await SPICEIO.parseAndLower(text, configuration: .init(expandModels: true))
            #expect(ir.instances.count == 8)
            // These values follow the source arithmetic, independently of the
            // parser's representation and the serializer's choice of delimiter.
            for (name, resistance) in [("rreference", 1000.0), ("rproduct", 2000.0),
                                       ("rfunction", 2000.0), ("rglobal", 4000.0),
                                       ("xdefault.r1", 6000.0), ("xoverride.r1", 12000.0)] {
                let resistor = try #require(ir.instances.first { $0.name == name })
                #expect(resistor.typeName == "resistor")
                try Self.expectReal(resistor.parameters["r"], equals: resistance, name: "\(inputKind): \(name)")
            }
            let mos = try #require(ir.instances.first { $0.name == "m1" })
            #expect(mos.typeName == "nmos_l1")
            try Self.expectReal(mos.parameters["kp"], equals: 2000, name: "\(inputKind): model kp")
            try Self.expectReal(mos.parameters["vto"], equals: 2, name: "\(inputKind): model vto")
            try Self.expectReal(mos.parameters["w"], equals: 1e-6, name: "\(inputKind): instance width")
            try Self.expectReal(mos.parameters["l"], equals: 1e-6, name: "\(inputKind): instance length")
        }
    }

    @Test(arguments: ["'", "\""])
    func quotedModelVersionRetainsExactIdentityAndNativeRefusal(delimiter: String) async throws {
        let source = """
        Model version is an exact text role
        .model process nmos level=54 version=\(delimiter)4.5\(delimiter) vth0=0.7 u0=0.05 toxe=10n
        VD drain 0 1
        VG gate 0 1.2
        M1 drain gate 0 0 process w=10u l=1u
        .end
        """
        let parsed = try await SPICEIO.parse(source).get()
        let serialized = SPICESerializer().serialize(parsed, options: .default)
        let policy = try BSIM4PreparationPolicy(maximumStressIterations: 8)
        for text in [source, serialized] {
            let netlist = try await SPICEIO.parse(text).get()
            let model = try #require(netlist.models.first)
            guard case .string(let version) = try #require(model.parameters["version"]) else {
                Issue.record("A model version lost its exact text identity")
                return
            }
            #expect(version == "4.5")
            // Public lowering performs cold Level54 native admission with this
            // explicit work policy. The original 4.5 identity must be refused,
            // rather than rounded or silently replaced with supported 4.8.3.
            do {
                _ = try await SPICEIO.parseAndLower(
                    text, configuration: .init(bsim4PreparationPolicy: policy)
                )
                Issue.record("The unsupported original model version was admitted")
            } catch let error as BSIM4Error {
                #expect(error == .unsupportedVersion("4.5"))
            }
        }
    }

    private static func expectReal(_ value: ParameterValue?, equals expected: Double, name: String) throws {
        guard case .real(let actual) = try #require(value, "Missing lowered numeric parameter: \(name)") else {
            Issue.record("\(name) did not lower to a real-valued parameter")
            return
        }
        #expect(actual == expected, "\(name), actual=\(actual), expected=\(expected)")
    }
}
