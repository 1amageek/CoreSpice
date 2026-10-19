import CircuiteFoundation
import CircuiteFoundationFoundation
import CoreSpiceIO
import Foundation

/// Actual unique source owners and their grammar occurrences, retained once per run.
public struct CoreSpiceCLIPrecisionSources: Encodable, Sendable, Hashable {
    public struct Capture: Encodable, Sendable, Hashable {
        public let key: String
        public let reference: ArtifactReference
        public let bytes: Data
        init(_ source: SPICECheckedSource) { key = source.binding.key; reference = source.binding.reference; bytes = source.bytes }
        private enum CodingKeys: String, CodingKey { case key, reference, bytes }
        init(from decoder: any Decoder, maximumBytes: UInt64) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            key = try c.decode(String.self, forKey: .key); reference = try c.decode(ArtifactReference.self, forKey: .reference)
            guard reference.byteCount <= maximumBytes else { throw CoreSpiceCLIOSDIError.incompleteReceipt("Source byte budget exceeded") }
            bytes = try CoreSpiceCLIPrecisionProgramRecord.decodeBytes(c.decode(String.self, forKey: .bytes), maximumBytes: reference.byteCount)
            try validate()
        }
        func validate() throws {
            guard !key.isEmpty, key.utf8.count <= 65536, UInt64(bytes.count) == reference.byteCount,
                  reference.digest.algorithm == .sha256, try CoreSpiceCLIPrecisionProgramRecord.sha(bytes) == reference.digest.hexadecimalValue else {
                throw CoreSpiceCLIOSDIError.incompleteReceipt("Saved source binding differs from complete bytes")
            }
        }
    }
    public struct Occurrence: Codable, Sendable, Hashable {
        public let key: String
        public let occurrenceID: UInt64
        public let parentOccurrenceID: UInt64?
        public let statementByteOffset: UInt64?
        public let statementOrdinal: UInt64?
        public let kind: String?
        public let parentSection: String?
        public let selectedSection: String?
        init(_ value: SPICESimulationSourceOccurrence) {
            key = value.source.binding.key; occurrenceID = value.occurrenceID.rawValue
            parentOccurrenceID = value.parentOccurrenceID?.rawValue; statementByteOffset = value.statementByteOffset
            statementOrdinal = value.statementOrdinal; kind = value.kind?.rawValue
            parentSection = value.parentSection; selectedSection = value.selectedSection
        }
    }
    public let rootKey: String
    public let captures: [Capture]
    public let occurrences: [Occurrence]
    init(_ input: PreparedSPICESimulation) {
        captures = input.sources.map(Capture.init)
        occurrences = input.sourceOccurrences.map(Occurrence.init)
        rootKey = occurrences.first?.key ?? ""
    }
    private enum CodingKeys: String, CodingKey { case rootKey, captures, occurrences }
    init(from decoder: any Decoder, maximumBytes: UInt64) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rootKey = try c.decode(String.self, forKey: .rootKey)
        var collection = try c.nestedUnkeyedContainer(forKey: .captures), values: [Capture] = []
        var remaining = maximumBytes
        while !collection.isAtEnd {
            guard values.count < 8192 else { throw CoreSpiceCLIOSDIError.incompleteReceipt("Too many source owners") }
            let value = try Capture(from: collection.superDecoder(), maximumBytes: remaining)
            remaining -= UInt64(value.bytes.count); values.append(value)
        }
        captures = values
        let occurrenceContainer = try c.nestedUnkeyedContainer(forKey: .occurrences)
        guard let count = occurrenceContainer.count, count <= 8192 else { throw CoreSpiceCLIOSDIError.incompleteReceipt("Source occurrence limit exceeded") }
        occurrences = try c.decode([Occurrence].self, forKey: .occurrences)
        try validate()
    }
    func validate() throws {
        guard !captures.isEmpty, captures.count <= 8192, Set(captures.map(\.key)).count == captures.count,
              !occurrences.isEmpty, occurrences.count <= 8192, occurrences[0].key == rootKey,
              occurrences[0].parentOccurrenceID == nil else { throw CoreSpiceCLIOSDIError.incompleteReceipt("Incomplete source graph") }
        for value in captures { try value.validate() }
        let keys = Set(captures.map(\.key)); var seen = Set<UInt64>()
        for value in occurrences {
            guard keys.contains(value.key), !seen.contains(value.occurrenceID),
                  value.parentOccurrenceID.map({ seen.contains($0) }) ?? true,
                  value.kind.map({ ["include", "externalLibrary"].contains($0) }) ?? true else {
                throw CoreSpiceCLIOSDIError.incompleteReceipt("Invalid source occurrence order or binding")
            }
            seen.insert(value.occurrenceID)
        }
        guard Set(occurrences.map(\.key)) == keys else { throw CoreSpiceCLIOSDIError.incompleteReceipt("Unused saved source owner") }
    }
}
