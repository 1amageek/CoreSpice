import CoreSpiceIO
import Darwin
import Foundation

/// Private sibling staging and no-replace publication for one CLI invocation.
struct CoreSpiceCLIPrecisionPublication {
    private struct Entry {
        let destination: String
        let staged: String
        var directory = false
    }
    private var entries: [Entry] = []
    private var published: [String] = []

    init(inputs: [String], outputs: [String]) throws {
        do { try CoreSpiceCLIOutputPathGuard.validate(inputs: inputs, outputs: outputs) }
        catch let failure as CoreSpiceCLIOutputPathGuard.Failure {
            throw CoreSpiceCLIOSDIError.incompleteReceipt(failure.reason)
        }
    }

    mutating func stage(for destination: String) throws -> String {
        let parent = URL(fileURLWithPath: destination).deletingLastPathComponent()
        let path = parent.appendingPathComponent(".corespice-output-" + UUID().uuidString).path
        let descriptor = Darwin.open(path, O_WRONLY | O_CREAT | O_EXCL, mode_t(0o600))
        guard descriptor >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        entries.append(.init(destination: destination, staged: path))
        guard Darwin.close(descriptor) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        return path
    }

    mutating func stageDirectory(for destination: String) throws -> String {
        let parent = URL(fileURLWithPath: destination).deletingLastPathComponent()
        let path = parent.appendingPathComponent(".corespice-output-" + UUID().uuidString).path
        guard Darwin.mkdir(path, mode_t(0o700)) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        entries.append(.init(destination: destination, staged: path, directory: true))
        return path
    }

    func chargeHash(path: String, maximumBytes: UInt64, resources: any SPICESourceResourceAccounting) throws {
        try resources.checkCancellation()
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        guard let size = (attributes[.size] as? NSNumber)?.uint64Value, size <= maximumBytes else {
            throw CoreSpiceCLIOSDIError.incompleteReceipt("Staged precision output exceeds evidence ceiling")
        }
        try resources.chargeHashedBytes(size)
    }

    mutating func publish() throws {
        for entry in entries {
            // linkItem fails if the destination already exists, including a raced alias.
            if entry.directory {
                guard Darwin.renamex_np(entry.staged, entry.destination, UInt32(RENAME_EXCL)) == 0 else {
                    throw POSIXError(.init(rawValue: errno) ?? .EIO)
                }
            } else { try FileManager.default.linkItem(atPath: entry.staged, toPath: entry.destination) }
            published.append(entry.destination)
        }
        for entry in entries where !entry.directory { try FileManager.default.removeItem(atPath: entry.staged) }
        entries = []; published = []
    }

    mutating func failed(_ primary: any Error) throws -> Never {
        var failures: [String] = []
        for path in entries.map(\.staged) + published where FileManager.default.fileExists(atPath: path) {
            do { try FileManager.default.removeItem(atPath: path) }
            catch { failures.append("\(path): \(error)") }
        }
        entries = []; published = []
        guard failures.isEmpty else {
            throw CoreSpiceCLIOSDIError.incompleteReceipt("CLI output publication failed: \(primary); cleanup failed: \(failures.joined(separator: "; "))")
        }
        throw primary
    }
}
