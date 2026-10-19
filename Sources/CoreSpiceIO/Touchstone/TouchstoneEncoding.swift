import CoreSpiceExporter
import Foundation

/// Encodes typed network data, independently of waveform column naming.
public protocol TouchstoneEncoding: Sendable {
    func encode(_ data: TouchstoneData, configuration: TouchstoneEncodingConfiguration, limits: TouchstoneLimits) throws -> Data
    func export(_ data: TouchstoneData, to destination: ExportDestination,
                configuration: TouchstoneEncodingConfiguration, limits: TouchstoneLimits) async throws -> ExportResult
    func beginExport(to destination: ExportDestination, parameterKind: TouchstoneParameterKind,
                     referenceResistances: [Double], frequencyPointCount: Int,
                     configuration: TouchstoneEncodingConfiguration, limits: TouchstoneLimits) async throws -> any TouchstoneExportSession
}
