import CoreSpiceMOSContracts

struct FrontendComponentJob: Sendable {
    let template: FrontendComponentTemplate
    let invocation: UInt64
    let prefix: String
    let nodes: [String]
    let portMapping: [String: String]
}
