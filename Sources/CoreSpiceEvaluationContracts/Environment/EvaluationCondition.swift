/// Ordered global temperature roots, independent of any device model.
public enum EvaluationCondition: UInt8, Sendable, Hashable {
    case ambient, nominal
}
