import CoreSpiceAnalysis
import CoreSpiceDevices
import CoreSpiceEvent
import CoreSpiceIR
import CoreSpiceOSDI
import Synchronization

/// Retains actual accepted static equations and checks the independent accepted-step balance.
internal final class NativeOSDICanonicalTransientValidator: Sendable {
    private struct Buffers: Sendable {
        var accepted: [CompensatedEnclosure]
        var trial: [CompensatedEnclosure]
        var increment: [CompensatedEnclosure]
        var initialized = false
        var acceptedTime = 0.0
        var validatedTime: Double?
        var failedPromotion = false
    }
    static var logicalStateByteCount: Int {
        2 * MemoryLayout<Int>.stride + MemoryLayout<Mutex<Buffers?>>.stride + MemoryLayout<Buffers>.stride
            + MemoryLayout<Array<any TransientPhysicalEquationDecomposing>>.stride
            + MemoryLayout<Array<any TransientPhysicalEquationEnclosureDecomposing>>.stride
            + MemoryLayout<Array<DCEquationRowPolicy>>.stride + MemoryLayout<Dictionary<MNAVariable, Int>>.stride
            + MemoryLayout<TransientExecutionBudget>.stride + MemoryLayout<CancellationToken>.stride
            + MemoryLayout<CompensatedEnclosure>.stride + MemoryLayout<Int>.stride
            + MemoryLayout<Array<OSDIExecutionOwner>>.stride
    }
    private let storage: Mutex<Buffers?>
    private let ordinary: [any TransientPhysicalEquationDecomposing]
    private let enclosed: [any TransientPhysicalEquationEnclosureDecomposing]
    private let rows: [DCEquationRowPolicy]
    private let variableMap: [MNAVariable: Int]
    private let budget: TransientExecutionBudget
    private let cancellation: CancellationToken
    private let zero: CompensatedEnclosure
    private let work: Int
    private let osdiOwners: [OSDIExecutionOwner]

    init(devices: [any BoundDevice], precision: Bool, rows: [DCEquationRowPolicy],
         variableMap: [MNAVariable: Int], budget: TransientExecutionBudget,
         cancellation: CancellationToken, sourceFactWork: Int = 0, osdiOwners: [OSDIExecutionOwner] = []) throws {
        self.osdiOwners = osdiOwners
        self.rows = rows; self.variableMap = variableMap; self.budget = budget; self.cancellation = cancellation
        let empty = try CompensatedEnclosure(center: .zero)
        zero = empty
        storage = Mutex(Buffers(accepted: Array(repeating: empty, count: rows.count),
            trial: Array(repeating: empty, count: rows.count), increment: Array(repeating: empty, count: rows.count)))
        let rowWork = try NativeCircuitExecution.capacityProduct(UInt64(rows.count), precision ? 512 : 128)
        let deviceWork = try NativeCircuitExecution.capacityProduct(UInt64(devices.count), 4)
        guard sourceFactWork >= 0, let admittedWork = Int(exactly: try NativeCircuitExecution.capacitySum(
            NativeCircuitExecution.capacitySum(rowWork, deviceWork), UInt64(sourceFactWork))) else {
            throw SPICENativeExecutionError.resource(TransientExecutionError.arithmeticOverflow("canonical equation work"))
        }
        work = admittedWork
        if precision {
            ordinary = []
            enclosed = try devices.map {
                guard let provider = $0 as? any TransientPhysicalEquationEnclosureDecomposing else {
                    throw SPICENativeExecutionError.unsupportedCapability("Missing enclosed original equation decomposition")
                }
                try provider.validateTransientPhysicalEquationDecomposition()
                return provider
            }
        } else {
            enclosed = []
            ordinary = try devices.map {
                guard let provider = $0 as? any TransientPhysicalEquationDecomposing else {
                    throw SPICENativeExecutionError.unsupportedCapability("Missing original equation decomposition")
                }
                try provider.validateTransientPhysicalEquationDecomposition()
                return provider
            }
        }
    }

    private func withBuffers(_ body: (inout Buffers) throws -> Void) throws {
        var buffers = try storage.withLock { value in
            guard let available = value else { throw OSDIAdapterFailure.busy }
            value = nil; return available
        }
        defer { storage.withLock { $0 = buffers } }
        try body(&buffers)
    }

    func invalidateSourceFacts() {
        for owner in osdiOwners { owner.invalidateTransientSourceFacts() }
    }

