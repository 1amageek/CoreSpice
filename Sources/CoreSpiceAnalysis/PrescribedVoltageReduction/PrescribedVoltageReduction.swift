import CoreSpiceCompile
import CoreSpiceDevices
import CoreSpiceEvent

package protocol PrescribedVoltageReducing: Sendable {
    func prepare(axes: [DCEquationKind], sources: [PrescribedVoltageReduction.Source]) throws -> PrescribedVoltageReduction.Plan
    func makeWorkspace(plan: PrescribedVoltageReduction.Plan) throws -> PrescribedVoltageReduction.Workspace
    func lift(workspace: PrescribedVoltageReduction.Workspace, reducedCoordinates: [CompensatedEnclosure],
        sourceValues: [CompensatedEnclosure]) throws -> PrescribedVoltageReduction.Lift
    func apply(workspace: PrescribedVoltageReduction.Workspace, reducedCoordinates: [CompensatedEnclosure],
        sourceValues: [CompensatedEnclosure], staticResidual: [CompensatedEnclosure],
        stateChargeRate: [CompensatedEnclosure], prescribedChargeRate: [CompensatedEnclosure],
        explicitTimeChargeRate: [CompensatedEnclosure]) throws -> PrescribedVoltageReduction.Application
}

/// Conditional incidence algebra, without device, source-jet or physical-root authority.
package struct PrescribedVoltageReduction: PrescribedVoltageReducing {
    package struct Source: Sendable, Equatable {
        package let positiveRow: Int?
        package let negativeRow: Int?
        package let branchRow: Int
        package init(positiveRow: Int?, negativeRow: Int?, branchRow: Int) {
            self.positiveRow = positiveRow; self.negativeRow = negativeRow; self.branchRow = branchRow
        }
    }
    package struct Limits: Sendable {
        package let maximumAxes: Int
        package let maximumSources: Int
        package let maximumWorkspaceBytes: Int
        package let maximumResultBytes: Int
        package init(maximumAxes: Int, maximumSources: Int, maximumWorkspaceBytes: Int, maximumResultBytes: Int) {
            self.maximumAxes = maximumAxes; self.maximumSources = maximumSources
            self.maximumWorkspaceBytes = maximumWorkspaceBytes; self.maximumResultBytes = maximumResultBytes
        }
    }
    package enum Failure: Error, Sendable, Equatable {
        case invalidInput
        case selfLoop(source: Int)
        case dependentSources
        case wrongOwner
        case workspaceLimit
        case resultLimit
    }

    /// Retained immutable tables use original global indices; ground has index axisCount internally.
    package final class Plan: Sendable {
        package let axisCount: Int
        package let sourceCount: Int
        package let reducedCount: Int
        fileprivate let axes: [DCEquationKind]
        fileprivate let sources: [Source]
        fileprivate let parent: [Int]
        fileprivate let parentSource: [Int]
        fileprivate let sign: [Int]
        fileprivate let root: [Int]
        fileprivate let coordinate: [Int]
        fileprivate let order: [Int]
        fileprivate let orderCount: Int
        fileprivate let sourceChild: [Int]
        fileprivate let owner: Owner
        private let lease: any Sendable
        fileprivate init(axes: [DCEquationKind], sources: [Source], parent: [Int], parentSource: [Int],
            sign: [Int], root: [Int], coordinate: [Int], order: [Int], orderCount: Int,
            sourceChild: [Int], reducedCount: Int, owner: Owner, lease: any Sendable) {
            self.axes = axes; self.sources = sources; self.parent = parent; self.parentSource = parentSource
            self.sign = sign; self.root = root; self.coordinate = coordinate; self.order = order
            self.orderCount = orderCount; self.sourceChild = sourceChild; self.reducedCount = reducedCount
            axisCount = axes.count; sourceCount = sources.count; self.owner = owner; self.lease = lease
        }
        package func nature(at row: Int) throws -> DCEquationKind { try check(row); return axes[row] }
        package func source(at index: Int) throws -> Source {
            guard sources.indices.contains(index) else { throw Failure.invalidInput }; return sources[index]
        }
        package func reducedCoordinate(at row: Int) throws -> Int? {
            try check(row); return coordinate[row] < 0 ? nil : coordinate[row]
        }
        package func parentRow(at row: Int) throws -> Int? {
            try check(row); let value = parent[row]; return value == axisCount || value == row || value < 0 ? nil : value
        }
        package func sourceEdge(at row: Int) throws -> Int? {
            try check(row); return parentSource[row] < 0 ? nil : parentSource[row]
        }
        package func sourceSign(at row: Int) throws -> Int { try check(row); return sign[row] }
        package func rootRow(at row: Int) throws -> Int? {
            try check(row); return root[row] == axisCount || root[row] < 0 ? nil : root[row]
        }
        private func check(_ row: Int) throws {
            guard axes.indices.contains(row) else { throw Failure.invalidInput }
        }
    }

    /// Synchronous caller-isolated reusable scratch. It deliberately has no Sendable conformance.
    package final class Workspace {
        fileprivate let plan: Plan
        fileprivate var values: [CompensatedEnclosure]
        fileprivate var residual: [CompensatedEnclosure]
        fileprivate var sums: [CompensatedEnclosure]
        private let lease: any Sendable
        fileprivate init(plan: Plan, zero: CompensatedEnclosure, lease: any Sendable,
            cancellation: CancellationToken?) throws {
            self.plan = plan; self.lease = lease
            try PrescribedVoltageReduction.checkCancellation(cancellation)
            values = .init(repeating: zero, count: plan.axisCount)
            try PrescribedVoltageReduction.checkCancellation(cancellation)
            residual = .init(repeating: zero, count: plan.axisCount)
            try PrescribedVoltageReduction.checkCancellation(cancellation)
            sums = .init(repeating: zero, count: plan.axisCount)
            try PrescribedVoltageReduction.checkCancellation(cancellation)
        }
    }

    /// Affine coordinates before current reconstruction; selected currents are deliberately unavailable.
    package final class Lift: Sendable {
        package let plan: Plan
        private let values: [CompensatedEnclosure]
        private let lease: any Sendable
        fileprivate init(plan: Plan, values: [CompensatedEnclosure], lease: any Sendable) {
            self.plan = plan; self.values = values; self.lease = lease
        }
        package func coordinate(at row: Int) throws -> CompensatedEnclosure {
            guard values.indices.contains(row), plan.parent[row] != -2 else { throw Failure.invalidInput }
            return values[row]
        }
    }

    /// Outward calculations only. None of these arrays certifies an equation or physical root.
    package final class Application: Sendable {
        package let plan: Plan
        private let coordinates: [CompensatedEnclosure]
        private let residual: [CompensatedEnclosure]
        private let reduced: [CompensatedEnclosure]
        private let lease: any Sendable
        fileprivate init(plan: Plan, coordinates: [CompensatedEnclosure], residual: [CompensatedEnclosure],
            reduced: [CompensatedEnclosure], lease: any Sendable) {
            self.plan = plan; self.coordinates = coordinates; self.residual = residual
            self.reduced = reduced; self.lease = lease
        }
        package func coordinate(at row: Int) throws -> CompensatedEnclosure {
            guard coordinates.indices.contains(row) else { throw Failure.invalidInput }; return coordinates[row]
        }
        package func originalResidual(at row: Int) throws -> CompensatedEnclosure {
            guard residual.indices.contains(row) else { throw Failure.invalidInput }; return residual[row]
        }
        package func reducedResidual(at row: Int) throws -> CompensatedEnclosure {
            guard reduced.indices.contains(row) else { throw Failure.invalidInput }; return reduced[row]
        }
    }

    fileprivate final class Owner: Sendable {
        let control: any LinearSolverExecutionControlling
        init(control: any LinearSolverExecutionControlling) {
            self.control = control
        }
    }
    let limits: Limits
    fileprivate let owner: Owner
    package init(limits: Limits, budget: TransientExecutionBudget,
        storage: any AnalysisResultStorageAccounting, cancellation: CancellationToken) throws {
        try self.init(limits: limits, control: AnalysisLinearSolverControl(
            budget: budget, cancellation: cancellation, storage: storage))
    }
    package init(limits: Limits, control: any LinearSolverExecutionControlling) throws {
        guard limits.maximumAxes > 0, limits.maximumSources >= 0,
              limits.maximumWorkspaceBytes > 0, limits.maximumResultBytes > 0 else { throw Failure.invalidInput }
        self.limits = limits; owner = .init(control: control)
        try owner.control.checkpoint(workUnits: 0)
    }

    package func prepare(axes: [DCEquationKind], sources: [Source]) throws -> Plan {
        let n = axes.count, m = sources.count
        guard n > 0, n <= limits.maximumAxes, m <= limits.maximumSources else { throw Failure.invalidInput }
        try owner.control.checkpoint(workUnits: 0)
        let capacity = try Self.capacity(axisCount: n, sourceCount: m)
        let v = capacity.vertices, twice = capacity.arcs
        let resultInts = capacity.resultIntegers, temporaryInts = capacity.temporaryIntegers
        let resultBytes = capacity.resultBytes, temporaryBytes = capacity.temporaryBytes
        guard temporaryBytes <= limits.maximumWorkspaceBytes else { throw Failure.workspaceLimit }
        guard resultBytes <= limits.maximumResultBytes else { throw Failure.resultLimit }
        let scratchLease = try owner.control.reserveStorage(byteCount: temporaryBytes)
        defer { withExtendedLifetime(scratchLease) {} }
        let resultLease = try owner.control.reserveStorage(byteCount: resultBytes)
        try owner.control.checkpoint(workUnits: add(add(resultInts, temporaryInts), add(n, m)))
        var parent = [Int](repeating: -1, count: v)
        var parentSource = [Int](repeating: -1, count: v)
        var signs = [Int](repeating: 0, count: v)
        var roots = [Int](repeating: -1, count: v)
        var coordinate = [Int](repeating: -1, count: n)
        var order = [Int](repeating: -1, count: v)
        var sourceChild = [Int](repeating: -1, count: m)
        var head = [Int](repeating: -1, count: v)
        var next = [Int](repeating: -1, count: twice)
        var destination = [Int](repeating: -1, count: twice)
        var edge = [Int](repeating: -1, count: twice)
        var direction = [Int](repeating: 0, count: twice)
        var work = Work(control: owner.control)
        for index in sources.indices {
            try work.tick(1)
            let source = sources[index]
            guard axes.indices.contains(source.branchRow), axes[source.branchRow] == .electricalFlow,
                  parent[source.branchRow] != -2 else { throw Failure.invalidInput }
            parent[source.branchRow] = -2
            if let endpoint = source.positiveRow {
                guard axes.indices.contains(endpoint), axes[endpoint] == .electricalPotential else { throw Failure.invalidInput }
            }
            if let endpoint = source.negativeRow {
                guard axes.indices.contains(endpoint), axes[endpoint] == .electricalPotential else { throw Failure.invalidInput }
            }
            guard source.positiveRow != source.negativeRow else { throw Failure.selfLoop(source: index) }
            let positive = source.positiveRow ?? n, negative = source.negativeRow ?? n
            let a = index * 2, b = a + 1
            destination[a] = negative; edge[a] = index; direction[a] = -1; next[a] = head[positive]; head[positive] = a
            destination[b] = positive; edge[b] = index; direction[b] = 1; next[b] = head[negative]; head[negative] = b
        }
        var count = 0, reducedCount = 0
        // Ground is visited first; subsequent roots use the smallest original global index.
        for candidate in 0..<v {
            try work.tick(1)
            let start = candidate == 0 ? n : candidate - 1
            if parent[start] != -1 { continue }
            let coordinateIndex = start == n ? -1 : reducedCount
            if start != n { reducedCount += 1 }
            parent[start] = start; roots[start] = start
            order[count] = start; count += 1
            var cursor = count - 1
            while cursor < count {
                try work.tick(1)
                let row = order[cursor]; cursor += 1
                if row < n { coordinate[row] = coordinateIndex }
                var arc = head[row]
                while arc >= 0 {
                    try work.tick(1)
                    let target = destination[arc], sourceIndex = edge[arc]
                    if sourceIndex != parentSource[row] {
                        guard parent[target] == -1 else { throw Failure.dependentSources }
                        parent[target] = row; parentSource[target] = sourceIndex; signs[target] = direction[arc]
                        roots[target] = start; sourceChild[sourceIndex] = target
                        order[count] = target; count += 1
                    }
                    arc = next[arc]
                }
            }
        }
        // Independent local checks establish each sparse identity without a numerical rank test.
        let expectedCount = try add(n - m, 1)
        guard count == expectedCount, reducedCount == n - twice else { throw Failure.invalidInput }
        for index in sources.indices {
            try work.tick(1)
            let child = sourceChild[index], source = sources[index]
            guard child >= 0, child < n, parentSource[child] == index else { throw Failure.invalidInput }
            let positive = source.positiveRow ?? n, negative = source.negativeRow ?? n
            guard roots[positive] == roots[negative],
                  (child == positive && parent[child] == negative && signs[child] == 1)
                    || (child == negative && parent[child] == positive && signs[child] == -1) else { throw Failure.invalidInput }
        }
        try owner.control.checkpoint(workUnits: 0)
        return Plan(axes: axes, sources: sources, parent: parent, parentSource: parentSource,
            sign: signs, root: roots, coordinate: coordinate, order: order, orderCount: count,
            sourceChild: sourceChild, reducedCount: reducedCount, owner: owner, lease: resultLease)
    }

    package func makeWorkspace(plan: Plan) throws -> Workspace {
        try makeWorkspace(plan: plan, additionalCancellation: nil)
    }

    package func makeWorkspace(plan: Plan, cancellation: CancellationToken) throws -> Workspace {
        try makeWorkspace(plan: plan, additionalCancellation: cancellation)
    }

    private func makeWorkspace(plan: Plan, additionalCancellation: CancellationToken?) throws -> Workspace {
        try Self.checkCancellation(additionalCancellation)
        guard plan.owner === owner else { throw Failure.wrongOwner }
        let cells = try multiply(plan.axisCount, 3)
        let bytes = try multiply(cells, MemoryLayout<CompensatedEnclosure>.stride)
        guard bytes <= limits.maximumWorkspaceBytes else { throw Failure.workspaceLimit }
        try Self.checkCancellation(additionalCancellation)
        let lease = try owner.control.reserveStorage(byteCount: bytes)
        try Self.checkCancellation(additionalCancellation)
        try owner.control.checkpoint(workUnits: cells)
        try Self.checkCancellation(additionalCancellation)
        let zero = try CompensatedEnclosure(center: .zero)
        let workspace = try Workspace(plan: plan, zero: zero, lease: lease, cancellation: additionalCancellation)
        try Self.checkCancellation(additionalCancellation)
        return workspace
    }

    package func lift(workspace: Workspace, reducedCoordinates: [CompensatedEnclosure],
        sourceValues: [CompensatedEnclosure]) throws -> Lift {
        try lift(workspace: workspace, reducedCoordinates: reducedCoordinates,
            sourceValues: sourceValues, additionalCancellation: nil)
    }

    package func lift(workspace: Workspace, reducedCoordinates: [CompensatedEnclosure],
        sourceValues: [CompensatedEnclosure], cancellation: CancellationToken) throws -> Lift {
        try lift(workspace: workspace, reducedCoordinates: reducedCoordinates,
            sourceValues: sourceValues, additionalCancellation: cancellation)
    }

    private func lift(workspace: Workspace, reducedCoordinates: [CompensatedEnclosure],
        sourceValues: [CompensatedEnclosure], additionalCancellation: CancellationToken?) throws -> Lift {
        try Self.checkCancellation(additionalCancellation)
        let plan = workspace.plan
        guard plan.owner === owner else { throw Failure.wrongOwner }
        guard reducedCoordinates.count == plan.reducedCount, sourceValues.count == plan.sourceCount else { throw Failure.invalidInput }
        let zero = try CompensatedEnclosure(center: .zero)
        var work = Work(control: owner.control, cancellation: additionalCancellation)
        for row in 0..<plan.axisCount { try work.tick(1); workspace.values[row] = zero }
        try populateLift(workspace: workspace, reducedCoordinates: reducedCoordinates,
            sourceValues: sourceValues, zero: zero, work: &work)
        let bytes = try multiply(plan.axisCount, MemoryLayout<CompensatedEnclosure>.stride)
        guard bytes <= limits.maximumResultBytes else { throw Failure.resultLimit }
        try Self.checkCancellation(additionalCancellation)
        let lease = try owner.control.reserveStorage(byteCount: bytes)
        try Self.checkCancellation(additionalCancellation)
        try owner.control.checkpoint(workUnits: plan.axisCount)
        try Self.checkCancellation(additionalCancellation)
        var values = [CompensatedEnclosure](repeating: zero, count: plan.axisCount)
        for row in 0..<plan.axisCount { try work.tick(1); values[row] = workspace.values[row] }
        try Self.checkCancellation(additionalCancellation)
        try owner.control.checkpoint(workUnits: 0)
        try Self.checkCancellation(additionalCancellation)
        return Lift(plan: plan, values: values, lease: lease)
    }

    private func populateLift(workspace: Workspace, reducedCoordinates: [CompensatedEnclosure],
        sourceValues: [CompensatedEnclosure], zero: CompensatedEnclosure, work: inout Work) throws {
        let plan = workspace.plan, n = plan.axisCount
        for index in 0..<plan.orderCount {
            try work.tick(1)
            let row = plan.order[index]
            if row == n { continue }
            let edge = plan.parentSource[row]
            if edge < 0 {
                workspace.values[row] = reducedCoordinates[plan.coordinate[row]]
            } else {
                let previous = plan.parent[row] == n ? zero : workspace.values[plan.parent[row]]
                workspace.values[row] = try plan.sign[row] == 1
                    ? previous.adding(sourceValues[edge]) : previous.subtracting(sourceValues[edge])
            }
        }
    }

    package func apply(workspace: Workspace, reducedCoordinates: [CompensatedEnclosure],
        sourceValues: [CompensatedEnclosure], staticResidual: [CompensatedEnclosure],
        stateChargeRate: [CompensatedEnclosure], prescribedChargeRate: [CompensatedEnclosure],
        explicitTimeChargeRate: [CompensatedEnclosure]) throws -> Application {
        let plan = workspace.plan, n = plan.axisCount
        guard plan.owner === owner else { throw Failure.wrongOwner }
        guard reducedCoordinates.count == plan.reducedCount, sourceValues.count == plan.sourceCount,
              staticResidual.count == n, stateChargeRate.count == n, prescribedChargeRate.count == n,
              explicitTimeChargeRate.count == n else { throw Failure.invalidInput }
        let zero = try CompensatedEnclosure(center: .zero)
        var work = Work(control: owner.control)
        for source in plan.sources {
            try work.tick(1)
            let row = source.branchRow
            guard staticResidual[row] == zero, stateChargeRate[row] == zero,
                  prescribedChargeRate[row] == zero, explicitTimeChargeRate[row] == zero else { throw Failure.invalidInput }
        }
        for row in 0..<n {
            try work.tick(4)
            workspace.values[row] = zero
            workspace.residual[row] = try staticResidual[row].adding(stateChargeRate[row])
                .adding(prescribedChargeRate[row]).adding(explicitTimeChargeRate[row])
            workspace.sums[row] = workspace.residual[row]
        }
        try populateLift(workspace: workspace, reducedCoordinates: reducedCoordinates,
            sourceValues: sourceValues, zero: zero, work: &work)
        for index in (0..<plan.orderCount).reversed() {
            try work.tick(1)
            let row = plan.order[index]
            if row == n || plan.parentSource[row] < 0 { continue }
            let edge = plan.parentSource[row], parent = plan.parent[row]
            workspace.values[plan.sources[edge].branchRow] = try plan.sign[row] == 1
                ? workspace.sums[row].negated() : workspace.sums[row]
            if parent != n { workspace.sums[parent] = try workspace.sums[parent].adding(workspace.sums[row]) }
        }
        let outputCells = try add(multiply(n, 2), plan.reducedCount)
        let outputBytes = try multiply(outputCells, MemoryLayout<CompensatedEnclosure>.stride)
        guard outputBytes <= limits.maximumResultBytes else { throw Failure.resultLimit }
        let lease = try owner.control.reserveStorage(byteCount: outputBytes)
        try owner.control.checkpoint(workUnits: outputCells)
        var coordinates = [CompensatedEnclosure](repeating: zero, count: n)
        var residuals = [CompensatedEnclosure](repeating: zero, count: n)
        var reduced = [CompensatedEnclosure](repeating: zero, count: plan.reducedCount)
        for row in 0..<n {
            try work.tick(1)
            coordinates[row] = workspace.values[row]; residuals[row] = workspace.residual[row]
            if plan.parent[row] == row, plan.coordinate[row] >= 0 {
                reduced[plan.coordinate[row]] = workspace.sums[row]
            }
        }
        for (index, source) in plan.sources.enumerated() {
            try work.tick(4)
            let current = coordinates[source.branchRow]
            if let positive = source.positiveRow { residuals[positive] = try residuals[positive].adding(current) }
            if let negative = source.negativeRow { residuals[negative] = try residuals[negative].subtracting(current) }
            let positive = source.positiveRow.map { coordinates[$0] } ?? zero
            let negative = source.negativeRow.map { coordinates[$0] } ?? zero
            residuals[source.branchRow] = try positive.subtracting(negative).subtracting(sourceValues[index])
        }
        try owner.control.checkpoint(workUnits: 0)
        return Application(plan: plan, coordinates: coordinates, residual: residuals, reduced: reduced, lease: lease)
    }

    package struct Capacity: Sendable {
        package let vertices: Int
        package let arcs: Int
        package let resultIntegers: Int
        package let temporaryIntegers: Int
        package let resultBytes: Int
        package let temporaryBytes: Int
    }
    package static func capacity(axisCount n: Int, sourceCount m: Int) throws -> Capacity {
        guard n > 0, m >= 0 else { throw Failure.invalidInput }
        let v = try checkedAdd(n, 1)
        let arcs = try TransientExecutionBudget.multiply(m, 2, "prescribed voltage arcs")
        let resultInts = try checkedAdd(checkedAdd(TransientExecutionBudget.multiply(v, 5, "prescribed voltage tables"), n), m)
        let temporaryInts = try checkedAdd(v, TransientExecutionBudget.multiply(m, 8, "prescribed voltage adjacency"))
        let resultBytes = try checkedAdd(checkedAdd(TransientExecutionBudget.multiply(resultInts, MemoryLayout<Int>.stride, "prescribed voltage indices"),
            TransientExecutionBudget.multiply(n, MemoryLayout<DCEquationKind>.stride, "prescribed voltage natures")),
            TransientExecutionBudget.multiply(m, MemoryLayout<Source>.stride, "prescribed voltage sources"))
        let temporaryBytes = try TransientExecutionBudget.multiply(temporaryInts, MemoryLayout<Int>.stride, "prescribed voltage scratch")
        return Capacity(vertices: v, arcs: arcs, resultIntegers: resultInts, temporaryIntegers: temporaryInts,
            resultBytes: resultBytes, temporaryBytes: temporaryBytes)
    }

    fileprivate static func checkedAdd(_ a: Int, _ b: Int) throws -> Int {
        try TransientExecutionBudget.add(a, b, "prescribed voltage cells")
    }
    private func add(_ a: Int, _ b: Int) throws -> Int { try Self.checkedAdd(a, b) }
    private func multiply(_ a: Int, _ b: Int) throws -> Int {
        try TransientExecutionBudget.multiply(a, b, "prescribed voltage capacity")
    }
    private static func checkCancellation(_ cancellation: CancellationToken?) throws {
        if let cancellation, cancellation.isCancelled || Task.isCancelled { throw AnalysisError.cancelled }
    }
    private struct Work {
        let control: any LinearSolverExecutionControlling
        let cancellation: CancellationToken?
        var remaining = 0
        init(control: any LinearSolverExecutionControlling, cancellation: CancellationToken? = nil) {
            self.control = control; self.cancellation = cancellation
        }
        mutating func tick(_ units: Int) throws {
            try PrescribedVoltageReduction.checkCancellation(cancellation)
            if remaining < units {
                try control.checkpoint(workUnits: 256)
                try PrescribedVoltageReduction.checkCancellation(cancellation)
                remaining += 256
            }
            remaining -= units
        }
    }
}
