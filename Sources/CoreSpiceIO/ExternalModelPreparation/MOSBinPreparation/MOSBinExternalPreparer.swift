import CoreSpiceLowering
import CoreSpiceMOSContracts
import CoreSpiceMOSResolution
import CoreSpiceOSDIContracts
import CoreSpiceParsedIR
import OSDIContracts

/// Original-source bin selection using a caller-supplied foreign normalization profile.
public struct MOSBinExternalPreparer: ExternalMOSPreparing {
    public let profile: ExternalMOSNormalizationProfile
    private let resources: any SPICESourceResourceAccounting
    private let profileReservation: SPICESourceStorageReservation
    public let identity: String

    public init(profile: ExternalMOSNormalizationProfile, resources: any SPICESourceResourceAccounting,
                maximumIdentityBytes: UInt64) throws {
        let bytes = try Self.retainedProfileBytes(profile)
        let reservation = try resources.reserveStorage(kind: .liveOwnedBytes, byteCount: bytes)
        self.profile = profile; self.resources = resources; profileReservation = reservation
        identity = "external-mos-profile-v1:" + (try profile.digest(resources: resources,
            maximumBytes: maximumIdentityBytes)).hexadecimalValue
    }

    public func prepare(_ source: ExternalMOSSourceRequest,
        evaluate: (ExternalMOSScalarAddress) throws -> Double,
        chargeWork: () throws -> Void) throws -> ExternalMOSPreparation {
        func step() throws {
            try resources.checkCancellation()
            try resources.charge(.retainedElements, units: 1)
            try chargeWork()
        }
        func added(_ a: Int, _ b: Int) throws -> Int {
            let (n, overflow) = a.addingReportingOverflow(b)
            guard !overflow, n >= 0 else { throw MOSBinPreparationError.sizeOverflow }; return n
        }
        func multiplied(_ a: Int, _ b: Int) throws -> Int {
            let (n, overflow) = a.multipliedReportingOverflow(by: b)
            guard !overflow, n >= 0 else { throw MOSBinPreparationError.sizeOverflow }; return n
        }
        var maximumCoefficients = 0
        for id in source.candidateDeclarations {
            try step()
            maximumCoefficients = max(maximumCoefficients, try source.snapshot.declaration(id).coefficients.count)
        }
        var capacity = try multiplied(source.candidateDeclarations.count, 4)
        for count in [maximumCoefficients, source.resolution.bindings.count,
                      source.resolution.modelOverrides.count, profile.nmosAssignments.count,
                      profile.pmosAssignments.count, 8] { capacity = try added(capacity, count) }
        let records = try multiplied(capacity, MemoryLayout<ExternalMOSParameterFact>.stride
            + MemoryLayout<OSDIParameterAssignment>.stride + MemoryLayout<EvaluatedParameter>.stride)
        var nameCount = 0, nameBytes = 0
        for parameter in profile.parameters {
            try step()
            for name in parameter.names {
                try step()
                nameCount = try added(nameCount, 1); nameBytes = try added(nameBytes, name.utf8.count)
            }
        }
        for rule in profile.rules {
            try step()
            for name in rule.sourceNames {
                try step()
                nameCount = try added(nameCount, 1); nameBytes = try added(nameBytes, name.utf8.count)
            }
        }
        // Conservative logical payload capacity covers result/temporary vectors,
        // both lookup tables and canonical-name references before their growth.
        let mapBytes = try added(try multiplied(nameCount, 4 * (MemoryLayout<SourceKey>.stride
            + MemoryLayout<BoundRule>.stride + MemoryLayout<OSDIParameterInfo>.stride)), nameBytes)
        let reservation = try resources.reserveStorage(kind: .temporaryBytes,
            byteCount: UInt64(try added(records, mapBytes)))
        defer { withExtendedLifetime(reservation) {} }
        let rules = try bindProfile(nameCapacity: nameCount, step: step)
        guard source.graph.snapshot.sameStorage(as: source.snapshot),
              !source.candidateDeclarations.isEmpty,
              source.resolution.geometryScale.isFinite, source.resolution.geometryScale > 0,
              source.resolution.source?.captureID != nil,
              source.original.origin != nil else { throw MOSBinPreparationError.invalidSource("source binding") }

        var facts: [ExternalMOSParameterFact] = []; facts.reserveCapacity(capacity)
        var instanceValues: [EvaluatedParameter] = []
        instanceValues.reserveCapacity(source.resolution.bindings.count)
        var seenInstance = Set<Int>(); seenInstance.reserveCapacity(source.resolution.bindings.count)
        for (index, binding) in source.resolution.bindings.enumerated() {
            try step()
            let name = try source.snapshot.name(of: binding.symbol)
            guard let rule = rules[SourceKey(name: name, scope: .instance)] else {
                throw MOSBinPreparationError.unknownParameter(name)
            }
            guard seenInstance.insert(rule.index).inserted else { throw MOSBinPreparationError.duplicateParameter(name) }
            let value = try evaluate(.instance(index: index))
            try validate(value, rule: rule.rule)
            instanceValues.append(.init(rule: rule, address: .instance(index: index), raw: value))
        }
        func raw(_ meaning: ExternalMOSParameterRule.Meaning) throws -> Double? {
            for value in instanceValues {
                try step()
                if value.rule.rule.meaning == meaning { return value.raw }
            }
            return nil
        }
        guard let length = try raw(.length) else { throw MOSBinPreparationError.missingGeometry("l") }
        guard let width = try raw(.width) else { throw MOSBinPreparationError.missingGeometry("w") }
        let fingers = try raw(.fingerCount) ?? profile.omittedFingerCount
        guard let nf = fingers, nf.isFinite, nf >= 1, nf.rounded(.towardZero) == nf else {
            throw MOSBinPreparationError.invalidGeometry("nf")
        }
        let multiplier = try raw(.multiplicity) ?? 1
        guard multiplier.isFinite, multiplier > 0 else { throw MOSBinPreparationError.invalidGeometry("m") }
        if source.resolution.globalWidthPerFinger && profile.selectionWidth == .total {
            throw MOSBinPreparationError.invalidSource("width selection flag conflicts with profile")
        }
        let scale = source.resolution.geometryScale
        let lengthSI = try scaled(length, by: scale, kind: .length, name: "l")
        func widthSI(_ convention: ExternalMOSNormalizationProfile.WidthConvention) throws -> Double {
            let unscaled: Double
            switch (profile.sourceWidth, convention) {
            case (.total, .perFinger): unscaled = width / nf
            case (.perFinger, .total): unscaled = width * nf
            default: unscaled = width
            }
            guard unscaled.isFinite, unscaled > 0 else { throw MOSBinPreparationError.invalidGeometry("w/nf") }
            return try scaled(unscaled, by: scale, kind: .length, name: "w")
        }
        let selectionConvention: ExternalMOSNormalizationProfile.WidthConvention
        switch profile.selectionWidth {
        case .total: selectionConvention = .total
        case .perFinger: selectionConvention = .perFinger
        case .sourceFlag: selectionConvention = source.resolution.globalWidthPerFinger ? .perFinger : .total
        }
        let totalWidth = try widthSI(.total)
        let selectionWidth = try widthSI(selectionConvention)
        let providerWidth = try widthSI(profile.providerWidth)
        let geometry = ExternalMOSGeometry(rawLength: length, rawWidth: width,
            effectiveLengthSI: lengthSI, totalWidthSI: totalWidth,
            selectionLengthSI: lengthSI, selectionWidthSI: selectionWidth,
            fingerCount: nf, parallelMultiplier: multiplier,
            widthInputIsPerFinger: profile.sourceWidth == .perFinger)
        var instanceAssignments: [OSDIParameterAssignment] = []
        instanceAssignments.reserveCapacity(instanceValues.count)
        for value in instanceValues {
            try step()
            let number: Double
            if value.rule.rule.meaning == .width { number = providerWidth }
            else {
                number = try scaled(value.raw, by: scale, kind: value.rule.rule.scale,
                                    name: value.rule.rule.sourceNames[0])
            }
            let assignment = try numericAssignment(value: number, rule: value.rule, scope: .instance)
            if let assignment { instanceAssignments.append(assignment) }
            facts.append(fact(value, normalized: number, assignment: assignment))
        }
        if try raw(.fingerCount) == nil {
            facts.append(.init(address: nil, name: "nf", role: .instance, rawValue: nil,
                normalizedValue: nf, providerValue: nil, isGiven: false))
        }
        if try raw(.multiplicity) == nil {
            facts.append(.init(address: nil, name: "m", role: .instance, rawValue: nil,
                normalizedValue: 1, providerValue: nil, isGiven: false))
        }

        var selected: MOSModelDeclaration?
        var visitedNames = Set<MOSSymbolID>(); visitedNames.reserveCapacity(source.candidateDeclarations.count)
        // Duplicate-card policy is resolved in original declaration order, independent
        // of traversal order. A discarded duplicate never evaluates a coefficient.
        var candidates: [MOSDeclarationID] = []; candidates.reserveCapacity(source.candidateDeclarations.count)
        for id in source.candidateDeclarations {
            try step()
            let model = try source.snapshot.declaration(id)
            if !visitedNames.insert(model.name).inserted {
                guard profile.duplicateModels == .firstDeclaration else {
                    throw MOSBinPreparationError.duplicateModel(model.originalName)
                }
            } else { candidates.append(id) }
        }
        if profile.candidateOrder == .firstReverse { candidates.reverse() }
        for id in candidates {
            try step()
            let model = try source.snapshot.declaration(id)
            guard model.scope == source.candidateScope, model.invalidCoefficient == nil,
                  model.level == profile.sourceLevel,
                  let version = model.version, profile.sourceVersions.contains(version),
                  model.source.captureID != nil, model.source.statementByteOffset != nil else {
                throw MOSBinPreparationError.invalidSource(model.originalName)
            }
            let original = try source.originalModel(for: id, chargeWork: step)
            var sourceNames = Set<String>(); sourceNames.reserveCapacity(original.parameterAssignments.count)
            for assignment in original.parameterAssignments {
                try step()
                guard sourceNames.insert(assignment.name.lowercased()).inserted else {
                    throw MOSBinPreparationError.duplicateParameter(assignment.name)
                }
            }
            var bounds: [ExternalMOSParameterRule.Meaning: Double] = [:]; bounds.reserveCapacity(4)
            var seenBounds = Set<Int>(); seenBounds.reserveCapacity(4)
            if source.isFamily {
                for (index, binding) in model.coefficients.enumerated() {
                    try step()
                    let name = try source.snapshot.name(of: binding.symbol)
                    guard let rule = rules[SourceKey(name: name, scope: .model)], rule.rule.meaning.isBound else { continue }
                    guard seenBounds.insert(rule.index).inserted else { throw MOSBinPreparationError.duplicateParameter(name) }
                    let value = try evaluate(.model(declaration: id, index: index))
                    try validate(value, rule: rule.rule)
                    guard value >= 0 else { throw MOSBinPreparationError.invalidBin(model.originalName) }
                    bounds[rule.rule.meaning] = value
                    facts.append(.init(address: .model(declaration: id, index: index), name: name,
                        role: .model, rawValue: value, normalizedValue: value, providerValue: nil, isGiven: true))
                }
                guard let lmin = bounds[.lengthMinimum], let lmax = bounds[.lengthMaximum],
                      let wmin = bounds[.widthMinimum], let wmax = bounds[.widthMaximum],
                      lmin <= lmax, wmin <= wmax else { throw MOSBinPreparationError.invalidBin(model.originalName) }
                func contains(_ x: Double, _ lower: Double, _ upper: Double) -> Bool {
                    (x >= lower && x <= upper) || abs(x - lower) < profile.endpointToleranceSI
                        || abs(x - upper) < profile.endpointToleranceSI
                }
                if !contains(lengthSI, lmin, lmax) || !contains(selectionWidth, wmin, wmax) { continue }
            }
            guard selected == nil else { throw MOSBinPreparationError.ambiguousBins }
            selected = model
            if profile.candidateOrder != .unique { break }
        }
        guard let model = selected else { throw MOSBinPreparationError.noMatchingBin }
        var modelValues: [EvaluatedParameter] = []; modelValues.reserveCapacity(model.coefficients.count)
        var seenModel = Set<Int>(); seenModel.reserveCapacity(model.coefficients.count)
        for (index, binding) in model.coefficients.enumerated() {
            try step()
            let name = try source.snapshot.name(of: binding.symbol)
            guard let rule = rules[SourceKey(name: name, scope: .model)] else {
                throw MOSBinPreparationError.unknownParameter(name)
            }
            guard seenModel.insert(rule.index).inserted else { throw MOSBinPreparationError.duplicateParameter(name) }
            let value = try evaluate(.model(declaration: model.id, index: index))
            try validate(value, rule: rule.rule)
            modelValues.append(.init(rule: rule, address: .model(declaration: model.id, index: index), raw: value))
        }
        var overridden = Set<Int>(); overridden.reserveCapacity(source.resolution.modelOverrides.count)
        for (index, binding) in source.resolution.modelOverrides.enumerated() {
            try step()
            let name = try source.snapshot.name(of: binding.symbol)
            guard let rule = rules[SourceKey(name: name, scope: .model)], !rule.rule.meaning.isBound,
                  let originalIndex = try modelValues.firstIndex(where: { try step(); return $0.rule.index == rule.index }) else {
                throw MOSBinPreparationError.invalidParameter(name)
            }
            guard overridden.insert(rule.index).inserted else { throw MOSBinPreparationError.duplicateParameter(name) }
            let prior = modelValues[originalIndex]
            facts.append(fact(prior, normalized: prior.raw, assignment: nil))
            let value = try evaluate(.modelOverride(index: index)); try validate(value, rule: rule.rule)
            modelValues[originalIndex] = .init(rule: rule, address: .modelOverride(index: index), raw: value)
        }
        var modelAssignments: [OSDIParameterAssignment] = []; modelAssignments.reserveCapacity(capacity)
        for value in modelValues {
            try step()
            let assignment = try numericAssignment(value: value.raw, rule: value.rule, scope: .model)
            if let assignment { modelAssignments.append(assignment) }
            let entry = fact(value, normalized: value.raw, assignment: assignment)
            if let index = try facts.firstIndex(where: { try step(); return $0.address == entry.address }) { facts[index] = entry }
            else { facts.append(entry) }
        }
        let polarity = model.polarity == .nmos ? profile.nmosAssignments : profile.pmosAssignments
        for assignment in polarity {
            try step()
            try appendUnique(assignment, to: &modelAssignments, step: step)
            facts.append(.init(address: nil, name: assignment.name, role: .model, rawValue: nil,
                normalizedValue: assignment.value.numericValue, providerValue: assignment.value, isGiven: true))
        }
        if let name = profile.versionParameter, let version = model.version {
            let assignment = try OSDIParameterAssignment(name: name, scope: .model, value: .string(version))
            try appendUnique(assignment, to: &modelAssignments, step: step)
            facts.append(.init(address: nil, name: name, role: .model, rawValue: nil,
                normalizedValue: nil, providerValue: assignment.value, isGiven: true))
        }
        let binding = try OSDIModelBinding(modelName: model.originalName, artifact: profile.artifact,
            descriptorIndex: profile.descriptor.index, expectedDescriptorName: profile.descriptor.name,
            modelParameters: modelAssignments)
        let resolved = try OSDIResolvedInstance(binding: binding, instanceParameters: instanceAssignments, previousState: [])
        return ExternalMOSPreparation(source: source, selectedDeclaration: model.id, resolved: resolved,
            facts: .init(profileIdentity: identity, geometry: geometry, parameters: facts))
    }
}

