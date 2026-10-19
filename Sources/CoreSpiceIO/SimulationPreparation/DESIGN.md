# Simulation Preparation

## Purpose and Scope

Status: implemented Native CPU capability; see supported domain below. Parent: [CoreSpiceIO](../DESIGN.md). No children.
Own domain intake that turns actual immutable SPICE sources into a retained parsed
and lowered input with effective analysis intent. No PDKKit dependency is added.

## Responsibilities and Boundaries

Reuse the shared owned grammar, source/environment owners and node-voltage resolver.
Resolve source options, analysis selection, runtime conditions and input identity
once. Numerical compilation/binding/execution belongs to CoreSpice NativeExecution;
project availability, expected PDK selection, ledger and DB storage remain external.
This is an intake component, not a second parser or a general flow executor.

## Related Designs

| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [IO](../DESIGN.md) | parent | Caller-owned exact/bounded source intake | Domain composition | Ordinary exact loader has count/work limits, not owned grammar capacity proof |
| [ParserSPICE](../../CoreSpiceParserSPICE/DESIGN.md) | depends on | SPICEProfileSourceParsing.parseProfile | Actual AST/context/edges | Includes enabled and owned documents required |
| [InitialConditions](../InitialConditions/DESIGN.md) | depends on | SPICENodeVoltageResolving.resolveBounded | Actual circuit node binding | Unicode remains typed unsupported; expressions share the frontend session |
| [Lowering](../../CoreSpiceLowering/DESIGN.md) | depends on | CompiledNetlist, resourceEnvelope and LoweredCircuit | Same AST and one scalar session | Reserve explicit frontend capacities before compile/begin |
| [CLI](../../CoreSpiceCLI/DESIGN.md) | used by | Typed capacity and wrapped refusal causes | Finite exact-source developer intake | Refusal is not numerical evidence |
| [Native execution](../../CoreSpice/NativeExecution/DESIGN.md) | used by | PreparedSPICESimulation | Compile/bind/run exact intent | No source reread or reparse |
| [Host](../../../../Xcircuite/Sources/Xcircuite/ProfileExecution/DESIGN.md) | used by | Full prepared graph and actual settings | PDK composition | Domain values carry no PDK admission authority |

## Architecture

```text
owned root + exact contextual resolver + initial environment + explicit policy
    -> parseProfile -> owned AST + all actual source occurrences
    -> bounded effective options/analysis resolution -> lower the same AST
    -> resolve IC/nodeset against that CircuitIR -> PreparedSPICESimulation
```

## Contracts and Invariants

`SPICEDeckLoader.loadFile(..., resources:)` is the resource-aware local-file
adapter for caller-profile batch intake. Before each content read it checks local
file size, charges source work and initial hashing, and reserves simultaneous
read/array scratch. It then creates an invocation-accounted checked source,
uses the existing contextual `parseProfile` grammar for active includes/library
sections, and retains the owned AST and source owners in LoadedSPICEDeck. File
size drift is refused. An accounted source registry bounds capture metadata and
shares repeated full-source owners while allocating distinct occurrence IDs.
Coverage materialization receives its own checked retained/work envelope before
generation. Default legacy loading keeps its existing contract and entry point.
The CLI retains the loaded owner as long as its compiled batch source is retained;
low work/hash/storage refusal precedes content read and releases all pending leases.

Host composition uses the shared compiled frontend and node-voltage contracts;
ordinary host analysis selection remains separate from checked prepared selection. The [owned grammar entry](../../CoreSpiceParserSPICE/SPICEProfileSourceParsing.swift)
owns captured parsing and the [resolver](../InitialConditions/SPICENodeVoltageResolving.swift)
owns actual node binding. Host execution evidence belongs to the consuming host.

