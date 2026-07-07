import Foundation

public struct CoreSpiceMetricMeasurementReport: Codable, Sendable, Hashable {
    public var runID: String?
    public var metrics: [CoreSpiceMetricMeasurement]

    public init(runID: String? = nil, metrics: [CoreSpiceMetricMeasurement]) {
        self.runID = runID
        self.metrics = metrics
    }
}

public struct CoreSpiceMetricMeasurement: Codable, Sendable, Hashable {
    public var name: String
    public var value: Double
    public var unit: String?

    public init(name: String, value: Double, unit: String? = nil) {
        self.name = name
        self.value = value
        self.unit = unit
    }
}

public struct CoreSpiceMetricSpecificationSet: Codable, Sendable, Hashable {
    public var specifications: [CoreSpiceMetricSpecification]

    public init(specifications: [CoreSpiceMetricSpecification]) {
        self.specifications = specifications
    }
}

public struct CoreSpiceMetricSpecification: Codable, Sendable, Hashable {
    public var name: String
    public var target: Double?
    public var minimum: Double?
    public var maximum: Double?
    public var tolerance: Double?
    public var weight: Double?

    public init(
        name: String,
        target: Double? = nil,
        minimum: Double? = nil,
        maximum: Double? = nil,
        tolerance: Double? = nil,
        weight: Double? = nil
    ) {
        self.name = name
        self.target = target
        self.minimum = minimum
        self.maximum = maximum
        self.tolerance = tolerance
        self.weight = weight
    }
}

public struct CoreSpiceMetricParameterSpace: Codable, Sendable, Hashable {
    public var parameters: [CoreSpiceBoundedParameter]

    public init(parameters: [CoreSpiceBoundedParameter]) {
        self.parameters = parameters
    }
}

public struct CoreSpiceBoundedParameter: Codable, Sendable, Hashable {
    public var name: String
    public var lowerBound: Double
    public var upperBound: Double
    public var nominalValue: Double?
    public var step: Double?
    public var unit: String?

    public init(
        name: String,
        lowerBound: Double,
        upperBound: Double,
        nominalValue: Double? = nil,
        step: Double? = nil,
        unit: String? = nil
    ) {
        self.name = name
        self.lowerBound = lowerBound
        self.upperBound = upperBound
        self.nominalValue = nominalValue
        self.step = step
        self.unit = unit
    }
}

public struct CoreSpiceMetricImprovementObjectiveRequest: Codable, Sendable, Hashable {
    public var problemID: String
    public var createdAt: String
    public var measurementReport: CoreSpiceMetricMeasurementReport
    public var specificationSet: CoreSpiceMetricSpecificationSet
    public var parameterSpace: CoreSpiceMetricParameterSpace
    public var sourceRefs: [CoreSpiceMetricImprovementSourceRef]

    public init(
        problemID: String,
        createdAt: String,
        measurementReport: CoreSpiceMetricMeasurementReport,
        specificationSet: CoreSpiceMetricSpecificationSet,
        parameterSpace: CoreSpiceMetricParameterSpace,
        sourceRefs: [CoreSpiceMetricImprovementSourceRef] = []
    ) {
        self.problemID = problemID
        self.createdAt = createdAt
        self.measurementReport = measurementReport
        self.specificationSet = specificationSet
        self.parameterSpace = parameterSpace
        self.sourceRefs = sourceRefs
    }
}

public struct CoreSpiceMetricImprovementPlanningProblem: Codable, Sendable, Hashable {
    public var schemaVersion: Int
    public var problemID: String
    public var createdAt: String
    public var status: String
    public var objectives: [CoreSpiceMetricImprovementObjective]
    public var parameterSpace: CoreSpiceMetricParameterSpace
    public var diagnostics: [CoreSpiceMetricImprovementDiagnostic]
    public var sourceRefs: [CoreSpiceMetricImprovementSourceRef]
    public var suggestedActions: [String]
    public var verificationGates: [String]

