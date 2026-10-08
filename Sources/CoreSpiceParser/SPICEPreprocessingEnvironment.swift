import CircuiteFoundation
import CircuiteFoundationCrypto
import CoreSpiceParsedIR

/// Checked immutable parameter snapshot used when entering a fresh child preprocessor.
public struct SPICEPreprocessingEnvironment: Sendable {
    public let identity: String
    public let policyIdentity: String
    public let caseInsensitive: Bool
    public let parameters: SPICEAccountedCollection<SPICEPreprocessingParameter>
    private let identityOwner: SPICEAccountedText
    private let policyOwner: SPICEAccountedText

    private init(identity: SPICEAccountedText, policy: SPICEAccountedText, caseInsensitive: Bool,
                 parameters: SPICEAccountedCollection<SPICEPreprocessingParameter>) {
        self.identity = identity.text
        self.policyIdentity = policy.text
        self.caseInsensitive = caseInsensitive
        self.parameters = parameters
        self.identityOwner = identity
        self.policyOwner = policy
    }

    public static func empty(policyIdentity: String, configuration: ParserConfiguration,
                             resources: any SPICESourceResourceAccounting,
                             maximumPageByteCount: UInt64) throws -> Self {
        try admit(parameters: [], policyIdentity: policyIdentity, configuration: configuration,
                  resources: resources, maximumPageByteCount: maximumPageByteCount)
    }

    public static func admit(parameters: [SPICEPreprocessingParameter], policyIdentity: String,
                             configuration: ParserConfiguration,
                             resources: any SPICESourceResourceAccounting,
                             maximumPageByteCount: UInt64) throws -> Self {
        try validatePage(maximumPageByteCount, resources: resources)
        guard configuration.resolveIncludes, !policyIdentity.isEmpty else {
            throw SPICEBoundedSourceError.invalidEnvironment
        }
        let policy = try SPICEAccountedText.copy(policyIdentity, resources: resources,
                                               maximumChunkByteCount: maximumPageByteCount)
        let entries = try checkedEntries(parameters, resources: resources, page: maximumPageByteCount)
        return try make(policy: policy, caseInsensitive: configuration.caseInsensitive, parameters: entries,
                        resources: resources, page: maximumPageByteCount)
    }

    /// Replacement entries override existing normalized names; duplicates within replacements fail.
    public func inheriting(replacing replacements: [SPICEPreprocessingParameter],
                           resources: any SPICESourceResourceAccounting,
                           maximumPageByteCount: UInt64) throws -> Self {
        try Self.validatePage(maximumPageByteCount, resources: resources)
        let policy = try SPICEAccountedText.copy(policyIdentity, resources: resources,
                                               maximumChunkByteCount: maximumPageByteCount)
        let replacementEntries = try Self.checkedEntries(replacements, resources: resources,
                                                         page: maximumPageByteCount)
        let (capacity, overflow) = parameters.count.addingReportingOverflow(replacementEntries.count)
        guard !overflow else { throw SPICESourceStorageError.arithmeticOverflow }
        var entries = SPICEAccountedCollection<SPICEPreprocessingParameter>(storageKind: .liveOwnedBytes)
        try entries.reserveCapacity(capacity, resources: resources)
        var oldIndex = 0
        var replacementIndex = 0
        while oldIndex < parameters.count || replacementIndex < replacementEntries.count {
            try resources.checkCancellation()
            if oldIndex == parameters.count {
                try entries.append(replacementEntries[replacementIndex], resources: resources)
                replacementIndex += 1
            } else if replacementIndex == replacementEntries.count {
                try entries.append(Self.copy(parameters[oldIndex], resources: resources,
                                             page: maximumPageByteCount), resources: resources)
                oldIndex += 1
            } else {
                let order = try Self.compare(parameters[oldIndex].name,
                                             replacementEntries[replacementIndex].name, resources: resources)
                if order < 0 {
                    try entries.append(Self.copy(parameters[oldIndex], resources: resources,
                                                 page: maximumPageByteCount), resources: resources)
                    oldIndex += 1
                } else {
                    try entries.append(replacementEntries[replacementIndex], resources: resources)
                    replacementIndex += 1
                    if order == 0 { oldIndex += 1 }
                }
            }
        }
        return try Self.make(policy: policy, caseInsensitive: caseInsensitive, parameters: entries,
                             resources: resources, page: maximumPageByteCount)
    }

    private static func validatePage(_ page: UInt64,
                                     resources: any SPICESourceResourceAccounting) throws {
        try resources.checkCancellation()
        guard page > 0, Int(exactly: page) != nil else { throw SPICEBoundedSourceError.invalidPolicy }
    }

