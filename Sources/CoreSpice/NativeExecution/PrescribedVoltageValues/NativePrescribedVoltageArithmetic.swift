import CoreSpiceAnalysis
import CoreSpiceCompile
import CoreSpiceDevices

internal enum NativePrescribedVoltageArithmetic {
    static func add(_ a: Int, _ b: Int) throws -> Int {
        let (value, overflow) = a.addingReportingOverflow(b)
        guard !overflow, a >= 0, b >= 0 else { throw NativePrescribedVoltageFailure.capacityExceeded }
        return value
    }
    static func multiply(_ a: Int, _ b: Int) throws -> Int {
        let (value, overflow) = a.multipliedReportingOverflow(by: b)
        guard !overflow, a >= 0, b >= 0 else { throw NativePrescribedVoltageFailure.capacityExceeded }
        return value
    }
    static func ordered(_ a: CompensatedValue, _ b: CompensatedValue) -> Bool {
        a.high < b.high || (a.high == b.high && a.low <= b.low)
    }
    static func bounds(_ value: CompensatedEnclosure) throws -> (CompensatedValue, CompensatedValue) {
        if value.radius == 0 { return (value.center, value.center) }
        let lo = (value.center.bounds.lower - value.radius).nextDown
        let hi = (value.center.bounds.upper + value.radius).nextUp
        guard lo.isFinite, hi.isFinite else { throw NumericalStateError.arithmeticOverflow }
        return try (.init(high: lo), .init(high: hi))
    }
    static func hull(_ lo: Double, _ hi: Double) throws -> CompensatedEnclosure {
        guard lo.isFinite, hi.isFinite, lo <= hi else { throw NativePrescribedVoltageFailure.invalidBinding }
        let lower = try CompensatedEnclosure(center: .init(high: lo))
        if lo == hi { return lower }
        let upper = try CompensatedEnclosure(center: .init(high: hi))
        let two = try CompensatedEnclosure(center: .init(high: 2))
        let midpoint = try lower.divided(by: two).adding(upper.divided(by: two))
        let center = try CompensatedEnclosure(center: midpoint.center)
        let radius = max(try lower.subtracting(center).absoluteUpperBound,
            try upper.subtracting(center).absoluteUpperBound)
        return try CompensatedEnclosure(center: center.center, radius: radius)
    }
    struct Retained {
        let control: any LinearSolverExecutionControlling
        let limit: Int
        var used = 0
        mutating func take(_ bytes: Int) throws {
            let next = try add(used, bytes)
            guard next <= limit else { throw NativePrescribedVoltageFailure.capacityExceeded }
            used = next
        }
        mutating func array<T>(_ type: T.Type, _ count: Int) throws {
            try take(multiply(count, MemoryLayout<T>.stride))
            try control.checkpoint(workUnits: count)
        }
    }
}