    public init(
        schemaVersion: Int = 1,
        problemID: String,
        createdAt: String,
        status: String,
        objectives: [CoreSpiceMetricImprovementObjective],
        parameterSpace: CoreSpiceMetricParameterSpace,
        diagnostics: [CoreSpiceMetricImprovementDiagnostic],
        sourceRefs: [CoreSpiceMetricImprovementSourceRef],
        suggestedActions: [String],
        verificationGates: [String]
    ) {
        self.schemaVersion = schemaVersion
        self.problemID = problemID
        self.createdAt = createdAt
        self.status = status
        self.objectives = objectives
        self.parameterSpace = parameterSpace
        self.diagnostics = diagnostics
        self.sourceRefs = sourceRefs
        self.suggestedActions = suggestedActions
        self.verificationGates = verificationGates
    }
}

public struct CoreSpiceMetricImprovementObjective: Codable, Sendable, Hashable {
    public var objectiveID: String
    public var metricName: String
    public var currentValue: Double
    public var target: Double?
    public var requiredMinimum: Double?
    public var requiredMaximum: Double?
    public var tolerance: Double?
    public var direction: String
    public var magnitude: Double
    public var weight: Double
    public var unit: String?

    public init(
        objectiveID: String,
        metricName: String,
        currentValue: Double,
        target: Double?,
        requiredMinimum: Double?,
        requiredMaximum: Double?,
        tolerance: Double?,
        direction: String,
        magnitude: Double,
        weight: Double,
        unit: String?
    ) {
        self.objectiveID = objectiveID
        self.metricName = metricName
        self.currentValue = currentValue
        self.target = target
        self.requiredMinimum = requiredMinimum
        self.requiredMaximum = requiredMaximum
        self.tolerance = tolerance
        self.direction = direction
        self.magnitude = magnitude
        self.weight = weight
        self.unit = unit
    }
}

public struct CoreSpiceMetricImprovementDiagnostic: Codable, Sendable, Hashable {
    public var severity: String
    public var code: String
    public var message: String
    public var metricName: String?

    public init(severity: String, code: String, message: String, metricName: String? = nil) {
        self.severity = severity
        self.code = code
        self.message = message
        self.metricName = metricName
    }
}

public struct CoreSpiceMetricImprovementSourceRef: Codable, Sendable, Hashable {
    public var refID: String
    public var path: String
    public var kind: String

    public init(refID: String, path: String, kind: String) {
        self.refID = refID
        self.path = path
        self.kind = kind
    }
}

public enum CoreSpiceMetricImprovementObjectiveError: Error, Equatable, LocalizedError {
    case emptyMetricReport
    case emptySpecifications
    case emptyParameterSpace
    case duplicateMetric(String)
    case duplicateSpecification(String)
    case duplicateParameter(String)
    case invalidMetricValue(String)
    case invalidSpecification(String)
    case invalidSpecificationBounds(String)
    case invalidParameterBounds(String)
    case invalidParameterStep(String)

    public var errorDescription: String? {
        switch self {
        case .emptyMetricReport:
            return "metric improvement objective requires at least one measurement"
        case .emptySpecifications:
            return "metric improvement objective requires at least one specification"
        case .emptyParameterSpace:
            return "metric improvement objective requires at least one bounded parameter"
        case .duplicateMetric(let name):
            return "duplicate metric measurement: \(name)"
        case .duplicateSpecification(let name):
            return "duplicate metric specification: \(name)"
        case .duplicateParameter(let name):
            return "duplicate bounded parameter: \(name)"
        case .invalidMetricValue(let name):
            return "metric measurement value must be finite: \(name)"
        case .invalidSpecification(let name):
            return "metric specification must define a target, minimum, or maximum: \(name)"
        case .invalidSpecificationBounds(let name):
            return "metric specification bounds must be finite and ordered: \(name)"
        case .invalidParameterBounds(let name):
            return "parameter lowerBound and upperBound must be finite and ordered: \(name)"
        case .invalidParameterStep(let name):
            return "parameter step must be finite and greater than zero: \(name)"
        }
    }
}

public struct CoreSpiceMetricImprovementObjectiveBuilder: Sendable {
    public init() {}

