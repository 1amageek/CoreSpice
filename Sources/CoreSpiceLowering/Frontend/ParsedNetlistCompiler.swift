import CoreSpiceMOSContracts
import CoreSpiceMOSResolution
import CoreSpiceParsedIR

struct ParsedNetlistCompiler: ~Copyable {
    let limits: MOSResolutionLimits
    let control: (any MOSResolutionControlling)?
    private var builder: MOSDeclarationSnapshotBuilder
    private let storage: FrontendStorage
    private let identity = MOSIdentitySpace()
    private var scopes: [FrontendScopeTemplate] = []
    private var models: [FrontendModelTemplate] = []
    private var slots: [NetlistScalarAddress: NetlistScalarSlot] = [:]
    private var origins: [ParsedModelOrigin?] = []
    private var nextSlot = 0

    init(limits: MOSResolutionLimits, control: (any MOSResolutionControlling)?) {
        self.limits = limits; self.control = control
        builder = MOSDeclarationSnapshotBuilder(limits: limits, control: control)
        storage = FrontendStorage(limits: limits, control: control)
    }
    consuming func compile(_ source: ParsedNetlist, overrideNames: [String]) throws -> CompiledNetlist {
        try storage.budget.add(UInt64(MemoryLayout<CompiledNetlist>.stride + MemoryLayout<ParsedNetlist>.stride))
        try storage.text(source.title); try storage.text(source.sourcePath)
        for name in overrideNames { _ = try builder.intern(name) }
        _ = try compileBody(source.body, parent: nil, subcircuit: nil)
        try compileControls(source.controls)
        try validateNodeAliases(source.initialConditions, initial: true)
        try validateNodeAliases(source.nodeSets, initial: false)
        try storage.retain(source.analyses)
        for (index, analysis) in source.analyses.enumerated() { try compileAnalysis(analysis, index: index, prefix: "") }
        try storage.budget.reserveDictionary(&slots, required: slots.count + source.initialConditions.count + source.nodeSets.count)
        for (name, value) in try storage.entries(source.initialConditions) {
            try storage.text(name); try storage.value(value)
            if slots[.initialCondition(node: name.lowercased())] == nil { try addSlot(value, at: .initialCondition(node: name.lowercased())) }
        }
        for (name, value) in try storage.entries(source.nodeSets) {
            try storage.text(name); try storage.value(value)
            if slots[.nodeSet(node: name.lowercased())] == nil { try addSlot(value, at: .nodeSet(node: name.lowercased())) }
        }
        try storage.retain(source.globalNodes)
        for name in source.globalNodes { try storage.text(name) }
        try storage.sourceEvidence(source)
        var hierarchicalMultiplier: MOSExpressionBinding?
        for scope in scopes {
            for template in scope.components {
                try storage.spend()
                if template.component.type == .subcircuitInstance, template.programs["m"] != nil,
                   hierarchicalMultiplier == nil {
                    let symbol = try builder.intern("m")
                    hierarchicalMultiplier = .init(symbol: symbol,
                        program: try compileValue(.expression(.identifier("m"))))
                }
            }
        }
        let snapshot = try builder.finish()
        try storage.budget.add(snapshot.retainedBytes)
        return CompiledNetlist(source: source, snapshot: snapshot, retainedBytes: storage.budget.bytes,
            identity: identity, scopes: scopes, models: models, slots: slots, modelOrigins: origins, hierarchicalMultiplier: hierarchicalMultiplier)
    }
    private mutating func compileBody(_ body: ParsedNetlistBody, parent: MOSScopeID?,
        subcircuit: ParsedSubcircuit?) throws -> MOSScopeID {
        try storage.spend()
        let origin = subcircuit?.origin
        let source = MOSSourceOccurrence(captureID: origin?.captureID, occurrenceID: origin?.occurrenceID?.rawValue,
            path: origin?.location.file ?? subcircuit?.location?.file,
            line: origin?.location.line ?? subcircuit?.location?.line,
            column: origin?.location.column ?? subcircuit?.location?.column,
            statementByteOffset: origin?.statementByteOffset, statementOrdinal: origin?.statementOrdinal)
        let scope = try builder.addScope(parent: parent, source: subcircuit == nil ? nil : source)
        try storage.reserve(&scopes, scopes.count + 1)
        scopes.append(FrontendScopeTemplate(id: scope, parent: parent, subcircuit: subcircuit,
            components: [], modelIndices: [], subcircuits: [:], functions: [:]))
        if let subcircuit {
            try storage.location(subcircuit.location); try storage.text(subcircuit.origin?.captureID); try storage.location(subcircuit.origin?.location)
            try storage.text(subcircuit.name); try storage.retain(subcircuit.ports)
            for port in subcircuit.ports { try storage.text(port) }
            let assignments = try orderedAssignments(subcircuit.parameterAssignments, fallback: subcircuit.parameters)
            for assignment in assignments {
                let symbol = try builder.intern(assignment.name), program = try compileValue(assignment.value)
                _ = try builder.addBinding(symbol: symbol, scope: scope, program: program,
                    source: frontendSource(assignment.origin, location: assignment.location))
            }
        }
        try storage.controls(body.controls)
        if subcircuit != nil {
            for control in body.controls {
                try storage.spend()
                if case .temp = control { throw LoweringError.unsupportedFeature(feature: "Temperature must be global") }
                if case .option(let name, _, _) = control, ["wnflag", "temp", "tnom"].contains(name.lowercased()) {
                    throw LoweringError.unsupportedFeature(feature: "Temperature and width conditions must be declared at global scope")
                }
            }
        }
        try storage.retain(body.parameterDefinitions)
        try storage.budget.add(MOSStorageBudget.capacityBytes(body.parameters.capacity, of: (String, ParsedExpression).self))
        if body.parameterDefinitions.isEmpty {
            for (name, expression) in try storage.entries(body.parameters) {
                try storage.text(name); try storage.expression(expression)
                let symbol = try builder.intern(name), program = try compileValue(.expression(expression))
                _ = try builder.addBinding(symbol: symbol, scope: scope, program: program)
            }
        } else {
            for definition in body.parameterDefinitions {
                try storage.location(definition.location); try storage.origin(definition.origin)
                try storage.text(definition.name); try storage.expression(definition.value)
                let symbol = try builder.intern(definition.name), program = try compileValue(.expression(definition.value))
                _ = try builder.addBinding(symbol: symbol, scope: scope, program: program,
                    source: frontendSource(definition.origin, location: definition.location))
            }
            for (name, expression) in body.parameters { try storage.text(name); try storage.expression(expression) }
        }
        var functions: [String: ParsedFunctionDefinition] = [:]
        try storage.retain(body.functionDefinitions)
        let definitions: [ParsedFunctionDefinition]
        if body.functionDefinitions.isEmpty {
            var fallback: [ParsedFunctionDefinition] = []
            for statement in body.controls {
                if case .function(let name, let parameters, let expression, let location) = statement {
                    try storage.reserve(&fallback, fallback.count + 1)
                    fallback.append(.init(name: name, parameters: parameters, body: expression, location: location))
                }
            }
            definitions = fallback
        } else { definitions = body.functionDefinitions }
        for function in definitions {
            try storage.location(function.location); try storage.origin(function.origin)
            try storage.text(function.name); try storage.retain(function.parameters); try storage.expression(function.body)
            var formals: [MOSSymbolID] = []
            for parameter in function.parameters {
                try storage.text(parameter); try storage.reserve(&formals, formals.count + 1)
                formals.append(try builder.intern(parameter))
            }
            let name = try builder.intern(function.name), program = try compileValue(.expression(function.body))
            _ = try builder.addFunction(symbol: name, scope: scope, parameters: formals, program: program,
                source: frontendSource(function.origin, location: function.location))
            try storage.reserve(&functions, functions.count + 1)
            functions[function.name.lowercased()] = function
        }
        var indices: [Int] = []
        try storage.retain(body.models)
        for model in body.models {
            try storage.location(model.location); try storage.text(model.origin?.captureID); try storage.location(model.origin?.location)
            try storage.text(model.name)
            let assignments = try orderedAssignments(model.parameterAssignments, fallback: model.parameters)
            var coefficients: [MOSExpressionBinding] = [], programs: [(String, MOSProgramID)] = []
            var invalidCoefficient: MOSSymbolID?
            let isMOS = model.type == .nmos || model.type == .pmos
            for assignment in assignments {
                let name = assignment.name.lowercased()
                if name == "level" || name == "version" { continue }
                guard isScalar(assignment.value) else {
                    if isMOS, invalidCoefficient == nil { invalidCoefficient = try builder.intern(name) }
                    continue
                }
                let symbol = try builder.intern(name), program = try compileValue(assignment.value)
                try storage.reserve(&coefficients, coefficients.count + 1)
                coefficients.append(.init(symbol: symbol, program: program))
                try storage.reserve(&programs, programs.count + 1)
                programs.append((name, program))
            }
            if isMOS {
                let version: String?
                if case .string(let exact) = model.parameters["version"] { version = exact }
                else {
                    version = nil
                    if model.parameters["version"] != nil, invalidCoefficient == nil {
                        invalidCoefficient = try builder.intern("version")
                    }
                }
                _ = try builder.addModel(name: model.name, scope: scope,
                    polarity: model.type == .nmos ? .nmos : .pmos, level: model.level,
                    version: version, coefficients: coefficients, source: frontendModelSource(model),
                    invalidCoefficient: invalidCoefficient)
                try storage.reserve(&origins, origins.count + 1); origins.append(model.origin)
            }
            try storage.reserve(&indices, indices.count + 1); indices.append(models.count)
            try storage.reserve(&models, models.count + 1)
            models.append(FrontendModelTemplate(model: model, scope: scope, programs: programs))
        }
        var components: [FrontendComponentTemplate] = []
        try storage.retain(body.components)
        for component in body.components {
            try storage.location(component.location); try storage.origin(component.origin)
            try storage.text(component.name); try storage.text(component.modelName); try storage.text(component.passiveModelCandidate)
            try storage.retain(component.nodes)
            for node in component.nodes { try storage.text(node.name) }
            let assignments = try orderedAssignments(component.parameterAssignments, fallback: component.parameters)
            var programs: [String: MOSProgramID] = [:], bindings: [MOSExpressionBinding] = []
            let hasInitialVector = component.type == .mosfet && assignments.contains { $0.name.lowercased() == "ic" }
            var mosFailure: String?
            for assignment in assignments {
                let name = assignment.name.lowercased()
                if component.type == .mosfet && name == "ic" {
                    let count: Int
                    if case .numericVector(let vector) = assignment.value {
                        count = vector.count
                        if !assignment.additionalValues.isEmpty { mosFailure = "MOS IC requires one to three scalar operands" }
                    } else { count = 1 + assignment.additionalValues.count }
                    guard (1...3).contains(count) else { mosFailure = "MOS IC requires one to three scalar operands"; continue }
                    for index in 0..<count {
                        let value: ParsedParameterValue
                        if case .numericVector(let vector) = assignment.value { value = .numeric(vector[index]) }
                        else { value = index == 0 ? assignment.value : assignment.additionalValues[index - 1] }
                        guard isScalar(value) else { mosFailure = "MOS IC operands must be scalar"; continue }
                        let canonical = index == 0 ? "ic_vds" : index == 1 ? "ic_vgs" : "ic_vbs"
                        if programs[canonical] != nil { mosFailure = "MOS IC vector and explicit canonical assignments must be unique" }
                        let symbol = try builder.intern(canonical), program = try compileValue(value)
                        try storage.reserve(&programs, programs.count + 1); programs[canonical] = program
                        try storage.reserve(&bindings, bindings.count + 1); bindings.append(.init(symbol: symbol, program: program))
                    }
                    continue
                }
                if component.type == .mosfet && !assignment.additionalValues.isEmpty { mosFailure = "Only MOS IC accepts multiple scalar operands" }
                guard isScalar(assignment.value) else {
                    if component.type == .mosfet { mosFailure = "MOS supplied assignments must be scalar" }
                    continue
                }
                if name == "control_source" {
                    if component.type == .mosfet { mosFailure = "MOS control_source is not a supported supplied assignment" }
                    continue
                }
                if component.type == .mosfet && hasInitialVector && ["ic_vds", "ic_vgs", "ic_vbs"].contains(name) {
                    mosFailure = "MOS IC vector and explicit canonical assignments must be unique"
                }
                let symbol = try builder.intern(name), program = try compileValue(assignment.value)
                try storage.reserve(&programs, programs.count + 1); programs[name] = program
                try storage.reserve(&bindings, bindings.count + 1); bindings.append(.init(symbol: symbol, program: program))
            }
            // Metadata owns IC operands; parser default projections do not become supplied inputs.
            for (name, value) in try storage.entries(component.parameters) {
                let normalized = name.lowercased()
                if hasInitialVector && ["ic", "ic_vds", "ic_vgs", "ic_vbs"].contains(normalized) { continue }
                if programs[normalized] != nil { continue }
                if normalized == "control_source" {
                    if component.type == .mosfet { mosFailure = "MOS control_source is not a supported supplied assignment" }
                    continue
                }
                guard isScalar(value) else {
                    if component.type == .mosfet { mosFailure = "MOS supplied assignments must be scalar" }
                    continue
                }
                let symbol = try builder.intern(normalized), program = try compileValue(value)
                try storage.reserve(&programs, programs.count + 1); programs[normalized] = program
                try storage.reserve(&bindings, bindings.count + 1); bindings.append(.init(symbol: symbol, program: program))
            }
            if let modelName = component.modelName { _ = try builder.intern(modelName) }
            try storage.reserve(&components, components.count + 1)
            components.append(.init(component: component, scope: scope, programs: programs, assignments: bindings,
                mosAssignmentFailure: mosFailure, hasMOSInitialConditionVector: hasInitialVector))
        }
        var children: [String: MOSScopeID] = [:]
        try storage.retain(body.subcircuits)
        for child in body.subcircuits {
            let id = try compileBody(child.body, parent: scope, subcircuit: child)
            try storage.reserve(&children, children.count + 1); children[child.name.lowercased()] = id
        }
        scopes[Int(scope.rawValue)] = .init(id: scope, parent: parent, subcircuit: subcircuit,
            components: components, modelIndices: indices, subcircuits: children, functions: functions)
        return scope
    }
    private func isScalar(_ value: ParsedParameterValue) -> Bool {
        switch value { case .numeric, .boolean, .expression: true; case .string, .numericVector: false }
    }
    private func orderedAssignments(_ ordered: [ParsedParameterAssignment], fallback: [String: ParsedParameterValue]) throws -> [ParsedParameterAssignment] {
        try storage.retain(ordered)
        try storage.budget.add(MOSStorageBudget.capacityBytes(fallback.capacity, of: (String, ParsedParameterValue).self))
        for (name, value) in fallback { try storage.text(name); try storage.value(value) }
        if !ordered.isEmpty {
            for assignment in ordered {
                try storage.location(assignment.location); try storage.origin(assignment.origin)
                try storage.text(assignment.name); try storage.value(assignment.value); try storage.retain(assignment.additionalValues)
                for extra in assignment.additionalValues { try storage.value(extra) }
            }
            return ordered
        }
        var result: [ParsedParameterAssignment] = []
        for (name, value) in try storage.entries(fallback) {
            try storage.reserve(&result, result.count + 1); result.append(.init(name: name, value: value))
        }
        return result
    }
    private mutating func compileValue(_ value: ParsedParameterValue) throws -> MOSProgramID {
        let before = storage.budget.bytes
        try storage.value(value)
        defer { storage.budget.release(storage.budget.bytes - before) }
        let expression: MOSExpression
        switch value {
        case .numeric(let number): expression = .literal(number)
        case .boolean(let flag): expression = .literal(flag ? 1 : 0)
        case .expression(let parsed): expression = try bridge(parsed, depth: 1)
        case .string, .numericVector: throw MOSResolutionFailure.invalidRequest
        }
        return try builder.addProgram(expression)
    }
    private mutating func bridge(_ parsed: ParsedExpression, depth: Int) throws -> MOSExpression {
        guard depth <= limits.maximumExpressionDepth else { throw MOSResolutionFailure.limitExceeded(.expressionDepth) }
        try storage.spend()
        switch parsed {
        case .literal(let value): return .literal(value)
        case .identifier(let name): return .reference(try builder.intern(name))
        case .unaryOperation(let operation, let value):
            let mapped: MOSUnaryOperator = switch operation { case .plus: .plus; case .negate: .negate; case .not: .not }
            return .unary(mapped, try bridge(value, depth: depth + 1))
        case .binaryOperation(let operation, let lhs, let rhs):
            let mapped: MOSBinaryOperator = switch operation {
            case .add: .add; case .subtract: .subtract; case .multiply: .multiply; case .divide: .divide
            case .power: .power; case .modulo: .modulo; case .equal: .equal; case .notEqual: .notEqual
            case .lessThan: .lessThan; case .lessOrEqual: .lessOrEqual; case .greaterThan: .greaterThan
            case .greaterOrEqual: .greaterOrEqual; case .and: .and; case .or: .or
            }
            return .binary(mapped, try bridge(lhs, depth: depth + 1), try bridge(rhs, depth: depth + 1))
        case .conditional(let condition, let yes, let no):
            return .conditional(condition: try bridge(condition, depth: depth + 1),
                then: try bridge(yes, depth: depth + 1), else: try bridge(no, depth: depth + 1))
        case .functionCall(let name, let arguments):
            let symbol = try builder.intern(name)
            var values: [MOSExpression] = []
            for argument in arguments {
                try storage.reserve(&values, values.count + 1); values.append(try bridge(argument, depth: depth + 1))
            }
            return .function(symbol, arguments: values)
        }
    }
    private func validateNodeAliases(_ values: [String: ParsedParameterValue], initial: Bool) throws {
        var aliases: [String: ParsedParameterValue] = [:]
        for (name, value) in values {
            try storage.spend()
            let key = name.lowercased()
            let address: NetlistScalarAddress = initial ? .initialCondition(node: key) : .nodeSet(node: key)
            if slots[address] != nil { continue }
            if let existing = aliases[key] {
                guard existing == value else { throw MOSResolutionFailure.invalidRequest }
            } else {
                try storage.text(key); try storage.reserve(&aliases, aliases.count + 1); aliases[key] = value
            }
        }
    }
    private mutating func addSlot(_ value: ParsedParameterValue?, at address: NetlistScalarAddress) throws {
        guard let value, isScalar(value) else { return }
        let program = try compileValue(value)
        try storage.reserve(&slots, slots.count + 1)
        slots[address] = .init(address: address, program: program, identity: identity, index: nextSlot)
        nextSlot += 1
    }
    private mutating func compileControls(_ controls: [ParsedControlStatement]) throws {
        try storage.retain(controls)
        for (index, statement) in controls.enumerated() {
            try storage.spend()
            switch statement {
            case .option(let name, let value, _):
                if ["temp", "tnom"].contains(name.lowercased()) {
                    guard let value, isScalar(value) else {
                        throw LoweringError.unsupportedFeature(feature: "Temperature requires one scalar value")
                    }
                }
                try storage.text(name); if let value { try storage.value(value) }
                try addSlot(value, at: .control(index: index, field: "value"))
            case .temp(let value, _):
                guard isScalar(value) else { throw LoweringError.unsupportedFeature(feature: "Temperature sweeps are not supported") }
                try storage.value(value); try addSlot(value, at: .control(index: index, field: "value"))
            case .initialCondition(let node, let value, _):
                try storage.text(node); try storage.value(value)
                try addSlot(value, at: .control(index: index, field: "value"))
                if let slot = slots[.control(index: index, field: "value")] { try storage.reserve(&slots, slots.count + 1); slots[.initialCondition(node: node.lowercased())] = slot }
            case .nodeSet(let node, let value, _):
                try storage.text(node); try storage.value(value)
                try addSlot(value, at: .control(index: index, field: "value"))
                if let slot = slots[.control(index: index, field: "value")] { try storage.reserve(&slots, slots.count + 1); slots[.nodeSet(node: node.lowercased())] = slot }
            case .alter(let spec): try addSlot(spec.value, at: .control(index: index, field: "value"))
            case .measure(let spec):
                switch spec.measureType {
                case .find(_, let value): try addSlot(value, at: .control(index: index, field: "at"))
                case .average(_, let from, let to), .rms(_, let from, let to), .min(_, let from, let to), .max(_, let from, let to), .peakToPeak(_, let from, let to), .integral(_, let from, let to):
                    try addSlot(from, at: .control(index: index, field: "from")); try addSlot(to, at: .control(index: index, field: "to"))
                case .delay(_, let first, _, let second):
                    try addSlot(first, at: .control(index: index, field: "value1")); try addSlot(second, at: .control(index: index, field: "value2"))
                default: break
                }
            default: break
            }
        }
    }
    private mutating func compileAnalysis(_ analysis: ParsedAnalysisCommand, index: Int, prefix: String, depth: Int = 1) throws {
        guard depth <= limits.maximumExpressionDepth else { throw MOSResolutionFailure.limitExceeded(.expressionDepth) }
        try storage.analysis(analysis, recursive: false)
        func address(_ field: String) -> NetlistScalarAddress { .analysis(index: index, field: prefix + field) }
        switch analysis {
        case .dc(let spec):
            try addSlot(spec.startValue, at: address("startValue")); try addSlot(spec.stopValue, at: address("stopValue"))
            try addSlot(spec.stepValue, at: address("stepValue")); try addSlot(spec.startValue2, at: address("startValue2"))
            try addSlot(spec.stopValue2, at: address("stopValue2")); try addSlot(spec.stepValue2, at: address("stepValue2"))
        case .transient(let spec):
            try addSlot(spec.stopTime, at: address("stopTime")); try addSlot(spec.stepTime, at: address("stepTime"))
            try addSlot(spec.startTime, at: address("startTime")); try addSlot(spec.maxStep, at: address("maxStep"))
        case .ac(let spec):
            try addSlot(spec.startFrequency, at: address("startFrequency")); try addSlot(spec.stopFrequency, at: address("stopFrequency"))
        case .noise(let spec):
            try addSlot(spec.startFrequency, at: address("startFrequency")); try addSlot(spec.stopFrequency, at: address("stopFrequency"))
        case .monteCarlo(let spec): try compileAnalysis(spec.analysis, index: index, prefix: prefix + "analysis.", depth: depth + 1)
        case .sensitivity(let spec):
            if let ac = spec.acSpec { try addSlot(ac.startFrequency, at: address("acSpec.startFrequency")); try addSlot(ac.stopFrequency, at: address("acSpec.stopFrequency")) }
        case .fourier(let spec): try addSlot(spec.frequency, at: address("frequency"))
        default: break
        }
    }
}
