import CoreSpiceDevices
import CoreSpiceEvent

/// Tests one common Newton direction against independently borrowed device limiters.
enum NewtonVoltageLimiting {
    /// Nil restores the previous point; thrown errors invalidate the working buffers.
    static func apply(
        raw: borrowing [Double], previous: borrowing [Double],
        candidate: inout [Double], scratch: inout [Double],
        devices: [any BoundDevice], firstIteration: Bool, damping: Double,
        maxProbes: Int, executionBudget: TransientExecutionBudget?,
        cancellation: CancellationToken, iteration: Int = 0
    ) throws -> Double? {
        let count = raw.count
        guard previous.count == count, candidate.count == count, scratch.count == count,
              damping.isFinite, damping > 0, damping <= 1, maxProbes > 0 else {
            throw AnalysisError.invalidConfiguration("Voltage limiting requires matching buffers, positive probes and damping in (0, 1]")
        }
        if cancellation.isCancelled || Task.isCancelled { throw AnalysisError.cancelled }
        for index in raw.indices {
            guard raw[index].isFinite, previous[index].isFinite else {
                throw AnalysisError.nonFiniteSolution(iteration: iteration, variableIndex: index,
                    value: raw[index].isFinite ? previous[index] : raw[index])
            }
        }
        let vectorWork = try TransientExecutionBudget.multiply(count, 8, "voltage limiting vector work")
        let deviceWork = try TransientExecutionBudget.add(
            TransientExecutionBudget.multiply(count, 3, "voltage limiting copy and comparison"),
            2, "voltage limiting device work")
        var alpha = damping
        for _ in 0..<maxProbes {
            if cancellation.isCancelled || Task.isCancelled { throw AnalysisError.cancelled }
            try executionBudget?.chargeWork(vectorWork)
            var changed = false
            for index in raw.indices {
                candidate[index] = alpha == 1 ? raw[index]
                    : previous[index].addingProduct(alpha, raw[index] - previous[index])
                guard candidate[index].isFinite else {
                    throw AnalysisError.nonFiniteSolution(iteration: iteration,
                        variableIndex: index, value: candidate[index])
                }
                changed = changed || candidate[index] != previous[index]
            }
            var admissible = true
            for device in devices {
                guard let limiter = device as? any VoltageLimitingDevice,
                      !firstIteration || limiter.limitsFirstIteration else { continue }
                if cancellation.isCancelled || Task.isCancelled { throw AnalysisError.cancelled }
                try executionBudget?.chargeWork(deviceWork)
                for index in raw.indices { scratch[index] = candidate[index] }
                limiter.limitVoltages(solution: &scratch, previousSolution: previous)
                if cancellation.isCancelled || Task.isCancelled { throw AnalysisError.cancelled }
                var limited = false
                for index in raw.indices {
                    guard scratch[index].isFinite else {
                        throw AnalysisError.nonFiniteSolution(iteration: iteration,
                            variableIndex: index, value: scratch[index])
                    }
                    limited = limited || scratch[index] != candidate[index]
                }
                if limited { admissible = false; break }
            }
            if admissible { return alpha }
            if !changed { break }
            alpha *= 0.5
            if alpha == 0 { break }
        }
        for index in previous.indices { candidate[index] = previous[index] }
        return nil
    }
}
