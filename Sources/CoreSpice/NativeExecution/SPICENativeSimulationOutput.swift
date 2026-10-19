import CircuiteFoundation
import CoreSpiceAnalysis
import CoreSpiceWaveform
import CoreSpiceParsedIR

public struct SPICENativeSimulationOutput: Sendable {
    public let prepared: SPICENativeSimulationRecord
    public let waveform: WaveformData
    public let executedModels: [SPICENativeModelReceipt]
    public let operatingPoint: DCResult?
    public let storedDCResult: SPICENativeStoredDCResult?
    public let dcSweepResult: SweepResult<DCResult>?
    public let transientResult: TransientResult?
    public let networkResult: NetworkParameterResult?
    public let tfResult: TransferFunctionResult?
    public let sensitivityResult: SensitivityResult?
    public let acSensitivityResult: ACSensitivityResult?
    public let poleZeroResult: PoleZeroResult?
    public let fourierResult: FourierResult?
    public let noiseResult: NoiseResult?
    public let phases: [NativeCircuitExecutionFacts]
    public let statistics: TransientExecutionStatistics
    public var sourceInputIdentity: ContentDigest { prepared.input.sourceInputIdentity }
    public var configurationIdentity: ContentDigest { prepared.configurationIdentity }
    private let reservation: NativeExecutionStorage
    internal init(prepared: SPICENativeSimulationRecord, waveform: WaveformData,
                  executedModels: [SPICENativeModelReceipt], statistics: TransientExecutionStatistics,
                  reservation: NativeExecutionStorage, operatingPoint: DCResult? = nil,
                  dcSweepResult: SweepResult<DCResult>? = nil, storedDCResult: SPICENativeStoredDCResult? = nil, transientResult: TransientResult? = nil, noiseResult: NoiseResult? = nil,
                  phases: [NativeCircuitExecutionFacts] = [], networkResult: NetworkParameterResult? = nil, tfResult: TransferFunctionResult? = nil,
                  sensitivityResult: SensitivityResult? = nil, acSensitivityResult: ACSensitivityResult? = nil,
                  poleZeroResult: PoleZeroResult? = nil, fourierResult: FourierResult? = nil) {
        self.networkResult = networkResult
        self.tfResult = tfResult; self.sensitivityResult = sensitivityResult; self.acSensitivityResult = acSensitivityResult
        self.poleZeroResult = poleZeroResult; self.fourierResult = fourierResult
        self.prepared = prepared; self.waveform = waveform; self.executedModels = executedModels
        self.statistics = statistics; self.reservation = reservation
        self.storedDCResult = storedDCResult
        self.operatingPoint = operatingPoint; self.dcSweepResult = dcSweepResult; self.transientResult = transientResult
        self.noiseResult = noiseResult; self.phases = phases
    }
}
