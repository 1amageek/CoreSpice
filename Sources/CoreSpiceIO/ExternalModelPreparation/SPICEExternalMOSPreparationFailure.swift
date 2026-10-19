/// Invalid external preparation metadata, before any source or numerical evaluation.
public enum SPICEExternalMOSPreparationFailure: Error, Sendable, Equatable {
    case invalidIdentity
    case capacityOverflow
}
