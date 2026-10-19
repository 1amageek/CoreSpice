/// Source preparation failures remain distinct from foreign setup failures.
public enum MOSBinPreparationError: Error, Sendable, Equatable {
    case invalidProfile(String)
    case descriptorMismatch(String)
    case invalidSource(String)
    case unknownParameter(String)
    case duplicateParameter(String)
    case invalidParameter(String)
    case missingGeometry(String)
    case invalidGeometry(String)
    case invalidBin(String)
    case duplicateModel(String)
    case ambiguousBins
    case noMatchingBin
    case sizeOverflow
}
