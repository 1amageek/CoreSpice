import CoreSpice

/// A completed prepared execution summary; admission alone cannot construct this record.
struct CoreSpiceCLIPreparedRunRecord: Encodable, Sendable {
    let schemaVersion = 1
    let status = "succeeded"
    let sourceInputIdentity: String
    let configurationIdentity: String
    let points: Int
    let newtonIterations: Int

    init(_ output: SPICENativeSimulationOutput) {
        sourceInputIdentity = output.sourceInputIdentity.hexadecimalValue
        configurationIdentity = output.configurationIdentity.hexadecimalValue
        points = output.waveform.pointCount
        newtonIterations = output.statistics.newtonIterations
    }
}
