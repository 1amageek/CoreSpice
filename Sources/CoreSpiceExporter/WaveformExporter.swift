import CoreSpiceWaveform
import Foundation

/// A protocol for waveform data exporters.
///
/// Waveform exporters write simulation results to various file formats
/// such as RAW, CSV, or PSF.
public protocol WaveformExporter: Sendable {

    /// A unique identifier for this export format.
    var formatIdentifier: String { get }

    /// The file extension for this format.
    var fileExtension: String { get }

    /// A human-readable name for this format.
    var formatName: String { get }

    /// Whether this exporter supports streaming output.
    var supportsStreaming: Bool { get }

    /// Exports waveform data to the destination.
    ///
    /// - Parameters:
    ///   - data: The waveform data to export.
    ///   - destination: Where to write the output.
    ///   - configuration: Export configuration options.
    /// - Returns: The export result.
    func export(
        _ data: WaveformData,
        to destination: ExportDestination,
        configuration: ExportConfiguration
    ) async throws -> ExportResult
}

extension WaveformExporter {

    /// Exports with default configuration.
    public func export(
        _ data: WaveformData,
        to destination: ExportDestination
    ) async throws -> ExportResult {
        try await export(data, to: destination, configuration: .default)
    }

    /// Exports to a file at the given path.
    public func export(
        _ data: WaveformData,
        toPath path: String,
        configuration: ExportConfiguration = .default
    ) async throws -> ExportResult {
        try await export(data, to: .file(path: path), configuration: configuration)
    }

    /// Exports to memory and returns the data.
    public func exportToData(
        _ data: WaveformData,
        configuration: ExportConfiguration = .default
    ) async throws -> Data {
        let result = try await export(data, to: .memory, configuration: configuration)
        guard let exportedData = result.data else {
            throw ExporterError.memoryExportFailed
        }
        return exportedData
    }
}

/// Errors that can occur during export.
public enum ExporterError: Error, Sendable {

    /// The destination file could not be created.
    case cannotCreateFile(path: String)

    /// Writing to the output failed.
    case writeFailed(reason: String)

    /// Memory export did not produce data.
    case memoryExportFailed

    /// The data format is not supported by this exporter.
    case unsupportedDataFormat(reason: String)

    /// The configuration is invalid.
    case invalidConfiguration(reason: String)

    /// A streaming session error.
    case streamingError(reason: String)
}

extension ExporterError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .cannotCreateFile(let path):
            return "Cannot create file at path: \(path)"
        case .writeFailed(let reason):
            return "Write failed: \(reason)"
        case .memoryExportFailed:
            return "Memory export did not produce data"
        case .unsupportedDataFormat(let reason):
            return "Unsupported data format: \(reason)"
        case .invalidConfiguration(let reason):
            return "Invalid configuration: \(reason)"
        case .streamingError(let reason):
            return "Streaming error: \(reason)"
        }
    }
}
