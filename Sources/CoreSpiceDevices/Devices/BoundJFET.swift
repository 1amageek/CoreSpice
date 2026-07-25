import Foundation
import CoreSpiceIR

/// A Shichman-Hodges JFET bound to circuit nodes.
public struct BoundJFET: BoundDevice, VoltageLimitingDevice, TransientStateCommittingDevice, NoisyDevice, Sendable {

    public let instance: Instance
    private let drain: Node
    private let gate: Node
    private let source: Node
    private let parameters: JFETModelParameters
    private let drainIdx: Int?
    private let gateIdx: Int?
    private let sourceIdx: Int?
    private let capacitanceStore: TransientCapacitanceStore

    private static let voltageTolerance: Double = 1e-6
    private static let minGds: Double = 1e-12
    private static let smoothDelta: Double = 0.025
    private static let maxExpArg: Double = 40.0
    private static let gmin: Double = 1e-12

    init(
        instance: Instance,
        drain: Node,
        gate: Node,
        source: Node,
        parameters: JFETModelParameters,
        drainIdx: Int?,
        gateIdx: Int?,
        sourceIdx: Int?
    ) {
        self.instance = instance
        self.drain = drain
        self.gate = gate
        self.source = source
        self.parameters = parameters
        self.drainIdx = drainIdx
        self.gateIdx = gateIdx
        self.sourceIdx = sourceIdx
        self.capacitanceStore = TransientCapacitanceStore()
    }

    public func stampDC(into stamper: inout MatrixStamper, state: SolutionState) {
        let point = operatingPoint(state: state)
        stampChannel(into: &stamper, point: point.channel)
        stampJunction(into: &stamper, junction: point.gateSource, terminalIdx: sourceIdx)
        stampJunction(into: &stamper, junction: point.gateDrain, terminalIdx: drainIdx)
    }

    public func stampAC(into stamper: inout ComplexMatrixStamper, state: SolutionState, omega: Double) {
        let point = operatingPoint(state: state)
        stampChannel(into: &stamper, point: point.channel)
        stampJunction(into: &stamper, junction: point.gateSource, terminalIdx: sourceIdx)
        stampJunction(into: &stamper, junction: point.gateDrain, terminalIdx: drainIdx)
        stampCapacitance(into: &stamper, node1: gateIdx, node2: sourceIdx, capacitance: gateSourceCapacitance(state: state), omega: omega)
        stampCapacitance(into: &stamper, node1: gateIdx, node2: drainIdx, capacitance: gateDrainCapacitance(state: state), omega: omega)
    }

    public func stampTransient(
        into stamper: inout MatrixStamper,
        state: SolutionState,
        integration: IntegrationState
    ) {
        stampDC(into: &stamper, state: state)
        capacitanceStore.stamp(
            key: "cgs",
            into: &stamper,
            node1: gateIdx,
            node2: sourceIdx,
            capacitance: gateSourceCapacitance(state: state),
            state: state,
            integration: integration
        )
        capacitanceStore.stamp(
            key: "cgd",
            into: &stamper,
            node1: gateIdx,
            node2: drainIdx,
            capacitance: gateDrainCapacitance(state: state),
            state: state,
            integration: integration
        )
    }

    public func commitTransientStep(state: SolutionState, integration: IntegrationState) {
        capacitanceStore.commit(
            key: "cgs",
            node1: gateIdx,
            node2: sourceIdx,
            capacitance: gateSourceCapacitance(state: state),
            state: state,
            integration: integration
        )
        capacitanceStore.commit(
            key: "cgd",
            node1: gateIdx,
            node2: drainIdx,
            capacitance: gateDrainCapacitance(state: state),
            state: state,
            integration: integration
        )
    }

    public func checkConvergence(state: SolutionState, previousState: SolutionState) -> ConvergenceResult {
        let current = convergenceVoltages(state: state)
        let previous = convergenceVoltages(state: previousState)
        let maxDelta = max(
            abs(current.vgs - previous.vgs),
            max(abs(current.vds - previous.vds), abs(current.vgd - previous.vgd))
        )
        if maxDelta < Self.voltageTolerance {
            return .converged
        }
        return .notConverged(maxDelta: maxDelta, deviceName: instance.name)
    }

    public var limitsFirstIteration: Bool { true }

    public func limitVoltages(solution: inout [Double], previousSolution: [Double]) {
        limitJunctionVoltage(terminalIdx: sourceIdx, solution: &solution, previousSolution: previousSolution)
        limitJunctionVoltage(terminalIdx: drainIdx, solution: &solution, previousSolution: previousSolution)
    }

