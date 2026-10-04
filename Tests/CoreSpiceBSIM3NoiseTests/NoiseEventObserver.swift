import CoreSpiceEvent
import Synchronization

final class NoiseEventObserver: AnalysisObserver {
    private let finishes = Mutex<[AnalysisFinishedInfo]>([])
    func onEvent(_ event: AnalysisEvent) {
        if case .analysisFinished(let info) = event, info.type == .noise {
            finishes.withLock { $0.append(info) }
        }
    }
    func snapshot() -> [AnalysisFinishedInfo] { finishes.withLock { $0 } }
}
