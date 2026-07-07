import Foundation

public struct CoreSpiceConvergenceDiagnosticReport: Codable, Sendable, Hashable {
    public var runID: String?
    public var analysisType: String
    public var diagnostics: [CoreSpiceConvergenceDiagnostic]

    public init(runID: String? = nil, analysisType: String, diagnostics: [CoreSpiceConvergenceDiagnostic]) {
        self.runID = runID
        self.analysisType = analysisType
        self.diagnostics = diagnostics
    }
}

public struct CoreSpiceConvergenceDiagnostic: Codable, Sendable, Hashable {
    public var severity: String
    public var code: String
    public var message: String
    public var component: String?
    public var iteration: Int?
    public var residualNorm: Double?
    public var time: Double?
    public var suggestedActions: [String]

    public init(
        severity: String,
        code: String,
        message: String,
        component: String? = nil,
        iteration: Int? = nil,
        residualNorm: Double? = nil,
        time: Double? = nil,
        suggestedActions: [String] = []
    ) {
        self.severity = severity
        self.code = code
        self.message = message
        self.component = component
        self.iteration = iteration
        self.residualNorm = residualNorm
        self.time = time
        self.suggestedActions = suggestedActions
    }

    private enum CodingKeys: String, CodingKey {
        case severity
        case code
        case message
        case component
        case iteration
        case residualNorm
        case time
        case suggestedActions
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        severity = try container.decode(String.self, forKey: .severity)
        code = try container.decode(String.self, forKey: .code)
        message = try container.decode(String.self, forKey: .message)
        component = try container.decodeIfPresent(String.self, forKey: .component)
        iteration = try container.decodeIfPresent(Int.self, forKey: .iteration)
        residualNorm = try container.decodeIfPresent(Double.self, forKey: .residualNorm)
        time = try container.decodeIfPresent(Double.self, forKey: .time)
        suggestedActions = try container.decodeIfPresent([String].self, forKey: .suggestedActions) ?? []
    }
}

public struct CoreSpiceConvergenceAnalysisOptions: Codable, Sendable, Hashable {
    public var analysisType: String
    public var reltol: Double?
    public var abstol: Double?
    public var vntol: Double?
    public var maxIterations: Int?
    public var gmin: Double?
    public var timestep: Double?
    public var stopTime: Double?
    public var integrationMethod: String?

    public init(
        analysisType: String,
        reltol: Double? = nil,
        abstol: Double? = nil,
        vntol: Double? = nil,
        maxIterations: Int? = nil,
        gmin: Double? = nil,
        timestep: Double? = nil,
        stopTime: Double? = nil,
        integrationMethod: String? = nil
    ) {
        self.analysisType = analysisType
        self.reltol = reltol
        self.abstol = abstol
        self.vntol = vntol
        self.maxIterations = maxIterations
        self.gmin = gmin
        self.timestep = timestep
        self.stopTime = stopTime
        self.integrationMethod = integrationMethod
    }
}

public struct CoreSpiceConvergenceRetryPolicy: Codable, Sendable, Hashable {
    public var maxIterationsLimit: Int
    public var gminLimit: Double
    public var timestepScale: Double

    public init(
        maxIterationsLimit: Int = 200,
        gminLimit: Double = 1.0e-9,
        timestepScale: Double = 0.5
    ) {
        self.maxIterationsLimit = maxIterationsLimit
        self.gminLimit = gminLimit
        self.timestepScale = timestepScale
    }
}

public struct CoreSpiceConvergenceRecoveryObjectiveRequest: Codable, Sendable, Hashable {
    public var problemID: String
    public var createdAt: String
    public var diagnosticReport: CoreSpiceConvergenceDiagnosticReport
    public var netlistRef: CoreSpiceConvergenceSourceRef
    public var analysisOptions: CoreSpiceConvergenceAnalysisOptions
    public var retryPolicy: CoreSpiceConvergenceRetryPolicy
    public var sourceRefs: [CoreSpiceConvergenceSourceRef]

    public init(
        problemID: String,
        createdAt: String,
        diagnosticReport: CoreSpiceConvergenceDiagnosticReport,
        netlistRef: CoreSpiceConvergenceSourceRef,
        analysisOptions: CoreSpiceConvergenceAnalysisOptions,
        retryPolicy: CoreSpiceConvergenceRetryPolicy = CoreSpiceConvergenceRetryPolicy(),
        sourceRefs: [CoreSpiceConvergenceSourceRef] = []
    ) {
        self.problemID = problemID
        self.createdAt = createdAt
        self.diagnosticReport = diagnosticReport
        self.netlistRef = netlistRef
        self.analysisOptions = analysisOptions
        self.retryPolicy = retryPolicy
        self.sourceRefs = sourceRefs
    }
}

