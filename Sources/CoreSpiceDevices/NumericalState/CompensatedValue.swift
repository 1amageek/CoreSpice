/// A real value represented by a normalized, nonoverlapping binary64 pair.
public struct CompensatedValue: Sendable, Equatable {
    public let high: Double
    public let low: Double
    public static let zero = Self(uncheckedHigh: 0, low: 0)

    public init(high: Double, low: Double = 0) throws {
        guard high.isFinite, low.isFinite else { throw NumericalStateError.nonFiniteComponent }
        let pair = Self.twoSum(high, low)
        guard pair.0.isFinite else { throw NumericalStateError.arithmeticOverflow }
        guard pair.0 == high, pair.1 == low else { throw NumericalStateError.nonNormalizedPair }
        self.init(uncheckedHigh: high == 0 ? 0 : high, low: low == 0 ? 0 : low)
    }

    private init(uncheckedHigh high: Double, low: Double) { self.high = high; self.low = low }

    private static func twoSum(_ a: Double, _ b: Double) -> (Double, Double) {
        let sum = a + b
        let virtualB = sum - a
        return (sum, (a - (sum - virtualB)) + (b - virtualB))
    }

    static func normalized(_ high: Double, _ low: Double) throws -> Self {
        let pair = twoSum(high, low)
        return try Self(high: pair.0, low: pair.1)
    }

    public func negated() -> Self { Self(uncheckedHigh: -high, low: low == 0 ? 0 : -low) }

    /// Produces a represented iterate; equation enclosures certify it independently.
    public func adding(_ other: Self) throws -> Self { try Self.addition(self, other).0 }

    /// TwoSum retains every large cancellation before bounding only discarded tails.
    static func addition(_ a: Self, _ b: Self) throws -> (Self, Double) {
        let s = twoSum(a.high, b.high)
        let t = twoSum(a.low, b.low)
        let u = twoSum(s.1, t.0)
        let v = twoSum(s.0, u.0)
        let w = twoSum(v.1, u.1)
        let tail = twoSum(w.0, t.1)
        let center = try normalized(v.0, tail.0)
        let discarded = abs(w.1) + abs(tail.1)
        guard discarded.isFinite else { throw NumericalStateError.arithmeticOverflow }
        return (center, discarded == 0 ? 0 : discarded.nextUp)
    }

    public func subtracting(_ other: Self) throws -> Self { try adding(other.negated()) }

    public func multiplied(by other: Self) throws -> Self {
        let product = high * other.high
        guard product.isFinite else { throw NumericalStateError.arithmeticOverflow }
        let error = (-product).addingProduct(high, other.high)
        return try Self.normalized(product, error + high * other.low + low * other.high + low * other.low)
    }

    public func divided(by other: Self) throws -> Self {
        guard other.high != 0 || other.low != 0 else { throw NumericalStateError.divisionByZero }
        let quotient = high / other.high
        guard quotient.isFinite else { throw NumericalStateError.arithmeticOverflow }
        let first = try Self(high: quotient)
        let remainder = try subtracting(other.multiplied(by: first))
        return try first.adding(Self(high: (remainder.high + remainder.low) / other.high))
    }

    /// Outward binary64 bounds include gradual-underflow rounding.
    public var bounds: (lower: Double, upper: Double) {
        if low == 0 { return (high, high) }
        let rounded = high + low
        return (rounded.nextDown, rounded.nextUp)
    }
}