private struct SourceKey: Hashable {
    let name: String
    let role: Int32
    init(name: String, scope: OSDIParameterScope) { self.name = name; role = scope.rawValue }
}
private enum MetadataMatch {
    case unique(OSDIParameterInfo)
    case ambiguous
}
private struct ProviderKey: Hashable {
    let parameter: Int
    let scope: Int32
    init(_ parameter: OSDIParameterInfo, scope: OSDIParameterScope) {
        self.parameter = parameter.index; self.scope = scope.rawValue
    }
}
private struct BoundRule {
    let index: Int
    let rule: ExternalMOSParameterRule
    let parameter: OSDIParameterInfo?
}
private struct EvaluatedParameter {
    let rule: BoundRule
    let address: ExternalMOSScalarAddress
    let raw: Double
}
private extension ExternalMOSParameterRule.Meaning {
    var isBound: Bool {
        switch self {
        case .lengthMinimum, .lengthMaximum, .widthMinimum, .widthMaximum: true
        default: false
        }
    }
}
private extension OSDIParameterValue {
    var numericValue: Double? {
        switch self {
        case .real(let x): x
        case .integer(let x): Double(x)
        case .string: nil
        }
    }
}

private extension MOSBinExternalPreparer {
    func bindProfile(nameCapacity: Int, step: () throws -> Void) throws -> [SourceKey: BoundRule] {
        guard !identity.isEmpty, !identity.utf8.contains(0), !profile.sourceVersions.isEmpty,
              profile.sourceVersions.allSatisfy({ !$0.isEmpty && !$0.utf8.contains(0) }),
              profile.endpointToleranceSI.isFinite, profile.endpointToleranceSI >= 0,
              !profile.nmosAssignments.isEmpty, !profile.pmosAssignments.isEmpty,
              profile.nmosAssignments != profile.pmosAssignments else {
            throw MOSBinPreparationError.invalidProfile("dispatch/polarity")
        }
        let (count, overflow) = profile.descriptor.parameterCount.addingReportingOverflow(profile.descriptor.operatingPointCount)
        guard !overflow, profile.parameters.count == count else {
            throw MOSBinPreparationError.descriptorMismatch("parameter count")
        }
        var metadata: [String: MetadataMatch] = [:]; metadata.reserveCapacity(nameCapacity)
        var instanceCount = 0, operatingCount = 0
        for (index, parameter) in profile.parameters.enumerated() {
            try step()
            guard parameter.index == index else { throw MOSBinPreparationError.descriptorMismatch("parameter index") }
            if parameter.kind == .instance { instanceCount += 1 }
            if parameter.kind == .operatingPoint { operatingCount += 1 }
            guard (index < profile.descriptor.parameterCount) == (parameter.kind != .operatingPoint) else {
                throw MOSBinPreparationError.descriptorMismatch("parameter kind")
            }
            for name in parameter.names {
                try step()
                // SDK lookup searches setter indices, not scopes or operating points.
                // A repeated alias within one index still denotes that same setter.
                guard parameter.kind != .operatingPoint else { continue }
                if let existing = metadata[name] {
                    if case .unique(let prior) = existing, prior.index == parameter.index { continue }
                    metadata[name] = .ambiguous
                } else { metadata[name] = .unique(parameter) }
            }
        }
        guard instanceCount == profile.descriptor.instanceParameterCount,
              operatingCount == profile.descriptor.operatingPointCount else {
            throw MOSBinPreparationError.descriptorMismatch("parameter kind count")
        }
        func setter(_ name: String, scope: OSDIParameterScope) throws -> OSDIParameterInfo {
            try step()
            guard case .unique(let parameter)? = metadata[name], parameter.kind != .operatingPoint,
                  parameter.arrayLength == 0,
                  scope == .model || parameter.kind == .instance else {
                throw MOSBinPreparationError.descriptorMismatch(name)
            }
            return parameter
        }
        var bound: [SourceKey: BoundRule] = [:]; bound.reserveCapacity(nameCapacity)
        var meanings = Set<ExternalMOSParameterRule.Meaning>(); meanings.reserveCapacity(8)
        var providerKeys = Set<ProviderKey>(); providerKeys.reserveCapacity(profile.rules.count)
        for (index, rule) in profile.rules.enumerated() {
            try step()
            guard !rule.sourceNames.isEmpty,
                  rule.requiredValue == nil || rule.requiredValue!.isFinite,
                  rule.scope != .model || rule.scale == .none else {
                throw MOSBinPreparationError.invalidProfile("parameter rule")
            }
            if rule.meaning != .ordinary {
                guard meanings.insert(rule.meaning).inserted,
                      rule.scope == (rule.meaning.isBound ? .model : .instance) else {
                    throw MOSBinPreparationError.invalidProfile("geometry role")
                }
                let expected: MOSParameterScale = rule.meaning == .length || rule.meaning == .width ? .length : .none
                guard rule.scale == expected else { throw MOSBinPreparationError.invalidProfile("geometry scale") }
            }
            let parameter: OSDIParameterInfo?
            if let name = rule.providerName {
                let info = try setter(name, scope: rule.scope)
                guard info.type != .string,
                      providerKeys.insert(ProviderKey(info, scope: rule.scope)).inserted else {
                    throw MOSBinPreparationError.invalidProfile("provider alias/type")
                }
                parameter = info
            } else { parameter = nil }
            let result = BoundRule(index: index, rule: rule, parameter: parameter)
            for name in rule.sourceNames {
                try step()
                guard !name.isEmpty, name == name.lowercased(), !name.utf8.contains(0),
                      name != "level", name != "version", name != "scale",
                      bound[SourceKey(name: name, scope: rule.scope)] == nil else {
                    throw MOSBinPreparationError.invalidProfile("source alias/scale")
                }
                bound[SourceKey(name: name, scope: rule.scope)] = result
            }
        }
        guard meanings.contains(.length), meanings.contains(.width), meanings.contains(.fingerCount),
              meanings.contains(.multiplicity), meanings.contains(.lengthMinimum),
              meanings.contains(.lengthMaximum), meanings.contains(.widthMinimum),
              meanings.contains(.widthMaximum) else { throw MOSBinPreparationError.invalidProfile("missing geometry roles") }
        if let omitted = profile.omittedFingerCount {
            guard omitted.isFinite, omitted >= 1, omitted.rounded(.towardZero) == omitted else {
                throw MOSBinPreparationError.invalidProfile("omitted nf")
            }
        }
        for assignments in [profile.nmosAssignments, profile.pmosAssignments] {
            var seen = providerKeys
            for assignment in assignments {
                let parameter = try setter(assignment.name, scope: .model)
                guard assignment.scope == .model, assignment.value.type == parameter.type,
                      seen.insert(ProviderKey(parameter, scope: .model)).inserted else {
                    throw MOSBinPreparationError.invalidProfile("polarity setter")
                }
            }
        }
        if let name = profile.versionParameter {
            let parameter = try setter(name, scope: .model)
            guard parameter.type == .string, !providerKeys.contains(ProviderKey(parameter, scope: .model)) else {
                throw MOSBinPreparationError.invalidProfile("version setter")
            }
            for assignment in profile.nmosAssignments + profile.pmosAssignments {
                let polarityParameter = try setter(assignment.name, scope: .model)
                guard polarityParameter.index != parameter.index else {
                    throw MOSBinPreparationError.invalidProfile("version/polarity alias")
                }
            }
        }
        return bound
    }

