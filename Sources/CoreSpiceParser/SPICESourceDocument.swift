import Foundation

/// Text and provenance returned by one source selection; identity names the full source.
public struct SPICESourceDocument: Sendable {
    public let text: String
    public let resolvedPath: String?
    public let captureID: String?
    public let librarySection: String?

    public init(text: String, resolvedPath: String? = nil, captureID: String? = nil,
                librarySection: String? = nil) {
        self.text = text
        self.resolvedPath = resolvedPath
        self.captureID = captureID
        self.librarySection = librarySection
    }

    /// Projects a section without moving any selected physical line or column.
    public func selectingLibrarySection(_ section: String?) throws -> Self {
        guard let section else { return self }
        var projected = ""
        projected.reserveCapacity(text.utf8.count)
        var active = false
        var found = false
        var ended = false
        var start = text.startIndex
        while start < text.endIndex {
            let end = text[start...].firstIndex { $0 == "\n" || $0 == "\r\n" || $0 == "\r" } ?? text.endIndex
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
}
