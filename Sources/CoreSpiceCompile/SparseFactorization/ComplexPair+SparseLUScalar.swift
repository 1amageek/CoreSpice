extension ComplexPair: SparseLUScalar {
    static var luZero: ComplexPair { .zero }
    static var luOne: ComplexPair { .one }
    var luIsFinite: Bool { real.isFinite && imag.isFinite }
    var luMagnitude: Double { max(abs(real), abs(imag)) }

    static func luSubtractProduct(
        _ accumulator: ComplexPair, _ lhs: ComplexPair, _ rhs: ComplexPair
    ) -> ComplexPair {
        ComplexPair(
            real: accumulator.real.addingProduct(-lhs.real, rhs.real).addingProduct(lhs.imag, rhs.imag),
            imag: accumulator.imag.addingProduct(-lhs.real, rhs.imag).addingProduct(-lhs.imag, rhs.real)
        )
    }

    static func luDivide(_ lhs: ComplexPair, _ rhs: ComplexPair) -> ComplexPair {
        lhs / rhs
    }
}
