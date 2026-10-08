import Foundation

/// Native Foundation handle adapter with one synchronous read owner.
final class FoundationSPICESourceFileHandle: SPICESourceFileHandle {
    private let handle: FileHandle
    init(path: String) throws { handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path)) }
    func seekToEnd() throws -> UInt64 { try handle.seekToEnd() }
    func seek(toOffset: UInt64) throws { try handle.seek(toOffset: toOffset) }
    func read(upToCount: Int) throws -> Data? { try handle.read(upToCount: upToCount) }
    func close() throws { try handle.close() }
}
