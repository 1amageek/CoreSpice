public enum EventCategory: Sendable, Hashable {
    case lifecycle
    case progress
    case sweep
    case newton
    case timeStep
    case gpu
    case metric
    case diagnostic
}

extension AnalysisEvent {

    public var category: EventCategory {
        switch self {
        case .analysisStarted, .analysisFinished:
            return .lifecycle
        case .progressUpdate:
            return .progress
        case .sweepPointStarted, .sweepPointFinished:
            return .sweep
        case .newtonIterationStarted, .newtonIterationFinished, .newtonConvergenceFailure:
            return .newton
        case .timeStepCompleted, .timeStepRejected:
            return .timeStep
        case .gpuDispatchStarted, .gpuDispatchFinished:
            return .gpu
        case .metricSample:
            return .metric
        case .warning, .error:
            return .diagnostic
        }
    }
}
