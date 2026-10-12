import CoreSpiceDiodeContracts
import CoreSpiceMOSContracts
import CoreSpiceParsedIR

/// Typed refusal with bounded coordinates into the retained immutable source owner.
public struct DiodeResolutionFailure: Error, Sendable {
    public enum Cause: Error, Sendable, Equatable {
        case profileRequired
        case undefinedModel
        case duplicateModel
        case wrongModelType
        case missingOccurrenceEvidence
        case inconsistentProjection
        case nonScalarAssignment
        case duplicateSelector
        case implicitMultiplicity
        case invalidPorts
        case schema(DiodeSchemaFailure)
        case evaluation(MOSResolutionFailure)
    }
    public let cause: Cause
    public let compiled: CompiledNetlist
    public let instance: String?
    public let scope: UInt32?
    public let invocation: UInt64?
    public let declarationRange: Range<Int>?
    public let assignmentIndex: Int?
    public let modelAssignment: Bool
    public let componentIndex: Int?
    public let isTruncated: Bool
    public func candidate(at offset: Int) -> ParsedModel? {
        guard let range = declarationRange, offset >= 0, offset < range.count else { return nil }
        return compiled.models[compiled.diodeCandidates[range.lowerBound + offset]].model
    }
    public var assignment: ParsedParameterAssignment? {
        guard let index = assignmentIndex else { return nil }
        if modelAssignment, let model = candidate(at: 0) {
            guard model.parameterAssignments.indices.contains(index) else { return nil }
            return model.parameterAssignments[index]
        }
        if let scope, let componentIndex,
           compiled.scopes.indices.contains(Int(scope)),
           compiled.scopes[Int(scope)].components.indices.contains(componentIndex) {
            let assignments = compiled.scopes[Int(scope)].components[componentIndex].component.parameterAssignments
            if assignments.indices.contains(index) { return assignments[index] }
        }
        return nil
    }
}
