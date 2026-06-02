public enum BenchmarkError: Error, CustomStringConvertible {
    case nonFiniteChecksum(String)
    case nonPositiveDuration(String)
    case missingRowMajorStorage(String)
    case referenceMismatch(name: String, lhs: Double, rhs: Double)
    case storageNotShared(String)

    public var description: String {
        switch self {
        case .nonFiniteChecksum(let name):
            return "\(name) produced a non-finite checksum."
        case .nonPositiveDuration(let name):
            return "\(name) produced a non-positive median duration."
        case .missingRowMajorStorage(let name):
            return "\(name) did not expose row-major storage."
        case .referenceMismatch(let name, let lhs, let rhs):
            return "\(name) reference mismatch: \(lhs) vs \(rhs)."
        case .storageNotShared(let name):
            return "\(name) did not preserve storage sharing."
        }
    }
}
