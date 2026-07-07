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
            let goldenRequired: Bool
            let tolerance: String
        }

        let schemaVersion: Int
        let cases: [Case]
    }

    private func packageRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func decode<T: Decodable>(_ relativePath: String, as type: T.Type) throws -> T {
        let url = packageRoot().appendingPathComponent(relativePath)
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(T.self, from: data)
    }

    @Test("Analysis coverage contract names every public analysis")
    func analysisCoverageNamesEveryPublicAnalysis() throws {
        let coverage = try decode("validation/analysis-coverage.json", as: Coverage.self)
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
        let passports = try decode("validation/device-passports.json", as: DevicePassports.self)
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
    }

    @Test("Trust-gate corpus manifest matches committed golden references")
    func trustGateCorpusManifestMatchesGoldenReferences() throws {
        let manifest = try decode("validation/corpus-manifest.json", as: CorpusManifest.self)
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

        let goldenURL = packageRoot().appendingPathComponent("validation/golden.json")
        let goldenData = try Data(contentsOf: goldenURL)
        let goldenObject = try JSONSerialization.jsonObject(with: goldenData)
        guard let golden = goldenObject as? [String: Any] else {
            throw ReliabilityContractError.invalidGoldenJSON
        }
        let requiredGolden = Set(manifest.cases.filter(\.goldenRequired).map(\.name))
        #expect(Set(golden.keys) == requiredGolden)
    }
}

private enum ReliabilityContractError: Error {
    case invalidGoldenJSON
}
