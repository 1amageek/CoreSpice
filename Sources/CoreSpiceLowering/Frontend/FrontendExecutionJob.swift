enum FrontendExecutionJob: Sendable {
    case enter(UInt64)
    case component(FrontendComponentJob)
}
