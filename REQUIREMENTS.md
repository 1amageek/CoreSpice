# CoreSpice Requirements

## Required capabilities

| ID | Requirement |
|---|---|
| CS-001 | Build as an independent Swift package with a local `CircuiteFoundation` dependency. |
| CS-002 | Expose `CoreSpiceSimulationEngine` as the Foundation engine boundary. |
| CS-003 | Keep simulation requests and results `Sendable`, `Hashable`, and `Codable` for Agent and CLI use. |
| CS-004 | Carry input and output files through digest-bearing `ArtifactReference` values. |
| CS-005 | Carry execution provenance and structured `DesignDiagnostic` values without discarding conversion failures. |
| CS-006 | Preserve existing SPICE analyses, device models, optoelectronic models, photonic execution, and waveform I/O. |
| CS-007 | Preserve cooperative cancellation and typed numerical/parser errors at the domain boundary. |
| CS-008 | Keep standard SPICE/RAW/CSV/PSF formats as the source of truth for simulation artifacts. |
| CS-009 | Keep CLI and library operations independently callable without requiring Xcircuite or a UI. |

## Quality and acceptance criteria

- `swift build` succeeds in the package checkout.
- Existing simulation and I/O tests remain green; the current baseline is 218
  passing tests under `swift test --parallel`.
- New engine implementations must be deterministic for the same input,
  configuration, and random seed, and must retain reproducibility metadata.
- Failure results must identify the analysis stage and preserve actionable
  typed diagnostics; a bare `Simulation failed` message is insufficient.
- Foundation artifacts must be created from materialized files and verified
  byte counts/digests; a path string alone is not evidence.

## Non-goals

- No project manifest, run ledger, approval workflow, or flow scheduler.
- No DRC/LVS/PEX/STA/EM-IR implementation.
- No claim that an in-process simulation is foundry-qualified.
- No replacement of domain-specific SPICE IR with a universal Foundation IR.

## Next-agent acceptance gate

An implementation agent is complete when a concrete engine can be invoked from
the library or CLI, returns a reproducible `CoreSpiceSimulationResult`, and
passes the build/test/diagnostic checks above without changing the ownership
boundary in `DESIGN.md`.
