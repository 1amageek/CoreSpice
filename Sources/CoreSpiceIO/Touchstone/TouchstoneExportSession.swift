import CoreSpiceExporter

/// Serialized network output. Finish or cancel explicitly for checked cleanup.
public protocol TouchstoneExportSession: Sendable {
    func writePoint(_ point: TouchstonePoint) async throws
    func finalize() async throws -> ExportResult
    func cancel() async throws
}
