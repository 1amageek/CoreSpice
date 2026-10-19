import CoreSpiceDiodeContracts
import CoreSpiceMOSContracts
import CoreSpiceMOSResolution
import CoreSpiceParsedIR

/// Non-overridable scalar adapter. All mutable evaluation belongs to the caller's frozen session.
struct DiodeResolver {
    let compiled: CompiledNetlist
    let job: FrontendComponentJob
    let storage: FrontendStorage
    let limits: MOSResolutionLimits
    var candidates: Range<Int>?
    var assignmentIndex: Int?
    var modelAssignment = true

    mutating func resolve<Schemas: DiodeModelSchemaProviding>(schemas: borrowing Schemas, profile: DiodeInputProfile?, scale: Double, seed: UInt64,
                         session: inout MOSEvaluationSession,
                         memo: inout [DiodeModelMemoKey: DiodeModelMemoEntry],
                         sourceScalars: inout [NetlistSourceScalarOverride]) throws -> ResolvedDiodeInstance {
        do {
            try session.checkHealthy()
            guard let profile else { throw DiodeResolutionFailure.Cause.profileRequired }
            guard let environment = session.environment else { throw MOSResolutionFailure.environmentUnavailable }
            guard job.nodes.count == 2 else { throw DiodeResolutionFailure.Cause.invalidPorts }
            guard job.inheritedMultiplier == nil else { throw DiodeResolutionFailure.Cause.implicitMultiplicity }
            guard let symbol = job.template.diodeReference else { throw DiodeResolutionFailure.Cause.undefinedModel }
            var scope: MOSScopeID? = job.template.scope
            while let current = scope {
                try storage.spend()
                if let range = compiled.diodeIndex[.init(scope: current, symbol: symbol)] { candidates = range; break }
                scope = compiled.scopes[Int(current.rawValue)].parent
            }
            guard let candidates else { throw DiodeResolutionFailure.Cause.undefinedModel }
            guard candidates.count <= limits.maximumCandidates else { throw MOSResolutionFailure.limitExceeded(.candidates) }
            guard candidates.count == 1 else { throw DiodeResolutionFailure.Cause.duplicateModel }
            let index = compiled.diodeCandidates[candidates.lowerBound]
            let declaration = compiled.models[index]
            guard declaration.model.type == .diode else { throw DiodeResolutionFailure.Cause.wrongModelType }
            let owner = try compiledOwner(of: declaration.scope)
            let key = DiodeModelMemoKey(declaration: index, invocation: owner)
            let inputLimits = try DiodeInputLimits(maximumAssignments: limits.maximumPrograms,
                                                  maximumParameterNameBytes: Int(min(limits.maximumRetainedBytes, UInt64(Int.max))))
            let overrides = compiled.scalarOverrides[fullName.lowercased()] ?? []
            for override in overrides {
                let assignments = override.source.role == .model ? declaration.diodeAssignments : job.template.diodeAssignments
                guard override.name != "level", override.name != "version",
                      assignments.contains(where: { $0.source.name.lowercased() == override.name && $0.program != nil }) else {
                    throw LoweringError.invalidComponent(name: fullName, reason: "Diode override is not an explicit scalar source assignment")
                }
            }
            let hasModelOverride = overrides.contains(where: { $0.source.role == .model })
            let model: ResolvedDiodeModel
            var modelAssignments: [DiodeScalarAssignment] = []
            if !hasModelOverride, let cached = memo[key] {
                model = cached.model; modelAssignments = cached.assignments
            }
            else {
                guard memo.count < limits.maximumCacheEntries else { throw MOSResolutionFailure.limitExceeded(.cacheEntries) }
                try validateProjection(declaration.diodeAssignments, projection: declaration.model.parameters,
                                       level: declaration.model.level)
                // Selectors are admitted before coefficient expressions, including duplicate and shape errors.
                var level: Double? = declaration.model.level.map(Double.init)
                var sawLevel = false
                for (offset, assignment) in declaration.diodeAssignments.enumerated() {
                    try storage.spend(); assignmentIndex = offset
                    let name = assignment.source.name.lowercased()
                    if name == "version" { throw DiodeSchemaFailure.unsupportedVersionSelector }
                    guard name == "level" else { continue }
                    guard !sawLevel else { throw DiodeResolutionFailure.Cause.duplicateSelector }
                    sawLevel = true
                    let evaluated = try evaluate(assignment, invocation: owner, scope: declaration.scope, session: &session)
                    if let expected = declaration.model.level, evaluated != Double(expected) {
                        throw DiodeResolutionFailure.Cause.inconsistentProjection
                    }
                    level = evaluated
                }
                let law = try profile.modelLaw(level: level, version: nil)
                let schema = try schemas.schema(for: law)
                try admit(declaration.diodeAssignments, schema: schema, role: .model, inputLimits: inputLimits)
                // Reserve the immutable heap owner and memo capacity before allocating either.
                try storage.budget.add(ResolvedDiodeModel.ownedByteCount)
                try storage.reserve(&memo, memo.count + 1)
                let baseline = storage.budget.bytes
                defer { storage.budget.release(storage.budget.bytes - baseline) }
                var values: [DiodeScalarAssignment] = []
                for (offset, assignment) in declaration.diodeAssignments.enumerated() {
                    assignmentIndex = offset
                    if assignment.source.name.lowercased() == "level" { continue }
                    let value = try evaluate(assignment, invocation: owner, scope: declaration.scope, session: &session)
                    try storage.reserve(&values, values.count + 1)
                    values.append(.init(name: assignment.source.name, value: value))
                }
                let input = try DiodeModelInput(schema: schema, assignments: values.span,
                                               environment: environment, limits: inputLimits)
                if compiled.captureSourceScalars { modelAssignments = values }
                let source = frontendModelSource(declaration.model)
                model = ResolvedDiodeModel(declaration: .init(declaration: UInt64(index),
                    scope: declaration.scope.rawValue, invocation: owner, sourcePath: source.path,
                    captureID: source.captureID, occurrence: source.occurrenceID, line: source.line,
                    statementOrdinal: source.statementOrdinal), input: input,
                    orderedAssignmentEvidence: !declaration.model.parameterAssignments.isEmpty || declaration.model.parameters.isEmpty)
            }
            // Cache insertion is outside the scratch release scope; immutable backing is charged once.
            if !hasModelOverride, memo[key] == nil {
                try storage.retain(modelAssignments)
                memo[key] = .init(model: model, assignments: modelAssignments)
            }
            if hasModelOverride { try storage.retain(modelAssignments) }
            defer {
                if hasModelOverride {
                    storage.budget.release(UInt64(modelAssignments.capacity) * UInt64(MemoryLayout<DiodeScalarAssignment>.stride))
                }
            }
            let modelSchema = try schemas.schema(for: model.input.schemaIdentity.law)
            for assignment in modelAssignments where compiled.captureSourceScalars {
                try storage.spend()
                let definition = try modelSchema.parameter(named: assignment.name, role: .model, limits: inputLimits)
                guard case .model(let id) = definition.id, model.input.disposition(for: id) == .active else { continue }
                try recordScalar(assignment, role: .model, into: &sourceScalars)
            }
            modelAssignment = false; assignmentIndex = nil
            let assignments = job.template.diodeAssignments
            try validateProjection(assignments, projection: job.template.component.parameters, level: nil)
            let schema = try schemas.schema(for: model.input.schemaIdentity.law)
            try admit(assignments, schema: schema, role: .instance, inputLimits: inputLimits)
            var values: [DiodeScalarAssignment] = []
            defer { storage.budget.release(UInt64(values.capacity) * UInt64(MemoryLayout<DiodeScalarAssignment>.stride)) }
            for (offset, assignment) in assignments.enumerated() {
                assignmentIndex = offset
                let value = try evaluate(assignment, invocation: job.invocation, scope: job.template.scope, session: &session)
                try storage.reserve(&values, values.count + 1)
                values.append(.init(name: assignment.source.name, value: value))
                try recordScalar(.init(name: assignment.source.name, value: value), role: .instance, into: &sourceScalars)
            }
            let input = try DiodeInstanceInput(schema: schema, assignments: values.span,
                environment: environment, scale: DiodeGeometryScale(scale), limits: inputLimits)
            return try .init(instance: fullName, scope: job.template.scope.rawValue, invocation: job.invocation,
                             model: model, input: input, profile: profile, seed: seed,
                             evaluatorVersion: MOSEvaluationSession.evaluatorVersion,
                             randomGeneratorVersion: MOSEvaluationSession.randomGeneratorVersion,
                             orderedAssignmentEvidence: !assignments.isEmpty || job.template.component.parameters.isEmpty)
        } catch {
            let cause: DiodeResolutionFailure.Cause
            if let failure = error as? DiodeResolutionFailure.Cause { cause = failure }
            else if let failure = error as? DiodeSchemaFailure { cause = .schema(failure) }
            else if let failure = error as? MOSResolutionFailure { cause = .evaluation(failure) }
            else { throw error }
            // The compiled source is already retained and budgeted; diagnostics retain only fixed coordinates.
            var textBytes = fullName.utf8.count
            switch cause {
            case .schema(.unknownParameter(let name, _)), .schema(.unsupportedParameter(let name, _)),
                 .schema(.wrongRole(let name, _)): textBytes += name.utf8.count
            default: break
            }
            let fits = limits.maximumDiagnosticBytes >= UInt64(MemoryLayout<DiodeResolutionFailure>.stride + textBytes)
            let boundedCause: DiodeResolutionFailure.Cause
            switch cause {
            case .schema(.unknownParameter(_, let role)) where !fits: boundedCause = .schema(.unknownParameter(name: "", role: role))
            case .schema(.unsupportedParameter(_, let role)) where !fits: boundedCause = .schema(.unsupportedParameter(name: "", role: role))
            case .schema(.wrongRole(_, let role)) where !fits: boundedCause = .schema(.wrongRole(name: "", requested: role))
            default: boundedCause = cause
            }
            session.poison((error as? MOSResolutionFailure) ?? .invalidRequest)
            throw DiodeResolutionFailure(cause: boundedCause, compiled: compiled, instance: fits ? fullName : nil,
                scope: fits ? job.template.scope.rawValue : nil, invocation: fits ? job.invocation : nil,
                declarationRange: fits ? candidates : nil, assignmentIndex: fits ? assignmentIndex : nil,
                modelAssignment: modelAssignment, componentIndex: fits ? job.template.ordinal : nil, isTruncated: !fits)
        }
    }
    private func recordScalar(_ assignment: DiodeScalarAssignment, role: NetlistSourceScalarOverride.Role,
        into sourceScalars: inout [NetlistSourceScalarOverride]) throws {
        guard compiled.captureSourceScalars else { return }
        try storage.text(fullName); try storage.text(assignment.name)
        try storage.reserve(&sourceScalars, sourceScalars.count + 1)
        sourceScalars.append(try .init(instanceName: fullName, parameterName: assignment.name,
            role: role, value: assignment.value))
    }
    private var fullName: String {
        job.prefix.isEmpty ? job.template.component.name : job.prefix + "." + job.template.component.name
    }
    private func compiledOwner(of scope: MOSScopeID) throws -> UInt64 {
        // Invocation identity comes from the shared graph supplied by the session composition root.
        try graph.lexicalOwner(of: scope, from: job.invocation)
    }
    let graph: MOSInvocationGraph
    private mutating func validateProjection(_ assignments: [DiodeCompiledAssignment],
                                              projection: [String: ParsedParameterValue], level: Int?) throws {
        guard !assignments.isEmpty || projection.isEmpty else { throw DiodeResolutionFailure.Cause.missingOccurrenceEvidence }
        for (name, value) in projection {
            let canonical = name.lowercased()
            var last: ParsedParameterAssignment?
            for assignment in assignments {
                try storage.spend()
                if assignment.source.name.lowercased() == canonical { last = assignment.source }
            }
            guard last?.value == value else { throw DiodeResolutionFailure.Cause.inconsistentProjection }
        }
        for (offset, assignment) in assignments.enumerated() {
            assignmentIndex = offset
            let canonical = assignment.source.name.lowercased()
            if canonical == "level", modelAssignment { continue }
            var present = false
            for name in projection.keys {
                try storage.spend()
                if name.lowercased() == canonical { present = true; break }
            }
            guard present else { throw DiodeResolutionFailure.Cause.inconsistentProjection }
        }
    }

