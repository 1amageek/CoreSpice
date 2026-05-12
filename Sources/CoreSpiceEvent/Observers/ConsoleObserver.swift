public struct ConsoleObserver: AnalysisObserver {

    public init() {}

    public func onEvent(_ event: AnalysisEvent) {
        switch event {
        case .analysisStarted(let info):
            print("[CoreSpice] Analysis started: \(info.type.rawValue) (nodes=\(info.nodeCount), devices=\(info.deviceCount))")

        case .analysisFinished(let info):
            if let failure = info.failure {
                print("[CoreSpice] Analysis finished: \(info.type.rawValue) status=\(info.status.rawValue) reason=\(failure.reason) message=\(failure.message) wallTime=\(info.wallTime)")
            } else {
                print("[CoreSpice] Analysis finished: \(info.type.rawValue) status=\(info.status.rawValue) wallTime=\(info.wallTime)")
            }

        case .progressUpdate(let info):
            let percent = Int(info.fraction * 100)
            print("[CoreSpice] Progress: \(percent)% - \(info.message)")

        case .newtonIterationStarted(let info):
            print("[CoreSpice] Newton iteration \(info.iteration)/\(info.maxIterations)")

        case .newtonIterationFinished(let info):
            let status = info.converged ? "converged" : "continuing"
            print("[CoreSpice] Newton iteration \(info.iteration): residual=\(info.residualNorm) damping=\(info.damping) [\(status)]")

        case .newtonConvergenceFailure(let info):
            print("[CoreSpice] Newton convergence failure at iteration \(info.iteration): residual=\(info.residualNorm) reason=\(info.reason)")

        case .sweepPointStarted(let info):
            print("[CoreSpice] Sweep \(info.index + 1)/\(info.total): \(info.parameterName)=\(info.value)")

        case .sweepPointFinished(let info):
            let status = info.converged ? "converged" : "failed"
            print("[CoreSpice] Sweep point \(info.parameterName)=\(info.value): \(status) in \(info.iterations) iterations")

        case .timeStepCompleted(let info):
            print("[CoreSpice] Time step: t=\(info.time) dt=\(info.timeStep) iter=\(info.iterations) lte=\(info.lte)")

        case .timeStepRejected(let info):
            print("[CoreSpice] Time step rejected at t=\(info.time): dt=\(info.rejectedStep) -> \(info.newStep) reason=\(info.reason)")

        case .gpuDispatchStarted(let info):
            print("[CoreSpice] GPU dispatch: \(info.kernelName) grid=\(info.gridSize.width)x\(info.gridSize.height) [\(info.tag)]")

        case .gpuDispatchFinished(let info):
            print("[CoreSpice] GPU completed: \(info.kernelName) elapsed=\(info.elapsedTime) [\(info.tag)]")

        case .metricSample(let info):
            print("[CoreSpice] Metric: \(info.name)=\(info.value) \(info.unit)")

        case .warning(let info):
            print("[CoreSpice] WARNING [\(info.code.rawValue)]: \(info.message)")

        case .error(let info):
            print("[CoreSpice] ERROR [\(info.code.rawValue)]: \(info.message)")
        }
    }
}
