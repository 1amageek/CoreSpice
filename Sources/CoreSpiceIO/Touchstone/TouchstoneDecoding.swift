import CoreSpiceEvent
import Foundation

/// Decodes supplied bytes without discovering or reopening input files.
public protocol TouchstoneDecoding: Sendable {
    func decode(
        _ bytes: Data,
        configuration: TouchstoneDecodingConfiguration,
        limits: TouchstoneLimits,
        cancellation: CancellationToken?
    ) throws -> TouchstoneData
}
