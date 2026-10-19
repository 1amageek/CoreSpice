import CoreSpiceExporter

/// No suspension occurs inside a complete writer operation.
actor TouchstoneActorExportSession: TouchstoneExportSession {
    private let writer: TouchstoneWriter

    init(destination: ExportDestination, parameterKind: TouchstoneParameterKind,
         references: [Double], frequencyCount: Int,
         configuration: TouchstoneEncodingConfiguration, limits: TouchstoneLimits) throws {
        writer = try TouchstoneWriter(destination: destination, parameterKind: parameterKind,
                                     references: references, frequencyCount: frequencyCount,
                                     configuration: configuration, limits: limits)
    }

    func writePoint(_ point: TouchstonePoint) async throws {
        do { try writer.writePoint(point) }
        catch { throw writer.discard(after: error) }
    }

    func writeAll(_ points: [TouchstonePoint]) throws -> ExportResult {
        do {
            for point in points { try writer.writePoint(point) }
            return try writer.finalize()
        } catch { throw writer.discard(after: error) }
    }

    func finalize() async throws -> ExportResult {
        do { return try writer.finalize() }
        catch { throw writer.discard(after: error) }
    }

    func cancel() async throws { try writer.cancel() }
}
