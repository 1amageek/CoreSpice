import CoreSpiceWaveform
import CoreSpiceExporter
import Foundation
import Synchronization

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
final class PSFExportSession: ExportSession, Sendable {

    /// Local mutable state protected by Mutex.
    private struct LocalState {
        var headerWritten = false
        var isComplex = false
        var valueBuffer: PSFBinaryWriter = PSFBinaryWriter()
    }

    private let localState: Mutex<LocalState>
    private let helper: ExportSessionHelper

    var pointsWritten: Int {
        helper.pointsWritten
    }

    init(
        destination: ExportDestination,
        metadata: SimulationMetadata,
        sweepVariable: VariableDescriptor,
        variables: [VariableDescriptor],
        configuration: ExportConfiguration
    ) throws {
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

        try writeValuePoint(sweepValue: sweepValue, values: values)
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

        try writeComplexValuePoint(sweepValue: sweepValue, values: values)
        helper.incrementPointCount()
    }

    func finalize() async throws -> ExportResult {
        // Write value section
        let valueData = localState.withLock { state -> Data in
            state.valueBuffer.getData()
        }

        // Write value section header with actual size
        var sectionWriter = PSFBinaryWriter()
        sectionWriter.writeSectionHeader(type: PSFFormat.valueSection, size: UInt32(valueData.count))
        try helper.write(sectionWriter.getData())
        try helper.write(valueData)

        // Write end section
        try writeEndSection()

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

        try helper.write(writer.getData())
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

        return writer.getData()
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

        return writer.getData()
    }

    private func buildSweepSection() -> Data {
        var writer = PSFBinaryWriter()

        // Number of sweep variables
        writer.writeInt32(1)

        // Sweep variable definition
        writer.writeString(helper.sweepVariable.name)
        writer.writeUInt32(PSFFormat.typeReal)  // Sweep is always real

        return writer.getData()
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

        return writer.getData()
    }

    private func writeValuePoint(sweepValue: Double, values: [Double]) throws {
        localState.withLock { state in
            // Write sweep value
            state.valueBuffer.writeDouble(sweepValue)

            // Write each variable value
            for value in values {
                state.valueBuffer.writeDouble(value)
            }
        }
    }

    private func writeComplexValuePoint(
        sweepValue: Double,
        values: [(real: Double, imag: Double)]
    ) throws {
        localState.withLock { state in
            // Write sweep value as complex (real, imag=0)
            state.valueBuffer.writeComplex(real: sweepValue, imag: 0.0)

            // Write each complex variable
            for value in values {
                state.valueBuffer.writeComplex(real: value.real, imag: value.imag)
            }
        }
    }

    private func writeEndSection() throws {
        var writer = PSFBinaryWriter()
        writer.writeSectionHeader(type: PSFFormat.endSection, size: 0)
        try helper.write(writer.getData())
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
        }
    }
}
