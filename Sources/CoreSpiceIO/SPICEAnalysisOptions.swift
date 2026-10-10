import CoreSpiceAnalysis
import CoreSpiceDevices
import CoreSpiceIR
import CoreSpiceLowering
import CoreSpiceMOSContracts
import CoreSpiceParsedIR
import Foundation

/// Analysis configuration resolved from SPICE control statements.
///
/// The parser owns syntax only. This type translates SPICE deck intent into
/// CoreSpice analysis configuration and records options that were intentionally
/// not applied.
public struct SPICEAnalysisOptions: Sendable {

    public var bsim4NoisePreparationRequested: Bool
    public var bsim4PreparationPolicy: BSIM4PreparationPolicy?
    public var executionLimits: TransientExecutionLimits?
    /// Whether the source deck declares any execution-limit option, including a partial policy.
    public private(set) var executionLimitOptionsPresent: Bool = false
    public var convergence: ConvergenceConfig
    public var transient: SPICETransientOptions
    public var temperatureCelsius: Double?
    public var nominalTemperatureCelsius: Double?
    public var geometryScale: Double?
    public var diagnostics: [SPICEAnalysisOptionDiagnostic]

    public init(
        executionLimits: TransientExecutionLimits? = nil,
        bsim4PreparationPolicy: BSIM4PreparationPolicy? = nil,
        bsim4NoisePreparationRequested: Bool = false,
        convergence: ConvergenceConfig = ConvergenceConfig(),
        transient: SPICETransientOptions = SPICETransientOptions(),
        temperatureCelsius: Double? = nil,
        nominalTemperatureCelsius: Double? = nil,
        geometryScale: Double? = nil,
        diagnostics: [SPICEAnalysisOptionDiagnostic] = []
    ) {
        self.bsim4NoisePreparationRequested = bsim4NoisePreparationRequested
        self.bsim4PreparationPolicy = bsim4PreparationPolicy
        self.executionLimits = executionLimits
        self.convergence = convergence
        self.transient = transient
        self.temperatureCelsius = temperatureCelsius
        self.nominalTemperatureCelsius = nominalTemperatureCelsius
        self.geometryScale = geometryScale
        self.diagnostics = diagnostics
    }

    public static let `default` = SPICEAnalysisOptions()

    /// Resolves controls through the caller's exclusive scalar evaluation session.
    public static func resolve(from compiled: CompiledNetlist,
                               session: inout NetlistLoweringSession) throws -> SPICEAnalysisOptions {
        do {
            guard compiled.sameStorage(as: session.compiled) else {
                throw MOSResolutionFailure.invalidRequest
            }
            return try checkedResolve(from: compiled, session: &session)
        } catch {
            session.poison(.invalidRequest)
            throw error
        }
    }

