import Testing
@testable import CoreSpiceDevices
@testable import CoreSpiceIR

@Suite("Current-controlled switch binding")
struct CurrentControlledSwitchTests {
    @Test("Explicit current-controlled switch rejects unsupported hysteresis")
    func currentControlledSwitchRejectsHysteresis() {
        let instance = Instance(
            name: "W1",
            typeName: "cswitch",
            nodes: [Node(id: 1), Node(id: 2), Node(id: 3), .ground],
            parameters: [
                "ron": .real(10.0),
                "roff": .real(1.0e9),
                "it": .real(1.0e-3),
                "ih": .real(1.0e-4),
            ]
        )
        var context = BindingContext(variableMap: [:], matrixDimension: 0)

        #expect(throws: DeviceBindingError.self) {
            _ = try CurrentControlledSwitchDescriptor().bind(instance: instance, context: &context)
        }
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
            guard case .invalidParameterValue(_, let parameter, let message) = error else {
                Issue.record("Unexpected DeviceBindingError: \(error)")
                return
            }
            #expect(parameter == "sense_branch")
            #expect(message.contains("No matrix branch index found"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("Branch-referenced current-controlled switch rejects unsupported hysteresis")
    func branchReferencedCurrentControlledSwitchRejectsHysteresis() {
        let controlBranch = Branch(id: 7)
        let instance = Instance(
            name: "W2",
            typeName: "cswitch_ref",
            nodes: [Node(id: 1), Node(id: 2)],
            parameters: [
                "ron": .real(10.0),
                "roff": .real(1.0e9),
                "it": .real(1.0e-3),
                "ih": .real(1.0e-4),
                "control_source": .string("VCTRL"),
            ]
        )
        var context = BindingContext(
            variableMap: [.branchCurrent(controlBranch): 0],
            matrixDimension: 1,
            branchNames: [controlBranch: "VCTRL"]
        )

        #expect(throws: DeviceBindingError.self) {
            _ = try BranchReferencedCurrentControlledSwitchDescriptor().bind(instance: instance, context: &context)
        }
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
