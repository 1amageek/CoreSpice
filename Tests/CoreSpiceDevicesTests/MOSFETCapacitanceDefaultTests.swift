import Testing
@testable import CoreSpiceDevices
import CoreSpiceIR

/// Regression guard for the MOSFET gate-capacitance default.
///
/// When a model card omits TOX, no oxide capacitance must be derived, so the
/// intrinsic gate capacitances are zero. This matches the SPICE/ngspice
/// convention. A nonzero default TOX previously fabricated ~2.3 fF of phantom
/// gate capacitance per device, which slowed the ring-oscillator dogfood by
/// ~36% (1.18 GHz vs ngspice 1.85 GHz). See validation/corespice-vs-ngspice.md.
@Suite("MOSFET capacitance defaults")
struct MOSFETCapacitanceDefaultTests {

    @Test("Unspecified tox yields zero oxide capacitance")
    func defaultToxGivesZeroCox() {
        #expect(MOSFETModelParameters().cox == 0)
    }

    @Test("Explicit tox yields the expected oxide capacitance")
    func explicitToxGivesExpectedCox() {
        let params = MOSFETModelParameters(tox: 100e-9)
        let expected = 3.453e-11 / 100e-9  // Cox = eps_ox / tox
        #expect(params.cox > 0)
        #expect(abs(params.cox - expected) <= 1e-12 * expected)
    }

    @Test("All MOSFET descriptors declare a tox default of 0")
    func descriptorToxDefaultsAreZero() {
        let descriptors: [any DeviceDescriptor] = [
            NMOSL1Descriptor(), PMOSL1Descriptor(),
            NMOSL2Descriptor(), PMOSL2Descriptor(),
            NMOSL3Descriptor(), PMOSL3Descriptor(),
        ]
        for descriptor in descriptors {
            guard let tox = descriptor.parameterDescriptors.first(where: { $0.name == "tox" }) else {
                Issue.record("\(descriptor.typeName) has no tox parameter descriptor")
                continue
            }
            guard case .real(let value)? = tox.defaultValue else {
                Issue.record("\(descriptor.typeName) tox default is not a real value")
                continue
            }
            #expect(value == 0, "\(descriptor.typeName) tox default should be 0, got \(value)")
        }
    }
}
