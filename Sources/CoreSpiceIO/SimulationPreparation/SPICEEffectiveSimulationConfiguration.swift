import CircuiteFoundation
import CoreSpiceAnalysis
import CoreSpiceIR

public struct SPICEEffectiveSimulationConfiguration: Sendable {
    public enum Analysis: Sendable {
        case network(frequencies: [Double], ports: [NetworkPort], limits: NetworkParameterLimits)
        case transferFunction(outputNode: Node, inputSourceName: String)
        case sensitivity(outputNode: Node, acSweep: FrequencySweep?)
        case poleZero(input: PoleZeroInput, outputNode: Node, referenceNode: Node, includePoles: Bool, includeZeros: Bool)
        case fourier(frequency: Double, outputs: [FourierOutput], transient: TransientConfig)
        case op
        case dc(sourceName: String, values: [Double], isSupply: Bool)
        case transient(TransientConfig)
        case ac(FrequencySweep)
        case noise(outputNode: Node, referenceNode: Node?, inputSourceName: String, sweep: FrequencySweep)
    }
    public let runSelection: SPICESimulationRunSelection
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
