import OSDIContracts

package struct OSDIPrecisionManifest: Decodable, Sendable {
    package let schema: String
    package let worker: Artifact
    package let semanticProfileSHA256: String
    package let numericProfileSHA256: String
    package let precisionBits: UInt32
    package let options: Options
    package let models: [Model]

    package struct Artifact: Decodable, Sendable {
        package let path: String
        package let sha256: String
        package let byteCount: UInt64
    }

    package struct Model: Decodable, Sendable {
        package let id: String
        package let path: String
        package let sha256: String
        package let byteCount: UInt64
        package let descriptorIndex: Int
        package let descriptorName: String
        package let program: Artifact
        package let source: Artifact
        package var library: OSDIDCManifest.Library {
            .init(id: id, path: path, sha256: sha256, descriptorIndex: descriptorIndex, descriptorName: descriptorName)
        }
    }

    package struct Options: Decodable, Sendable {
        package let maximumProgramBytes: UInt64
        package let maximumMappingBytes: UInt64
        package let arenaBytes: UInt64
        package let maximumWorkUnits: UInt64
        package let minimumPrecisionBits: UInt32
        package let maximumPrecisionBits: UInt32
        package let startupTimeoutNanoseconds: UInt64
        package let evaluationTimeoutNanoseconds: UInt64
        package let cleanupTimeoutNanoseconds: UInt64
        package let pollNanoseconds: UInt64

        package func value() throws -> OSDIPrecisionOptions {
            try .init(maximumProgramBytes: maximumProgramBytes, maximumMappingBytes: maximumMappingBytes,
                arenaBytes: arenaBytes, maximumWorkUnits: maximumWorkUnits,
                minimumPrecisionBits: minimumPrecisionBits, maximumPrecisionBits: maximumPrecisionBits,
                startupTimeoutNanoseconds: startupTimeoutNanoseconds, evaluationTimeoutNanoseconds: evaluationTimeoutNanoseconds,
                cleanupTimeoutNanoseconds: cleanupTimeoutNanoseconds, pollNanoseconds: pollNanoseconds)
        }
    }
}