    public func makePlanningProblem(
        request: CoreSpiceMetricImprovementObjectiveRequest
    ) throws -> CoreSpiceMetricImprovementPlanningProblem {
        try validate(request: request)
        let measurements = Dictionary(
            uniqueKeysWithValues: request.measurementReport.metrics.map { ($0.name, $0) }
        )
        var diagnostics: [CoreSpiceMetricImprovementDiagnostic] = []
        var objectives: [CoreSpiceMetricImprovementObjective] = []

        for specification in request.specificationSet.specifications {
            guard let measurement = measurements[specification.name] else {
                diagnostics.append(
                    CoreSpiceMetricImprovementDiagnostic(
                        severity: "error",
                        code: "missing-metric-measurement",
                        message: "Metric \(specification.name) is specified but not present in the measurement report.",
                        metricName: specification.name
                    )
                )
                continue
            }
            let interval = try acceptanceInterval(for: specification)
            guard !interval.contains(measurement.value) else {
                continue
            }
            let targetValue = nearestTarget(for: measurement.value, interval: interval, target: specification.target)
            objectives.append(
                CoreSpiceMetricImprovementObjective(
                    objectiveID: objectiveID(for: specification.name),
                    metricName: specification.name,
                    currentValue: measurement.value,
                    target: specification.target,
                    requiredMinimum: interval.minimum,
                    requiredMaximum: interval.maximum,
                    tolerance: specification.tolerance,
                    direction: direction(current: measurement.value, target: targetValue),
                    magnitude: abs(targetValue - measurement.value),
                    weight: specification.weight ?? 1,
                    unit: measurement.unit
                )
            )
        }

        let status = objectives.isEmpty && diagnostics.isEmpty ? "satisfied" : "requires-improvement"
        return CoreSpiceMetricImprovementPlanningProblem(
            problemID: request.problemID,
            createdAt: request.createdAt,
            status: status,
            objectives: objectives,
            parameterSpace: request.parameterSpace,
            diagnostics: diagnostics,
            sourceRefs: request.sourceRefs,
            suggestedActions: suggestedActions(hasObjectives: !objectives.isEmpty),
            verificationGates: [
                "schema-validation",
                "simulation-metric-gate",
                "artifact-integrity",
            ]
        )
    }

    private func validate(request: CoreSpiceMetricImprovementObjectiveRequest) throws {
        guard !request.measurementReport.metrics.isEmpty else {
            throw CoreSpiceMetricImprovementObjectiveError.emptyMetricReport
        }
        guard !request.specificationSet.specifications.isEmpty else {
            throw CoreSpiceMetricImprovementObjectiveError.emptySpecifications
        }
        guard !request.parameterSpace.parameters.isEmpty else {
            throw CoreSpiceMetricImprovementObjectiveError.emptyParameterSpace
        }
        try rejectDuplicates(request.measurementReport.metrics.map(\.name)) {
            CoreSpiceMetricImprovementObjectiveError.duplicateMetric($0)
        }
        try rejectDuplicates(request.specificationSet.specifications.map(\.name)) {
            CoreSpiceMetricImprovementObjectiveError.duplicateSpecification($0)
        }
        try rejectDuplicates(request.parameterSpace.parameters.map(\.name)) {
            CoreSpiceMetricImprovementObjectiveError.duplicateParameter($0)
        }
        for measurement in request.measurementReport.metrics {
            guard measurement.value.isFinite else {
                throw CoreSpiceMetricImprovementObjectiveError.invalidMetricValue(measurement.name)
            }
        }
        for specification in request.specificationSet.specifications {
            guard specification.target != nil || specification.minimum != nil || specification.maximum != nil else {
                throw CoreSpiceMetricImprovementObjectiveError.invalidSpecification(specification.name)
            }
            try validateSpecificationBounds(specification)
        }
        for parameter in request.parameterSpace.parameters {
            guard parameter.lowerBound.isFinite,
                  parameter.upperBound.isFinite,
                  parameter.lowerBound <= parameter.upperBound else {
                throw CoreSpiceMetricImprovementObjectiveError.invalidParameterBounds(parameter.name)
            }
            if let nominalValue = parameter.nominalValue,
               !nominalValue.isFinite || nominalValue < parameter.lowerBound || nominalValue > parameter.upperBound {
                throw CoreSpiceMetricImprovementObjectiveError.invalidParameterBounds(parameter.name)
            }
            if let step = parameter.step,
               !step.isFinite || step <= 0 {
                throw CoreSpiceMetricImprovementObjectiveError.invalidParameterStep(parameter.name)
            }
        }
    }

