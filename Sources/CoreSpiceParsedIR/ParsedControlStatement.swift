/// A control statement parsed from the netlist.
///
/// Control statements affect simulation behavior, output, and options.
public enum ParsedControlStatement: Sendable, Hashable {

    /// Include another file.
    case include(path: String, location: SourceLocation?)

    /// Include a library section.
    case library(path: String, section: String?, location: SourceLocation?)

    /// Set a simulator option.
    case option(name: String, value: ParsedParameterValue?, location: SourceLocation?)

    /// Set temperature.
    case temp(value: ParsedParameterValue, location: SourceLocation?)

    /// Initial condition for a node.
    case initialCondition(node: String, voltage: ParsedParameterValue, location: SourceLocation?)

    /// Node set (initial guess) for a node.
    case nodeSet(node: String, voltage: ParsedParameterValue, location: SourceLocation?)

    /// Print output.
    case print(PrintSpec)

    /// Plot output.
    case plot(PlotSpec)

    /// Save variables.
    case save(variables: [String], location: SourceLocation?)

    /// Probe output.
    case probe(variables: [String], location: SourceLocation?)

    /// Measure statement.
    case measure(MeasureSpec)

    /// Global nodes declaration.
    case global(nodes: [String], location: SourceLocation?)

    /// End of netlist.
    case end(location: SourceLocation?)

    /// End of control section.
    case endControl(location: SourceLocation?)

    /// Alter parameters between analyses.
    case alter(AlterSpec)

    /// Function definition.
    case function(name: String, parameters: [String], body: ParsedExpression, location: SourceLocation?)

    /// HDL include (Verilog-A, etc.).
    case hdl(path: String, location: SourceLocation?)
}


/// Specification for print statements.
public struct PrintSpec: Sendable, Hashable {

    /// The analysis type for this output.
    public let analysisType: OutputAnalysisType

    /// Variables to print.
    public let variables: [OutputVariable]

    /// The source location.
    public let location: SourceLocation?

    public init(
        analysisType: OutputAnalysisType,
        variables: [OutputVariable],
        location: SourceLocation? = nil
    ) {
        self.analysisType = analysisType
        self.variables = variables
        self.location = location
    }
}

/// Specification for plot statements.
public struct PlotSpec: Sendable, Hashable {

    /// The analysis type for this output.
    public let analysisType: OutputAnalysisType

    /// Variables to plot.
    public let variables: [OutputVariable]

    /// The source location.
    public let location: SourceLocation?

    public init(
        analysisType: OutputAnalysisType,
        variables: [OutputVariable],
        location: SourceLocation? = nil
    ) {
        self.analysisType = analysisType
        self.variables = variables
        self.location = location
    }
}

/// Analysis type for output statements.
public enum OutputAnalysisType: String, Sendable, Hashable, Codable {
    case dc
    case ac
    case transient = "tran"
    case noise
    case op
}

/// An output variable specification.
public indirect enum OutputVariable: Sendable, Hashable {

    /// Voltage at a node.
    case voltage(node: String, reference: String?)

    /// Current through a device or branch.
    case current(device: String)

    /// Power dissipation in a device.
    case power(device: String)

    /// Magnitude of a complex variable.
    case magnitude(OutputVariable)

    /// Phase of a complex variable.
    case phase(OutputVariable)

    /// Real part of a complex variable.
    case real(OutputVariable)

    /// Imaginary part of a complex variable.
    case imaginary(OutputVariable)

    /// Decibel magnitude.
    case dB(OutputVariable)

    /// A general expression.
    case expression(ParsedExpression)
}

/// Specification for measure statements.
public struct MeasureSpec: Sendable, Hashable {

    /// Analysis type for measurement.
    public let analysisType: OutputAnalysisType

    /// Result variable name.
    public let resultName: String

    /// Measurement type.
    public let measureType: MeasureType

    /// The source location.
    public let location: SourceLocation?

    public init(
        analysisType: OutputAnalysisType,
        resultName: String,
        measureType: MeasureType,
        location: SourceLocation? = nil
    ) {
        self.analysisType = analysisType
        self.resultName = resultName
        self.measureType = measureType
        self.location = location
    }
}

/// Type of measurement to perform.
public enum MeasureType: Sendable, Hashable {

    /// Find when a condition is met.
    case when(condition: ParsedExpression, target: ParsedExpression?)

    /// Find value at a specific time/frequency.
    case find(variable: OutputVariable, at: ParsedParameterValue)

    /// Average value over a range.
    case average(variable: OutputVariable, from: ParsedParameterValue?, to: ParsedParameterValue?)

    /// RMS value over a range.
    case rms(variable: OutputVariable, from: ParsedParameterValue?, to: ParsedParameterValue?)

    /// Minimum value.
    case min(variable: OutputVariable, from: ParsedParameterValue?, to: ParsedParameterValue?)

    /// Maximum value.
    case max(variable: OutputVariable, from: ParsedParameterValue?, to: ParsedParameterValue?)

    /// Peak-to-peak value.
    case peakToPeak(variable: OutputVariable, from: ParsedParameterValue?, to: ParsedParameterValue?)

    /// Integral value.
    case integral(variable: OutputVariable, from: ParsedParameterValue?, to: ParsedParameterValue?)

    /// Rise time.
    case riseTime(variable: OutputVariable, lowThreshold: Double, highThreshold: Double)

    /// Fall time.
    case fallTime(variable: OutputVariable, highThreshold: Double, lowThreshold: Double)

    /// Delay between two signals.
    case delay(variable1: OutputVariable, value1: ParsedParameterValue, variable2: OutputVariable, value2: ParsedParameterValue)

    /// A parsed but unsupported measurement form.
    case unsupported(keyword: String, arguments: [String], reason: String)
}

/// Specification for alter statements.
public struct AlterSpec: Sendable, Hashable {

    /// The device or model to alter.
    public let target: String

    /// The parameter to change.
    public let parameter: String

    /// The new value.
    public let value: ParsedParameterValue

    /// The source location.
    public let location: SourceLocation?

    public init(
        target: String,
        parameter: String,
        value: ParsedParameterValue,
        location: SourceLocation? = nil
    ) {
        self.target = target
        self.parameter = parameter
        self.value = value
        self.location = location
    }
}
