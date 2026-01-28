import SharedTypes

/// Compiles a `PhotonicMesh512` into a GPU-ready `LayerPlan512`.
///
/// The compiler iterates over all mesh layers, generates the
/// MZI transfer-matrix coefficients at the specified wavelength,
/// and produces a `LayerDescriptor` for each layer that the
/// GPU kernel uses to determine pairing offsets.
public struct PhotonicCompiler: Sendable {

    public init() {}

    /// Compile the mesh for a specific wavelength.
    ///
    /// - Parameters:
    ///   - mesh: The photonic mesh to compile.
    ///   - wavelength: Operating wavelength in meters.
    /// - Returns: A compiled execution plan with pre-computed coefficients.
    public func compile(mesh: PhotonicMesh512, wavelength: Double) -> LayerPlan512 {
        let generator = CoefficientGenerator(wavelengthModel: mesh.wavelengthModel)
        var allCoeffs: [[MZICoefficients]] = []
        var descriptors: [LayerDescriptor] = []

        for layer in mesh.layers {
            let coeffs = generator.generateLayer(layer: layer, wavelength: wavelength)
            allCoeffs.append(coeffs)

            let offset: UInt32 = layer.pattern == .even ? 0 : 1
            descriptors.append(LayerDescriptor(
                offset: offset,
                count: UInt32(layer.pairCount),
                pattern: layer.pattern.rawValue
            ))
        }

        return LayerPlan512(
            layerCount: mesh.layerCount,
            coefficients: allCoeffs,
            descriptors: descriptors
        )
    }
}
