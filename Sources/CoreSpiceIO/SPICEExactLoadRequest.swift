import CoreSpiceParser

/// Immutable expected graph and preprocessing selection supplied by the caller.
public struct SPICEExactLoadRequest: Sendable {
    public let rootKey: String
    public let selectedSection: String?
    public let initialParameters: [String: String]
    public let expectedSources: [SPICEExactSourceBinding]
    public let expectedDependencies: [SPICEExpectedDependency]
    public let configuration: ParserConfiguration
    public let capturePolicy: SPICESourceCapturePolicy
    public let workLimits: SPICESourceWorkLimits

    public init(rootKey: String, selectedSection: String? = nil,
                initialParameters: [String: String] = [:], expectedSources: [SPICEExactSourceBinding],
                expectedDependencies: [SPICEExpectedDependency], configuration: ParserConfiguration,
                capturePolicy: SPICESourceCapturePolicy, workLimits: SPICESourceWorkLimits) {
        self.rootKey = rootKey
        self.selectedSection = selectedSection
        self.initialParameters = initialParameters
        self.expectedSources = expectedSources
        self.expectedDependencies = expectedDependencies
        self.configuration = configuration
        self.capturePolicy = capturePolicy
        self.workLimits = workLimits
    }
}
