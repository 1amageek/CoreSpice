import CoreSpiceExporter
import Foundation

/// Exactly one writer owns this unpublished output and its checked close path.
final class TouchstoneOutput {
    private enum Phase { case open, published, cancelled, failed }
    private var phase: Phase = .open
    private var handle: FileHandle?
    private var memory: [UInt8]?
    private let temporaryURL: URL?
    private let destinationURL: URL?
    private let limits: TouchstoneLimits
    private var bytesWritten: UInt64 = 0
    private var tokensWritten: UInt64 = 0
    private var lineNumber = 1

    init(destination: ExportDestination, limits: TouchstoneLimits) throws {
        try Task.checkCancellation()
        self.limits = limits
        switch destination {
        case .memory:
            temporaryURL = nil; destinationURL = nil; memory = []
        case .file(let path):
            let destination = URL(fileURLWithPath: path)
            destinationURL = destination
            let temporary = destination.deletingLastPathComponent().appendingPathComponent(".\(destination.lastPathComponent).touchstone-\(UUID().uuidString).partial")
            temporaryURL = temporary
            guard FileManager.default.createFile(atPath: temporary.path, contents: nil) else { throw TouchstoneError.io("Cannot create temporary Touchstone output") }
            do { handle = try FileHandle(forWritingTo: temporary) }
            catch { throw discard(after: error) }
        }
    }

    deinit {
        if phase != .published {
            do { try cancel() }
            catch {
                // Destruction cannot throw; explicit finalize/cancel owns checked cleanup.
                #if DEBUG
                print("CoreSpiceIO Touchstone cleanup failed: \(error)")
                #endif
            }
        }
    }

    func requireOpen() throws {
        guard phase == .open else { throw TouchstoneError.endedSession }
    }

    /// The formatter uses the same admission before extending a header or row.
    @discardableResult
    func admitLineStorage(byteCount count: Int) throws -> UInt64 {
        try requireOpen()
        try Task.checkCancellation()
        let at = TouchstoneSourcePosition(byteOffset: bytesWritten, line: lineNumber, column: 1)
        guard count >= 0 else { throw TouchstoneError.invalidData("Negative output line length") }
        guard count <= limits.maximumLineBytes else { throw TouchstoneError.limitExceeded("line bytes", limit: UInt64(limits.maximumLineBytes), requested: UInt64(count), at: at) }
        let nextBytes = try touchstoneSum(bytesWritten, UInt64(count) + 1)
        guard nextBytes <= limits.maximumOutputBytes, nextBytes <= UInt64(Int.max) else { throw TouchstoneError.limitExceeded("output bytes", limit: min(limits.maximumOutputBytes, UInt64(Int.max)), requested: nextBytes, at: at) }
        let scratch = try touchstoneBytes(count + 1, 4)
        let retained = try touchstoneSum(UInt64(memory?.capacity ?? 0), scratch)
        guard retained <= limits.maximumRetainedBytes else { throw TouchstoneError.limitExceeded("retained bytes", limit: limits.maximumRetainedBytes, requested: retained, at: at) }
        return scratch
    }

