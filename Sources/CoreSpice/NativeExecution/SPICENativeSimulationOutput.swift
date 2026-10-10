import CircuiteFoundation
import CoreSpiceAnalysis
import CoreSpiceWaveform
import CoreSpiceParsedIR

public struct SPICENativeSimulationOutput: Sendable {
    public let prepared: SPICENativeSimulationRecord
    public let waveform: WaveformData
    public let executedModels: [SPICENativeModelReceipt]
    public let statistics: TransientExecutionStatistics
    public var sourceInputIdentity: ContentDigest { prepared.input.sourceInputIdentity }
    public var configurationIdentity: ContentDigest { prepared.configurationIdentity }
    private let reservation: NativeExecutionStorage
    internal init(prepared: SPICENativeSimulationRecord, waveform: WaveformData,
                  executedModels: [SPICENativeModelReceipt], statistics: TransientExecutionStatistics,
                  reservation: NativeExecutionStorage) {
        self.prepared = prepared; self.waveform = waveform; self.executedModels = executedModels
        self.statistics = statistics; self.reservation = reservation
    }
}
