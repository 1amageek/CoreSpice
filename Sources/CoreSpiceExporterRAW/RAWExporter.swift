import CoreSpiceWaveform
import CoreSpiceExporter
import Foundation
import Synchronization

/// Exports waveform data in Berkeley SPICE RAW format.
///
/// The RAW format is compatible with ngspice, LTspice, and other
/// SPICE simulators. Supports both ASCII and binary output.
public struct RAWExporter: WaveformExporter, StreamingWaveformExporter {

    public let formatIdentifier = "raw"
    public let fileExtension = "raw"
    public let formatName = "Berkeley SPICE RAW"
    public let supportsStreaming = true

    /// Whether to output in binary format (more compact) or ASCII.
    public var useBinaryFormat: Bool

    public init(useBinaryFormat: Bool = true) {
        self.useBinaryFormat = useBinaryFormat
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
        try RAWExportSession(
            destination: destination,
            metadata: metadata,
            sweepVariable: sweepVariable,
            variables: variables,
            configuration: configuration,
            useBinaryFormat: useBinaryFormat
        )
    }
}

/// Export session for RAW format.
final class RAWExportSession: ExportSession, Sendable {

    /// Local mutable state protected by Mutex.
    private struct LocalState {
        var headerWritten = false
    }

    private let localState: Mutex<LocalState>
    private let helper: ExportSessionHelper
    private let useBinaryFormat: Bool
    private let byteOrder: ByteOrder

    var pointsWritten: Int {
        helper.pointsWritten
    }

    init(
        destination: ExportDestination,
        metadata: SimulationMetadata,
        sweepVariable: VariableDescriptor,
        variables: [VariableDescriptor],
        configuration: ExportConfiguration,
        useBinaryFormat: Bool
    ) throws {
        self.useBinaryFormat = useBinaryFormat
        self.byteOrder = configuration.byteOrder
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
                return true
            }
            return false
        }

        if needsHeader {
            try writeHeader(isComplex: false)
        }

        if useBinaryFormat {
            try writeBinaryPoint(sweepValue: sweepValue, values: values)
        } else {
            try writeASCIIPoint(sweepValue: sweepValue, values: values)
        }

        helper.incrementPointCount()
    }

    func writeComplexPoint(
        sweepValue: Double,
        values: [(real: Double, imag: Double)]
    ) async throws {
        let needsHeader = localState.withLock { state -> Bool in
            if !state.headerWritten {
                state.headerWritten = true
                return true
            }
            return false
        }

        if needsHeader {
            try writeHeader(isComplex: true)
        }

        if useBinaryFormat {
            try writeBinaryComplexPoint(sweepValue: sweepValue, values: values)
        } else {
            try writeASCIIComplexPoint(sweepValue: sweepValue, values: values)
        }

        helper.incrementPointCount()
    }

    func finalize() async throws -> ExportResult {
        helper.close()
        return helper.createResult()
    }

    func cancel() async {
        helper.close()
        // Delete partial file if needed
        if let path = helper.outputPath {
            do {
                try FileManager.default.removeItem(atPath: path)
            } catch {
                // File removal during cancel is best-effort.
                // The file may already be deleted or inaccessible.
                #if DEBUG
                print("RAWExporter: Failed to remove partial file at \(path): \(error)")
                #endif
            }
        }
    }

    // MARK: - Private Methods

    private func writeHeader(isComplex: Bool) throws {
        var header = ""

        // Title
        header += "Title: \(helper.metadata.title ?? "CoreSpice Simulation")\n"

        // Date
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE MMM dd HH:mm:ss yyyy"
        header += "Date: \(formatter.string(from: helper.metadata.date))\n"

        // Plot name
        header += "Plotname: \(helper.metadata.analysisType.rawPlotType)\n"

        // Flags
        if isComplex {
            header += "Flags: complex\n"
        } else {
            header += "Flags: real\n"
        }

        // Variable count (sweep + data variables)
        header += "No. Variables: \(helper.variables.count + 1)\n"

        // Point count (0 for streaming, actual count for full export)
        header += "No. Points: \(helper.metadata.pointCount)\n"

        // Variables section
        header += "Variables:\n"

        // Sweep variable first
        header += "\t0\t\(helper.sweepVariable.name)\t\(helper.sweepVariable.unit.rawFileString)\n"

        // Data variables
        for (idx, variable) in helper.variables.enumerated() {
            header += "\t\(idx + 1)\t\(variable.name)\t\(variable.unit.rawFileString)\n"
        }

        // Binary/Values marker
        if useBinaryFormat {
            header += "Binary:\n"
        } else {
            header += "Values:\n"
        }

        try helper.write(header)
    }

    private func writeBinaryPoint(sweepValue: Double, values: [Double]) throws {
        var data = Data()

        // Write sweep value as double with correct byte order
        data.append(doubleToData(sweepValue))

        // Write each variable
        for value in values {
            data.append(doubleToData(value))
        }

        try helper.write(data)
    }

    private func writeBinaryComplexPoint(
        sweepValue: Double,
        values: [(real: Double, imag: Double)]
    ) throws {
        var data = Data()

        // Write sweep value as complex (real, imag=0)
        data.append(doubleToData(sweepValue))
        data.append(doubleToData(0.0))

        // Write each complex variable
        for value in values {
            data.append(doubleToData(value.real))
            data.append(doubleToData(value.imag))
        }

        try helper.write(data)
    }

    /// Converts a Double to Data with the configured byte order.
    private func doubleToData(_ value: Double) -> Data {
        var bytes = value.bitPattern

        switch byteOrder {
        case .native:
            // Use native byte order
            break
        case .littleEndian:
            bytes = bytes.littleEndian
        case .bigEndian:
            bytes = bytes.bigEndian
        }

        return withUnsafeBytes(of: bytes) { Data($0) }
    }

    private func writeASCIIPoint(sweepValue: Double, values: [Double]) throws {
        var line = "\(helper.pointsWritten)\t\(formatDouble(sweepValue))"
        for value in values {
            line += "\t\(formatDouble(value))"
        }
        line += "\n"
        try helper.write(line)
    }

    private func writeASCIIComplexPoint(
        sweepValue: Double,
        values: [(real: Double, imag: Double)]
    ) throws {
        var line = "\(helper.pointsWritten)\t\(formatDouble(sweepValue)),\(formatDouble(0.0))"
        for value in values {
            line += "\t\(formatDouble(value.real)),\(formatDouble(value.imag))"
        }
        line += "\n"
        try helper.write(line)
    }

    private func formatDouble(_ value: Double) -> String {
        String(format: "%.15e", value)
    }
}
