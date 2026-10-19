/// Invalid original-equation contributions are fatal numerical failures.
public enum NonlinearPhysicalResidualError: Error, Sendable, Equatable {
    case insufficientPrecision(row: Int, radius: Double, tolerance: Double)
    case uncertifiedResidual(row: Int, upperBound: Double, tolerance: Double)
    case invalidRow(row: Int, dimension: Int)
    case nonfiniteContribution(row: Int, value: Double)
}
