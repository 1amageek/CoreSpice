import Testing
import Synchronization
@testable import CoreSpiceDevices
@testable import CoreSpiceIR

@Suite("Current-controlled switch binding")
struct CurrentControlledSwitchTests {
    @Test("Explicit current-controlled switch commits hysteresis only after acceptance")
    func currentControlledSwitchCommitsHysteresisOnlyAfterAcceptance() throws {
        let switchedNode = Node(id: 1)
        let senseBranch = Branch(id: 0)
        let instance = Instance(
            name: "W1",
            typeName: "cswitch",
            nodes: [switchedNode, .ground, .ground, .ground],
            parameters: [
                "ron": .real(10.0),
                "roff": .real(1.0e9),
                "it": .real(1.0e-3),
                "ih": .real(1.0e-4),
            ]
        )
        let variableMap: [MNAVariable: Int] = [
            .nodeVoltage(switchedNode): 0,
            .branchCurrent(senseBranch): 1,
        ]
        var context = BindingContext(variableMap: variableMap, matrixDimension: 2)
        let bound = try CurrentControlledSwitchDescriptor().bind(
            instance: instance,
            context: &context
        )
        let stateful = try #require(bound as? any AcceptedStateCommittingDevice)

        func conductance(controlCurrent: Double) -> Double {
            let value = Mutex(0.0)
            var stamper = MatrixStamper(
                variableMap: variableMap,
                stampMatrix: { row, column, entry in
                    if row == 0, column == 0 {
                        value.withLock { $0 += entry }
                    }
                },
                stampRHS: { _, _ in }
            )
            bound.stampDC(
                into: &stamper,
                state: SolutionState(
                    variables: [1.0, controlCurrent],
                    variableMap: variableMap
                )
            )
            return value.withLock { $0 }
        }

        #expect(abs(conductance(controlCurrent: 1.0e-3) - 1.0e-9) < 1.0e-12)
        #expect(abs(conductance(controlCurrent: 1.2e-3) - 0.1) < 1.0e-12)
        #expect(abs(conductance(controlCurrent: 1.0e-3) - 1.0e-9) < 1.0e-12)

        stateful.commitAcceptedState(
            SolutionState(variables: [1.0, 1.2e-3], variableMap: variableMap)
        )
        #expect(abs(conductance(controlCurrent: 1.0e-3) - 0.1) < 1.0e-12)

        stateful.commitAcceptedState(
            SolutionState(variables: [1.0, 0.8e-3], variableMap: variableMap)
        )
        #expect(abs(conductance(controlCurrent: 1.0e-3) - 1.0e-9) < 1.0e-12)
    }

    @Test("Explicit current-controlled switch rejects unindexed sense branch")
    func currentControlledSwitchRejectsUnindexedSenseBranch() {
        let instance = Instance(
            name: "W1",
            typeName: "cswitch",
            nodes: [Node(id: 1), Node(id: 2), Node(id: 3), .ground],
            parameters: [
                "ron": .real(10.0),
                "roff": .real(1.0e9),
                "it": .real(1.0e-3),
                "ih": .real(0.0),
            ]
        )
        var context = BindingContext(variableMap: [:], matrixDimension: 0)

        do {
            _ = try CurrentControlledSwitchDescriptor().bind(instance: instance, context: &context)
            Issue.record("Expected binding to reject an unindexed sense branch.")
        } catch let error as DeviceBindingError {
            guard case .missingBranchVariable(let device, let index) = error else {
                Issue.record("Unexpected DeviceBindingError: \(error)")
                return
            }
            #expect(device == "W1")
            #expect(index == 0)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("Branch-referenced current-controlled switch supports hysteresis")
    func branchReferencedCurrentControlledSwitchSupportsHysteresis() throws {
        let switchedNode = Node(id: 1)
        let controlBranch = Branch(id: 7)
        let instance = Instance(
            name: "W2",
            typeName: "cswitch_ref",
            nodes: [switchedNode, .ground],
            parameters: [
                "ron": .real(10.0),
                "roff": .real(1.0e9),
                "it": .real(1.0e-3),
                "ih": .real(1.0e-4),
                "control_source": .string("VCTRL"),
            ]
        )
        var context = BindingContext(
            variableMap: [
                .nodeVoltage(switchedNode): 0,
                .branchCurrent(controlBranch): 1,
            ],
            matrixDimension: 2,
            branchNames: [controlBranch: "VCTRL"]
        )
        let bound = try BranchReferencedCurrentControlledSwitchDescriptor().bind(
            instance: instance,
            context: &context
        )
        let stateful = try #require(bound as? any AcceptedStateCommittingDevice)
        let variableMap = context.variableMap
        stateful.commitAcceptedState(
            SolutionState(variables: [1.0, 1.2e-3], variableMap: variableMap)
        )
        let conductance = Mutex(0.0)
        var stamper = MatrixStamper(
            variableMap: variableMap,
            stampMatrix: { row, column, value in
                if row == 0, column == 0 {
                    conductance.withLock { $0 += value }
                }
            },
            stampRHS: { _, _ in }
        )

        bound.stampDC(
            into: &stamper,
            state: SolutionState(variables: [1.0, 1.0e-3], variableMap: variableMap)
        )

        #expect(abs(conductance.withLock { $0 } - 0.1) < 1.0e-12)
    }

    @Test("Zero-hysteresis transition width scales with control-current magnitude")
    func zeroHysteresisTransitionWidthUsesRelativeScale() {
        let milliampWidth = CurrentControlledSwitchTransition.width(
            hysteresisCurrent: 0.0,
            thresholdCurrent: 1.0e-3,
            controlCurrent: 0.0
        )
        let ampWidth = CurrentControlledSwitchTransition.width(
            hysteresisCurrent: 0.0,
            thresholdCurrent: 1.0,
            controlCurrent: 0.0
        )
        let explicitHysteresisWidth = CurrentControlledSwitchTransition.width(
            hysteresisCurrent: 8.0e-6,
            thresholdCurrent: 1.0,
            controlCurrent: 0.0
        )

        #expect(milliampWidth == 1.0e-6)
        #expect(ampWidth == 1.0e-3)
        #expect(explicitHysteresisWidth == 1.0e-6)
    }
}
