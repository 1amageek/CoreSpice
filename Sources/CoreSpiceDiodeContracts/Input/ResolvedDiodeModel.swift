/// Immutable shared coefficient owner. Source selection and checked construction belong to Lowering.
public final class ResolvedDiodeModel: Sendable {
    /// Conservative header plus aligned stored payload; the model owner defines its accounting extent.
    package static var ownedByteCount: UInt64 {
        UInt64(2 * MemoryLayout<Int>.stride
            + MemoryLayout<(DiodeDeclarationIdentity, DiodeModelInput, Bool)>.stride)
    }
    public let declaration: DiodeDeclarationIdentity
    public let input: DiodeModelInput
    public let orderedAssignmentEvidence: Bool
    package init(declaration: DiodeDeclarationIdentity, input: DiodeModelInput,
                 orderedAssignmentEvidence: Bool) {
        self.declaration = declaration; self.input = input
        self.orderedAssignmentEvidence = orderedAssignmentEvidence
    }
    public func sameStorage(as other: ResolvedDiodeModel) -> Bool { self === other }
}
