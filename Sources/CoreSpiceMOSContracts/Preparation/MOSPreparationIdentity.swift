/// Complete process-local semantic identity; accounting capacities are not preparation inputs.
public struct MOSPreparationIdentity: Sendable, Hashable {
    public let resolved: ResolvedMOSInstance
    public let conditions: MOSPreparationConditions
    public let implementationIdentity: String

    public init(resolved: ResolvedMOSInstance, conditions: MOSPreparationConditions,
                implementationIdentity: String) throws(MOSPreparationFailure) {
        guard !implementationIdentity.isEmpty else { throw .invalidImplementationIdentity }
        self.resolved = resolved; self.conditions = conditions; self.implementationIdentity = implementationIdentity
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        let a = lhs.resolved, b = rhs.resolved
        return lhs.conditions == rhs.conditions && lhs.implementationIdentity == rhs.implementationIdentity &&
            a.identitySpace == b.identitySpace && a.source == b.source && a.instanceSource == b.instanceSource &&
            a.selectedName == b.selectedName && a.symbolNames == b.symbolNames && a.scope == b.scope &&
            a.scopeInstantiation == b.scopeInstantiation && a.instance == b.instance && a.declaration == b.declaration &&
            a.polarity == b.polarity && a.release == b.release && a.releaseOrigin == b.releaseOrigin &&
            a.schema == b.schema && a.modelCoefficients == b.modelCoefficients && a.instanceParameters == b.instanceParameters &&
            a.rawGeometry == b.rawGeometry && a.normalizedGeometry == b.normalizedGeometry &&
            a.selectionGeometry == b.selectionGeometry && a.profile == b.profile && a.geometryScale == b.geometryScale &&
            a.rules == b.rules && a.candidates == b.candidates
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(conditions); hasher.combine(implementationIdentity)
        hasher.combine(resolved.identitySpace); hasher.combine(resolved.source); hasher.combine(resolved.instanceSource)
        hasher.combine(resolved.selectedName); hasher.combine(resolved.symbolNames); hasher.combine(resolved.scope)
        hasher.combine(resolved.scopeInstantiation); hasher.combine(resolved.instance); hasher.combine(resolved.declaration)
        hasher.combine(resolved.polarity); hasher.combine(resolved.release); hasher.combine(resolved.releaseOrigin)
        hasher.combine(resolved.schema); hasher.combine(resolved.modelCoefficients); hasher.combine(resolved.instanceParameters)
        hasher.combine(resolved.rawGeometry); hasher.combine(resolved.normalizedGeometry); hasher.combine(resolved.selectionGeometry)
        hasher.combine(resolved.profile); hasher.combine(resolved.geometryScale); hasher.combine(resolved.rules)
        hasher.combine(resolved.candidates)
    }
}
