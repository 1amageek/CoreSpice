/// An analysis command parsed from the netlist.
///
/// Analysis commands specify what type of simulation to perform.
public indirect enum ParsedAnalysisCommand: Sendable, Hashable {

    /// DC operating point analysis.
    case op

    /// DC sweep analysis.
    case dc(DCAnalysisSpec)

    /// AC small-signal frequency analysis.
    case ac(ACAnalysisSpec)

    /// Transient (time-domain) analysis.
    case transient(TransientAnalysisSpec)

    /// Noise analysis.
    case noise(NoiseAnalysisSpec)

    /// Transfer function analysis.
    case transferFunction(TransferFunctionSpec)

    /// Sensitivity analysis.
    case sensitivity(SensitivitySpec)

    /// Monte Carlo analysis.
    case monteCarlo(MonteCarloSpec)

    /// Pole-zero analysis.
    case poleZero(PoleZeroSpec)

    /// Fourier analysis (performed after transient).
    case fourier(FourierSpec)
}

// MARK: - Analysis Specifications

/// Specification for DC sweep analysis.
public struct DCAnalysisSpec: Sendable, Hashable {

    /// The source to sweep.
    public let source: String

    /// The starting value.
    public let startValue: ParsedParameterValue

    /// The ending value.
    public let stopValue: ParsedParameterValue

    /// The step increment.
    public let stepValue: ParsedParameterValue

    /// Optional second source for nested sweep.
    public let source2: String?

    /// Second source start value.
    public let startValue2: ParsedParameterValue?

    /// Second source stop value.
    public let stopValue2: ParsedParameterValue?

    /// Second source step value.
    public let stepValue2: ParsedParameterValue?

    public init(
        source: String,
        startValue: ParsedParameterValue,
        stopValue: ParsedParameterValue,
        stepValue: ParsedParameterValue,
        source2: String? = nil,
        startValue2: ParsedParameterValue? = nil,
        stopValue2: ParsedParameterValue? = nil,
        stepValue2: ParsedParameterValue? = nil
    ) {
        self.source = source
        self.startValue = startValue
        self.stopValue = stopValue
        self.stepValue = stepValue
        self.source2 = source2
        self.startValue2 = startValue2
        self.stopValue2 = stopValue2
        self.stepValue2 = stepValue2
    }
}

/// The scale type for AC frequency sweeps.
public enum ACScaleType: String, Sendable, Hashable, Codable {
    case decade = "dec"
    case octave = "oct"
    case linear = "lin"
}

/// Specification for AC analysis.
public struct ACAnalysisSpec: Sendable, Hashable {

    /// The frequency scale type.
    public let scaleType: ACScaleType

    /// Number of points per decade/octave (or total for linear).
    public let numberOfPoints: Int

    /// Starting frequency in Hz.
    public let startFrequency: ParsedParameterValue

    /// Ending frequency in Hz.
    public let stopFrequency: ParsedParameterValue

    public init(
        scaleType: ACScaleType,
        numberOfPoints: Int,
        startFrequency: ParsedParameterValue,
        stopFrequency: ParsedParameterValue
    ) {
        self.scaleType = scaleType
        self.numberOfPoints = numberOfPoints
        self.startFrequency = startFrequency
        self.stopFrequency = stopFrequency
    }
}

/// Specification for transient analysis.
public struct TransientAnalysisSpec: Sendable, Hashable {

    /// The simulation stop time.
    public let stopTime: ParsedParameterValue

    /// The suggested step time (may be adjusted by the simulator).
    public let stepTime: ParsedParameterValue?

    /// The time at which to start saving data.
    public let startTime: ParsedParameterValue?

    /// The maximum step size.
    public let maxStep: ParsedParameterValue?

    /// Whether to use initial conditions.
    public let useInitialConditions: Bool

    public init(
        stopTime: ParsedParameterValue,
        stepTime: ParsedParameterValue? = nil,
        startTime: ParsedParameterValue? = nil,
        maxStep: ParsedParameterValue? = nil,
        useInitialConditions: Bool = false
    ) {
        self.stopTime = stopTime
        self.stepTime = stepTime
        self.startTime = startTime
        self.maxStep = maxStep
        self.useInitialConditions = useInitialConditions
    }
}

