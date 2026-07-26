import CoreSpiceIR
import Foundation

/// An ideal, lossless transmission line with fixed characteristic impedance and delay.
public struct BoundTransmissionLine:
    BoundDevice,
    TransientStateCommittingDevice,
    TransientTimeStepConstraintDevice,
    Sendable
{
    public let instance: Instance
    public let maximumTransientTimeStep: Double

    private let port1Positive: Node
    private let port1Negative: Node
    private let port2Positive: Node
    private let port2Negative: Node
    private let port1Branch: Branch
    private let port2Branch: Branch
    private let impedance: Double
    private let history: TransmissionLineHistory

    private let port1PositiveIndex: Int?
    private let port1NegativeIndex: Int?
    private let port2PositiveIndex: Int?
    private let port2NegativeIndex: Int?
    private let port1BranchIndex: Int
    private let port2BranchIndex: Int

    init(
        instance: Instance,
        port1Positive: Node,
        port1Negative: Node,
        port2Positive: Node,
        port2Negative: Node,
        port1Branch: Branch,
        port2Branch: Branch,
        impedance: Double,
        delay: Double,
        port1PositiveIndex: Int?,
        port1NegativeIndex: Int?,
        port2PositiveIndex: Int?,
        port2NegativeIndex: Int?,
        port1BranchIndex: Int,
        port2BranchIndex: Int
    ) {
        self.instance = instance
        self.port1Positive = port1Positive
        self.port1Negative = port1Negative
        self.port2Positive = port2Positive
        self.port2Negative = port2Negative
        self.port1Branch = port1Branch
        self.port2Branch = port2Branch
        self.impedance = impedance
        self.maximumTransientTimeStep = delay
        self.history = TransmissionLineHistory()
        self.port1PositiveIndex = port1PositiveIndex
        self.port1NegativeIndex = port1NegativeIndex
        self.port2PositiveIndex = port2PositiveIndex
        self.port2NegativeIndex = port2NegativeIndex
        self.port1BranchIndex = port1BranchIndex
        self.port2BranchIndex = port2BranchIndex
    }

    public func stampDC(into stamper: inout MatrixStamper, state: SolutionState) {
        stampPortKCL(into: &stamper)
        stampRealBranchEquation(
            row: port1BranchIndex,
            localPositive: port1PositiveIndex,
            localNegative: port1NegativeIndex,
            localBranch: port1BranchIndex,
            remotePositive: port2PositiveIndex,
            remoteNegative: port2NegativeIndex,
            remoteBranch: port2BranchIndex,
            propagation: 1,
            into: &stamper
        )
        stampRealBranchEquation(
            row: port2BranchIndex,
            localPositive: port2PositiveIndex,
            localNegative: port2NegativeIndex,
            localBranch: port2BranchIndex,
            remotePositive: port1PositiveIndex,
            remoteNegative: port1NegativeIndex,
            remoteBranch: port1BranchIndex,
            propagation: 1,
            into: &stamper
        )
    }

    public func stampAC(
        into stamper: inout ComplexMatrixStamper,
        state: SolutionState,
        omega: Double
    ) {
        stampPortKCL(into: &stamper)
        let angle = -omega * maximumTransientTimeStep
        let propagation = ComplexStampValue(real: cos(angle), imag: sin(angle))
        stampComplexBranchEquation(
            row: port1BranchIndex,
            localPositive: port1PositiveIndex,
            localNegative: port1NegativeIndex,
            localBranch: port1BranchIndex,
            remotePositive: port2PositiveIndex,
            remoteNegative: port2NegativeIndex,
            remoteBranch: port2BranchIndex,
            propagation: propagation,
            into: &stamper
        )
        stampComplexBranchEquation(
            row: port2BranchIndex,
            localPositive: port2PositiveIndex,
            localNegative: port2NegativeIndex,
            localBranch: port2BranchIndex,
            remotePositive: port1PositiveIndex,
            remoteNegative: port1NegativeIndex,
            remoteBranch: port1BranchIndex,
            propagation: propagation,
            into: &stamper
        )
    }

    public func stampTransient(
        into stamper: inout MatrixStamper,
        state: SolutionState,
        integration: IntegrationState
    ) {
        stampPortKCL(into: &stamper)
        let initialWaves = waves(from: state, previous: true)
        let delayed = history.delayedWaves(
            currentTime: integration.currentTime,
            delay: maximumTransientTimeStep,
            initialWaves: initialWaves
        )

        stampLocalTransientEquation(
            row: port1BranchIndex,
            positive: port1PositiveIndex,
            negative: port1NegativeIndex,
            branch: port1BranchIndex,
            delayedWave: delayed.fromPort2,
            into: &stamper
        )
        stampLocalTransientEquation(
            row: port2BranchIndex,
            positive: port2PositiveIndex,
            negative: port2NegativeIndex,
            branch: port2BranchIndex,
            delayedWave: delayed.fromPort1,
            into: &stamper
        )
    }

    public func commitTransientStep(state: SolutionState, integration: IntegrationState) {
        history.commit(
            time: integration.currentTime,
            waves: waves(from: state, previous: false),
            delay: maximumTransientTimeStep
        )
    }

    public func checkConvergence(
        state: SolutionState,
        previousState: SolutionState
    ) -> ConvergenceResult {
        .converged
    }

    private func waves(from state: SolutionState, previous: Bool) -> TransmissionLineHistory.Waves {
        let port1Voltage = value(at: port1PositiveIndex, from: state, previous: previous)
            - value(at: port1NegativeIndex, from: state, previous: previous)
        let port2Voltage = value(at: port2PositiveIndex, from: state, previous: previous)
            - value(at: port2NegativeIndex, from: state, previous: previous)
        let port1Current = previous
            ? state.previousValue(at: port1BranchIndex)
            : state.value(at: port1BranchIndex)
        let port2Current = previous
            ? state.previousValue(at: port2BranchIndex)
            : state.value(at: port2BranchIndex)
        return TransmissionLineHistory.Waves(
            fromPort1: port1Voltage + impedance * port1Current,
            fromPort2: port2Voltage + impedance * port2Current
        )
    }

    private func value(
        at index: Int?,
        from state: SolutionState,
        previous: Bool
    ) -> Double {
        guard let index else {
            return 0
        }
        return previous ? state.previousValue(at: index) : state.value(at: index)
    }

    private func stampPortKCL(into stamper: inout MatrixStamper) {
        stampPortKCL(
            positive: port1PositiveIndex,
            negative: port1NegativeIndex,
            branch: port1BranchIndex,
            into: &stamper
        )
        stampPortKCL(
            positive: port2PositiveIndex,
            negative: port2NegativeIndex,
            branch: port2BranchIndex,
            into: &stamper
        )
    }

    private func stampPortKCL(into stamper: inout ComplexMatrixStamper) {
        stampPortKCL(
            positive: port1PositiveIndex,
            negative: port1NegativeIndex,
            branch: port1BranchIndex,
            into: &stamper
        )
        stampPortKCL(
            positive: port2PositiveIndex,
            negative: port2NegativeIndex,
            branch: port2BranchIndex,
            into: &stamper
        )
    }

    private func stampPortKCL(
        positive: Int?,
        negative: Int?,
        branch: Int,
        into stamper: inout MatrixStamper
    ) {
        if let positive {
            stamper.stampMatrix(positive, branch, 1)
        }
        if let negative {
            stamper.stampMatrix(negative, branch, -1)
        }
    }

    private func stampPortKCL(
        positive: Int?,
        negative: Int?,
        branch: Int,
        into stamper: inout ComplexMatrixStamper
    ) {
        if let positive {
            stamper.stampMatrix(positive, branch, 1, 0)
        }
        if let negative {
            stamper.stampMatrix(negative, branch, -1, 0)
        }
    }

    private func stampRealBranchEquation(
        row: Int,
        localPositive: Int?,
        localNegative: Int?,
        localBranch: Int,
        remotePositive: Int?,
        remoteNegative: Int?,
        remoteBranch: Int,
        propagation: Double,
        into stamper: inout MatrixStamper
    ) {
        stampNodeDifference(
            row: row,
            positive: localPositive,
            negative: localNegative,
            coefficient: 1,
            into: &stamper
        )
        stamper.stampMatrix(row, localBranch, -impedance)
        stampNodeDifference(
            row: row,
            positive: remotePositive,
            negative: remoteNegative,
            coefficient: -propagation,
            into: &stamper
        )
        stamper.stampMatrix(row, remoteBranch, -propagation * impedance)
    }

    private func stampComplexBranchEquation(
        row: Int,
        localPositive: Int?,
        localNegative: Int?,
        localBranch: Int,
        remotePositive: Int?,
        remoteNegative: Int?,
        remoteBranch: Int,
        propagation: ComplexStampValue,
        into stamper: inout ComplexMatrixStamper
    ) {
        stampNodeDifference(
            row: row,
            positive: localPositive,
            negative: localNegative,
            coefficient: ComplexStampValue(real: 1),
            into: &stamper
        )
        stamper.stampMatrix(row, localBranch, -impedance, 0)
        stampNodeDifference(
            row: row,
            positive: remotePositive,
            negative: remoteNegative,
            coefficient: ComplexStampValue(real: -propagation.real, imag: -propagation.imag),
            into: &stamper
        )
        stamper.stampMatrix(
            row,
            remoteBranch,
            -propagation.real * impedance,
            -propagation.imag * impedance
        )
    }

    private func stampLocalTransientEquation(
        row: Int,
        positive: Int?,
        negative: Int?,
        branch: Int,
        delayedWave: Double,
        into stamper: inout MatrixStamper
    ) {
        stampNodeDifference(
            row: row,
            positive: positive,
            negative: negative,
            coefficient: 1,
            into: &stamper
        )
        stamper.stampMatrix(row, branch, -impedance)
        stamper.stampRHS(row, delayedWave)
    }

    private func stampNodeDifference(
        row: Int,
        positive: Int?,
        negative: Int?,
        coefficient: Double,
        into stamper: inout MatrixStamper
    ) {
        if let positive {
            stamper.stampMatrix(row, positive, coefficient)
        }
        if let negative {
            stamper.stampMatrix(row, negative, -coefficient)
        }
    }

    private func stampNodeDifference(
        row: Int,
        positive: Int?,
        negative: Int?,
        coefficient: ComplexStampValue,
        into stamper: inout ComplexMatrixStamper
    ) {
        if let positive {
            stamper.stampMatrix(row, positive, coefficient.real, coefficient.imag)
        }
        if let negative {
            stamper.stampMatrix(row, negative, -coefficient.real, -coefficient.imag)
        }
    }
}
