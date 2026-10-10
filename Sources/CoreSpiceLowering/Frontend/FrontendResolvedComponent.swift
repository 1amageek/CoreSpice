import CoreSpiceIR

struct FrontendResolvedComponent {
    let typeName: String
    let parameters: [String: ParameterValue]
    let model: ResolvedDeviceModel?
    let consumption: ModelConsumption
    let readNodes: [String]
    let readBranches: [String]
}
