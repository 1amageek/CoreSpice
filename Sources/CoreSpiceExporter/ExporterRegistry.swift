import CoreSpiceWaveform
import Foundation
import Synchronization

/// A registry for waveform exporters.
///
/// The exporter registry maintains a collection of available exporters
/// and provides methods for selecting the appropriate exporter based
/// on format or file extension.
public final class ExporterRegistry: Sendable {

    /// The registered exporters.
    private let exporters: Mutex<[String: any WaveformExporter]>

    /// Creates an empty registry.
    public init() {
        self.exporters = Mutex([:])
    }

    /// Creates a registry with the given exporters.
    public init(exporters: [any WaveformExporter]) {
        var dict: [String: any WaveformExporter] = [:]
        for exporter in exporters {
            dict[exporter.formatIdentifier] = exporter
        }
        self.exporters = Mutex(dict)
    }

    /// Registers an exporter.
    ///
    /// - Parameter exporter: The exporter to register.
    public func register(_ exporter: any WaveformExporter) {
        exporters.withLock { dict in
            dict[exporter.formatIdentifier] = exporter
        }
    }

    /// Returns the exporter for the given format identifier.
    ///
    /// - Parameter identifier: The format identifier (e.g., "raw", "csv").
    /// - Returns: The registered exporter, or nil if not found.
    public func exporter(for identifier: String) -> (any WaveformExporter)? {
        exporters.withLock { dict in
            dict[identifier]
        }
    }

    /// Returns the exporter for a file path based on extension.
    ///
    /// - Parameter path: The file path.
    /// - Returns: The matching exporter, or nil if none match.
    public func exporter(forPath path: String) -> (any WaveformExporter)? {
        let ext = (path as NSString).pathExtension.lowercased()
        return exporters.withLock { dict in
            for exporter in dict.values {
                if exporter.fileExtension.lowercased() == ext {
                    return exporter
                }
            }
            return nil
        }
    }

    /// Returns all registered exporters.
    public var allExporters: [any WaveformExporter] {
        exporters.withLock { dict in
            Array(dict.values)
        }
    }

    /// Returns all registered format identifiers.
    public var registeredFormats: [String] {
        exporters.withLock { dict in
            Array(dict.keys).sorted()
        }
    }

    // MARK: - Convenience Export Methods

    /// Exports waveform data using the specified format or auto-detected from path.
    ///
    /// - Parameters:
    ///   - data: The waveform data to export.
    ///   - path: The output file path.
    ///   - format: The format identifier, or nil to detect from extension.
    ///   - configuration: Export configuration.
    /// - Returns: The export result.
    public func export(
        _ data: WaveformData,
        toPath path: String,
        format: String? = nil,
        configuration: ExportConfiguration = .default
    ) async throws -> ExportResult {
        let selectedExporter: (any WaveformExporter)?

        if let format = format {
            selectedExporter = exporter(for: format)
        } else {
            selectedExporter = exporter(forPath: path)
        }

        guard let exp = selectedExporter else {
            throw ExporterError.unsupportedDataFormat(
                reason: "No exporter available for the given format or extension"
            )
        }

        return try await exp.export(data, to: .file(path: path), configuration: configuration)
    }

    /// Exports waveform data to memory using the specified format.
    ///
    /// - Parameters:
    ///   - data: The waveform data to export.
    ///   - format: The format identifier.
    ///   - configuration: Export configuration.
    /// - Returns: The exported data.
    public func exportToData(
        _ data: WaveformData,
        format: String,
        configuration: ExportConfiguration = .default
    ) async throws -> Data {
        guard let exp = exporter(for: format) else {
            throw ExporterError.unsupportedDataFormat(
                reason: "No exporter available for format: \(format)"
            )
        }

        return try await exp.exportToData(data, configuration: configuration)
    }
}
