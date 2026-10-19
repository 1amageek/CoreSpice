import CoreSpiceDevices

/// Actual accepted integration context, independent of output interpolation.
public struct TransientAcceptedStep: Sendable {
    public let time: Double
    public let timeStep: Double
    public let method: IntegrationMethod
    public let previousTimeStep: Double?

    public let timeStepLowComponent: Double
    public let previousTimeStepLowComponent: Double?

    public init(time: Double, timeStep: Double, method: IntegrationMethod, previousTimeStep: Double?, timeStepLowComponent: Double = 0, previousTimeStepLowComponent: Double? = nil) {
        self.timeStepLowComponent = timeStepLowComponent
        self.previousTimeStepLowComponent = previousTimeStepLowComponent
        self.time = time
        self.timeStep = timeStep
        self.method = method
        self.previousTimeStep = previousTimeStep
    }
}
