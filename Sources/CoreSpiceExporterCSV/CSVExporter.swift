import CoreSpiceWaveform
import CoreSpiceExporter
import Foundation
import Synchronization

/// Exports waveform data in CSV (Comma-Separated Values) format.
///
/// CSV is a widely supported format that can be opened in
/// spreadsheets and data analysis tools.
public struct CSVExporter: WaveformExporter, StreamingWaveformExporter {

    public let formatIdentifier = "csv"
    public let fileExtension = "csv"
    public let formatName = "Comma-Separated Values"
    public let supportsStreaming = true

    /// The field separator character.
    public var separator: String

    /// Whether to include a header row with variable names.
    public var includeHeader: Bool

    /// Whether to include units in the header.
    public var includeUnits: Bool

    /// Whether to quote string fields.
    public var quoteFields: Bool

    public init(
        separator: String = ",",
        includeHeader: Bool = true,
        includeUnits: Bool = true,
        quoteFields: Bool = false
    ) {
        self.separator = separator
        self.includeHeader = includeHeader
        self.includeUnits = includeUnits
        self.quoteFields = quoteFields
    }

    public func export(
        _ data: any WaveformReadable,
        to destination: ExportDestination,
        configuration: ExportConfiguration
    ) async throws -> ExportResult {
        let exportData = configuration.applyFilters(to: data)
        let session = try CSVExportSession(
            destination: destination,
            metadata: exportData.metadata,
            sweepVariable: exportData.sweepVariable,
            variables: exportData.variables,
            configuration: configuration,
            separator: separator,
            includeHeader: includeHeader,
            includeUnits: includeUnits,
            quoteFields: quoteFields
        )

        do {
            if exportData.isComplex {
                for point in 0..<exportData.pointCount {
                    guard let sweepValue = exportData.sweepValue(at: point) else {
                        throw ExporterError.unsupportedDataFormat(reason: "Sweep point unavailable")
                    }
                    try session.writeComplexPointValues(
                        sweepValue: sweepValue,
                        source: exportData,
                        point: point
                    )
                }
            } else {
                for point in 0..<exportData.pointCount {
                    guard let sweepValue = exportData.sweepValue(at: point) else {
                        throw ExporterError.unsupportedDataFormat(reason: "Sweep point unavailable")
                    }
                    try session.writePointValues(
                        sweepValue: sweepValue,
                        source: exportData,
                        point: point
                    )
                }
            }
            return try await session.finalize()
        } catch {
            await session.cancel()
            throw error
        }
    }

    public func beginExport(
        to destination: ExportDestination,
        metadata: SimulationMetadata,
        sweepVariable: VariableDescriptor,
        variables: [VariableDescriptor],
        configuration: ExportConfiguration
    ) async throws -> any ExportSession {
        try CSVExportSession(
            destination: destination,
            metadata: metadata,
            sweepVariable: sweepVariable,
            variables: variables,
            configuration: configuration,
            separator: separator,
            includeHeader: includeHeader,
            includeUnits: includeUnits,
            quoteFields: quoteFields
        )
    }
}

/// Export session for CSV format.
final class CSVExportSession: ExportSession, Sendable {

    /// Local mutable state protected by Mutex.
    private struct LocalState {
        var headerWritten = false
        var isComplex = false
    }

    private let localState: Mutex<LocalState>
    private let helper: ExportSessionHelper
    private let separator: String
    private let includeHeader: Bool
    private let includeUnits: Bool
    private let quoteFields: Bool

    var pointsWritten: Int {
        helper.pointsWritten
    }

    init(
        destination: ExportDestination,
        metadata: SimulationMetadata,
        sweepVariable: VariableDescriptor,
        variables: [VariableDescriptor],
        configuration: ExportConfiguration,
        separator: String,
        includeHeader: Bool,
        includeUnits: Bool,
        quoteFields: Bool
    ) throws {
        self.separator = separator
        self.includeHeader = includeHeader && configuration.includeVariableNames
        self.includeUnits = includeUnits && configuration.includeMetadata
        self.quoteFields = quoteFields
        self.localState = Mutex(LocalState())
        self.helper = try ExportSessionHelper(
            metadata: metadata,
            sweepVariable: sweepVariable,
            variables: variables,
            configuration: configuration,
            destination: destination
        )
    }

    func writePoint(sweepValue: Double, values: [Double]) async throws {
        try values.withUnsafeBufferPointer { buffer in
            try writePointBuffer(sweepValue: sweepValue, values: buffer)
        }
    }

