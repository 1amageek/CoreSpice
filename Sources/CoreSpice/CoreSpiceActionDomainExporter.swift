public struct CoreSpiceActionDomainExporter: Sendable {
    public init() {}

    public func snapshot() -> CoreSpiceActionDomainSnapshot {
        CoreSpiceActionDomainSnapshot(
            domainID: "simulation-analysis",
            ownerPackages: ["CoreSpice"],
            operations: [
                loadNetlistOperation(),
                runOperatingPointOperation(),
                runTransientOperation(),
                runACOperation(),
                runDCSweepOperation(),
                runMonteCarloOperation(),
                exportWaveformOperation(),
                exportCoverageOperation(),
                setNetlistParametersOperation(),
                metricImprovementObjectiveOperation(),
                convergenceRecoveryObjectiveOperation(),
            ]
        )
    }

    private func loadNetlistOperation() -> CoreSpiceActionDomainOperation {
        CoreSpiceActionDomainOperation(
            operationID: "simulation.load-netlist",
            maturity: "implemented",
            inputRefs: ["spice-netlist-ref", "optional-model-library-ref"],
            preconditions: ["spice-netlist-readable", "parser-capability-known"],
            effects: ["circuit-ir-produced", "analysis-options-resolved"],
            producedArtifacts: ["coverage-report"],
            verificationGates: ["schema-validation", "parser-diagnostics"],
            reversible: true
        )
    }

    private func runOperatingPointOperation() -> CoreSpiceActionDomainOperation {
        CoreSpiceActionDomainOperation(
            operationID: "simulation.run-op",
            maturity: "implemented",
            inputRefs: ["spice-netlist-ref", "analysis-options"],
            preconditions: ["netlist-loaded", "dc-operating-point-supported"],
            effects: ["operating-point-waveform-produced", "measurements-produced"],
            producedArtifacts: ["waveform-raw", "waveform-csv", "waveform-psf", "measurement-report"],
            verificationGates: ["simulation-completed", "measurement-gate", "artifact-integrity"],
            reversible: true
        )
    }

    private func runTransientOperation() -> CoreSpiceActionDomainOperation {
        CoreSpiceActionDomainOperation(
            operationID: "simulation.run-tran",
            maturity: "implemented",
            inputRefs: ["spice-netlist-ref", "transient-analysis-spec", "analysis-options"],
            preconditions: ["netlist-loaded", "positive-time-step", "positive-stop-time"],
            effects: ["transient-waveform-produced", "measurements-produced"],
            producedArtifacts: ["waveform-raw", "waveform-csv", "waveform-psf", "measurement-report"],
            verificationGates: ["simulation-completed", "measurement-gate", "artifact-integrity"],
            reversible: true
        )
    }

    private func runACOperation() -> CoreSpiceActionDomainOperation {
        CoreSpiceActionDomainOperation(
            operationID: "simulation.run-ac",
            maturity: "implemented",
            inputRefs: ["spice-netlist-ref", "ac-analysis-spec", "analysis-options"],
            preconditions: ["netlist-loaded", "frequency-sweep-valid"],
            effects: ["ac-waveform-produced", "measurements-produced"],
            producedArtifacts: ["waveform-raw", "waveform-csv", "waveform-psf", "measurement-report"],
            verificationGates: ["simulation-completed", "measurement-gate", "artifact-integrity"],
            reversible: true
        )
    }

    private func runDCSweepOperation() -> CoreSpiceActionDomainOperation {
        CoreSpiceActionDomainOperation(
            operationID: "simulation.run-dc",
            maturity: "implemented",
            inputRefs: ["spice-netlist-ref", "dc-sweep-spec", "analysis-options"],
            preconditions: ["netlist-loaded", "sweep-source-resolvable", "nonzero-sweep-step"],
            effects: ["dc-sweep-waveform-produced", "measurements-produced"],
            producedArtifacts: ["waveform-raw", "waveform-csv", "waveform-psf", "measurement-report"],
            verificationGates: ["simulation-completed", "measurement-gate", "artifact-integrity"],
            reversible: true
        )
    }

    private func runMonteCarloOperation() -> CoreSpiceActionDomainOperation {
        CoreSpiceActionDomainOperation(
            operationID: "simulation.run-monte-carlo",
            maturity: "implemented",
            inputRefs: ["spice-netlist-ref", "monte-carlo-spec", "analysis-options"],
            preconditions: ["netlist-loaded", "monte-carlo-spec-valid", "random-seed-recorded"],
            effects: ["parametric-waveform-produced", "statistics-produced"],
            producedArtifacts: ["waveform-csv", "measurement-report"],
            verificationGates: ["simulation-completed", "statistical-summary-gate", "artifact-integrity"],
            reversible: true
        )
    }

    private func exportWaveformOperation() -> CoreSpiceActionDomainOperation {
        CoreSpiceActionDomainOperation(
            operationID: "simulation.export-waveform",
            maturity: "implemented",
            inputRefs: ["waveform-ref", "export-format"],
            preconditions: ["waveform-available", "export-format-supported"],
            effects: ["waveform-artifact-written"],
            producedArtifacts: ["waveform-raw", "waveform-csv", "waveform-psf"],
            verificationGates: ["artifact-integrity"],
            reversible: true
        )
    }

    private func exportCoverageOperation() -> CoreSpiceActionDomainOperation {
        CoreSpiceActionDomainOperation(
            operationID: "simulation.export-deck-coverage",
            maturity: "implemented",
            inputRefs: ["spice-netlist-ref"],
            preconditions: ["spice-netlist-readable"],
            effects: ["coverage-report-written"],
            producedArtifacts: ["coverage-report"],
            verificationGates: ["schema-validation"],
            reversible: true
        )
    }

    private func setNetlistParametersOperation() -> CoreSpiceActionDomainOperation {
        CoreSpiceActionDomainOperation(
            operationID: "simulation.set-netlist-parameters",
            maturity: "implemented",
            inputRefs: ["spice-netlist-ref", "parameter-candidate-ref"],
            preconditions: ["spice-netlist-readable", "parameter-candidate-bounded", "target-parameters-resolvable"],
            effects: ["edited-spice-netlist-produced", "parameter-edit-report-produced"],
            producedArtifacts: ["spice-netlist", "parameter-edit-report"],
            verificationGates: ["parser-diagnostics", "simulation-metric-gate", "artifact-integrity"],
            reversible: true
        )
    }

    private func metricImprovementObjectiveOperation() -> CoreSpiceActionDomainOperation {
        CoreSpiceActionDomainOperation(
            operationID: "simulation.metric-improvement-objective",
            maturity: "planned",
            inputRefs: ["measurement-report", "specification-ref", "bounded-parameter-space"],
            preconditions: ["metric-gap-detected", "editable-parameter-space-known"],
            effects: ["planning-objective-created", "parameter-search-bounded"],
            producedArtifacts: ["planning-problem"],
            verificationGates: ["schema-validation", "simulation-metric-gate"],
            reversible: true
        )
    }

    private func convergenceRecoveryObjectiveOperation() -> CoreSpiceActionDomainOperation {
        CoreSpiceActionDomainOperation(
            operationID: "simulation.convergence-recovery-objective",
            maturity: "planned",
            inputRefs: ["simulation-diagnostic", "spice-netlist-ref", "analysis-options"],
            preconditions: ["nonconvergence-diagnostic-structured", "safe-retry-policy-known"],
            effects: ["planning-objective-created", "retry-options-bounded"],
            producedArtifacts: ["planning-problem"],
            verificationGates: ["schema-validation", "simulation-completed"],
            reversible: true
        )
    }
}
