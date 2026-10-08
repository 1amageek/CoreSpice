/// Static failures preserve resource/resolver causes rather than rendering them as strings.
public enum SPICEBoundedSourceError: Error, Sendable, Equatable {
    case invalidPolicy
    case invalidEnvironment
    case caseCollidingParameter
    case unsupportedBudgetCapability(String)
    case invalidUTF8
    case unaccountedSource
    case invalidSourceContext
}
