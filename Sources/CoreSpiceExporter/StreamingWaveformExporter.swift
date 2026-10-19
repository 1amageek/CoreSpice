import CoreSpiceWaveform
import Foundation

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
        do {
            for (i, sweep) in sweepValues.enumerated() {
                try await writePoint(sweepValue: sweep, values: values[i])
            }
        } catch is CancellationError {
            await cancel()
            throw CancellationError()
        }
    }
}

/// A synchronous output owner. A session actor must exclusively own this helper.
/// Only its point-count snapshot may be shared across isolation boundaries.
public final class ExportSessionHelper {
    public enum PointKind: Sendable, Equatable {
        case real
        case complex
    }

    private enum Phase {
        case open
        case finalized
        case cancelled
        case failed
    }

    private var phase: Phase = .open
    private var fileHandle: FileHandle?
    private var memoryData: Data?
    private var pointKind: PointKind?
    private var writtenBytes = 0
    public let progress: ExportSessionProgress
    public let metadata: SimulationMetadata
    public let sweepVariable: VariableDescriptor
    public let variables: [VariableDescriptor]
    public let configuration: ExportConfiguration
    public let isMemoryExport: Bool
    public let outputPath: String?
    private let temporaryPath: String?

    public var pointsWritten: Int { progress.pointsWritten }
    public var bytesWritten: Int { writtenBytes }
    public var outputData: Data? { memoryData }

    public init(
        metadata: SimulationMetadata,
        sweepVariable: VariableDescriptor,
        variables: [VariableDescriptor],
        configuration: ExportConfiguration,
        destination: ExportDestination
    ) throws {
        try Task.checkCancellation()
        try configuration.validate()
        self.metadata = metadata
        self.sweepVariable = sweepVariable
        self.variables = variables
        self.configuration = configuration
        self.progress = ExportSessionProgress()
        switch destination {
        case .file(let path):
            isMemoryExport = false
            outputPath = path
            let url = URL(fileURLWithPath: path)
            let temporaryURL = url.deletingLastPathComponent().appendingPathComponent(
                ".\(url.lastPathComponent).corespice-\(UUID().uuidString).partial"
            )
            temporaryPath = temporaryURL.path
            guard FileManager.default.createFile(atPath: temporaryURL.path, contents: nil) else {
                throw ExporterError.cannotCreateFile(path: temporaryURL.path)
            }
            do {
                fileHandle = try FileHandle(forWritingTo: temporaryURL)
            } catch {
                do {
                    try FileManager.default.removeItem(at: temporaryURL)
                } catch {
                    throw ExporterError.writeFailed(reason: "Cannot open or remove temporary output: \(error)")
                }
                throw ExporterError.cannotCreateFile(path: temporaryURL.path)
            }
        case .memory:
            isMemoryExport = true
            outputPath = nil
            temporaryPath = nil
            memoryData = Data()
        }
        try checkCancellation()
    }

    public func write(_ data: Data) throws {
        try requireOpen()
        do {
            // Bound cancellation latency during large row/header writes without copying file chunks.
            let chunkSize = 64 * 1024
            var offset = data.startIndex
            while offset < data.endIndex {
                try Task.checkCancellation()
                let end = offset + min(chunkSize, data.endIndex - offset)
                if isMemoryExport {
                    memoryData?.append(data[offset..<end])
                } else {
                    guard let fileHandle else {
                        throw ExporterError.writeFailed(reason: "Output file handle is closed")
                    }
                    try fileHandle.write(contentsOf: data[offset..<end])
                }
                writtenBytes += end - offset
                offset = end
            }
            try Task.checkCancellation()
        } catch {
            cancel()
            throw error
        }
    }

    public func write(_ string: String) throws {
        try write(Data(string.utf8))
    }

    public func validatePoint(kind: PointKind, sweepValue: Double, valueCount: Int) throws {
        try requireOpen()
        try checkCancellation()
        guard sweepValue.isFinite else {
            throw ExporterError.streamingError(reason: "Sweep value must be finite")
        }
        guard valueCount == variables.count else {
            throw ExporterError.streamingError(reason: "Expected \(variables.count) values, got \(valueCount)")
        }
        if let pointKind, pointKind != kind {
            throw ExporterError.streamingError(reason: "Cannot mix real and complex points in one export session")
        }
        self.pointKind = kind
    }

    public func incrementPointCount() throws {
        try requireOpen()
        progress.increment()
    }

    public func finalize() throws -> ExportResult {
        try requireOpen()
        do {
            try Task.checkCancellation()
            if metadata.pointCount > 0, pointsWritten != metadata.pointCount {
                throw ExporterError.streamingError(
                    reason: "Expected \(metadata.pointCount) points, wrote \(pointsWritten)"
                )
            }
            try fileHandle?.synchronize()
            try fileHandle?.close()
            fileHandle = nil
            // The next atomic move/replace is the publication linearization point.
            try Task.checkCancellation()
            if let temporaryPath, let outputPath {
                let manager = FileManager.default
                let temporaryURL = URL(fileURLWithPath: temporaryPath)
                let outputURL = URL(fileURLWithPath: outputPath)
                let destinationExists = manager.fileExists(atPath: outputPath)
                try Task.checkCancellation()
                if destinationExists {
                    _ = try manager.replaceItemAt(outputURL, withItemAt: temporaryURL)
                } else {
                    try manager.moveItem(at: temporaryURL, to: outputURL)
                }
            }
            phase = .finalized
            return ExportResult(
                pointsExported: pointsWritten, variablesExported: variables.count,
                bytesWritten: writtenBytes, outputPath: outputPath, data: memoryData
            )
        } catch let error as CancellationError {
            cancel()
            throw error
        } catch let error as ExporterError {
            cancel()
            throw error
        } catch {
            cancel()
            throw ExporterError.writeFailed(reason: "Failed to commit export atomically: \(error)")
        }
    }

    public func cancel() {
        guard phase == .open || phase == .failed else { return }
        phase = .cancelled
        memoryData = nil
        if let handle = fileHandle {
            fileHandle = nil
            do {
                try handle.close()
            } catch {
                phase = .failed
            }
        }
        if let temporaryPath {
            do {
                try FileManager.default.removeItem(atPath: temporaryPath)
            } catch let error as CocoaError where error.code == .fileNoSuchFile {
                return
            } catch {
                phase = .failed
                #if DEBUG
                print("CoreSpiceExporter: failed to remove partial output \(temporaryPath): \(error)")
                #endif
            }
        }
    }

    private func requireOpen() throws {
        guard phase == .open else {
            throw ExporterError.streamingError(reason: "Export session has ended")
        }
    }

    private func checkCancellation() throws {
        do {
            try Task.checkCancellation()
        } catch {
            cancel()
            throw error
        }
    }
}
