import CoreSpiceWaveform
import Foundation
import Synchronization

/// A protocol for streaming waveform exporters.
///
/// Streaming exporters allow writing waveform data point-by-point
/// without holding the entire dataset in memory. This is useful
/// for large simulations.
public protocol StreamingWaveformExporter: WaveformExporter {

    /// Begins a streaming export session.
    ///
    /// - Parameters:
    ///   - destination: Where to write the output.
    ///   - metadata: Simulation metadata for the header.
    ///   - sweepVariable: The sweep variable descriptor.
    ///   - variables: Descriptors for all data variables.
    ///   - configuration: Export configuration options.
    /// - Returns: An export session for writing data.
    func beginExport(
        to destination: ExportDestination,
        metadata: SimulationMetadata,
        sweepVariable: VariableDescriptor,
        variables: [VariableDescriptor],
        configuration: ExportConfiguration
    ) async throws -> any ExportSession
}

/// A session for streaming waveform export.
///
/// Export sessions write data incrementally and must be finalized
/// when all data has been written.
public protocol ExportSession: Sendable {

    /// Writes a single data point.
    ///
    /// - Parameters:
    ///   - sweepValue: The sweep value (time, frequency, etc.).
    ///   - values: The variable values at this point.
    func writePoint(
        sweepValue: Double,
        values: [Double]
    ) async throws

    /// Writes a single complex data point.
    ///
    /// - Parameters:
    ///   - sweepValue: The sweep value (time, frequency, etc.).
    ///   - values: The complex variable values at this point.
    func writeComplexPoint(
        sweepValue: Double,
        values: [(real: Double, imag: Double)]
    ) async throws

    /// Writes a batch of data points for efficiency.
    ///
    /// - Parameters:
    ///   - sweepValues: The sweep values.
    ///   - values: The variable values as [point][variable].
    func writeBatch(
        sweepValues: [Double],
        values: [[Double]]
    ) async throws

    /// Finalizes the export session and closes the output.
    ///
    /// - Returns: The export result.
    func finalize() async throws -> ExportResult

    /// The number of points written so far.
    var pointsWritten: Int { get }

    /// Cancels the export session, discarding any partial output.
    func cancel() async
}

extension ExportSession {

    /// Default implementation for complex point writing (not all exporters support this).
    public func writeComplexPoint(
        sweepValue: Double,
        values: [(real: Double, imag: Double)]
    ) async throws {
        throw ExporterError.unsupportedDataFormat(reason: "Complex data not supported")
    }

    /// Default implementation for batch writing.
    public func writeBatch(
        sweepValues: [Double],
        values: [[Double]]
    ) async throws {
        for (i, sweep) in sweepValues.enumerated() {
            try await writePoint(sweepValue: sweep, values: values[i])
        }
    }
}

/// A helper class for export sessions with common I/O functionality.
///
/// Uses `Mutex` for thread-safe mutable state access.
/// Export session implementations should compose this helper rather than inherit from it.
public final class ExportSessionHelper: Sendable {

    /// Mutable state protected by Mutex.
    private struct MutableState {
        var pointsWritten: Int = 0
        var bytesWritten: Int = 0
        var fileHandle: FileHandle?
        var outputData: Data?
    }

    /// The protected mutable state.
    private let state: Mutex<MutableState>

    /// The metadata for this export.
    public let metadata: SimulationMetadata

    /// The sweep variable.
    public let sweepVariable: VariableDescriptor

    /// The data variables.
    public let variables: [VariableDescriptor]

    /// The configuration.
    public let configuration: ExportConfiguration

    /// Whether we're exporting to memory.
    public let isMemoryExport: Bool

    /// The output path if writing to file.
    public let outputPath: String?

    /// Counter for points written.
    public var pointsWritten: Int {
        state.withLock { $0.pointsWritten }
    }

    /// Total bytes written.
    public var bytesWritten: Int {
        state.withLock { $0.bytesWritten }
    }

    public init(
        metadata: SimulationMetadata,
        sweepVariable: VariableDescriptor,
        variables: [VariableDescriptor],
        configuration: ExportConfiguration,
        destination: ExportDestination
    ) throws {
        self.metadata = metadata
        self.sweepVariable = sweepVariable
        self.variables = variables
        self.configuration = configuration

        var initialState = MutableState()

        switch destination {
        case .file(let path):
            self.isMemoryExport = false
            self.outputPath = path
            FileManager.default.createFile(atPath: path, contents: nil)
            let handle = FileHandle(forWritingAtPath: path)
            if handle == nil {
                throw ExporterError.cannotCreateFile(path: path)
            }
            initialState.fileHandle = handle

        case .memory:
            self.isMemoryExport = true
            self.outputPath = nil
            initialState.outputData = Data()
        }

        self.state = Mutex(initialState)
    }

    /// Writes data to the output.
    public func write(_ data: Data) throws {
        state.withLock { state in
            if isMemoryExport {
                state.outputData?.append(data)
            } else if let handle = state.fileHandle {
                handle.write(data)
            }
            state.bytesWritten += data.count
        }
    }

    /// Writes a string to the output.
    public func write(_ string: String) throws {
        guard let data = string.data(using: .utf8) else {
            throw ExporterError.writeFailed(reason: "Failed to encode string as UTF-8")
        }
        try write(data)
    }

    /// Increments the point counter.
    public func incrementPointCount() {
        state.withLock { $0.pointsWritten += 1 }
    }

    /// Creates the final export result.
    public func createResult() -> ExportResult {
        state.withLock { state in
            ExportResult(
                pointsExported: state.pointsWritten,
                variablesExported: variables.count,
                bytesWritten: state.bytesWritten,
                outputPath: outputPath,
                data: state.outputData
            )
        }
    }

    /// Closes the file handle.
    public func close() {
        state.withLock { state in
            state.fileHandle?.closeFile()
            state.fileHandle = nil
        }
    }

    /// The current output data for an in-memory export.
    public var outputData: Data? {
        state.withLock { $0.outputData }
    }
}