    private static func checkedResolve(from compiled: CompiledNetlist,
                                       session: inout NetlistLoweringSession) throws -> SPICEAnalysisOptions {
        let netlist = compiled.source
        var options = SPICEAnalysisOptions(bsim4NoisePreparationRequested: netlist.analyses.contains(where: requestsNoise))
        var diagnostics: [SPICEAnalysisOptionDiagnostic] = []
        let budgetKeys = ["tranmaxaccepted", "tranmaxattempts", "tranmaxiterations", "tranmaxscalars", "tranmaxdimension", "tranmaxwork", "tranmaxbreakpoints"]
        var budgetValues: [String: Int] = [:]

        for (index, control) in netlist.controls.enumerated() {
            switch control {
            case .option(let name, let sourceValue, let location):
                let key = normalizedOptionName(name)
                var value = sourceValue
                if isNumericOption(name), sourceValue != nil {
                    let slot = try compiled.scalarSlot(at: .control(index: index, field: "value"))
                    value = .numeric(try session.evaluateScalar(slot))
                }
                if key == "bsim4stressiterations" {
                    let count: Double
                    do { count = try positiveNumericOption(value, name: name) }
                    catch let error as SPICEAnalysisOptionError { throw error }
                    catch {
                        throw SPICEAnalysisOptionError.invalidOptionValue(name: name, value: String(describing: value),
                            reason: "Preparation budget could not be resolved: \(error)")
                    }
                    guard let bounded = UInt32(exactly: count) else {
                        throw SPICEAnalysisOptionError.invalidAnalysisValue(name: name, value: String(count),
                            reason: "BSIM4 preparation budget must fit positive UInt32")
                    }
                    options.bsim4PreparationPolicy = try BSIM4PreparationPolicy(maximumStressIterations: bounded)
                    continue
                }
                if budgetKeys.contains(key) {
                    budgetValues[key] = try positiveIntegerOption(value, name: name)
                    continue
                }
                try applyOption(
                    name: name,
                    value: value,
                    location: location,
                    options: &options,
                    diagnostics: &diagnostics
                )
            case .temp:
                let slot = try compiled.scalarSlot(at: .control(index: index, field: "value"))
                let temperature = try session.evaluateScalar(slot)
                try validateFinite(temperature, optionName: "temp")
                options.temperatureCelsius = temperature
            default:
                break
            }
        }

        options.executionLimitOptionsPresent = !budgetValues.isEmpty
        if let accepted = budgetValues[budgetKeys[0]], let attempts = budgetValues[budgetKeys[1]],
           let iterations = budgetValues[budgetKeys[2]], let scalars = budgetValues[budgetKeys[3]],
           let dimension = budgetValues[budgetKeys[4]], let work = budgetValues[budgetKeys[5]],
           let breakpoints = budgetValues[budgetKeys[6]] {
            options.executionLimits = TransientExecutionLimits(maximumAcceptedSteps: accepted,
                maximumSolveAttempts: attempts, maximumNewtonIterations: iterations,
                maximumSavedScalars: scalars, maximumMatrixDimension: dimension,
                maximumWorkUnits: work, maximumBreakpoints: breakpoints)
        }
        options.diagnostics = diagnostics
        return options
    }

    /// Returns the standard descriptor inventory; MOS preparation consumes explicit conditions separately.
    public func deviceRegistry() -> DeviceRegistry { .standard() }

    private static func requestsNoise(_ analysis: ParsedAnalysisCommand) -> Bool {
        switch analysis {
        case .noise: true
        case .monteCarlo(let specification): requestsNoise(specification.analysis)
        default: false
        }
    }

    /// Resolves validated device operating conditions for binding.
    public func operatingConditions() throws -> OperatingConditions {
        try OperatingConditions(
            temperatureCelsius: temperatureCelsius
                ?? 27.0,
            nominalTemperatureCelsius: nominalTemperatureCelsius ?? 27.0
        )
    }

