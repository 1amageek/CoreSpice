import CoreSpiceParsedIR

/// One expected active grammar occurrence; order, physical location and context are semantic.
public struct SPICEExpectedDependency: Sendable, Hashable {
    public let parentKey: String
    public let childKey: String
    public let kind: SPICESourceDependencyEvent.Kind
    public let path: String
    public let selectedSection: String?
    public let line: Int
    public let column: Int
    public let preprocessingContext: [String: String]

    public init(parentKey: String, childKey: String, kind: SPICESourceDependencyEvent.Kind,
                path: String, selectedSection: String? = nil, line: Int, column: Int = 1,
                preprocessingContext: [String: String] = [:]) {
        self.parentKey = parentKey
        self.childKey = childKey
        self.kind = kind
        self.path = path
        self.selectedSection = selectedSection
        self.line = line
        self.column = column
        self.preprocessingContext = preprocessingContext
    }
}
