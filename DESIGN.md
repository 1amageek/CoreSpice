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

The package uses the exact Swift 6.4.0 release toolchain and macOS 27 or later.
Native preparation transfers noncopyable device owners through the standard
library's `UniqueArray`; this availability requirement propagates to direct
and transitive host consumers. Pure MOS targets are independently verified
with the matching ordinary and Embedded WebAssembly SDKs.

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

## Proposed BSIM4 4.5 Implementation Units

Status: B45-1 portable schema, B45-2 isolated C preparation and B45-3 static
I/Q/Jacobians are implemented.
The public native execution provider still refuses 4.5 numerical preparation. The [research record](docs/bsim45-research/RESEARCH.md)
owns original-source and Sky130 observations. Child designs own their
respective implemented/proposed contracts; this package owns composition, ordering and completion.
The solver's numerical algorithms remain unchanged.

```mermaid
flowchart TD
    Source["Pinned original 4.5.0 + Sky130 inventory"] --> Schema["B45-1 portable schema"]
    Source --> Owner["B45-2 C preparation owner"]
    Owner --> Static["B45-3 full I/Q/Jacobians"]
    Static --> Dynamic["B45-4 AC and transient history"]
    Static --> Noise["B45-5 original noise"]
    Schema --> Binding["B45-6 safe Swift and consuming binding"]
    Dynamic --> Binding
    Noise --> Binding
    Binding --> Adoption["B45-7 original PDK and consumer adoption"]
```

| Unit / responsibility | Dependencies | Independent completion evidence |
|---|---|---|
| B45-1: [Schema](Sources/CoreSpiceMOSContracts/Schema/DESIGN.md) | Frozen research | Pure original ID/kind/unit/alias/version tests; unsupported extension refusal; one-evaluation resolver; fixed Native/WASM/Embedded runtime |
| B45-2: [Native owner](Sources/CoreSpiceBSIM45/DESIGN.md) and [source adaptation](Sources/CoreSpiceBSIM45/Kernel/DESIGN.md) | Frozen research | Standalone C setup/defaults/temp/topology; exact owner-size accounting; allocation/fatal-check/diagnostic/work failure; ASan/UBSan cleanup |
| B45-3: original current, charge and analytic derivatives | B45-2 | Separate unadapted-source references, n/p reverse/body bias, every enabled selector, full-node finite differences/conservation and SC correction |
| B45-4: AC and BE/TR state machine | B45-3 | Actual frequency-dependent NQS matrix, all 29 states, accepted/rejected trials, stale/double/cross-owner commit refusal, history preserved by DC/AC |
| B45-5: release-specific noise | B45-3 | Thirteen original sources plus total, gain-pair/partition, mode 0/1, temperature/frequency, noise-only topology and unchanged accepted history |
| B45-6: [Safe owner](Sources/CoreSpiceCompactModels/BSIM45/DESIGN.md) and [production](Sources/CoreSpiceDevices/BSIM45/DESIGN.md) | B45-1, B45-4, B45-5 | Real C-backed Swift evaluator plus public parse->resolve->prepare->compile->consume->bind->Analysis; identity/capability/budget/cancel/cleanup and lock-order proof |
| B45-7: original PDK and direct/transitive adoption | B45-6 | Source/corner/wrapper-specific DC/AC/transient/noise runs, 4.62 refusal, release performance/resource counters, actual CLI/API/PDK/Host/Studio consumers and dependency pins |

Independence means each unit's contract can be falsified without completing the
whole platform, not removing its real prerequisites. B45-1 and B45-2 can progress
on separate responsibilities after source freeze. B45-4 and B45-5 have independent
proof inputs but share native context/adapter state; serialize those implementation
changes under the same owner. Package manifest and higher-level composition changes
have one owner. During implementation, each sprint updates the workspace progress,
reviews its complete change, verifies only findings after fixes, runs bounded
focused checks, and creates a coherent local commit before dependent adoption.

Completion is a matrix, not a single supported flag: exact-source kernel behavior,
public numerical execution, original-PDK wrapper execution, and physical process
accuracy are distinct evidence. A selected/inspected declaration is not a run.
BSIM4.62 and unsupported composed wrapper elements remain explicit refusals and
cannot inflate 4.5 numerical coverage. Full 4.5 kernel qualification includes modes
absent from Sky130 cards; Sky130 qualification includes wrappers outside that kernel.

