import CoreSpiceEvent
import Synchronization

final class NoiseEventObserver: AnalysisObserver {
    private let finishes = Mutex<[AnalysisFinishedInfo]>([])
    let cancellation: CancellationToken?
    init(cancellation: CancellationToken? = nil) { self.cancellation = cancellation }
    func onEvent(_ event: AnalysisEvent) {
        if case .progressUpdate = event { cancellation?.cancel() }
        if case .analysisFinished(let info) = event, info.type == .noise { finishes.withLock { $0.append(info) } }
    }
    func snapshot() -> [AnalysisFinishedInfo] { finishes.withLock { $0 } }
}
