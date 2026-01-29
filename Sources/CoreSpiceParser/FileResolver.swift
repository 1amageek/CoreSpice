import Foundation

/// A protocol for resolving and reading included files.
///
/// File resolvers handle `.include` and `.lib` directives by
/// locating and reading the referenced files.
public protocol FileResolver: Sendable {

    /// Resolves an include path to the file content.
    ///
    /// - Parameters:
    ///   - path: The path specified in the .include directive.
    ///   - relativeTo: The path of the file containing the include.
    /// - Returns: The content of the included file.
    func resolveInclude(
        path: String,
        relativeTo: String?
    ) async throws -> String

    /// Resolves a library path to the file content.
    ///
    /// - Parameters:
    ///   - path: The path specified in the .lib directive.
    ///   - section: The optional library section name.
    ///   - relativeTo: The path of the file containing the lib directive.
    /// - Returns: The content of the library section.
    func resolveLibrary(
        path: String,
        section: String?,
        relativeTo: String?
    ) async throws -> String

    /// Reads a file at the given path.
    ///
    /// - Parameter path: The absolute or relative path to read.
    /// - Returns: The file content as a string.
    func readFile(at path: String) async throws -> String
}

/// Errors that can occur during file resolution.
public enum FileResolverError: Error, Sendable {

    /// The file was not found at the given path.
    case fileNotFound(path: String)

    /// The file could not be read.
    case readError(path: String, underlying: String)

    /// The library section was not found.
    case sectionNotFound(library: String, section: String)

    /// The include depth exceeded the maximum.
    case maxIncludeDepthExceeded(depth: Int)

    /// The path is invalid or unsafe.
    case invalidPath(path: String, reason: String)
}

extension FileResolverError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .fileNotFound(let path):
            return "File not found: \(path)"
        case .readError(let path, let underlying):
            return "Failed to read file '\(path)': \(underlying)"
        case .sectionNotFound(let library, let section):
            return "Section '\(section)' not found in library '\(library)'"
        case .maxIncludeDepthExceeded(let depth):
            return "Maximum include depth (\(depth)) exceeded"
        case .invalidPath(let path, let reason):
            return "Invalid path '\(path)': \(reason)"
        }
    }
}

/// A file resolver that reads from the local filesystem.
public struct LocalFileResolver: FileResolver {

    /// Search paths for resolving includes.
    public let searchPaths: [String]

    /// The maximum depth for nested includes.
    public let maxDepth: Int

    public init(
        searchPaths: [String] = [],
        maxDepth: Int = 32
    ) {
        self.searchPaths = searchPaths
        self.maxDepth = maxDepth
    }

    public func resolveInclude(
        path: String,
        relativeTo: String?
    ) async throws -> String {
        let resolvedPath = try resolvePath(path, relativeTo: relativeTo)
        return try await readFile(at: resolvedPath)
    }

    public func resolveLibrary(
        path: String,
        section: String?,
        relativeTo: String?
    ) async throws -> String {
        let resolvedPath = try resolvePath(path, relativeTo: relativeTo)
        let content = try await readFile(at: resolvedPath)

        guard let sectionName = section else {
            return content
        }

        // Extract the named section from the library
        return try extractLibrarySection(from: content, section: sectionName, library: path)
    }

    public func readFile(at path: String) async throws -> String {
        let url = URL(fileURLWithPath: path)
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw FileResolverError.readError(path: path, underlying: error.localizedDescription)
        }
    }

    /// Resolves a path relative to the base path or search paths.
    private func resolvePath(_ path: String, relativeTo: String?) throws -> String {
        // Check if path is absolute
        if path.hasPrefix("/") {
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
            throw FileResolverError.fileNotFound(path: path)
        }

        // Try relative to the including file first
        if let base = relativeTo {
            let baseDir = URL(fileURLWithPath: base).deletingLastPathComponent().path
            let fullPath = URL(fileURLWithPath: baseDir).appendingPathComponent(path).path
            if FileManager.default.fileExists(atPath: fullPath) {
                return fullPath
            }
        }

        // Try search paths
        for searchPath in searchPaths {
            let fullPath = URL(fileURLWithPath: searchPath).appendingPathComponent(path).path
            if FileManager.default.fileExists(atPath: fullPath) {
                return fullPath
            }
        }

        // Try current directory
        let cwd = FileManager.default.currentDirectoryPath
        let cwdPath = URL(fileURLWithPath: cwd).appendingPathComponent(path).path
        if FileManager.default.fileExists(atPath: cwdPath) {
            return cwdPath
        }

        throw FileResolverError.fileNotFound(path: path)
    }

    /// Extracts a section from a library file.
    private func extractLibrarySection(
        from content: String,
        section: String,
        library: String
    ) throws -> String {
        // Look for .lib <section> ... .endl <section> or .endl
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
        var inSection = false
        var sectionLines: [Substring] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces).lowercased()

            if !inSection {
                // Check for .lib <section>
                if trimmed.hasPrefix(".lib") {
                    let parts = trimmed.split(separator: " ", omittingEmptySubsequences: true)
                    if parts.count >= 2 && parts[1].lowercased() == section.lowercased() {
                        inSection = true
                    }
                }
            } else {
                // Check for .endl
                if trimmed.hasPrefix(".endl") {
                    break
                }
                sectionLines.append(line)
            }
        }

        if sectionLines.isEmpty && !inSection {
            throw FileResolverError.sectionNotFound(library: library, section: section)
        }

        return sectionLines.map(String.init).joined(separator: "\n")
    }
}

/// A file resolver that never finds files (for testing or isolated parsing).
public struct NullFileResolver: FileResolver {

    public init() {}

    public func resolveInclude(path: String, relativeTo: String?) async throws -> String {
        throw FileResolverError.fileNotFound(path: path)
    }

    public func resolveLibrary(path: String, section: String?, relativeTo: String?) async throws -> String {
        throw FileResolverError.fileNotFound(path: path)
    }

    public func readFile(at path: String) async throws -> String {
        throw FileResolverError.fileNotFound(path: path)
    }
}
