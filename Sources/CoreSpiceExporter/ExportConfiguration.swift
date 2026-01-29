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

    /// Gzip compression.
    case gzip

    /// Bzip2 compression.
    case bzip2

    /// Zstandard compression.
    case zstd
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

    /// Applies configured filters to waveform data.
    ///
    /// - Parameter data: The original waveform data.
    /// - Returns: A new waveform data with filters applied.
    public func applyFilters(to data: WaveformData) -> WaveformData {
        var filteredData = data

        // Apply variable filter
        if let filter = variableFilter, !filter.isEmpty {
            filteredData = filterVariables(filteredData, matching: filter)
        }

        // Apply sweep range filter
        if let range = sweepRange {
            filteredData = filterSweepRange(filteredData, to: range)
        }

        return filteredData
    }

    /// Filters variables by name patterns.
    private func filterVariables(_ data: WaveformData, matching patterns: [String]) -> WaveformData {
        var matchedIndices: [Int] = []

        for (index, variable) in data.variables.enumerated() {
            for pattern in patterns {
                if matchesPattern(variable.name, pattern: pattern) {
                    matchedIndices.append(index)
                    break
                }
            }
        }

        guard !matchedIndices.isEmpty else { return data }

        // Rebuild variables with new indices
        let filteredVariables: [VariableDescriptor] = matchedIndices.enumerated().map { newIndex, oldIndex in
            let old = data.variables[oldIndex]
            return VariableDescriptor(
                name: old.name,
                unit: old.unit,
                type: old.type,
                index: newIndex
            )
        }

        // Filter data
        let filteredRealData: [[Double]]?
        let filteredComplexData: [[(real: Double, imag: Double)]]?

        if data.isComplex {
            filteredRealData = nil
            filteredComplexData = data.allComplexData?.map { point in
                matchedIndices.map { point[$0] }
            }
        } else {
            filteredRealData = data.allRealData?.map { point in
                matchedIndices.map { point[$0] }
            }
            filteredComplexData = nil
        }

        let newMetadata = SimulationMetadata(
            title: data.metadata.title,
            analysisType: data.metadata.analysisType,
            pointCount: data.metadata.pointCount,
            variableCount: filteredVariables.count,
            isComplex: data.metadata.isComplex
        )

        if data.isComplex, let cdata = filteredComplexData {
            return WaveformData(
                metadata: newMetadata,
                sweepVariable: data.sweepVariable,
                sweepValues: data.sweepValues,
                variables: filteredVariables,
                complexData: cdata
            )
        } else if let rdata = filteredRealData {
            return WaveformData(
                metadata: newMetadata,
                sweepVariable: data.sweepVariable,
                sweepValues: data.sweepValues,
                variables: filteredVariables,
                realData: rdata
            )
        }

        return data
    }

    /// Filters sweep range to the specified bounds.
    private func filterSweepRange(_ data: WaveformData, to range: ClosedRange<Double>) -> WaveformData {
        var includedIndices: [Int] = []

        for (index, value) in data.sweepValues.enumerated() {
            if range.contains(value) {
                includedIndices.append(index)
            }
        }

        guard !includedIndices.isEmpty else { return data }

        let filteredSweepValues = includedIndices.map { data.sweepValues[$0] }

        // Filter data points
        let filteredRealData: [[Double]]?
        let filteredComplexData: [[(real: Double, imag: Double)]]?

        if data.isComplex {
            filteredRealData = nil
            filteredComplexData = data.allComplexData.map { allData in
                includedIndices.map { allData[$0] }
            }
        } else {
            filteredRealData = data.allRealData.map { allData in
                includedIndices.map { allData[$0] }
            }
            filteredComplexData = nil
        }

        let newMetadata = SimulationMetadata(
            title: data.metadata.title,
            analysisType: data.metadata.analysisType,
            pointCount: includedIndices.count,
            variableCount: data.metadata.variableCount,
            isComplex: data.metadata.isComplex
        )

        if data.isComplex, let cdata = filteredComplexData {
            return WaveformData(
                metadata: newMetadata,
                sweepVariable: data.sweepVariable,
                sweepValues: filteredSweepValues,
                variables: data.variables,
                complexData: cdata
            )
        } else if let rdata = filteredRealData {
            return WaveformData(
                metadata: newMetadata,
                sweepVariable: data.sweepVariable,
                sweepValues: filteredSweepValues,
                variables: data.variables,
                realData: rdata
            )
        }

        return data
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
        case .gzip:
            return try compressWithAlgorithm(data, algorithm: .zlib)
        case .bzip2:
            // bzip2 not directly available in Foundation, use zlib as fallback
            return try compressWithAlgorithm(data, algorithm: .zlib)
        case .zstd:
            // Zstandard requires external library, use lz4 as closest alternative
            if #available(macOS 10.15, *) {
                return try compressWithAlgorithm(data, algorithm: .lz4)
            } else {
                return data
            }
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
        case .gzip:
            return try decompressWithAlgorithm(data, algorithm: .zlib)
        case .bzip2:
            return try decompressWithAlgorithm(data, algorithm: .zlib)
        case .zstd:
            if #available(macOS 10.15, *) {
                return try decompressWithAlgorithm(data, algorithm: .lz4)
            } else {
                return data
            }
        }
    }

    /// The file extension modifier for this compression type.
    public var fileExtension: String? {
        switch self {
        case .none: return nil
        case .gzip: return "gz"
        case .bzip2: return "bz2"
        case .zstd: return "zst"
        }
    }

    private func compressWithAlgorithm(_ data: Data, algorithm: NSData.CompressionAlgorithm) throws -> Data {
        let nsData = data as NSData
        do {
            return try nsData.compressed(using: algorithm) as Data
        } catch {
            throw ExporterError.writeFailed(reason: "Compression failed: \(error)")
        }
    }

    private func decompressWithAlgorithm(_ data: Data, algorithm: NSData.CompressionAlgorithm) throws -> Data {
        let nsData = data as NSData
        do {
            return try nsData.decompressed(using: algorithm) as Data
        } catch {
            throw ExporterError.writeFailed(reason: "Decompression failed: \(error)")
        }
    }
}
