/// Work and retained-storage dimensions charged before their corresponding operations.
public enum SPICESourceWorkKind: String, Sendable, Hashable, CaseIterable {
    case sourceBytes, projectedBytes, lexicalBytes, tokens, retainedElements
    case dependencyExpansions, conditionalEvaluations
}
