import CoreSpiceParsedIR
import Foundation

/// Text and provenance returned by one source selection; identity names the full source.
public struct SPICESourceDocument: Sendable {
    public let text: String
    public let resolvedPath: String?
    public let captureID: String?
    public let librarySection: String?
    public let occurrenceID: SPICEParseOccurrenceID?
    public var sourceKey: String? { captureID }
    public var isInvocationAccounted: Bool { textOwner != nil }
    private let textOwner: SPICEAccountedText?
    private let fullTextOwner: SPICEAccountedText?
    private let retainedSource: (any Sendable)?
    private let offsetMap: SPICEAccountedCollection<OffsetRange>?
    private let originalByteCount: Int

    public init(text: String, resolvedPath: String? = nil, captureID: String? = nil,
                librarySection: String? = nil) {
        self.text = text
        self.resolvedPath = resolvedPath
        self.captureID = captureID
        self.librarySection = librarySection
        self.occurrenceID = nil; self.textOwner = nil; self.fullTextOwner = nil
        self.retainedSource = nil; self.offsetMap = nil; self.originalByteCount = text.utf8.count
    }

    /// Projects a section without moving any selected physical line or column.
    public func selectingLibrarySection(_ section: String?, work: (any SPICESourceWorkAccounting)? = nil) throws -> Self {
        guard let section else { return self }
        guard !isInvocationAccounted else {
            throw SPICEBoundedSourceError.unsupportedBudgetCapability("Count-only library projection")
        }
        try work?.checkCancellation()
        try work?.charge(.projectedBytes, units: UInt64(text.utf8.count))
        var projected = ""
        projected.reserveCapacity(text.utf8.count)
        var active = false
        var found = false
        var ended = false
        var start = text.startIndex
        while start < text.endIndex {
            try work?.charge(.retainedElements, units: 1)
            var end = start
            var characters = 0
            while end < text.endIndex, text[end] != "\n", text[end] != "\r\n", text[end] != "\r" {
                end = text.index(after: end)
                characters += 1
                if characters == 256 { try work?.checkCancellation(); characters = 0 }
            }
            try work?.checkCancellation()
            let line = text[start..<end]
            let fields = line.trimmingCharacters(in: .whitespaces).split(whereSeparator: { $0.isWhitespace })
            let directive = fields.first?.lowercased()
            var retained = active
            if !found, directive == ".lib", fields.count == 2, fields[1].lowercased() == section.lowercased() {
                found = true
                active = true
                retained = false
            } else if active, directive == ".endl" {
                active = false
                ended = true
                retained = false
            }
            if retained { projected.append(contentsOf: line) }
            if end < text.endIndex {
                projected.append(text[end])
                start = text.index(after: end)
            } else { start = end }
        }
        guard found, ended else {
            throw FileResolverError.sectionNotFound(library: resolvedPath ?? "<memory>", section: section)
        }
        return Self(text: projected, resolvedPath: resolvedPath, captureID: captureID, librarySection: section)
    }

    /// Owned text is storage evidence; the injected provider owns content approval.
    public init(accountedText: SPICEAccountedText, sourceKey: String,
                occurrenceID: SPICEParseOccurrenceID, resolvedPath: String? = nil,
                retaining source: (any Sendable)? = nil) throws {
        guard !sourceKey.isEmpty else { throw SPICEBoundedSourceError.invalidSourceContext }
        self.text = accountedText.text; self.resolvedPath = resolvedPath; self.captureID = sourceKey
        self.librarySection = nil; self.occurrenceID = occurrenceID
        self.textOwner = accountedText; self.fullTextOwner = accountedText
        self.retainedSource = source; self.offsetMap = nil
        self.originalByteCount = accountedText.managedByteCapacity
    }

    private init(parent: Self, text: SPICEAccountedText, section: String,
                 offsets: SPICEAccountedCollection<OffsetRange>) {
        self.text = text.text; self.resolvedPath = parent.resolvedPath; self.captureID = parent.captureID
        self.librarySection = section; self.occurrenceID = parent.occurrenceID
        self.textOwner = text; self.fullTextOwner = parent.fullTextOwner
        self.retainedSource = parent.retainedSource; self.offsetMap = offsets
        self.originalByteCount = parent.originalByteCount
    }

    /// Maps a projected byte location back to the same immutable full source.
    public func originalByteOffset(for offset: UInt64,
                                   resources: any SPICESourceResourceAccounting) throws -> UInt64 {
        try resources.checkCancellation()
        guard let position = Int(exactly: offset), position >= 0, position <= text.utf8.count else {
            throw SPICESourceStorageError.indexOutOfBounds
        }
        guard let map = offsetMap else { return offset }
        if position == text.utf8.count { return UInt64(originalByteCount) }
        var low = 0, high = map.count
        while low < high {
            try resources.checkCancellation(); try resources.charge(.tokens, units: 1)
            let middle = low + (high - low) / 2
            let entry = map[middle]
            if position < entry.projectedStart { high = middle }
            else if position - entry.projectedStart >= entry.count { low = middle + 1 }
            else { return UInt64(entry.originalStart + position - entry.projectedStart) }
        }
        throw SPICESourceStorageError.indexOutOfBounds
    }

