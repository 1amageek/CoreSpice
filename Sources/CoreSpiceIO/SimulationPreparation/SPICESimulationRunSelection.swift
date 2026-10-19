import CoreSpiceLowering

/// One deterministic member of a captured source execution family.
public struct SPICESimulationRunSelection: Sendable {
    public enum SeedOrigin: String, Sendable { case callerOverride, sourceDirective, requestDefault }
    public let monteCarloSeedOrigin: SeedOrigin?
    public let seed: UInt64
    public let temperatureSelection: NetlistSourceTemperature?
    public let monteCarloIteration: Int?
    public let monteCarloIterations: Int?
    public let monteCarloBaseSeed: UInt64?

    package init(seed: UInt64, temperatureSelection: NetlistSourceTemperature?,
                 monteCarloIteration: Int? = nil, monteCarloIterations: Int? = nil,
                 monteCarloBaseSeed: UInt64? = nil, monteCarloSeedOrigin: SeedOrigin? = nil) {
        self.monteCarloSeedOrigin = monteCarloSeedOrigin
        self.seed = seed; self.temperatureSelection = temperatureSelection
        self.monteCarloIteration = monteCarloIteration; self.monteCarloIterations = monteCarloIterations
        self.monteCarloBaseSeed = monteCarloBaseSeed
    }
}