public struct CoreSpiceConvergenceRecoveryPlanningProblem: Codable, Sendable, Hashable {
    public var schemaVersion: Int
    public var problemID: String
    public var createdAt: String
    public var status: String
    public var analysisType: String
    public var objectives: [CoreSpiceConvergenceRecoveryObjective]
    public var retryOptions: [CoreSpiceConvergenceRetryOption]
    public var diagnostics: [CoreSpiceConvergenceDiagnostic]
    public var sourceRefs: [CoreSpiceConvergenceSourceRef]
    public var verificationGates: [String]
    public var suggestedActions: [String]

    public init(
        schemaVersion: Int = 1,
        problemID: String,
        createdAt: String,
        status: String,
        analysisType: String,
        objectives: [CoreSpiceConvergenceRecoveryObjective],
        retryOptions: [CoreSpiceConvergenceRetryOption],
        diagnostics: [CoreSpiceConvergenceDiagnostic],
        sourceRefs: [CoreSpiceConvergenceSourceRef],
        verificationGates: [String],
        suggestedActions: [String]
    ) {
        self.schemaVersion = schemaVersion
        self.problemID = problemID
        self.createdAt = createdAt
        self.status = status
        self.analysisType = analysisType
        self.objectives = objectives
        self.retryOptions = retryOptions
        self.diagnostics = diagnostics
        self.sourceRefs = sourceRefs
        self.verificationGates = verificationGates
        self.suggestedActions = suggestedActions
    }
}

public struct CoreSpiceConvergenceRecoveryObjective: Codable, Sendable, Hashable {
    public var objectiveID: String
    public var target: String
    public var severity: String
    public var diagnosticCode: String
    public var component: String?
    public var residualNorm: Double?
    public var time: Double?

    public init(
        objectiveID: String,
        target: String,
        severity: String,
        diagnosticCode: String,
        component: String?,
        residualNorm: Double?,
        time: Double?
    ) {
        self.objectiveID = objectiveID
        self.target = target
        self.severity = severity
        self.diagnosticCode = diagnosticCode
        self.component = component
        self.residualNorm = residualNorm
        self.time = time
    }
}

public struct CoreSpiceConvergenceRetryOption: Codable, Sendable, Hashable {
    public var optionID: String
    public var action: String
    public var rationale: String
    public var parameterName: String
    public var currentValue: Double?
    public var proposedValue: Double?
    public var boundedByPolicy: Bool

    public init(
        optionID: String,
        action: String,
        rationale: String,
        parameterName: String,
        currentValue: Double?,
        proposedValue: Double?,
        boundedByPolicy: Bool
    ) {
        self.optionID = optionID
        self.action = action
        self.rationale = rationale
        self.parameterName = parameterName
        self.currentValue = currentValue
        self.proposedValue = proposedValue
        self.boundedByPolicy = boundedByPolicy
    }
}

public struct CoreSpiceConvergenceSourceRef: Codable, Sendable, Hashable {
    public var refID: String
    public var path: String
    public var kind: String

    public init(refID: String, path: String, kind: String) {
        self.refID = refID
        self.path = path
        self.kind = kind
    }
}

public enum CoreSpiceConvergenceRecoveryObjectiveError: Error, Equatable, LocalizedError {
    case emptyProblemID
    case emptyCreatedAt
    case emptyDiagnostics
    case emptyAnalysisType(source: String)
    case analysisTypeMismatch(report: String, options: String)
    case emptyDiagnosticField(index: Int, field: String)
    case emptyNetlistRef
    case invalidSourceRef(index: Int, field: String)
    case invalidRetryPolicy(String)

    public var errorDescription: String? {
        switch self {
        case .emptyProblemID:
            return "convergence recovery objective requires a problem identifier"
        case .emptyCreatedAt:
            return "convergence recovery objective requires a creation timestamp"
        case .emptyDiagnostics:
            return "convergence recovery objective requires at least one diagnostic"
        case .emptyAnalysisType(let source):
            return "convergence recovery objective requires a non-empty analysis type in \(source)"
        case .analysisTypeMismatch(let report, let options):
            return "convergence recovery objective analysis type mismatch: report=\(report), options=\(options)"
        case .emptyDiagnosticField(let index, let field):
            return "convergence diagnostic \(index) requires a non-empty \(field)"
        case .emptyNetlistRef:
            return "convergence recovery objective requires a netlist reference"
        case .invalidSourceRef(let index, let field):
            return "convergence source reference \(index) requires a non-empty \(field)"
        case .invalidRetryPolicy(let message):
            return "invalid convergence retry policy: \(message)"
        }
    }
}

