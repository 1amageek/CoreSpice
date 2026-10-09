public enum MOSCandidateDisposition: Sendable, Hashable {
    case selected, shadowed, missingBounds, outsideBounds, incompatibleRelease, duplicate
}
