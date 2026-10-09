public struct MOSInputGeometry: Sendable, Hashable {
    public let length: Double?
    public let width: Double?
    public let drainArea: Double?
    public let sourceArea: Double?
    public let drainPerimeter: Double?
    public let sourcePerimeter: Double?
    public init(length: Double?, width: Double?, drainArea: Double? = nil, sourceArea: Double? = nil,
                drainPerimeter: Double? = nil, sourcePerimeter: Double? = nil) {
        self.length = length; self.width = width; self.drainArea = drainArea; self.sourceArea = sourceArea
        self.drainPerimeter = drainPerimeter; self.sourcePerimeter = sourcePerimeter
    }
    package func validate() throws(MOSResolutionFailure) {
        for (name, value) in [("l", length), ("w", width)] {
            if let value, !value.isFinite || value <= 0 { throw .invalidGeometry(name) }
        }
        for (name, value) in [("ad", drainArea), ("as", sourceArea), ("pd", drainPerimeter), ("ps", sourcePerimeter)] {
            if let value, !value.isFinite || value < 0 { throw .invalidGeometry(name) }
        }
    }
}
