import Foundation
import Synchronization

public final class JsonLinesObserver: AnalysisObserver {

    private let fileHandle: Mutex<FileHandle>

    public init(fileHandle: FileHandle) {
        self.fileHandle = Mutex(fileHandle)
    }

    public func onEvent(_ event: AnalysisEvent) {
        let envelope = EventEnvelope(event: event)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        fileHandle.withLock { handle in
            do {
                let data = try encoder.encode(envelope)
                handle.write(data)
                handle.write(Data([0x0A])) // newline
            } catch {
                let message = "[CoreSpice] Failed to encode event: \(error)\n"
                if let errorData = message.data(using: .utf8) {
                    FileHandle.standardError.write(errorData)
                }
            }
        }
    }
}
