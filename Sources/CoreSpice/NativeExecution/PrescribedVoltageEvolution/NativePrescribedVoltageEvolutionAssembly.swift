import CoreSpiceAnalysis
import CoreSpiceDevices
import CoreSpiceEvent
import CoreSpiceOSDI

internal enum NativePrescribedVoltageEvolutionAssembly {
    typealias A = NativePrescribedVoltageArithmetic
    typealias E = CompensatedEnclosure
    static func reconstruct(record: NativeCircuitPreparationRecord, chart: NativePrescribedVoltageChart,
        limits: NativePrescribedVoltageEvolutionLimits, cancellation: CancellationToken) throws -> NativePrescribedVoltageEvolution.Payload {
        let matched = try chart.evolutionPayload(record: record), control = matched.control
        let source = try matched.values.reconstructionPayload(record: record), cache = matched.spatial
        let n = matched.values.dimension, k = chart.dimension, m = source.sources.count, l = matched.dynamic.count
        func tick(_ units: Int = 1) throws {
            guard !cancellation.isCancelled, !Task.isCancelled else { throw NativeConstitutiveInspection.Failure.cancelled }
            try control.checkpoint(workUnits: units)
        }
        try tick(0)
        guard limits.maximumRetainedBytes > 0, limits.maximumWorkspaceBytes > 0 else {
            throw NativePrescribedVoltageEvolutionFailure.invalidInput
        }
        guard matched.checkedCoordinates.count == k, cache.staticResidual.count == n,
              cache.inputChargeLeft.count == n, cache.inputChargeRight.count == n,
              cache.inputStaticLeft.count == n, cache.inputStaticRight.count == n,
              cache.leftSlopes.count == m, cache.rightSlopes.count == m,
              cache.sourceCharges.count == matched.smooth.count,
              cache.sourceCharges.count == record.osdiPreparationRecords.count else {
            throw NativePrescribedVoltageEvolutionFailure.invalidBinding
        }
        let ownCells = try A.add(l, A.add(A.multiply(k, 2), A.multiply(n, 2)))
        let ownBytes = try A.add(MemoryLayout<NativePrescribedVoltageEvolution.Payload>.stride,
            A.add(A.multiply(ownCells, MemoryLayout<E>.stride), A.multiply(m, MemoryLayout<Int>.stride)))
        let applicationCells = try A.multiply(A.add(A.multiply(n, 2), k), 2)
        let applicationBytes = try A.multiply(applicationCells, MemoryLayout<E>.stride)
        guard try A.add(ownBytes, applicationBytes) <= limits.maximumRetainedBytes else {
            throw NativePrescribedVoltageEvolutionFailure.capacityExceeded
        }
        // Two RHS arrays, exact-zero inputs, three reduced maps, and reusable lower 3n/n buffers.
        let scratchCells = try A.add(A.multiply(k, 2), A.add(m, n))
        let scratchBytes = try A.add(A.multiply(scratchCells, MemoryLayout<E>.stride),
            A.add(A.multiply(A.add(A.multiply(k, 3), n), MemoryLayout<Int>.stride),
                A.add(A.multiply(4, MemoryLayout<[E]>.stride), A.multiply(4, MemoryLayout<[Int]>.stride))))
        let lowerWorkspace = try A.multiply(A.multiply(n, 4), MemoryLayout<E>.stride)
        guard try A.add(scratchBytes, lowerWorkspace) <= limits.maximumWorkspaceBytes else {
            throw NativePrescribedVoltageEvolutionFailure.capacityExceeded
        }
        let lease = try control.reserveNativeStorage(kind: .liveOwnedBytes, byteCount: UInt64(ownBytes))
        let scratchLease = try control.reserveStorage(byteCount: scratchBytes)
        defer { withExtendedLifetime(scratchLease) {} }
        let chargeStateLipschitzUpperBound = try NativePrescribedVoltageEvolutionInverse.chargeStateLipschitzUpperBound(
            record: record, chart: chart, cancellation: cancellation)
        try tick(A.add(ownCells, A.add(scratchCells, A.add(A.multiply(k, 3), A.add(n, m)))))
        let zero = try E(center: .zero)
        var qDot = [E](repeating: zero, count: l)
        var leftRates = [E](repeating: zero, count: k), rightRates = leftRates
        var leftCharge = [E](repeating: zero, count: n), rightCharge = leftCharge
        var leftRHS = [E](repeating: zero, count: k), rightRHS = leftRHS
        let zeroSources = [E](repeating: zero, count: m), zeroQt = [E](repeating: zero, count: n)
        var dynamic = [Int](repeating: -1, count: k), algebraic = dynamic, equation = dynamic
        var reduced = [Int](repeating: -1, count: n)
        var branches = [Int](repeating: 0, count: m)
        for index in matched.dynamic.indices { try tick(); dynamic[matched.dynamic[index]] = index; equation[matched.dynamic[index]] = index }
        for index in matched.algebraic.indices {
            try tick(); algebraic[matched.algebraic[index]] = index; equation[matched.algebraic[index]] = l + index
        }
        for row in 0..<n { try tick(); reduced[row] = try source.plan.reducedCoordinate(at: row) ?? -1 }
        for index in 0..<m {
            try tick(); let row = try source.plan.source(at: index).branchRow
            branches[index] = row; reduced[row] = -2
        }
        for row in 0..<n {
            try tick()
            let r = reduced[row]
            if r < 0 { continue }
            if dynamic[r] >= 0 {
                let index = dynamic[r]
                qDot[index] = try qDot[index].subtracting(cache.staticResidual[row])
                leftRHS[index] = try leftRHS[index].subtracting(cache.staticResidual[row]).subtracting(cache.inputChargeLeft[row])
                rightRHS[index] = try rightRHS[index].subtracting(cache.staticResidual[row]).subtracting(cache.inputChargeRight[row])
            } else {
                let index = equation[r]
                leftRHS[index] = try leftRHS[index].subtracting(cache.inputStaticLeft[row])
                rightRHS[index] = try rightRHS[index].subtracting(cache.inputStaticRight[row])
            }
        }
        do {
            var output = leftRates.mutableSpan
            try NativePrescribedVoltageEvolutionInverse.enclose(record: record, chart: chart,
                rightHandSide: leftRHS.span, into: &output, cancellation: cancellation)
        }
        do {
            var output = rightRates.mutableSpan
            try NativePrescribedVoltageEvolutionInverse.enclose(record: record, chart: chart,
                rightHandSide: rightRHS.span, into: &output, cancellation: cancellation)
        }
        let workspace = try source.reduction.makeWorkspace(plan: source.plan)
        func accumulate(rates: [E], into charge: inout [E]) throws {
            let lift = try source.reduction.lift(workspace: workspace, reducedCoordinates: rates, sourceValues: zeroSources)
            for term in source.terms where term.plane == .charge {
                try tick(2)
                let coefficient = try E(center: .init(high: Double(bitPattern: term.coefficientBits)))
                charge[term.row] = try charge[term.row].adding(coefficient.multiplied(by: lift.coordinate(at: term.column)))
            }
            for index in cache.sourceCharges.indices {
                try tick()
                let raw = cache.sourceCharges[index], coefficients = raw.coefficients
                guard coefficients.count == (try A.multiply(raw.rawCount, raw.rawCount)) else {
                    throw NativePrescribedVoltageEvolutionFailure.invalidBinding
                }
                try matched.smooth[index].withInventory { inventory in
                    guard inventory.rawGlobal.count == raw.rawCount else { throw NativePrescribedVoltageEvolutionFailure.invalidBinding }
                    for row in 0..<raw.rawCount {
                        for column in 0..<raw.rawCount {
                            try tick()
                            let coefficient = coefficients[row * raw.rawCount + column]
                            guard let globalRow = inventory.rawGlobal[row], let globalColumn = inventory.rawGlobal[column] else { continue }
                            guard (0..<n).contains(globalRow), (0..<n).contains(globalColumn) else { throw NativePrescribedVoltageEvolutionFailure.invalidBinding }
                            if reduced[globalColumn] == -2 { continue } // Structural READ exclusion, not a fabricated current rate.
                            try tick(2)
                            charge[globalRow] = try charge[globalRow].adding(coefficient.multiplied(by: lift.coordinate(at: globalColumn)))
                        }
                    }
                }
            }
        }
        try accumulate(rates: leftRates, into: &leftCharge)
        let left = try source.reduction.apply(workspace: workspace, reducedCoordinates: matched.checkedCoordinates,
            sourceValues: source.voltages, staticResidual: cache.staticResidual, stateChargeRate: leftCharge,
            prescribedChargeRate: cache.inputChargeLeft, explicitTimeChargeRate: zeroQt)
        try accumulate(rates: rightRates, into: &rightCharge)
        let right = try source.reduction.apply(workspace: workspace, reducedCoordinates: matched.checkedCoordinates,
            sourceValues: source.voltages, staticResidual: cache.staticResidual, stateChargeRate: rightCharge,
            prescribedChargeRate: cache.inputChargeRight, explicitTimeChargeRate: zeroQt)
        for row in 0..<n {
            try tick(2)
            leftCharge[row] = try leftCharge[row].adding(cache.inputChargeLeft[row])
            rightCharge[row] = try rightCharge[row].adding(cache.inputChargeRight[row])
        }
        func check(_ result: PrescribedVoltageReduction.Application, side: NativePrescribedVoltageReconstruction.Side) throws {
            for row in 0..<n {
                try tick()
                let bounds = try A.bounds(result.coordinate(at: row))
                guard A.ordered(source.originalDomain.lower[row], bounds.0), A.ordered(bounds.1, source.originalDomain.upper[row]) else {
                    throw NativePrescribedVoltageReconstructionFailure.outsideOriginalDomain(row: row, side: side)
                }
            }
        }
        try check(left, side: .left); try check(right, side: .right)
        try tick(0)
        return .init(chart: chart, chargeStateLipschitzUpperBound: chargeStateLipschitzUpperBound,
            chargeRates: qDot, leftRates: leftRates, rightRates: rightRates,
            leftCharge: leftCharge, rightCharge: rightCharge, branches: branches, left: left, right: right, lease: lease)
    }
}