SP-01: A preparation request supplies an invocation-accounted SPICECheckedSource
root, explicit initial SPICEPreprocessingEnvironment, exact source catalog/provider,
ParserConfiguration, mandatory MOSInputProfile/UInt64 seed/MOSResolutionLimits and
finite caller preparation/execution policies. The catalog
uses existing SPICEExactSourceBinding full references plus explicit normalized
routes/search order; it grants no undeclared path search. The injected
SPICEExactSourceProviding provider returns the checked owner for a selected binding.
Require full binding equality and invocation-accounted ownership before creating
the grammar document with SPICECheckedSource.document. Core owns the contextual
resolver bridge and records those same owners beside actual grammar occurrences.
A SPICESourceDocument captureID alone has no digest/descriptor authority and is
insufficient intake. Keep document/reference bound to one captured owner; no second
read, unresolved include or ordinary parse fallback. Reuse existing route-resolution
semantics rather than adding another include grammar. Active edges are observed
by grammar and checked against the PDK projection afterward, not fabricated from
the source catalog. Unused catalog entries are availability, not consumed inputs.

SP-02: Preserve the owned parse result and actual ordered source graph, including
circuit root, external library entry, sections, inherited parameters, repeated
occurrences and source statement coordinates. Compute source input identity from
those observations using a versioned domain-separated bounded encoding. Keep it
separate from configuration identity and availability evidence.

SP-03: Resolve effective configuration once before execution. An explicit optional
analysis selection identifies one parsed analysis; absence uses the current first
supported-directive rule, recorded with its index. No directive means typed failure.
The prepared lane selects `.op`, `.dc`, `.tran`, `.ac`, `.noise`, `.tf`, `.sens`,
`.pz` and `.four`; a source `.mc` selection executes its resolved inner directive
through the run family contract below.

The initial request has source-authoritative numeric analysis/options/IC/nodeset
settings. Caller controls explicit analysis index, supply bindings, operating-policy
expectations and finite numerical/resource policies; it cannot supply unrecorded
temperature, convergence or node-assignment overrides. Changing source settings
requires a new captured input and preparation. This fixes settings precedence
without introducing a second options language.

