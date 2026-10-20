import CoreSpiceCompile
import CoreSpiceDevices
import CoreSpiceEvent

/// Finite numerical self-map/contraction checks, conditional on the caller's field premises.
package enum ValidatedPicardSlab {
    package struct Limits: Sendable {
        package let maximumDimension: Int
        package let maximumResultBytes: Int
        package init(maximumDimension: Int, maximumResultBytes: Int) {
            self.maximumDimension = maximumDimension
            self.maximumResultBytes = maximumResultBytes
        }
    }
    package enum Failure: Error, Sendable, Equatable {
        case invalidInput
        case nonFiniteInput
        case resultLimit
        case selfMapUncertified
        case contractionUncertified
    }
    /// Numerical endpoint data only; no source or trajectory premise is established here.
    package final class Result: Sendable {
        package let dimension: Int
        package let duration: CompensatedValue
        package let contractionUpperBound: Double
        private let endpoints: [CompensatedEnclosure]
        private let lease: any Sendable
        fileprivate init(endpoints: [CompensatedEnclosure], duration: CompensatedValue,
            contractionUpperBound: Double, lease: any Sendable) {
            dimension = endpoints.count; self.duration = duration
            self.contractionUpperBound = contractionUpperBound
            self.endpoints = endpoints; self.lease = lease
        }
        package func endpoint(at index: Int) throws -> CompensatedEnclosure {
            guard endpoints.indices.contains(index) else { throw Failure.invalidInput }
            return endpoints[index]
        }
    }

    /// Borrows the complete box and uniform field only for this synchronous operation.
    package static func certify(lower: borrowing Span<CompensatedValue>,
        upper: borrowing Span<CompensatedValue>, initial: borrowing Span<CompensatedEnclosure>,
        field: borrowing Span<CompensatedEnclosure>, duration: CompensatedValue,
        lipschitzUpperBound: Double, limits: Limits,
        control: any LinearSolverExecutionControlling, cancellation: CancellationToken) throws -> Result {
        func tick(_ units: Int = 1) throws {
            guard !cancellation.isCancelled, !Task.isCancelled else { throw AnalysisError.cancelled }
            try control.checkpoint(workUnits: units)
            guard !cancellation.isCancelled, !Task.isCancelled else { throw AnalysisError.cancelled }
        }
        try tick(0)
        let n = lower.count
        guard n > 0, upper.count == n, initial.count == n, field.count == n,
              limits.maximumDimension > 0, n <= limits.maximumDimension,
              limits.maximumResultBytes >= 0, ordered(.zero, duration), duration != .zero else { throw Failure.invalidInput }
        guard finite(duration), lipschitzUpperBound.isFinite else { throw Failure.nonFiniteInput }
        guard lipschitzUpperBound >= 0 else { throw Failure.invalidInput }
        let bytes = try resultByteCount(dimension: n)
        guard bytes <= limits.maximumResultBytes else { throw Failure.resultLimit }
        // Validate every borrowed input and initial inclusion before admitting the result array.
        for row in 0..<n {
            try tick()
            guard ordered(lower[row], upper[row]) else { throw Failure.invalidInput }
            guard finite(lower[row]), finite(upper[row]),
                  initial[row].absoluteUpperBound.isFinite, field[row].absoluteUpperBound.isFinite else {
                throw Failure.nonFiniteInput
            }
            try tick(4)
            guard try contained(initial[row], lower: lower[row], upper: upper[row]) else {
                throw Failure.selfMapUncertified
            }
        }
        try tick(2)
        let h = try CompensatedEnclosure(center: duration)
        let factor = try h.multiplied(by: .init(center: .init(high: lipschitzUpperBound))).absoluteUpperBound
        guard factor.isFinite else { throw NumericalStateError.arithmeticOverflow }
        guard factor < 1 else { throw Failure.contractionUncertified }
        let lease = try control.reserveStorage(byteCount: bytes)
        try tick(n)
        let zero = try CompensatedEnclosure(center: .zero)
        var endpoints = [CompensatedEnclosure](repeating: zero, count: n)
        for row in 0..<n {
            try tick()
            let displacement = try h.multiplied(by: field[row])
            try tick()
            let end = try initial[row].adding(displacement)
            try tick(4)
            // Convex Q and initial inclusion cover every intermediate tau, not just h.
            guard try contained(end, lower: lower[row], upper: upper[row]) else {
                throw Failure.selfMapUncertified
            }
            endpoints[row] = end
        }
        try tick(0)
        return Result(endpoints: endpoints, duration: duration, contractionUpperBound: factor, lease: lease)
    }

    /// Logical initialized result fields and payload, excluding allocator headers and RSS.
    static func resultByteCount(dimension: Int) throws -> Int {
        guard dimension > 0 else { throw Failure.invalidInput }
        let cells = try TransientExecutionBudget.multiply(dimension, MemoryLayout<CompensatedEnclosure>.stride,
            "Picard endpoint payload")
        let fields = MemoryLayout<Int>.stride + MemoryLayout<CompensatedValue>.stride
            + MemoryLayout<Double>.stride + MemoryLayout<[CompensatedEnclosure]>.stride + MemoryLayout<any Sendable>.stride
        return try TransientExecutionBudget.add(cells, fields, "Picard result fields")
    }
    private static func ordered(_ a: CompensatedValue, _ b: CompensatedValue) -> Bool {
        a.high < b.high || (a.high == b.high && a.low <= b.low)
    }
    private static func finite(_ value: CompensatedValue) -> Bool {
        value.bounds.lower.isFinite && value.bounds.upper.isFinite
    }
    private static func contained(_ value: CompensatedEnclosure,
        lower: CompensatedValue, upper: CompensatedValue) throws -> Bool {
        let fromLower = try value.subtracting(.init(center: lower))
        let toUpper = try CompensatedEnclosure(center: upper).subtracting(value)
        return try lowerBound(fromLower) >= 0 && lowerBound(toUpper) >= 0
    }
    private static func lowerBound(_ value: CompensatedEnclosure) throws -> Double {
        let b = value.center.bounds
        let lo = value.radius == 0 ? b.lower : (b.lower - value.radius).nextDown
        let hi = value.radius == 0 ? b.upper : (b.upper + value.radius).nextUp
        guard lo.isFinite, hi.isFinite else { throw NumericalStateError.arithmeticOverflow }
        return lo
    }
}
