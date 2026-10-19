/// A signed twofold center with a certified absolute error, including arithmetic rounding.
public struct CompensatedEnclosure: Sendable, Equatable {
    public let center: CompensatedValue
    public let radius: Double

    public init(center: CompensatedValue, radius: Double = 0) throws {
        guard radius.isFinite, radius >= 0 else { throw NumericalStateError.invalidRadius(radius) }
        self.center = center; self.radius = radius
    }

    private static func addUp(_ a: Double, _ b: Double) throws -> Double {
        let sum = a + b
        guard sum.isFinite else { throw NumericalStateError.arithmeticOverflow }
        return a == 0 && b == 0 ? 0 : sum.nextUp
    }

    private static func multiplyUp(_ a: Double, _ b: Double) throws -> Double {
        if a == 0 || b == 0 { return 0 }
        let product = a * b
        guard product.isFinite, product.nextUp.isFinite else { throw NumericalStateError.arithmeticOverflow }
        return product.nextUp
    }

    /// The bound projection is used only after cancellation has occurred in the DD center.
    public var absoluteUpperBound: Double {
        let bounds = center.bounds
        let magnitude = max(abs(bounds.lower), abs(bounds.upper))
        if radius == 0 { return magnitude }
        return (magnitude + radius).nextUp
    }

    public func adding(_ other: Self) throws -> Self {
        let result = try CompensatedValue.addition(center, other.center)
        return try Self(center: result.0, radius: Self.addUp(Self.addUp(radius, other.radius), result.1))
    }

    public func negated() throws -> Self { try Self(center: center.negated(), radius: radius) }
    public func subtracting(_ other: Self) throws -> Self { try adding(other.negated()) }

    /// FMA TwoProduct is exact except for gradual-underflow residual loss.
    /// One least subnormal bounds that loss even when both returned terms round to zero.
    private static func product(_ a: Double, _ b: Double) throws -> Self {
        if a == 0 || b == 0 { return try Self(center: .zero) }
        let high = a * b
        guard high.isFinite else { throw NumericalStateError.arithmeticOverflow }
        let low = (-high).addingProduct(a, b)
        return try Self(center: CompensatedValue.normalized(high, low), radius: .leastNonzeroMagnitude)
    }

    public func multiplied(by other: Self) throws -> Self {
        var product = try Self.product(center.high, other.center.high)
        product = try product.adding(Self.product(center.high, other.center.low))
        product = try product.adding(Self.product(center.low, other.center.high))
        product = try product.adding(Self.product(center.low, other.center.low))
        let aMagnitude = max(abs(center.bounds.lower), abs(center.bounds.upper))
        let bMagnitude = max(abs(other.center.bounds.lower), abs(other.center.bounds.upper))
        var error = try Self.addUp(product.radius, Self.multiplyUp(aMagnitude, other.radius))
        error = try Self.addUp(error, Self.multiplyUp(bMagnitude, radius))
        error = try Self.addUp(error, Self.multiplyUp(radius, other.radius))
        return try Self(center: product.center, radius: error)
    }

    public func divided(by other: Self) throws -> Self {
        let bounds = other.center.bounds
        let lower = other.radius == 0 ? bounds.lower : (bounds.lower - other.radius).nextDown
        let upper = other.radius == 0 ? bounds.upper : (bounds.upper + other.radius).nextUp
        guard lower.isFinite, upper.isFinite else { throw NumericalStateError.arithmeticOverflow }
        guard lower > 0 || upper < 0 else { throw NumericalStateError.divisionByZero }
        let minimumMagnitude = min(abs(lower), abs(upper))
        let quotient = try center.divided(by: other.center)
        // A/B - q = (A - B*q)/B; this retains small differences of large coordinates.
        let residual = try subtracting(other.multiplied(by: Self(center: quotient)))
        let residualBound = residual.absoluteUpperBound
        let error = residualBound / minimumMagnitude
        guard error.isFinite, error.nextUp.isFinite else { throw NumericalStateError.arithmeticOverflow }
        // A positive exact error may underflow during division; nextUp(0) still encloses it.
        return try Self(center: quotient, radius: residualBound == 0 ? 0 : error.nextUp)
    }
}
