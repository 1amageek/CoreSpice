import CoreSpiceAnalysis

/// A solved Newton system failed the original physical equation at this compiled row.
public struct SPICEOSDIPhysicalResidualFailure: Error, Sendable {
    public let row: Int
    public let kind: DCEquationKind
    public let residual: Double
    public let absoluteTolerance: Double
}
