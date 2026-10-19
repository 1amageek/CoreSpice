import Foundation
import CoreSpiceIR

/// Pre-resolved CSR value indices for BJT O(1) stamping.
///
/// Contains the 9 matrix positions for a 3-terminal device (C, B, E).
public struct BJTCSRIndices: Sendable {
    let cc: Int?  // (collector, collector)
    let cb: Int?  // (collector, base)
    let ce: Int?  // (collector, emitter)
    let bc: Int?  // (base, collector)
    let bb: Int?  // (base, base)
    let be: Int?  // (base, emitter)
    let ec: Int?  // (emitter, collector)
    let eb: Int?  // (emitter, base)
    let ee: Int?  // (emitter, emitter)

    public init(
        cc: Int? = nil, cb: Int? = nil, ce: Int? = nil,
        bc: Int? = nil, bb: Int? = nil, be: Int? = nil,
        ec: Int? = nil, eb: Int? = nil, ee: Int? = nil
    ) {
        self.cc = cc; self.cb = cb; self.ce = ce
        self.bc = bc; self.bb = bb; self.be = be
        self.ec = ec; self.eb = eb; self.ee = ee
    }
}

/// A polarity-normalized, low-injection SPICE3 BJT with explicit intrinsic topology.
public struct BoundBJT: BoundDevice, VoltageLimitingDevice, TransientSessionDevice,
    DCPhysicalResidualContributing, TransientPhysicalResidualContributing, NoisyDevice, Sendable {
    public let instance: Instance
    private let collector: Node
    private let base: Node
    private let emitter: Node
    private let collectorIdx: Int?
    private let baseIdx: Int?
    private let emitterIdx: Int?
    private let parameters: BJTModelParameters
    private let csrIndices: BJTCSRIndices
    private let series: [BJTSeriesElement]
    private let history = BJTChargeHistory()
    private var polarity: Double { parameters.polarity == .npn ? 1 : -1 }

    init(instance: Instance, collector: Node, base: Node, emitter: Node,
        collectorIdx: Int?, baseIdx: Int?, emitterIdx: Int?, parameters: BJTModelParameters,
        csrIndices: BJTCSRIndices = BJTCSRIndices(), series: [BJTSeriesElement] = []) {
        self.instance = instance; self.collector = collector; self.base = base; self.emitter = emitter
        self.collectorIdx = collectorIdx; self.baseIdx = baseIdx; self.emitterIdx = emitterIdx
        self.parameters = parameters; self.csrIndices = csrIndices; self.series = series
    }

    private func voltageVbe(state: SolutionState) -> Double {
        polarity * ((baseIdx.map { state.value(at: $0) } ?? 0) - (emitterIdx.map { state.value(at: $0) } ?? 0))
    }
    private func voltageVbc(state: SolutionState) -> Double {
        polarity * ((baseIdx.map { state.value(at: $0) } ?? 0) - (collectorIdx.map { state.value(at: $0) } ?? 0))
    }
    private func evaluate(_ state: SolutionState) throws -> BJTModelEvaluation {
        if let collectorIdx { _ = try state.checkedBoundValue(at: collectorIdx, for: .nodeVoltage(collector)) }
        if let baseIdx { _ = try state.checkedBoundValue(at: baseIdx, for: .nodeVoltage(base)) }
        if let emitterIdx { _ = try state.checkedBoundValue(at: emitterIdx, for: .nodeVoltage(emitter)) }
        for element in series {
            if let index = element.externalIndex { _ = try state.checkedBoundValue(at: index, for: .nodeVoltage(element.external)) }
            let current = element.conductance * (try state.checkedVoltage(at: element.external)
                - state.checkedVoltage(at: element.intrinsic))
            guard current.isFinite else { throw invalid("seriesCurrent", "BJT series current must be finite") }
        }
        return try BJTModelEvaluation(parameters: parameters, be: voltageVbe(state: state),
            bc: voltageVbc(state: state), device: instance.name)
    }

    public func stampDC(into stamper: inout MatrixStamper, state: SolutionState) throws {
        let op = try evaluate(state)
        for element in series { element.stamp(into: &stamper) }
        try stampCurrentRows(op, state: state, into: &stamper)
    }

    private func stampCurrentRows(_ op: BJTModelEvaluation, state: SolutionState, into stamper: inout MatrixStamper) throws {
        try stampRow(op.collector, row: collectorIdx, csr: (csrIndices.cc, csrIndices.cb, csrIndices.ce), state: state, into: &stamper)
        try stampRow(op.base, row: baseIdx, csr: (csrIndices.bc, csrIndices.bb, csrIndices.be), state: state, into: &stamper)
        try stampRow(op.emitter, row: emitterIdx, csr: (csrIndices.ec, csrIndices.eb, csrIndices.ee), state: state, into: &stamper)
    }

    private func stampRow(_ quantity: BJTModelEvaluation.Quantity, row: Int?,
        csr: (Int?, Int?, Int?), state: SolutionState, scale: Double = 1, into stamper: inout MatrixStamper) throws {
        guard let row else { return }
        let c = -scale * quantity.bc, b = scale * (quantity.be + quantity.bc), e = -scale * quantity.be
        let equivalent = scale * polarity * (quantity.be * voltageVbe(state: state)
            + quantity.bc * voltageVbc(state: state) - quantity.value)
        guard c.isFinite, b.isFinite, e.isFinite, equivalent.isFinite else {
            throw invalid("linearization", "BJT linearized current and Jacobian must be finite")
        }
        if let sv = stamper.stampValue, csr.0 != nil || csr.1 != nil || csr.2 != nil {
            if let index = csr.0 { sv(index, c) }; if let index = csr.1 { sv(index, b) }; if let index = csr.2 { sv(index, e) }
        } else {
            if let collectorIdx { stamper.stampMatrix(row, collectorIdx, c) }
            if let baseIdx { stamper.stampMatrix(row, baseIdx, b) }
            if let emitterIdx { stamper.stampMatrix(row, emitterIdx, e) }
        }
        stamper.stampRHS(row, equivalent)
    }

    public func stampAC(into stamper: inout ComplexMatrixStamper, state: SolutionState, omega: Double) throws {
        guard omega.isFinite else { throw invalid("omega", "BJT frequency must be finite") }
        let op = try evaluate(state)
        for element in series { stamper.stampAdmittance(node1: element.external, node2: element.intrinsic,
            real: element.conductance, imag: 0) }
        try stampACRow(op.collector, row: collectorIdx, imaginary: false, scale: 1, into: &stamper)
        try stampACRow(op.base, row: baseIdx, imaginary: false, scale: 1, into: &stamper)
        try stampACRow(op.emitter, row: emitterIdx, imaginary: false, scale: 1, into: &stamper)
        try stampACRow(op.beCharge, row: baseIdx, imaginary: true, scale: omega, into: &stamper)
        try stampACRow(op.beCharge, row: emitterIdx, imaginary: true, scale: -omega, into: &stamper)
        try stampACRow(op.bcCharge, row: baseIdx, imaginary: true, scale: omega, into: &stamper)
        try stampACRow(op.bcCharge, row: collectorIdx, imaginary: true, scale: -omega, into: &stamper)
    }

    private func stampACRow(_ quantity: BJTModelEvaluation.Quantity, row: Int?, imaginary: Bool,
        scale: Double, into stamper: inout ComplexMatrixStamper) throws {
        guard let row else { return }
        func stamp(_ column: Int?, _ value: Double) throws {
            guard value.isFinite else { throw invalid("admittance", "BJT admittance must be finite") }
            guard let column else { return }
            stamper.stampMatrix(row, column, imaginary ? 0 : value, imaginary ? value : 0)
        }
        try stamp(collectorIdx, -scale * quantity.bc)
        try stamp(baseIdx, scale * (quantity.be + quantity.bc))
        try stamp(emitterIdx, -scale * quantity.be)
    }

    public func stampTransient(into stamper: inout MatrixStamper, state: SolutionState,
        integration: IntegrationState) throws {
        let op = try evaluate(state), previous = try evaluate(state.checkedPreviousSnapshot())
        try validate(integration)
        let stored = history.snapshot
        let be = chargeCurrent(op.beCharge, old: previous.beCharge, accepted: stored.beCurrent, integration: integration)
        let bc = chargeCurrent(op.bcCharge, old: previous.bcCharge, accepted: stored.bcCurrent, integration: integration)
        try validate(be); try validate(bc)
        for element in series { element.stamp(into: &stamper) }
        try stampCurrentRows(op, state: state, into: &stamper)
        try stampRow(be, row: baseIdx, csr: (csrIndices.bc, csrIndices.bb, csrIndices.be), state: state, into: &stamper)
        try stampRow(be, row: emitterIdx, csr: (csrIndices.ec, csrIndices.eb, csrIndices.ee), state: state, scale: -1, into: &stamper)
        try stampRow(bc, row: baseIdx, csr: (csrIndices.bc, csrIndices.bb, csrIndices.be), state: state, into: &stamper)
        try stampRow(bc, row: collectorIdx, csr: (csrIndices.cc, csrIndices.cb, csrIndices.ce), state: state, scale: -1, into: &stamper)
    }

    private func chargeCurrent(_ charge: BJTModelEvaluation.Quantity, old: BJTModelEvaluation.Quantity,
        accepted: Double, integration: IntegrationState) -> BJTModelEvaluation.Quantity {
        let difference = chargeDifference(charge, old: old, integration: integration)
        return .init(value: difference.value - (integration.method == .trapezoidal ? accepted : 0),
            be: difference.be, bc: difference.bc)
    }
    private func chargeDifference(_ charge: BJTModelEvaluation.Quantity, old: BJTModelEvaluation.Quantity,
        integration: IntegrationState) -> BJTModelEvaluation.Quantity {
        .init(value: integration.coefficient * (charge.value - old.value),
            be: integration.coefficient * charge.be, bc: integration.coefficient * charge.bc)
    }
    private func validate(_ integration: IntegrationState) throws {
        guard integration.timeStep.isFinite, integration.timeStep > 0, integration.coefficient.isFinite else {
            throw invalid("timeStep", "BJT charge integration requires a finite positive timestep and coefficient")
        }
    }
    private func validate(_ value: BJTModelEvaluation.Quantity) throws {
        guard value.value.isFinite, value.be.isFinite, value.bc.isFinite else {
            throw invalid("chargeCurrent", "BJT integrated charge and derivatives must be finite")
        }
    }
    private func invalid(_ parameter: String, _ message: String) -> DeviceBindingError {
        .invalidParameterValue(device: instance.name, parameter: parameter, message: message)
    }

    public func beginTransientSession(initialState: SolutionState) throws {
        _ = try evaluate(initialState)
        try history.begin(device: instance.name)
    }
    public func endTransientSession() { history.end() }
    public func commitTransientStep(state: SolutionState, integration: IntegrationState) throws {
        let generation = history.snapshot.generation
        let op = try evaluate(state), previous = try evaluate(state.checkedPreviousSnapshot())
        try validate(integration)
        try history.update(expectedGeneration: generation, device: instance.name) {
            let be = chargeCurrent(op.beCharge, old: previous.beCharge, accepted: $0.beCurrent, integration: integration)
            let bc = chargeCurrent(op.bcCharge, old: previous.bcCharge, accepted: $0.bcCurrent, integration: integration)
            try validate(be); try validate(bc)
            $0.beCurrent = be.value; $0.bcCurrent = bc.value
        }
    }

    public func accumulatePhysicalResidual(state: SolutionState, add: (Int, Double) -> Void) throws {
        let op = try evaluate(state)
        try accumulateStaticResidual(op, state: state, add: add)
    }
    private func accumulateStaticResidual(_ op: BJTModelEvaluation, state: SolutionState,
        add: (Int, Double) -> Void) throws {
        if let collectorIdx { add(collectorIdx, polarity * op.collector.value) }
        if let baseIdx { add(baseIdx, polarity * op.base.value) }
        if let emitterIdx { add(emitterIdx, polarity * op.emitter.value) }
        for element in series {
            let external = try state.checkedVoltage(at: element.external)
            let intrinsic = try state.checkedVoltage(at: element.intrinsic)
            let current = element.conductance * (external - intrinsic)
            guard current.isFinite else { throw invalid("seriesCurrent", "BJT series current must be finite") }
            if let index = element.externalIndex { add(index, current) }
            add(element.intrinsicIndex, -current)
        }
    }
    public func accumulateTransientPhysicalResidual(state: SolutionState, integration: IntegrationState,
        add: (Int, Double) -> Void) throws {
        let op = try evaluate(state), previous = try evaluate(state.checkedPreviousSnapshot())
        try validate(integration)
        let stored = history.snapshot
        let be = chargeCurrent(op.beCharge, old: previous.beCharge, accepted: stored.beCurrent, integration: integration)
        let bc = chargeCurrent(op.bcCharge, old: previous.bcCharge, accepted: stored.bcCurrent, integration: integration)
        try validate(be); try validate(bc)
        try accumulatePhysicalResidual(state: state, add: add)
        if let baseIdx { add(baseIdx, polarity * (be.value + bc.value)) }
        if let emitterIdx { add(emitterIdx, -polarity * be.value) }
        if let collectorIdx { add(collectorIdx, -polarity * bc.value) }
    }
    public func checkConvergence(state: SolutionState, previousState: SolutionState) -> ConvergenceResult {
        let delta = max(abs(voltageVbe(state: state) - voltageVbe(state: previousState)),
            abs(voltageVbc(state: state) - voltageVbc(state: previousState)))
        return delta < 1e-6 ? .converged : .notConverged(maxDelta: delta, deviceName: instance.name)
    }
    public func noiseContributions(state: SolutionState, frequency: Double) throws -> [NoiseSource] {
        guard frequency.isFinite, frequency > 0 else { throw invalid("frequency", "BJT noise frequency must be finite and positive") }
        let op = try evaluate(state)
        var sources: [NoiseSource] = []
        let collectorShot = 2 * 1.6021766208e-19 * abs(op.collector.value)
        let baseShot = 2 * 1.6021766208e-19 * abs(op.base.value)
        if collectorShot > 0 { sources.append(NoiseSource(name: "\(instance.name)_collector_shot",
            positiveNode: collector, negativeNode: emitter, currentSpectralDensity: collectorShot)) }
        if baseShot > 0 { sources.append(NoiseSource(name: "\(instance.name)_base_shot",
            positiveNode: base, negativeNode: emitter, currentSpectralDensity: baseShot)) }
        for (offset, element) in series.enumerated() {
            let density = 4 * 1.38064852e-23 * parameters.operatingTemperature * element.conductance
            guard density.isFinite else { throw invalid("thermalNoise", "BJT thermal noise must be finite") }
            sources.append(NoiseSource(name: "\(instance.name)_series_\(offset)_thermal",
                positiveNode: element.external, negativeNode: element.intrinsic, currentSpectralDensity: density))
        }
        return sources
    }

    public var limitsFirstIteration: Bool { true }

    public func limitVoltages(solution: inout [Double], previousSolution: [Double]) {
        let nfVt = parameters.forwardEmissionCoefficient * parameters.thermalVoltage
        let nrVt = parameters.reverseEmissionCoefficient * parameters.thermalVoltage
        let isat = parameters.saturationCurrent
        let isNPN = parameters.polarity == .npn

        let vbNew = baseIdx.map { solution[$0] } ?? 0.0
        let vcNew = collectorIdx.map { solution[$0] } ?? 0.0
        let veNew = emitterIdx.map { solution[$0] } ?? 0.0

        let vbOld = baseIdx.map { previousSolution[$0] } ?? 0.0
        let vcOld = collectorIdx.map { previousSolution[$0] } ?? 0.0
        let veOld = emitterIdx.map { previousSolution[$0] } ?? 0.0

        // Compute junction voltages accounting for polarity
        let vbeNew: Double
        let vbeOld: Double
        let vbcNew: Double
        let vbcOld: Double

        if isNPN {
            vbeNew = vbNew - veNew
            vbeOld = vbOld - veOld
            vbcNew = vbNew - vcNew
            vbcOld = vbOld - vcOld
        } else {
            vbeNew = veNew - vbNew
            vbeOld = veOld - vbOld
            vbcNew = vcNew - vbNew
            vbcOld = vcOld - vbOld
        }

        // Limit BE junction
        let vbeLimited = PNJunctionLimiter.limit(vNew: vbeNew, vOld: vbeOld, vt: nfVt, isat: isat)
        // Limit BC junction
        let vbcLimited = PNJunctionLimiter.limit(vNew: vbcNew, vOld: vbcOld, vt: nrVt, isat: isat)

        let beCorrection = vbeLimited - vbeNew
        let bcCorrection = vbcLimited - vbcNew

        if beCorrection != 0 || bcCorrection != 0 {
            if baseIdx == nil {
                // Grounded base fixes the reference; move the other junction terminals.
                let polarity = isNPN ? 1.0 : -1.0
                if let eIdx = emitterIdx {
                    solution[eIdx] -= polarity * beCorrection
                }
                if let cIdx = collectorIdx {
                    solution[cIdx] -= polarity * bcCorrection
                }
                return
            }
            if collectorIdx == nil, let bIdx = baseIdx {
                let polarity = isNPN ? 1.0 : -1.0
                if let eIdx = emitterIdx {
                    // Grounded collector fixes BC; preserve the requested BE correction through E.
                    solution[bIdx] += polarity * bcCorrection
                    solution[eIdx] += polarity * (bcCorrection - beCorrection)
                } else {
                    // Both fixed terminals share one base coordinate; either active rule must reject the probe.
                    solution[bIdx] += polarity * (beCorrection != 0 ? beCorrection : bcCorrection)
                }
                return
            }
            // Fix emitter node, adjust base and collector to achieve
            // the desired junction voltage corrections exactly.
            //
            // NPN: Vbe = Vb - Ve, Vbc = Vb - Vc
            //   ΔVb = beCorrection
            //   ΔVc = beCorrection - bcCorrection
            //
            // PNP: Vbe = Ve - Vb, Vbc = Vc - Vb
            //   ΔVb = -beCorrection
            //   ΔVc = bcCorrection - beCorrection
            if isNPN {
                if let bIdx = baseIdx {
                    solution[bIdx] += beCorrection
                }
                if let cIdx = collectorIdx {
                    solution[cIdx] += beCorrection - bcCorrection
                }
            } else {
                if let bIdx = baseIdx {
                    solution[bIdx] -= beCorrection
                }
                if let cIdx = collectorIdx {
                    solution[cIdx] += bcCorrection - beCorrection
                }
            }
        }
    }

}