    func writeLine(_ text: String) throws {
        let count = text.utf8.count
        let scratch = try admitLineStorage(byteCount: count)
        let at = TouchstoneSourcePosition(byteOffset: bytesWritten, line: lineNumber, column: 1)
        var tokenLength = 0
        var tokenCount: UInt64 = 0
        for byte in text.utf8 {
            if byte == 32 || byte == 9 { tokenLength = 0 }
            else {
                if tokenLength == 0 { tokenCount += 1 }
                tokenLength += 1
                guard tokenLength <= limits.maximumTokenBytes else { throw TouchstoneError.limitExceeded("token bytes", limit: UInt64(limits.maximumTokenBytes), requested: UInt64(tokenLength), at: at) }
            }
        }
        let nextTokens = try touchstoneSum(tokensWritten, tokenCount)
        guard nextTokens <= limits.maximumTokens else { throw TouchstoneError.limitExceeded("tokens", limit: limits.maximumTokens, requested: nextTokens, at: at) }
        let nextBytes = try touchstoneSum(bytesWritten, UInt64(count) + 1)
        var bytes = Data(text.utf8)
        bytes.append(10)
        var start = bytes.startIndex
        while start < bytes.endIndex {
            try Task.checkCancellation()
            let end = start + min(64 * 1024, bytes.endIndex - start)
            if memory != nil {
                let required = (memory?.count ?? 0) + end - start
                let capacity = memory?.capacity ?? 0
                if required > capacity {
                    let growth = min(Int(min(limits.maximumOutputBytes, UInt64(Int.max))), max(required, capacity + min(capacity, Int.max - capacity)))
                    let proposed = try touchstoneSum(UInt64(growth), scratch)
                    guard proposed <= limits.maximumRetainedBytes else { throw TouchstoneError.limitExceeded("retained bytes", limit: limits.maximumRetainedBytes, requested: proposed, at: at) }
                    memory?.reserveCapacity(growth)
                    let actual = try touchstoneSum(UInt64(memory?.capacity ?? 0), scratch)
                    guard actual <= limits.maximumRetainedBytes else { throw TouchstoneError.limitExceeded("retained bytes", limit: limits.maximumRetainedBytes, requested: actual, at: at) }
                }
                memory?.append(contentsOf: bytes[start..<end])
            }
            else if let handle { try handle.write(contentsOf: bytes[start..<end]) }
            else { throw TouchstoneError.io("Output handle is closed") }
            start = end
        }
        try Task.checkCancellation()
        bytesWritten = nextBytes; tokensWritten = nextTokens; lineNumber += 1
    }

    func finalize(points: Int, elements: Int) throws -> ExportResult {
        try requireOpen()
        try Task.checkCancellation()
        try handle?.synchronize()
        try handle?.close()
        handle = nil
        try Task.checkCancellation()
        if let temporaryURL, let destinationURL {
            let manager = FileManager.default
            let exists = manager.fileExists(atPath: destinationURL.path)
            try Task.checkCancellation()
            if exists { _ = try manager.replaceItemAt(destinationURL, withItemAt: temporaryURL) }
            else { try manager.moveItem(at: temporaryURL, to: destinationURL) }
        }
        let data: Data?
        if let memory {
            // One necessary Data materialization at the public output boundary;
            // admit its coexistence with the capacity-observable builder first.
            let peak = try touchstoneSum(UInt64(memory.capacity), UInt64(memory.count))
            guard peak <= limits.maximumRetainedBytes else {
                throw TouchstoneError.limitExceeded("retained bytes", limit: limits.maximumRetainedBytes, requested: peak, at: .init(byteOffset: bytesWritten, line: lineNumber))
            }
            data = Data(memory)
            self.memory = nil
            try Task.checkCancellation()
        } else { data = nil }
        phase = .published
        return ExportResult(pointsExported: points, variablesExported: elements, bytesWritten: Int(bytesWritten), outputPath: destinationURL?.path, data: data)
    }

    func cancel() throws {
        guard phase != .published, phase != .cancelled else { return }
        phase = .failed
        var failure: String?
        if let handle {
            self.handle = nil
            do { try handle.close() }
            catch { failure = "close: \(error)" }
        }
        memory = nil
        if let temporaryURL {
            do { try FileManager.default.removeItem(at: temporaryURL) }
            catch let error as CocoaError where error.code == .fileNoSuchFile { }
            catch { failure = [failure, "remove: \(error)"].compactMap { $0 }.joined(separator: "; ") }
        }
        if let failure { throw TouchstoneError.io(failure) }
        phase = .cancelled
    }

    func discard(after primary: any Error) -> any Error {
        do { try cancel(); return primary }
        catch { return TouchstoneError.cleanup(primary: String(describing: primary), cleanup: String(describing: error)) }
    }
}