public struct CoreSpiceConvergenceRecoveryObjectiveBuilder: Sendable {
    public init() {}

    public func makePlanningProblem(
        request: CoreSpiceConvergenceRecoveryObjectiveRequest
    ) throws -> CoreSpiceConvergenceRecoveryPlanningProblem {
        try validate(request: request)
        let diagnostics = normalizedDiagnostics(request.diagnosticReport.diagnostics)
        let sourceRefs = normalizedSourceRefs(
            netlistRef: request.netlistRef,
            sourceRefs: request.sourceRefs
        )
        let objectives = diagnostics.enumerated().map { index, diagnostic in
            CoreSpiceConvergenceRecoveryObjective(
                objectiveID: "convergence-recovery-\(index + 1)",
                target: "restore-simulation-convergence",
                severity: diagnostic.severity,
                diagnosticCode: diagnostic.code,
                component: diagnostic.component,
                residualNorm: diagnostic.residualNorm,
                time: diagnostic.time
            )
        }
        let retryOptions = makeRetryOptions(
            diagnostics: diagnostics,
            options: request.analysisOptions,
            policy: request.retryPolicy
        )
        return CoreSpiceConvergenceRecoveryPlanningProblem(
            problemID: request.problemID,
            createdAt: request.createdAt,
            status: retryOptions.isEmpty ? "diagnostic-only" : "requires-retry",
            analysisType: request.diagnosticReport.analysisType,
            objectives: objectives,
            retryOptions: retryOptions,
            diagnostics: diagnostics,
            sourceRefs: sourceRefs,
            verificationGates: [
                "schema-validation",
                "simulation-completed",
                "artifact-integrity",
            ],
            suggestedActions: retryOptions.isEmpty ? ["inspect-convergence-diagnostics"] : [
                "select-retry-option",
                "rerun-simulation",
                "compare-convergence-result",
            ]
        )
    }

    private func validate(request: CoreSpiceConvergenceRecoveryObjectiveRequest) throws {
        guard !trimmed(request.problemID).isEmpty else {
            throw CoreSpiceConvergenceRecoveryObjectiveError.emptyProblemID
        }
        guard !trimmed(request.createdAt).isEmpty else {
            throw CoreSpiceConvergenceRecoveryObjectiveError.emptyCreatedAt
        }
        let reportAnalysisType = trimmed(request.diagnosticReport.analysisType)
        guard !reportAnalysisType.isEmpty else {
            throw CoreSpiceConvergenceRecoveryObjectiveError.emptyAnalysisType(source: "diagnosticReport")
        }
        let optionsAnalysisType = trimmed(request.analysisOptions.analysisType)
        guard !optionsAnalysisType.isEmpty else {
            throw CoreSpiceConvergenceRecoveryObjectiveError.emptyAnalysisType(source: "analysisOptions")
        }
        guard reportAnalysisType.lowercased() == optionsAnalysisType.lowercased() else {
            throw CoreSpiceConvergenceRecoveryObjectiveError.analysisTypeMismatch(
                report: reportAnalysisType,
                options: optionsAnalysisType
            )
        }
        guard !request.diagnosticReport.diagnostics.isEmpty else {
            throw CoreSpiceConvergenceRecoveryObjectiveError.emptyDiagnostics
        }
        for (index, diagnostic) in request.diagnosticReport.diagnostics.enumerated() {
            try validate(diagnostic: diagnostic, index: index + 1)
        }
        try validate(sourceRef: request.netlistRef, index: 1, emptyPathError: .emptyNetlistRef)
        for (index, sourceRef) in request.sourceRefs.enumerated() {
            try validate(sourceRef: sourceRef, index: index + 1, emptyPathError: nil)
        }
        guard request.retryPolicy.maxIterationsLimit > 0 else {
            throw CoreSpiceConvergenceRecoveryObjectiveError.invalidRetryPolicy("maxIterationsLimit must be positive")
        }
        guard request.retryPolicy.gminLimit > 0 else {
            throw CoreSpiceConvergenceRecoveryObjectiveError.invalidRetryPolicy("gminLimit must be positive")
        }
        guard request.retryPolicy.timestepScale > 0 && request.retryPolicy.timestepScale < 1 else {
            throw CoreSpiceConvergenceRecoveryObjectiveError.invalidRetryPolicy("timestepScale must be between 0 and 1")
        }
    }

