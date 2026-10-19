import CoreSpiceIR
import CoreSpiceDevices
import CoreSpiceMOSContracts
import CoreSpiceDiodeContracts
import CoreSpiceParsedIR
import CoreSpiceAnalysis

/// Published only after a concrete numerical phase completes with these actual inputs.
public struct NativeCircuitExecutionFacts: Sendable {
    public let sourceReexecutionLedger: SPICENativeSourceReexecutionLedger?
    public var sourceReexecutions: [SPICENativeSourceReexecutionCompletion] { sourceReexecutionLedger?.records ?? [] }
    public let instances: [Instance]
    public let conditions: OperatingConditions
    /// Baseline binding plus every changed diode binding consumed by sensitivity.
    public let diodePerturbationReceipts: [DiodePreparationReceipt]
    public let osdiPreparationRecords: [NativeOSDIPreparationRecord]
    public let diodePreparationReceipts: [DiodePreparationReceipt]
    public let mosPreparationReceipts: [MOSPreparationReceipt]
    public let analysis: String
    public let completedPointCount: Int
    public let sourceName: String?
    public let sourceValue: Double?
    /// The actual original-equation gate used by a transient phase, when explicitly selected.
    public let equationPolicy: DCEquationPolicy?
    private let preparation: NativeCircuitPreparationRecord
    private let reservation: NativeExecutionStorage
    internal init(record: NativeCircuitPreparationRecord, instances: [Instance], analysis: String,
                  completedPointCount: Int, reservation: NativeExecutionStorage, sourceName: String? = nil, sourceValue: Double? = nil,
                  diodePerturbationReceipts: [DiodePreparationReceipt] = [], equationPolicy: DCEquationPolicy? = nil,
                  sourceReexecutionLedger: SPICENativeSourceReexecutionLedger? = nil) {
        self.sourceReexecutionLedger = sourceReexecutionLedger
        preparation = record; self.reservation = reservation
        self.instances = instances; conditions = record.operatingConditions
        self.diodePerturbationReceipts = diodePerturbationReceipts
        osdiPreparationRecords = record.osdiPreparationRecords
        diodePreparationReceipts = record.diodePreparationReceipts
        mosPreparationReceipts = record.mosPreparationReceipts; self.analysis = analysis
        self.completedPointCount = completedPointCount; self.sourceName = sourceName; self.sourceValue = sourceValue
        self.equationPolicy = equationPolicy
    }
}
