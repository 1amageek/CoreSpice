import CoreSpiceIR
import CoreSpiceDevices
import CoreSpiceParsedIR

/// Actual bound native value law with checked signed incidence and identically zero Q.
/// This value does not establish a dynamic family, derivative, root, or history law.
public struct NativeVoltageSourceFact: Sendable {
    public let instance: Instance
    public let positiveNode: Node
    public let negativeNode: Node
    public let positiveRow: Int?
    public let negativeRow: Int?
    public let branch: Branch
    public let branchRow: Int
    public let dcVoltage: Double
    public let waveform: Waveform
    private let preparation: NativeCircuitPreparationRecord
    private let storage: SPICESourceStorageReservation

    internal init(_ fact: IndependentVoltageSourceFact, preparation: NativeCircuitPreparationRecord,
        storage: SPICESourceStorageReservation) {
        instance = fact.instance; positiveNode = fact.positiveNode; negativeNode = fact.negativeNode
        positiveRow = fact.positiveRow; negativeRow = fact.negativeRow
        branch = fact.branch; branchRow = fact.branchRow
        dcVoltage = fact.dcVoltage; waveform = fact.waveform
        self.preparation = preparation; self.storage = storage
    }
}
