import CircuiteFoundation
import CircuiteFoundationCrypto
import CircuiteFoundationFoundation
import Foundation
import OSDIContracts
import OSDIRuntime

/// One cold model snapshot. Binary fields use canonical base64 JSON strings.
public struct CoreSpiceCLIPrecisionProgramRecord: Encodable, Sendable, Hashable {
    public struct Nature: Codable, Sendable, Hashable {
        public let kind: UInt32
        public let index: UInt32
        init(_ value: OSDINatureReference) { kind = value.kind; index = value.index }
    }
    public struct Node: Codable, Sendable, Hashable {
        public let index: Int
        public let name: String
        public let units: String
        public let residualUnits: String
        public let isFlow: Bool
        public let unknownNature: Nature
        public let residualNature: Nature
        public let activeUnknownIndex: Int?
        init(_ value: OSDINodeInfo) {
            index = value.index; name = value.name; units = value.units; residualUnits = value.residualUnits
            isFlow = value.isFlow; unknownNature = .init(value.unknownNature); residualNature = .init(value.residualNature)
            activeUnknownIndex = value.activeUnknownIndex
        }
    }
    public struct Topology: Codable, Sendable, Hashable {
        public let nodes: [Node]
        public let activeUnknownCount: Int
        public let stateCount: Int
        init(_ value: OSDIPreparedTopology) {
            nodes = value.nodes.map(Node.init); activeUnknownCount = value.activeUnknownCount; stateCount = value.stateCount
        }
    }
    public let modelReference: ArtifactReference
    public let descriptorIndex: UInt32
    public let topology: Topology
    public let programBytes: Data
    public let setupBytes: Data
    public let programSHA256: String
    public let setupSHA256: String
    public let semanticProfileSHA256: String

    init(_ program: OSDIPrecisionProgram) {
        modelReference = program.modelReference; descriptorIndex = program.descriptorIndex; topology = .init(program.topology)
        // One admitted cold output copy; lower owners retain the source byte arrays.
        programBytes = Data(program.programBytes); setupBytes = Data(program.setupBytes)
        programSHA256 = program.programDigest.hexadecimalValue; setupSHA256 = program.setupDigest.hexadecimalValue
        semanticProfileSHA256 = program.semanticProfile.hexadecimalValue
    }
    private enum CodingKeys: String, CodingKey {
        case modelReference, descriptorIndex, topology, programBytes, setupBytes, programSHA256, setupSHA256, semanticProfileSHA256
    }
    private enum TopologyKeys: String, CodingKey { case nodes }
    init(from decoder: any Decoder, maximumProgramBytes: UInt64, maximumSetupBytes: UInt64, maximumTotalBytes: UInt64) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        modelReference = try c.decode(ArtifactReference.self, forKey: .modelReference)
        descriptorIndex = try c.decode(UInt32.self, forKey: .descriptorIndex)
        let table = try c.nestedContainer(keyedBy: TopologyKeys.self, forKey: .topology)
        let nodes = try table.nestedUnkeyedContainer(forKey: .nodes)
        guard let count = nodes.count, count <= 8192 else { throw CoreSpiceCLIOSDIError.incompleteReceipt("Precision topology node limit exceeded") }
        topology = try c.decode(Topology.self, forKey: .topology)
        programBytes = try Self.decodeBytes(c.decode(String.self, forKey: .programBytes), maximumBytes: min(maximumProgramBytes, maximumTotalBytes))
        setupBytes = try Self.decodeBytes(c.decode(String.self, forKey: .setupBytes), maximumBytes: min(maximumSetupBytes, maximumTotalBytes - UInt64(programBytes.count)))
        programSHA256 = try c.decode(String.self, forKey: .programSHA256)
        setupSHA256 = try c.decode(String.self, forKey: .setupSHA256)
        semanticProfileSHA256 = try c.decode(String.self, forKey: .semanticProfileSHA256)
        try validate()
    }
    func validate() throws {
        guard !programBytes.isEmpty, !setupBytes.isEmpty,
              topology.nodes.count <= 8192, topology.activeUnknownCount > 0,
              topology.activeUnknownCount <= topology.nodes.count, topology.stateCount >= 0,
              topology.nodes.map(\.index) == Array(topology.nodes.indices),
              topology.nodes.allSatisfy({ $0.activeUnknownIndex.map { (0..<topology.activeUnknownCount).contains($0) } ?? true }),
              topology.nodes.allSatisfy({ $0.name.utf8.count <= 65536 && $0.units.utf8.count <= 64 && $0.residualUnits.utf8.count <= 64 }),
              Set(topology.nodes.compactMap(\.activeUnknownIndex)) == Set(0..<topology.activeUnknownCount),
              try Self.sha(programBytes) == programSHA256, try Self.sha(setupBytes) == setupSHA256 else {
            throw CoreSpiceCLIOSDIError.incompleteReceipt("Invalid precision snapshot bytes, digest or topology")
        }
        _ = try ContentDigest(algorithm: .sha256, hexadecimalValue: semanticProfileSHA256)
    }
    static func decodeBytes(_ text: String, maximumBytes: UInt64) throws -> Data {
        let limit = min(maximumBytes, UInt64(Int.max / 4))
        guard text.utf8.count <= Int((limit + 2) / 3 * 4), let bytes = Data(base64Encoded: text),
              UInt64(bytes.count) <= limit, bytes.base64EncodedString() == text else {
            throw CoreSpiceCLIOSDIError.incompleteReceipt("Invalid or over-budget canonical base64 bytes")
        }
        return bytes
    }
    static func sha(_ bytes: Data) throws -> String {
        let count = UInt64(bytes.count)
        return try SHA256ContentDigester().digest(using: .sha256,
            limits: .init(maximumChunkByteCount: 4096, maximumTotalByteCount: max(1, count), maximumUpdateCount: max(1, (count + 4095) / 4096))) {
                (lease: borrowing ContentDigestUpdateLease) throws(ContentDigestError) in
            var offset = 0
            while offset < bytes.count {
                let end = offset + min(4096, bytes.count - offset)
                try lease.update(Array(bytes[offset..<end])); offset = end
            }
        }.digest.hexadecimalValue
    }
}
