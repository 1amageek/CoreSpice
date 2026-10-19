import CoreSpiceDiodeContracts

/// Cached source scalars and their immutable checked model share one lexical owner.
struct DiodeModelMemoEntry {
    let model: ResolvedDiodeModel
    let assignments: [DiodeScalarAssignment]
}
