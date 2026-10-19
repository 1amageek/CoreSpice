import CircuiteFoundation
import CoreSpiceCompile
import OSDIContracts
import OSDIRuntime

/// Explicit snapshot-only policy sharing the request's work and storage owner.
package struct OSDIConstitutiveSnapshotInputs: Sendable {
    package let preparer: any OSDIPrecisionSessionPreparing
    package let semanticProfile: ContentDigest
    package let options: OSDIPrecisionOptions
    package let simulationParameters: [OSDISimulationParameter]
    package let control: any LinearSolverExecutionControlling
    package init(preparer: any OSDIPrecisionSessionPreparing, semanticProfile: ContentDigest,
        options: OSDIPrecisionOptions, control: any LinearSolverExecutionControlling,
        simulationParameters: [OSDISimulationParameter] = []) {
        self.preparer = preparer; self.semanticProfile = semanticProfile
        self.options = options; self.control = control; self.simulationParameters = simulationParameters
    }
}