    private func validate(diagnostic: CoreSpiceConvergenceDiagnostic, index: Int) throws {
        guard !trimmed(diagnostic.severity).isEmpty else {
            throw CoreSpiceConvergenceRecoveryObjectiveError.emptyDiagnosticField(
                index: index,
                field: "severity"
            )
        }
        guard !trimmed(diagnostic.code).isEmpty else {
            throw CoreSpiceConvergenceRecoveryObjectiveError.emptyDiagnosticField(
                index: index,
                field: "code"
            )
        }
        guard !trimmed(diagnostic.message).isEmpty else {
            throw CoreSpiceConvergenceRecoveryObjectiveError.emptyDiagnosticField(
                index: index,
                field: "message"
            )
        }
    }

    private func validate(
        sourceRef: CoreSpiceConvergenceSourceRef,
        index: Int,
        emptyPathError: CoreSpiceConvergenceRecoveryObjectiveError?
    ) throws {
        guard !trimmed(sourceRef.refID).isEmpty else {
            throw CoreSpiceConvergenceRecoveryObjectiveError.invalidSourceRef(index: index, field: "refID")
        }
        guard !trimmed(sourceRef.kind).isEmpty else {
            throw CoreSpiceConvergenceRecoveryObjectiveError.invalidSourceRef(index: index, field: "kind")
        }
        guard !trimmed(sourceRef.path).isEmpty else {
            if let emptyPathError {
                throw emptyPathError
            }
            throw CoreSpiceConvergenceRecoveryObjectiveError.invalidSourceRef(index: index, field: "path")
        }
    }

    private func normalizedDiagnostics(
        _ diagnostics: [CoreSpiceConvergenceDiagnostic]
    ) -> [CoreSpiceConvergenceDiagnostic] {
        diagnostics.map { diagnostic in
            let providedActions = nonEmptyStrings(diagnostic.suggestedActions)
            return CoreSpiceConvergenceDiagnostic(
                severity: trimmed(diagnostic.severity),
                code: trimmed(diagnostic.code),
                message: trimmed(diagnostic.message),
                component: trimmedOptional(diagnostic.component),
                iteration: diagnostic.iteration,
                residualNorm: diagnostic.residualNorm,
                time: diagnostic.time,
                suggestedActions: providedActions.isEmpty
                    ? suggestedActions(for: diagnostic)
                    : providedActions
            )
        }
    }

    private func normalizedSourceRefs(
        netlistRef: CoreSpiceConvergenceSourceRef,
        sourceRefs: [CoreSpiceConvergenceSourceRef]
    ) -> [CoreSpiceConvergenceSourceRef] {
        var result = sourceRefs.isEmpty ? [netlistRef] : sourceRefs
        if !result.contains(where: { sameSourceRef($0, netlistRef) }) {
            result.append(netlistRef)
        }
        return stableUnique(result.map(normalizedSourceRef))
    }

    private func normalizedSourceRef(_ sourceRef: CoreSpiceConvergenceSourceRef) -> CoreSpiceConvergenceSourceRef {
        CoreSpiceConvergenceSourceRef(
            refID: trimmed(sourceRef.refID),
            path: trimmed(sourceRef.path),
            kind: trimmed(sourceRef.kind)
        )
    }

    private func sameSourceRef(
        _ lhs: CoreSpiceConvergenceSourceRef,
        _ rhs: CoreSpiceConvergenceSourceRef
    ) -> Bool {
        trimmed(lhs.refID) == trimmed(rhs.refID)
            && trimmed(lhs.path) == trimmed(rhs.path)
            && trimmed(lhs.kind) == trimmed(rhs.kind)
    }

    private func stableUnique(_ sourceRefs: [CoreSpiceConvergenceSourceRef]) -> [CoreSpiceConvergenceSourceRef] {
        var seen: Set<String> = []
        var result: [CoreSpiceConvergenceSourceRef] = []
        for sourceRef in sourceRefs {
            let key = "\(sourceRef.refID)\u{1f}\(sourceRef.path)\u{1f}\(sourceRef.kind)"
            if seen.insert(key).inserted {
                result.append(sourceRef)
            }
        }
        return result
    }