    public func noiseContributions(state: SolutionState, frequency: Double) -> [NoiseSource] {
        _ = frequency
        let point = operatingPoint(state: state)
        let effectiveDrain = point.channel.reversed ? source : drain
        let effectiveSource = point.channel.reversed ? drain : source
        var sources = MOSFETNoiseModel.channelThermalNoiseSource(
            instanceName: instance.name,
            positiveNode: effectiveDrain,
            negativeNode: effectiveSource,
            gm: point.channel.gm,
            gds: point.channel.gds,
            temperatureKelvin: parameters.operatingTemperature
        )

        let q = 1.602176634e-19
        let gateSourceDensity = 2.0 * q * abs(point.gateSource.current)
        if gateSourceDensity > 0 {
            sources.append(NoiseSource(
                name: "\(instance.name)_gate_source_shot",
                positiveNode: gate,
                negativeNode: source,
                currentSpectralDensity: gateSourceDensity
            ))
        }
        let gateDrainDensity = 2.0 * q * abs(point.gateDrain.current)
        if gateDrainDensity > 0 {
            sources.append(NoiseSource(
                name: "\(instance.name)_gate_drain_shot",
                positiveNode: gate,
                negativeNode: drain,
                currentSpectralDensity: gateDrainDensity
            ))
        }
        if parameters.flickerNoiseCoefficient > 0 && frequency > 0 {
            let channelCurrent = abs(point.channel.current)
            let density = parameters.flickerNoiseCoefficient
                * pow(channelCurrent, parameters.flickerNoiseExponent)
                / frequency
            if density > 0 {
                sources.append(NoiseSource(
                    name: "\(instance.name)_flicker",
                    positiveNode: effectiveDrain,
                    negativeNode: effectiveSource,
                    currentSpectralDensity: density
                ))
            }
        }
        return sources
    }

    private struct OperatingPoint {
        let channel: ChannelPoint
        let gateSource: JunctionPoint
        let gateDrain: JunctionPoint
    }

    private struct ChannelPoint {
        let current: Double
        let gm: Double
        let gds: Double
        let vgs: Double
        let vds: Double
        let reversed: Bool
    }

    private struct JunctionPoint {
        let current: Double
        let conductance: Double
        let voltage: Double
    }

    private func operatingPoint(state: SolutionState) -> OperatingPoint {
        OperatingPoint(
            channel: channelPoint(state: state),
            gateSource: junctionPoint(gateVoltage: nodeVoltage(gateIdx, state), terminalVoltage: nodeVoltage(sourceIdx, state)),
            gateDrain: junctionPoint(gateVoltage: nodeVoltage(gateIdx, state), terminalVoltage: nodeVoltage(drainIdx, state))
        )
    }

    private func channelPoint(state: SolutionState) -> ChannelPoint {
        let sign = parameters.channelSign
        let drainVoltage = nodeVoltage(drainIdx, state)
        let gateVoltage = nodeVoltage(gateIdx, state)
        let sourceVoltage = nodeVoltage(sourceIdx, state)
        let reversed = sign * (drainVoltage - sourceVoltage) < 0.0

        let effectiveDrainVoltage = reversed ? sourceVoltage : drainVoltage
        let effectiveSourceVoltage = reversed ? drainVoltage : sourceVoltage
        let externalVds = effectiveDrainVoltage - effectiveSourceVoltage
        let externalVgs = gateVoltage - effectiveSourceVoltage
        let normalizedVds = sign * externalVds
        let normalizedVgs = sign * externalVgs

        let overdrive = smoothClamp(normalizedVgs - parameters.normalizedThresholdVoltage)
        let overdriveDerivative = smoothClampDerivative(normalizedVgs - parameters.normalizedThresholdVoltage)
        let beta = parameters.effectiveBeta
        let lambda = parameters.lambda
        let clm = 1.0 + lambda * normalizedVds

        let normalizedCurrent: Double
        let gm: Double
        let gds: Double

        if normalizedVds < overdrive {
            let channelCharge = 2.0 * overdrive * normalizedVds - normalizedVds * normalizedVds
            normalizedCurrent = beta * channelCharge * clm
            gm = 2.0 * beta * normalizedVds * clm * overdriveDerivative
            gds = beta * (2.0 * overdrive - 2.0 * normalizedVds) * clm + beta * channelCharge * lambda
        } else {
            normalizedCurrent = beta * overdrive * overdrive * clm
            gm = 2.0 * beta * overdrive * clm * overdriveDerivative
            gds = beta * overdrive * overdrive * lambda
        }

        return ChannelPoint(
            current: sign * normalizedCurrent,
            gm: gm,
            gds: max(gds, Self.minGds),
            vgs: externalVgs,
            vds: externalVds,
            reversed: reversed
        )
    }

