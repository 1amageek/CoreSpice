/// Configuration options for waveform export.
///
/// Export configuration controls which data is exported and how
/// it is formatted in the output file.
public struct ExportConfiguration: Sendable {

    /// Filter for selecting which variables to export.
    ///
    /// If nil, all variables are exported.
    public var variableFilter: [String]?

    /// Range of sweep values to export.
    ///
    /// If nil, all sweep values are exported.
    public var sweepRange: ClosedRange<Double>?

    /// Numeric precision for output values.
    public var precision: Int

    /// Compression option for the output.
    public var compression: CompressionOption

    /// Whether to include metadata headers.
    public var includeMetadata: Bool

    /// Whether to include variable names/headers.
    public var includeVariableNames: Bool

    /// The byte order for binary formats.
    public var byteOrder: ByteOrder

    public init(
        variableFilter: [String]? = nil,
        sweepRange: ClosedRange<Double>? = nil,
        precision: Int = 15,
        compression: CompressionOption = .none,
        includeMetadata: Bool = true,
        includeVariableNames: Bool = true,
        byteOrder: ByteOrder = .native
    ) {
        self.variableFilter = variableFilter
        self.sweepRange = sweepRange
        self.precision = precision
        self.compression = compression
        self.includeMetadata = includeMetadata
        self.includeVariableNames = includeVariableNames
        self.byteOrder = byteOrder
    }

    /// Default configuration.
    public static let `default` = ExportConfiguration()

    /// Configuration for compact output.
    public static let compact = ExportConfiguration(
        precision: 8,
        includeMetadata: false
    )

    /// Configuration for high-precision output.
    public static let highPrecision = ExportConfiguration(
        precision: 17
    )
}

/// Compression options for exported files.
public enum CompressionOption: String, Sendable, Hashable, Codable {

    /// No compression.
    case none

}

/// Byte order for binary formats.
public enum ByteOrder: String, Sendable, Hashable, Codable {

    /// Little-endian byte order.
    case littleEndian

    /// Big-endian byte order.
    case bigEndian

    /// Native byte order of the current system.
    case native

    /// Returns the actual byte order for native.
    public var resolved: ByteOrder {
        switch self {
        case .native:
            #if _endian(little)
            return .littleEndian
            #else
            return .bigEndian
            #endif
        case .littleEndian, .bigEndian:
            return self
        }
    }
}

// MARK: - Filtering Extension

import CoreSpiceWaveform
import Foundation

extension ExportConfiguration {

    /// Validates configuration shared by every exporter.
    public func validate() throws {
        guard (1...17).contains(precision) else {
            throw ExporterError.invalidConfiguration(
                reason: "Numeric precision must be in 1...17"
            )
        }
    }

    /// Applies configured filters as a lazy waveform projection.
    ///
    /// - Parameter data: The original waveform data.
    /// - Returns: A read-only view with filters applied.
    public func applyFilters(to data: any WaveformReadable) -> WaveformDataView {
        var variableIndices: [Int]?
        var pointIndices: [Int]?

        if let filter = variableFilter, !filter.isEmpty {
            variableIndices = matchingVariableIndices(in: data, patterns: filter)
        }

        if let range = sweepRange {
            pointIndices = matchingPointIndices(in: data, range: range)
        }

        return WaveformDataView(
            base: data,
            pointIndices: pointIndices,
            variableIndices: variableIndices
        )
    }

    private func matchingVariableIndices(in data: any WaveformReadable, patterns: [String]) -> [Int] {
        var matchedIndices: [Int] = []

        for (index, variable) in data.variables.enumerated() {
            for pattern in patterns {
                if matchesPattern(variable.name, pattern: pattern) {
                    matchedIndices.append(index)
                    break
                }
            }
        }

        return matchedIndices
    }

    private func matchingPointIndices(in data: any WaveformReadable, range: ClosedRange<Double>) -> [Int] {
        var includedIndices: [Int] = []

        for index in 0..<data.pointCount {
            guard let value = data.sweepValue(at: index) else { continue }
            if range.contains(value) {
                includedIndices.append(index)
            }
        }

        return includedIndices
    }

    /// Matches a name against a wildcard pattern.
    ///
    /// Supports * as a wildcard matching any sequence of characters.
    private func matchesPattern(_ name: String, pattern: String) -> Bool {
        if pattern == "*" { return true }

        if pattern.contains("*") {
            let parts = pattern.split(separator: "*", omittingEmptySubsequences: false)
            var remaining = name[...]

            for (index, part) in parts.enumerated() {
                if part.isEmpty { continue }

                if index == 0 {
                    // First part must be prefix
                    guard remaining.hasPrefix(part) else { return false }
                    remaining = remaining.dropFirst(part.count)
                } else if index == parts.count - 1 {
                    // Last part must be suffix
                    guard remaining.hasSuffix(part) else { return false }
                } else {
                    // Middle parts must be contained
                    guard let range = remaining.range(of: part) else { return false }
                    remaining = remaining[range.upperBound...]
                }
            }
            return true
        }

        return name == pattern
    }

    /// Formats a double value according to the configured precision.
    public func formatValue(_ value: Double) -> String {
        // Handle special values
        if value.isNaN { return "NaN" }
        if value.isInfinite { return value > 0 ? "Inf" : "-Inf" }

        // Use exponential for very small/large values
        if value != 0 && (abs(value) < 1e-10 || abs(value) > 1e10) {
            return String(format: "%.\(precision)e", value)
        }

        // Use general format for normal values
        return String(format: "%.\(precision)g", value)
    }
}

// MARK: - Compression Extension

extension CompressionOption {

    /// Compresses data using the selected algorithm.
    ///
    /// - Parameter data: The uncompressed data.
    /// - Returns: The compressed data.
    /// - Throws: If compression fails.
    public func compress(_ data: Data) throws -> Data {
        switch self {
        case .none:
            return data
        }
    }

    /// Decompresses data using the selected algorithm.
    ///
    /// - Parameter data: The compressed data.
    /// - Returns: The decompressed data.
    /// - Throws: If decompression fails.
    public func decompress(_ data: Data) throws -> Data {
        switch self {
        case .none:
            return data
        }
    }

    /// The file extension modifier for this compression type.
    public var fileExtension: String? {
        switch self {
        case .none: return nil
        }
    }

}