    private func suggestedActions(for diagnostic: CoreSpiceConvergenceDiagnostic) -> [String] {
        let code = trimmed(diagnostic.code).lowercased()
        let message = trimmed(diagnostic.message).lowercased()
        if code.contains("timestep") || message.contains("timestep") {
            return [
                "reduce-timestep",
                "rerun-transient-analysis",
                "compare-convergence-result",
            ]
        }
        if code.contains("matrix") || message.contains("matrix") || message.contains("singular") {
            return [
                "raise-gmin",
                "check-floating-nodes",
                "rerun-operating-point",
            ]
        }
        if code.contains("iteration") || message.contains("iteration") || message.contains("newton") {
            return [
                "increase-max-iterations",
                "inspect-nonlinear-device-bias",
                "rerun-simulation",
            ]
        }
        return [
            "inspect-convergence-diagnostics",
            "adjust-bounded-solver-options",
            "rerun-simulation",
        ]
    }

    private func nonEmptyStrings(_ values: [String]) -> [String] {
        values.map(trimmed).filter { !$0.isEmpty }
    }

    private func trimmedOptional(_ value: String?) -> String? {
        guard let value else {
            return nil
        }
        let trimmedValue = trimmed(value)
        return trimmedValue.isEmpty ? nil : trimmedValue
    }

    private func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func makeRetryOptions(
        diagnostics: [CoreSpiceConvergenceDiagnostic],
        options: CoreSpiceConvergenceAnalysisOptions,
        policy: CoreSpiceConvergenceRetryPolicy
    ) -> [CoreSpiceConvergenceRetryOption] {
        var retryOptions: [CoreSpiceConvergenceRetryOption] = []
        if let maxIterations = options.maxIterations, maxIterations < policy.maxIterationsLimit {
            let proposed = min(maxIterations * 2, policy.maxIterationsLimit)
            retryOptions.append(
                CoreSpiceConvergenceRetryOption(
                    optionID: "increase-max-iterations",
                    action: "increase-max-iterations",
                    rationale: "Allow the nonlinear solver more bounded Newton iterations before declaring failure.",
                    parameterName: "maxIterations",
                    currentValue: Double(maxIterations),
                    proposedValue: Double(proposed),
                    boundedByPolicy: proposed == policy.maxIterationsLimit
                )
            )
        }
        if let gmin = options.gmin, gmin < policy.gminLimit {
            let proposed = min(max(gmin * 10, 1.0e-12), policy.gminLimit)
            retryOptions.append(
                CoreSpiceConvergenceRetryOption(
                    optionID: "raise-gmin",
                    action: "raise-gmin",
                    rationale: "Improve matrix conditioning with a bounded minimum conductance increase.",
                    parameterName: "gmin",
                    currentValue: gmin,
                    proposedValue: proposed,
                    boundedByPolicy: proposed == policy.gminLimit
                )
            )
        }
        if diagnostics.contains(where: isTimestepDiagnostic), let timestep = options.timestep {
            retryOptions.append(
                CoreSpiceConvergenceRetryOption(
                    optionID: "reduce-timestep",
                    action: "reduce-timestep",
                    rationale: "Retry the transient analysis with a smaller bounded timestep near the failing region.",
                    parameterName: "timestep",
                    currentValue: timestep,
                    proposedValue: timestep * policy.timestepScale,
                    boundedByPolicy: true
                )
            )
        }
        if options.analysisType.lowercased() == "tran"
            && options.integrationMethod?.lowercased() != "backward-euler" {
            retryOptions.append(
                CoreSpiceConvergenceRetryOption(
                    optionID: "switch-to-backward-euler",
                    action: "switch-integration-method",
                    rationale: "Use a more damping-friendly transient integration method for the retry.",
                    parameterName: "integrationMethod",
                    currentValue: nil,
                    proposedValue: nil,
                    boundedByPolicy: true
                )
            )
        }
        return stableUnique(retryOptions)
    }

    private func isTimestepDiagnostic(_ diagnostic: CoreSpiceConvergenceDiagnostic) -> Bool {
        let code = diagnostic.code.lowercased()
        let message = diagnostic.message.lowercased()
        return code.contains("timestep") || message.contains("timestep")
    }

    private func stableUnique(_ retryOptions: [CoreSpiceConvergenceRetryOption]) -> [CoreSpiceConvergenceRetryOption] {
        var seen: Set<String> = []
        var result: [CoreSpiceConvergenceRetryOption] = []
        for option in retryOptions where !seen.contains(option.optionID) {
            seen.insert(option.optionID)
            result.append(option)
        }
        return result
    }
}
