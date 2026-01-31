import CoreSpiceIR
import CoreSpiceDevices

/// Device descriptor for a 1x2 optical power splitter.
///
/// Purely optical device: no electrical ports.
/// Optical ports: optical_in, optical_out1, optical_out2.
///
/// Splits input power according to the split ratio with optional excess loss.
public struct OpticalSplitterDescriptor: DeviceDescriptor, Sendable {

    public let typeName = "splitter"
    public let portNames: [String] = []

    public let parameterDescriptors: [ParameterDescriptor] = [
        ParameterDescriptor(name: "ratio", defaultValue: .real(0.5), description: "Power split ratio to output 1 (0..1)"),
        ParameterDescriptor(name: "excess_loss", defaultValue: .real(0.0), description: "Excess insertion loss (linear, 0..1)"),
    ]

    public init() {}

    public func bind(instance: Instance, context: inout BindingContext) throws -> any BoundDevice {
        let ratio = extractReal(instance.parameters["ratio"]) ?? 0.5
        let excessLoss = extractReal(instance.parameters["excess_loss"]) ?? 0.0

        // Optical nodes: [0]=input, [1]=output1, [2]=output2
        let opticalInput: OpticalNode
        let opticalOutput1: OpticalNode
        let opticalOutput2: OpticalNode
        if instance.opticalNodes.count >= 3 {
            opticalInput = instance.opticalNodes[0]
            opticalOutput1 = instance.opticalNodes[1]
            opticalOutput2 = instance.opticalNodes[2]
        } else {
            opticalInput = OpticalNode(id: 0)
            opticalOutput1 = OpticalNode(id: 1)
            opticalOutput2 = OpticalNode(id: 2)
        }

        return BoundOpticalSplitter(
            instance: instance,
            inputNode: opticalInput,
            outputNode1: opticalOutput1,
            outputNode2: opticalOutput2,
            splitRatio: ratio,
            excessLoss: excessLoss
        )
    }

    private func extractReal(_ value: ParameterValue?) -> Double? {
        guard let value else { return nil }
        if case .real(let v) = value { return v }
        return nil
    }
}