/// Specification for noise analysis.
public struct NoiseAnalysisSpec: Sendable, Hashable {

    /// Output node for noise measurement.
    public let outputNode: String

    /// Reference node (usually ground).
    public let referenceNode: String?

    /// Input source for noise figure calculation.
    public let inputSource: String

    /// Frequency sweep type.
    public let scaleType: ACScaleType

    /// Number of frequency points.
    public let numberOfPoints: Int

    /// Start frequency.
    public let startFrequency: ParsedParameterValue

    /// Stop frequency.
    public let stopFrequency: ParsedParameterValue

    public init(
        outputNode: String,
        referenceNode: String? = nil,
        inputSource: String,
        scaleType: ACScaleType,
        numberOfPoints: Int,
        startFrequency: ParsedParameterValue,
        stopFrequency: ParsedParameterValue
    ) {
        self.outputNode = outputNode
        self.referenceNode = referenceNode
        self.inputSource = inputSource
        self.scaleType = scaleType
        self.numberOfPoints = numberOfPoints
        self.startFrequency = startFrequency
        self.stopFrequency = stopFrequency
    }
}

/// Specification for transfer function analysis.
public struct TransferFunctionSpec: Sendable, Hashable {

    /// Output variable.
    public let output: String

    /// Input source.
    public let input: String

    public init(output: String, input: String) {
        self.output = output
        self.input = input
    }
}

/// Specification for sensitivity analysis.
public struct SensitivitySpec: Sendable, Hashable {

    /// Output variable to analyze.
    public let output: String

    /// Optional AC analysis specification for AC sensitivity.
    public let acSpec: ACAnalysisSpec?

    public init(output: String, acSpec: ACAnalysisSpec? = nil) {
        self.output = output
        self.acSpec = acSpec
    }
}

/// Statistical distribution type for Monte Carlo analysis.
public enum DistributionType: String, Sendable, Hashable, Codable {
    case gaussian = "gauss"
    case uniform = "unif"
    case lognormal = "lnorm"
}

/// Specification for Monte Carlo analysis.
public struct MonteCarloSpec: Sendable, Hashable {

    /// The underlying analysis to perform.
    public let analysis: ParsedAnalysisCommand

    /// Number of Monte Carlo iterations.
    public let iterations: Int

    /// The seed for random number generation.
    public let seed: Int?

    public init(
        analysis: ParsedAnalysisCommand,
        iterations: Int,
        seed: Int? = nil
    ) {
        self.analysis = analysis
        self.iterations = iterations
        self.seed = seed
    }
}

/// Specification for pole-zero analysis.
public struct PoleZeroSpec: Sendable, Hashable {

    /// Input node.
    public let inputNode: String

    /// Input reference node.
    public let inputReference: String

    /// Output node.
    public let outputNode: String

    /// Output reference node.
    public let outputReference: String

    /// Transfer type: voltage or current.
    public let transferType: TransferType

    /// Analysis type: poles, zeros, or both.
    public let analysisType: PoleZeroType

    public enum TransferType: String, Sendable, Hashable, Codable {
        case voltage = "vol"
        case current = "cur"
    }

    public enum PoleZeroType: String, Sendable, Hashable, Codable {
        case poles = "pol"
        case zeros = "zer"
        case both = "pz"
    }

    public init(
        inputNode: String,
        inputReference: String,
        outputNode: String,
        outputReference: String,
        transferType: TransferType,
        analysisType: PoleZeroType
    ) {
        self.inputNode = inputNode
        self.inputReference = inputReference
        self.outputNode = outputNode
        self.outputReference = outputReference
        self.transferType = transferType
        self.analysisType = analysisType
    }
}

/// Specification for Fourier analysis.
public struct FourierSpec: Sendable, Hashable {

    /// The fundamental frequency.
    public let frequency: ParsedParameterValue

    /// The output variables to analyze.
    public let outputs: [String]

    public init(frequency: ParsedParameterValue, outputs: [String]) {
        self.frequency = frequency
        self.outputs = outputs
    }
}
