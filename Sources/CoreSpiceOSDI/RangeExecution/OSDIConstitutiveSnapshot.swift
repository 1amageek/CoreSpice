import CoreSpiceCompile
import OSDIContracts
import OSDIRuntime

/// Shared immutable backing retains its original admission across prepared/bound copies.
struct OSDIConstitutiveSnapshot: Sendable {
    let program: OSDIPrecisionProgram
    let options: OSDIPrecisionOptions
    let control: any LinearSolverExecutionControlling
    init(program: OSDIPrecisionProgram, inputs: OSDIConstitutiveSnapshotInputs) {
        self.program = program; options = inputs.options; control = inputs.control
    }
}
