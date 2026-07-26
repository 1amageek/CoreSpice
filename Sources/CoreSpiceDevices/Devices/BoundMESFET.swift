import CoreSpiceIR
import Foundation

/// A SPICE Curtice MESFET bound to circuit nodes and matrix indices.
public struct BoundMESFET: BoundDevice, VoltageLimitingDevice, TransientStateCommittingDevice, NoisyDevice, Sendable {
    public let instance: Instance

    private let drain: Node
    private let gate: Node
    private let source: Node
    private let parameters: MESFETModelParameters
    private let drainIdx: Int?
    private let gateIdx: Int?
    private let sourceIdx: Int?
    private let capacitanceStore: TransientCapacitanceStore

    private static let voltageTolerance = 1e-6
    private static let minimumOutputConductance = 1e-12
    private static let maximumExponentialArgument = 40.0
    private static let minimumJunctionConductance = 1e-12

    init(
        instance: Instance,
        drain: Node,
        gate: Node,
        source: Node,
        parameters: MESFETModelParameters,
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
        stampJunction(into: &stamper, point: point.gateSource, terminalIdx: sourceIdx)
        stampJunction(into: &stamper, point: point.gateDrain, terminalIdx: drainIdx)
    }

    public func stampAC(
        into stamper: inout ComplexMatrixStamper,
        state: SolutionState,
        omega: Double
    ) {
        let point = operatingPoint(state: state)
        let capacitances = gateCapacitances(state: state)
        stampChannel(into: &stamper, point: point.channel)
        stampJunction(into: &stamper, point: point.gateSource, terminalIdx: sourceIdx)
        stampJunction(into: &stamper, point: point.gateDrain, terminalIdx: drainIdx)
        stampCapacitance(
            into: &stamper,
            node1: gateIdx,
            node2: sourceIdx,
            capacitance: capacitances.source,
            omega: omega
        )
        stampCapacitance(
            into: &stamper,
            node1: gateIdx,
            node2: drainIdx,
            capacitance: capacitances.drain,
            omega: omega
        )
    }

    public func stampTransient(
        into stamper: inout MatrixStamper,
        state: SolutionState,
        integration: IntegrationState
    ) {
        stampDC(into: &stamper, state: state)
        let capacitances = gateCapacitances(state: state)
        capacitanceStore.stamp(
            key: "cgs",
            into: &stamper,
            node1: gateIdx,
            node2: sourceIdx,
            capacitance: capacitances.source,
            state: state,
            integration: integration
        )
        capacitanceStore.stamp(
            key: "cgd",
            into: &stamper,
            node1: gateIdx,
            node2: drainIdx,
            capacitance: capacitances.drain,
            state: state,
            integration: integration
        )
    }

    public func commitTransientStep(state: SolutionState, integration: IntegrationState) {
        let capacitances = gateCapacitances(state: state)
        capacitanceStore.commit(
            key: "cgs",
            node1: gateIdx,
            node2: sourceIdx,
            capacitance: capacitances.source,
            state: state,
            integration: integration
        )
        capacitanceStore.commit(
            key: "cgd",
            node1: gateIdx,
            node2: drainIdx,
            capacitance: capacitances.drain,
            state: state,
            integration: integration
        )
    }

    public func checkConvergence(
        state: SolutionState,
        previousState: SolutionState
    ) -> ConvergenceResult {
        let current = normalizedVoltages(state: state)
        let previous = normalizedVoltages(state: previousState)
        let maximumDelta = max(
            abs(current.vgs - previous.vgs),
            max(abs(current.vgd - previous.vgd), abs(current.vds - previous.vds))
        )
        guard maximumDelta >= Self.voltageTolerance else {
            return .converged
        }
        return .notConverged(maxDelta: maximumDelta, deviceName: instance.name)
    }

    public var limitsFirstIteration: Bool { true }

    public func limitVoltages(solution: inout [Double], previousSolution: [Double]) {
        limitJunctionVoltage(
            terminalIdx: sourceIdx,
            solution: &solution,
            previousSolution: previousSolution
        )
        limitJunctionVoltage(
            terminalIdx: drainIdx,
            solution: &solution,
            previousSolution: previousSolution
        )
    }

