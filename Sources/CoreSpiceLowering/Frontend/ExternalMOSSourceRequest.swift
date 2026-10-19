import CoreSpiceEvaluationContracts
import CoreSpiceMOSContracts
import CoreSpiceMOSResolution
import CoreSpiceParsedIR

/// Lowering-created source authority for one concrete original MOS occurrence.
public final class ExternalMOSSourceRequest: Sendable {
    public let original: ParsedComponent
    public let resolution: MOSResolutionRequest
    public let compiled: CompiledNetlist
    public var snapshot: MOSDeclarationSnapshot { compiled.snapshot }
    public let graph: MOSInvocationGraph
    public let candidateDeclarations: [MOSDeclarationID]
    public let candidateScope: MOSScopeID
    public let candidateInvocation: UInt64
    public let isFamily: Bool
    public let terminals: [String]
    public let environment: EvaluationEnvironment

    // Referenced AST/program buffers already belong to the retained compiled/graph owners.
    // Charge this class's inline payload separately; MemoryLayout<Self>.stride is only a reference.
    static var retainedInlineBytes: UInt64 {
        UInt64(MemoryLayout<ParsedComponent>.stride + MemoryLayout<MOSResolutionRequest>.stride
            + MemoryLayout<CompiledNetlist>.stride + MemoryLayout<MOSInvocationGraph>.stride
            + MemoryLayout<[MOSDeclarationID]>.stride + MemoryLayout<MOSScopeID>.stride
            + MemoryLayout<UInt64>.stride + MemoryLayout<Bool>.stride
            + MemoryLayout<[String]>.stride + MemoryLayout<EvaluationEnvironment>.stride)
    }

    init(original: ParsedComponent, resolution: MOSResolutionRequest, compiled: CompiledNetlist,
         graph: MOSInvocationGraph, candidateDeclarations: [MOSDeclarationID],
         candidateScope: MOSScopeID, candidateInvocation: UInt64, isFamily: Bool,
         terminals: [String], environment: EvaluationEnvironment) {
        self.original = original; self.resolution = resolution; self.compiled = compiled
        self.graph = graph; self.candidateDeclarations = candidateDeclarations
        self.candidateScope = candidateScope; self.candidateInvocation = candidateInvocation
        self.isFamily = isFamily; self.terminals = terminals; self.environment = environment
    }

    /// Returns the original typed declaration, including its source span and assignment order.
    public func originalModel(for id: MOSDeclarationID, chargeWork: () throws -> Void) throws -> ParsedModel {
        guard candidateDeclarations.contains(id) else { throw ExternalMOSPreparationFailure.invalidCandidate }
        let declaration = try snapshot.declaration(id)
        for template in compiled.models {
            try chargeWork()
            if template.scope == declaration.scope, template.model.name == declaration.originalName,
               frontendModelSource(template.model) == declaration.source { return template.model }
        }
        throw ExternalMOSPreparationFailure.sourceMismatch
    }
}
