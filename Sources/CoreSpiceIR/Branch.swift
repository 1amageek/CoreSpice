/// A branch in the MNA formulation.
///
/// Branches represent current variables introduced by voltage sources
/// and inductors in Modified Nodal Analysis.
public struct Branch: Hashable, Sendable {

    public let id: Int

    public init(id: Int) {
        self.id = id
    }
}
