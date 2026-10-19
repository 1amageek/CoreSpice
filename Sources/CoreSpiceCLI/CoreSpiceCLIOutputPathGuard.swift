import Foundation

/// Shared filesystem identity admission; output owners map its refusals to their domain errors.
struct CoreSpiceCLIOutputPathGuard {
    enum Failure: Error {
        case protectedAlias(String)
        case duplicateOutput(String)
        case existingOutput(String)
        var reason: String {
            switch self {
            case .protectedAlias: "CLI output aliases a protected input or selected output"
            case .duplicateOutput: "CLI output aliases another output"
            case .existingOutput: "CLI output already exists; choose a fresh immutable destination"
            }
        }
    }
    private struct Identity: Equatable {
        let path: String
        let device: UInt64?
        let inode: UInt64?
        func aliases(_ other: Self) -> Bool {
            path == other.path || (device != nil && device == other.device && inode != nil && inode == other.inode)
        }
    }
    private static func identity(_ path: String) throws -> Identity {
        let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        if FileManager.default.fileExists(atPath: url.path) {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            return .init(path: url.path, device: (attributes[.systemNumber] as? NSNumber)?.uint64Value,
                inode: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value)
        }
        return .init(path: url.path, device: nil, inode: nil)
    }
    static func validate(inputs: [String], outputs: [String]) throws {
        let protected = try inputs.map(identity)
        var selected: [Identity] = []
        for path in outputs {
            let value = try identity(path)
            guard !protected.contains(where: { $0.aliases(value) }) else { throw Failure.protectedAlias(path) }
            guard !selected.contains(where: { $0.aliases(value) }) else { throw Failure.duplicateOutput(path) }
            guard !FileManager.default.fileExists(atPath: path) else { throw Failure.existingOutput(path) }
            selected.append(value)
        }
    }
}