    private func validateSpecificationBounds(_ specification: CoreSpiceMetricSpecification) throws {
        let numericValues = [
            specification.target,
            specification.minimum,
            specification.maximum,
            specification.tolerance,
            specification.weight,
        ]
        for value in numericValues {
            if let value, !value.isFinite {
                throw CoreSpiceMetricImprovementObjectiveError.invalidSpecificationBounds(specification.name)
            }
        }

        if let tolerance = specification.tolerance {
            guard tolerance >= 0 else {
                throw CoreSpiceMetricImprovementObjectiveError.invalidSpecificationBounds(specification.name)
            }
            if let target = specification.target {
                guard (target - tolerance).isFinite,
                      (target + tolerance).isFinite else {
                    throw CoreSpiceMetricImprovementObjectiveError.invalidSpecificationBounds(specification.name)
                }
            }
        }

        if let minimum = specification.minimum,
           let maximum = specification.maximum,
           minimum > maximum {
            throw CoreSpiceMetricImprovementObjectiveError.invalidSpecificationBounds(specification.name)
        }
    }

    private func rejectDuplicates(
        _ names: [String],
        error: (String) -> CoreSpiceMetricImprovementObjectiveError
    ) throws {
        var seen: Set<String> = []
        for name in names {
            if seen.contains(name) {
                throw error(name)
            }
            seen.insert(name)
        }
    }

    private func acceptanceInterval(
        for specification: CoreSpiceMetricSpecification
    ) throws -> CoreSpiceMetricAcceptanceInterval {
        if let minimum = specification.minimum, let maximum = specification.maximum {
            return CoreSpiceMetricAcceptanceInterval(minimum: minimum, maximum: maximum)
        }
        if let target = specification.target, let tolerance = specification.tolerance {
            return CoreSpiceMetricAcceptanceInterval(minimum: target - tolerance, maximum: target + tolerance)
        }
        if let minimum = specification.minimum {
            return CoreSpiceMetricAcceptanceInterval(minimum: minimum, maximum: nil)
        }
        if let maximum = specification.maximum {
            return CoreSpiceMetricAcceptanceInterval(minimum: nil, maximum: maximum)
        }
        if let target = specification.target {
            return CoreSpiceMetricAcceptanceInterval(minimum: target, maximum: target)
        }
        throw CoreSpiceMetricImprovementObjectiveError.invalidSpecification(specification.name)
    }

    private func nearestTarget(
        for currentValue: Double,
        interval: CoreSpiceMetricAcceptanceInterval,
        target: Double?
    ) -> Double {
        if let minimum = interval.minimum, currentValue < minimum {
            return minimum
        }
        if let maximum = interval.maximum, currentValue > maximum {
            return maximum
        }
        if let target {
            return target
        }
        return currentValue
    }

    private func direction(current: Double, target: Double) -> String {
        if target > current {
            return "increase"
        }
        if target < current {
            return "decrease"
        }
        return "hold"
    }

    private func objectiveID(for metricName: String) -> String {
        let normalized = metricName
            .lowercased()
            .map { character -> Character in
                if character.isLetter || character.isNumber {
                    return character
                }
                return "-"
            }
        let collapsed = String(normalized)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        return collapsed.isEmpty ? "metric-objective" : "metric-\(collapsed)-objective"
    }

    private func suggestedActions(hasObjectives: Bool) -> [String] {
        if hasObjectives {
            return [
                "generate-parameter-candidates",
                "set-netlist-parameters",
                "run-simulation-metric-gate",
            ]
        }
        return ["retain-current-parameters"]
    }
}

private struct CoreSpiceMetricAcceptanceInterval: Sendable, Hashable {
    var minimum: Double?
    var maximum: Double?

    func contains(_ value: Double) -> Bool {
        if let minimum, value < minimum {
            return false
        }
        if let maximum, value > maximum {
            return false
        }
        return true
    }
}
