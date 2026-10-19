import CoreSpiceDevices
import OSDIContracts
import OSDIRuntime
import Synchronization

/// The lock transfers exclusive ownership; foreign code and caller callbacks run unlocked.
package final class OSDIExecutionOwner: Sendable {
    private struct Session: ~Copyable, Sendable {
        var sourceFacts: OSDITransientSourceFacts
        var acceptedGeneration: UInt64 = 0
        var model: OSDIPreparedModel
        let library: OSDILibrary
        var unknowns: [Double]
        let initialPrevious: [Double]
        var previous: [Double]
        var nextTrial: [Double]
        var charge: [Double]
        var current: [Double]
        var chargeTrial: [Double]
        var currentTrial: [Double]
        var staticResidual: [Double]
        var staticResidualTrial: [Double]
        var ordinaryAcceptedContext: OSDIEvaluationContext?
        var staticHigh: [Double]
        var staticLow: [Double]
        var staticRadius: [Double]
        var staticTrialHigh: [Double]
        var staticTrialLow: [Double]
        var staticTrialRadius: [Double]
        var precision: OSDIPrecisionSession?
        let precisionBits: UInt32
        var unknownLow: [Double]
        var acceptedHigh: [Double]
        var acceptedLow: [Double]
        var iqHigh: [Double]
        var iqLow: [Double]
        var iqRadius: [Double]
        var iqTrialHigh: [Double]
        var iqTrialLow: [Double]
        var iqTrialRadius: [Double]
        var acceptedContext: OSDIPrecisionContext?
        var pendingPrecisionCleanup: OSDIPendingPrecisionCleanup? = nil
        var transientActive = false
        var acceptedTime = 0.0
        var hasAcceptedDerivative = false
        var maximumTimeStep: Double?

        mutating func endTransient() {
            sourceFacts.invalidate()
            transientActive = false
            hasAcceptedDerivative = false
            acceptedTime = 0
            maximumTimeStep = nil
            acceptedContext = nil
            ordinaryAcceptedContext = nil
        }
        mutating func close() throws(OSDIAdapterFailure) {
            sourceFacts.invalidate()
            if let pendingPrecisionCleanup {
                do { try pendingPrecisionCleanup.close(); self.pendingPrecisionCleanup = nil }
                catch { throw .runtime(error) }
            }
            do { try precision?.close() }
            catch {
                pendingPrecisionCleanup = OSDIExecutionOwner.pendingCleanup(error)
                throw .runtime(error)
            }
            model.close()
            do { try library.close() } catch { throw .runtime(error) }
        }
        mutating func gather(mapping: OSDIBoundMapping, solution: SolutionState) throws(OSDIAdapterFailure) {
            guard !Task.isCancelled else { throw .cancelled }
            guard solution.variables.count == mapping.matrixDimension else { throw .invalidMatrixMapping }
            for active in unknowns.indices {
                let value = mapping.activeGlobal[active].map { solution.variables[$0] } ?? 0
                guard value.isFinite else { throw .nonfiniteEvaluation }
                unknowns[active] = value
            }
        }
        mutating func gatherPrecision(mapping: OSDIBoundMapping, solution: SolutionState) throws(OSDIAdapterFailure) {
            guard !Task.isCancelled else { throw .cancelled }
            guard solution.variables.count == mapping.matrixDimension,
                  solution.variableLowComponents == nil || solution.variableLowComponents?.count == solution.variables.count else { throw .invalidMatrixMapping }
            do {
                for active in unknowns.indices {
                    let pair: CompensatedValue
                    if let variable = mapping.activeVariables[active], let global = mapping.activeGlobal[active] {
                        pair = try solution.checkedBoundCompensatedValue(at: global, for: variable)
                    } else { pair = .zero }
                    unknowns[active] = pair.high; unknownLow[active] = pair.low
                }
            } catch { throw OSDIExecutionOwner.precisionFailure(error) }
        }
        borrowing func preciseStep(_ integration: IntegrationState) throws(OSDIAdapterFailure) -> (CompensatedValue, Double) {
            guard transientActive, acceptedContext != nil else { throw .transientSessionRequired }
            guard integration.currentTime.isFinite, integration.currentTime > acceptedTime else { throw .invalidIntegration }
            if integration.method == .trapezoidal && !hasAcceptedDerivative { throw .invalidIntegration }
            do {
                let step = try integration.compensatedTimeStep
                let exact = try CompensatedValue(high: integration.currentTime).subtracting(CompensatedValue(high: acceptedTime))
                guard step == exact, step.high > 0 else { throw OSDIAdapterFailure.invalidIntegration }
                let factor = try CompensatedValue(high: integration.method == .trapezoidal ? 2 : 1)
                let alpha = try factor.divided(by: step)
                let rounded = alpha.high + alpha.low
                guard rounded.isFinite else { throw OSDIAdapterFailure.invalidIntegration }
                return (step, rounded)
            } catch { throw OSDIExecutionOwner.precisionFailure(error) }
        }
        mutating func publishPrecision(context: OSDIPrecisionContext, derivative: Bool, maximum: Double?) {
            sourceFacts.invalidate()
            // Invalidation prevents an old record surviving even generation wrap.
            acceptedGeneration &+= 1
            for active in unknowns.indices { acceptedHigh[active] = unknowns[active]; acceptedLow[active] = unknownLow[active] }
            swap(&iqHigh, &iqTrialHigh); swap(&iqLow, &iqTrialLow); swap(&iqRadius, &iqTrialRadius)
            swap(&staticHigh, &staticTrialHigh); swap(&staticLow, &staticTrialLow); swap(&staticRadius, &staticTrialRadius)
            acceptedContext = context; acceptedTime = context.timeHigh
            transientActive = true; hasAcceptedDerivative = derivative; maximumTimeStep = maximum
        }
        borrowing func coefficient(_ integration: IntegrationState) throws(OSDIAdapterFailure) -> Double {
            guard transientActive else { throw .transientSessionRequired }
            let dt = integration.timeStep, time = integration.currentTime
            guard dt.isFinite, dt > 0, time.isFinite, time > acceptedTime,
                  abs((time - acceptedTime) - dt) <= max(abs(time), dt) * 64 * Double.ulpOfOne,
                  integration.coefficient.isFinite else { throw .invalidIntegration }
            if case .trapezoidal = integration.method, !hasAcceptedDerivative { throw .invalidIntegration }
            return integration.coefficient
        }
        mutating func publishTrial(context: OSDIEvaluationContext, derivative: Bool, maximum: Double?) {
            sourceFacts.invalidate()
            // Invalidation prevents an old record surviving even generation wrap.
            acceptedGeneration &+= 1
            for active in unknowns.indices { acceptedHigh[active] = unknowns[active] }
            swap(&staticResidual, &staticResidualTrial)
            ordinaryAcceptedContext = context
            swap(&charge, &chargeTrial)
            swap(&current, &currentTrial)
            swap(&previous, &nextTrial)
            acceptedTime = context.timeSeconds
            hasAcceptedDerivative = derivative
            maximumTimeStep = maximum
            transientActive = true
        }
    }
    private struct State: ~Copyable {
        var session: Session?
        var busy = false
        var closed = false
        var ending = false
        var invalidatingSourceFacts = false
        // Immutable accepted-bound snapshot remains readable while the session is checked out.
        var maximumTimeStep: Double?
    }
    package static var logicalStateByteCount: Int { MemoryLayout<Mutex<State>>.stride + 2 * MemoryLayout<Int>.stride }
    private let state: Mutex<State>

    init(model: consuming OSDIPreparedModel, library: OSDILibrary, previous: [Double],
         precision: consuming OSDIPrecisionSession? = nil, precisionBits: UInt32 = 0,
         pendingPrecisionCleanup: OSDIPendingPrecisionCleanup? = nil) {
        let count = model.topology.activeUnknownCount, raw = model.topology.nodes.count
        let activePrecision = precisionBits == 0 ? 0 : count, rawPrecision = precisionBits == 0 ? 0 : raw
        state = Mutex(State(session: Session(sourceFacts: .init(active: count, raw: raw, precision: precisionBits != 0),
            model: consume model, library: library,
            unknowns: [Double](repeating: 0, count: count), initialPrevious: previous,
            previous: [Double](repeating: 0, count: previous.count), nextTrial: [Double](repeating: 0, count: previous.count),
            charge: [Double](repeating: 0, count: raw), current: [Double](repeating: 0, count: raw),
            chargeTrial: [Double](repeating: 0, count: raw), currentTrial: [Double](repeating: 0, count: raw),
            staticResidual: [Double](repeating: 0, count: raw), staticResidualTrial: [Double](repeating: 0, count: raw),
            staticHigh: [Double](repeating: 0, count: rawPrecision), staticLow: [Double](repeating: 0, count: rawPrecision), staticRadius: [Double](repeating: 0, count: rawPrecision),
            staticTrialHigh: [Double](repeating: 0, count: rawPrecision), staticTrialLow: [Double](repeating: 0, count: rawPrecision), staticTrialRadius: [Double](repeating: 0, count: rawPrecision),
            precision: consume precision, precisionBits: precisionBits,
            unknownLow: [Double](repeating: 0, count: activePrecision),
            acceptedHigh: [Double](repeating: 0, count: count), acceptedLow: [Double](repeating: 0, count: activePrecision),
            iqHigh: [Double](repeating: 0, count: rawPrecision), iqLow: [Double](repeating: 0, count: rawPrecision), iqRadius: [Double](repeating: 0, count: rawPrecision),
            iqTrialHigh: [Double](repeating: 0, count: rawPrecision), iqTrialLow: [Double](repeating: 0, count: rawPrecision), iqTrialRadius: [Double](repeating: 0, count: rawPrecision), pendingPrecisionCleanup: pendingPrecisionCleanup)))
    }

    private static func context(_ mode: OSDIEvaluationMode, time: Double = 0,
                                frequency: Double? = nil) throws(OSDIAdapterFailure) -> OSDIEvaluationContext {
        do { return try OSDIEvaluationContext(mode: mode, timeSeconds: time, noiseFrequencyHz: frequency) }
        catch { throw .runtime(.contract(error)) }
    }
    private static func evaluate<Result>(model: inout OSDIPreparedModel, context: OSDIEvaluationContext = .dc,
        unknowns: borrowing Span<Double>, previous: borrowing Span<Double>,
        _ body: (OSDIEvaluationView) -> Result) throws(OSDIAdapterFailure) -> Result {
        do {
            return try OSDINativeModelEvaluator().evaluate(model: &model, context: context,
                unknowns: unknowns, previousState: previous, body)
        } catch { throw .runtime(error) }
    }
    private static func valid(_ view: OSDIEvaluationView) -> Bool {
        for index in 0..<view.f.count { if !view.f[index].isFinite { return false } }
        for index in 0..<view.q.count { if !view.q[index].isFinite { return false } }
        for index in 0..<view.g.count { if !view.g[index].isFinite { return false } }
        for index in 0..<view.c.count { if !view.c[index].isFinite { return false } }
        for index in 0..<view.nextState.count { if !view.nextState[index].isFinite { return false } }
        return true
    }
    private static func reactiveCurrent(charge: Double, previous: Double, current: Double,
                                        alpha: Double, trapezoidal: Bool) -> Double {
        alpha * (charge - previous) - (trapezoidal ? current : 0)
    }

    // Separate inout fields keep the model borrow disjoint from trial-buffer writes.
    private static func captureTrial(model: inout OSDIPreparedModel, context: OSDIEvaluationContext,
        unknowns: borrowing Span<Double>, previous: borrowing Span<Double>,
        acceptedCharge: borrowing Span<Double>, acceptedCurrent: borrowing Span<Double>,
        integration: IntegrationState?, alpha: Double?,
        charge: inout [Double], current: inout [Double], staticResidual: inout [Double], next: inout [Double]
    ) throws(OSDIAdapterFailure) -> (OSDIAdapterFailure?, Double?) {
        try evaluate(model: &model, context: context, unknowns: unknowns, previous: previous) { view in
            guard valid(view) else { return (.nonfiniteEvaluation, nil) }
            if let integration, let maximum = view.maximumTimestep, maximum < integration.timeStep {
                return (.transientTimeStepExceedsBound(requested: integration.timeStep, maximum: maximum), nil)
            }
            if Task.isCancelled { return (.cancelled, nil) }
            for row in charge.indices {
                let iq: Double
                if let alpha, let integration {
                    iq = reactiveCurrent(charge: view.q[row], previous: acceptedCharge[row], current: acceptedCurrent[row],
                        alpha: alpha, trapezoidal: integration.method == .trapezoidal)
                } else { iq = 0 }
                guard iq.isFinite else { return (.nonfiniteEvaluation, nil) }
                staticResidual[row] = view.f[row]
                charge[row] = view.q[row]
                current[row] = iq
            }
            for index in next.indices { next[index] = view.nextState[index] }
            return (nil, view.maximumTimestep)
        }
    }

    func stamp(mapping: OSDIBoundMapping, stamper: inout MatrixStamper,
               solution: SolutionState) throws(OSDIAdapterFailure) {
        try withSession { session throws(OSDIAdapterFailure) in
            guard !session.transientActive else { throw .busy }
            guard let stampValue = stamper.stampValue else { throw .invalidMatrixMapping }
            try session.gather(mapping: mapping, solution: solution)
            let unknowns = session.unknowns.span, previous = session.initialPrevious.span
            let failure: OSDIAdapterFailure? = try Self.evaluate(model: &session.model, unknowns: unknowns, previous: previous) { view in
                let count = mapping.rawGlobal.count
                for row in 0..<count {
                    guard view.f[row].isFinite else { return .nonfiniteEvaluation }
                    var rhs = -view.f[row]
                    for col in 0..<count {
                        let g = view.g[row * count + col]
                        guard g.isFinite else { return .nonfiniteEvaluation }
                        if let active = mapping.rawActive[col] { rhs += g * unknowns[active] }
                    }
                    guard rhs.isFinite else { return .nonfiniteEvaluation }
                }
                if Task.isCancelled { return .cancelled }
                for row in 0..<count {
                    guard let global = mapping.rawGlobal[row] else { continue }
                    var rhs = -view.f[row]
                    for col in 0..<count {
                        let g = view.g[row * count + col]
                        if let active = mapping.rawActive[col] { rhs += g * unknowns[active] }
                        if let slot = mapping.csrIndices[row * count + col] { stampValue(slot, g) }
                    }
                    stamper.stampRHS(global, rhs)
                }
                return nil
            }
            if let failure { throw failure }
        }
    }

    func accumulatePhysicalResidual(mapping: OSDIBoundMapping, solution: SolutionState,
                                    add: (Int, Double) -> Void) throws(OSDIAdapterFailure) {
        try withSession { session throws(OSDIAdapterFailure) in
            guard !session.transientActive else { throw .busy }
            try session.gather(mapping: mapping, solution: solution)
            let unknowns = session.unknowns.span, previous = session.initialPrevious.span
            let failure: OSDIAdapterFailure? = try Self.evaluate(model: &session.model, unknowns: unknowns, previous: previous) { view in
                for row in mapping.rawGlobal.indices { if !view.f[row].isFinite { return .nonfiniteEvaluation } }
                if Task.isCancelled { return .cancelled }
                for row in mapping.rawGlobal.indices { if let global = mapping.rawGlobal[row] { add(global, view.f[row]) } }
                return nil
            }
            if let failure { throw failure }
        }
    }

    func stampComplex(mapping: OSDIBoundMapping, stamper: inout ComplexMatrixStamper,
                      solution: SolutionState, omega: Double, noise: Bool) throws(OSDIAdapterFailure) {
        guard omega.isFinite, omega >= 0 else { throw .nonfiniteEvaluation }
        let context = try Self.context(noise ? .noise : .ac, frequency: noise ? omega / (2 * .pi) : nil)
        try withSession { session throws(OSDIAdapterFailure) in
            guard !session.transientActive else { throw .busy }
            guard let stampValue = stamper.stampValue else { throw .invalidMatrixMapping }
            try session.gather(mapping: mapping, solution: solution)
            let unknowns = session.unknowns.span, previous = session.initialPrevious.span
            let failure: OSDIAdapterFailure? = try Self.evaluate(model: &session.model, context: context,
                unknowns: unknowns, previous: previous) { view in
                for index in mapping.csrIndices.indices {
                    guard view.g[index].isFinite, view.c[index].isFinite,
                          (omega * view.c[index]).isFinite else { return .nonfiniteEvaluation }
                }
                if Task.isCancelled { return .cancelled }
                for index in mapping.csrIndices.indices {
                    if let slot = mapping.csrIndices[index] { stampValue(slot, view.g[index], omega * view.c[index]) }
                }
                return nil
            }
            if let failure { throw failure }
        }
    }

    func withNoiseDensities(mapping: OSDIBoundMapping, solution: SolutionState, frequency: Double,
        expectedCount: Int, _ body: (borrowing Span<Double>) throws -> Void) throws {
        let context = try Self.context(.noise, frequency: frequency)
        var callbackFailure: (any Error)?
        try withSession { session throws(OSDIAdapterFailure) in
            guard !session.transientActive else { throw .busy }
            try session.gather(mapping: mapping, solution: solution)
            let unknowns = session.unknowns.span, previous = session.initialPrevious.span
            let failure: OSDIAdapterFailure? = try Self.evaluate(model: &session.model, context: context,
                unknowns: unknowns, previous: previous) { view in
                guard view.noiseDensities.count == expectedCount else { return .invalidNoiseSources }
                for index in 0..<view.noiseDensities.count {
                    let density = view.noiseDensities[index]
                    if !density.isFinite || density < 0 { return .nonfiniteEvaluation }
                }
                if Task.isCancelled { return .cancelled }
                do { try body(view.noiseDensities) } catch { callbackFailure = error }
                return nil
            }
            if let failure { throw failure }
        }
        if let callbackFailure { throw callbackFailure }
    }

    func beginTransient(mapping: OSDIBoundMapping, solution: SolutionState,
                        initialization: TransientInitialization) throws(OSDIAdapterFailure) {
        // The caller distinguishes OP and UIC solution origins; both seed under the explicit native IC phase.
        let context = try Self.context(.transientInitialization)
        try withSession { session throws(OSDIAdapterFailure) in
            session.sourceFacts.invalidate()
            guard !session.transientActive else { throw .busy }
            if session.precisionBits != 0 {
                try Self.beginPrecision(session: &session, mapping: mapping, solution: solution)
                return
            }
            try session.gather(mapping: mapping, solution: solution)
            let result: (OSDIAdapterFailure?, Double?)
            do {
                let unknowns = session.unknowns.span, previous = session.initialPrevious.span
                result = try Self.captureTrial(model: &session.model, context: context,
                    unknowns: unknowns, previous: previous, acceptedCharge: Span<Double>(), acceptedCurrent: Span<Double>(),
                    integration: nil, alpha: nil, charge: &session.chargeTrial, current: &session.currentTrial, staticResidual: &session.staticResidualTrial, next: &session.nextTrial)
            }
            if let failure = result.0 { throw failure }
            session.publishTrial(context: context, derivative: false, maximum: result.1)
        }
    }

    func stampTransient(mapping: OSDIBoundMapping, stamper: inout MatrixStamper,
                        solution: SolutionState, integration: IntegrationState) throws(OSDIAdapterFailure) {
        let context = try Self.context(.transient, time: integration.currentTime)
        try withSession { session throws(OSDIAdapterFailure) in
            guard let stampValue = stamper.stampValue else { throw .invalidMatrixMapping }
            if session.precisionBits != 0 {
                try Self.stampPrecision(session: &session, mapping: mapping, stamper: &stamper, solution: solution, integration: integration)
                return
            }
            let alpha = try session.coefficient(integration)
            try session.gather(mapping: mapping, solution: solution)
            let unknowns = session.unknowns.span, previous = session.previous.span
            let charges = session.charge.span, currents = session.current.span
            let trap = integration.method == .trapezoidal
            let failure: OSDIAdapterFailure? = try Self.evaluate(model: &session.model, context: context,
                unknowns: unknowns, previous: previous) { view in
                let count = mapping.rawGlobal.count
                for row in 0..<count {
                    let iq = Self.reactiveCurrent(charge: view.q[row], previous: charges[row], current: currents[row], alpha: alpha, trapezoidal: trap)
                    guard view.f[row].isFinite, view.q[row].isFinite, iq.isFinite else { return .nonfiniteEvaluation }
                    var rhs = -view.f[row] - iq
                    for col in 0..<count {
                        let index = row * count + col, value = view.g[index] + alpha * view.c[index]
                        guard view.g[index].isFinite, view.c[index].isFinite, value.isFinite else { return .nonfiniteEvaluation }
                        if let active = mapping.rawActive[col] { rhs += value * unknowns[active] }
                    }
                    guard rhs.isFinite else { return .nonfiniteEvaluation }
                }
                if Task.isCancelled { return .cancelled }
                for row in 0..<count {
                    guard let global = mapping.rawGlobal[row] else { continue }
                    var rhs = -view.f[row] - Self.reactiveCurrent(charge: view.q[row], previous: charges[row], current: currents[row], alpha: alpha, trapezoidal: trap)
                    for col in 0..<count {
                        let index = row * count + col, value = view.g[index] + alpha * view.c[index]
                        if let active = mapping.rawActive[col] { rhs += value * unknowns[active] }
                        if let slot = mapping.csrIndices[index] { stampValue(slot, value) }
                    }
                    stamper.stampRHS(global, rhs)
                }
                return nil
            }
            if let failure { throw failure }
        }
    }

    func accumulateTransientResidual(mapping: OSDIBoundMapping, solution: SolutionState,
        integration: IntegrationState, add: (Int, Double) -> Void) throws(OSDIAdapterFailure) {
        try withSession { session throws(OSDIAdapterFailure) in
            let context = try Self.context(.transient, time: integration.currentTime)
            if session.precisionBits != 0 {
                try Self.preciseResidual(session: &session, mapping: mapping, solution: solution, integration: integration) { row, center, _ in
                    add(row, center.high + center.low)
                }
                return
            }
            let alpha = try session.coefficient(integration)
            try session.gather(mapping: mapping, solution: solution)
            let unknowns = session.unknowns.span, previous = session.previous.span
            let charges = session.charge.span, currents = session.current.span
            let trap = integration.method == .trapezoidal
            session.sourceFacts.invalidate()
            try Self.captureOrdinaryCompanion(model: &session.model, context: context, unknowns: unknowns, previous: previous,
                charges: charges, currents: currents, alpha: alpha, trap: trap, mapping: mapping, facts: &session.sourceFacts, add: add)
            session.sourceFacts.publish(key: .init(integration: integration, generation: session.acceptedGeneration,
                ordinaryContext: context, ordinaryReference: session.ordinaryAcceptedContext), high: unknowns, low: Span<Double>())
        }
    }
    private static func captureOrdinaryCompanion(model: inout OSDIPreparedModel, context: OSDIEvaluationContext,
        unknowns: borrowing Span<Double>, previous: borrowing Span<Double>, charges: borrowing Span<Double>,
        currents: borrowing Span<Double>, alpha: Double, trap: Bool, mapping: OSDIBoundMapping,
        facts: inout OSDITransientSourceFacts, add: (Int, Double) -> Void) throws(OSDIAdapterFailure) {
        try facts.willEvaluate()
        let failure: OSDIAdapterFailure? = try Self.evaluate(model: &model, context: context,
            unknowns: unknowns, previous: previous) { view in
            for row in mapping.rawGlobal.indices {
                let iq = Self.reactiveCurrent(charge: view.q[row], previous: charges[row], current: currents[row], alpha: alpha, trapezoidal: trap)
                guard view.f[row].isFinite, view.q[row].isFinite, iq.isFinite,
                      (view.f[row] + iq).isFinite else { return .nonfiniteEvaluation }
            }
            for row in mapping.rawGlobal.indices {
                facts.fHigh[row] = view.f[row]; facts.qHigh[row] = view.q[row]
            }
            if Task.isCancelled { return .cancelled }
            for row in mapping.rawGlobal.indices {
                if let global = mapping.rawGlobal[row] {
                    add(global, view.f[row] + Self.reactiveCurrent(charge: view.q[row], previous: charges[row], current: currents[row], alpha: alpha, trapezoidal: trap))
                }
            }
            if Task.isCancelled { return .cancelled }
            return nil
        }
        if let failure { throw failure }
    }

    func initialStaticResidual(mapping: OSDIBoundMapping, solution: SolutionState, time: Double,
        add: (Int, CompensatedValue, Double) -> Void) throws(OSDIAdapterFailure) {
        try withSession { session throws(OSDIAdapterFailure) in
            guard session.transientActive, time == 0, session.acceptedTime == 0 else { throw .invalidIntegration }
            if session.precisionBits != 0 {
                guard session.acceptedContext == (try Self.precisionContext(time: 0, initialization: true)) else { throw .invalidIntegration }
                try session.gatherPrecision(mapping: mapping, solution: solution)
                for active in session.unknowns.indices {
                    guard session.unknowns[active].bitPattern == session.acceptedHigh[active].bitPattern,
                          session.unknownLow[active].bitPattern == session.acceptedLow[active].bitPattern else { throw .invalidIntegration }
                }
                for row in mapping.rawGlobal.indices {
                    if let global = mapping.rawGlobal[row] {
                        do { add(global, try CompensatedValue(high: session.staticHigh[row], low: session.staticLow[row]), session.staticRadius[row]) }
                        catch { throw Self.precisionFailure(error) }
                    }
                }
            } else {
                guard session.ordinaryAcceptedContext == (try Self.context(.transientInitialization, time: 0)) else { throw .invalidIntegration }
                try session.gather(mapping: mapping, solution: solution)
                for active in session.unknowns.indices {
                    guard session.unknowns[active].bitPattern == session.acceptedHigh[active].bitPattern else { throw .invalidIntegration }
                }
                for row in mapping.rawGlobal.indices {
                    if let global = mapping.rawGlobal[row] {
                        do { add(global, try CompensatedValue(high: session.staticResidual[row]), 0) }
                        catch { throw Self.precisionFailure(error) }
                    }
                }
            }
        }
    }

    func decomposeTransient(mapping: OSDIBoundMapping, solution: SolutionState, integration: IntegrationState,
        add: (Int, TransientPhysicalEquationTerm, Double) -> Void) throws(OSDIAdapterFailure) {
        try withSession { session throws(OSDIAdapterFailure) in
            let context = try Self.context(.transient, time: integration.currentTime)
            guard session.precisionBits == 0 else { throw .unsupportedAnalysis }
            let alpha = try session.coefficient(integration)
            try session.gather(mapping: mapping, solution: solution)
            let unknowns = session.unknowns.span, previous = session.previous.span, charges = session.charge.span
            let key = OSDITransientSourceFacts.Key(integration: integration, generation: session.acceptedGeneration,
                ordinaryContext: context, ordinaryReference: session.ordinaryAcceptedContext)
            let matches = session.sourceFacts.matches(key: key, high: unknowns, low: Span<Double>())
            session.sourceFacts.invalidate()
            if matches {
                for row in mapping.rawGlobal.indices {
                    guard (alpha * (session.sourceFacts.qHigh[row] - charges[row])).isFinite else { throw .nonfiniteEvaluation }
                }
                guard !Task.isCancelled else { throw .cancelled }
                for row in mapping.rawGlobal.indices {
                    if let global = mapping.rawGlobal[row] {
                        add(global, .staticResidual, session.sourceFacts.fHigh[row])
                        add(global, .chargeDifference, alpha * (session.sourceFacts.qHigh[row] - charges[row]))
                    }
                }
                guard !Task.isCancelled else { throw .cancelled }
                return
            }
            try session.sourceFacts.willEvaluate()
            let failure: OSDIAdapterFailure? = try Self.evaluate(model: &session.model, context: context, unknowns: unknowns, previous: previous) { view in
                for row in mapping.rawGlobal.indices {
                    guard view.f[row].isFinite, view.q[row].isFinite, (alpha * (view.q[row] - charges[row])).isFinite else { return .nonfiniteEvaluation }
                }
                if Task.isCancelled { return .cancelled }
                for row in mapping.rawGlobal.indices {
                    if let global = mapping.rawGlobal[row] {
                        add(global, .staticResidual, view.f[row])
                        add(global, .chargeDifference, alpha * (view.q[row] - charges[row]))
                    }
                }
                return nil
            }
            if let failure { throw failure }
        }
    }

    func decomposeTransientEnclosure(mapping: OSDIBoundMapping, solution: SolutionState, integration: IntegrationState,
        add: (Int, TransientPhysicalEquationTerm, CompensatedValue, Double) -> Void) throws(OSDIAdapterFailure) {
        try withSession { session throws(OSDIAdapterFailure) in
            guard session.precisionBits != 0 else { throw .unsupportedAnalysis }
            let (step, _) = try session.preciseStep(integration)
            try session.gatherPrecision(mapping: mapping, solution: solution)
            guard let reference = session.acceptedContext else { throw .transientSessionRequired }
            let context = try Self.precisionContext(time: integration.currentTime)
            let high = session.unknowns.span, low = session.unknownLow.span
            let referenceHigh = session.acceptedHigh.span, referenceLow = session.acceptedLow.span
            let referenceZero = Span<Double>()
            let key = OSDITransientSourceFacts.Key(integration: integration, generation: session.acceptedGeneration,
                precisionContext: context, precisionReference: reference)
            let matches = session.sourceFacts.matches(key: key, high: high, low: low)
            session.sourceFacts.invalidate()
            if matches {
                do {
                    for pass in 0..<2 {
                        for row in mapping.rawGlobal.indices {
                            let f = try CompensatedEnclosure(center: CompensatedValue(high: session.sourceFacts.fHigh[row], low: session.sourceFacts.fLow[row]), radius: session.sourceFacts.fRadius[row])
                            let delta = try CompensatedEnclosure(center: CompensatedValue(high: session.sourceFacts.qHigh[row], low: session.sourceFacts.qLow[row]), radius: session.sourceFacts.qRadius[row])
                            var derivative = try delta.divided(by: CompensatedEnclosure(center: step))
                            if integration.method == .trapezoidal { derivative = try derivative.adding(derivative) }
                            if pass == 1, let global = mapping.rawGlobal[row] {
                                add(global, .staticResidual, f.center, f.radius)
                                add(global, .chargeDifference, derivative.center, derivative.radius)
                            }
                        }
                        if Task.isCancelled { throw OSDIAdapterFailure.cancelled }
                    }
                } catch { throw Self.precisionFailure(error) }
                return
            }
            try session.sourceFacts.willEvaluate()
            let failure: OSDIAdapterFailure? = try Self.evaluatePrecision(precision: &session.precision, bits: session.precisionBits,
                high: high, low: low, referenceHigh: referenceHigh, referenceLow: referenceLow, context: context, reference: reference) { view in
                do {
                    // Both complete passes validate before callbacks can change caller-owned buffers.
                    for pass in 0..<2 {
                        for row in mapping.rawGlobal.indices {
                            let f = try CompensatedEnclosure(center: CompensatedValue(high: view.fHigh[row], low: view.fLow[row]), radius: view.fRadius[row])
                            var derivative = try Self.preciseCurrent(view: view, row: row, step: step, trapezoidal: false,
                                acceptedHigh: referenceZero, acceptedLow: referenceZero, acceptedRadius: referenceZero)
                            if integration.method == .trapezoidal { derivative = try derivative.adding(derivative) }
                            if pass == 1, let global = mapping.rawGlobal[row] {
                                add(global, .staticResidual, f.center, f.radius)
                                add(global, .chargeDifference, derivative.center, derivative.radius)
                            }
                        }
                        if Task.isCancelled { return .cancelled }
                    }
                } catch { return Self.precisionFailure(error) }
                return nil
            }
            if let failure { throw failure }
        }
    }

    func candidateMaximumTimeStep(mapping: OSDIBoundMapping, solution: SolutionState,
                                   integration: IntegrationState) throws(OSDIAdapterFailure) -> Double? {
        return try withSession { session throws(OSDIAdapterFailure) in
            let context = try Self.context(.transient, time: integration.currentTime)
            if session.precisionBits != 0 {
                return try Self.precisionBound(session: &session, mapping: mapping, solution: solution, integration: integration)
            }
            _ = try session.coefficient(integration)
            try session.gather(mapping: mapping, solution: solution)
            let unknowns = session.unknowns.span, previous = session.previous.span
            return try Self.evaluate(model: &session.model, context: context, unknowns: unknowns, previous: previous) { $0.maximumTimestep }
        }
    }

    func commitTransient(mapping: OSDIBoundMapping, solution: SolutionState,
                         integration: IntegrationState) throws(OSDIAdapterFailure) {
        try withSession { session throws(OSDIAdapterFailure) in
            let context = try Self.context(.transient, time: integration.currentTime)
            session.sourceFacts.invalidate()
            if session.precisionBits != 0 {
                try Self.commitPrecision(session: &session, mapping: mapping, solution: solution, integration: integration)
                return
            }
            let alpha = try session.coefficient(integration)
            try session.gather(mapping: mapping, solution: solution)
            let result: (OSDIAdapterFailure?, Double?)
            do {
                let unknowns = session.unknowns.span, previous = session.previous.span
                let charges = session.charge.span, currents = session.current.span
                result = try Self.captureTrial(model: &session.model, context: context,
                    unknowns: unknowns, previous: previous, acceptedCharge: charges, acceptedCurrent: currents,
                    integration: integration, alpha: alpha, charge: &session.chargeTrial, current: &session.currentTrial, staticResidual: &session.staticResidualTrial, next: &session.nextTrial)
            }
            if let failure = result.0 { throw failure }
            session.publishTrial(context: context, derivative: true, maximum: result.1)
        }
    }

    package static func pendingCleanup(_ error: OSDIError) -> OSDIPendingPrecisionCleanup? {
        switch error {
        case .precisionCleanup(_, let owner): return owner
        case .cleanup(let primary, let secondary): return pendingCleanup(primary) ?? pendingCleanup(secondary)
        default: return nil
        }
    }
    private static func pendingCleanup(_ error: OSDIAdapterFailure) -> OSDIPendingPrecisionCleanup? {
        switch error {
        case .runtime(let issue): return pendingCleanup(issue)
        case .cleanupPending(let cause, _): return pendingCleanup(cause)
        case .cleanup(let primary, let secondary): return pendingCleanup(primary) ?? pendingCleanup(secondary)
        default: return nil
        }
    }
    private static func precisionFailure(_ error: any Error) -> OSDIAdapterFailure {
        if let error = error as? OSDIAdapterFailure { return error }
        if let error = error as? OSDIError { return .runtime(error) }
        return .runtime(.host(operation: "OSDI compensated composition", underlying: error))
    }
    private static func precisionContext(time: Double, initialization: Bool = false) throws(OSDIAdapterFailure) -> OSDIPrecisionContext {
        do { return try OSDIPrecisionContext(mode: initialization ? .transientInitialization : .transient, timeHigh: time, timeLow: 0) }
        catch { throw .runtime(.contract(error)) }
    }
    private static func evaluatePrecision<Result>(precision: inout OSDIPrecisionSession?, bits: UInt32,
        high: borrowing Span<Double>, low: borrowing Span<Double>, referenceHigh: borrowing Span<Double>, referenceLow: borrowing Span<Double>,
        context: OSDIPrecisionContext, reference: OSDIPrecisionContext,
        _ body: (OSDIPrecisionEvaluationView) -> Result) throws(OSDIAdapterFailure) -> Result {
        guard var owner = precision.take() else { throw .unsupportedAnalysis }
        do {
            let result = try OSDINativePrecisionEvaluator().evaluate(session: &owner,
                candidateHigh: high, candidateLow: low, referenceHigh: referenceHigh, referenceLow: referenceLow,
                candidateContext: context, referenceContext: reference, precisionBits: bits, body)
            precision = consume owner
            return result
        } catch { precision = consume owner; throw .runtime(error) }
    }
    private static func preciseCurrent(view: borrowing OSDIPrecisionEvaluationView, row: Int,
        step: CompensatedValue, trapezoidal: Bool, acceptedHigh: borrowing Span<Double>,
        acceptedLow: borrowing Span<Double>, acceptedRadius: borrowing Span<Double>) throws -> CompensatedEnclosure {
        let delta = try CompensatedEnclosure(center: CompensatedValue(high: view.deltaQHigh[row], low: view.deltaQLow[row]), radius: view.deltaQRadius[row])
        let derivative = try delta.divided(by: CompensatedEnclosure(center: step))
        if !trapezoidal { return derivative }
        let previous = try CompensatedEnclosure(center: CompensatedValue(high: acceptedHigh[row], low: acceptedLow[row]), radius: acceptedRadius[row])
        return try derivative.adding(derivative).subtracting(previous)
    }
    private static func completeEnclosure(view: borrowing OSDIPrecisionEvaluationView, row: Int,
        step: CompensatedValue, trapezoidal: Bool, acceptedHigh: borrowing Span<Double>,
        acceptedLow: borrowing Span<Double>, acceptedRadius: borrowing Span<Double>) throws -> CompensatedEnclosure {
        let f = try CompensatedEnclosure(center: CompensatedValue(high: view.fHigh[row], low: view.fLow[row]), radius: view.fRadius[row])
        return try f.adding(preciseCurrent(view: view, row: row, step: step, trapezoidal: trapezoidal,
            acceptedHigh: acceptedHigh, acceptedLow: acceptedLow, acceptedRadius: acceptedRadius))
    }
    private static func capturePrecision(precision: inout OSDIPrecisionSession?, bits: UInt32,
        high: borrowing Span<Double>, low: borrowing Span<Double>, referenceHigh: borrowing Span<Double>, referenceLow: borrowing Span<Double>,
        context: OSDIPrecisionContext, reference: OSDIPrecisionContext, step: CompensatedValue?, trapezoidal: Bool,
        acceptedHigh: borrowing Span<Double>, acceptedLow: borrowing Span<Double>, acceptedRadius: borrowing Span<Double>,
        trialHigh: inout [Double], trialLow: inout [Double], trialRadius: inout [Double],
        staticHigh: inout [Double], staticLow: inout [Double], staticRadius: inout [Double]
    ) throws(OSDIAdapterFailure) -> (OSDIAdapterFailure?, Double?) {
        try evaluatePrecision(precision: &precision, bits: bits, high: high, low: low, referenceHigh: referenceHigh,
            referenceLow: referenceLow, context: context, reference: reference) { view in
            if let step, let maximum = view.maximumTimestep,
               step.high > maximum || (step.high == maximum && step.low > 0) {
                return (.transientTimeStepExceedsBound(requested: step.high, maximum: maximum), nil)
            }
            do {
                for row in trialHigh.indices {
                    let current: CompensatedEnclosure
                    if let step {
                        current = try preciseCurrent(view: view, row: row, step: step, trapezoidal: trapezoidal,
                            acceptedHigh: acceptedHigh, acceptedLow: acceptedLow, acceptedRadius: acceptedRadius)
                    } else { current = try CompensatedEnclosure(center: .zero) }
                    let f = try CompensatedEnclosure(center: CompensatedValue(high: view.fHigh[row], low: view.fLow[row]), radius: view.fRadius[row])
                    staticHigh[row] = f.center.high; staticLow[row] = f.center.low; staticRadius[row] = f.radius
                    trialHigh[row] = current.center.high; trialLow[row] = current.center.low; trialRadius[row] = current.radius
                }
            } catch { return (precisionFailure(error), nil) }
            if Task.isCancelled { return (.cancelled, nil) }
            return (nil, view.maximumTimestep)
        }
    }
    private static func beginPrecision(session: inout Session, mapping: OSDIBoundMapping,
                                       solution: SolutionState) throws(OSDIAdapterFailure) {
        try session.gatherPrecision(mapping: mapping, solution: solution)
        let context = try precisionContext(time: 0, initialization: true)
        let result: (OSDIAdapterFailure?, Double?)
        do {
            let high = session.unknowns.span, low = session.unknownLow.span
            result = try capturePrecision(precision: &session.precision, bits: session.precisionBits,
                high: high, low: low, referenceHigh: high, referenceLow: low, context: context, reference: context,
                step: nil, trapezoidal: false, acceptedHigh: Span<Double>(), acceptedLow: Span<Double>(), acceptedRadius: Span<Double>(),
                trialHigh: &session.iqTrialHigh, trialLow: &session.iqTrialLow, trialRadius: &session.iqTrialRadius,
                staticHigh: &session.staticTrialHigh, staticLow: &session.staticTrialLow, staticRadius: &session.staticTrialRadius)
        }
        if let failure = result.0 { throw failure }
        session.publishPrecision(context: context, derivative: false, maximum: result.1)
    }
    private static func stampPrecision(session: inout Session, mapping: OSDIBoundMapping,
        stamper: inout MatrixStamper, solution: SolutionState, integration: IntegrationState) throws(OSDIAdapterFailure) {
        let (step, alpha) = try session.preciseStep(integration)
        try session.gatherPrecision(mapping: mapping, solution: solution)
        guard let reference = session.acceptedContext, let stamp = stamper.stampValue else { throw .invalidMatrixMapping }
        let context = try precisionContext(time: integration.currentTime)
        let high = session.unknowns.span, low = session.unknownLow.span
        let referenceHigh = session.acceptedHigh.span, referenceLow = session.acceptedLow.span
        let acceptedHigh = session.iqHigh.span, acceptedLow = session.iqLow.span, acceptedRadius = session.iqRadius.span
        let trap = integration.method == .trapezoidal
        let failure: OSDIAdapterFailure? = try evaluatePrecision(precision: &session.precision, bits: session.precisionBits,
            high: high, low: low, referenceHigh: referenceHigh, referenceLow: referenceLow, context: context, reference: reference) { view in
            do {
                let count = mapping.rawGlobal.count
                for row in 0..<count {
                    let full = try completeEnclosure(view: view, row: row, step: step, trapezoidal: trap,
                        acceptedHigh: acceptedHigh, acceptedLow: acceptedLow, acceptedRadius: acceptedRadius)
                    var rhs = -full.center.high - full.center.low
                    for col in 0..<count {
                        let index = row * count + col, value = view.g[index] + alpha * view.c[index]
                        guard value.isFinite else { return .nonfiniteEvaluation }
                        if let active = mapping.rawActive[col] { rhs += value * high[active] }
                    }
                    guard rhs.isFinite else { return .nonfiniteEvaluation }
                }
                if Task.isCancelled { return .cancelled }
                for row in 0..<count {
                    guard let global = mapping.rawGlobal[row] else { continue }
                    let full = try completeEnclosure(view: view, row: row, step: step, trapezoidal: trap,
                        acceptedHigh: acceptedHigh, acceptedLow: acceptedLow, acceptedRadius: acceptedRadius)
                    var rhs = -full.center.high - full.center.low
                    for col in 0..<count {
                        let index = row * count + col, value = view.g[index] + alpha * view.c[index]
                        if let active = mapping.rawActive[col] { rhs += value * high[active] }
                        if let slot = mapping.csrIndices[index] { stamp(slot, value) }
                    }
                    stamper.stampRHS(global, rhs)
                }
            } catch { return precisionFailure(error) }
            return nil
        }
        if let failure { throw failure }
    }
    private static func preciseResidual(session: inout Session, mapping: OSDIBoundMapping,
        solution: SolutionState, integration: IntegrationState, add: (Int, CompensatedValue, Double) -> Void) throws(OSDIAdapterFailure) {
        let (step, _) = try session.preciseStep(integration)
        try session.gatherPrecision(mapping: mapping, solution: solution)
        guard let reference = session.acceptedContext else { throw .transientSessionRequired }
        let context = try precisionContext(time: integration.currentTime)
        let high = session.unknowns.span, low = session.unknownLow.span
        let referenceHigh = session.acceptedHigh.span, referenceLow = session.acceptedLow.span
        let acceptedHigh = session.iqHigh.span, acceptedLow = session.iqLow.span, acceptedRadius = session.iqRadius.span
        let trap = integration.method == .trapezoidal
        session.sourceFacts.invalidate()
        try capturePrecisionCompanion(precision: &session.precision, bits: session.precisionBits,
            high: high, low: low, referenceHigh: referenceHigh, referenceLow: referenceLow, context: context, reference: reference,
            acceptedHigh: acceptedHigh, acceptedLow: acceptedLow, acceptedRadius: acceptedRadius,
            step: step, trap: trap, mapping: mapping, facts: &session.sourceFacts, add: add)
        session.sourceFacts.publish(key: .init(integration: integration, generation: session.acceptedGeneration,
            precisionContext: context, precisionReference: reference), high: high, low: low)
    }
    private static func capturePrecisionCompanion(precision: inout OSDIPrecisionSession?, bits: UInt32,
        high: borrowing Span<Double>, low: borrowing Span<Double>, referenceHigh: borrowing Span<Double>, referenceLow: borrowing Span<Double>,
        context: OSDIPrecisionContext, reference: OSDIPrecisionContext, acceptedHigh: borrowing Span<Double>,
        acceptedLow: borrowing Span<Double>, acceptedRadius: borrowing Span<Double>, step: CompensatedValue, trap: Bool,
        mapping: OSDIBoundMapping, facts: inout OSDITransientSourceFacts,
        add: (Int, CompensatedValue, Double) -> Void) throws(OSDIAdapterFailure) {
        try facts.willEvaluate()
        let failure: OSDIAdapterFailure? = try evaluatePrecision(precision: &precision, bits: bits,
            high: high, low: low, referenceHigh: referenceHigh, referenceLow: referenceLow, context: context, reference: reference) { view in
            do {
                for row in mapping.rawGlobal.indices {
                    _ = try completeEnclosure(view: view, row: row, step: step, trapezoidal: trap,
                        acceptedHigh: acceptedHigh, acceptedLow: acceptedLow, acceptedRadius: acceptedRadius)
                }
                for row in mapping.rawGlobal.indices {
                    facts.fHigh[row] = view.fHigh[row]; facts.fLow[row] = view.fLow[row]; facts.fRadius[row] = view.fRadius[row]
                    facts.qHigh[row] = view.deltaQHigh[row]; facts.qLow[row] = view.deltaQLow[row]; facts.qRadius[row] = view.deltaQRadius[row]
                }
                if Task.isCancelled { return .cancelled }
                for row in mapping.rawGlobal.indices {
                    guard let global = mapping.rawGlobal[row] else { continue }
                    let value = try completeEnclosure(view: view, row: row, step: step, trapezoidal: trap,
                        acceptedHigh: acceptedHigh, acceptedLow: acceptedLow, acceptedRadius: acceptedRadius)
                    add(global, value.center, value.radius)
                }
                if Task.isCancelled { return .cancelled }
            } catch { return precisionFailure(error) }
            return nil
        }
        if let failure { throw failure }
    }
    func accumulateTransientEnclosure(mapping: OSDIBoundMapping, solution: SolutionState,
        integration: IntegrationState, add: (Int, CompensatedValue, Double) -> Void) throws(OSDIAdapterFailure) {
        try withSession { session throws(OSDIAdapterFailure) in
            guard session.precisionBits != 0 else { throw .unsupportedAnalysis }
            try Self.preciseResidual(session: &session, mapping: mapping, solution: solution, integration: integration, add: add)
        }
    }
    private static func precisionBound(session: inout Session, mapping: OSDIBoundMapping,
        solution: SolutionState, integration: IntegrationState) throws(OSDIAdapterFailure) -> Double? {
        _ = try session.preciseStep(integration)
        try session.gatherPrecision(mapping: mapping, solution: solution)
        guard let reference = session.acceptedContext else { throw .transientSessionRequired }
        let context = try precisionContext(time: integration.currentTime)
        let high = session.unknowns.span, low = session.unknownLow.span
        let referenceHigh = session.acceptedHigh.span, referenceLow = session.acceptedLow.span
        return try evaluatePrecision(precision: &session.precision, bits: session.precisionBits,
            high: high, low: low, referenceHigh: referenceHigh, referenceLow: referenceLow, context: context, reference: reference) { $0.maximumTimestep }
    }
    private static func commitPrecision(session: inout Session, mapping: OSDIBoundMapping,
        solution: SolutionState, integration: IntegrationState) throws(OSDIAdapterFailure) {
        let (step, _) = try session.preciseStep(integration)
        try session.gatherPrecision(mapping: mapping, solution: solution)
        guard let reference = session.acceptedContext else { throw .transientSessionRequired }
        let context = try precisionContext(time: integration.currentTime)
        let result: (OSDIAdapterFailure?, Double?)
        do {
            let high = session.unknowns.span, low = session.unknownLow.span
            let referenceHigh = session.acceptedHigh.span, referenceLow = session.acceptedLow.span
            let acceptedHigh = session.iqHigh.span, acceptedLow = session.iqLow.span, acceptedRadius = session.iqRadius.span
            result = try capturePrecision(precision: &session.precision, bits: session.precisionBits,
                high: high, low: low, referenceHigh: referenceHigh, referenceLow: referenceLow, context: context, reference: reference,
                step: step, trapezoidal: integration.method == .trapezoidal,
                acceptedHigh: acceptedHigh, acceptedLow: acceptedLow, acceptedRadius: acceptedRadius,
                trialHigh: &session.iqTrialHigh, trialLow: &session.iqTrialLow, trialRadius: &session.iqTrialRadius,
                staticHigh: &session.staticTrialHigh, staticLow: &session.staticTrialLow, staticRadius: &session.staticTrialRadius)
        }
        if let failure = result.0 { throw failure }
        session.publishPrecision(context: context, derivative: true, maximum: result.1)
    }

    package func transientSourceFactWork() throws(OSDIAdapterFailure) -> Int {
        try withSession { session throws(OSDIAdapterFailure) in
            let (active, a) = session.sourceFacts.candidateHigh.count.multipliedReportingOverflow(by: session.precisionBits == 0 ? 16 : 64)
            let (raw, r) = session.sourceFacts.fHigh.count.multipliedReportingOverflow(by: session.precisionBits == 0 ? 32 : 256)
            let (sum, s) = active.addingReportingOverflow(raw)
            let (total, t) = sum.addingReportingOverflow(128)
            guard !a, !r, !s, !t else { throw .capacityExceeded }
            return total
        }
    }
    package func invalidateTransientSourceFacts() {
        state.withLock { state in
            if state.busy { state.invalidatingSourceFacts = true; return }
            state.session?.sourceFacts.invalidate()
        }
    }
    // Counts actual model/worker requests made by companion or decomposition, including failed attempts.
    var transientSourceFactEvaluationCount: UInt64? { state.withLock { $0.session?.sourceFacts.evaluationCount } }

    var maximumTransientTimeStep: Double { state.withLock { $0.maximumTimeStep ?? .infinity } }
    func endTransient() {
        state.withLock { state in
            if state.busy { state.ending = true; return }
            if var session = state.session.take() {
                session.endTransient()
                state.session = consume session
            }
            state.maximumTimeStep = nil
        }
    }
    func validateConstitutiveCaptureAvailability() throws(OSDIAdapterFailure) {
        try withSession { _ in }
    }
    private func withSession<Result>(_ body: (inout Session) throws(OSDIAdapterFailure) -> Result) throws(OSDIAdapterFailure) -> Result {
        var session = try checkout()
        do {
            let result = try body(&session)
            if Task.isCancelled { session.sourceFacts.invalidate() }
            restore(consume session)
            return result
        } catch {
            session.sourceFacts.invalidate()
            if let pending = Self.pendingCleanup(error) { session.pendingPrecisionCleanup = pending }
            restore(consume session)
            throw error
        }
    }
    private func checkout() throws(OSDIAdapterFailure) -> Session {
        try state.withLock { state throws(OSDIAdapterFailure) in
            guard !state.closed else { throw .closed }
            guard !state.busy else { state.invalidatingSourceFacts = true; throw .busy }
            guard let session = state.session.take() else { throw .closed }
            state.busy = true
            return consume session
        }
    }
    private func restore(_ session: consuming sending Session) {
        var pending: Session? = consume session
        state.withLock { state in
            if state.ending { pending?.endTransient(); state.ending = false }
            if state.invalidatingSourceFacts { pending?.sourceFacts.invalidate(); state.invalidatingSourceFacts = false }
            state.maximumTimeStep = pending?.maximumTimeStep
            state.session = consume pending
            pending = nil
            state.busy = false
        }
    }
    func close() throws(OSDIAdapterFailure) {
        let alreadyClosed = state.withLock { $0.closed }
        if alreadyClosed { return }
        var session = try checkout()
        do { try session.close() }
        catch { restore(consume session); throw error }
        state.withLock { $0.busy = false; $0.closed = true; $0.maximumTimeStep = nil }
    }
}
