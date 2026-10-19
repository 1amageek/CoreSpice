import CoreSpiceEvent
import Foundation

/// The strict single-ended Touchstone network-exchange decoder.
public struct TouchstoneDecoder: TouchstoneDecoding {
    public init() {}

    public func decode(
        _ bytes: Data,
        configuration: TouchstoneDecodingConfiguration = .init(),
        limits: TouchstoneLimits = .init(),
        cancellation: CancellationToken? = nil
    ) throws -> TouchstoneData {
        var stream = try TouchstoneStreamDecoder(configuration: configuration, limits: limits, cancellation: cancellation)
        try stream.append(bytes)
        return try stream.finish()
    }
}