    private static func checkedEntries(_ input: [SPICEPreprocessingParameter],
                                      resources: any SPICESourceResourceAccounting,
                                      page: UInt64) throws -> SPICEAccountedCollection<SPICEPreprocessingParameter> {
        var entries = SPICEAccountedCollection<SPICEPreprocessingParameter>(storageKind: .liveOwnedBytes)
        try entries.reserveCapacity(input.count, resources: resources)
        for entry in input {
            let name = try normalizedName(entry.name, resources: resources, page: page)
            let expression = try SPICEAccountedText.copy(entry.expression, resources: resources,
                                                       maximumChunkByteCount: page)
            let owned = SPICEPreprocessingParameter(name: name, expression: expression)
            var lower = 0
            var upper = entries.count
            while lower < upper {
                let middle = lower + (upper - lower) / 2
                let order = try compare(entries[middle].name, owned.name, resources: resources)
                guard order != 0 else { throw SPICEBoundedSourceError.caseCollidingParameter }
                if order < 0 { lower = middle + 1 } else { upper = middle }
            }
            try entries.append(owned, resources: resources)
            var index = entries.count - 1
            while index > lower {
                try entries.replace(at: index, with: entries[index - 1], resources: resources)
                index -= 1
            }
            if lower != entries.count - 1 {
                try entries.replace(at: lower, with: owned, resources: resources)
            }
        }
        return entries
    }

    private static func copy(_ parameter: SPICEPreprocessingParameter,
                             resources: any SPICESourceResourceAccounting, page: UInt64) throws
        -> SPICEPreprocessingParameter {
        let name = try SPICEAccountedText.copy(parameter.name, resources: resources, maximumChunkByteCount: page)
        let expression = try SPICEAccountedText.copy(parameter.expression, resources: resources,
                                                   maximumChunkByteCount: page)
        return SPICEPreprocessingParameter(name: name, expression: expression)
    }

    private static func normalizedName(_ name: String, resources: any SPICESourceResourceAccounting,
                                       page: UInt64) throws -> SPICEAccountedText {
        let result = try name.utf8.withContiguousStorageIfAvailable { input in
            try resources.checkCancellation()
            guard !input.isEmpty else { throw SPICEBoundedSourceError.invalidEnvironment }
            try resources.charge(.lexicalBytes, units: UInt64(input.count))
            let scratch = try resources.reserveStorage(kind: .temporaryBytes, byteCount: UInt64(input.count))
            defer { withExtendedLifetime(scratch) {} }
            try resources.charge(.projectedBytes, units: UInt64(input.count))
            var bytes: [UInt8] = []
            bytes.reserveCapacity(input.count)
            for index in input.indices {
                if index.isMultiple(of: 256) { try resources.checkCancellation() }
                let byte = input[index]
                guard byte < 128 else {
                    throw SPICEBoundedSourceError.unsupportedBudgetCapability("Cooperative Unicode name normalization")
                }
                bytes.append(byte >= 65 && byte <= 90 ? byte + 32 : byte)
            }
            return try SPICEAccountedText.admit(bytes: bytes.span, resources: resources, maximumChunkByteCount: page)
        }
        guard let result else {
            throw SPICEBoundedSourceError.unsupportedBudgetCapability("Noncontiguous UTF-8 name")
        }
        return result
    }

    private static func compare(_ lhs: String, _ rhs: String,
                                resources: any SPICESourceResourceAccounting) throws -> Int {
        var left = lhs.utf8.makeIterator()
        var right = rhs.utf8.makeIterator()
        var compared = 0
        while true {
            if compared.isMultiple(of: 256) { try resources.checkCancellation() }
            try resources.charge(.lexicalBytes, units: 2)
            let a = left.next()
            let b = right.next()
            guard let a else { return b == nil ? 0 : -1 }
            guard let b else { return 1 }
            if a != b { return a < b ? -1 : 1 }
            compared += 1
        }
    }

