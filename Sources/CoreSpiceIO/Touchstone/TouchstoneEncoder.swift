import CoreSpiceExporter
import Foundation

/// Bounded memory encoding and standalone transactional file output.
public struct TouchstoneEncoder: TouchstoneEncoding {
    public init() {}

    public func encode(
        _ data: TouchstoneData,
        configuration: TouchstoneEncodingConfiguration = .init(),
        limits: TouchstoneLimits = .init()
    ) throws -> Data {
        let writer = try TouchstoneWriter(destination: .memory, parameterKind: data.parameterKind,
                                         references: data.referenceResistances, frequencyCount: data.points.count,
                                         configuration: configuration, limits: limits)
        do {
            for point in data.points { try writer.writePoint(point) }
            let result = try writer.finalize()
            guard let bytes = result.data else { throw TouchstoneError.io("Memory output is unavailable") }
            return bytes
        } catch { throw writer.discard(after: error) }
    }

    public func export(
        _ data: TouchstoneData,
        to destination: ExportDestination,
        configuration: TouchstoneEncodingConfiguration = .init(),
        limits: TouchstoneLimits = .init()
    ) async throws -> ExportResult {
        let session = try TouchstoneActorExportSession(destination: destination, parameterKind: data.parameterKind,
                                                       references: data.referenceResistances, frequencyCount: data.points.count,
                                                       configuration: configuration, limits: limits)
        return try await session.writeAll(data.points)
    }

    public func beginExport(
        to destination: ExportDestination,
        parameterKind: TouchstoneParameterKind,
        referenceResistances: [Double],
        frequencyPointCount: Int,
        configuration: TouchstoneEncodingConfiguration = .init(),
        limits: TouchstoneLimits = .init()
    ) async throws -> any TouchstoneExportSession {
        try TouchstoneActorExportSession(destination: destination, parameterKind: parameterKind,
                                        references: referenceResistances, frequencyCount: frequencyPointCount,
                                        configuration: configuration, limits: limits)
    }
}