For Native CPU integration references, record units and an absolute-plus-relative
comparison before generating fixtures: DC current uses the child kernel threshold;
AC complex admittance uses `1e-12 S + 2e-6 relative` per active matrix entry; reference
waveform voltage uses `1e-6 V + 2e-4 relative` on the same requested sample grid with
recorded integration tolerances. These are proposed numerical acceptance thresholds,
not measured 4.5 results or physical accuracy. Step-size/convergence studies must
explain a failure before any tolerance change; do not tune thresholds just to pass.

Release measurements separate cold parsing/snapshot/preparation/binding/analysis
from snapshot reuse, with identical input/seed/conditions, sample counts and audit
settings. Report wall time, allocation/copy counters, retained/temporary peaks,
expression work, candidate visits and cold setup count. Enforce zero downstream
model search, binding re-evaluation, candidate-range intermediate copies and
duplicate same-condition cold setup. Compare 4.8.3 only for infrastructure cost;
different-release numerical results are not an equivalence oracle. No runtime
speedup is claimed until measured on the complete changed path.

R01-R20 remain owned by Parser/Lowering/MOSResolution and the release schema;
B45-1 revalidates their changed release/scale assumptions. R21-R30 are owned by
MOSPreparation, the new native/safe/bound owners and existing NativeExecution;
B45-2 through B45-6 provide concrete failure/resource/lifetime counterexamples.
R31-R35 are owned by independent target tests and B45-7 integration evidence;
every adopted row records source/release/schema/conditions and actual completed
analysis, never declaration counts as executed coverage. The package's existing
requirement-to-test evidence remains valid where its premises are unchanged.

## Related Designs

| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [LSI](../DESIGN.md) | parent | Simulation domain ownership | Platform composition | Numerical evidence is not signoff approval |
| [CoreSpiceParsedIR](Sources/CoreSpiceParsedIR/DESIGN.md) | child | Ordered parsed numeric vectors | SPICE source identity | Scalar consumers reject vectors |
| [CoreSpiceIO](Sources/CoreSpiceIO/DESIGN.md) | child | Explicit transient caller policy | Typed and CLI intent | Missing limits fail before execution |
| [CoreSpice module](Sources/CoreSpice/DESIGN.md) | child | Artifact backend and native prepared execution | Domain dispatch composition | Prepared native execution has bounded CPU/runtime evidence; physical qualification remains separate |
| [CoreSpiceIR](Sources/CoreSpiceIR/DESIGN.md) | child | Canonical model and node ownership | Lossless circuit values | Revalidate direct consumers |
| [CoreSpiceParserSPICE](Sources/CoreSpiceParserSPICE/DESIGN.md) | child | Exact SPICE syntax and quoted-value role preservation | Parser-owned syntax contract | Revalidate direct consumers and serialization |
| [CoreSpiceParser](Sources/CoreSpiceParser/DESIGN.md) | child | Source-document and resolver contracts | Atomic selected path/content identity | Revalidate include/library and memory adapters |
| [CoreSpiceCLICore](Sources/CoreSpiceCLI/DESIGN.md) | child | Completed phase evidence and explicit case output | Direct developer execution | Baseline binding does not prove sweep or Monte Carlo execution |
| [CoreSpiceMOSContracts](Sources/CoreSpiceMOSContracts/DESIGN.md) | child | Explicit MOS input profiles, exact release/schema and staged values | Portable semantic dependency floor | Selection is distinct from preparation and physical qualification |
| [CoreSpiceMOSResolution](Sources/CoreSpiceMOSResolution/DESIGN.md) | child | Immutable declaration snapshot and checked one-evaluation resolution | Independent scoped MOS interpretation | No numerical device/kernel dependency |
| [CoreSpiceBSIM4](Sources/CoreSpiceBSIM4/DESIGN.md) | child | Exact existing 4.8.3 opaque kernel | Current native release | Release-specific physics and qualification |
| [CoreSpiceBSIM45](Sources/CoreSpiceBSIM45/DESIGN.md) | child | Exact 4.5.0 opaque preparation/static kernel and bounded outputs | Independent native C implementation | Public Devices adoption and dynamic analysis remain future units |
| [CoreSpiceLowering](Sources/CoreSpiceLowering/DESIGN.md) | child | Parsed declaration/program projection and circuit lowering | Source-preserving adapter to MOS resolution | Device preparation belongs to execution composition |
| [CoreSpiceCompile](Sources/CoreSpiceCompile/DESIGN.md) | child | Auxiliary sparse topology | CPU solver structure | Revalidate direct consumers |
| [CoreSpiceWaveform](Sources/CoreSpiceWaveform/DESIGN.md) | child | Opaque result-storage retention and waveform views | Export value lifetime | Numerical conversion and IO projection retain the admitted owner |
| [CoreSpiceAnalysis](Sources/CoreSpiceAnalysis/DESIGN.md) | child | Fallible stamps and session lifetime | Numerical execution | Revalidate direct consumers |
| [CoreSpiceDevices](Sources/CoreSpiceDevices/DESIGN.md) | child | Bound-device stamping | Native electrical models | Revalidate affected analyses when device derivatives change |
| [CoreSpiceCompactModels](Sources/CoreSpiceCompactModels/DESIGN.md) | child | Safe compact-model evaluation | Independent native BSIM3 kernel | Production selection is separately verified by Devices BSIM3 |
| [CoreSpiceBSIM3](Sources/CoreSpiceBSIM3/DESIGN.md) | child | Private physics ABI | Official Berkeley model equations | The safe evaluator owns exclusive lifetime |

