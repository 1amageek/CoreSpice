import CoreSpiceAnalysis
import CoreSpiceDevices

/// Transient-specific option overrides resolved from a SPICE deck.
public struct SPICETransientOptions: Sendable {

    public var maxTimeStep: Double?
    public var initialTimeStep: Double?
    public var minTimeStep: Double?
    public var initialMethod: IntegrationMethod?
    public var lteTolerance: Double?
    public var maxTimeStepReductions: Int?
    public var shrinkFactor: Double?
    public var gminSteppingThreshold: Int?
    public var gminStepping: GminStepping?

    public init(
        maxTimeStep: Double? = nil,
        initialTimeStep: Double? = nil,
        minTimeStep: Double? = nil,
        initialMethod: IntegrationMethod? = nil,
        lteTolerance: Double? = nil,
        maxTimeStepReductions: Int? = nil,
        shrinkFactor: Double? = nil,
        gminSteppingThreshold: Int? = nil,
        gminStepping: GminStepping? = nil
    ) {
        self.maxTimeStep = maxTimeStep
        self.initialTimeStep = initialTimeStep
        self.minTimeStep = minTimeStep
        self.initialMethod = initialMethod
        self.lteTolerance = lteTolerance
        self.maxTimeStepReductions = maxTimeStepReductions
        self.shrinkFactor = shrinkFactor
        self.gminSteppingThreshold = gminSteppingThreshold
        self.gminStepping = gminStepping
    }
}