    func validate(state: SolutionState, integration: IntegrationState) throws {
        defer { invalidateSourceFacts() }
        try NativeCircuitExecution.check(cancellation)
        try budget.chargeWork(work)
        try withBuffers { buffers in
            guard !buffers.failedPromotion, state.variables.count == rows.count,
                  integration.currentTime > buffers.acceptedTime else { throw OSDIAdapterFailure.invalidIntegration }
            buffers.validatedTime = nil
            var failure: (any Error)?
            func value(_ row: Int, _ center: CompensatedValue, _ radius: Double) throws -> CompensatedEnclosure {
                guard rows.indices.contains(row) else { throw OSDIAdapterFailure.invalidMatrixMapping }
                return try CompensatedEnclosure(center: center, radius: radius)
            }
            if !buffers.initialized {
                guard let previous = state.previousVariables, previous.count == rows.count,
                      previous.allSatisfy(\.isFinite), buffers.acceptedTime == 0,
                      enclosed.isEmpty || state.previousVariableLowComponents?.count == rows.count else { throw OSDIAdapterFailure.invalidIntegration }
                let initial = SolutionState(variables: previous, variableMap: variableMap,
                    variableLowComponents: state.previousVariableLowComponents)
                for index in rows.indices { buffers.accepted[index] = zero }
                func addInitial(_ row: Int, _ center: CompensatedValue, _ radius: Double) {
                    guard failure == nil else { return }
                    do {
                        let term = try value(row, center, radius)
                        buffers.accepted[row] = try buffers.accepted[row].adding(term)
                    }
                    catch { failure = error }
                }
                for provider in ordinary {
                    try NativeCircuitExecution.check(cancellation)
                    try provider.accumulateTransientStaticResidual(state: initial, time: 0) { row, scalar in
                        do { addInitial(row, try CompensatedValue(high: scalar), 0) } catch { failure = error }
                    }
                }
                for provider in enclosed {
                    try NativeCircuitExecution.check(cancellation)
                    try provider.accumulateTransientStaticResidualEnclosure(state: initial, time: 0, add: addInitial)
                }
                if let failure { throw failure }
                buffers.initialized = true
                try budget.chargeWork(work)
            }
            for index in rows.indices { buffers.trial[index] = zero; buffers.increment[index] = zero }
            func addTerm(_ row: Int, _ form: TransientPhysicalEquationForm, _ term: TransientPhysicalEquationTerm,
                         _ center: CompensatedValue, _ radius: Double) {
                guard failure == nil else { return }
                do {
                    switch (form, term) {
                    case (.chargeDifference, .differentialIncrement), (.chargeDifference, .differentialHistoryCorrection),
                         (.differentialCapacitance, .chargeDifference): throw OSDIAdapterFailure.invalidIntegration
                    default: break
                    }
                    let termValue = try value(row, center, radius)
                    switch term {
                    case .staticResidual: buffers.trial[row] = try buffers.trial[row].adding(termValue)
                    case .chargeDifference, .differentialIncrement, .differentialHistoryCorrection:
                        buffers.increment[row] = try buffers.increment[row].adding(termValue)
                    }
                } catch { failure = error }
            }
            for provider in ordinary {
                try NativeCircuitExecution.check(cancellation)
                try provider.accumulateTransientPhysicalEquation(state: state, integration: integration) { row, term, scalar in
                    do { addTerm(row, provider.transientPhysicalEquationForm, term, try CompensatedValue(high: scalar), 0) } catch { failure = error }
                }
            }
            for provider in enclosed {
                try NativeCircuitExecution.check(cancellation)
                try provider.accumulateTransientPhysicalEquationEnclosure(state: state, integration: integration) { row, term, center, radius in
                    addTerm(row, provider.transientPhysicalEquationForm, term, center, radius)
                }
            }
            if let failure { throw failure }
            for index in rows.indices {
                var residual = try buffers.trial[index].adding(buffers.increment[index])
                if integration.method == .trapezoidal { residual = try residual.adding(buffers.accepted[index]) }
                guard residual.absoluteUpperBound <= rows[index].equationAbsoluteTolerance else {
                    throw SPICEOSDIPhysicalResidualFailure(row: index, kind: rows[index].kind,
                        residual: residual.center.high + residual.center.low,
                        absoluteTolerance: rows[index].equationAbsoluteTolerance)
                }
            }
            try NativeCircuitExecution.check(cancellation)
            buffers.validatedTime = integration.currentTime
        }
    }

    /// Called only by Analysis's existing callback after every device commit succeeded.
    func promote(time: Double) {
        storage.withLock { buffers in
            guard var available = buffers else { return }
            buffers = nil
            defer { buffers = available }
            guard !cancellation.isCancelled, !Task.isCancelled,
                  available.validatedTime == time else { available.failedPromotion = true; return }
            swap(&available.accepted, &available.trial)
            available.acceptedTime = time; available.validatedTime = nil
        }
    }

    func validateCompletion() throws {
        try NativeCircuitExecution.check(cancellation)
        try storage.withLock { buffers in
            guard let buffers, buffers.initialized, !buffers.failedPromotion,
                  buffers.validatedTime == nil else { throw OSDIAdapterFailure.invalidIntegration }
        }
    }
}
