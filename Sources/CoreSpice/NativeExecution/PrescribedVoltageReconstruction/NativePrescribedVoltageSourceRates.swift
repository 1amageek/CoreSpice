import CoreSpiceAnalysis
import CoreSpiceCompile
import CoreSpiceDevices
import CoreSpiceOSDI

/// Existing charge-rate actions on the explicitly selected lifted spatial box.
internal enum NativePrescribedVoltageSourceRates {
    typealias A = NativePrescribedVoltageArithmetic
    static func enclose(device: any BoundDevice, preparation: NativeOSDIPreparationRecord,
        original: OSDIConstitutiveCaptureRetention, values: NativePrescribedVoltageValues.Payload, selectedRows: [Bool],
        inputs: OSDISmoothRangeCaptureInputs, limits: NativePrescribedVoltageReconstructionLimits,
        control: any LinearSolverExecutionControlling,
        stateLeftLift: PrescribedVoltageReduction.Lift, stateRightLift: PrescribedVoltageReduction.Lift,
        inputLeftLift: PrescribedVoltageReduction.Lift, inputRightLift: PrescribedVoltageReduction.Lift,
        stateLeft: inout [CompensatedEnclosure], stateRight: inout [CompensatedEnclosure],
        inputLeft: inout [CompensatedEnclosure], inputRight: inout [CompensatedEnclosure],
        checkpoint: () throws -> Void) async throws -> OSDISmoothRangeScope {
        let n = values.lower.count
        guard selectedRows.count == n, stateLeft.count == n, stateRight.count == n,
              inputLeft.count == n, inputRight.count == n else { throw NativePrescribedVoltageReconstructionFailure.invalidBinding }
        return try await NativePrescribedVoltageSpatialSource.withRange(device: device, preparation: preparation,
            original: original, values: values, query: .lifted, inputs: inputs,
            maximumWorkspaceBytes: limits.maximumWorkspaceBytes, precisionBits: limits.precisionBits,
            control: control, checkpoint: checkpoint) { view, inventory in
                let rawCount = inventory.rawGlobal.count
                let zero = try CompensatedEnclosure(center: .zero)
                for rawRow in 0..<rawCount {
                    for rawColumn in 0..<rawCount {
                        try checkpoint()
                        let index = try A.add(A.multiply(rawRow, rawCount), rawColumn)
                        let coefficient = try A.hull(view.cLower[index], view.cUpper[index])
                        guard let row = inventory.rawGlobal[rawRow], let column = inventory.rawGlobal[rawColumn] else { continue }
                        // Complete actual READ exclusion proves selected-current columns absent;
                        // their unavailable tangent coordinates are never replaced with a guessed rate.
                        if selectedRows[column] { continue }
                        if coefficient == zero { continue }
                        try control.checkpoint(workUnits: 4)
                        stateLeft[row] = try stateLeft[row].adding(coefficient.multiplied(by: stateLeftLift.coordinate(at: column)))
                        stateRight[row] = try stateRight[row].adding(coefficient.multiplied(by: stateRightLift.coordinate(at: column)))
                        inputLeft[row] = try inputLeft[row].adding(coefficient.multiplied(by: inputLeftLift.coordinate(at: column)))
                        inputRight[row] = try inputRight[row].adding(coefficient.multiplied(by: inputRightLift.coordinate(at: column)))
                    }
                }
            }
    }
}
