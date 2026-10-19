import CoreSpiceDiodeContracts
import CoreSpiceMOSContracts
import CoreSpiceMOSResolution
import CoreSpiceParsedIR

/// Immutable frontend source/program owner reusable across seeded evaluation runs.
public final class CompiledNetlist: Sendable {
    public let source: ParsedNetlist
    public let sourceOverrides: [NetlistSourceScalarOverride]
    public let temperatureSelection: NetlistSourceTemperature?
    /// Opt-in evaluated scalar evidence for source perturbation inventories.
    public let captureSourceScalars: Bool
    let scalarOverrides: [String: [FrontendScalarOverride]]
    public let snapshot: MOSDeclarationSnapshot
    public let retainedBytes: UInt64
    let hierarchicalMultiplier: MOSExpressionBinding?
    let identity: MOSIdentitySpace
    let scopes: [FrontendScopeTemplate]
    let models: [FrontendModelTemplate]
    let slots: [NetlistScalarAddress: NetlistScalarSlot]
    let modelOrigins: [ParsedModelOrigin?]
    let diodeIndex: [DiodeLookupKey: Range<Int>]
    let diodeCandidates: [Int]

    init(source: ParsedNetlist, snapshot: MOSDeclarationSnapshot, retainedBytes: UInt64,
         identity: MOSIdentitySpace, scopes: [FrontendScopeTemplate], models: [FrontendModelTemplate],
         slots: [NetlistScalarAddress: NetlistScalarSlot], modelOrigins: [ParsedModelOrigin?],
         hierarchicalMultiplier: MOSExpressionBinding?, diodeIndex: [DiodeLookupKey: Range<Int>], diodeCandidates: [Int],
         sourceOverrides: [NetlistSourceScalarOverride], scalarOverrides: [String: [FrontendScalarOverride]],
         temperatureSelection: NetlistSourceTemperature?, captureSourceScalars: Bool) {
        self.sourceOverrides = sourceOverrides; self.scalarOverrides = scalarOverrides
        self.temperatureSelection = temperatureSelection; self.captureSourceScalars = captureSourceScalars
        self.diodeIndex = diodeIndex; self.diodeCandidates = diodeCandidates
        self.source = source; self.snapshot = snapshot; self.retainedBytes = retainedBytes
        self.hierarchicalMultiplier = hierarchicalMultiplier
        self.identity = identity; self.scopes = scopes; self.models = models
        self.slots = slots; self.modelOrigins = modelOrigins
    }
    public func sameStorage(as other: CompiledNetlist) -> Bool { self === other }
    public func scalarSlot(at address: NetlistScalarAddress) throws -> NetlistScalarSlot {
        let normalized: NetlistScalarAddress = switch address {
        case .initialCondition(let node): .initialCondition(node: node.lowercased())
        case .nodeSet(let node): .nodeSet(node: node.lowercased())
        default: address
        }
        guard let slot = slots[normalized] else { throw MOSResolutionFailure.invalidRequest }
        return slot
    }
    /// Returns only the actual selected parsed origin; missing source identity remains absent.
    public func modelOrigin(for result: ResolvedMOSInstance) throws -> ParsedModelOrigin? {
        guard snapshot.identitySpace.sameStorage(as: result.identitySpace) else {
            throw MOSResolutionFailure.conditionMismatch
        }
        let declaration = try snapshot.declaration(result.declaration)
        guard declaration.source == result.source, Int(result.declaration.rawValue) < modelOrigins.count else {
            throw MOSResolutionFailure.conditionMismatch
        }
        return modelOrigins[Int(result.declaration.rawValue)]
    }
    /// Checked selected diode declaration; indices are frontend model coordinates, not MOS IDs.
    public func modelOrigin(for result: ResolvedDiodeInstance) throws -> ParsedModelOrigin? {
        try checkedDiodeModel(result).origin
    }
    public func modelName(for result: ResolvedDiodeInstance) throws -> String {
        try checkedDiodeModel(result).name
    }
    private func checkedDiodeModel(_ result: ResolvedDiodeInstance) throws -> ParsedModel {
        guard let index = Int(exactly: result.model.declaration.declaration), models.indices.contains(index) else {
            throw MOSResolutionFailure.conditionMismatch
        }
        let template = models[index], identity = result.model.declaration
        let source = frontendModelSource(template.model)
        guard template.model.type == .diode, template.scope.rawValue == identity.scope,
              source.captureID == identity.captureID, source.occurrenceID == identity.occurrence,
              source.line == identity.line, source.statementOrdinal == identity.statementOrdinal else {
            throw MOSResolutionFailure.conditionMismatch
        }
        return template.model
    }
    func model(named name: String, scope: MOSScopeID) -> FrontendModelTemplate? {
        var current: MOSScopeID? = scope
        while let id = current {
            let body = scopes[Int(id.rawValue)]
            for index in body.modelIndices.reversed() where models[index].model.name.lowercased() == name.lowercased() {
                return models[index]
            }
            current = body.parent
        }
        return nil
    }
    func function(named name: String, scope: MOSScopeID) -> (ParsedFunctionDefinition, MOSScopeID)? {
        var current: MOSScopeID? = scope
        while let id = current {
            let body = scopes[Int(id.rawValue)]
            if let function = body.functions[name.lowercased()] { return (function, id) }
            current = body.parent
        }
        return nil
    }
}
