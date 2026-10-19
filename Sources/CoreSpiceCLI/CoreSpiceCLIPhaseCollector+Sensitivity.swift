import CoreSpice
import CoreSpiceIO
import CoreSpiceAnalysis

extension CoreSpiceCLIPhaseCollector {
    func sensitivity(_ output: SPICENativeSimulationOutput, prefix: String) throws {
        let evidence = try CoreSpiceCLISensitivityEvidence(output)
        let complex = evidence.analysis == "sens-ac"
        let physical = complex ? "ac" : "op"
        guard let baseline = output.phases.first(where: { $0.analysis == physical }),
              let derived = output.phases.first(where: { $0.analysis == (complex ? "sens-ac" : "sens") }) else {
            throw CoreSpiceCLICaseError.incompleteOutput("Actual sensitivity baseline or derived completion is missing")
        }
        let records = derived.sourceReexecutions
        guard records.count == evidence.children.count else { throw CoreSpiceCLICaseError.incompleteOutput("Sensitivity completed child count differs") }
        let compiled = output.prepared.input.lowered.compiled
        let artifactPrefix = prefix + "sensitivity:"
        let baselineID = artifactPrefix + "baseline:" + physical
        func samples(_ values: [CoreSpiceCLISensitivityEvidence.Sample], label: String, physical: Bool,
                     normalized: Bool = false) throws -> ([String: Double], [String: CoreSpiceCLIMetricSemantics]) {
            var observations: [String: Double] = [:], meanings: [String: CoreSpiceCLIMetricSemantics] = [:]
            for (index, value) in values.enumerated() {
                let components: [(String, Double)] = value.imaginaryBits.map {
                    [("real", value.real), ("imaginary", Double(bitPattern: $0))]
                } ?? [("high", value.real), ("low", Double(bitPattern: value.lowBits ?? 0))]
                for (component, scalar) in components {
                    let name = "sample:\(index):\(label):\(component)"
                    guard scalar.isFinite else { throw CoreSpiceCLICaseError.incompleteOutput("Nonfinite sensitivity observation") }
                    observations[name] = scalar; meanings[name] = .sensitivity(name: label, normalized: normalized, physical: physical)
                }
            }
            return (observations, meanings)
        }
        let (baselineObservations, baselineMeanings) = try samples(evidence.baseline, label: evidence.outputVariable, physical: true)
        try record(id: baselineID, facts: baseline, compiled: compiled, observations: baselineObservations, semantics: baselineMeanings)
        var derivatives: [String: Double] = [:], semantics: [String: CoreSpiceCLIMetricSemantics] = [:]
        var contributors: [String: [String]] = [:]
        for (index, child) in evidence.children.enumerated() {
            let actual = records[index]
            let childID = artifactPrefix + "child:\(index):" + actual.completedPhase.analysis
            let (observations, meanings) = try samples(child.observations, label: evidence.outputVariable, physical: true)
            try record(id: childID, facts: actual.completedPhase, compiled: compiled,
                observations: observations, semantics: meanings, modelOrigins: actual.selectedModelOrigins,
                diodeModelNames: actual.selectedDiodeModels)
            let label = child.instance + "." + child.parameter
            let (absolute, absoluteMeanings) = try samples(child.absolute, label: label + ":absolute", physical: false)
            for (key, value) in absolute {
                derivatives[key] = value; semantics[key] = absoluteMeanings[key]; contributors[key] = [baselineID, childID]
            }
            for (point, value) in child.normalized.enumerated() {
                guard let value else { continue }
                let (normalized, normalizedMeanings) = try samples([value], label: label + ":normalized:frequency-index:\(point)", physical: false, normalized: true)
                for (key, value) in normalized {
                    derivatives[key] = value; semantics[key] = normalizedMeanings[key]; contributors[key] = [baselineID, childID]
                }
            }
        }
        try record(id: artifactPrefix + "derived", facts: derived, compiled: compiled,
            observations: derivatives, semantics: semantics, contributors: contributors)
        try sensitivityArtifact(evidence, id: artifactPrefix + "derived", prefix: artifactPrefix,
            resources: output.prepared.input.resources)
    }
}
