import CoreSpiceMOSContracts
import CoreSpiceParsedIR

struct DiodeCompiledAssignment: Sendable {
    let source: ParsedParameterAssignment
    let program: MOSProgramID?
}
