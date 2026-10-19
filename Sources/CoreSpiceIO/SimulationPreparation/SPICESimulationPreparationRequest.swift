import CoreSpiceDiodeContracts
import CoreSpiceOSDIContracts
import CoreSpiceParser
import CoreSpiceLowering
import CoreSpiceMOSContracts
import CoreSpiceParsedIR

public struct SPICESimulationPreparationRequest: Sendable {
    package var runSelection: SPICESimulationRunSelection? = nil
    public let externalMOSPreparers: [String: any ExternalMOSPreparing]
    public let networkSelection: SPICENetworkParameterSelection?
    public let captureSourceScalars: Bool?
    public let monteCarloSeedOverride: UInt64?
    public let sourceOverrides: [NetlistSourceScalarOverride]
    public let temperatureSelection: NetlistSourceTemperature?
    public let parameterOverrides: [String: Double]
    public let osdiInstances: [String: OSDIResolvedInstance]
    public let diodeProfile: DiodeInputProfile?
    public let temperaturePolicy: NetlistTemperaturePolicy?
    public let root: SPICECheckedSource
    public let environment: SPICEPreprocessingEnvironment
    public let catalog: [SPICEExactSourceBinding]
    public let routes: [SPICESourceCatalogRoute]
    public let provider: any SPICEExactSourceProviding
    public let configuration: ParserConfiguration
    public let analysisIndex: Int?
    public let supplyBindings: [SPICESupplyBinding]
    public let operatingPolicy: SPICEOperatingConditionPolicy
    public let profile: MOSInputProfile
    public let seed: UInt64
    public let resolutionLimits: MOSResolutionLimits
    public let limits: SPICESimulationPreparationLimits

    public init(root: SPICECheckedSource, environment: SPICEPreprocessingEnvironment,
                catalog: [SPICEExactSourceBinding], routes: [SPICESourceCatalogRoute],
                provider: any SPICEExactSourceProviding, configuration: ParserConfiguration,
                analysisIndex: Int? = nil, supplyBindings: [SPICESupplyBinding] = [],
                operatingPolicy: SPICEOperatingConditionPolicy,
                limits: SPICESimulationPreparationLimits, profile: MOSInputProfile,
                seed: UInt64, resolutionLimits: MOSResolutionLimits,
                temperaturePolicy: NetlistTemperaturePolicy? = nil, diodeProfile: DiodeInputProfile? = nil,
                osdiInstances: [String: OSDIResolvedInstance] = [:],
                parameterOverrides: [String: Double] = [:],
                sourceOverrides: [NetlistSourceScalarOverride] = [],
                temperatureSelection: NetlistSourceTemperature? = nil, monteCarloSeedOverride: UInt64? = nil,
                captureSourceScalars: Bool? = nil, networkSelection: SPICENetworkParameterSelection? = nil, externalMOSPreparers: [String: any ExternalMOSPreparing] = [:]) {
        self.externalMOSPreparers = externalMOSPreparers
        self.networkSelection = networkSelection
        self.captureSourceScalars = captureSourceScalars
        self.monteCarloSeedOverride = monteCarloSeedOverride
        self.sourceOverrides = sourceOverrides; self.temperatureSelection = temperatureSelection
        self.parameterOverrides = parameterOverrides
        self.osdiInstances = osdiInstances
        self.diodeProfile = diodeProfile
        self.temperaturePolicy = temperaturePolicy
        self.profile = profile; self.seed = seed; self.resolutionLimits = resolutionLimits
        self.root = root; self.environment = environment; self.catalog = catalog; self.routes = routes
        self.provider = provider; self.configuration = configuration; self.analysisIndex = analysisIndex
        self.supplyBindings = supplyBindings; self.operatingPolicy = operatingPolicy; self.limits = limits
    }
}
