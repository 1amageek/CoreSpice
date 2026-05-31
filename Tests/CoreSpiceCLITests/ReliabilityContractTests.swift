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
            "vcvs", "vccs", "ccvs", "cccs",
            "diode", "npn", "pnp",
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
}
