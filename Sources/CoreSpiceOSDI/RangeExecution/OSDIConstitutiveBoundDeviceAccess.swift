import CoreSpiceDevices
import CoreSpiceIR
import OSDIRuntime

/// Concrete producer checks stay inside the module that owns the actual device.
package enum OSDIConstitutiveBoundDeviceAccess {
    package static func snapshot(of device: any BoundDevice) throws -> OSDIPrecisionProgram? {
        guard let actual = device as? BoundOSDIDevice else { throw OSDIConstitutiveCaptureFailure.invalidBinding }
        return actual.constitutiveSnapshot?.program
    }
    package static func visitStructure(of device: any BoundDevice, checkpoint: () throws -> Void,
        _ visit: (ContinuousEquationAccess, MNAVariable, Int) throws -> Void) throws {
        guard let actual = device as? BoundOSDIDevice else { throw OSDIConstitutiveCaptureFailure.invalidBinding }
        try actual.visitContinuousEquationStructure(checkpoint: checkpoint, visit)
    }
    package static func prepareCapture(of device: any BoundDevice,
        inputs: OSDIConstitutiveCaptureInputs) async throws -> OSDIConstitutiveCapture {
        guard let actual = device as? BoundOSDIDevice else { throw OSDIConstitutiveCaptureFailure.invalidBinding }
        return try await actual.prepareConstitutiveCapture(inputs: inputs)
    }
    package static func prepareSmoothRangeCapture(of device: any BoundDevice,
        inputs: OSDISmoothRangeCaptureInputs) async throws -> OSDISmoothRangeCapture {
        guard let actual = device as? BoundOSDIDevice else { throw OSDISmoothRangeFailure.invalidBinding }
        return try await actual.prepareSmoothRangeCapture(inputs: inputs)
    }
}
