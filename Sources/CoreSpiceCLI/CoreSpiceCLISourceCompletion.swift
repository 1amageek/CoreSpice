import CoreSpice
import CoreSpiceIO
import CoreSpiceAnalysis
import CircuiteFoundation
import CircuiteFoundationCrypto
import Foundation

/// One exact encoded source completion shared by batch and case publication.
struct CoreSpiceCLISourceCompletion: Sendable {
    let verification: CoreSpiceCLINetworkVerification?
    let record: CoreSpiceCLIPreparedRunRecord
    let json: String
    let artifact: ArtifactReference
    private let resources: any SPICESourceResourceAccounting
    private let reservation: SPICESourceStorageReservation
    init(_ output: SPICENativeSimulationOutput, numericalResources: AnalysisExecutionResources? = nil,
         cancellation: CancellationToken = .init()) throws {
        let resources = output.prepared.input.resources
        self.resources = resources
        record = try CoreSpiceCLIPreparedRunRecord(output)
        let upper = try CoreSpiceCLIJSONUpperBound.count(record, maximumBytes: 16 * 1024 * 1024, resources: resources)
        let scratch = try resources.reserveStorage(kind: .temporaryBytes, byteCount: CoreSpiceCLIPrecisionExecution.multiply(upper, 4))
        reservation = try resources.reserveStorage(kind: .liveOwnedBytes, byteCount: upper)
        json = try CoreSpiceCLIJSON.encode(record)
        guard UInt64(json.utf8.count) <= upper else { throw CoreSpiceCLICaseError.incompleteOutput("Source completion exceeds admitted serialization") }
        let bytes = Data(json.utf8)
        let decoder: JSONDecoder
        if output.networkResult != nil {
            guard let numericalResources else { throw CoreSpiceCLIOSDIError.incompleteReceipt("Missing RF verification invocation") }
            decoder = CoreSpiceCLIJSON.networkDecoder(numericalResources: numericalResources, sourceResources: resources, cancellation: cancellation)
        } else { decoder = JSONDecoder() }
        verification = decoder.userInfo[CoreSpiceCLINetworkVerification.key] as? CoreSpiceCLINetworkVerification
        _ = try decoder.decode(CoreSpiceCLIPreparedRunRecord.self, from: bytes)
        try resources.chargeHashedBytes(UInt64(bytes.count))
        artifact = try Self.reference(bytes)
        withExtendedLifetime(scratch) { }
    }
    func withJSONBytes<Result>(_ body: (Data) throws -> Result) throws -> Result {
        let bytes = UInt64(json.utf8.count)
        let scratch = try resources.reserveStorage(kind: .temporaryBytes,
            byteCount: CoreSpiceCLIPrecisionExecution.multiply(bytes, 2))
        try resources.charge(.projectedBytes, units: bytes)
        let result = try body(Data(json.utf8))
        withExtendedLifetime(scratch) { }
        return result
    }
    static func reference(_ bytes: Data) throws -> ArtifactReference {
        let digest = try SHA256ContentDigester().digest(data: bytes, using: .sha256)
        return try .init(digest: digest, byteCount: UInt64(bytes.count), descriptor: .init(role: .output, kind: .report, format: .json))
    }
}
