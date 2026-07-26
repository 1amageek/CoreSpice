/// A value that can be assigned to a device parameter.
public enum ParameterValue: Sendable {
    case real(Double)
    case integer(Int)
    case string(String)
    case complex(ComplexValue)
    case expression(Expression)
    case behavioralExpression(BehavioralExpression)
}

/// A complex number value with real and imaginary parts.
public struct ComplexValue: Hashable, Sendable {

    public let real: Double
    public let imag: Double

    public init(real: Double, imag: Double) {
        self.real = real
        self.imag = imag
    }
}

/// A symbolic expression represented as text.
///
/// Expressions are evaluated later during circuit compilation,
/// allowing parameter values to depend on other parameters or variables.
public struct Expression: Hashable, Sendable {

    public let text: String

    public init(text: String) {
        self.text = text
    }
}

/// Describes a parameter that a device accepts.
public struct ParameterDescriptor: Sendable {

    public let name: String
    public let defaultValue: ParameterValue?
    public let description: String

    public init(name: String, defaultValue: ParameterValue?, description: String) {
        self.name = name
        self.defaultValue = defaultValue
        self.description = description
    }
}
