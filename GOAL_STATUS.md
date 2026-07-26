# CoreSpice Goal Status

Updated: 2026-07-26

| Goal | Status | Evidence |
|---|---|---|
| Independent Swift package | Complete | Existing multi-target CoreSpice package builds independently. |
| CircuiteFoundation dependency | Complete | `Package.swift` depends on `../CircuiteFoundation`; public APIs use shared types directly without re-exporting the module. |
| Foundation simulation request boundary | Complete | `CoreSpiceSimulationRequest`. |
| Foundation simulation result boundary | Complete | `CoreSpiceSimulationResult` implements artifact, diagnostic, and evidence protocols. |
| Foundation engine protocol | Complete | `CoreSpiceSimulating`. |
| Existing simulation domain retained | Complete | SPICE, device, optoelectronic, photonic, analysis, and I/O targets remain unchanged in ownership. |
| Structured artifact/provenance hand-off | Complete | The execution boundary retains invocation, sanitized environment fingerprint, input/output artifacts, diagnostics, and timestamps. |
| Reproducible CLI artifact contract | Verified | Batch and measurement JSON records use digest-backed `ArtifactReference` inputs and outputs, include replayable `ExecutionInvocation` data, identify CoreSpiceCLI as the output producer, and are covered by the aggregate package test. |
| Build after Foundation integration | Verified | The workspace package verifier completed the aggregate Xcode package build. |
| Regression tests after Foundation integration | Verified | The aggregate Xcode package test passed, including the 31-case numerical regression corpus. |
| Concrete asynchronous simulation engine | Complete | `CoreSpiceSimulator` directly conforms to the engine protocol, preserves cancellation, and emits Foundation provenance, artifacts, and diagnostics. |
| Isolated production process backend | Complete | `CoreSpiceExternalProcessBackend` verifies declared inputs, requires an explicit seed, executes the real CLI in an isolated run directory, checks exact consumed inputs, verifies outputs, preserves stdout/stderr evidence, and propagates cancellation. |
| Pole-zero execution | Complete | Differential voltage/current inputs and outputs use generalized eigenvalue analysis with typed malformed/non-finite failures. |
| DC and AC sensitivity | Complete | Dedicated DC and AC sensitivity engines use deterministic perturbations, including zero-nominal parameters, with strict parser/CLI contracts. |
| PEX-scale sparse topology | Verified quality gate | Canonical per-instance owned/referenced branch connectivity avoids global branch coupling; the 1,000-device fixture asserts 4,000 structural nonzeros. |
| Numerical false-success prevention | Complete | Newton iteration rejects non-finite solution/residual values and validates the physical KCL residual before reporting convergence. |
| Public analysis result validation | Complete | DC, AC, transient, noise, transfer-function, pole-zero, and sensitivity result constructors reject malformed dimensions and non-finite values with typed errors. |
| Optical/electrical execution boundary | Complete | Optical-network analyses pass evaluated optical state explicitly; intentional electrical-only device calls use a zero-power state sized to the device's declared optical nodes, without out-of-bounds fallback. |
| Stateful switch hysteresis | Complete | SW and both CSW bindings implement non-zero `VH`/`IH`; Newton candidates read committed state without mutation, and only accepted DC/transient states commit threshold crossings. |
| Independent numerical correlation | Verified | Regression-fixture and live-ngspice runs both pass 31/31; live evidence retains executable/input/output digests without rewriting the fixture. |
| Behavioral source execution | Complete | Parsed B voltage/current outputs lower to canonical runtime expressions, execute in DC/AC/transient analyses, support `V()`, `I()`, `time`, deterministic functions and non-recursive `.func`, and fail malformed or non-finite paths explicitly. |
| Foundry compact-model production claim | Blocked by contract | Native Level 1/2/3 execution cannot issue production qualification; a qualified external foundry-model simulator is required. |

## Explicitly blocked native capabilities

The supported-model envelope is complete for the capabilities marked complete
above. BSIM3/4, lossy LTRA, unsupported JFET parameters, and other unsupported
compact models remain typed failures. Their
production call paths and implementation completion
conditions are marked with `FIXME(INCOMPLETE_IMPLEMENTATION)` in the lowering
or binding boundary; they are not silently accepted and are not part of the
native supported-model completion claim.

## Execution boundary

`CoreSpiceSimulator` composes the existing analysis types behind
`CoreSpiceSimulating`. Numerical backends remain responsible for execution
orchestration, artifact materialization, and diagnostic creation; project/run
lifecycle and physical signoff responsibilities remain outside CoreSpice.

`CoreSpiceExternalProcessBackend` is a separate composition adapter. It owns
process lifecycle and artifact verification but does not own SPICE parsing,
analysis algorithms, project lifecycle, or release qualification.

## Switch-state isolation review

| Target | Storage | Isolation | Read entry point | Mutation entry point | Release |
|---|---|---|---|---|---|
| Native | `Mutex<Bool>` | `Synchronization.Mutex` | `position(for:threshold:hysteresis:)` | accepted DC or transient `commit` only | owner release |
| WASM | `Mutex<Bool>` | `Synchronization.Mutex` | same implementation | same implementation | owner release |
| Embedded WASM | `Mutex<Bool>` | `Synchronization.Mutex` | same implementation | same implementation | owner release |

The switch state has no target-conditional declaration, conformance, read, or
mutation path. Stamping never commits state, so a rejected Newton candidate or
transient retry cannot contaminate the next attempt. No I/O, callback, event
emission, or suspension occurs while the state lock is held.

The aggregate `CoreSpice-Package` Xcode test run passes on macOS arm64 with no
failures. `CoreSpiceDevices` also builds for the pinned Swift 6.4 WASM SDK, and
the switch-state source type-checks with the matching Embedded WASM SDK.
The complete Embedded target remains outside the current package envelope
because the pre-existing `CoreSpiceEvent` target imports Foundation.
