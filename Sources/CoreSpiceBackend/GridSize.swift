public struct GridSize: Sendable {

    public let width: Int
    public let height: Int
    public let depth: Int

    public init(width: Int, height: Int = 1, depth: Int = 1) {
        self.width = width
        self.height = height
        self.depth = depth
    }

    public static func oneDimensional(_ size: Int) -> GridSize {
        GridSize(width: size)
    }

    public static func twoDimensional(_ width: Int, _ height: Int) -> GridSize {
        GridSize(width: width, height: height)
    }
}
