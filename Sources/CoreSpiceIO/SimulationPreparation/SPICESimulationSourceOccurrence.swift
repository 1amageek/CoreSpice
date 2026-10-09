import CoreSpiceParser
import CoreSpiceParsedIR

/// Actual acquisition facts captured at the grammar boundary, retaining the complete checked source and context.
public struct SPICESimulationSourceOccurrence: Sendable {
    public let source: SPICECheckedSource
    public let occurrenceID: SPICEParseOccurrenceID
    public let parentOccurrenceID: SPICEParseOccurrenceID?
    public let statementByteOffset: UInt64?
    public let statementOrdinal: UInt64?
    public let kind: SPICESourceDependencyEvent.Kind?
    public let parentSection: String?
    public let selectedSection: String?
    public let environment: SPICEPreprocessingEnvironment
}