    /// Creates a transient analysis configuration from a `.tran` directive and global options.
    public func transientConfig(
        executionLimits: TransientExecutionLimits? = nil,
        stopTime: Double,
        stepTime: Double?,
        startTime: Double?,
        maxStep: Double?,
        useInitialConditions: Bool,
        initialNodeVoltages: [Node: Double] = [:],
        nodeVoltageGuesses: [Node: Double] = [:]
    ) throws -> TransientConfig {
        guard stopTime > 0, stopTime.isFinite else {
            throw SPICEAnalysisOptionError.invalidAnalysisValue(
                name: "tstop",
                value: stopTime.description,
                reason: "transient stop time must be positive and finite"
            )
        }
        if let startTime {
            guard startTime >= 0, startTime.isFinite else {
                throw SPICEAnalysisOptionError.invalidAnalysisValue(
                    name: "tstart",
                    value: startTime.description,
                    reason: "transient start time must be non-negative and finite"
                )
            }
            guard startTime == 0 else {
                throw SPICEAnalysisOptionError.unsupportedAnalysisFeature(
                    name: "tstart",
                    reason: "CoreSpice does not yet support delayed transient output windows"
                )
            }
        }

        let selectedMaxStep = maxStep ?? transient.maxTimeStep ?? stepTime ?? (stopTime / 50.0)
        guard selectedMaxStep > 0, selectedMaxStep.isFinite else {
            throw SPICEAnalysisOptionError.invalidAnalysisValue(
                name: "maxTimeStep",
                value: selectedMaxStep.description,
                reason: "maximum transient time step must be positive and finite"
            )
        }

        let selectedInitialStep = transient.initialTimeStep ?? stepTime ?? selectedMaxStep
        guard selectedInitialStep > 0, selectedInitialStep.isFinite else {
            throw SPICEAnalysisOptionError.invalidAnalysisValue(
                name: "initialTimeStep",
                value: selectedInitialStep.description,
                reason: "initial transient time step must be positive and finite"
            )
        }

        let selectedMinTimeStep = transient.minTimeStep ?? 1e-18
        guard selectedMinTimeStep > 0, selectedMinTimeStep.isFinite else {
            throw SPICEAnalysisOptionError.invalidAnalysisValue(
                name: "minTimeStep",
                value: selectedMinTimeStep.description,
                reason: "minimum transient time step must be positive and finite"
            )
        }
        guard selectedMinTimeStep <= selectedMaxStep else {
            throw SPICEAnalysisOptionError.invalidAnalysisValue(
                name: "minTimeStep",
                value: selectedMinTimeStep.description,
                reason: "minimum transient time step must be less than or equal to maximum transient time step"
            )
        }

        let selectedLTETolerance = transient.lteTolerance ?? 1.0
        guard selectedLTETolerance > 0, selectedLTETolerance.isFinite else {
            throw SPICEAnalysisOptionError.invalidAnalysisValue(
                name: "lteTolerance",
                value: selectedLTETolerance.description,
                reason: "transient LTE tolerance must be positive and finite"
            )
        }

        let selectedMaxTimeStepReductions = transient.maxTimeStepReductions ?? 30
        guard selectedMaxTimeStepReductions >= 0 else {
            throw SPICEAnalysisOptionError.invalidAnalysisValue(
                name: "maxTimeStepReductions",
                value: selectedMaxTimeStepReductions.description,
                reason: "maximum transient time step reductions must be non-negative"
            )
        }

        let selectedShrinkFactor = transient.shrinkFactor ?? 0.5
        guard selectedShrinkFactor > 0, selectedShrinkFactor < 1.0, selectedShrinkFactor.isFinite else {
            throw SPICEAnalysisOptionError.invalidAnalysisValue(
                name: "shrinkFactor",
                value: selectedShrinkFactor.description,
                reason: "transient shrink factor must be finite and in the range (0, 1)"
            )
        }

        let selectedGminSteppingThreshold = transient.gminSteppingThreshold ?? 5
        guard selectedGminSteppingThreshold > 0 else {
            throw SPICEAnalysisOptionError.invalidAnalysisValue(
                name: "gminSteppingThreshold",
                value: selectedGminSteppingThreshold.description,
                reason: "GMIN stepping threshold must be positive"
            )
        }

        let selectedGminStepping = transient.gminStepping ?? GminStepping(
            initialGmin: 1e-3,
            finalGmin: 1e-12,
            reductionFactor: 10.0,
            maxSteps: 5
        )
        try Self.validateGminStepping(selectedGminStepping)

        let config = TransientConfig(
            stopTime: stopTime,
            executionLimits: executionLimits ?? self.executionLimits,
            maxTimeStep: selectedMaxStep,
            initialTimeStep: selectedInitialStep,
            minTimeStep: selectedMinTimeStep,
            initialMethod: transient.initialMethod ?? .backwardEuler,
            lteTolerance: selectedLTETolerance,
            maxTimeStepReductions: selectedMaxTimeStepReductions,
            shrinkFactor: selectedShrinkFactor,
            useInitialConditions: useInitialConditions,
            initialNodeVoltages: initialNodeVoltages,
            nodeVoltageGuesses: nodeVoltageGuesses,
            gminSteppingThreshold: selectedGminSteppingThreshold,
            gminStepping: selectedGminStepping
        )
        do {
            try config.validate()
        } catch let error as AnalysisError {
            guard case .invalidConfiguration(let message) = error else {
                throw error
            }
            throw SPICEAnalysisOptionError.invalidAnalysisValue(
                name: "transientConfig",
                value: "invalid",
                reason: message
            )
        }
        return config
    }

