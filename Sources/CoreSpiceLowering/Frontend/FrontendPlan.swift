import CoreSpiceMOSContracts
import CoreSpiceMOSResolution

struct FrontendPlan {
    let graph: MOSInvocationGraph
    let jobs: [FrontendExecutionJob]
    let storage: FrontendStorage
}
