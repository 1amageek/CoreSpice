import CircuiteFoundation
import CoreSpiceIR
import CoreSpiceLowering
import CoreSpiceParsedIR

/// Only the checked preparation algorithm can create this retained owner.
public struct PreparedSPICESimulation: Sendable {
    public let parsedResult: SPICEOwnedParseResult
    public var netlist: ParsedNetlist { parsedResult.netlist }
    public let sourceOccurrences: SPICEAccountedCollection<SPICESimulationSourceOccurrence>
    public let sources: [SPICECheckedSource]
    public let lowered: LoweredCircuit
    public var circuit: CircuitIR { lowered.circuit }
    public let configuration: SPICEEffectiveSimulationConfiguration
    public let sourceInputIdentity: ContentDigest
    public let initialConditions: SPICEOwnedNodeVoltages
    public let nodeSets: SPICEOwnedNodeVoltages
    package var retainedConfigurationBytes: UInt64 { reservation.byteCount }
    package let request: SPICESimulationPreparationRequest
    package let resources: any SPICESourceResourceAccounting
    package let maximumTransformBytes: UInt64
    private let reservation: SPICESourceStorageReservation
    private let frontendReservation: SPICESourceStorageReservation
    internal init(parsedResult: SPICEOwnedParseResult, sourceOccurrences: SPICEAccountedCollection<SPICESimulationSourceOccurrence>, sources: [SPICECheckedSource], lowered: LoweredCircuit,
                  configuration: SPICEEffectiveSimulationConfiguration, sourceInputIdentity: ContentDigest,
                  initialConditions: SPICEOwnedNodeVoltages, nodeSets: SPICEOwnedNodeVoltages,
                  reservation: SPICESourceStorageReservation, frontendReservation: SPICESourceStorageReservation, resources: any SPICESourceResourceAccounting,
                  maximumTransformBytes: UInt64, request: SPICESimulationPreparationRequest) {
        self.request = request
        self.frontendReservation = frontendReservation
        self.sourceOccurrences = sourceOccurrences
        self.parsedResult = parsedResult; self.sources = sources; self.lowered = lowered
        self.configuration = configuration; self.sourceInputIdentity = sourceInputIdentity
        self.resources = resources; self.maximumTransformBytes = maximumTransformBytes
        self.initialConditions = initialConditions; self.nodeSets = nodeSets; self.reservation = reservation
    }
    /// Preserves all owned storage while adding a stricter invocation cancellation boundary.
    package func checkingResources(_ accounting: any SPICESourceResourceAccounting) -> Self {
        Self(parsedResult: parsedResult, sourceOccurrences: sourceOccurrences, sources: sources, lowered: lowered,
            configuration: configuration, sourceInputIdentity: sourceInputIdentity, initialConditions: initialConditions,
            nodeSets: nodeSets, reservation: reservation, frontendReservation: frontendReservation,
            resources: accounting, maximumTransformBytes: maximumTransformBytes, request: request)
    }

}
