import Testing
@testable import CoreSpiceDevices
@testable import CoreSpiceIR

@Suite("Branch-referenced controlled device binding")
struct BranchReferencedControlledSourceTests {
    @Test("Branch-referenced controlled devices reject named branches without matrix variables")
    func branchReferencedDevicesRejectUnindexedControlBranch() throws {
        let controlBranch = Branch(id: 7)
        let context = BindingContext(
            variableMap: [:],
            matrixDimension: 0,
            branchNames: [controlBranch: "VCTRL"]
        )

        try expectControlBranchIndexFailure(
            instance: Instance(
                name: "F1",
                typeName: "cccs_ref",
                nodes: [Node(id: 1), Node(id: 2)],
                parameters: [
                    "f": .real(2.0),
                    "control_source": .string("VCTRL"),
                ]
            ),
            descriptor: BranchReferencedCCCSDescriptor(),
            context: context
        )

        try expectControlBranchIndexFailure(
            instance: Instance(
                name: "H1",
                typeName: "ccvs_ref",
                nodes: [Node(id: 1), Node(id: 2)],
                parameters: [
                    "h": .real(10.0),
                    "control_source": .string("VCTRL"),
                ]
            ),
            descriptor: BranchReferencedCCVSDescriptor(),
            context: context
        )

        try expectControlBranchIndexFailure(
            instance: Instance(
                name: "W1",
                typeName: "cswitch_ref",
                nodes: [Node(id: 1), Node(id: 2)],
                parameters: [
                    "ron": .real(1.0),
                    "roff": .real(1.0e9),
                    "it": .real(0.0),
                    "ih": .real(0.0),
                    "control_source": .string("VCTRL"),
                ]
            ),
            descriptor: BranchReferencedCurrentControlledSwitchDescriptor(),
            context: context
        )
    }

    private func expectControlBranchIndexFailure(
        instance: Instance,
        descriptor: any DeviceDescriptor,
        context: BindingContext
    ) throws {
        var mutableContext = context
        do {
            _ = try descriptor.bind(instance: instance, context: &mutableContext)
            Issue.record("Expected binding to reject an unindexed control branch.")
        } catch let error as DeviceBindingError {
            guard case .invalidParameterValue(_, let parameter, let message) = error else {
                Issue.record("Unexpected DeviceBindingError: \(error)")
                return
            }
            #expect(parameter == "control_source")
            #expect(message.contains("No matrix branch index found"))
        }
    }
}
