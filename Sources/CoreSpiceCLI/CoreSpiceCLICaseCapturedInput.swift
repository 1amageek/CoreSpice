import CircuiteFoundation
import CircuiteFoundationCrypto
import CoreSpiceIO
import Foundation

/// Exact additional host input bytes retained before numerical execution.
struct CoreSpiceCLICaseCapturedInput: Sendable {
    let bytes: Data
    let reference: ArtifactReference
    private let reservation: SPICESourceStorageReservation

    static func capture(_ catalog: CoreSpiceCLIOSDICatalog.Loaded,
                        resources: any SPICESourceResourceAccounting) throws -> [Self] {
        var total: UInt64 = 0, captured: [Self] = []
        for path in catalog.evidenceInputPaths.keys.sorted() {
            try resources.checkCancellation()
            guard let expected = catalog.evidenceInputPaths[path] else { throw CoreSpiceCLICaseError.incompleteOutput("Missing catalog evidence input") }
            let size = expected.byteCount
            guard size > 0, size <= UInt64(CoreSpiceCLICasePublisher.maximumPublishedBytes) - total else {
                throw CoreSpiceCLICaseError.incompleteOutput("OSDI evidence input byte ceiling exceeded")
            }
            let reservation = try resources.reserveStorage(kind: .liveOwnedBytes, byteCount: size)
            let bytes = path == catalog.sourcePath ? catalog.sourceBytes : try LocalSPICESourceReader().read(at: path,
                maximumByteCount: size, maximumPageByteCount: min(65536, size))
            try resources.chargeHashedBytes(UInt64(bytes.count))
            let digest = try SHA256ContentDigester().digest(data: bytes, using: .sha256)
            let actual = try ArtifactReference(digest: digest, byteCount: UInt64(bytes.count), descriptor: expected.descriptor)
            guard actual == expected else { throw CoreSpiceCLICaseError.incompleteOutput("OSDI evidence input changed after catalog capture") }
            captured.append(.init(bytes: bytes, reference: actual, reservation: reservation)); total += size
        }
        return captured
    }
}
