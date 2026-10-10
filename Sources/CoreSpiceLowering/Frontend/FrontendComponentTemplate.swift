import CoreSpiceMOSContracts
import CoreSpiceParsedIR

struct FrontendComponentTemplate: Sendable {
    let component: ParsedComponent
    let scope: MOSScopeID
    let programs: [String: MOSProgramID]
    let assignments: [MOSExpressionBinding]
    let mosAssignmentFailure: String?
    let hasMOSInitialConditionVector: Bool
}
