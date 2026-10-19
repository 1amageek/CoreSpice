import CoreSpiceIR

/// Complete checked inventory, available only inside the prepared owner's lexical borrow.
public struct NativeVoltageSourceInspectionView: ~Escapable {
    public let preparation: NativeCircuitPreparationRecord
    public let origin: NativeVoltageSourceInspectionOrigin
    /// Every slot is nonnil; the optional representation supports checked axis construction.
    public let variables: Span<MNAVariable?>
    public let sources: Span<NativeVoltageSourceFact>

    @_lifetime(copy variables, copy sources)
    internal init(preparation: NativeCircuitPreparationRecord, origin: NativeVoltageSourceInspectionOrigin,
        variables: Span<MNAVariable?>, sources: Span<NativeVoltageSourceFact>) {
        self.preparation = preparation; self.origin = origin
        self.variables = variables; self.sources = sources
    }
}
