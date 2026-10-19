import CoreSpiceLowering
import CoreSpiceParsedIR

/// Retains explicit-profile metadata in the caller's source-resource lifetime.
public struct SPICEExternalMOSPreparer: ExternalMOSPreparing {
    public let identity: String
    private let preparer: any ExternalMOSPreparing
    private let resources: any SPICESourceResourceAccounting
    private let metadata: SPICESourceStorageReservation

    public init(preparer: any ExternalMOSPreparing, resources: any SPICESourceResourceAccounting) throws {
        let identity = preparer.identity
        guard !identity.isEmpty, !identity.utf8.contains(0) else {
            throw SPICEExternalMOSPreparationFailure.invalidIdentity
        }
        try resources.checkCancellation()
        let (bytes, overflow) = UInt64(identity.utf8.count).addingReportingOverflow(UInt64(MemoryLayout<Self>.stride))
        guard !overflow else { throw SPICEExternalMOSPreparationFailure.capacityOverflow }
        try resources.charge(.retainedElements, units: 1)
        try resources.charge(.projectedBytes, units: UInt64(identity.utf8.count))
        let metadata = try resources.reserveStorage(kind: .liveOwnedBytes, byteCount: bytes)
        self.identity = identity; self.preparer = preparer; self.resources = resources; self.metadata = metadata
    }

    public func prepare(_ source: ExternalMOSSourceRequest,
                        evaluate: (ExternalMOSScalarAddress) throws -> Double,
                        chargeWork: () throws -> Void) throws -> ExternalMOSPreparation {
        try resources.checkCancellation()
        guard preparer.identity == identity else { throw ExternalMOSPreparationFailure.sourceMismatch }
        let result = try preparer.prepare(source, evaluate: { address in
            try resources.checkCancellation()
            return try evaluate(address)
        }, chargeWork: {
            try resources.checkCancellation()
            try chargeWork()
        })
        try resources.checkCancellation()
        guard preparer.identity == identity else { throw ExternalMOSPreparationFailure.sourceMismatch }
        return result
    }
}