    func writePointBuffer(
        sweepValue: Double,
        values: UnsafeBufferPointer<Double>
    ) throws {
        try helper.validatePoint(
            kind: .real,
            sweepValue: sweepValue,
            valueCount: values.count
        )
        let needsHeader = localState.withLock { state -> Bool in
            if !state.headerWritten {
                state.headerWritten = true
                state.isComplex = false
                return true
            }
            return false
        }

        if needsHeader {
            try writeHeader(isComplex: false)
        }

        var line = formatDouble(sweepValue)
        for value in values {
            line += separator
            line += formatDouble(value)
        }
        line += "\n"

        try helper.write(line)
        try helper.incrementPointCount()
    }

    func writePointValues(
        sweepValue: Double,
        source: any WaveformReadable,
        point: Int
    ) throws {
        try helper.validatePoint(
            kind: .real,
            sweepValue: sweepValue,
            valueCount: source.variables.count
        )
        let needsHeader = localState.withLock { state -> Bool in
            if !state.headerWritten {
                state.headerWritten = true
                state.isComplex = false
                return true
            }
            return false
        }

        if needsHeader {
            try writeHeader(isComplex: false)
        }

        var line = formatDouble(sweepValue)
        let completed = source.forEachRealValue(at: point) { value in
            line += separator
            line += formatDouble(value)
        }
        guard completed else {
            throw ExporterError.unsupportedDataFormat(reason: "Real point storage unavailable")
        }
        line += "\n"

        try helper.write(line)
        try helper.incrementPointCount()
    }

    func writeComplexPoint(
        sweepValue: Double,
        values: [(real: Double, imag: Double)]
    ) async throws {
        try values.withUnsafeBufferPointer { buffer in
            try writeComplexPointBuffer(sweepValue: sweepValue, values: buffer)
        }
    }

    func writeComplexPointBuffer(
        sweepValue: Double,
        values: UnsafeBufferPointer<(real: Double, imag: Double)>
    ) throws {
        try helper.validatePoint(
            kind: .complex,
            sweepValue: sweepValue,
            valueCount: values.count
        )
        let needsHeader = localState.withLock { state -> Bool in
            if !state.headerWritten {
                state.headerWritten = true
                state.isComplex = true
                return true
            }
            return false
        }

        if needsHeader {
            try writeHeader(isComplex: true)
        }

        var line = formatDouble(sweepValue)
        for value in values {
            line += separator
            line += formatDouble(value.real)
            line += separator
            line += formatDouble(value.imag)
        }
        line += "\n"

        try helper.write(line)
        try helper.incrementPointCount()
    }

    func writeComplexPointValues(
        sweepValue: Double,
        source: any WaveformReadable,
        point: Int
    ) throws {
        try helper.validatePoint(
            kind: .complex,
            sweepValue: sweepValue,
            valueCount: source.variables.count
        )
        let needsHeader = localState.withLock { state -> Bool in
            if !state.headerWritten {
                state.headerWritten = true
                state.isComplex = true
                return true
            }
            return false
        }

        if needsHeader {
            try writeHeader(isComplex: true)
        }

        var line = formatDouble(sweepValue)
        let completed = source.forEachComplexValue(at: point) { value in
            line += separator
            line += formatDouble(value.real)
            line += separator
            line += formatDouble(value.imag)
        }
        guard completed else {
            throw ExporterError.unsupportedDataFormat(reason: "Complex point storage unavailable")
        }
        line += "\n"

        try helper.write(line)
        try helper.incrementPointCount()
    }

    func finalize() async throws -> ExportResult {
        try helper.finalize()
    }

    func cancel() async {
        helper.cancel()
    }

    // MARK: - Private Methods

    private func writeHeader(isComplex: Bool) throws {
        guard includeHeader else { return }

        var headers: [String] = []

        // Sweep variable
        let sweepHeader = formatHeader(helper.sweepVariable.name, unit: helper.sweepVariable.unit)
        headers.append(sweepHeader)

        // Data variables
        if isComplex {
            for variable in helper.variables {
                headers.append(formatHeader("\(variable.name)_real", unit: variable.unit))
                headers.append(formatHeader("\(variable.name)_imag", unit: variable.unit))
            }
        } else {
            for variable in helper.variables {
                headers.append(formatHeader(variable.name, unit: variable.unit))
            }
        }

        try helper.write(headers.joined(separator: separator) + "\n")
    }

    private func formatHeader(_ name: String, unit: SIUnit) -> String {
        var header = name
        if includeUnits && !unit.rawValue.isEmpty {
            header += " [\(unit.rawValue)]"
        }
        if quoteFields {
            header = "\"\(header)\""
        }
        return header
    }

    private func formatDouble(_ value: Double) -> String {
        helper.configuration.formatValue(value)
    }
}
