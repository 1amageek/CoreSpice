import Foundation
import Testing

@Suite("Reliability contract")
struct ReliabilityContractTests {

    private struct Coverage: Decodable {
        struct Analysis: Decodable {
            let id: String
            let status: String
            let requiredGates: [String]
        }

        let schemaVersion: Int
        let analyses: [Analysis]
    }

    private struct DevicePassports: Decodable {
        struct Device: Decodable {
            let typeName: String
            let modelFamily: String
            let supportedAnalyses: [String]
            let supportedRegions: [String]
            let parameterPolicy: String
            let oracleRequirements: [String]
            let knownLimitations: [String]
        }

        let schemaVersion: Int
        let devices: [Device]
    }

    private struct CorpusManifest: Decodable {
        struct Case: Decodable {
            let id: String
            let name: String
            let analysis: String
            let oracle: String
            let regressionFixtureRequired: Bool
            let tolerance: String
        }

        let schemaVersion: Int
        let cases: [Case]
    }

    private struct ProductionQualificationContract: Decodable {
        struct NativeModelEnvelope: Decodable {
            let classification: String
            let productionQualificationIssuedByCoreSpice: Bool
        }

        struct FoundryExecution: Decodable {
            let nativeCompactModelStatus: String
            let unsupportedModelFamilies: [String]
            let requiredExecutionClass: String
        }

        struct ProductionTrust: Decodable {
            let qualificationAuthority: String
            let evidenceSchema: String
            let requiredIdentityArtifactRoles: [String]
            let requiredRunArtifactRoles: [String]
            let requirements: [String]
        }

        let schemaVersion: Int
        let nativeModelEnvelope: NativeModelEnvelope
        let foundryExecution: FoundryExecution
        let productionTrust: ProductionTrust
    }

    private func decode<T: Decodable>(
        _ resource: CoreSpiceValidationFixture,
        as type: T.Type
    ) throws -> T {
        let url = try resource.url
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(T.self, from: data)
    }

    @Test("Analysis coverage contract names every public analysis")
    func analysisCoverageNamesEveryPublicAnalysis() throws {
        let coverage = try decode(.analysisCoverage, as: Coverage.self)
        #expect(coverage.schemaVersion == 1)

        let expected: Set<String> = ["op", "dc", "ac", "tran", "noise", "tf", "pz", "four", "sens", "mc"]
        let actual = Set(coverage.analyses.map(\.id))
        #expect(actual == expected)

        for analysis in coverage.analyses {
            #expect(!analysis.status.isEmpty)
            #expect(!analysis.requiredGates.isEmpty)
        }
    }

    @Test("Device passports cover the built-in electrical devices")
    func devicePassportsCoverBuiltInElectricalDevices() throws {
        let passports = try decode(.devicePassports, as: DevicePassports.self)
        #expect(passports.schemaVersion == 1)

        let expected: Set<String> = [
            "resistor", "capacitor", "inductor", "vsource", "isource",
            "mutual",
            "vcvs", "vccs", "ccvs", "cccs", "ccvs_ref", "cccs_ref",
            "vswitch", "cswitch", "cswitch_ref",
            "diode", "npn", "pnp",
            "njfet", "pjfet",
            "nmos_l1", "pmos_l1", "nmos_l2", "pmos_l2", "nmos_l3", "pmos_l3",
            "optoelectronic"
        ]
        let actual = Set(passports.devices.map(\.typeName))
        #expect(expected.isSubset(of: actual))

        for device in passports.devices {
            #expect(!device.modelFamily.isEmpty)
            #expect(!device.supportedAnalyses.isEmpty)
            #expect(!device.supportedRegions.isEmpty)
            #expect(!device.parameterPolicy.isEmpty)
            #expect(!device.oracleRequirements.isEmpty)
            _ = device.knownLimitations
        }

        let voltageSwitch = try #require(
            passports.devices.first { $0.typeName == "vswitch" }
        )
        #expect(voltageSwitch.parameterPolicy.contains("vh must be finite and equal to zero"))
        #expect(
            voltageSwitch.knownLimitations.contains {
                $0.contains("non-zero vh is rejected")
            }
        )

        for typeName in ["cswitch", "cswitch_ref"] {
            let currentSwitch = try #require(
                passports.devices.first { $0.typeName == typeName }
            )
            #expect(currentSwitch.parameterPolicy.contains("ih must be finite and equal to zero"))
            #expect(
                currentSwitch.knownLimitations.contains {
                    $0.contains("non-zero ih is rejected")
                }
            )
        }
    }

    @Test("Regression corpus manifest matches the committed fixture")
    func regressionCorpusManifestMatchesRegressionFixture() throws {
        let manifest = try decode(.corpusManifest, as: CorpusManifest.self)
        #expect(manifest.schemaVersion == 1)
        #expect(manifest.cases.count == 31)

        var seenIDs: Set<String> = []
        var seenNames: Set<String> = []
        for item in manifest.cases {
            #expect(!item.id.isEmpty)
            #expect(!item.name.isEmpty)
            #expect(!item.analysis.isEmpty)
            #expect(!item.oracle.isEmpty)
            #expect(!item.tolerance.isEmpty)
            #expect(seenIDs.insert(item.id).inserted)
            #expect(seenNames.insert(item.name).inserted)
        }

        let regressionFixtureURL = try CoreSpiceValidationFixture.regressionReference.url
        let regressionFixtureData = try Data(contentsOf: regressionFixtureURL)
        let regressionFixtureObject = try JSONSerialization.jsonObject(with: regressionFixtureData)
        guard let regressionFixture = regressionFixtureObject as? [String: Any] else {
            throw ReliabilityContractError.invalidRegressionFixtureJSON
        }
        let requiredRegressionFixtures = Set(manifest.cases.filter(\.regressionFixtureRequired).map(\.name))
        #expect(Set(regressionFixture.keys) == requiredRegressionFixtures)
    }

    @Test("Production qualification contract blocks native foundry promotion")
    func productionQualificationContractSeparatesNativeRegressionFromFoundryTrust() throws {
        let contract = try decode(.productionQualificationContract, as: ProductionQualificationContract.self)

        #expect(contract.schemaVersion == 1)
        #expect(contract.nativeModelEnvelope.classification == "supported-model-regression")
        #expect(!contract.nativeModelEnvelope.productionQualificationIssuedByCoreSpice)
        #expect(contract.foundryExecution.nativeCompactModelStatus == "unsupported")
        #expect(Set(contract.foundryExecution.unsupportedModelFamilies) == Set(["bsim3", "bsim4"]))
        #expect(contract.foundryExecution.requiredExecutionClass == "qualified-external-foundry-model-simulator")
        #expect(contract.productionTrust.qualificationAuthority == "ToolQualification")
        #expect(contract.productionTrust.evidenceSchema == "ToolProcessQualificationEvidence")
        #expect(!contract.productionTrust.requiredIdentityArtifactRoles.isEmpty)
        #expect(!contract.productionTrust.requiredRunArtifactRoles.isEmpty)
        #expect(!contract.productionTrust.requirements.isEmpty)
    }
}

private enum ReliabilityContractError: Error {
    case invalidRegressionFixtureJSON
}
