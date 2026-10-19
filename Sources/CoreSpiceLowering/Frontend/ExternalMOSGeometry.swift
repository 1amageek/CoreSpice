/// Profile-owned distinction between supplied geometry, bin coordinates and provider geometry.
public struct ExternalMOSGeometry: Sendable, Equatable {
    public let rawLength: Double?
    public let rawWidth: Double?
    public let effectiveLengthSI: Double
    public let totalWidthSI: Double
    public let selectionLengthSI: Double
    public let selectionWidthSI: Double
    public let fingerCount: Double
    public let parallelMultiplier: Double
    public let widthInputIsPerFinger: Bool

    public init(rawLength: Double?, rawWidth: Double?, effectiveLengthSI: Double,
                totalWidthSI: Double, selectionLengthSI: Double, selectionWidthSI: Double,
                fingerCount: Double, parallelMultiplier: Double, widthInputIsPerFinger: Bool) {
        self.rawLength = rawLength; self.rawWidth = rawWidth
        self.effectiveLengthSI = effectiveLengthSI; self.totalWidthSI = totalWidthSI
        self.selectionLengthSI = selectionLengthSI; self.selectionWidthSI = selectionWidthSI
        self.fingerCount = fingerCount; self.parallelMultiplier = parallelMultiplier
        self.widthInputIsPerFinger = widthInputIsPerFinger
    }
}
