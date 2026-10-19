import CoreSpiceCompile

/// Homogeneous coordinates, never a magnitude-based infinity classification.
struct HomogeneousEigenvalue: Sendable {
    let alphaReal: Double
    let alphaImag: Double
    let beta: Double
}
