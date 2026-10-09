import CircuiteFoundation
import CoreSpiceIR
import CoreSpiceParsedIR

/// Only the checked preparation algorithm can create this retained owner.
public struct PreparedSPICESimulation: Sendable {
    public let parsedResult: SPICEOwnedParseResult
    public var netlist: ParsedNetlist { parsedResult.netlist }
    public let sourceOccurrences: SPICEAccountedCollection<SPICESimulationSourceOccurrence>
    public let sources: [SPICECheckedSource]
    public let circuit: CircuitIR
    public let configuration: SPICEEffectiveSimulationConfiguration
    public let sourceInputIdentity: ContentDigest
    public let initialConditions: SPICEOwnedNodeVoltages
    public let nodeSets: SPICEOwnedNodeVoltages
    package let resources: any SPICESourceResourceAccounting
    package let maximumTransformBytes: UInt64
    private let reservation: SPICESourceStorageReservation
    internal init(parsedResult: SPICEOwnedParseResult, sourceOccurrences: SPICEAccountedCollection<SPICESimulationSourceOccurrence>, sources: [SPICECheckedSource], circuit: CircuitIR,
                  configuration: SPICEEffectiveSimulationConfiguration, sourceInputIdentity: ContentDigest,
                  initialConditions: SPICEOwnedNodeVoltages, nodeSets: SPICEOwnedNodeVoltages,
                  reservation: SPICESourceStorageReservation, resources: any SPICESourceResourceAccounting,
                  maximumTransformBytes: UInt64) {
        self.sourceOccurrences = sourceOccurrences
        self.parsedResult = parsedResult; self.sources = sources; self.circuit = circuit
        self.configuration = configuration; self.sourceInputIdentity = sourceInputIdentity
        self.resources = resources; self.maximumTransformBytes = maximumTransformBytes
        self.initialConditions = initialConditions; self.nodeSets = nodeSets; self.reservation = reservation
    }
}
