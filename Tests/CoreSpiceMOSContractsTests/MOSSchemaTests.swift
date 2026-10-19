import CoreSpiceMOSContracts
import Testing

@Suite("Classical MOS schema contracts")
struct MOSSchemaTests {
    @Test func nativeReleaseDomainContainsOnlyClassicalLevels() throws {
        #expect(MOSModelRelease.allCases == [.level1, .level2, .level3])
        for level in 1...3 {
            let release = try MOSModelRelease.resolve(level: level, version: nil, profile: .coreStrictV1)
            #expect(release.level == level && release.exactVersion == nil)
            #expect(release.schemaIdentity.revision == 1)
            #expect(throws: MOSSchemaFailure.unsupportedRelease(level: level, version: "4.5")) {
                try MOSModelRelease.resolve(level: level, version: "4.5", profile: .coreStrictV1)
            }
        }
        for profile in MOSInputProfile.allCases {
            for (level, version) in [(49, nil), (49, "3.3.0"), (54, nil), (54, "4.5"),
                                      (54, "4.5.0"), (54, "4.8.3"), (54, "4.500000e+0")] as [(Int, String?)] {
                #expect(throws: MOSSchemaFailure.osdiBindingRequired(level: level, version: version)) {
                    try MOSModelRelease.resolve(level: level, version: version, profile: profile)
                }
            }
        }
    }

    @Test func classicalParameterAdmissionDoesNotInheritCompactModelFields() throws {
        let provider: any MOSModelSchemaProviding = StandardMOSModelSchemas()
        for release in MOSModelRelease.allCases {
            let schema = try provider.schema(for: release)
            for name in ["l", "w", "pd", "ps"] {
                #expect(try schema.parameter(named: name, role: .instance).scale == .length)
            }
            for name in ["ad", "as"] {
                #expect(try schema.parameter(named: name, role: .instance).scale == .area)
            }
            #expect(try schema.parameter(named: "m", role: .instance).scale == .none)
            #expect(try schema.parameter(named: "vto", role: .model).kind == .real)
            for name in ["nf", "sa", "sc", "trnqsmod", "rgatemod"] {
                #expect(throws: MOSSchemaFailure.unknownParameter(name: name, role: .instance, release: release)) {
                    try schema.parameter(named: name, role: .instance)
                }
            }
            for name in ["toxe", "lmin", "binunit", "vth0", "version"] {
                #expect(throws: MOSSchemaFailure.unknownParameter(name: name, role: .model, release: release)) {
                    try schema.parameter(named: name, role: .model)
                }
            }
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
