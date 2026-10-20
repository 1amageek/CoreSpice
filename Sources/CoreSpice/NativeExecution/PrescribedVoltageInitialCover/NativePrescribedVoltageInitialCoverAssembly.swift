import CoreSpiceDevices
import CoreSpiceEvent

internal enum NativePrescribedVoltageInitialCoverAssembly {
    typealias A = NativePrescribedVoltageArithmetic
    typealias E = CompensatedEnclosure
    typealias V = CompensatedValue
    typealias Failure = NativePrescribedVoltageInitialCoverFailure
    private struct Frame {
        let right: Int
        let depth: Int
        let axis: Int
        let lower: V
        let upper: V
        let split: V
        var rightVisited: Bool
    }
    static func check(record: NativeCircuitPreparationRecord, structure: NativePrescribedVoltageInitialStructure,
        lower: [V], upper: [V], initialNormalized: [ClosedRange<Double>],
        proposal: NativePrescribedVoltageInitialCoverProposal, limits: NativePrescribedVoltageInitialCoverLimits,
        cancellation: CancellationToken) throws -> NativePrescribedVoltageInitialCover.Payload {
        guard let control = record.constitutiveBacking?.control,
              let original = structure.preparation.constitutiveBacking?.control,
              control === original else { throw Failure.wrongOwner }
        func tick(_ units: Int = 1) throws {
            guard !cancellation.isCancelled, !Task.isCancelled else { throw Failure.cancelled }
            try control.checkpoint(workUnits: units)
            guard !cancellation.isCancelled, !Task.isCancelled else { throw Failure.cancelled }
        }
        try tick(0)
        let base = try structure.values.reconstructionPayload(record: record)
        let k = base.plan.reducedCount, m = base.sources.count, n = base.lower.count
        let axes = try A.add(k, m), count = proposal.nodes.count
        guard k > 0, lower.count == k, upper.count == k, initialNormalized.count == m,
              structure.dynamic.count + structure.algebraic.count == k,
              limits.maximumAxes > 0, limits.maximumNodes > 0, limits.maximumDepth >= 0,
              limits.maximumRetainedBytes >= 0, limits.maximumWorkspaceBytes >= 0,
              axes <= limits.maximumAxes, count > 0, count <= limits.maximumNodes else { throw Failure.invalidInput }
        for row in 0..<k {
            try tick()
            guard finite(lower[row]), finite(upper[row]), A.ordered(lower[row], upper[row]) else { throw Failure.invalidInput }
        }
        for index in 0..<m {
            try tick()
            guard initialNormalized[index] == base.sources[index].normalized else { throw Failure.invalidBinding }
        }
        let depthCapacity = min(count, limits.maximumDepth)
        var workspaceBytes = try A.multiply(A.multiply(axes, 2), MemoryLayout<V>.stride)
        workspaceBytes = try A.add(workspaceBytes, A.multiply(count, MemoryLayout<Bool>.stride))
        workspaceBytes = try A.add(workspaceBytes, A.multiply(depthCapacity, MemoryLayout<Frame>.stride))
        workspaceBytes = try A.add(workspaceBytes, A.add(A.multiply(2, MemoryLayout<[V]>.stride), A.add(MemoryLayout<[Bool]>.stride, MemoryLayout<[Frame]>.stride)))
        var retainedBytes = try A.add(MemoryLayout<NativePrescribedVoltageInitialCover.Payload>.stride, A.multiply(2, MemoryLayout<Int>.stride))
        retainedBytes = try A.add(retainedBytes, A.multiply(A.multiply(k, 2), MemoryLayout<V>.stride))
        retainedBytes = try A.add(retainedBytes, A.multiply(m, MemoryLayout<ClosedRange<Double>>.stride))
        retainedBytes = try A.add(retainedBytes, A.multiply(count, MemoryLayout<NativePrescribedVoltageInitialCoverProposal.Node>.stride))
        retainedBytes = try A.add(retainedBytes, A.multiply(count, MemoryLayout<NativePrescribedVoltageInitialCover.Leaf>.stride))
        guard workspaceBytes <= limits.maximumWorkspaceBytes, retainedBytes <= limits.maximumRetainedBytes else {
            throw Failure.capacityExceeded
        }
        let workspace = try control.reserveStorage(byteCount: workspaceBytes)
        defer { withExtendedLifetime(workspace) {} }
        try tick(0)
        let lease = try control.reserveNativeStorage(kind: .liveOwnedBytes, byteCount: UInt64(retainedBytes))
        try tick(0)
        try tick(count)
        var seen = [Bool](repeating: false, count: count)
        var lo: [V] = [], hi: [V] = []
        lo.reserveCapacity(axes); hi.reserveCapacity(axes)
        for row in 0..<k { try tick(2); lo.append(lower[row]); hi.append(upper[row]) }
        for range in initialNormalized {
            try tick(2); lo.append(try V(high: range.lowerBound)); hi.append(try V(high: range.upperBound))
        }
        var stack: [Frame] = []; stack.reserveCapacity(depthCapacity)
        var leaves: [NativePrescribedVoltageInitialCover.Leaf] = []; leaves.reserveCapacity(count)
        var included = 0, excluded = 0, unresolved = 0

        func checkScope(_ value: NativePrescribedVoltageValues.Payload) throws {
            try tick()
            guard value.plan.reducedCount == k, value.sources.count == m,
                  value.originalDomain.lower.count == n, value.originalDomain.upper.count == n,
                  value.originalDomain.lowerContext == base.originalDomain.lowerContext,
                  value.originalDomain.upperContext == base.originalDomain.upperContext,
                  value.captures.count == base.captures.count else { throw Failure.invalidBinding }
            for row in 0..<n {
                try tick()
                guard A.ordered(base.originalDomain.lower[row], value.originalDomain.lower[row]),
                      A.ordered(value.originalDomain.upper[row], base.originalDomain.upper[row]),
                      try value.plan.reducedCoordinate(at: row) == base.plan.reducedCoordinate(at: row) else {
                    throw Failure.invalidBinding
                }
            }
            for index in 0..<m {
                try tick()
                let a = base.sources[index], b = value.sources[index]
                guard a.deviceIndex == b.deviceIndex, a.zeroVoltage.bitPattern == b.zeroVoltage.bitPattern,
                      a.oneVoltage.bitPattern == b.oneVoltage.bitPattern, a.timeOrigin.bitPattern == b.timeOrigin.bitPattern,
                      a.timeScale.bitPattern == b.timeScale.bitPattern, a.leftSlope == b.leftSlope, a.rightSlope == b.rightSlope,
                      A.ordered(try V(high: b.normalized.lowerBound), lo[k + index]),
                      A.ordered(hi[k + index], try V(high: b.normalized.upperBound)) else { throw Failure.invalidBinding }
            }
            for index in base.captures.indices {
                try tick()
                let a = base.captures[index], b = value.captures[index]
                guard a.source == b.source, a.workerReference == b.workerReference,
                      a.numericProfile == b.numericProfile, a.options == b.options,
                      a.coverLimits == b.coverLimits, a.identityLimits == b.identityLimits else { throw Failure.invalidBinding }
            }
        }
        func includedBy(_ interval: E, lower: V, upper: V) throws -> Bool {
            try tick(2)
            if lower == interval.center && upper == interval.center { return true }
            let center = try E(center: interval.center)
            return try E(center: lower).subtracting(center).absoluteUpperBound <= interval.radius
                && E(center: upper).subtracting(center).absoluteUpperBound <= interval.radius
        }
        var current = 0, depth = 0
        while true {
            try tick()
            guard proposal.nodes.indices.contains(current), !seen[current] else { throw Failure.invalidInput }
            seen[current] = true
            switch proposal.nodes[current] {
            case .split(let axis, let at, let left, let right):
                guard axis >= 0, axis < axes, finite(at), lo[axis] != at, hi[axis] != at,
                      A.ordered(lo[axis], at), A.ordered(at, hi[axis]), left != right,
                      proposal.nodes.indices.contains(left), proposal.nodes.indices.contains(right),
                      axis < k || at.low == 0 else { throw Failure.invalidInput }
                let nextDepth = try A.add(depth, 1)
                guard nextDepth <= limits.maximumDepth, stack.count < depthCapacity else { throw Failure.capacityExceeded }
                try tick()
                stack.append(Frame(right: right, depth: nextDepth, axis: axis, lower: lo[axis], upper: hi[axis],
                    split: at, rightVisited: false))
                hi[axis] = at; current = left; depth = nextDepth
                continue
            case .excluded(let values, let component):
                guard component >= structure.dynamic.count, component < k else { throw Failure.insufficientWitness }
                let value = try values.reconstructionPayload(record: record)
                try checkScope(value)
                guard value.reducedCoordinates.count == k else { throw Failure.invalidBinding }
                for row in 0..<k {
                    guard try includedBy(value.reducedCoordinates[row], lower: lo[row], upper: hi[row]) else {
                        throw Failure.insufficientWitness
                    }
                }
                let selected = structure.algebraic[component - structure.dynamic.count]
                var residual = try E(center: .zero)
                for row in 0..<n {
                    try tick()
                    if try value.plan.reducedCoordinate(at: row) == selected { residual = try residual.adding(value.f[row]) }
                }
                let bounds = try A.bounds(residual)
                guard (bounds.0 != .zero && A.ordered(.zero, bounds.0))
                    || (bounds.1 != .zero && A.ordered(bounds.1, .zero)) else { throw Failure.insufficientWitness }
                try tick(); leaves.append(.init(nodeIndex: current, classification: .excluded,
                    excludedComponent: component, residual: residual)); excluded += 1
            case .included(let root):
                let proof = try root.initialPayload(record: record)
                guard proof.algebraic == structure.algebraic, proof.dynamic == structure.dynamic,
                      proof.checkedLower.count == k, proof.checkedUpper.count == k,
                      proof.dynamicInitialCoordinates.count == structure.dynamic.count else { throw Failure.invalidBinding }
                try checkScope(proof.values.reconstructionPayload(record: record))
                for row in 0..<k {
                    try tick()
                    guard A.ordered(proof.checkedLower[row], lo[row]), A.ordered(hi[row], proof.checkedUpper[row]) else {
                        throw Failure.insufficientWitness
                    }
                }
                for slot in structure.dynamic.indices {
                    let row = structure.dynamic[slot]
                    guard try includedBy(proof.dynamicInitialCoordinates[slot], lower: lo[row], upper: hi[row]) else {
                        throw Failure.insufficientWitness
                    }
                }
                try tick(); leaves.append(.init(nodeIndex: current, classification: .included,
                    excludedComponent: nil, residual: nil)); included += 1
            case .unresolved:
                try tick(); leaves.append(.init(nodeIndex: current, classification: .unresolved,
                    excludedComponent: nil, residual: nil)); unresolved += 1
            }
            var next: Int?
            while !stack.isEmpty {
                try tick()
                let index = stack.count - 1, frame = stack[index]
                if !frame.rightVisited {
                    stack[index].rightVisited = true
                    lo[frame.axis] = frame.split; hi[frame.axis] = frame.upper
                    next = frame.right; depth = frame.depth; break
                }
                lo[frame.axis] = frame.lower; hi[frame.axis] = frame.upper
                stack.removeLast()
            }
            guard let next else { break }
            current = next
        }
        for entry in seen { try tick(); guard entry else { throw Failure.invalidInput } }
        try tick(5)
        return .init(structure: structure, lower: lower, upper: upper, initialNormalized: initialNormalized,
            nodes: proposal.nodes, leaves: leaves, included: included, excluded: excluded, unresolved: unresolved, lease: lease)
    }
    private static func finite(_ value: V) -> Bool {
        value.bounds.lower.isFinite && value.bounds.upper.isFinite
    }
}
