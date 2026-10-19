/// Numerical integration method used for transient analysis.
public enum IntegrationMethod: Sendable {
    case backwardEuler
    case trapezoidal
}

/// State carried by the transient integration engine.
///
/// Devices use this to build their companion models when stamping
/// reactive elements (capacitors, inductors) into the MNA system.
public struct IntegrationState: Sendable {

    public let method: IntegrationMethod
    public let timeStep: Double
    public let currentTime: Double
    public let previousTimeStep: Double?

    public let timeStepLowComponent: Double
    public let previousTimeStepLowComponent: Double?

    public init(method: IntegrationMethod, timeStep: Double, currentTime: Double, previousTimeStep: Double? = nil,
                timeStepLowComponent: Double = 0, previousTimeStepLowComponent: Double? = nil) {
        self.timeStepLowComponent = timeStepLowComponent
        self.previousTimeStepLowComponent = previousTimeStepLowComponent
        self.method = method
        self.timeStep = timeStep
        self.currentTime = currentTime
        self.previousTimeStep = previousTimeStep
    }

    public var compensatedTimeStep: CompensatedValue {
        get throws { try CompensatedValue(high: timeStep, low: timeStepLowComponent) }
    }

    public var compensatedPreviousTimeStep: CompensatedValue? {
        get throws {
            guard let previousTimeStep else {
                if previousTimeStepLowComponent != nil { throw NumericalStateError.missingHighHistory }
                return nil
            }
            return try CompensatedValue(high: previousTimeStep, low: previousTimeStepLowComponent ?? 0)
        }
    }

    /// Coefficient for the companion model: `C * coefficient` or `L / coefficient`.
    ///
    /// - Backward Euler: `1 / dt`
    /// - Trapezoidal: `2 / dt`
    public var coefficient: Double {
        switch method {
        case .backwardEuler:
            return 1.0 / timeStep
        case .trapezoidal:
            return 2.0 / timeStep
        }
    }
}