    private func junctionPoint(gateVoltage: Double, terminalVoltage: Double) -> JunctionPoint {
        let voltage = gateVoltage - terminalVoltage
        let sign = parameters.channelSign
        let normalizedVoltage = sign * voltage
        let nvt = parameters.emissionCoefficient * parameters.thermalVoltage
        let isat = parameters.effectiveSaturationCurrent

        let normalizedCurrent: Double
        let conductance: Double
        if normalizedVoltage >= -5.0 * nvt {
            let expArg = min(normalizedVoltage / nvt, Self.maxExpArg)
            let expValue = exp(expArg)
            normalizedCurrent = isat * (expValue - 1.0)
            conductance = isat / nvt * expValue + Self.gmin
        } else {
            normalizedCurrent = -isat
            conductance = isat / nvt + Self.gmin
        }

        return JunctionPoint(
            current: sign * normalizedCurrent,
            conductance: conductance,
            voltage: voltage
        )
    }

    private func stampChannel(into stamper: inout MatrixStamper, point: ChannelPoint) {
        let dIdx = point.reversed ? sourceIdx : drainIdx
        let sIdx = point.reversed ? drainIdx : sourceIdx
        let gIdx = gateIdx

        if let dIdx {
            stamper.stampMatrix(dIdx, dIdx, point.gds)
        }
        if let sIdx {
            stamper.stampMatrix(sIdx, sIdx, point.gds + point.gm)
        }
        if let dIdx, let sIdx {
            stamper.stampMatrix(dIdx, sIdx, -point.gds - point.gm)
            stamper.stampMatrix(sIdx, dIdx, -point.gds)
        }
        if let dIdx, let gIdx {
            stamper.stampMatrix(dIdx, gIdx, point.gm)
        }
        if let sIdx, let gIdx {
            stamper.stampMatrix(sIdx, gIdx, -point.gm)
        }

        let ieq = point.current - point.gm * point.vgs - point.gds * point.vds
        if let dIdx {
            stamper.stampRHS(dIdx, -ieq)
        }
        if let sIdx {
            stamper.stampRHS(sIdx, ieq)
        }
    }

    private func stampChannel(into stamper: inout ComplexMatrixStamper, point: ChannelPoint) {
        let dIdx = point.reversed ? sourceIdx : drainIdx
        let sIdx = point.reversed ? drainIdx : sourceIdx
        let gIdx = gateIdx

        if let dIdx {
            stamper.stampMatrix(dIdx, dIdx, point.gds, 0.0)
        }
        if let sIdx {
            stamper.stampMatrix(sIdx, sIdx, point.gds + point.gm, 0.0)
        }
        if let dIdx, let sIdx {
            stamper.stampMatrix(dIdx, sIdx, -point.gds - point.gm, 0.0)
            stamper.stampMatrix(sIdx, dIdx, -point.gds, 0.0)
        }
        if let dIdx, let gIdx {
            stamper.stampMatrix(dIdx, gIdx, point.gm, 0.0)
        }
        if let sIdx, let gIdx {
            stamper.stampMatrix(sIdx, gIdx, -point.gm, 0.0)
        }
    }

    private func stampJunction(into stamper: inout MatrixStamper, junction: JunctionPoint, terminalIdx: Int?) {
        let gIdx = gateIdx
        if let gIdx {
            stamper.stampMatrix(gIdx, gIdx, junction.conductance)
        }
        if let terminalIdx {
            stamper.stampMatrix(terminalIdx, terminalIdx, junction.conductance)
        }
        if let gIdx, let terminalIdx {
            stamper.stampMatrix(gIdx, terminalIdx, -junction.conductance)
            stamper.stampMatrix(terminalIdx, gIdx, -junction.conductance)
        }

        let ieq = junction.current - junction.conductance * junction.voltage
        if let gIdx {
            stamper.stampRHS(gIdx, -ieq)
        }
        if let terminalIdx {
            stamper.stampRHS(terminalIdx, ieq)
        }
    }

