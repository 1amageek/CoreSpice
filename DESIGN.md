# CoreSpice Design Contract

## Purpose and Scope

This directory is both the package and system root for CoreSpice. The parent is
the [LSI system design](../DESIGN.md). Device implementation contracts are owned
by the [CoreSpiceDevices module](Sources/CoreSpiceDevices/DESIGN.md).

## Responsibilities and Boundaries

CoreSpice is the independently usable simulation domain package. It owns
SPICE parsing and lowering, circuit IR, device models, numerical analyses,
optoelectronic co-simulation, photonic GPU execution, waveform conversion, and
SPICE-compatible I/O.

It does not own project state, flow ordering, tool trust, human approval, or
physical signoff semantics.

```mermaid
flowchart TD
    Request["CoreSpiceSimulationRequest\nFoundation artifact inputs"] --> Engine["CoreSpiceSimulating"]
    Engine --> Domain["SPICE parser / IR / analyses / devices"]
    Domain --> Result["CoreSpiceSimulationResult"]
    Result --> Artifacts["ArtifactReference[]"]
    Result --> Evidence["EvidenceManifest"]
    Result --> Diagnostics["DesignDiagnostic[]"]
    Evidence --> Consumer["Agent / human / flow coordinator"]
    Diagnostics --> Consumer
```

## CircuiteFoundation integration

The package depends on `CircuiteFoundation` and uses its types directly from
the `CoreSpice` target. Clients import `CircuiteFoundation` explicitly when
they use the shared boundary, which is intentionally small:

- `CoreSpiceSimulationRequest` carries digest-bearing input
  `ArtifactReference` values and optional configuration, revision, and random
  seed digests.
- `CoreSpiceSimulationResult` carries output artifacts, typed diagnostics, and
  an `EvidenceManifest` built from caller-supplied `ExecutionProvenance`.
- `CoreSpiceSimulating` refines `CircuiteFoundation.Engine` for an
  asynchronous simulation entry point.

The existing analysis types and synchronous setup APIs remain domain-owned.
They are composed through the injected executor, but their numerical
algorithms must not move into Foundation and must not silently invent artifact
digests or provenance.

## Ownership boundary

| Concern | Owner |
|---|---|
| Artifact, provenance, evidence, and diagnostic vocabulary | CircuiteFoundation |
| SPICE syntax, netlist lowering, circuit IR | CoreSpice |
| Device physics and numerical solvers | CoreSpice |
| Waveform serialization and SPICE-compatible formats | CoreSpice |
| Process timeout and external tool cleanup | SignoffToolSupport |
| Tool qualification and trust gates | ToolQualification / DesignFlowKernel |
| Project/run persistence and human approval | Xcircuite / DesignFlowKernel |
| DRC, LVS, PEX, STA, EM/IR, and physical signoff rules | Domain signoff engines |

## Related Designs

| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [LSI](../DESIGN.md) | parent | Simulation domain ownership | Platform composition | Numerical evidence is not signoff approval |
| [CoreSpiceParsedIR](Sources/CoreSpiceParsedIR/DESIGN.md) | child | Ordered parsed numeric vectors | SPICE source identity | Scalar consumers reject vectors |
| [CoreSpiceIO](Sources/CoreSpiceIO/DESIGN.md) | child | Explicit transient caller policy | Typed and CLI intent | Missing limits fail before execution |
| [CoreSpiceIR](Sources/CoreSpiceIR/DESIGN.md) | child | Canonical model and node ownership | Lossless circuit values | Revalidate direct consumers |
| [CoreSpiceParserSPICE](Sources/CoreSpiceParserSPICE/DESIGN.md) | child | Exact SPICE syntax | Version and IC preservation | Revalidate direct consumers |
| [CoreSpiceLowering](Sources/CoreSpiceLowering/DESIGN.md) | child | Cold model admission | Model/instance resolution | Revalidate direct consumers |
| [CoreSpiceCompile](Sources/CoreSpiceCompile/DESIGN.md) | child | Auxiliary sparse topology | CPU solver structure | Revalidate direct consumers |
| [CoreSpiceAnalysis](Sources/CoreSpiceAnalysis/DESIGN.md) | child | Fallible stamps and session lifetime | Numerical execution | Revalidate direct consumers |
| [CoreSpiceDevices](Sources/CoreSpiceDevices/DESIGN.md) | child | Bound-device stamping | Native electrical models | Revalidate affected analyses when device derivatives change |
| [CoreSpiceCompactModels](Sources/CoreSpiceCompactModels/DESIGN.md) | child | Safe compact-model evaluation | Independent native BSIM3 kernel | Production selection is separately verified by Devices BSIM3 |
| [CoreSpiceBSIM3](Sources/CoreSpiceBSIM3/DESIGN.md) | child | Private physics ABI | Official Berkeley model equations | The safe evaluator owns exclusive lifetime |

