import CoreSpiceMOSContracts
import Testing

@Suite("Exact MOS schema contracts")
struct MOSSchemaTests {
    @Test func exactReleaseIdentityAndInspectionAreIndependentOfExecution() throws {
        #expect(try MOSModelRelease.resolve(level: 49, version: "3.3.0") == .bsim3_3_3_0)
        #expect(try MOSModelRelease.resolve(level: 54, version: "4.5") == .bsim4_4_5)
        #expect(throws: MOSSchemaFailure.unsupportedRelease(level: 54, version: nil)) {
            try MOSModelRelease.resolve(level: 54, version: nil)
        }
        for version in ["4.50", "4.5.0", "4.8", "4.8.30"] {
            #expect(throws: MOSSchemaFailure.unsupportedRelease(level: 54, version: version)) {
                try MOSModelRelease.resolve(level: 54, version: version)
            }
        }
        let provider: any MOSModelSchemaProviding = StandardMOSModelSchemas()
        let inspect = try provider.schema(for: .bsim4_4_5)
        #expect(try inspect.parameter(named: "vth0", role: .model).kind == .real)
        #expect(throws: MOSSchemaFailure.nonExecutableRelease(.bsim4_4_5)) { try inspect.requireExecutable() }
        try provider.schema(for: .bsim4_4_8_3).requireExecutable()
        #expect(MOSInputProfile.allCases.count == 2)
        #expect(MOSInputProfile.pinnedNgspiceCommit == "ebdaf58ec76a06ffaac7e0f138360dd1cf5ee4b6")
    }

    @Test func exactSetterRulesDoNotGuessDimensionsOrConflateReleases() throws {
        for release in [MOSModelRelease.bsim4_4_5, .bsim4_4_8_3] {
            let schema = MOSModelSchema(release: release)
            for name in ["l", "w", "pd", "ps", "sa", "sb", "sd", "sc"] {
                #expect(try schema.parameter(named: name, role: .instance).scale == .length)
            }
            for name in ["ad", "as"] { #expect(try schema.parameter(named: name, role: .instance).scale == .area) }
            for name in ["m", "nf", "nrs", "nrd", "sca", "scb", "scc", "xgw"] {
                #expect(try schema.parameter(named: name, role: .instance).scale == .none)
            }
            for name in ["lmin", "lmax", "wmin", "wmax", "binunit", "toxe"] {
                #expect(try schema.parameter(named: name, role: .model).scale == .none)
            }
            #expect(try schema.parameter(named: "rgatemod", role: .instance).kind == .integer)
            #expect(try schema.parameter(named: "vtho", role: .model).canonicalName == "vth0")
            #expect(try schema.parameter(named: "vth0", role: .model).canonicalName == "vth0")
            #expect(try schema.parameter(named: "off", role: .instance).kind == .flag)
            try schema.parameter(named: "nf", role: .instance).validate(1.5)
        }
        #expect(try MOSModelSchema(release: .bsim4_4_5).parameter(named: "mulu0", role: .instance).kind == .real)
        #expect(throws: MOSSchemaFailure.unknownParameter(name: "mulu0", role: .instance, release: .bsim4_4_8_3)) {
            try MOSModelSchema(release: .bsim4_4_8_3).parameter(named: "mulu0", role: .instance)
        }
        #expect(throws: MOSSchemaFailure.unknownParameter(name: "nf", role: .instance, release: .bsim3_3_3_0)) {
            try MOSModelSchema(release: .bsim3_3_3_0).parameter(named: "nf", role: .instance)
        }
    }

    @Test func scalingPreservesRepresentableAreaAndRefusesUnderflowOverflowAndNonfinite() throws {
        let converted = try MOSParameterScale.area.apply(to: 1e-300, scale: 1e200)
        #expect(abs(converted / 1e100 - 1) < 1e-14)
        #expect(try MOSParameterScale.area.apply(to: 0, scale: 1e200) == 0)
        for (rule, value, scale) in [(MOSParameterScale.length, 1e-300, 1e-200),
                                    (.area, 1e200, 1e200), (.length, .infinity, 1),
                                    (.length, 1, .nan), (.area, 1, 0)] {
            #expect(throws: MOSSchemaFailure.invalidValue(name: "scale")) { try rule.apply(to: value, scale: scale) }
        }
    }
}