    public func noiseContributions(
        state: SolutionState,
        frequency: Double
    ) -> [NoiseSource] {
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

        let electronCharge = 1.602176634e-19
        appendShotNoise(
            name: "\(instance.name)_gate_source_shot",
            positiveNode: gate,
            negativeNode: source,
            current: point.gateSource.current,
            electronCharge: electronCharge,
            into: &sources
        )
        appendShotNoise(
            name: "\(instance.name)_gate_drain_shot",
            positiveNode: gate,
            negativeNode: drain,
            current: point.gateDrain.current,
            electronCharge: electronCharge,
            into: &sources
        )
        if parameters.flickerNoiseCoefficient > 0, frequency > 0 {
            let density = parameters.flickerNoiseCoefficient
                * pow(abs(point.channel.current), parameters.flickerNoiseExponent)
                / frequency
            if density > 0 {
                sources.append(
                    NoiseSource(
                        name: "\(instance.name)_flicker",
                        positiveNode: effectiveDrain,
                        negativeNode: effectiveSource,
                        currentSpectralDensity: density
                    )
                )
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
            gateSource: junctionPoint(
                gateVoltage: nodeVoltage(gateIdx, state),
                terminalVoltage: nodeVoltage(sourceIdx, state)
            ),
            gateDrain: junctionPoint(
                gateVoltage: nodeVoltage(gateIdx, state),
                terminalVoltage: nodeVoltage(drainIdx, state)
            )
        )
    }

    private func channelPoint(state: SolutionState) -> ChannelPoint {
        let sign = parameters.channelSign
        let drainVoltage = nodeVoltage(drainIdx, state)
        let gateVoltage = nodeVoltage(gateIdx, state)
        let sourceVoltage = nodeVoltage(sourceIdx, state)
        let reversed = sign * (drainVoltage - sourceVoltage) < 0
        let effectiveDrainVoltage = reversed ? sourceVoltage : drainVoltage
        let effectiveSourceVoltage = reversed ? drainVoltage : sourceVoltage
        let externalVds = effectiveDrainVoltage - effectiveSourceVoltage
        let externalVgs = gateVoltage - effectiveSourceVoltage
        let normalizedVds = sign * externalVds
        let normalizedVgs = sign * externalVgs
        let overdrive = normalizedVgs - parameters.thresholdVoltage

        guard overdrive > 0 else {
            return ChannelPoint(
                current: 0,
                gm: 0,
                gds: Self.minimumOutputConductance,
                vgs: externalVgs,
                vds: externalVds,
                reversed: reversed
            )
        }

        let beta = parameters.effectiveBeta
        let modulation = 1 + parameters.lambda * normalizedVds
        let denominator = 1 + parameters.dopingTailParameter * overdrive
        let inverseDenominator = 1 / denominator
        let saturated = normalizedVds >= 3 / parameters.alpha
        let transition: Double
        let transitionDerivative: Double
        if saturated {
            transition = 1
            transitionDerivative = 0
        } else {
            let factor = 1 - parameters.alpha * normalizedVds / 3
            transition = 1 - factor * factor * factor
            transitionDerivative = parameters.alpha * factor * factor
        }

        let overdriveSquared = overdrive * overdrive
        let normalizedCurrent = beta * modulation * overdriveSquared
            * inverseDenominator * transition
        let gm = beta * modulation * overdrive
            * (1 + denominator) * inverseDenominator * inverseDenominator
            * transition
        let gds = beta * overdriveSquared * inverseDenominator
            * (parameters.lambda * transition + modulation * transitionDerivative)

        return ChannelPoint(
            current: sign * normalizedCurrent,
            gm: gm,
            gds: max(gds, Self.minimumOutputConductance),
            vgs: externalVgs,
            vds: externalVds,
            reversed: reversed
        )
    }

    private func junctionPoint(
        gateVoltage: Double,
        terminalVoltage: Double
    ) -> JunctionPoint {
        let voltage = gateVoltage - terminalVoltage
        let sign = parameters.channelSign
        let normalizedVoltage = sign * voltage
        let thermalVoltage = parameters.thermalVoltage
        let saturationCurrent = parameters.effectiveSaturationCurrent
        let normalizedCurrent: Double
        let conductance: Double
        if normalizedVoltage <= -3 * thermalVoltage {
            var tail = 3 * thermalVoltage
                / (normalizedVoltage * Foundation.exp(1))
            tail *= tail * tail
            normalizedCurrent = -saturationCurrent * (1 + tail)
                + Self.minimumJunctionConductance * normalizedVoltage
            conductance = saturationCurrent * 3 * tail / normalizedVoltage
                + Self.minimumJunctionConductance
        } else {
            let exponential = exp(
                min(normalizedVoltage / thermalVoltage, Self.maximumExponentialArgument)
            )
            normalizedCurrent = saturationCurrent * (exponential - 1)
                + Self.minimumJunctionConductance * normalizedVoltage
            conductance = saturationCurrent / thermalVoltage * exponential
                + Self.minimumJunctionConductance
        }
        return JunctionPoint(
            current: sign * normalizedCurrent,
            conductance: conductance,
            voltage: voltage
        )
    }

    private func stampChannel(into stamper: inout MatrixStamper, point: ChannelPoint) {
        let effectiveDrainIdx = point.reversed ? sourceIdx : drainIdx
        let effectiveSourceIdx = point.reversed ? drainIdx : sourceIdx
        stampChannelMatrix(
            point: point,
            drainIdx: effectiveDrainIdx,
            sourceIdx: effectiveSourceIdx,
            stamp: { row, column, value in
                stamper.stampMatrix(row, column, value)
            }
        )
        let equivalentCurrent = point.current - point.gm * point.vgs - point.gds * point.vds
        if let effectiveDrainIdx {
            stamper.stampRHS(effectiveDrainIdx, -equivalentCurrent)
        }
        if let effectiveSourceIdx {
            stamper.stampRHS(effectiveSourceIdx, equivalentCurrent)
        }
    }

    private func stampChannel(
        into stamper: inout ComplexMatrixStamper,
        point: ChannelPoint
    ) {
        let effectiveDrainIdx = point.reversed ? sourceIdx : drainIdx
        let effectiveSourceIdx = point.reversed ? drainIdx : sourceIdx
        stampChannelMatrix(
            point: point,
            drainIdx: effectiveDrainIdx,
            sourceIdx: effectiveSourceIdx,
            stamp: { row, column, value in
                stamper.stampMatrix(row, column, value, 0)
            }
        )
    }

    private func stampChannelMatrix(
        point: ChannelPoint,
        drainIdx: Int?,
        sourceIdx: Int?,
        stamp: (Int, Int, Double) -> Void
    ) {
        if let drainIdx {
            stamp(drainIdx, drainIdx, point.gds)
        }
        if let sourceIdx {
            stamp(sourceIdx, sourceIdx, point.gds + point.gm)
        }
        if let drainIdx, let sourceIdx {
            stamp(drainIdx, sourceIdx, -point.gds - point.gm)
            stamp(sourceIdx, drainIdx, -point.gds)
        }
        if let drainIdx, let gateIdx {
            stamp(drainIdx, gateIdx, point.gm)
        }
        if let sourceIdx, let gateIdx {
            stamp(sourceIdx, gateIdx, -point.gm)
        }
    }

    private func stampJunction(
        into stamper: inout MatrixStamper,
        point: JunctionPoint,
        terminalIdx: Int?
    ) {
        stampJunctionMatrix(
            conductance: point.conductance,
            terminalIdx: terminalIdx
        ) { row, column, value in
            stamper.stampMatrix(row, column, value)
        }
        let equivalentCurrent = point.current - point.conductance * point.voltage
        if let gateIdx {
            stamper.stampRHS(gateIdx, -equivalentCurrent)
        }
        if let terminalIdx {
            stamper.stampRHS(terminalIdx, equivalentCurrent)
        }
    }

    private func stampJunction(
        into stamper: inout ComplexMatrixStamper,
        point: JunctionPoint,
        terminalIdx: Int?
    ) {
        stampJunctionMatrix(
            conductance: point.conductance,
            terminalIdx: terminalIdx
        ) { row, column, value in
            stamper.stampMatrix(row, column, value, 0)
        }
    }

    private func stampJunctionMatrix(
        conductance: Double,
        terminalIdx: Int?,
        stamp: (Int, Int, Double) -> Void
    ) {
        if let gateIdx {
            stamp(gateIdx, gateIdx, conductance)
        }
        if let terminalIdx {
            stamp(terminalIdx, terminalIdx, conductance)
        }
        if let gateIdx, let terminalIdx {
            stamp(gateIdx, terminalIdx, -conductance)
            stamp(terminalIdx, gateIdx, -conductance)
        }
    }

    private func stampCapacitance(
        into stamper: inout ComplexMatrixStamper,
        node1: Int?,
        node2: Int?,
        capacitance: Double,
        omega: Double
    ) {
        guard capacitance > 0 else {
            return
        }
        let susceptance = omega * capacitance
        if let node1 {
            stamper.stampMatrix(node1, node1, 0, susceptance)
        }
        if let node2 {
            stamper.stampMatrix(node2, node2, 0, susceptance)
        }
        if let node1, let node2 {
            stamper.stampMatrix(node1, node2, 0, -susceptance)
            stamper.stampMatrix(node2, node1, 0, -susceptance)
        }
    }

    private func gateCapacitances(
        state: SolutionState
    ) -> (source: Double, drain: Double) {
        let sign = parameters.channelSign
        let gateVoltage = nodeVoltage(gateIdx, state)
        let normalizedGateSource = sign
            * (gateVoltage - nodeVoltage(sourceIdx, state))
        let normalizedGateDrain = sign
            * (gateVoltage - nodeVoltage(drainIdx, state))
        let sourceZeroBias = parameters.effectiveGateSourceCapacitance
        let drainZeroBias = parameters.effectiveGateDrainCapacitance
        guard sourceZeroBias > 0 || drainZeroBias > 0 else {
            return (0, 0)
        }

        let smoothingVoltage = 1 / parameters.alpha
        let voltageDifference = normalizedGateSource - normalizedGateDrain
        let effectiveRoot = sqrt(
            voltageDifference * voltageDifference
                + smoothingVoltage * smoothingVoltage
        )
        let effectiveHigh = 0.5
            * (normalizedGateSource + normalizedGateDrain + effectiveRoot)
        let thresholdDelta = effectiveHigh - parameters.thresholdVoltage
        let thresholdRoot = sqrt(thresholdDelta * thresholdDelta + 0.04)
        let unclampedGateVoltage = 0.5
            * (effectiveHigh + parameters.thresholdVoltage + thresholdRoot)
        let gateVoltageForCharge = min(unclampedGateVoltage, 0.5)
        let chargeRoot = sqrt(
            1 - gateVoltageForCharge / parameters.gateJunctionPotential
        )
        let thresholdPartition = 0.5 * (1 + thresholdDelta / thresholdRoot)
        let drainSourcePartition = voltageDifference / effectiveRoot
        let sourcePartition = 0.5 * (1 + drainSourcePartition)
        let drainPartition = sourcePartition - drainSourcePartition

        return (
            sourceZeroBias / chargeRoot * thresholdPartition * sourcePartition
                + drainZeroBias * drainPartition,
            sourceZeroBias / chargeRoot * thresholdPartition * drainPartition
                + drainZeroBias * sourcePartition
        )
    }

    private func limitJunctionVoltage(
        terminalIdx: Int?,
        solution: inout [Double],
        previousSolution: [Double]
    ) {
        guard let gateIdx else {
            return
        }
        let sign = parameters.channelSign
        let terminalVoltage = terminalIdx.map { solution[$0] } ?? 0
        let previousTerminalVoltage = terminalIdx.map { previousSolution[$0] } ?? 0
        let normalizedVoltage = sign * (solution[gateIdx] - terminalVoltage)
        let previousNormalizedVoltage = sign
            * (previousSolution[gateIdx] - previousTerminalVoltage)
        let limited = PNJunctionLimiter.limit(
            vNew: normalizedVoltage,
            vOld: previousNormalizedVoltage,
            vt: parameters.thermalVoltage,
            isat: parameters.effectiveSaturationCurrent
        )
        if limited != normalizedVoltage {
            solution[gateIdx] += sign * (limited - normalizedVoltage)
        }
    }

    private func normalizedVoltages(
        state: SolutionState
    ) -> (vgs: Double, vgd: Double, vds: Double) {
        let sign = parameters.channelSign
        let drainVoltage = nodeVoltage(drainIdx, state)
        let gateVoltage = nodeVoltage(gateIdx, state)
        let sourceVoltage = nodeVoltage(sourceIdx, state)
        return (
            sign * (gateVoltage - sourceVoltage),
            sign * (gateVoltage - drainVoltage),
            sign * (drainVoltage - sourceVoltage)
        )
    }

    private func appendShotNoise(
        name: String,
        positiveNode: Node,
        negativeNode: Node,
        current: Double,
        electronCharge: Double,
        into sources: inout [NoiseSource]
    ) {
        let density = 2 * electronCharge * abs(current)
        if density > 0 {
            sources.append(
                NoiseSource(
                    name: name,
                    positiveNode: positiveNode,
                    negativeNode: negativeNode,
                    currentSpectralDensity: density
                )
            )
        }
    }

    private func nodeVoltage(_ index: Int?, _ state: SolutionState) -> Double {
        index.map { state.value(at: $0) } ?? 0
    }
}
