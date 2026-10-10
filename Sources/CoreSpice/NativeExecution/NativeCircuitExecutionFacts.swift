import CoreSpiceIR
import CoreSpiceDevices
import CoreSpiceMOSContracts
import CoreSpiceParsedIR

/// Published only after a concrete numerical phase completes with these actual inputs.
public struct NativeCircuitExecutionFacts: Sendable {
    public let instances: [Instance]
    public let conditions: OperatingConditions
    public let mosPreparationReceipts: [MOSPreparationReceipt]
    public let analysis: String
    public let completedPointCount: Int
    public let sourceName: String?
    public let sourceValue: Double?
    private let preparation: NativeCircuitPreparationRecord
    private let reservation: NativeExecutionStorage
    internal init(record: NativeCircuitPreparationRecord, instances: [Instance], analysis: String,
                  completedPointCount: Int, reservation: NativeExecutionStorage, sourceName: String? = nil, sourceValue: Double? = nil) {
        preparation = record; self.reservation = reservation
        self.instances = instances; conditions = record.operatingConditions
        mosPreparationReceipts = record.mosPreparationReceipts; self.analysis = analysis
        self.completedPointCount = completedPointCount; self.sourceName = sourceName; self.sourceValue = sourceValue
    }
}