extension BoundBJT: TransientPhysicalEquationDecomposing {
    public var transientPhysicalEquationForm: TransientPhysicalEquationForm { .chargeDifference }
    public func validateTransientPhysicalEquationDecomposition() throws {
        // Checked binding admits the complete low-injection GP static and charge kernel.
    }
    public func accumulateTransientStaticResidual(state: SolutionState, time: Double,
        add: (Int, Double) -> Void) throws {
        try PhysicalResidualState.validate(time)
        try accumulatePhysicalResidual(state: state, add: add)
    }
    public func accumulateTransientPhysicalEquation(state: SolutionState, integration: IntegrationState,
        add: (Int, TransientPhysicalEquationTerm, Double) -> Void) throws {
        try PhysicalResidualState.validate(integration.currentTime)
        try validate(integration)
        let op = try evaluate(state), previous = try evaluate(state.checkedPreviousSnapshot())
        let be = chargeDifference(op.beCharge, old: previous.beCharge, integration: integration)
        let bc = chargeDifference(op.bcCharge, old: previous.bcCharge, integration: integration)
        try validate(be); try validate(bc)
        let baseCharge = polarity * (be.value + bc.value)
        try PhysicalResidualState.validate(baseCharge)
        try accumulateStaticResidual(op, state: state) { add($0, .staticResidual, $1) }
        if let baseIdx { add(baseIdx, .chargeDifference, baseCharge) }
        if let emitterIdx { add(emitterIdx, .chargeDifference, -polarity * be.value) }
        if let collectorIdx { add(collectorIdx, .chargeDifference, -polarity * bc.value) }
    }
}
