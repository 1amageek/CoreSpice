import CoreSpiceMOSContracts
import CoreSpiceOSDIContracts

/// Explicit profile result, checked against its exact request before circuit publication.
public struct ExternalMOSPreparation: Sendable {
    public let source: ExternalMOSSourceRequest
    public let selectedDeclaration: MOSDeclarationID
    public let resolved: OSDIResolvedInstance
    public let facts: ExternalMOSPreparationFacts

    public init(source: ExternalMOSSourceRequest, selectedDeclaration: MOSDeclarationID,
                resolved: OSDIResolvedInstance, facts: ExternalMOSPreparationFacts) {
        self.source = source; self.selectedDeclaration = selectedDeclaration
        self.resolved = resolved; self.facts = facts
    }
}