## Architecture

The request-to-domain-to-evidence diagram above describes package composition.
Native devices depend on IR and event types; analyses consume their stamps.

## Contracts and Invariants

PDK declaration intake, semantic model/geometry admission, numerical execution
and physical qualification are distinct boundaries. The target PDK contracts are
owned by [IO](Sources/CoreSpiceIO/DESIGN.md),
[Lowering](Sources/CoreSpiceLowering/DESIGN.md),
[native resistors](Sources/CoreSpiceDevices/Devices/DESIGN.md#resistor-execution-contract)
and [exact BSIM4 release admission](Sources/CoreSpiceCompactModels/BSIM4/DESIGN.md#exact-release-admission).
These contracts record current gaps; they do not assert completed Sky130 support.
The [CLI](Sources/CoreSpiceCLI/DESIGN.md) owns receipts generated from actual
selected/bound models. Trust and application criteria remain with
[ToolQualification](../ToolQualification/DESIGN.md) and their domain/application
authorities. Loaded declarations cannot supply executed-model coverage.

Native L3 MOS DC, AC, and transient analyses use the same device current and its
linearization. A non-finite numerical result is a failure, never completed
simulation evidence. L3 binding rejects unsupported parameter domains.

## MOS Boundary Migration

The approved migration fixes one semantic authority: source declarations become an
immutable snapshot; checked resolution determines an exact declaration, release,
schema and normalized supplied values. Devices prepares that result once for
explicit execution conditions. Preparation supplies auxiliary topology before the
existing compiler, and the prepared owner is consumed by binding. Resolution is
reusable; an executable owner belongs to one run. The solver algorithm is unchanged.

```mermaid
flowchart LR
    Parser --> Snapshot[MOSResolution snapshot]
    Snapshot --> Resolve[Checked resolution]
    Resolve --> Result[ResolvedMOSInstance]
    Result --> Inspection
    Result --> Prepare[Devices preparation]
    Prepare --> Topology
    Topology --> Compiler
    Prepare --> Bind[Consuming binding]
    Compiler --> Bind
    Bind --> Analysis
    Analysis --> Receipts[Completed execution evidence]
```

The [MOS requirement/evidence index](docs/mos-boundary-requirements.md) links
R01–R35 to their owners, tests and scoped cumulative verification. Workspace
PROGRESS.md, B8.6.5.18, owns task completion, including the final commit.
The semantic contracts and their local counterexamples are owned by MOSContracts
and MOSResolution. Parser owns source retention, Lowering owns the
adapter, Devices owns preparation and executable lifetime, and the native/CLI
composition owns complete run ordering. Each owner design records its local
requirement mapping. BSIM4.5 inspection must succeed independently of executable
support; numerical preparation must reject that exact unsupported release.
No loaded or selected declaration is counted as executed model coverage.

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
under explicit caller preparation policy and noise-dependent topology intent. [CLI](Sources/CoreSpiceCLI/DESIGN.md) owns execution provenance.

### Exact caller-owned SPICE source intake

[IO](Sources/CoreSpiceIO/DESIGN.md#caller-owned-exact-source-intake) composes
full `ArtifactReference` bindings and immutable checked bytes with the ordinary
SPICE grammar. [ParsedIR](Sources/CoreSpiceParsedIR/DESIGN.md#exact-source-dependency-values)
owns portable dependency/work evidence; [ParserSPICE](Sources/CoreSpiceParserSPICE/DESIGN.md#exact-profile-dependency-and-work-contract)
owns active grammar events and cooperative parsing; [Parser](Sources/CoreSpiceParser/DESIGN.md#cooperative-library-projection)
owns location-preserving projection. No target depends on PDKKit. Native exact
intake and ordinary parser/IO behavioral tests establish only source admission,
not numerical support, foundry qualification or cross-platform execution.


### Designed bounded profile source boundary

Status: designed, not implemented. Existing exact loader proves post-resolution
expected-graph comparison and finite work counts; it does not prove pre-await
contextual authorization or retained/temporary byte capacity. The next lower
contract composes [ParsedIR owned storage/occurrences](Sources/CoreSpiceParsedIR/DESIGN.md#bounded-source-storage-and-occurrence-values),
[Parser contextual source/environment](Sources/CoreSpiceParser/DESIGN.md#bounded-contextual-source-contract),
[ParserSPICE bounded grammar](Sources/CoreSpiceParserSPICE/DESIGN.md#bounded-profile-grammar)
and [IO Span intake/proof sprints](Sources/CoreSpiceIO/DESIGN.md#bounded-profile-source-intake).
It supports exact-approved and candidate-discovery providers using the same actual
grammar, without requiring a whole expected graph. The optional PDK adapter owns
PDK approval/availability; CoreSpice owns actual parser context and storage.
This adds no PDK dependency, numerical qualification, new allocator or implicit
filesystem fallback. Source design/proof does not change model physics or Engine.

### MOS input-admission finding closure

The [frontend contract](Sources/CoreSpiceLowering/Frontend/DESIGN.md#mos-source-admission-repairs)
and [declaration intake](Sources/CoreSpiceMOSResolution/Declarations/DESIGN.md#non-scalar-model-input-admission)
own non-scalar coefficient refusal and global width-selection transport. Public
source callers use those shared contracts; Devices and solver algorithms do not
interpret source options or repair omitted invalid coefficients.

### MOS boundary regression and performance closure

The parser rejects malformed model fields before declaration publication; native
preparation separates its IR/MOS reservation from exact-topology compile admission.
Their owning contracts are [parser](Sources/CoreSpiceParserSPICE/DESIGN.md#mos-declaration-intake)
and [native execution](Sources/CoreSpice/NativeExecution/DESIGN.md#incremental-result-capacity-ownership).
The reproducible [MOS boundary benchmark](Benchmarks/MOSBoundary/DESIGN.md) owns
calibrated allocation/copy API measurements and their scope; it creates no new
physical-model or portable numerical qualification.

B45-1/B45-2 evidence covers portable interpretation and Native CPU C
preparation. B45-3 implements independently verified static I/Q and analytic
Jacobians with explicit derivative correction identities. The C target is not
yet composed into Devices. B45-4 Native C AC/transient and B45-5 noise are implemented; B45-6/B45-7 remain unfinished;
public 4.5 numerical refusal and existing 4.8.3 execution remain intentional.

B45-4 AC/frequency NQS is implemented/qualified separately from its transient
history unit. Its ABI, exclusive ownership and verification authority are
[CoreSpiceBSIM45](Sources/CoreSpiceBSIM45/DESIGN.md#b45-4-ac-and-frequency-nqs-contract).
Native Devices remains unsupported for 4.5 until B45-6 composition; C capability
does not imply public simulation capability.

B45-4 transient BE/TR/NQS qualification uses the Native C history contract in
[CoreSpiceBSIM45](Sources/CoreSpiceBSIM45/DESIGN.md#b45-4-transient-contract).
The 29-state owner and augmented deficit equation do not change Analysis methods;
public 4.5 preparation refusal remains until B45-6 adoption.

B45-5 Native C spectra and interval integration are independently qualified under
[the noise contract](Sources/CoreSpiceBSIM45/DESIGN.md#b45-5-noise-contract).
The C target owns bounded source evaluation; the future execution composition
owns sweep storage, frequency policy, input referral and cumulative sums.
No existing Analysis integration policy or public numerical capability changes.
