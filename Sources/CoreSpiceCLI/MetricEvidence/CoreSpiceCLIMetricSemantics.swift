import CircuiteFoundation
import CoreSpiceWaveform

/// Meaning of a retained observation; no comparison or qualification is performed here.
struct CoreSpiceCLIMetricSemantics: Codable, Sendable, Hashable {
    let unitID: String
    let declaredUnit: String
    let extractionID: String
    let quantity: String
    let unitMeaning: String
    let sourceCompletionArtifact: ArtifactReference?
    let derivationArtifact: ArtifactReference?

    init(unitID: String, declaredUnit: String, extractionID: String, quantity: String,
         unitMeaning: String, derivationArtifact: ArtifactReference? = nil, sourceCompletionArtifact: ArtifactReference? = nil) {
        self.unitID = unitID; self.declaredUnit = declaredUnit; self.extractionID = extractionID
        self.quantity = quantity; self.unitMeaning = unitMeaning; self.derivationArtifact = derivationArtifact; self.sourceCompletionArtifact = sourceCompletionArtifact
    }
    func binding(_ artifact: ArtifactReference) -> Self {
        .init(unitID: unitID, declaredUnit: declaredUnit, extractionID: extractionID,
              quantity: quantity, unitMeaning: unitMeaning, derivationArtifact: artifact, sourceCompletionArtifact: sourceCompletionArtifact)
    }
    func bindingSource(_ artifact: ArtifactReference) -> Self {
        .init(unitID: unitID, declaredUnit: declaredUnit, extractionID: extractionID, quantity: quantity,
              unitMeaning: unitMeaning, derivationArtifact: derivationArtifact, sourceCompletionArtifact: artifact)
    }
    static func sensitivity(name: String, normalized: Bool = false, physical: Bool = false) -> Self {
        .init(unitID: normalized ? "CoreSpice.sensitivity.dimensionless" : physical
            ? "CoreSpice.sensitivity.selected-output.volt" : "CoreSpice.sensitivity.source-scalar-coordinate",
            declaredUnit: normalized ? "" : physical ? "V" : "V/source-scalar-unit",
            extractionID: "CoreSpice.source-sensitivity.selected-observations.v1",
            quantity: name, unitMeaning: normalized ? "dimensionless-normalized-derivative" : physical
                ? "actual-selected-physical-output" : "raw-source-scalar-coordinate-physical-parameter-unit-unavailable")
    }

    static func waveform(_ variable: VariableDescriptor, complexPart: String? = nil) -> Self {
        let unit = variable.unit.rawValue
        let unavailable = variable.type == .noiseDensity && variable.unit != .voltSquaredPerHertz && variable.unit != .ampereSquaredPerHertz
        return .init(unitID: unavailable ? "CoreSpice.unit.unspecified.noise-density"
            : "CoreSpice.waveform-declared-unit." + (unit.isEmpty ? "dimensionless" : unit),
            declaredUnit: unit,
            extractionID: "CoreSpice.final-phase-sample." + (complexPart ?? "real") + ".v1",
            quantity: variable.name, unitMeaning: unavailable ? "physical-unit-unavailable" : "declared-waveform-header-unit")
    }
    static func poleZero(name: String, gain: Bool = false) -> Self {
        .init(unitID: gain ? "CoreSpice.pole-zero.unit.dimensionless" : "CoreSpice.pole-zero.unit.radian-per-second",
            declaredUnit: gain ? "" : "rad/s", extractionID: "CoreSpice.pole-zero.indexed-value.v1",
            quantity: name, unitMeaning: "declared-typed-pole-zero-result-unit")
    }
    static func measurement(name: String, unit: String) -> Self {
        .init(unitID: "CoreSpice.measurement-declared-unit." + (unit.isEmpty ? "unspecified" : unit),
              declaredUnit: unit, extractionID: "CoreSpice.source-measurement.v1", quantity: name,
              unitMeaning: "declared-measurement-result-unit")
    }
}
