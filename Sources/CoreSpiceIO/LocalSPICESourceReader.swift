import Foundation

/// One opened handle owns the bounded initial read and checked close.
public struct LocalSPICESourceReader: SPICESourceReading {
    private let open: @Sendable (String) throws -> any SPICESourceFileHandle
    public init() { open = { try FoundationSPICESourceFileHandle(path: $0) } }
    init(open: @escaping @Sendable (String) throws -> any SPICESourceFileHandle) { self.open = open }

    public func read(at path: String, maximumByteCount: UInt64, maximumPageByteCount: UInt64) throws -> Data {
        guard maximumByteCount <= UInt64(Int.max), maximumPageByteCount > 0, maximumPageByteCount <= UInt64(Int.max) else {
            throw SPICESourceCaptureError.invalidPolicy
        }
        let handle: any SPICESourceFileHandle
        do { handle = try open(path) }
        catch { throw SPICESourceCaptureError.readFailed(path: path, reason: String(describing: error)) }
        let bytes: Data
        do {
            let size = try handle.seekToEnd()
            guard size <= maximumByteCount else {
                throw SPICESourceCaptureError.totalByteLimitExceeded(limit: maximumByteCount, requested: size)
            }
            try handle.seek(toOffset: 0)
            var storage = Data()
            // Admission precedes allocation; growth is detected without reading beyond the budget.
            storage.reserveCapacity(Int(size))
            while UInt64(storage.count) < size {
                let remaining = size - UInt64(storage.count)
                let count = Int(min(remaining, maximumPageByteCount))
                guard let page = try handle.read(upToCount: count), !page.isEmpty else {
                    throw SPICESourceCaptureError.readFailed(path: path, reason: "Source ended before its admitted byte count.")
                }
                storage.append(page)
            }
            guard try handle.seekToEnd() == size else {
                throw SPICESourceCaptureError.sourceChangedDuringRead(path: path)
            }
            bytes = storage
        } catch let primary {
            do { try handle.close() }
            catch { throw SPICESourceCaptureError.cleanupFailed(primary: String(describing: primary), closeReason: String(describing: error)) }
            if let captureError = primary as? SPICESourceCaptureError { throw captureError }
            throw SPICESourceCaptureError.readFailed(path: path, reason: String(describing: primary))
        }
        do { try handle.close() }
        catch { throw SPICESourceCaptureError.closeFailed(path: path, reason: String(describing: error)) }
        return bytes
    }
}
