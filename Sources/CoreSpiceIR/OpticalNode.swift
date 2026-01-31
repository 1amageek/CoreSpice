/// A node in the optical signal network.
///
/// Optical nodes represent connection points for optical signals,
/// analogous to electrical `Node` but for the optical domain.
/// The optical ground node has id 0 and represents "no optical connection".
///
/// Node IDs are used as indices into `OpticalState.signals` for O(1) access.
public struct OpticalNode: Hashable, Sendable {

    public let id: Int

    public static let opticalGround = OpticalNode(id: 0)

    public init(id: Int) {
        self.id = id
    }
}