    private static func applyOption(
        name: String,
        value: ParsedParameterValue?,
        location: SourceLocation?,
        options: inout SPICEAnalysisOptions,
        diagnostics: inout [SPICEAnalysisOptionDiagnostic]
    ) throws {
        let key = normalizedOptionName(name)

        switch key {
        case "scale":
            options.geometryScale = try positiveNumericOption(value, name: name)
        case "tnom":
            let temperature = try numericOption(value, name: name)
            guard temperature.isFinite, temperature + 273.15 > 0 else {
                throw SPICEAnalysisOptionError.invalidOptionValue(name: name, value: String(temperature),
                    reason: "Nominal temperature must be finite and above absolute zero")
            }
            options.nominalTemperatureCelsius = temperature
        case "abstol":
            options.convergence.abstol = try positiveNumericOption(value, name: name)
        case "reltol":
            options.convergence.reltol = try positiveNumericOption(value, name: name)
        case "vntol":
            options.convergence.vntol = try positiveNumericOption(value, name: name)
        case "gmin":
            options.convergence.gmin = try nonNegativeNumericOption(value, name: name)
        case "itl1", "itl4", "itmax", "maxiter", "maxiters":
            options.convergence.maxIterations = try positiveIntegerOption(value, name: name)
        case "mindamping", "dampmin":
            let damping = try positiveNumericOption(value, name: name)
            guard damping <= 1.0 else {
                throw SPICEAnalysisOptionError.invalidOptionValue(
                    name: name,
                    value: damping.description,
                    reason: "minimum damping must be in the range (0, 1]"
                )
            }
            options.convergence.minDamping = damping
        case "opttol", "opticalpowertol", "opticalpowertolerance":
            options.convergence.opticalPowerTolerance = try positiveNumericOption(
                value,
                name: name
            )
        case "temp":
            let temperature = try numericOption(value, name: name)
            try validateFinite(temperature, optionName: name)
            options.temperatureCelsius = temperature
        case "method":
            options.transient.initialMethod = try integrationMethodOption(value, name: name)
        case "maxstep", "delmax":
            options.transient.maxTimeStep = try positiveNumericOption(value, name: name)
        case "initstep", "initialstep", "tstep":
            options.transient.initialTimeStep = try positiveNumericOption(value, name: name)
        case "minstep", "delmin":
            options.transient.minTimeStep = try positiveNumericOption(value, name: name)
        case "ltetol", "ltetolerance":
            options.transient.lteTolerance = try positiveNumericOption(value, name: name)
        case "maxstepreductions":
            options.transient.maxTimeStepReductions = try positiveIntegerOption(
                value,
                name: name
            )
        case "shrink", "shrinkfactor":
            let shrinkFactor = try positiveNumericOption(value, name: name)
            guard shrinkFactor < 1.0 else {
                throw SPICEAnalysisOptionError.invalidOptionValue(
                    name: name,
                    value: shrinkFactor.description,
                    reason: "transient shrink factor must be in the range (0, 1)"
                )
            }
            options.transient.shrinkFactor = shrinkFactor
        case "gminsteppingthreshold":
            options.transient.gminSteppingThreshold = try positiveIntegerOption(
                value,
                name: name
            )
        case "gmininitial":
            let initial = try positiveNumericOption(value, name: name)
            let current = options.transient.gminStepping ?? GminStepping()
            options.transient.gminStepping = GminStepping(
                initialGmin: initial,
                finalGmin: current.finalGmin,
                reductionFactor: current.reductionFactor,
                maxSteps: current.maxSteps
            )
        case "gminfinal":
            let final = try positiveNumericOption(value, name: name)
            let current = options.transient.gminStepping ?? GminStepping()
            options.transient.gminStepping = GminStepping(
                initialGmin: current.initialGmin,
                finalGmin: final,
                reductionFactor: current.reductionFactor,
                maxSteps: current.maxSteps
            )
        case "gminsteps":
            let steps = try positiveIntegerOption(value, name: name)
            let current = options.transient.gminStepping ?? GminStepping()
            options.transient.gminStepping = GminStepping(
                initialGmin: current.initialGmin,
                finalGmin: current.finalGmin,
                reductionFactor: current.reductionFactor,
                maxSteps: steps
            )
        case "maxord":
            throw SPICEAnalysisOptionError.unsupportedOptionValue(
                name: name,
                value: value?.description ?? "true",
                reason: "CoreSpice transient integration does not expose a persistent integration order limit"
            )
        default:
            diagnostics.append(SPICEAnalysisOptionDiagnostic(
                name: name,
                valueDescription: value?.description,
                message: "SPICE option '\(name)' is not applied by CoreSpice",
                location: location
            ))
        }
    }

