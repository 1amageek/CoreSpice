/// Configuration options for netlist parsing.
///
/// Parser configuration controls how the parser handles various
/// situations and what features are enabled.
public struct ParserConfiguration: Sendable {

    /// Whether to enable strict mode (fail on warnings).
    public var strictMode: Bool

    /// Whether to parse continuation lines (+ at start of line).
    public var allowContinuationLines: Bool

    /// Whether to be case-insensitive for identifiers.
    public var caseInsensitive: Bool

    /// Whether to allow HSPICE extensions.
    public var allowHSPICEExtensions: Bool

    /// Whether to allow ngspice extensions.
    public var allowNgspiceExtensions: Bool

    /// Whether to allow Spectre syntax in SPICE files.
    public var allowSpectreInSPICE: Bool

    /// Maximum include depth to prevent infinite recursion.
    public var maxIncludeDepth: Int

    /// Whether to collect all diagnostics or stop at first error.
    public var collectAllDiagnostics: Bool

    /// Whether to resolve includes at parse time.
    /// When true, .include and .lib files are read and parsed inline.
    /// When false, they are stored as control statements for later resolution.
    public var resolveIncludes: Bool

    /// The default temperature in Celsius.
    public var defaultTemperature: Double

    /// The default model level for MOSFETs.
    public var defaultMOSLevel: Int

    /// Additional search paths for includes.
    public var includePaths: [String]

    /// Creates a configuration with default values.
    public init(
        strictMode: Bool = false,
        allowContinuationLines: Bool = true,
        caseInsensitive: Bool = true,
        allowHSPICEExtensions: Bool = true,
        allowNgspiceExtensions: Bool = true,
        allowSpectreInSPICE: Bool = false,
        maxIncludeDepth: Int = 32,
        collectAllDiagnostics: Bool = true,
        resolveIncludes: Bool = false,
        defaultTemperature: Double = 27.0,
        defaultMOSLevel: Int = 1,
        includePaths: [String] = []
    ) {
        self.strictMode = strictMode
        self.allowContinuationLines = allowContinuationLines
        self.caseInsensitive = caseInsensitive
        self.allowHSPICEExtensions = allowHSPICEExtensions
        self.allowNgspiceExtensions = allowNgspiceExtensions
        self.allowSpectreInSPICE = allowSpectreInSPICE
        self.maxIncludeDepth = maxIncludeDepth
        self.collectAllDiagnostics = collectAllDiagnostics
        self.resolveIncludes = resolveIncludes
        self.defaultTemperature = defaultTemperature
        self.defaultMOSLevel = defaultMOSLevel
        self.includePaths = includePaths
    }

    /// A default configuration suitable for most SPICE files.
    public static let `default` = ParserConfiguration()

    /// A strict configuration for validation.
    public static let strict = ParserConfiguration(
        strictMode: true,
        allowHSPICEExtensions: false,
        allowNgspiceExtensions: false,
        collectAllDiagnostics: true
    )

    /// A permissive configuration accepting most formats.
    public static let permissive = ParserConfiguration(
        strictMode: false,
        allowHSPICEExtensions: true,
        allowNgspiceExtensions: true,
        allowSpectreInSPICE: true
    )
}
