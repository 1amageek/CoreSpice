import CoreSpiceWaveform
import CoreSpiceExporter
import Foundation

/// Exports waveform data in Cadence PSF (Parameter Storage Format).
///
/// PSF is a binary format commonly used by Cadence tools (Spectre, ADE).
/// This implementation writes "simple" (non-windowed) PSF files.
public struct PSFExporter: WaveformExporter, StreamingWaveformExporter {

    public let formatIdentifier = "psf"
    public let fileExtension = "psf"
    public let formatName = "Cadence PSF"
    public let supportsStreaming = true

    public init() {}

    public func export(
        _ data: any WaveformReadable,
        to destination: ExportDestination,
        configuration: ExportConfiguration
    ) async throws -> ExportResult {
        try Task.checkCancellation()
        let exportData = configuration.applyFilters(to: data)
        let session = try PSFExportSession(
            destination: destination,
            metadata: exportData.metadata,
            sweepVariable: exportData.sweepVariable,
            variables: exportData.variables,
            configuration: configuration
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
        try PSFExportSession(
            destination: destination,
            metadata: metadata,
            sweepVariable: sweepVariable,
            variables: variables,
            configuration: configuration
        )
    }
}

/// Export session for PSF format.
actor PSFExportSession: ExportSession {

    private var headerWritten = false
    private nonisolated let progress: ExportSessionProgress
    private let helper: ExportSessionHelper

    nonisolated var pointsWritten: Int {
        progress.pointsWritten
    }

    init(
        destination: ExportDestination,
        metadata: SimulationMetadata,
        sweepVariable: VariableDescriptor,
        variables: [VariableDescriptor],
        configuration: ExportConfiguration
    ) throws {
        guard configuration.includeMetadata, configuration.includeVariableNames else {
            throw ExporterError.invalidConfiguration(
                reason: "PSF requires metadata and variable names for a valid file"
            )
        }
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

        try writeValuePoint(sweepValue: sweepValue, values: values)
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

        try writeValuePoint(sweepValue: sweepValue, source: source, point: point)
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

        try writeComplexValuePoint(sweepValue: sweepValue, values: values)
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

        try writeComplexValuePoint(sweepValue: sweepValue, source: source, point: point)
        try helper.incrementPointCount()
    }

    func finalize() async throws -> ExportResult {
        do {
            try writeEndSection()
            return try helper.finalize()
        } catch {
            helper.cancel()
            throw error
        }
    }

    func cancel() async {
        helper.cancel()
    }

    // MARK: - Private Methods

    private func writeHeader(isComplex: Bool) throws {
        var writer = PSFBinaryWriter()

        // Magic number
        writer.writeUInt32(PSFFormat.magic)

        // Header section
        let headerContent = buildHeaderSection()
        writer.writeSectionHeader(type: PSFFormat.headerSection, size: UInt32(headerContent.count))
        writer.writeData(headerContent)

        // Type section
        let typeContent = buildTypeSection(isComplex: isComplex)
        writer.writeSectionHeader(type: PSFFormat.typeSection, size: UInt32(typeContent.count))
        writer.writeData(typeContent)

        // Sweep section
        let sweepContent = buildSweepSection()
        writer.writeSectionHeader(type: PSFFormat.sweepSection, size: UInt32(sweepContent.count))
        writer.writeData(sweepContent)

        // Trace section
        let traceContent = buildTraceSection(isComplex: isComplex)
        writer.writeSectionHeader(type: PSFFormat.traceSection, size: UInt32(traceContent.count))
        writer.writeData(traceContent)

        guard helper.metadata.pointCount > 0 else {
            throw ExporterError.invalidConfiguration(
                reason: "PSF streaming requires an exact positive point count"
            )
        }
        let scalarWidth = isComplex ? 16 : 8
        let (valuesPerPoint, valuesOverflow) = helper.variables.count
            .addingReportingOverflow(1)
        let (bytesPerPoint, widthOverflow) = valuesPerPoint
            .multipliedReportingOverflow(by: scalarWidth)
        let (valueByteCount, pointOverflow) = bytesPerPoint
            .multipliedReportingOverflow(by: helper.metadata.pointCount)
        guard !valuesOverflow,
              !widthOverflow,
              !pointOverflow,
              valueByteCount <= Int(UInt32.max) else {
            throw ExporterError.invalidConfiguration(
                reason: "PSF value section exceeds the UInt32 format limit"
            )
        }
        writer.writeSectionHeader(
            type: PSFFormat.valueSection,
            size: UInt32(valueByteCount)
        )

        try helper.write(writer.data)
    }

    private func buildHeaderSection() -> Data {
        var writer = PSFBinaryWriter()

        // PSF version
        writer.writeProperty(id: PSFFormat.propVersion, string: "1.00")

        // Title
        writer.writeProperty(id: PSFFormat.propTitle, string: helper.metadata.title ?? "CoreSpice Simulation")

        // Date
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE MMM dd HH:mm:ss yyyy"
        writer.writeProperty(id: PSFFormat.propDate, string: formatter.string(from: helper.metadata.date))

        // Origin
        writer.writeProperty(id: PSFFormat.propOrigin, string: "CoreSpice")

        // Analysis type
        writer.writeProperty(id: PSFFormat.propAnalysisType, string: helper.metadata.analysisType.psfAnalysisName)

        // End of properties marker (property count as negative)
        writer.writeInt32(-1)

        return writer.data
    }

    private func buildTypeSection(isComplex: Bool) -> Data {
        var writer = PSFBinaryWriter()

        // Number of types defined
        writer.writeInt32(1)

        // Type definition: real or complex
        if isComplex {
            writer.writeUInt32(PSFFormat.typeComplex)
        } else {
            writer.writeUInt32(PSFFormat.typeReal)
        }

        return writer.data
    }

    private func buildSweepSection() -> Data {
        var writer = PSFBinaryWriter()

        // Number of sweep variables
        writer.writeInt32(1)

        // Sweep variable definition
        writer.writeString(helper.sweepVariable.name)
        writer.writeUInt32(PSFFormat.typeReal)  // Sweep is always real

        return writer.data
    }

    private func buildTraceSection(isComplex: Bool) -> Data {
        var writer = PSFBinaryWriter()

        // Number of traces
        writer.writeInt32(Int32(helper.variables.count))

        // Trace definitions
        let dataType = isComplex ? PSFFormat.typeComplex : PSFFormat.typeReal
        for variable in helper.variables {
            writer.writeString(variable.name)
            writer.writeUInt32(dataType)
        }

        return writer.data
    }

    private func writeValuePoint(
        sweepValue: Double,
        values: UnsafeBufferPointer<Double>
    ) throws {
        var writer = PSFBinaryWriter(capacity: (values.count + 1) * 8)
        writer.writeDouble(sweepValue)
        for value in values {
            writer.writeDouble(value)
        }
        try helper.write(writer.data)
    }

    private func writeValuePoint(
        sweepValue: Double,
        source: any WaveformReadable,
        point: Int
    ) throws {
        var writer = PSFBinaryWriter(capacity: (source.variableCount + 1) * 8)
        writer.writeDouble(sweepValue)
        let completed = source.forEachRealValue(at: point) { value in
            writer.writeDouble(value)
        }
        guard completed else {
            throw ExporterError.unsupportedDataFormat(reason: "Real point storage unavailable")
        }
        try helper.write(writer.data)
    }

    private func writeComplexValuePoint(
        sweepValue: Double,
        values: UnsafeBufferPointer<(real: Double, imag: Double)>
    ) throws {
        var writer = PSFBinaryWriter(capacity: (values.count + 1) * 16)
        writer.writeComplex(real: sweepValue, imag: 0.0)
        for value in values {
            writer.writeComplex(real: value.real, imag: value.imag)
        }
        try helper.write(writer.data)
    }

    private func writeComplexValuePoint(
        sweepValue: Double,
        source: any WaveformReadable,
        point: Int
    ) throws {
        var writer = PSFBinaryWriter(capacity: (source.variableCount + 1) * 16)
        writer.writeComplex(real: sweepValue, imag: 0.0)
        let completed = source.forEachComplexValue(at: point) { value in
            writer.writeComplex(real: value.real, imag: value.imag)
        }
        guard completed else {
            throw ExporterError.unsupportedDataFormat(reason: "Complex point storage unavailable")
        }
        try helper.write(writer.data)
    }

    private func writeEndSection() throws {
        var writer = PSFBinaryWriter()
        writer.writeSectionHeader(type: PSFFormat.endSection, size: 0)
        try helper.write(writer.data)
    }
}

// MARK: - Analysis Kind Extension

extension AnalysisKind {

    /// Returns the PSF analysis name for this analysis type.
    var psfAnalysisName: String {
        switch self {
        case .operatingPoint:
            return "dcOp"
        case .dc:
            return "dc"
        case .ac:
            return "ac"
        case .networkParameters:
            return "network"
        case .transient:
            return "tran"
        case .noise:
            return "noise"
        case .sensitivity:
            return "sens"
        case .transferFunction:
            return "tf"
        case .poleZero:
            return "pz"
        case .fourier:
            return "four"
        case .monteCarlo:
            return "mc"
        }
    }
}