    /// Syntax inventory only; this does not evaluate a scalar or consume randomness.
    internal static func isNumericOption(_ name: String) -> Bool {
        switch normalizedOptionName(name) {
        case "scale", "tnom", "abstol", "reltol", "vntol", "gmin", "itl1", "itl4", "itmax", "maxiter", "maxiters",
             "mindamping", "dampmin", "opttol", "opticalpowertol", "opticalpowertolerance", "temp",
             "maxstep", "delmax", "initstep", "initialstep", "tstep", "minstep", "delmin", "ltetol", "ltetolerance",
             "maxstepreductions", "shrink", "shrinkfactor", "gminsteppingthreshold", "gmininitial", "gminfinal", "gminsteps",
             "bsim4stressiterations", "tranmaxaccepted", "tranmaxattempts", "tranmaxiterations", "tranmaxscalars",
             "tranmaxdimension", "tranmaxwork", "tranmaxbreakpoints": true
        default: false
        }
    }

    private static func normalizedOptionName(_ name: String) -> String {
        name.lowercased().replacingOccurrences(of: "_", with: "")
    }

    private static func numericOption(
        _ value: ParsedParameterValue?,
        name: String
    ) throws -> Double {
        guard let value else {
            throw SPICEAnalysisOptionError.missingOptionValue(name: name)
        }
        let result = try numericValue(value, optionName: name)
        try validateFinite(result, optionName: name)
        return result
    }

    private static func positiveNumericOption(
        _ value: ParsedParameterValue?,
        name: String
    ) throws -> Double {
        let result = try numericOption(value, name: name)
        guard result > 0 else {
            throw SPICEAnalysisOptionError.invalidOptionValue(
                name: name,
                value: result.description,
                reason: "value must be positive"
            )
        }
        return result
    }

    private static func nonNegativeNumericOption(
        _ value: ParsedParameterValue?,
        name: String
    ) throws -> Double {
        let result = try numericOption(value, name: name)
        guard result >= 0 else {
            throw SPICEAnalysisOptionError.invalidOptionValue(
                name: name,
                value: result.description,
                reason: "value must be non-negative"
            )
        }
        return result
    }

    private static func positiveIntegerOption(
        _ value: ParsedParameterValue?,
        name: String
    ) throws -> Int {
        let result = try positiveNumericOption(value, name: name)
        let rounded = result.rounded()
        guard abs(result - rounded) <= Double.ulpOfOne * max(1.0, abs(result)) else {
            throw SPICEAnalysisOptionError.invalidOptionValue(
                name: name,
                value: result.description,
                reason: "value must be an integer"
            )
        }
        guard let integer = Int(exactly: rounded) else {
            throw SPICEAnalysisOptionError.invalidOptionValue(name: name, value: result.description,
                reason: "value must fit Int")
        }
        return integer
    }

