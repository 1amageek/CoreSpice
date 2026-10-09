import CircuiteFoundation
import CoreSpiceAnalysis
import CoreSpiceIR

public struct SPICEEffectiveSimulationConfiguration: Sendable {
    public enum Analysis: Sendable {
        case op
        case dc(sourceName: String, values: [Double], isSupply: Bool)
        case transient(TransientConfig)
    }
    public let analysis: Analysis
    public let analysisIndex: Int
    public let options: SPICEAnalysisOptions
    public let temperatureCelsius: Double
    public let temperatureOrigin: String
    public let nominalTemperatureCelsius: Double
    public let nominalTemperatureOrigin: String
    public let instanceOperatingConditions: [SPICEInstanceOperatingConditions]
    public let supplyBindings: [SPICESupplyBinding]
    public let prescribedSupplies: [[Double]]
    public let operatingPolicy: SPICEOperatingConditionPolicy
    public let numericalLimits: TransientExecutionLimits
    public let seed: UInt64
    public let identity: ContentDigest
}
