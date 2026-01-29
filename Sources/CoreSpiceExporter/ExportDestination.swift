import Foundation

/// The destination for waveform export.
///
/// Destinations can be files or memory buffers.
public enum ExportDestination: Sendable {

    /// Export to a file at the given path.
    case file(path: String)

    /// Export to memory, returning the data.
    case memory

    /// Creates a file destination.
    public static func path(_ path: String) -> ExportDestination {
        .file(path: path)
    }
}

/// The result of an export operation.
public struct ExportResult: Sendable {

    /// Whether the export completed successfully.
    public let success: Bool

    /// The number of data points exported.
    public let pointsExported: Int

    /// The number of variables exported.
    public let variablesExported: Int

    /// The number of bytes written.
    public let bytesWritten: Int

    /// The destination path if writing to a file.
    public let outputPath: String?

    /// The exported data if writing to memory.
    public let data: Data?

    /// Any warnings generated during export.
    public let warnings: [String]

    /// Creates a successful export result.
    public init(
        pointsExported: Int,
        variablesExported: Int,
        bytesWritten: Int,
        outputPath: String? = nil,
        data: Data? = nil,
        warnings: [String] = []
    ) {
        self.success = true
        self.pointsExported = pointsExported
        self.variablesExported = variablesExported
        self.bytesWritten = bytesWritten
        self.outputPath = outputPath
        self.data = data
        self.warnings = warnings
    }

    /// Creates a failed export result.
    public static func failure(reason: String) -> ExportResult {
        ExportResult(
            success: false,
            pointsExported: 0,
            variablesExported: 0,
            bytesWritten: 0,
            warnings: [reason]
        )
    }

    private init(
        success: Bool,
        pointsExported: Int,
        variablesExported: Int,
        bytesWritten: Int,
        outputPath: String? = nil,
        data: Data? = nil,
        warnings: [String]
    ) {
        self.success = success
        self.pointsExported = pointsExported
        self.variablesExported = variablesExported
        self.bytesWritten = bytesWritten
        self.outputPath = outputPath
        self.data = data
        self.warnings = warnings
    }
}

extension ExportResult: CustomStringConvertible {
    public var description: String {
        if success {
            var parts = ["Exported \(pointsExported) points, \(variablesExported) variables"]
            if bytesWritten > 0 {
                parts.append("(\(bytesWritten) bytes)")
            }
            if let path = outputPath {
                parts.append("to \(path)")
            }
            return parts.joined(separator: " ")
        } else {
            return "Export failed: \(warnings.first ?? "unknown error")"
        }
    }
}
