import CoreSpiceWaveform
import CoreSpiceExporter
import Foundation

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
        _ data: any WaveformReadable,
        to destination: ExportDestination,
        configuration: ExportConfiguration
    ) async throws -> ExportResult {
        try Task.checkCancellation()
        let exportData = configuration.applyFilters(to: data)
        let session = try RAWExportSession(
            destination: destination,
            metadata: exportData.metadata,
            sweepVariable: exportData.sweepVariable,
            variables: exportData.variables,
            configuration: configuration,
            useBinaryFormat: useBinaryFormat
        )

        do {
            try await session.writeWaveform(exportData)
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
actor RAWExportSession: ExportSession {

    private var headerWritten = false
    private nonisolated let progress: ExportSessionProgress
    private let helper: ExportSessionHelper
    private let useBinaryFormat: Bool
    private let byteOrder: ByteOrder

    nonisolated var pointsWritten: Int {
        progress.pointsWritten
    }

    init(
        destination: ExportDestination,
        metadata: SimulationMetadata,
        sweepVariable: VariableDescriptor,
        variables: [VariableDescriptor],
        configuration: ExportConfiguration,
        useBinaryFormat: Bool
    ) throws {
        guard configuration.includeMetadata, configuration.includeVariableNames else {
            throw ExporterError.invalidConfiguration(
                reason: "RAW requires metadata and variable names for a valid file"
            )
        }
        self.useBinaryFormat = useBinaryFormat
        self.byteOrder = configuration.byteOrder
        let helper = try ExportSessionHelper(
            metadata: metadata,
            sweepVariable: sweepVariable,
            variables: variables,
            configuration: configuration,
            destination: destination
        )
        self.progress = helper.progress
        self.helper = helper
    }

    /// Keep full-waveform export on one executor while retaining per-point cancellation checks.
    func writeWaveform(_ exportData: any WaveformReadable) throws {
        if exportData.isComplex {
            for point in 0..<exportData.pointCount {
                try Task.checkCancellation()
                guard let sweepValue = exportData.sweepValue(at: point) else {
                    throw ExporterError.unsupportedDataFormat(reason: "Sweep point unavailable")
                }
                try writeComplexPointValues(
                    sweepValue: sweepValue,
                    source: exportData,
                    point: point
                )
            }
        } else {
            for point in 0..<exportData.pointCount {
                try Task.checkCancellation()
                guard let sweepValue = exportData.sweepValue(at: point) else {
                    throw ExporterError.unsupportedDataFormat(reason: "Sweep point unavailable")
                }
                try writePointValues(
                    sweepValue: sweepValue,
                    source: exportData,
                    point: point
                )
            }
        }
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
        if !headerWritten {
            try writeHeader(isComplex: false)
            headerWritten = true
        }

        if useBinaryFormat {
            try writeBinaryPoint(sweepValue: sweepValue, values: values)
        } else {
            try writeASCIIPoint(sweepValue: sweepValue, values: values)
        }

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
        if !headerWritten {
            try writeHeader(isComplex: false)
            headerWritten = true
        }

        if useBinaryFormat {
            try writeBinaryPointValues(sweepValue: sweepValue, source: source, point: point)
        } else {
            try writeASCIIPointValues(sweepValue: sweepValue, source: source, point: point)
        }

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
        if !headerWritten {
            try writeHeader(isComplex: true)
            headerWritten = true
        }

        if useBinaryFormat {
            try writeBinaryComplexPoint(sweepValue: sweepValue, values: values)
        } else {
            try writeASCIIComplexPoint(sweepValue: sweepValue, values: values)
        }

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
        if !headerWritten {
            try writeHeader(isComplex: true)
            headerWritten = true
        }

        if useBinaryFormat {
            try writeBinaryComplexPointValues(sweepValue: sweepValue, source: source, point: point)
        } else {
            try writeASCIIComplexPointValues(sweepValue: sweepValue, source: source, point: point)
        }

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

    private func writeBinaryPoint(
        sweepValue: Double,
        values: UnsafeBufferPointer<Double>
    ) throws {
        var data = Data()
        data.reserveCapacity((values.count + 1) * MemoryLayout<UInt64>.size)

        // Write sweep value as double with correct byte order
        appendDouble(sweepValue, to: &data)

        // Write each variable
        for value in values {
            appendDouble(value, to: &data)
        }

        try helper.write(data)
    }

    private func writeBinaryComplexPoint(
        sweepValue: Double,
        values: UnsafeBufferPointer<(real: Double, imag: Double)>
    ) throws {
        var data = Data()
        data.reserveCapacity(((values.count + 1) * 2) * MemoryLayout<UInt64>.size)

        // Write sweep value as complex (real, imag=0)
        appendDouble(sweepValue, to: &data)
        appendDouble(0.0, to: &data)

        // Write each complex variable
        for value in values {
            appendDouble(value.real, to: &data)
            appendDouble(value.imag, to: &data)
        }

        try helper.write(data)
    }

    private func writeBinaryPointValues(
        sweepValue: Double,
        source: any WaveformReadable,
        point: Int
    ) throws {
        var data = Data()
        data.reserveCapacity((source.variableCount + 1) * MemoryLayout<UInt64>.size)

        appendDouble(sweepValue, to: &data)
        let completed = source.forEachRealValue(at: point) { value in
            appendDouble(value, to: &data)
        }
        guard completed else {
            throw ExporterError.unsupportedDataFormat(reason: "Real point storage unavailable")
        }

        try helper.write(data)
    }

    private func writeBinaryComplexPointValues(
        sweepValue: Double,
        source: any WaveformReadable,
        point: Int
    ) throws {
        var data = Data()
        data.reserveCapacity(((source.variableCount + 1) * 2) * MemoryLayout<UInt64>.size)

        appendDouble(sweepValue, to: &data)
        appendDouble(0.0, to: &data)
        let completed = source.forEachComplexValue(at: point) { value in
            appendDouble(value.real, to: &data)
            appendDouble(value.imag, to: &data)
        }
        guard completed else {
            throw ExporterError.unsupportedDataFormat(reason: "Complex point storage unavailable")
        }

        try helper.write(data)
    }

    /// Appends a Double to Data with the configured byte order.
    private func appendDouble(_ value: Double, to data: inout Data) {
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

        withUnsafeBytes(of: bytes) { data.append(contentsOf: $0) }
    }

    private func writeASCIIPoint(
        sweepValue: Double,
        values: UnsafeBufferPointer<Double>
    ) throws {
        var line = "\(helper.pointsWritten)\t\(formatDouble(sweepValue))"
        for value in values {
            line += "\t\(formatDouble(value))"
        }
        line += "\n"
        try helper.write(line)
    }

    private func writeASCIIPointValues(
        sweepValue: Double,
        source: any WaveformReadable,
        point: Int
    ) throws {
        var line = "\(helper.pointsWritten)\t\(formatDouble(sweepValue))"
        let completed = source.forEachRealValue(at: point) { value in
            line += "\t\(formatDouble(value))"
        }
        guard completed else {
            throw ExporterError.unsupportedDataFormat(reason: "Real point storage unavailable")
        }
        line += "\n"
        try helper.write(line)
    }

    private func writeASCIIComplexPoint(
        sweepValue: Double,
        values: UnsafeBufferPointer<(real: Double, imag: Double)>
    ) throws {
        var line = "\(helper.pointsWritten)\t\(formatDouble(sweepValue)),\(formatDouble(0.0))"
        for value in values {
            line += "\t\(formatDouble(value.real)),\(formatDouble(value.imag))"
        }
        line += "\n"
        try helper.write(line)
    }

    private func writeASCIIComplexPointValues(
        sweepValue: Double,
        source: any WaveformReadable,
        point: Int
    ) throws {
        var line = "\(helper.pointsWritten)\t\(formatDouble(sweepValue)),\(formatDouble(0.0))"
        let completed = source.forEachComplexValue(at: point) { value in
            line += "\t\(formatDouble(value.real)),\(formatDouble(value.imag))"
        }
        guard completed else {
            throw ExporterError.unsupportedDataFormat(reason: "Complex point storage unavailable")
        }
        line += "\n"
        try helper.write(line)
    }

    private func formatDouble(_ value: Double) -> String {
        String(
            format: "%.\(helper.configuration.precision)e",
            locale: Locale(identifier: "en_US_POSIX"),
            value
        ).lowercased()
    }
}
