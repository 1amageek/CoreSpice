/// Checked source field address; strings name fields, never expression text.
public enum NetlistScalarAddress: Sendable, Hashable {
    case control(index: Int, field: String)
    case analysis(index: Int, field: String)
    case initialCondition(node: String)
    case nodeSet(node: String)
}
