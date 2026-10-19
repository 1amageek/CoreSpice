import Testing
import CoreSpiceIR
@testable import CoreSpiceDevices

@Suite("Compensated numerical state", .timeLimit(.minutes(1)))
struct CompensatedStateTests {
    @Test func repeatedSubULPUpdatesSurviveNormalization() throws {
        let increment = try CompensatedValue(high: 0x1p-56)
        var value = try CompensatedValue(high: 0.5)
        value = try value.adding(increment)
        #expect(value.high == 0.5 && value.low == 0x1p-56)
        for _ in 1..<8 { value = try value.adding(increment) }
        #expect(value.high == 0.5.nextUp && value.low == 0)
        #expect(try value.subtracting(CompensatedValue(high: 0.5)) == CompensatedValue(high: 0x1p-53))
    }

    @Test func invalidPairsAndHistoryWidthsFail() throws {
        #expect(throws: NumericalStateError.nonNormalizedPair) { try CompensatedValue(high: 1, low: 1) }
        #expect(throws: NumericalStateError.nonFiniteComponent) { try CompensatedValue(high: .infinity) }
        let state = SolutionState(variables: [0.5], variableMap: [.nodeVoltage(Node(id: 1)): 0], variableLowComponents: [])
        #expect(throws: NumericalStateError.lowComponentCountMismatch(expected: 1, actual: 0)) {
            try state.validateCompensatedComponents()
        }
    }

    @Test func previousSnapshotPreservesLowAndPrivateIdentity() throws {
        let node = Node(id: 7)
        let state = SolutionState(variables: [0.5], previousVariables: [0.5], variableMap: [.nodeVoltage(node): 0],
            variableLowComponents: [0x1p-55], previousVariableLowComponents: [0x1p-56])
        try state.validateCompensatedComponents()
        let previous = try state.checkedPreviousSnapshot()
        #expect(try previous.checkedCompensatedVoltage(at: node).low == 0x1p-56)
        #expect(try previous.checkedCompensatedVoltage(at: .ground) == .zero)
    }

    @Test func outwardArithmeticIncludesUnderflowAndCancellation() throws {
        let tiny = try CompensatedEnclosure(center: CompensatedValue(high: .leastNonzeroMagnitude))
        let half = try CompensatedEnclosure(center: CompensatedValue(high: 0.5))
        let underflow = try tiny.multiplied(by: half)
        #expect(underflow.center.high == 0)
        #expect(underflow.radius >= Double.leastNonzeroMagnitude)
        let big = try CompensatedEnclosure(center: CompensatedValue(high: 0x1p54))
        let one = try CompensatedEnclosure(center: CompensatedValue(high: 1))
        let cancellation = try big.adding(one).subtracting(big)
        #expect(cancellation.center.high == 1)
        #expect(cancellation.absoluteUpperBound >= 1)
        #expect(throws: NumericalStateError.divisionByZero) { try one.divided(by: CompensatedEnclosure(center: .zero)) }
        #expect(throws: NumericalStateError.invalidRadius(-1)) { try CompensatedEnclosure(center: .zero, radius: -1) }
    }

    @Test func quotientErrorUnderflowRemainsStrictlyPositive() throws {
        let numerator = try CompensatedEnclosure(center: CompensatedValue(high: .leastNonzeroMagnitude))
        let denominator = try CompensatedEnclosure(center: CompensatedValue(high: .greatestFiniteMagnitude))
        let quotient = try numerator.divided(by: denominator)
        #expect(quotient.center == .zero)
        #expect(quotient.radius >= Double.leastNonzeroMagnitude)
    }

    @Test func chargeDifferenceCancelsBeforeAnyIntervalProjection() throws {
        let x = try CompensatedEnclosure(center: CompensatedValue(high: 0.5, low: 0x1p-56))
        let y = try CompensatedEnclosure(center: CompensatedValue(high: 0.5))
        let deltaQ = try x.subtracting(y).multiplied(by: CompensatedEnclosure(center: CompensatedValue(high: 0x1p-37)))
        let current = try deltaQ.divided(by: CompensatedEnclosure(center: CompensatedValue(high: 0x1p-54)))
        #expect(current.center.high == 0x1p-39)
        #expect(current.radius < 1e-25)
    }

    @Test func exactIntervalRetainsDifferenceLow() throws {
        let interval = try CompensatedValue(high: 1).subtracting(CompensatedValue(high: 0x1p-54))
        #expect(interval.high == 1 && interval.low == -0x1p-54)
        let integration = IntegrationState(method: .backwardEuler, timeStep: interval.high, currentTime: 1,
            timeStepLowComponent: interval.low)
        #expect(try integration.compensatedTimeStep == interval)
    }
}
