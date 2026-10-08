import CoreSpiceParsedIR

/// Exact source admission and graph failures never return a partially loaded deck.
public enum SPICEExactSourceError: Error, Sendable, Equatable {
    case invalidPolicy
    case invalidSourceKey
    case duplicateSource(String)
    case undeclaredSource(String)
    case sourceDrift(String)
    case unsupportedDigest(String)
    case invalidUTF8(String)
    case undeclaredDependency(parent: String, path: String)
    case graphMismatch
    case unusedSource(String)
    case workLimit(SPICESourceWorkKind)
}