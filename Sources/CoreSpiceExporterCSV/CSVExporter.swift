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
        _ data: WaveformData,
        to destination: ExportDestination,
        configuration: ExportConfiguration
    ) async throws -> ExportResult {
        let session = try await beginExport(
            to: destination,
            metadata: data.metadata,
            sweepVariable: data.sweepVariable,
            variables: data.variables,
            configuration: configuration
        )

        // Write all data points
        if data.isComplex {
            for point in 0..<data.pointCount {
                var values: [(real: Double, imag: Double)] = []
                for varIdx in 0..<data.variableCount {
                    if let v = data.complexValue(variable: varIdx, point: point) {
                        values.append(v)
                    }
                }
                try await session.writeComplexPoint(
                    sweepValue: data.sweepValues[point],
                    values: values
                )
            }
        } else {
            for point in 0..<data.pointCount {
                var values: [Double] = []
                for varIdx in 0..<data.variableCount {
                    if let v = data.realValue(variable: varIdx, point: point) {
                        values.append(v)
                    }
                }
                try await session.writePoint(
                    sweepValue: data.sweepValues[point],
                    values: values
                )
            }
        }

        return try await session.finalize()
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
        self.includeHeader = includeHeader
        self.includeUnits = includeUnits
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

        var fields: [String] = [formatDouble(sweepValue)]
        for value in values {
            fields.append(formatDouble(value))
        }

        try helper.write(fields.joined(separator: separator) + "\n")
        helper.incrementPointCount()
    }

    func writeComplexPoint(
        sweepValue: Double,
        values: [(real: Double, imag: Double)]
    ) async throws {
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

        var fields: [String] = [formatDouble(sweepValue)]
        for value in values {
            fields.append(formatDouble(value.real))
            fields.append(formatDouble(value.imag))
        }

        try helper.write(fields.joined(separator: separator) + "\n")
        helper.incrementPointCount()
    }

    func finalize() async throws -> ExportResult {
        helper.close()
        return helper.createResult()
    }

    func cancel() async {
        helper.close()
        if let path = helper.outputPath {
            try? FileManager.default.removeItem(atPath: path)
        }
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
        // Use enough precision but avoid scientific notation for small numbers
        if abs(value) < 1e-10 && value != 0 {
            return String(format: "%.15e", value)
        }
        return String(format: "%.15g", value)
    }
}
