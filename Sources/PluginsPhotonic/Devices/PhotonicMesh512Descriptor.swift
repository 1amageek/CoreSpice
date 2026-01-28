import CoreSpiceIR
import CoreSpiceDevices

/// Descriptor for a full 512-port photonic MZI mesh device.
///
/// This device exposes 512 ports ("p0" through "p511") and is
/// intended for GPU-accelerated simulation through the photonic
/// executor rather than conventional SPICE matrix stamping.
/// The `BoundPhotonicMesh512` stores the mesh IR and delegates
/// computation to the GPU fast path.
public struct PhotonicMesh512Descriptor: DeviceDescriptor, Sendable {

    public let typeName = "photonic_mesh_512"

    public let portNames: [String] = (0..<512).map { "p\($0)" }

    public let parameterDescriptors: [ParameterDescriptor] = [
        ParameterDescriptor(
            name: "layer_count",
            defaultValue: .integer(0),
            description: "Number of mesh layers"
        ),
    ]

    public init() {}

    public func bind(instance: Instance, context: inout BindingContext) throws -> any BoundDevice {
        guard instance.nodes.count == 512 else {
            throw DeviceBindingError.portCountMismatch(
                device: instance.name, expected: 512, got: instance.nodes.count
            )
        }

        return BoundPhotonicMesh512(instance: instance)
    }
}