    private static func make(policy: SPICEAccountedText, caseInsensitive: Bool,
                             parameters: SPICEAccountedCollection<SPICEPreprocessingParameter>,
                             resources: any SPICESourceResourceAccounting, page: UInt64) throws -> Self {
        let domain = "CoreSpice.Preprocessing.Entry"
        let semantics = "spice-conditional-entry-1"
        var total: UInt64 = 8 + 1 + 8 + 8
        func addFrame(_ text: String) throws {
            let (framed, frameOverflow) = UInt64(text.utf8.count).addingReportingOverflow(8)
            let (next, totalOverflow) = total.addingReportingOverflow(framed)
            guard !frameOverflow, !totalOverflow else { throw SPICESourceStorageError.arithmeticOverflow }
            total = next
        }
        try addFrame(domain)
        try addFrame(policy.text)
        try addFrame(semantics)
        for parameter in parameters {
            try resources.checkCancellation()
            try addFrame(parameter.name)
            try addFrame(parameter.expression)
        }
        var writer = try FingerprintWriter(capacity: Int(Swift.min(page, total)), resources: resources)
        let digestScratch = try resources.reserveStorage(kind: .temporaryBytes, byteCount: 64)
        defer { withExtendedLifetime(digestScratch) {} }
        let identityReservation = try resources.reserveStorage(kind: .liveOwnedBytes, byteCount: 71)
        var resourceError: (any Error)?
        let result: ContentDigestResult
        do {
            result = try SHA256ContentDigester().digest(using: .sha256,
                limits: ContentDigestSessionLimits(maximumChunkByteCount: page,
                    maximumTotalByteCount: total, maximumUpdateCount: (total - 1) / page + 1)) {
                    (lease: borrowing ContentDigestUpdateLease) throws(ContentDigestError) in
                do {
                    try writer.frame(domain, lease: lease)
                    try writer.integer(1, lease: lease)
                    try writer.frame(policy.text, lease: lease)
                    try writer.frame(semantics, lease: lease)
                    try writer.byte(caseInsensitive ? 1 : 0, lease: lease)
                    try writer.integer(UInt64(parameters.count), lease: lease)
                    for parameter in parameters {
                        try writer.frame(parameter.name, lease: lease)
                        try writer.frame(parameter.expression, lease: lease)
                    }
                    try writer.integer(0, lease: lease)
                    try writer.flush(lease: lease)
                } catch {
                    resourceError = error
                    throw .backendUpdateFailed(reason: "Preprocessing environment resource admission refused")
                }
            }
        } catch {
            if let resourceError { throw resourceError }
            throw error
        }
        try resources.checkCancellation()
        try resources.charge(.projectedBytes, units: 71)
        var identity = ""
        identity.reserveCapacity(71)
        identity.append("sha256:")
        identity.append(result.digest.hexadecimalValue)
        let identityOwner = SPICEAccountedText(text: identity, managedByteCapacity: 71,
                                              reservation: identityReservation)
        return Self(identity: identityOwner, policy: policy, caseInsensitive: caseInsensitive, parameters: parameters)
    }

    private struct FingerprintWriter {
        private var bytes: [UInt8] = []
        private let capacity: Int
        private let resources: any SPICESourceResourceAccounting
        private let reservation: SPICESourceStorageReservation

        init(capacity: Int, resources: any SPICESourceResourceAccounting) throws {
            self.capacity = capacity
            self.resources = resources
            self.reservation = try resources.reserveStorage(kind: .temporaryBytes, byteCount: UInt64(capacity))
            bytes.reserveCapacity(capacity)
        }

        mutating func byte(_ byte: UInt8, lease: borrowing ContentDigestUpdateLease) throws {
            try resources.charge(.projectedBytes, units: 1)
            try append(byte, lease: lease)
        }

        mutating func integer(_ value: UInt64, lease: borrowing ContentDigestUpdateLease) throws {
            try resources.charge(.projectedBytes, units: 8)
            for shift in stride(from: 56, through: 0, by: -8) {
                try append(UInt8(truncatingIfNeeded: value >> shift), lease: lease)
            }
        }

        mutating func frame(_ text: String, lease: borrowing ContentDigestUpdateLease) throws {
            try integer(UInt64(text.utf8.count), lease: lease)
            try resources.charge(.projectedBytes, units: UInt64(text.utf8.count))
            var index = 0
            for byte in text.utf8 {
                if index.isMultiple(of: 256) { try resources.checkCancellation() }
                try append(byte, lease: lease)
                index += 1
            }
        }

        private mutating func append(_ byte: UInt8, lease: borrowing ContentDigestUpdateLease) throws {
            bytes.append(byte)
            if bytes.count == capacity { try flush(lease: lease) }
        }

        mutating func flush(lease: borrowing ContentDigestUpdateLease) throws {
            guard !bytes.isEmpty else { return }
            try resources.checkCancellation()
            try resources.chargeHashedBytes(UInt64(bytes.count))
            try lease.update(bytes)
            bytes.removeAll(keepingCapacity: true)
            withExtendedLifetime(reservation) {}
        }
    }
}