    private static func numericValue(
        _ value: ParsedParameterValue,
        optionName: String
    ) throws -> Double {
        switch value {
        case .numeric(let number): return number
        case .boolean(let flag): return flag ? 1 : 0
        case .expression:
            throw MOSResolutionFailure.invalidRequest
        case .numericVector:
            throw SPICEAnalysisOptionError.invalidOptionValue(name: optionName, value: value.description, reason: "value must be scalar")
        case .string(let text):
            throw SPICEAnalysisOptionError.invalidOptionValue(
                name: optionName,
                value: text,
                reason: "value must be numeric"
            )
        }
    }

    private static func validateFinite(_ value: Double, optionName: String) throws {
        guard value.isFinite else {
            throw SPICEAnalysisOptionError.invalidOptionValue(
                name: optionName,
                value: value.description,
                reason: "value must be finite"
            )
        }
    }

    private static func validateGminStepping(_ gminStepping: GminStepping) throws {
        guard gminStepping.initialGmin > 0, gminStepping.initialGmin.isFinite else {
            throw SPICEAnalysisOptionError.invalidAnalysisValue(
                name: "gminStepping.initialGmin",
                value: gminStepping.initialGmin.description,
                reason: "initial transient GMIN must be positive and finite"
            )
        }
        guard gminStepping.finalGmin >= 0, gminStepping.finalGmin.isFinite else {
            throw SPICEAnalysisOptionError.invalidAnalysisValue(
                name: "gminStepping.finalGmin",
                value: gminStepping.finalGmin.description,
                reason: "final transient GMIN must be non-negative and finite"
            )
        }
        guard gminStepping.initialGmin >= gminStepping.finalGmin else {
            throw SPICEAnalysisOptionError.invalidAnalysisValue(
                name: "gminStepping.initialGmin",
                value: gminStepping.initialGmin.description,
                reason: "initial transient GMIN must be greater than or equal to final transient GMIN"
            )
        }
        guard gminStepping.reductionFactor > 1, gminStepping.reductionFactor.isFinite else {
            throw SPICEAnalysisOptionError.invalidAnalysisValue(
                name: "gminStepping.reductionFactor",
                value: gminStepping.reductionFactor.description,
                reason: "transient GMIN reduction factor must be finite and greater than one"
            )
        }
        guard gminStepping.maxSteps > 0 else {
            throw SPICEAnalysisOptionError.invalidAnalysisValue(
                name: "gminStepping.maxSteps",
                value: gminStepping.maxSteps.description,
                reason: "transient GMIN max steps must be positive"
            )
        }
    }

    private static func integrationMethodOption(
        _ value: ParsedParameterValue?,
        name: String
    ) throws -> IntegrationMethod {
        let text = try stringOption(value, name: name).lowercased()
        switch text {
        case "trap", "trapezoidal":
            return .trapezoidal
        case "be", "euler", "backwardeuler", "backward_euler":
            return .backwardEuler
        default:
            throw SPICEAnalysisOptionError.unsupportedOptionValue(
                name: name,
                value: text,
                reason: "supported integration methods are trap and backwardEuler"
            )
        }
    }

    private static func stringOption(
        _ value: ParsedParameterValue?,
        name: String
    ) throws -> String {
        guard let value else {
            throw SPICEAnalysisOptionError.missingOptionValue(name: name)
        }

        switch value {
        case .numericVector:
            throw SPICEAnalysisOptionError.invalidOptionValue(name: name, value: value.description, reason: "value must be scalar")
        case .string(let text):
            return text
        case .expression(.identifier(let identifier)):
            return identifier
        case .numeric(let numeric):
            return numeric.description
        case .boolean(let flag):
            return flag ? "true" : "false"
        case .expression(let expression):
            return expression.description
        }
    }
}
