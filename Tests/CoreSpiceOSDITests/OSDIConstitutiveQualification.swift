import CircuiteFoundation
import CircuiteFoundationCrypto
import Foundation

/// External test qualifier; runtime session fields alone do not attest numeric code.
struct OSDIConstitutiveQualification {
    enum Refusal: Error, Equatable { case invalidBinding }
    private struct Pin: Decodable {
        let path: String
        let sha256: String
        func read() throws -> Data {
            let bytes = try Data(contentsOf: URL(fileURLWithPath: path))
            guard try OSDIConstitutiveQualification.digest(bytes) == sha256 else { throw Refusal.invalidBinding }
            return bytes
        }
    }
    private struct PublicReceipt: Decodable {
        struct Precision: Decodable {
            let numericProfileSHA256, workerSHA256: String
            let workerReceipt: Pin
        }
        struct Source: Decodable { let revision, version: String }
        struct Resolution: Decodable { let mode: String; let overrideCount: Int }
        let status: String
        let precision: Precision
        let source: Source
        let dependencyResolution: Resolution
    }
    private struct WorkerReceipt: Decodable {
        let schema: Int
        let worker, numericProfile: Pin
    }
    private struct NumericProfile: Decodable {
        struct Worker: Decodable { let sha256: String }
        let schema: Int
        let worker: Worker
    }
    let numericProfileSHA256: String
    let workerSHA256: String

    private static func environment(_ name: String) throws -> String {
        guard let value = ProcessInfo.processInfo.environment[name], !value.isEmpty else { throw Refusal.invalidBinding }
        return value
    }
    private static func digest(_ bytes: Data) throws -> String {
        try SHA256ContentDigester().digest(using: .sha256, limits: .singleBufferMaximum) { lease throws(ContentDigestError) in
            try lease.update(Array(bytes))
        }.digest.hexadecimalValue
    }
    static func load(expectedNumericProfile: String? = nil, runtimeWorkerPath: String? = nil) throws -> Self {
        let profileSHA = try expectedNumericProfile ?? environment("CORESPICE_OSDI_CONSTITUTIVE_NUMERIC_SHA256")
        let workerSHA = try environment("CORESPICE_OSDI_CONSTITUTIVE_WORKER_SHA256")
        let decoder = JSONDecoder()
        let qualification = try decoder.decode(PublicReceipt.self, from: Pin(
            path: environment("CORESPICE_OSDI_CONSTITUTIVE_QUALIFICATION_RECEIPT"),
            sha256: environment("CORESPICE_OSDI_CONSTITUTIVE_QUALIFICATION_RECEIPT_SHA256")).read())
        guard qualification.status == "passed", qualification.source.version == "1.2.0",
              qualification.source.revision == "e17d3bcca1224c8ab9ccfaddea7a47580b29b748",
              qualification.dependencyResolution.mode == "public-remote-no-overrides",
              qualification.dependencyResolution.overrideCount == 0,
              qualification.precision.numericProfileSHA256 == profileSHA,
              qualification.precision.workerSHA256 == workerSHA else { throw Refusal.invalidBinding }
        let built = try decoder.decode(WorkerReceipt.self, from: qualification.precision.workerReceipt.read())
        guard built.schema == 1, built.worker.sha256 == workerSHA,
              built.numericProfile.sha256 == profileSHA else { throw Refusal.invalidBinding }
        let profile = try decoder.decode(NumericProfile.self, from: built.numericProfile.read())
        guard profile.schema == 1, profile.worker.sha256 == workerSHA else { throw Refusal.invalidBinding }
        // Verify both the qualified build output and the exact runtime worker path.
        _ = try built.worker.read()
        let workerPath = try runtimeWorkerPath ?? environment("CORESPICE_OSDI_CONSTITUTIVE_WORKER")
        _ = try Pin(path: workerPath, sha256: workerSHA).read()
        return Self(numericProfileSHA256: profileSHA, workerSHA256: workerSHA)
    }
}