    /// Accounted section projection; unsupported Unicode operations never change meaning.
    public func selectingLibrarySection(_ section: String?, resources: any SPICESourceResourceAccounting) throws -> Self {
        guard let section else { try resources.checkCancellation(); return self }
        guard let fullTextOwner, isInvocationAccounted, offsetMap == nil else {
            throw SPICEBoundedSourceError.unaccountedSource
        }
        try resources.checkCancellation()
        // Legacy section matching uses Unicode whitespace/case mapping. This bounded backend
        // refuses Unicode selection instead of substituting different ASCII semantics.
        try resources.charge(.lexicalBytes, units: UInt64(section.utf8.count))
        var sectionIndex = 0
        for byte in section.utf8 {
            if sectionIndex.isMultiple(of: 256) { try resources.checkCancellation() }; sectionIndex += 1
            if byte >= 128 { throw SPICEBoundedSourceError.unsupportedBudgetCapability("Unicode library selection") }
        }
        let result = try fullTextOwner.text.utf8.withContiguousStorageIfAvailable { bytes in
            try resources.charge(.lexicalBytes, units: UInt64(bytes.count))
            for index in bytes.indices {
                if index.isMultiple(of: 256) { try resources.checkCancellation() }
                guard bytes[index] < 128 else {
                    throw SPICEBoundedSourceError.unsupportedBudgetCapability("Unicode library selection")
                }
            }
            var map = SPICEAccountedCollection<OffsetRange>(storageKind: .liveOwnedBytes)
            var projectedCount = 0, start = 0
            try resources.charge(.lexicalBytes, units: UInt64(bytes.count))
            var found = false, active = false, ended = false
            while start < bytes.count {
                try resources.checkCancellation()
                var end = start
                while end < bytes.count && bytes[end] != 10 && bytes[end] != 13 {
                    if (end - start).isMultiple(of: 256) { try resources.checkCancellation() }
                    end += 1
                }
                try resources.charge(.tokens, units: 1)
                let fields = try Self.headerFields(bytes, start: start, end: end, resources: resources)
                var retain = active
                if !found && fields.count == 2 && Self.matches(bytes, range: fields.first, spelling: ".lib"),
                   try Self.matches(bytes, range: fields.second, spelling: section, resources: resources) {
                    found = true; active = true; retain = false
                } else if active && Self.matches(bytes, range: fields.first, spelling: ".endl") {
                    active = false; ended = true; retain = false
                }
                var next = end
                if next < bytes.count {
                    next += 1
                    if bytes[end] == 13 && next < bytes.count && bytes[next] == 10 { next += 1 }
                }
                let copyStart = retain ? start : end
                if next > copyStart {
                    try map.append(OffsetRange(projectedStart: projectedCount, originalStart: copyStart,
                        count: next - copyStart), resources: resources)
                    projectedCount += next - copyStart
                }
                start = next
            }
            guard found && ended else { throw FileResolverError.sectionNotFound(library: resolvedPath ?? "<memory>", section: section) }
            let bufferReservation = try resources.reserveStorage(kind: .temporaryBytes, byteCount: UInt64(projectedCount))
            defer { withExtendedLifetime(bufferReservation) {} }
            try resources.charge(.projectedBytes, units: UInt64(projectedCount))
            var output: [UInt8] = []; output.reserveCapacity(projectedCount)
            for range in map {
                for index in 0..<range.count {
                    if index.isMultiple(of: 256) { try resources.checkCancellation() }
                    output.append(bytes[range.originalStart + index])
                }
            }
            let owned = try SPICEAccountedText.admit(bytes: output.span, resources: resources, maximumChunkByteCount: 256)
            try resources.checkCancellation()
            return Self(parent: self, text: owned, section: section, offsets: map)
        }
        guard let result else { throw SPICEBoundedSourceError.unsupportedBudgetCapability("Noncontiguous UTF-8 text") }
        return result
    }

    private struct OffsetRange: Sendable {
        let projectedStart: Int
        let originalStart: Int
        let count: Int
    }
    private static func headerFields(_ bytes: UnsafeBufferPointer<UInt8>, start: Int, end: Int,
        resources: any SPICESourceResourceAccounting) throws -> (first: Range<Int>, second: Range<Int>, count: Int) {
        try resources.charge(.lexicalBytes, units: UInt64(end - start))
        var first = start..<start, second = start..<start, count = 0, cursor = start
        while cursor < end {
            if (cursor - start).isMultiple(of: 256) { try resources.checkCancellation() }
            if bytes[cursor] == 32 || (bytes[cursor] >= 9 && bytes[cursor] <= 13) { cursor += 1; continue }
            let begin = cursor
            while cursor < end && bytes[cursor] != 32 && !(bytes[cursor] >= 9 && bytes[cursor] <= 13) {
                if (cursor - begin).isMultiple(of: 256) { try resources.checkCancellation() }; cursor += 1
            }
            count += 1
            if count == 1 { first = begin..<cursor }; if count == 2 { second = begin..<cursor }
        }
        return (first, second, count)
    }
    private static func matches(_ bytes: UnsafeBufferPointer<UInt8>, range: Range<Int>, spelling: String) -> Bool {
        guard range.count == spelling.utf8.count else { return false }
        var index = range.lowerBound
        for byte in spelling.utf8 {
            let actual = bytes[index]; index += 1
            if (actual >= 65 && actual <= 90 ? actual + 32 : actual) != byte { return false }
        }
        return true
    }
    private static func matches(_ bytes: UnsafeBufferPointer<UInt8>, range: Range<Int>, spelling: String,
                                resources: any SPICESourceResourceAccounting) throws -> Bool {
        guard range.count == spelling.utf8.count else { return false }
        try resources.charge(.lexicalBytes, units: UInt64(range.count))
        var index = range.lowerBound
        for byte in spelling.utf8 {
            if (index - range.lowerBound).isMultiple(of: 256) { try resources.checkCancellation() }
            let actual = bytes[index]; index += 1
            let lhs = actual >= 65 && actual <= 90 ? actual + 32 : actual
            let rhs = byte >= 65 && byte <= 90 ? byte + 32 : byte
            if lhs != rhs { return false }
        }
        return true
    }
}