    private func stampJunction(into stamper: inout ComplexMatrixStamper, junction: JunctionPoint, terminalIdx: Int?) {
        let gIdx = gateIdx
        if let gIdx {
            stamper.stampMatrix(gIdx, gIdx, junction.conductance, 0.0)
        }
        if let terminalIdx {
            stamper.stampMatrix(terminalIdx, terminalIdx, junction.conductance, 0.0)
        }
        if let gIdx, let terminalIdx {
            stamper.stampMatrix(gIdx, terminalIdx, -junction.conductance, 0.0)
            stamper.stampMatrix(terminalIdx, gIdx, -junction.conductance, 0.0)
        }
    }

    private func stampCapacitance(
        into stamper: inout ComplexMatrixStamper,
        node1: Int?,
        node2: Int?,
        capacitance: Double,
        omega: Double
    ) {
        guard capacitance > 0 else { return }
        let susceptance = omega * capacitance
        if let node1 {
            stamper.stampMatrix(node1, node1, 0.0, susceptance)
        }
        if let node2 {
            stamper.stampMatrix(node2, node2, 0.0, susceptance)
        }
        if let node1, let node2 {
            stamper.stampMatrix(node1, node2, 0.0, -susceptance)
            stamper.stampMatrix(node2, node1, 0.0, -susceptance)
        }
    }

    private func gateSourceCapacitance(state: SolutionState) -> Double {
        let voltage = parameters.channelSign * (nodeVoltage(gateIdx, state) - nodeVoltage(sourceIdx, state))
        return junctionCapacitance(zeroBiasCapacitance: parameters.effectiveGateSourceCapacitance, voltage: voltage)
    }

    private func gateDrainCapacitance(state: SolutionState) -> Double {
        let voltage = parameters.channelSign * (nodeVoltage(gateIdx, state) - nodeVoltage(drainIdx, state))
        return junctionCapacitance(zeroBiasCapacitance: parameters.effectiveGateDrainCapacitance, voltage: voltage)
    }

    private func junctionCapacitance(zeroBiasCapacitance: Double, voltage: Double) -> Double {
        guard zeroBiasCapacitance > 0 else { return 0 }
        let potential = parameters.gateJunctionPotential
        let grading = parameters.gateJunctionGradingCoefficient
        let forwardCoefficient = parameters.forwardBiasDepletionCoefficient
        let forwardVoltage = forwardCoefficient * potential
        if voltage < forwardVoltage {
            return zeroBiasCapacitance / pow(1.0 - voltage / potential, grading)
        }

        let base = zeroBiasCapacitance / pow(1.0 - forwardCoefficient, grading)
        let slope = base * grading / (potential * (1.0 - forwardCoefficient))
        return base + slope * (voltage - forwardVoltage)
    }

    private func limitJunctionVoltage(
        terminalIdx: Int?,
        solution: inout [Double],
        previousSolution: [Double]
    ) {
        guard let gateIdx else { return }
        let sign = parameters.channelSign
        let gateVoltage = solution[gateIdx]
        let terminalVoltage = terminalIdx.map { solution[$0] } ?? 0.0
        let oldGateVoltage = previousSolution[gateIdx]
        let oldTerminalVoltage = terminalIdx.map { previousSolution[$0] } ?? 0.0
        let normalizedNew = sign * (gateVoltage - terminalVoltage)
        let normalizedOld = sign * (oldGateVoltage - oldTerminalVoltage)
        let limited = PNJunctionLimiter.limit(
            vNew: normalizedNew,
            vOld: normalizedOld,
            vt: parameters.emissionCoefficient * parameters.thermalVoltage,
            isat: parameters.effectiveSaturationCurrent
        )
        if limited != normalizedNew {
            solution[gateIdx] += sign * (limited - normalizedNew)
        }
    }

    private func convergenceVoltages(state: SolutionState) -> (vgs: Double, vds: Double, vgd: Double) {
        let sign = parameters.channelSign
        let gateVoltage = nodeVoltage(gateIdx, state)
        let sourceVoltage = nodeVoltage(sourceIdx, state)
        let drainVoltage = nodeVoltage(drainIdx, state)
        return (
            vgs: sign * (gateVoltage - sourceVoltage),
            vds: sign * (drainVoltage - sourceVoltage),
            vgd: sign * (gateVoltage - drainVoltage)
        )
    }

    private func nodeVoltage(_ index: Int?, _ state: SolutionState) -> Double {
        if let index {
            return state.value(at: index)
        }
        return 0.0
    }

    private func smoothClamp(_ value: Double) -> Double {
        0.5 * (value + sqrt(value * value + Self.smoothDelta * Self.smoothDelta))
    }

    private func smoothClampDerivative(_ value: Double) -> Double {
        0.5 * (1.0 + value / sqrt(value * value + Self.smoothDelta * Self.smoothDelta))
    }
}
