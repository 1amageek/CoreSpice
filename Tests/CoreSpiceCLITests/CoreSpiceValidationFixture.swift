import Foundation

enum CoreSpiceValidationFixture: String, CaseIterable, Sendable {
    case analysisCoverage = "analysis-coverage.json"
    case corpusManifest = "corpus-manifest.json"
    case devicePassports = "device-passports.json"
    case numericalCorrelationRunner = "gate.py"
    case productionQualificationContract = "production-qualification-contract.json"
    case regressionReference = "golden.json"

    var url: URL {
        get throws {
            guard let url = Bundle.module.url(
                forResource: rawValue,
                withExtension: nil,
                subdirectory: "validation"
            ) else {
                throw CoreSpiceValidationFixtureError.resourceUnavailable(name: rawValue)
            }
            return url
        }
    }
}
