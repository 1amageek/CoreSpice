# CoreSpice Goal Status

Updated: 2026-07-16

| Goal | Status | Evidence |
|---|---|---|
| Independent Swift package | Complete | Existing multi-target CoreSpice package builds independently. |
| CircuiteFoundation dependency | Complete | `Package.swift` depends on `../CircuiteFoundation`; umbrella re-exports it. |
| Foundation simulation request boundary | Complete | `CoreSpiceSimulationRequest`. |
| Foundation simulation result boundary | Complete | `CoreSpiceSimulationResult` implements artifact, diagnostic, and evidence protocols. |
| Foundation engine protocol | Complete | `CoreSpiceSimulating`. |
| Existing simulation domain retained | Complete | SPICE, device, optoelectronic, photonic, analysis, and I/O targets remain unchanged in ownership. |
| Structured artifact/provenance hand-off | Complete | The execution boundary retains invocation, sanitized environment fingerprint, input/output artifacts, diagnostics, and timestamps. |
| Reproducible CLI artifact contract | Implemented, verification pending | Batch and measurement JSON records use digest-backed `ArtifactReference` inputs and outputs, include replayable `ExecutionInvocation` data, and identify CoreSpiceCLI as the output producer. |
| Build after Foundation integration | Verified | The workspace package verifier completed the aggregate Xcode package build. |
| Regression tests after Foundation integration | Verified | The aggregate Xcode package test passed, including the 31-case numerical regression corpus. |
| Concrete asynchronous simulation engine | Complete | `CoreSpiceSimulator` directly conforms to the engine protocol, preserves cancellation, and emits Foundation provenance, artifacts, and diagnostics. |
| Independent numerical correlation | Verified | Regression-fixture and live-ngspice runs both pass 31/31; live evidence retains executable/input/output digests without rewriting the fixture. |
| Foundry compact-model production claim | Blocked by contract | Native Level 1/2/3 execution cannot issue production qualification; a qualified external foundry-model simulator is required. |

## Execution boundary

`CoreSpiceSimulator` composes the existing analysis types behind
`CoreSpiceSimulating`. Numerical backends remain responsible for execution
orchestration, artifact materialization, and diagnostic creation; project/run
lifecycle and physical signoff responsibilities remain outside CoreSpice.