## Architecture

The request-to-domain-to-evidence diagram above describes package composition.
Native devices depend on IR and event types; analyses consume their stamps.

## Contracts and Invariants

Native L3 MOS DC, AC, and transient analyses use the same device current and its
linearization. A non-finite numerical result is a failure, never completed
simulation evidence. L3 binding rejects unsupported parameter domains.

## Verification and Change Impact

Device numerical changes require local current/Jacobian tests and actual affected
analysis execution. See the device module for its owned behavioral evidence.
The Metal backend qualification below applies only to GPU execution changes.

## Deliberate non-goals

- `CoreSpice` does not become a project or run ledger.
- `CoreSpice` does not qualify an external simulator, PDK, or foundry deck.
- Foundation does not contain SPICE-specific requests, waveform types, or
  device models.
- A simulation result is evidence for review; it is not a signoff approval.

## Concrete engine boundary

`CoreSpiceSimulator` is the concrete domain engine and directly conforms to
`CoreSpiceSimulating`. It delegates numerical execution to an injected
`CoreSpiceSimulationBackend`
implementation, checks cooperative cancellation, records the request inputs
and execution-supplied invocation/environment fields in `ExecutionProvenance`, and exposes verified
artifact references and structured diagnostics from the execution.

The injected backend remains responsible for parsing, analysis selection,
artifact materialization, artifact verification, and typed domain errors.
CLI and I/O surfaces expose only the current contract; obsolete compatibility
paths are removed during development.

## CLI artifact boundary

JSON-mode CLI operations expose domain records rather than a generic result
envelope. `CoreSpiceCLIBatchRunRecord` contains the materialized deck under
`inputArtifacts` and every emitted waveform or coverage report under
`outputArtifacts`. `CoreSpiceCLIMeasurementRunRecord` references the exact CSV
that was measured. All references use `CircuiteFoundation.ArtifactReference`;
output references identify CoreSpiceCLI as their producer, and every reference
is created only after the file exists so its digest and byte count describe the
materialized bytes. Both records include `ExecutionInvocation`, preserving the
executable, arguments, and working directory needed to replay the operation.

## Metal execution verification

[MetalBackendExecutionTests](Tests/CoreSpiceBackendTests/MetalBackendExecutionTests.swift)
requires an actual Metal device, compiles the production photonic library, dispatches
the production even-layer kernel and checks its swapped complex amplitudes plus
untouched state. Device absence fails qualification rather than skipping it. Run
this owner through `xcodebuild test-without-building` after `build-for-testing`,
with the exact `CoreSpiceBackendTests/MetalBackendExecutionTests/dispatchesProductionEvenLayer()`
selector and a bounded process. CPU-only, compile and kernel-load checks do not
prove GPU execution. Test-owned shared buffers remain alive until the awaited
dispatch completes and are returned to the backend pool on all exit paths.

## BSIM4 Kernel Composition

[BSIM4 standalone kernel](Sources/CoreSpiceBSIM4/DESIGN.md) owns exact Berkeley 4.8.3 host CPU evaluation. This lower
contract is composed by [BSIM4 Devices](Sources/CoreSpiceDevices/BSIM4/DESIGN.md)
under explicit caller preparation policy. Correlated-noise composition remains
incomplete. [CLI](Sources/CoreSpiceCLI/DESIGN.md) owns execution provenance.
