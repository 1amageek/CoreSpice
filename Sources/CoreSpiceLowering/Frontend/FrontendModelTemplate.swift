import CoreSpiceMOSContracts
import CoreSpiceParsedIR

struct FrontendModelTemplate: Sendable {
    let model: ParsedModel
    let scope: MOSScopeID
    let programs: [(String, MOSProgramID)]
}
