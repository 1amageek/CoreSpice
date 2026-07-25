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
        guard sweepValues.count == values.count else {
            throw ExporterError.streamingError(
                reason: "Batch contains \(sweepValues.count) sweep values and \(values.count) value rows"
            )
        }
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

    public enum PointKind: Sendable, Equatable {
        case real
        case complex
    }

    /// Mutable state protected by Mutex.
    private struct MutableState {
        enum Phase: Equatable {
            case open
            case finalized
            case cancelled
            case failed
        }

        var pointsWritten: Int = 0
        var bytesWritten: Int = 0
        var fileHandle: FileHandle?
        var outputData: Data?
        var pointKind: PointKind?
        var phase: Phase = .open
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

    private let temporaryPath: String?

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
        try configuration.validate()
        self.metadata = metadata
        self.sweepVariable = sweepVariable
        self.variables = variables
        self.configuration = configuration

        var initialState = MutableState()

        switch destination {
        case .file(let path):
            self.isMemoryExport = false
            self.outputPath = path
            let destinationURL = URL(fileURLWithPath: path)
            let temporaryURL = destinationURL
                .deletingLastPathComponent()
                .appendingPathComponent(
                    ".\(destinationURL.lastPathComponent).corespice-\(UUID().uuidString).partial"
                )
            self.temporaryPath = temporaryURL.path
            guard FileManager.default.createFile(
                atPath: temporaryURL.path,
                contents: nil
            ) else {
                throw ExporterError.cannotCreateFile(path: temporaryURL.path)
            }
            let handle = FileHandle(forWritingAtPath: temporaryURL.path)
            if handle == nil {
                throw ExporterError.cannotCreateFile(path: temporaryURL.path)
            }
            initialState.fileHandle = handle

        case .memory:
            self.isMemoryExport = true
            self.outputPath = nil
            self.temporaryPath = nil
            initialState.outputData = Data()
        }

        self.state = Mutex(initialState)
    }

    /// Writes data to the output.
    public func write(_ data: Data) throws {
        try state.withLock { state in
            guard state.phase == .open else {
                throw ExporterError.streamingError(
                    reason: "Cannot write after the export session has ended"
                )
            }
            do {
                if isMemoryExport {
                    guard state.outputData != nil else {
                        throw ExporterError.writeFailed(
                            reason: "In-memory output storage is unavailable"
                        )
                    }
                    state.outputData?.append(data)
                } else {
                    guard let handle = state.fileHandle else {
                        throw ExporterError.writeFailed(reason: "Output file handle is closed")
                    }
                    try handle.write(contentsOf: data)
                }
                state.bytesWritten += data.count
            } catch {
                state.phase = .failed
                state.fileHandle?.closeFile()
                state.fileHandle = nil
                throw error
            }
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
    public func validatePoint(
        kind: PointKind,
        sweepValue: Double,
        valueCount: Int
    ) throws {
        try state.withLock { state in
            guard state.phase == .open else {
                throw ExporterError.streamingError(
                    reason: "Cannot write a point after the export session has ended"
                )
            }
            guard sweepValue.isFinite else {
                throw ExporterError.streamingError(
                    reason: "Sweep value must be finite"
                )
            }
            guard valueCount == variables.count else {
                throw ExporterError.streamingError(
                    reason: "Expected \(variables.count) values, got \(valueCount)"
                )
            }
            if let pointKind = state.pointKind, pointKind != kind {
                throw ExporterError.streamingError(
                    reason: "Cannot mix real and complex points in one export session"
                )
            }
            state.pointKind = kind
        }
    }

    /// Increments the point counter after one complete point was written.
    public func incrementPointCount() throws {
        try state.withLock { state in
            guard state.phase == .open else {
                throw ExporterError.streamingError(
                    reason: "Cannot count a point after the export session has ended"
                )
            }
            state.pointsWritten += 1
        }
    }

    /// Creates the final export result.
    private func createResult() -> ExportResult {
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

    /// Atomically commits the completed output.
    public func finalize() throws -> ExportResult {
        try state.withLock { state in
            guard state.phase == .open else {
                throw ExporterError.streamingError(
                    reason: "Export session can only be finalized once"
                )
            }
            if metadata.pointCount > 0, state.pointsWritten != metadata.pointCount {
                throw ExporterError.streamingError(
                    reason: "Expected \(metadata.pointCount) points, wrote \(state.pointsWritten)"
                )
            }
            do {
                try state.fileHandle?.synchronize()
                try state.fileHandle?.close()
                state.fileHandle = nil

                if let temporaryPath, let outputPath {
                    let manager = FileManager.default
                    let temporaryURL = URL(fileURLWithPath: temporaryPath)
                    let outputURL = URL(fileURLWithPath: outputPath)
                    if manager.fileExists(atPath: outputPath) {
                        _ = try manager.replaceItemAt(
                            outputURL,
                            withItemAt: temporaryURL
                        )
                    } else {
                        try manager.moveItem(at: temporaryURL, to: outputURL)
                    }
                }
                state.phase = .finalized
            } catch {
                state.phase = .failed
                throw ExporterError.writeFailed(
                    reason: "Failed to commit export atomically: \(error)"
                )
            }
        }
        return createResult()
    }

    /// Cancels the session and removes its uncommitted temporary file.
    public func cancel() {
        let pathToRemove = state.withLock { state -> String? in
            guard state.phase == .open || state.phase == .failed else { return nil }
            state.fileHandle?.closeFile()
            state.fileHandle = nil
            state.phase = .cancelled
            return temporaryPath
        }
        if let pathToRemove {
            do {
                try FileManager.default.removeItem(atPath: pathToRemove)
            } catch let error as CocoaError where error.code == .fileNoSuchFile {
                return
            } catch {
                #if DEBUG
                print("CoreSpiceExporter: failed to remove partial output \(pathToRemove): \(error)")
                #endif
            }
        }
    }

    /// The current output data for an in-memory export.
    public var outputData: Data? {
        state.withLock { $0.outputData }
    }
}
