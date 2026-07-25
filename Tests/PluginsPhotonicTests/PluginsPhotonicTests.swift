import Testing
import Foundation
@testable import PluginsPhotonic

@Suite("PluginsPhotonic Tests")
struct PluginsPhotonicTests {

    @Test func layerPatternValues() {
        #expect(LayerPattern.even.rawValue == 0)
        #expect(LayerPattern.odd.rawValue == 1)
    }

    @Test func mziBlockIdentity() {
        let block = MZIBlock.identity
        #expect(block.theta == 0)
        #expect(block.phi == 0)
        #expect(block.loss == 1.0)
    }

    @Test func mziBlockHalfSplitter() {
        let block = MZIBlock.halfSplitter
        #expect(abs(block.theta - .pi / 2) < 1e-10)
    }

    @Test func meshLayerCreation() {
        let blocks = (0..<256).map { _ in MZIBlock.identity }
        let layer = MeshLayer(pattern: .even, blocks: blocks)
        #expect(layer.pairCount == 256)
        #expect(layer.pattern == .even)
    }

    @Test func photonicMesh512PortCount() {
        #expect(PhotonicMesh512.portCount == 512)
        #expect(PhotonicMesh512.maxPairs(for: .even) == 256)
        #expect(PhotonicMesh512.maxPairs(for: .odd) == 255)
    }

    @Test func wavelengthModelDefault() throws {
        let model = WavelengthModel()
        #expect(model.centerWavelength == 1550e-9)
        // At center wavelength, effective phase should equal base phase
        let phase = try model.effectivePhase(basePhase: 1.0, wavelength: 1550e-9)
        #expect(abs(phase - 1.0) < 1e-10)
    }

    @Test func coefficientGeneratorIdentity() throws {
        let gen = CoefficientGenerator()
        let coeffs = try gen.generate(block: .identity, wavelength: 1550e-9)
        // Identity MZI (θ=0): m00 = e^(iφ) = 1, m01 = 0, m10 = 0, m11 = e^(-iφ) = 1
        #expect(abs(coeffs.m00_real - 1.0) < 1e-5)
        #expect(abs(coeffs.m00_imag) < 1e-5)
        #expect(abs(coeffs.m01_real) < 1e-5)
        #expect(abs(coeffs.m01_imag) < 1e-5)
        #expect(abs(coeffs.m11_real - 1.0) < 1e-5)
        #expect(abs(coeffs.m11_imag) < 1e-5)
    }

    @Test func coefficientGeneratorHalfSplitter() throws {
        let gen = CoefficientGenerator()
        let block = MZIBlock.halfSplitter  // θ=π/2, φ=0
        let coeffs = try gen.generate(block: block, wavelength: 1550e-9)
        // cos(π/4) ≈ 0.7071, sin(π/4) ≈ 0.7071
        let expected = Float(cos(Double.pi / 4))
        #expect(abs(coeffs.m00_real - expected) < 1e-4)
        // m01 should be purely imaginary: i * sin(π/4)
        #expect(abs(coeffs.m01_real) < 1e-4)
        #expect(abs(coeffs.m01_imag - expected) < 1e-4)
    }

    @Test func photonicCompilerProducesLayerPlan() throws {
        let layers = [
            MeshLayer(pattern: .even, blocks: (0..<256).map { _ in MZIBlock.identity }),
            MeshLayer(pattern: .odd, blocks: (0..<255).map { _ in MZIBlock.identity }),
        ]
        let mesh = PhotonicMesh512(layers: layers)
        let compiler = PhotonicCompiler()
        let plan = try compiler.compile(mesh: mesh, wavelength: 1550e-9)

        #expect(plan.layerCount == 2)
        #expect(plan.coefficients.count == 2)
        #expect(plan.descriptors.count == 2)
        #expect(plan.descriptors[0].pattern == 0)  // even
        #expect(plan.descriptors[1].pattern == 1)  // odd
    }

    @Test func photonicSweepBatch() throws {
        let batch = PhotonicSweepBatch(
            wavelengths: [1530e-9, 1540e-9, 1550e-9, 1560e-9, 1570e-9],
            repetitions: 16,
            inputPortIndex: 0
        )
        #expect(try batch.totalBatchSize() == 80)
        #expect(batch.wavelengths.count == 5)
    }

    @Test func photonicSweepBatchRejectsInvalidExecutionInputs() {
        #expect(throws: PhotonicExecutionError.self) {
            try PhotonicSweepBatch(
                wavelengths: [],
                repetitions: 1
            ).validate()
        }
        #expect(throws: PhotonicExecutionError.self) {
            try PhotonicSweepBatch(
                wavelengths: [1550e-9],
                repetitions: 0
            ).validate()
        }
        #expect(throws: PhotonicExecutionError.self) {
            try PhotonicSweepBatch(
                wavelengths: [1550e-9],
                inputPortIndex: 512
            ).validate()
        }
    }

    @Test func compilerRejectsInvalidMeshAndWavelength() {
        let invalidMesh = PhotonicMesh512(layers: [
            MeshLayer(
                pattern: .odd,
                blocks: (0..<256).map { _ in MZIBlock.identity }
            )
        ])
        #expect(throws: PhotonicExecutionError.self) {
            try PhotonicCompiler().compile(mesh: invalidMesh, wavelength: 1550e-9)
        }
        let validMesh = PhotonicMesh512(layers: [
            MeshLayer(pattern: .even, blocks: [MZIBlock.identity])
        ])
        #expect(throws: PhotonicExecutionError.self) {
            try PhotonicCompiler().compile(mesh: validMesh, wavelength: .nan)
        }
    }

    @Test func photonicPortOutput() {
        let output = PhotonicPortOutput(portIndex: 0, real: 0.6, imag: 0.8)
        #expect(abs(output.power - 1.0) < 1e-5)
        #expect(abs(output.amplitude - 1.0) < 1e-5)
    }
}