    private mutating func admit(_ assignments: [DiodeCompiledAssignment], schema: DiodeModelSchema,
                                 role: DiodeParameterRole, inputLimits: DiodeInputLimits) throws {
        guard assignments.count <= inputLimits.maximumAssignments else { throw DiodeSchemaFailure.assignmentLimit }
        var mask: UInt16 = 0
        for (offset, assignment) in assignments.enumerated() {
            try storage.spend(); assignmentIndex = offset
            if role == .model && assignment.source.name.lowercased() == "level" { continue }
            let definition = try schema.parameter(named: assignment.source.name, role: role, limits: inputLimits)
            let bit: UInt16
            switch definition.id {
            case .model(let id): bit = 1 << id.rawValue
            case .instance(let id): bit = 1 << id.rawValue
            }
            guard mask & bit == 0 else { throw DiodeSchemaFailure.duplicateParameter(definition.id) }
            mask |= bit
            guard assignment.program != nil, assignment.source.additionalValues.isEmpty else {
                throw DiodeResolutionFailure.Cause.nonScalarAssignment
            }
            if case .boolean = assignment.source.value { throw DiodeResolutionFailure.Cause.nonScalarAssignment }
        }
    }
    private func evaluate(_ assignment: DiodeCompiledAssignment, invocation: UInt64, scope: MOSScopeID,
                           session: inout MOSEvaluationSession) throws -> Double {
        guard let program = assignment.program else { throw DiodeResolutionFailure.Cause.nonScalarAssignment }
        if case .boolean = assignment.source.value { throw DiodeResolutionFailure.Cause.nonScalarAssignment }
        let role: NetlistSourceScalarOverride.Role = modelAssignment ? .model : .instance
        let overridden = compiled.scalarOverrides[fullName.lowercased()]?.first {
            $0.source.role == role && $0.name == assignment.source.name.lowercased()
        }
        return try evaluateMOSProgram(overridden?.binding.program ?? program, invocation: invocation, lexicalScope: scope,
                                      from: compiled.snapshot, session: &session)
    }
}
