import CoreSpiceParsedIR

/// Grammar physical positions are measured against the selected immutable input,
/// before conditional processing normalizes its newline spelling.
package struct SPICEPhysicalSourceCoordinates: Sendable {
    private struct Line: Sendable {
        let start: Int
        let length: Int
    }
    private let document: SPICESourceDocument
    private let lines: SPICEAccountedCollection<Line>

    package init(document: SPICESourceDocument, resources: any SPICESourceResourceAccounting) throws {
        guard document.isInvocationAccounted else { throw SPICEBoundedSourceError.unaccountedSource }
        let result = try document.text.utf8.withContiguousStorageIfAvailable { bytes in
            try resources.charge(.lexicalBytes, units: UInt64(bytes.count))
            var output = SPICEAccountedCollection<Line>(storageKind: .liveOwnedBytes)
            var start = 0, index = 0
            while index < bytes.count {
                if index.isMultiple(of: 256) { try resources.checkCancellation() }
                guard bytes[index] < 128 else {
                    throw SPICEBoundedSourceError.unsupportedBudgetCapability("Unicode physical source coordinates")
                }
                if bytes[index] == 10 {
                    let end = index > start && bytes[index - 1] == 13 ? index - 1 : index
                    try output.append(Line(start: start, length: end - start), resources: resources)
                    start = index + 1
                }
                index += 1
            }
            try output.append(Line(start: start, length: bytes.count - start), resources: resources)
            try resources.checkCancellation()
            return output
        }
        guard let result else {
            throw SPICEBoundedSourceError.unsupportedBudgetCapability("Contiguous physical source coordinates")
        }
        self.document = document
        self.lines = result
    }

    package func originalByteOffset(at location: SourceLocation,
                            resources: any SPICESourceResourceAccounting) throws -> UInt64 {
        try resources.checkCancellation()
        try resources.charge(.tokens, units: 1)
        guard location.line > 0, location.line <= lines.count, location.column > 0 else {
            throw SPICESourceStorageError.indexOutOfBounds
        }
        let line = lines[location.line - 1]
        guard location.column - 1 <= line.length else { throw SPICESourceStorageError.indexOutOfBounds }
        let (offset, overflow) = line.start.addingReportingOverflow(location.column - 1)
        guard !overflow else { throw SPICESourceStorageError.arithmeticOverflow }
        return try document.originalByteOffset(for: UInt64(offset), resources: resources)
    }
}
