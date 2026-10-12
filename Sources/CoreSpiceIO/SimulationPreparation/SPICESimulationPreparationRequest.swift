import CoreSpiceParser
import CoreSpiceLowering
import CoreSpiceMOSContracts
import CoreSpiceParsedIR

public struct SPICESimulationPreparationRequest: Sendable {
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
                temperaturePolicy: NetlistTemperaturePolicy? = nil) {
        self.temperaturePolicy = temperaturePolicy
        self.profile = profile; self.seed = seed; self.resolutionLimits = resolutionLimits
        self.root = root; self.environment = environment; self.catalog = catalog; self.routes = routes
        self.provider = provider; self.configuration = configuration; self.analysisIndex = analysisIndex
        self.supplyBindings = supplyBindings; self.operatingPolicy = operatingPolicy; self.limits = limits
    }
}
