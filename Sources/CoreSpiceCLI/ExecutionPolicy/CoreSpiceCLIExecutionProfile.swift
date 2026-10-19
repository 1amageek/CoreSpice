import CircuiteFoundation
import CircuiteFoundationCrypto
import CoreSpiceIO
import Foundation

/// Explicit caller admission; numerical circuit policy remains source-owned.
public struct CoreSpiceCLIExecutionProfile: Codable, Sendable, Hashable {
    public enum Failure: Error, Sendable {
        case invalidProfile(String)
        case conflictingPrecisionBudget
    }
    public let schemaVersion: Int
    public let maximumElements: Int
    public let maximumNativeAllocationBytes: UInt64
    public let maximumLiveOwnedBytes: UInt64
    public let maximumTemporaryBytes: UInt64
    public let maximumHashedBytes: UInt64
    public let maximumSourceBytes: UInt64
    public let maximumPreparationWorkUnits: UInt64
    public let maximumResolutionRetainedBytes: UInt64

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion, maximumElements, maximumNativeAllocationBytes, maximumLiveOwnedBytes
        case maximumTemporaryBytes, maximumHashedBytes, maximumSourceBytes
        case maximumPreparationWorkUnits, maximumResolutionRetainedBytes
    }
    private struct FieldKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    public init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: FieldKey.self)
        let allowed = Set(CodingKeys.allCases.map(\.rawValue))
        guard fields.allKeys.allSatisfy({ allowed.contains($0.stringValue) }) else {
            throw Failure.invalidProfile("Unknown execution profile field")
        }
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        maximumElements = try values.decode(Int.self, forKey: .maximumElements)
        maximumNativeAllocationBytes = try values.decode(UInt64.self, forKey: .maximumNativeAllocationBytes)
        maximumLiveOwnedBytes = try values.decode(UInt64.self, forKey: .maximumLiveOwnedBytes)
        maximumTemporaryBytes = try values.decode(UInt64.self, forKey: .maximumTemporaryBytes)
        maximumHashedBytes = try values.decode(UInt64.self, forKey: .maximumHashedBytes)
        maximumSourceBytes = try values.decode(UInt64.self, forKey: .maximumSourceBytes)
        maximumPreparationWorkUnits = try values.decode(UInt64.self, forKey: .maximumPreparationWorkUnits)
        maximumResolutionRetainedBytes = try values.decode(UInt64.self, forKey: .maximumResolutionRetainedBytes)
        try validate()
    }

    func validate() throws(Failure) {
        let bounds = [maximumNativeAllocationBytes, maximumLiveOwnedBytes, maximumTemporaryBytes,
            maximumHashedBytes, maximumSourceBytes, maximumPreparationWorkUnits, maximumResolutionRetainedBytes]
        let (_, extentOverflow) = maximumElements.multipliedReportingOverflow(by: 4096)
        let (_, workOverflow) = UInt64(max(0, maximumElements)).multipliedReportingOverflow(by: UInt64(max(0, maximumElements)))
        guard schemaVersion == 1, maximumElements > 0, !extentOverflow, !workOverflow,
              bounds.allSatisfy({ $0 > 0 && $0 <= UInt64(Int.max) }),
              maximumSourceBytes <= maximumLiveOwnedBytes, maximumSourceBytes <= maximumTemporaryBytes,
              maximumResolutionRetainedBytes <= maximumLiveOwnedBytes else {
            throw .invalidProfile("Execution profile requires version1 and positive representable resource ceilings")
        }
    }

    static func load(path: String) throws -> (profile: Self, reference: ArtifactReference) {
        let bytes = try LocalSPICESourceReader().read(at: path, maximumByteCount: 64 * 1024,
            maximumPageByteCount: 4096)
        let profile: Self
        do { profile = try JSONDecoder().decode(Self.self, from: bytes) }
        catch let failure as Failure { throw failure }
        catch { throw Failure.invalidProfile("Invalid execution profile JSON: \(error)") }
        let array = Array(bytes)
        let digest = try SHA256ContentDigester().digest(using: .sha256,
            limits: .init(maximumChunkByteCount: UInt64(max(1, bytes.count)),
                maximumTotalByteCount: UInt64(max(1, bytes.count)), maximumUpdateCount: 1)) {
                (lease: borrowing ContentDigestUpdateLease) throws(ContentDigestError) in
            try lease.update(array)
        }
        let reference = try ArtifactReference(digest: digest.digest, byteCount: UInt64(bytes.count),
            descriptor: .init(role: .input, kind: .report, format: .json))
        return (profile, reference)
    }

    static func validateSaved(_ profile: Self?, reference: ArtifactReference?, hasPrecisionBudget: Bool) throws {
        guard (profile == nil) == (reference == nil), !(profile != nil && hasPrecisionBudget) else {
            throw Failure.invalidProfile("Incomplete or conflicting saved execution profile")
        }
        if let profile, let reference {
            try profile.validate()
            guard reference.byteCount > 0, reference.byteCount <= 64 * 1024,
                  reference.descriptor.role == .input, reference.descriptor.kind == .report,
                  reference.descriptor.format == .json else {
                throw Failure.invalidProfile("Invalid saved execution profile reference")
            }
        }
    }
}
