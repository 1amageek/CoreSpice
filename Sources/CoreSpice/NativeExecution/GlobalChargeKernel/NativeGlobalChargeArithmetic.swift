import CoreSpiceAnalysis
import CoreSpiceCompile
import CoreSpiceDevices

/// Checked host capacities and exact imports; no source or rank authority.
internal enum NativeGlobalChargeArithmetic {
    typealias Scalar = ExactRowAlgebra.Scalar
    static func add(_ a: Int, _ b: Int) throws -> Int {
        let (v, overflow) = a.addingReportingOverflow(b)
        guard !overflow, v >= 0 else { throw NativeGlobalChargeFailure.capacityExceeded }
        return v
    }
    static func multiply(_ a: Int, _ b: Int) throws -> Int {
        let (v, overflow) = a.multipliedReportingOverflow(by: b)
        guard !overflow, a >= 0, b >= 0, v >= 0 else { throw NativeGlobalChargeFailure.capacityExceeded }
        return v
    }
    static func ordered(_ a: CompensatedValue, _ b: CompensatedValue) -> Bool {
        a.high < b.high || (a.high == b.high && a.low <= b.low)
    }
    static func hull(lower: Double, upper: Double) throws -> CompensatedEnclosure {
        guard lower.isFinite, upper.isFinite, lower <= upper else { throw NativeGlobalChargeFailure.invalidBinding }
        let width = upper - lower
        guard width.isFinite, width == 0 || width.nextUp.isFinite else { throw NumericalStateError.arithmeticOverflow }
        return try .init(center: .init(high: lower), radius: width == 0 ? 0 : width.nextUp)
    }

    /// One explicitly preadmitted retained arena allowance; every payload is counted before construction.
    struct Retained {
        let control: any LinearSolverExecutionControlling
        let lease: any Sendable
        let limit: Int
        var used = 0
        mutating func take(_ bytes: Int) throws {
            let next = try add(used, bytes)
            guard next <= limit else { throw NativeGlobalChargeFailure.capacityExceeded }
            used = next
        }
        mutating func array<T>(_ type: T.Type, count: Int) throws {
            try take(multiply(count, MemoryLayout<T>.stride))
            try control.checkpoint(workUnits: count)
        }
        mutating func scalar(_ value: Scalar, maximumBits: Int) throws -> Scalar {
            guard value.words.count <= maximumBits / 64 + (maximumBits % 64 == 0 ? 0 : 1),
                  value.denominatorPower <= UInt64(maximumBits) else { throw ExactRowAlgebra.Failure.bitLimit }
            try array(UInt64.self, count: value.words.count)
            var words = [UInt64](repeating: 0, count: value.words.count)
            for i in words.indices { try control.checkpoint(workUnits: 1); words[i] = value.words[i] }
            return .init(negative: value.negative, words: words, denominatorPower: value.denominatorPower, lease: lease)
        }
        mutating func scalar(negative: Bool, denominatorPower: UInt64, words source: Span<UInt64>,
            maximumBits: Int) throws -> Scalar {
            guard source.count <= maximumBits / 64 + (maximumBits % 64 == 0 ? 0 : 1),
                  denominatorPower <= UInt64(maximumBits) else { throw ExactRowAlgebra.Failure.bitLimit }
            try array(UInt64.self, count: source.count)
            var words = [UInt64](repeating: 0, count: source.count)
            for i in words.indices { try control.checkpoint(workUnits: 1); words[i] = source[i] }
            return .init(negative: negative, words: words, denominatorPower: denominatorPower, lease: lease)
        }
        mutating func scalar(bits: UInt64, maximumBits: Int) throws -> Scalar {
            let exponentBits = Int((bits >> 52) & 0x7ff)
            guard exponentBits != 0x7ff else { throw NativeGlobalChargeFailure.invalidBinding }
            var numerator = bits & 0x000f_ffff_ffff_ffff
            if exponentBits != 0 { numerator |= 1 << 52 }
            if numerator == 0 { return .init(negative: false, words: [], lease: lease) }
            var exponent = exponentBits == 0 ? -1074 : exponentBits - 1075
            let trailing = numerator.trailingZeroBitCount
            numerator >>= trailing; exponent += trailing
            let numeratorBits = 64 - numerator.leadingZeroBitCount
            let totalBits = try add(numeratorBits, max(0, exponent))
            guard totalBits <= maximumBits, max(0, -exponent) <= maximumBits else { throw ExactRowAlgebra.Failure.bitLimit }
            let count = (totalBits - 1) / 64 + 1
            try array(UInt64.self, count: count)
            var words = [UInt64](repeating: 0, count: count)
            if exponent < 0 { words[0] = numerator }
            else {
                let index = exponent / 64, shift = exponent % 64
                words[index] = numerator << shift
                if shift != 0, index + 1 < count { words[index + 1] = numerator >> (64 - shift) }
            }
            return .init(negative: bits >> 63 != 0, words: words,
                denominatorPower: UInt64(max(0, -exponent)), lease: lease)
        }
    }
}
