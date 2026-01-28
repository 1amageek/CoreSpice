/// Identifies a variable in the MNA system.
///
/// Each variable has a numeric kind (real or complex) and a
/// positional index within that kind's namespace.
public struct VarID: Hashable, Sendable {

    public let kind: UnknownKind
    public let index: Int

    public init(kind: UnknownKind, index: Int) {
        self.kind = kind
        self.index = index
    }
}
