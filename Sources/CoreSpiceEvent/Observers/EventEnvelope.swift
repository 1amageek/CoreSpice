import Foundation

public struct EventEnvelope: Sendable, Codable {

    public let timestampNanos: Int64
    public let category: String
    public let eventType: String
    public let payload: [String: String]

    public init(event: AnalysisEvent) {
        timestampNanos = Int64(Date().timeIntervalSince1970 * 1_000_000_000)
        category = String(describing: event.category)
        eventType = EventEnvelope.eventTypeName(event)
        payload = EventEnvelope.buildPayload(event)
    }

    private static func eventTypeName(_ event: AnalysisEvent) -> String {
        switch event {
        case .analysisStarted: return "analysisStarted"
        case .analysisFinished: return "analysisFinished"
        case .progressUpdate: return "progressUpdate"
        case .sweepPointStarted: return "sweepPointStarted"
        case .sweepPointFinished: return "sweepPointFinished"
        case .newtonIterationStarted: return "newtonIterationStarted"
        case .newtonIterationFinished: return "newtonIterationFinished"
        case .newtonConvergenceFailure: return "newtonConvergenceFailure"
        case .timeStepCompleted: return "timeStepCompleted"
        case .timeStepRejected: return "timeStepRejected"
        case .gpuDispatchStarted: return "gpuDispatchStarted"
        case .gpuDispatchFinished: return "gpuDispatchFinished"
        case .metricSample: return "metricSample"
        case .warning: return "warning"
        case .error: return "error"
        }
    }

    private static func buildPayload(_ event: AnalysisEvent) -> [String: String] {
        switch event {
        case .analysisStarted(let info):
            return [
                "id": info.id.rawValue.uuidString,
                "type": info.type.rawValue,
                "nodeCount": String(info.nodeCount),
                "deviceCount": String(info.deviceCount),
            ]
        case .analysisFinished(let info):
            return [
                "id": info.id.rawValue.uuidString,
                "type": info.type.rawValue,
                "status": info.status.rawValue,
                "wallTime": String(describing: info.wallTime),
            ]
        case .progressUpdate(let info):
            return [
                "id": info.id.rawValue.uuidString,
                "fraction": String(info.fraction),
                "message": info.message,
            ]
        case .sweepPointStarted(let info):
            return [
                "id": info.id.rawValue.uuidString,
                "index": String(info.index),
                "total": String(info.total),
                "value": String(info.value),
                "parameterName": info.parameterName,
            ]
        case .sweepPointFinished(let info):
            return [
                "id": info.id.rawValue.uuidString,
                "index": String(info.index),
                "value": String(info.value),
                "parameterName": info.parameterName,
                "converged": String(info.converged),
                "iterations": String(info.iterations),
            ]
        case .newtonIterationStarted(let info):
            return [
                "id": info.id.rawValue.uuidString,
                "iteration": String(info.iteration),
                "maxIterations": String(info.maxIterations),
            ]
        case .newtonIterationFinished(let info):
            return [
                "id": info.id.rawValue.uuidString,
                "iteration": String(info.iteration),
                "residualNorm": String(info.residualNorm),
                "damping": String(info.damping),
                "converged": String(info.converged),
            ]
        case .newtonConvergenceFailure(let info):
            return [
                "id": info.id.rawValue.uuidString,
                "iteration": String(info.iteration),
                "residualNorm": String(info.residualNorm),
                "reason": info.reason,
            ]
        case .timeStepCompleted(let info):
            return [
                "id": info.id.rawValue.uuidString,
                "time": String(info.time),
                "timeStep": String(info.timeStep),
                "iterations": String(info.iterations),
                "lte": String(info.lte),
            ]
        case .timeStepRejected(let info):
            return [
                "id": info.id.rawValue.uuidString,
                "time": String(info.time),
                "rejectedStep": String(info.rejectedStep),
                "newStep": String(info.newStep),
                "reason": info.reason,
            ]
        case .gpuDispatchStarted(let info):
            return [
                "id": info.id.rawValue.uuidString,
                "kernelName": info.kernelName,
                "gridWidth": String(info.gridSize.width),
                "gridHeight": String(info.gridSize.height),
                "tag": info.tag,
            ]
        case .gpuDispatchFinished(let info):
            return [
                "id": info.id.rawValue.uuidString,
                "kernelName": info.kernelName,
                "elapsedTime": String(describing: info.elapsedTime),
                "tag": info.tag,
            ]
        case .metricSample(let info):
            return [
                "id": info.id.rawValue.uuidString,
                "name": info.name,
                "value": String(info.value),
                "unit": info.unit,
            ]
        case .warning(let info), .error(let info):
            return [
                "id": info.id.rawValue.uuidString,
                "code": info.code.rawValue,
                "message": info.message,
            ]
        }
    }
}
