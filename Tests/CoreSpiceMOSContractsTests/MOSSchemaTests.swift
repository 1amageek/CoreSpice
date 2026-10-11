import CoreSpiceMOSContracts
import Testing

@Suite("Exact MOS schema contracts")
struct MOSSchemaTests {
    @Test func exactReleaseIdentityAndInspectionAreIndependentOfExecution() throws {
        #expect(try MOSModelRelease.resolve(level: 49, version: "3.3.0", profile: .coreStrictV1) == .bsim3_3_3_0)
        #expect(try MOSModelRelease.resolve(level: 54, version: "4.5", profile: .coreStrictV1) == .bsim4_4_5)
        #expect(throws: MOSSchemaFailure.unsupportedRelease(level: 54, version: nil)) {
            try MOSModelRelease.resolve(level: 54, version: nil, profile: .coreStrictV1)
        }
        for version in ["4.50", "4.500000e+0", "4.8", "4.8.30", "4.62"] {
            #expect(throws: MOSSchemaFailure.unsupportedRelease(level: 54, version: version)) {
                try MOSModelRelease.resolve(level: 54, version: version, profile: .coreStrictV1)
            }
        }
        let provider: any MOSModelSchemaProviding = StandardMOSModelSchemas()
        let inspect = try provider.schema(for: .bsim4_4_5)
        #expect(try inspect.parameter(named: "vth0", role: .model).kind == .real)
        #expect(MOSModelRelease.bsim4_4_5.exactVersion == "4.5.0")
        #expect(try MOSModelRelease.resolve(level: 54, version: "4.5.0", profile: .coreStrictV1) == .bsim4_4_5)
        #expect(try MOSModelRelease.resolve(level: 54, version: "4.500000e+0", profile: .pinnedNgspiceNormalV1) == .bsim4_4_5)
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
        for name in ["mulu0", "dtemp", "gidlmod"] {
            let role: MOSParameterRole = name == "gidlmod" ? .model : .instance
            #expect(throws: MOSSchemaFailure.unknownParameter(name: name, role: role, release: .bsim4_4_5)) {
                try MOSModelSchema(release: .bsim4_4_5).parameter(named: name, role: role)
            }
        }
        #expect(throws: MOSSchemaFailure.unknownParameter(name: "mulu0", role: .instance, release: .bsim4_4_8_3)) {
            try MOSModelSchema(release: .bsim4_4_8_3).parameter(named: "mulu0", role: .instance)
        }
        #expect(throws: MOSSchemaFailure.unknownParameter(name: "nf", role: .instance, release: .bsim3_3_3_0)) {
            try MOSModelSchema(release: .bsim3_3_3_0).parameter(named: "nf", role: .instance)
        }
    }

    @Test func originalSelectorsKeepRoleAndFrontendOwnershipSeparate() throws {
        let schema = MOSModelSchema(release: .bsim4_4_5)
        let sc = try schema.parameter(named: "sc", role: .instance)
        let sca = try schema.parameter(named: "sca", role: .instance)
        guard case .native(let scID) = sc.authority,
              case .native(let scaID) = sca.authority else { Issue.record("Missing original selector identity"); return }
        #expect(scID != scaID && scID.schema.revision == 2 && scID.role == .instance)
        #expect(sc.scale == .length && sca.scale == .none)
        #expect(try schema.parameter(named: "m", role: .instance).authority == .parallelMultiplicity)
        for (index, name) in ["ic_vds", "ic_vgs", "ic_vbs"].enumerated() {
            #expect(try schema.parameter(named: name, role: .instance).authority == .initialConditionComponent(index))
        }
        #expect(try schema.parameter(named: "delvt0", role: .instance).authority == schema.parameter(named: "delvto", role: .instance).authority)
        #expect(try schema.parameter(named: "vtho", role: .model).authority == schema.parameter(named: "vth0", role: .model).authority)
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