    func validate(_ value: Double, rule: ExternalMOSParameterRule) throws {
        guard value.isFinite, !rule.nonnegative || value >= 0,
              rule.requiredValue == nil || value == rule.requiredValue else {
            throw MOSBinPreparationError.invalidParameter(rule.sourceNames[0])
        }
        switch rule.meaning {
        case .length, .width, .multiplicity:
            guard value > 0 else { throw MOSBinPreparationError.invalidGeometry(rule.sourceNames[0]) }
        case .fingerCount:
            guard value >= 1, value.rounded(.towardZero) == value else { throw MOSBinPreparationError.invalidGeometry("nf") }
        default: break
        }
    }

    func scaled(_ value: Double, by scale: Double, kind: MOSParameterScale, name: String) throws -> Double {
        do { return try kind.apply(to: value, scale: scale) }
        catch { throw MOSBinPreparationError.invalidGeometry(name) }
    }

    func numericAssignment(value: Double, rule: BoundRule, scope: OSDIParameterScope) throws -> OSDIParameterAssignment? {
        guard let parameter = rule.parameter, let selectedName = rule.rule.providerName else { return nil }
        let typed: OSDIParameterValue
        switch parameter.type {
        case .real: typed = .real(value)
        case .integer:
            guard let integer = Int32(exactly: value) else {
                throw MOSBinPreparationError.invalidParameter(parameter.names[0])
            }
            typed = .integer(integer)
        case .string: throw MOSBinPreparationError.descriptorMismatch(parameter.names[0])
        }
        return try .init(name: selectedName, scope: scope, value: typed)
    }

    func fact(_ value: EvaluatedParameter, normalized: Double,
              assignment: OSDIParameterAssignment?) -> ExternalMOSParameterFact {
        .init(address: value.address, name: assignment?.name ?? value.rule.rule.sourceNames[0],
            role: value.rule.rule.scope, rawValue: value.raw, normalizedValue: normalized,
            providerValue: assignment?.value, isGiven: true)
    }

    func appendUnique(_ assignment: OSDIParameterAssignment,
                      to assignments: inout [OSDIParameterAssignment], step: () throws -> Void) throws {
        guard try !assignments.contains(where: { try step(); return $0.name == assignment.name }) else {
            throw MOSBinPreparationError.duplicateParameter(assignment.name)
        }
        assignments.append(assignment)
    }
}
