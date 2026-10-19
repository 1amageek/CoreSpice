/// Statically specialized scalar operations for the shared sparse traversal.
protocol SparseLUScalar: Sendable, Equatable {
    static var luZero: Self { get }
    static var luOne: Self { get }
    var luIsFinite: Bool { get }
    var luMagnitude: Double { get }
    static func luSubtractProduct(_ accumulator: Self, _ lhs: Self, _ rhs: Self) -> Self
    static func luDivide(_ lhs: Self, _ rhs: Self) -> Self
}

extension Double: SparseLUScalar {
    static var luZero: Double { 0 }
    static var luOne: Double { 1 }
    var luIsFinite: Bool { isFinite }
    var luMagnitude: Double { abs(self) }
    static func luSubtractProduct(_ accumulator: Double, _ lhs: Double, _ rhs: Double) -> Double {
        accumulator.addingProduct(-lhs, rhs)
    }
    static func luDivide(_ lhs: Double, _ rhs: Double) -> Double { lhs / rhs }
}
