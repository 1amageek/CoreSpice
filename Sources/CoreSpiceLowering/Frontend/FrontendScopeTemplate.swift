import CoreSpiceMOSContracts
import CoreSpiceParsedIR

struct FrontendScopeTemplate: Sendable {
    let id: MOSScopeID
    let parent: MOSScopeID?
    let subcircuit: ParsedSubcircuit?
    let components: [FrontendComponentTemplate]
    let modelIndices: [Int]
    let subcircuits: [String: MOSScopeID]
    let functions: [String: ParsedFunctionDefinition]
}
