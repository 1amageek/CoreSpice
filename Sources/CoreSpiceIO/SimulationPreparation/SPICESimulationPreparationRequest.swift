import CoreSpiceParser
import CoreSpiceParsedIR

public struct SPICESimulationPreparationRequest: Sendable {
    public let root: SPICECheckedSource
    public let environment: SPICEPreprocessingEnvironment
    public let catalog: [SPICEExactSourceBinding]
    public let routes: [SPICESourceCatalogRoute]
    public let provider: any SPICEExactSourceProviding
    public let configuration: ParserConfiguration
    public let analysisIndex: Int?
    public let supplyBindings: [SPICESupplyBinding]
    public let operatingPolicy: SPICEOperatingConditionPolicy
    public let limits: SPICESimulationPreparationLimits

    public init(root: SPICECheckedSource, environment: SPICEPreprocessingEnvironment,
                catalog: [SPICEExactSourceBinding], routes: [SPICESourceCatalogRoute],
                provider: any SPICEExactSourceProviding, configuration: ParserConfiguration,
                analysisIndex: Int? = nil, supplyBindings: [SPICESupplyBinding] = [],
                operatingPolicy: SPICEOperatingConditionPolicy,
                limits: SPICESimulationPreparationLimits) {
        self.root = root; self.environment = environment; self.catalog = catalog; self.routes = routes
        self.provider = provider; self.configuration = configuration; self.analysisIndex = analysisIndex
        self.supplyBindings = supplyBindings; self.operatingPolicy = operatingPolicy; self.limits = limits
    }
}
