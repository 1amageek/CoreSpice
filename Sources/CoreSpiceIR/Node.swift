/// A node in the circuit graph.
///
/// Each node represents an electrical connection point. The ground node
/// is the reference node with id 0.
public struct Node: Hashable, Sendable {

    public let id: Int

    public static let ground = Node(id: 0)

    public init(id: Int) {
        self.id = id
    }
}
