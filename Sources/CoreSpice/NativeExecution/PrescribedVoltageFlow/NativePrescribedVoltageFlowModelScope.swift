import CircuiteFoundation
import CoreSpiceParsedIR
import OSDIContracts
import OSDIRuntime

/// Actual retained source bindings and projection; no Physical candidate association.
public struct NativePrescribedVoltageFlowModelScope: Sendable {
    // Escaping an immutable element must retain the original proof and storage owners.
    private let initialOwner: NativePrescribedVoltageInitialRoot
    private let windowOwner: NativePrescribedVoltageChart
    private let storage: SPICESourceStorageReservation
    public let deviceIndex: Int
    public let preparation: NativeOSDIPreparationRecord
    public let initialBinding: OSDIPrecisionConstitutiveBinding
    public let windowBinding: OSDIPrecisionConstitutiveBinding
    public let smoothBinding: OSDIPrecisionChartBinding
    public let workerReference: ArtifactReference
    public let numericProfile: ContentDigest
    public let options: OSDIPrecisionOptions
    public let coverLimits: OSDIPrecisionDecisionCoverLimits
    public let identityLimits: OSDIPrecisionConstitutiveLimits
    public let requestedPrecisionBits: UInt32
    internal init(initialOwner: NativePrescribedVoltageInitialRoot, windowOwner: NativePrescribedVoltageChart,
        storage: SPICESourceStorageReservation, deviceIndex: Int, preparation: NativeOSDIPreparationRecord,
        initialBinding: OSDIPrecisionConstitutiveBinding, windowBinding: OSDIPrecisionConstitutiveBinding,
        smoothBinding: OSDIPrecisionChartBinding, workerReference: ArtifactReference,
        numericProfile: ContentDigest, options: OSDIPrecisionOptions,
        coverLimits: OSDIPrecisionDecisionCoverLimits, identityLimits: OSDIPrecisionConstitutiveLimits,
        requestedPrecisionBits: UInt32) {
        self.initialOwner = initialOwner; self.windowOwner = windowOwner; self.storage = storage
        self.deviceIndex = deviceIndex; self.preparation = preparation
        self.initialBinding = initialBinding; self.windowBinding = windowBinding; self.smoothBinding = smoothBinding
        self.workerReference = workerReference; self.numericProfile = numericProfile; self.options = options
        self.coverLimits = coverLimits; self.identityLimits = identityLimits; self.requestedPrecisionBits = requestedPrecisionBits
    }
}