`SPICEEffectiveSimulationConfiguration` is immutable. It records analysis/index,
actual options and convergence/model-registry choices, TEMP, circuit/model nominal
temperatures with their distinct origins, step/start/stop/max-step/UIC, resolved
IC/nodeset, explicit supply bindings, stimulus/sweep definitions, seed, supported
operating policy and numerical limit policy. The domain computes a canonical digest
from every effective setting that can change results, admitted scope, truncation or
completion. Unknown settings fail or retain explicit unsupported meaning; no caller
digest can override computed identity. Paths, run IDs, timestamps, source budget
ceilings and scheduling observations stay outside semantic configuration identity.
Defaulted effective values carry an algorithm/default-rule version; they are not
presented as observations from source text. Transient encoding additionally binds
`transient.checked-be-bootstrap.v1.preferred-method.v1.voltage-lte-d3.v1.minimum-step-admission.v1.newton-minimum-retry.v1` to the
[Analysis startup and local-error contract](../../CoreSpiceAnalysis/DESIGN.md#checked-variable-step-lte-and-startup).
This separates the former first-step-only method semantics from the preferred
steady method, checked bootstrap, and minimum-bounded accepted proposals and
optional breakpoint approaches, and a Newton retry that tries the minimum
before declaring a shrunken proposal too small. Changes to these numerical rules require a
new transient marker; OP/DC encoding and the outer identity domain remain unchanged. Ordered bindings/model precedence are
not sorted away; nonfinite values and framing overflow fail.

SP-04: IC and nodeset are resolved against the actual lowered circuit using the
existing bounded resolver. Retain SPICEOwnedNodeVoltages; a required dictionary for
TransientConfig is a separately admitted materialization. UIC, initial voltages
and guesses are passed to numerical analysis, not merely hashed or reported. Apply
the same preparation to every future transient-derived analysis. Expressions use canonical compiled slots in the same exclusive session; no
ExpressionEvaluator or retry fallback is available.

SP-05: Runtime temperature comes from effective domain options. Supply bindings are
explicit domain source IDs and ordered positive/negative node IDs; validate a
voltage-source target and its orientation against actual CircuitIR. An absent
binding means supply unobserved, not nominal PDK voltage. A DC sweep of that target
records a supply schedule; other voltage/current sweeps record stimulus schedules.
Report prescribed source values separately from solved node voltages. Arbitrary
node measurements do not redefine nominal supply.

`SPICEOperatingConditionPolicy` has two cases: `recordActual` records actual
conditions without nominal-match assurance; `requireExactReference` carries finite
reference temperature, positive supply voltage and nonempty explicit supply bindings.
The latter requires actual effective temperature and every prescribed supply point
to equal the reference before execution. An unbound supply, nonconstant transient
supply or unavailable bounded schedule proof is typed unsupported/missing coverage,
not a passed comparison. Neither policy asserts a process operating range or
qualification; no guessed operating envelope is introduced. Host policy choice is
explicit and enters configuration identity. It cannot be inferred from corner names.

Implemented checked interface:

```swift
public protocol SPICESimulationPreparing: Sendable {
    func prepare(
        _ request: SPICESimulationPreparationRequest,
        resources: any SPICESourceResourceAccounting
    ) async throws(SPICESimulationPreparationError) -> PreparedSPICESimulation
}
```

`PreparedSPICESimulation: Sendable` has an internal checked constructor, is not
Codable, and retains SPICEOwnedParseResult, exact graph/captures, LoweredCircuit,
effective configuration and owned IC/nodeset. Its circuit is computed from lowered.circuit;
its exact compiled input/snapshot/invocation graph/final evaluation provenance remain
retained through that owner. Inspection borrows immutable values
while retaining this owner. A deserialized request/claim or externally constructed
CircuitIR cannot create it. Protocol implementations obtain it through the concrete
checked preparation algorithm, not a public unchecked constructor.

Capacity refusal belongs to this component. `SPICESimulationCapacityError`
records the exact catalog/route, parsed-transform, lowered-instance/node element
boundary or transform-byte ceiling, its configured limit and required count.
These errors travel through `.resource`, rather than `invalidPolicy` or
`unsupportedCapability`; neither counts nor limits change. Arithmetic overflow
remains a storage failure. No partial prepared owner is published. Actual caller
configuration errors remain `invalidPolicy`.

## Runtime Flows

Actual capture -> owned grammar -> frontend resource admission -> compile ->
beginEvaluation(profile/limits/seed) -> same-session options/TEMP -> lower(scale) ->
same-session analysis/IC/nodeset -> schedule/policy validation -> consuming finish ->
compute identities -> final cancellation check -> prepared owner. Any failure publishes no prepared input. PDK comparison happens
after native compilation/binding preparation and before numerical execution.

## State, Ownership, and Lifecycle

Preparation is invocation-local. Immutable owners and receipts survive to the final
prepared/output copy. The source registry may use its existing actor for ordered
I/O/occurrence admission. Stage accounting is injected, synchronized and distinct
from the original closed profile admission accountant. No I/O/callback/await runs
inside a Mutex critical section. New actual parsed/lowered/configuration capacity
is admitted before construction; shared backing retains its existing owner.

## Failure, Concurrency, and Constraints

`SPICESimulationPreparationError` preserves typed MOS resolution failures, their exact
optional injected source-resource cause, and source/parser/resource/option/lowering/
node causes and distinguishes missing/unsupported analysis, invalid supply binding,
condition mismatch, missing condition coverage and unsupported bounded transform.
Bounded grammar proof is not proof of options evaluation, lowering, registry
construction, hashing or dictionary capacity. Each new transform must use explicit
work/capacity admission and cooperative cancellation, or refuse before that transform.
Caller policies own permitted ranges and quota selection; no new magic defaults.
Source preparation and numerical execution policies have separate owners/metrics.
Native CPU proof does not establish Metal/WASM/Embedded semantics.

## Verification and Change Impact

`CoreSpiceNativeExecutionTests` preparation fixtures target depends only on IO and its
domain dependencies, without PDK/Xcircuite. Prove real include/section/context
selection, missing include refusal, stable relocation, input/config digest drift,
source-backed/defaulted TEMP distinction, TNOM separation, input versus supply DC
sweep, both operating policies, IC/nodeset node errors and retained-last-copy quota
behavior. Existing grammar/resolver proof is reused. NativeExecution owns waveform
application; host owns expected profile matching, full lineage and resume.
Implementation updates IO dependencies/excludes and migrates actual CLI/native host
intake together; do not label the legacy exact loader as the bounded implementation.

## Implemented Native CPU Capability

The checked implementation is [SPICESimulationPreparer](SPICESimulationPreparer.swift).
`SPICESourceCatalogRoute` is availability only and has no fabricated coordinates;
actual edges/context remain `SPICEOwnedParseResult.netlist.dependencyEvents`.
`SPICECheckedSource` full binding and invocation admission are both checked before
an accounted document is created. Root occurrence is zero; every actual child
acquisition receives a distinct occurrence. Repeated content retains one checked
source owner and multiple grammar occurrences. Catalog entries that are not read
remain availability and are excluded from actual input identity.

The shared frontend owns hierarchical/scalar/MOS transformation work, depth and
storage. Superseded flat-device/literal-only gates are removed; native analysis dispatch and explicit supply contracts use the checked effective configuration. Inspectable resolved MOS
input is retained even when later numerical preparation refuses an exact release.
No second model/parameter evaluator or cold numerical preparation runs in IO.

| New storage/work | Admission owner | Lifetime / refusal |
|---|---|---|
| Catalog resolver references | Preparation reserves bounded catalog slots | Invocation scratch |
| Frontend compile and run | NetlistLowering.resourceEnvelope(limits:): checked retained 2B, temporary B, simultaneous 3B where B is maximumRetainedBytes | Reserve before compile; retained receipt follows prepared copies; scratch stays charged through identity emission and ends at preparation return/failure |
| IO configuration/sweep/node dictionaries | Source byte/name and maximumElements capacity envelope; actual emitted counts checked before materialization | Retained with prepared copy; no frontend storage charged as an IO allocation |
| Frontend work/cancellation | MOSResolutionControlling bridge forwards source-accountant checks/charges outside its short Mutex | Typed resolution category plus exact first injected resource cause |
| Semantic encoding | Immutable framing count preflight, then exact encoded-capacity reservation before byte construction; hash budget before hash | Maximum transform bytes is a ceiling, not eager capacity; live IO/frontend scratch remains charged |
| Native numerical preparation/execution | [NativeExecution](../../CoreSpice/NativeExecution/DESIGN.md) | Separate prepare/execute admission |

The resource bridge stores only the first injected cause under Mutex; external
accounting callbacks execute outside the critical section. Source cancellation
remains identifiable separately from expression, scope or resolution-limit failure.
Borrowed static-consumer validation failures poison the session before return.
Preparation owns its session locally: any later failure destroys that exclusive run
and publishes no session that can finish or draw again. Failure publishes no prepared owner
and releases both frontend and IO capacity reservations.

Input identity remains CoreSpice.prepared-input.v1 and frames full content and
descriptor identity, ordered captures, initial environment, actual parent/child
indices and occurrence IDs, source coordinates, section and preprocessing identity.
Availability paths, source keys and scheduling observations stay outside identity.
Configuration uses CoreSpice.effective-settings.v2.defaults-v1 and frames actual
profile, seed and evaluation algorithm identity alongside effective convergence,
temperature, geometry, analysis, UIC/IC/nodeset, supply/policy and numerical limits.
Resolution ceilings are retained as execution policy/provenance, without claiming
that a ceiling is a physical value.

| Assignment / policy | Supported behavior |
|---|---|
| IC + transient UIC | Materialized admitted voltages passed to TransientConfig, actual initial waveform retained |
| IC + op/DC/transient without UIC | Typed refusal; no ignored assignment |
| Nodeset + op/DC/transient without UIC | Actual DC starting guess |
| Nodeset + UIC | Typed refusal because UIC skips DC |
| Supply | Exact source ID and ordered actual node IDs validated; prescribed DC values remain distinct from solved voltages |
| Nonconstant bound supply | Missing bounded schedule coverage, typed refusal |
| recordActual | Records actual conditions; no reference assurance |
| requireExactReference | Requires finite reference and nonempty binding coverage, and compares every prescribed point and runtime temperature before dispatch |

Public interfaces and immutable owner constructors are implemented; ownership is
not Codable. Source files are neither reread nor replaced after preparation.
[Native tests](../../../Tests/CoreSpiceNativeExecutionTests/PreparedNativeExecutionTests.swift)
exercise actual numerical behavior; the CLI fixture exercises the same domain owner.

Effective per-instance conditions are retained in configuration, including resistor
instance TEMP/DTEMP and selected-model TNOM precedence. Source model TNOM overrides
circuit nominal temperature for that binding; it does not change runtime TEMP.
`requireExactReference` compares every admitted instance runtime temperature as well
as global TEMP and every prescribed supply point. The default-rule version and
source/default origin enter configuration identity. This prevents a source instance
override from silently passing a global-only temperature comparison.

`PreparedSPICESimulation.sourceOccurrences` retains the complete checked binding
beside each actual document occurrence and the owned entering environment. Child
entries are created from the grammar's contextual request, with actual parent ID,
physical statement coordinate, kind and selected section. The circuit root has no
invented library section. This exposes inherited parameter values without inferring
an empty dictionary from the older count-only dependency-event compatibility field.

Verified preparation and actual execution evidence is owned by the
[NativeExecution evidence](../../CoreSpice/NativeExecution/DESIGN.md#verified-evidence).
The dedicated test registry and matching event census are part of completion,
including retained-last-copy release and failed-admission cleanup.

[SPICESimulationFrontendTests](../../../Tests/CoreSpiceIOTests/SPICESimulationFrontendTests.swift)
owns hierarchical resolved-MOS/source retention, same-session settings/IC/analysis,
profile-sensitive configuration identity and final-copy frontend receipt lifetime.
[SPICEFrontendControlTests](../../../Tests/CoreSpiceIOTests/SPICEFrontendControlTests.swift)
owns preservation of exact injected charge/cancellation causes on actual compile.

| State | Native / WASM / Embedded storage | Isolation and access | Release |
|---|---|---|---|
| First source-accounting cause | Mutex<(any Error)?> on every target | firstFailure read / retain mutation under withLock | Last bridge owner |
| Resource callbacks | Injected Sendable owner on every target | checkCancellation / charge outside the bridge mutex | Caller-owned accounting lifetime |

There are no target-conditional synchronization or Sendable branches in this bridge.
Native verification does not establish WASM/Embedded runtime synchronization evidence.

Semantic input/settings identity uses two framing passes over already resolved,
immutable values. The count-only pass performs checked length arithmetic and the
same cancellation/work admission without allocating an encoding byte buffer. The
emission pass reserves the exact framed byte count before reserving its buffer;
every append is bounded by that admitted capacity and the final count must match
the preflight. It never replays expression evaluation or RNG. The reservation lives
through hashing and is released on success or failure. IO configuration and
frontend scratch remain admitted while their buffers are live; identity encoding
cannot free those reservations merely to fit its own capacity. The transform
ceiling remains unchanged. The existing package initializer remains the bounded
full-capacity path for callers that explicitly request that capacity.

`SPICESimulationFrontendTests` covers a first preparation with 8192 admitted IO
elements, a 64 MiB transform ceiling and a shared 64 MiB temporary budget; exact
encoding hash failure with other scratch still live; and unchanged framing at the
exact required capacity versus refusal one byte below it.

## Designed Condition and Diode Intake Migration

Status: proposed; current beginEvaluation still evaluates roots before options.
IO owns source/caller/default selection into the
[Environment contract](../../CoreSpiceEvaluationContracts/Environment/DESIGN.md),
then freezes the shared frontend session before ordinary scalar/device resolution.
The new diode profile is explicit alongside the existing MOS profile. IO retains
source-backed diode/environment diagnostics through public failures and CLI encoding.
Do not return only an interned symbol ID or produce execution evidence from resolution.
Native preparation remains external to this component.

## D2 Condition Policy Adoption

Public IO, CLI and profile preparer choose a typed NetlistTemperaturePolicy before
beginEvaluation. Frozen source/caller/default precedence is resolved once.
SPICEAnalysisOptions consumes the frozen conditions/provenance and skips all source
temp/tnom replay. operatingConditions uses canonical Kelvin words and rejects
subsequent conflicting Celsius edits. Effective settings identity includes the
frozen environment, condition origins and evaluator V2. Numerical preparation
receives the same conditions. Condition-source evaluation changes invalidate the
old effective-settings digest, not the captured original source identity.

Condition bootstrap failures retain MOSConditionEvaluationFailure diagnostics and
the frontend resource cause in a dedicated condition error case. They are not
misclassified as unrelated resource failures. Native preparation compares canonical
Kelvin conditions rather than reconstructing them from the Celsius projection.

### D3 Resolution Transport

The request has a separate optional diode profile. It is forwarded unchanged to
Lowering; nil refuses encountered diodes. Typed diode diagnostics retain the
frontend resource cause through the public preparation error. Source preparation
is not native numerical admission; resolved IR is refused by compile/binding
until D4. See [resolution owner](../../CoreSpiceLowering/DiodeResolution/DESIGN.md).

D3 source-backed failures retain the frontend reservation together with their
compiled diagnostic owner. Releasing the session must not release accounting while
the thrown diagnostic still retains the parsed/compiled values. Reservation copies
share one exactly-once release owner. Native preparation rejects resolved diodes
before allocating or preparing unrelated MOS owners.

07C effective-settings.v4.diode-profile includes the explicit diode interpretation
profile (or its absence) in bounded semantic identity, independently from source
availability. Native configuration adds prepared execution identity and policy.

## Newton Numerical Rule Identity

All prepared non-OSDI configurations use effective-settings.v8.source-reexecution
(OSDI uses effective-settings.v9.osdi-source-reexecution)
and bind `newton.accurate-residual.factor-reuse-refinement.v1`. This identifies the
[Analysis-owned refinement rule](../../CoreSpiceAnalysis/DESIGN.md#bounded-linear-refinement)
under unchanged caller tolerances. Source identity and public artifact fields are
unchanged. Exact previous preparation digests are rejected by the OP/DC/transient
identity regression; repeat preparation remains deterministic.

## Explicit OSDI Input Transport

`SPICESimulationPreparationRequest.osdiInstances` supplies exact flattened names
to typed portable resolved instances. The same source session forwards this map
to Lowering; no source coefficient kind inference or second evaluator is added.
Preparation retains the selected effective analysis, including bounded source DC
sweeps and transient intent, without evaluating a foreign model. Its frozen Kelvin
environment remains unchanged. Native preparation owns actual setup and
model/analysis capability admission; source transport is not numerical coverage.

```text
exact source + typed OSDI instance map -> one source session -> resolved CircuitIR
 -> configuration identity including exact artifact/descriptor/typed scopes/state
 -> existing native preparation and selected analysis execution
```

The historical `v6.osdi-inputs` semantic domain was extended by the current
source-reexecution domains above. The current encoding binds every instance map key, complete artifact
reference, descriptor selection, ordered scoped assignment kinds/values and
previous state. Local paths remain availability information. Different typed
input or previous state must change the configuration digest; saved inspection
data cannot authorize an executable library. Frontend tests own source transport;
native API/CLI tests own numerical results, receipt matching and save/reload.

## S4 Frequency Analysis Admission

Existing effective Analysis adds AC and noise configurations. The same source evaluation
session resolves bounded frequency sweeps, exact output/reference nodes and the independent
input source. These effective values enter configuration identity. IC remains exclusive to
transient UIC; nodesets initialize nested operating points. Source DC sweeps and
other selected analyses retain their effective intent and exact model bindings;
Native model capability checks decide execution support. Nonconstant bound-supply coverage
retains its existing explicit refusal contract.

### Shared inclusive DC schedule

`SPICEDCSweepSchedule` owns finite directional numeric DC coordinates for both
prepared execution and actual batch CLI. Coordinates use `start + index * step`;
a stop within one binary64 representational step of the final grid coordinate is
included as the exact requested stop, for both undershoot and overshoot. The initial
coordinate always preserves the requested start. Endpoint normalization preserves
the advancing-value check; a repeated grid coordinate remains a failure. Nongrid
stops are not rounded by a fraction of the sweep step. Finite span, direction, checked point count and advancing values
are validated before publishing a schedule. The prepared caller retains its
per-point cancellation/work accounting through the utility's checked callback.
Decimal endpoints, descending sweeps, nongrid stop exclusion and count refusals
are covered by focused schedule tests and the complete CLI DC persistence test.

Schedule failures are translated at their caller boundary: prepared execution
preserves `SPICESimulationPreparationError.unsupportedCapability`, and batch CLI
preserves `CoreSpiceCLICaseError.incompleteOutput`. Only schedule failures are
translated; cancellation and resource-accounting failures propagate unchanged.

## Fresh Source Reexecution

`SPICESimulationPreparer.reprepare` reuses the retained parsed input and exact source
owners, then creates a new exclusive frontend evaluation and numerical input. It
does not reread the filesystem or reuse mutable model history. Root parameter
overrides, explicit temperature policy, seed and selected analysis belong to the
new request; their values are included in effective configuration identity. The
source input identity remains unchanged for the same captured graph. A reexecution
retains its own reservations while sharing immutable captured storage. Cancellation
and work/storage charges use the original invocation accountant.

```text
Prepared owned sources -> fresh evaluation(parameters, seed, temperature)
                      -> fresh resolved circuit + effective configuration
                      -> fresh native preparation -> analysis
```

Parameter overrides are finite root invocation constants using the existing
frontend contract. No flat IR mutation is treated as a resolved MOS input.

`prepareRuns` captures and parses once, then returns an immutable run-selection
owner. `prepareRun(at:)` prepares one selected temperature/Monte Carlo case at a
time. Every case uses a fresh exclusive frontend session and actual seed. The
winning source `.temp` vector forms the temperature axis; selected `.mc` forms
the iteration axis. The finite product is admitted before selection allocation.
Temperature discovery reserves only the Lowering-owned capacity for traversal and
the actual winning literal vector. An absent family reserves no model-compilation
envelope; a large resolution policy is an admission ceiling, not schedule storage.
The temporary receipt remains alive until all selected coordinates have been copied.
Iteration seeds are checked `baseSeed + zeroBasedIteration`; an explicit caller
`monteCarloSeedOverride` owns the base, then the source `.mc` seed, then the request
seed. The typed selection records this authority, preserving CLI explicit `--seed`
precedence without guessing whether a general request seed was defaulted. Each prepared configuration
retains this complete selection, while numerical result storage belongs to the
consumer. Selection alone is no execution evidence.

Prepared TF/PZ/sensitivity/Fourier use the same source scalar resolution and native
analysis implementations as ordinary APIs. Fourier resolves its supporting `.tran`
through the same exclusive scalar session, including IC/nodeset application.
Sensitivity source rebinding uses a fresh source override/snapshot and native
preparation for every changed scalar, including unchanged MOS in that circuit.

### Actual IO Transform Capacity

IO intake reserves text and parsed-entry storage from the captured source size and
actual parsed counts. Sweep capacity is a separate Double-coordinate envelope, not
4096 bytes per permitted sweep point. After fresh lowering, IO reserves configuration
and node-map storage from actual lowered instance/node counts before building those
collections. The source transform ceiling applies to the combined IO reservation;
policy `maximumElements` remains an admission ceiling and is never an eager allocation
size. Frontend compilation/evaluation retains its independently checked envelope.

The prepared OSDI frontend test `preparedDynamicIntentRetainsExactBindingForNativeAdmission`
checks exact DC coordinates, transient timing and unchanged typed model input.
The former S3-only rejection test is retired because dynamic source preparation is
implemented. Actual-worker Native/CLI tests own numerical success and capability
refusal; this frontend test grants neither model execution nor flow authority.

### Explicit fixed-bias network selection

An optional `SPICENetworkParameterSelection` is caller intent, not source grammar.
It requires an explicit request `analysisIndex` and applies only to that resolved
AC directive (including an explicitly selected family member's inner AC). Other
AC directives are not converted. Ports name ordered existing independent voltage
sources and carry explicit finite positive real reference resistances. The same
captured source and effective DC configuration supply the bias; no new parser or
matched-wave boundary is introduced. The effective analysis is distinct `network`,
with positive strictly increasing Hz coordinates and checked caller RF limits.
Zero/negative frequencies, duplicate/unknown ports, non-AC selection and missing
explicit index fail before numerical execution. RF residual tolerance is an
explicit positive caller field, never an inferred floor on convergence tolerance.

Configuration identity binds the actual ordered source names, owned branches,
terminal orientation, reference resistances, frequency coordinates, voltage-basis
excitation convention and RF numerical limits. Existing non-RF identities retain
their previous encoding. Family re-preparation preserves the selection and binds
each fresh temperature/seed case without rereading source. RF frequency and port
materializations participate in the existing invocation storage/work accounting.

Network policy validation is shared by initial capture and retained-source
resolution. `prepare`, `prepareRuns`, each `prepareRun` and `reprepare` enforce
the same explicit-index, nonempty bounded ports and valid signed RF policy checks
before any network-specific materialization or unsigned identity encoding.
