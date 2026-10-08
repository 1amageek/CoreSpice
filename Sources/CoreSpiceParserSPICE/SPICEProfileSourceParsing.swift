import CoreSpiceParsedIR
import CoreSpiceParser

/// Checked grammar intake over owned immutable source occurrences.
/// The provider owns source approval; this interface owns syntax and context.
public protocol SPICEProfileSourceParsing: Sendable {
    func parseProfile(document: SPICESourceDocument, configuration: ParserConfiguration,
                      environment: SPICEPreprocessingEnvironment,
                      resolver: any SPICEContextualFileResolver,
                      resources: any SPICESourceResourceAccounting) async throws -> SPICEOwnedParseResult
}
