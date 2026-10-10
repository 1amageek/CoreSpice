/// Native composition attaches an opaque capacity owner to a complete result header.
/// Numerical payload fields remain immutable; Analysis does not know the resource implementation.
package protocol AnalysisResultStorageRetaining: Sendable {
    func retainingStorage(_ owner: any Sendable) -> Self
}
