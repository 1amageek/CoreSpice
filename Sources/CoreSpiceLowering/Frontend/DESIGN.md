# Lowering Frontend

## Purpose and Scope

This component owns source-preserving ParsedNetlist compilation, concrete
invocation planning, shared scalar evaluation, and canonical CircuitIR emission.
Parent: [CoreSpiceLowering](../DESIGN.md). It has no child components.
The contracts below specify the approved S4 adapter migration; implementation and
verification completion are recorded only in workspace PROGRESS.md B8.6.5.18.4.

Private `ParsedNetlistCompiler` is noncopyable and its compile operation consumes
the construction owner. It composes the noncopyable declaration builder and
consuming snapshot publication described by
[Declarations](../../CoreSpiceMOSResolution/Declarations/DESIGN.md). Source compilation
publishes reusable immutable `CompiledNetlist`; mutable construction cannot survive
that publication or share the builder's private program table.

## Responsibilities and Boundaries

Lowering compiles typed parsed input once and retains its ordered source metadata.
It supplies lexical declarations and concrete caller environments to MOSResolution,
uses its exclusive evaluation session for every scalar consumer, and emits resolved
MOS stages. Ordered execution jobs are internal implementation values, not a second
public circuit representation. Instance.mos is the sole MOS value authority.

Lowering depends on ParsedIR, IR, MOSContracts and MOSResolution. It does not depend
on Devices, compact-model kernels or native execution; BSIM preparation policies,
operating conditions, cold preparation, auxiliary topology allocation and consuming
binding belong to execution composition. No model-name search or flattened model
map can override an emitted resolved MOS stage.

| Responsibility | Owner | Consumed contract |
|---|---|---|
| Source grammar and ordered occurrences | ParsedIR / ParserSPICE | Typed AST, assignment/function order, actual source origin |
| Declaration storage, final invocation bindings, RNG and model selection | MOSResolution | Shared snapshot/graph, exclusive session, exact resolved result |
| Typed circuit instance and resolved/prepared stage | IR | Instance.mos and canonical port identities |
| Option/analysis interpretation | IO caller | Compile-time scalar slots evaluated through this session |
| Numerical preparation and executable lifetime | Devices / native composition | Resolve, prepare, allocate, compile, consume-bind |

## Related Designs

| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [CoreSpiceLowering](../DESIGN.md) | parent | Frontend module composition | Native-independent frontend responsibility | Revalidate public consumers together |
| [ParsedIR](../../CoreSpiceParsedIR/DESIGN.md) | depends on | Ordered assignments/functions and source occurrences | Single source-to-program projection | Dictionaries do not replace available ordered metadata |
| [ParserSPICE](../../CoreSpiceParserSPICE/DESIGN.md) | depends on | Typed expression and runtime syntax | No source reparsing | Keep bare passive roles and runtime payload distinct |
| [Declarations](../../CoreSpiceMOSResolution/Declarations/DESIGN.md) | depends on | Immutable snapshot builder | Compile once, retain every occurrence | No declarations copied per X invocation |
| [Evaluation](../../CoreSpiceMOSResolution/Evaluation/DESIGN.md) | depends on | Graph, constants, exclusive shared session | Sole scalar and random authority | Numeric caller ancestry and lexical declaration ancestry differ |
| [Selection](../../CoreSpiceMOSResolution/Selection/DESIGN.md) | depends on | resolveMOS and independent inspection | Sole MOS selection/normalization | No model or coefficient reevaluation |
| [MOS instances](../../CoreSpiceIR/MOSInstances/DESIGN.md) | depends on | resolved and prepared stages | Sole immutable MOS truth | Resolved stage is not compile/bind admission |
| [IO](../../CoreSpiceIO/DESIGN.md) | used by | Compiled slots and exclusive frontend session | Public parse/lower/options/control migration | IO cannot create another parameter resolver or RNG |
| [Native execution](../../CoreSpice/NativeExecution/DESIGN.md) | used by | LoweredCircuit and resolved stage | Numerical composition | Allocate original auxiliary topology after actual preparation |
| [Devices](../../CoreSpiceDevices/DESIGN.md) | coordinates with | Non-MOS execution and runtime expression semantics | Physical laws remain device-owned | No implementation dependency from Lowering |

## Architecture

```mermaid
flowchart TD
    Parsed[Typed ParsedNetlist] --> Compile[Compile once: lexical declarations and scalar slots]
    Compile --> Compiled[CompiledNetlist: shared immutable snapshot and source templates]
    Compiled --> Plan[Evaluation-free reachable X planning]
    Overrides[Finite root override constants] --> Plan
    Plan --> Graph[Checked concrete invocation graph and internal ordered jobs]
    Graph --> Session[One exclusive frontend session / MOSEvaluationSession]
    IO[IO numeric options, analyses and controls] <--> Session
    Session --> MOS[resolveMOS -> Instance.mos.resolved]
    Session --> Other[Non-MOS scalars and retained runtime payload]
    MOS --> Circuit[Canonical CircuitIR]
    Other --> Circuit
    Circuit --> Finish[LoweredCircuit: circuit + snapshot + graph + final provenance]
    Session --> Finish
    Finish --> Native[Execution-owned prepare / allocate / compile / consuming bind]
```

## Contracts and Invariants

### Source compilation and authority

CompiledNetlist is an immutable Sendable owner of one MOSDeclarationSnapshot,
lexical body/subcircuit templates, non-MOS model occurrences, and caller-addressable
scalar slot descriptors. It strongly retains all tables needed to interpret IDs;
identity tokens alone are insufficient. Compilation is independent of seed and
concrete invocation values. All reachable and unused lexical declarations remain
inspectable without numerically evaluating unused bodies or model cards.

ParsedExpression maps structurally and exhaustively to MOSExpression: literals,
references, unary/binary operators, ordered function arguments and conditionals.
There is no String serialization/reparse, expression-text hashing, AST-based random
slot deduplication, or re-interning after snapshot publication. A program may be
shared only when semantic slots remain distinct at evaluation/cache boundaries.

Ordered parameterDefinitions, parameterAssignments and functionDefinitions are
authoritative when present. Header defaults precede body defaults; source order
and duplicate occurrences survive compilation. Function metadata and matching
controls are one declaration, not two executable registrations. Only manually
constructed ParsedIR without the corresponding metadata uses a deterministic
case-normalized dictionary/control fallback. Such fallback never invents source
order, capture IDs, parse occurrence IDs or content digests. Exact release version
text is preserved as text; it is not evaluated as a floating-point number.

Source conversion occurs once. Actual selected model provenance comes from its
ParsedModel.origin, including capture, parse occurrence and supplied coordinates.
Unavailable coordinates remain absent. Synthetic caller/scalar slot identities
are internal evaluation identities and never masquerade as source occurrences.

### Invocation planning and parameter lookup

The planner traverses reachable X instances without evaluating a scalar. It
validates names, port counts, expansion depth and graph budgets, creates stable
per-run invocation IDs, and maps ports/internal nodes and runtime V/I references
once. Caller invocations precede children. Lexical declarations are shared rather
than cloned. Header/body final defaults and unique explicit actuals are delegated
to the checked graph; duplicate explicit actuals fail. Body defaults are last-wins.

Parameter overrides enter the root invocation as finite MOSInvocationValue.constant
actuals before any dependent global evaluation. Their symbols must already belong
to the compiled symbol inventory; callers declare additional override names at
compile time. Constants support new MC values without extending the snapshot.
A root program actual has no caller for self pass-through and therefore retains
normal cycle rejection. X program actual self-name lookup uses the exact caller;
other references see the final child environment. Function formals take priority.

Model/subcircuit/function declaration selection follows lexical scope ancestry,
not arbitrary caller declarations. Numeric parameter lookup follows the exact
concrete caller chain. A selected model coefficient is evaluated in the concrete
invocation owning that model declaration; a function body uses callsite numeric
invocation while nested function names use the function declaration's lexical
scope. No same-named parent/sibling model can repair a failed nearer owner.

### Pinned ordinary hierarchical multiplicity

The pinned normal profile uses the source-level `inp_fix_subckt_multiplier` rule in
[fixed inpcom.c](https://github.com/imr/ngspice/blob/ebdaf58ec76a06ffaac7e0f138360dd1cf5ee4b6/src/frontend/inpcom.c#L4129-L4278).
A reachable lexical X occurrence supplying `m` activates its target declaration unless
that declaration explicitly owns a header or body `m` parameter. The fixed
reference promotes body defaults before multiplier activation. Activation applies
to every reachable invocation of that declaration, including siblings without a
supplied multiplier. Missing `m` defaults to one; explicit X actuals retain priority.
An explicit header/body `m` delegates all device scaling to the author's expressions.
Strict profile supplies no implicit multiplicity.

Compilation retains one interned `m` reference program if source X actuals require
it, without changing parsed source or adding fictitious declaration occurrences.
Evaluation-free planning owns a bounded reachability/activation worklist and
records effective component bindings. Ordinary mode's appended `m={m}` replaces an existing device
`m`, rather than multiplying it as HSPICE mode would; discarded expressions are
not evaluated. The reference excludes V/E/H/A/K/N/O/P/S/T/U/W/Y devices and voltage
behavioral sources. Eligible resistors receive the same effective scalar through
their existing parallel-multiplicity contract. Other eligible non-MOS families are refused before
scalar evaluation: their existing flattened `m` may be ignored or denote a model
grading coefficient, so propagating it would silently change or lose meaning.
Their physical multiplicity implementation is outside this MOS boundary change.
Nested inherited X arguments require the child to declare `m` or already be activated
by a reachable explicit X actual. Otherwise planning refuses the path: the fixed
source's one-pass rewrite has order-dependent nested success/refusal, which the
unordered ParsedIR body collections cannot reproduce. It does not invent recursive
implicit activation. Unreachable declarations cannot activate a used sibling.
The graph owns concrete multiplier bindings; normal evaluation memoizes them once.
MOS resolution, schema validation and normalization consume the effective program
before publishing ResolvedMOSInstance. Devices only consume its immutable `m`.
No execution-stage multiplier injection, geometry alteration or re-preparation is
permitted. Synthetic binding/program identities do not fabricate source positions.

Activation storage, visits, default actuals and effective binding arrays are charged
to FrontendStorage under existing caller limits. Reachability/activation scratch
is released before publishing the graph/session; it is not retained-value capacity. A failed expansion publishes no
partial circuit. `HierarchicalMultiplierTests` owns nested/default/header/strict,
body-default and discarded-random counterexamples; original RF execution and
independent DC comparison own the upper-path evidence.

### Model coefficients are evaluation slots

Non-MOS coefficient assignments, like MOS coefficients, are scalar evaluation
slots, not .param declarations. They never add peer coefficients to the numeric
environment. The selected declaration's owning invocation and lexical scope are
passed to the shared evaluator. A coefficient referring to its own spelling reads
the enclosing parameter if present; a reference existing only as another model
coefficient fails as missing binding. No synthetic coefficient scope is created.

This deliberately replaces the legacy temporary resolver's sorted publication,
peer-coefficient extension and retry behavior. Existing API shape and processing
order are not compatibility requirements of this migration. For global b=7 and
model a={b}, b=2 the values remain a=7 and b=2; removing global b makes a fail,
regardless of coefficient order. Non-MOS device laws and admitted parameter roles
remain unchanged. Ordered source occurrences and selected declaration identity
remain available independently of executable value maps.

### One scalar session and explicit caller policy

Profile, MOSResolutionLimits and UInt64 seed are explicit required inputs to every
frontend evaluation run. There is no hidden strict/pinned choice, unlimited limit,
time-based seed or default RNG. One noncopyable NetlistLoweringSession exclusively
owns the graph, internal ordered jobs, one MOSEvaluationSession, frontend scalar
slot memo and optional emitted circuit. It is synchronously borrowed inout and
cannot be copied, shared or captured by an escaping callback.

Global/default/actual parameter bindings, non-MOS instance/model scalar slots,
MOS requests, numeric options, .temp, analysis bounds, initial conditions, node
sets and other admitted static control expressions use that same session. A
single semantic slot evaluates at most once per invocation; retries after failure
and a second legacy global/model resolver are prohibited. Distinct scalar slots
with the same program retain distinct draws. Binding and MOS caches remain owned
by MOSResolution; frontend slot memo keys include compiled identity, slot and
concrete invocation. Failed adapter validation/evaluation poisons the run before partial
success or another draw can escape.

Root-call order is explicit and retained in provenance: final root bindings,
caller-requested static control/analysis slots, then depth-first component jobs
with final invocation bindings on entry. Calls after circuit emission remain in
the same ordered session. Within an expression, operand/argument ordering and
short-circuit behavior are Evaluation-owned. Internal topology publication may
defer coupled inductors within a body without silently changing scalar call order.
The final provenance records seed, PRNG version, profile, call order, cumulative
steps/draws and bounded retained/peak capacity counters.

### Public scalar bridge and result

The minimum public API has the following roles; these names are approved adapter
API targets, not a claim that callable implementations already exist:

| API / value | Contract |
|---|---|
| NetlistLowering.compile | Compile ParsedNetlist plus explicit limits/control and declared extra override symbols into CompiledNetlist once |
| CompiledNetlist.scalarSlots | Read-only typed source/field addresses for static scalar consumers; slot IDs are tied to the compiled identity |
| NetlistLowering.beginEvaluation | Accept compiled input, explicit profile/limits/seed, finite root constants and optional cancellation/work control; build reachable graph and exclusive session |
| NetlistLoweringSession.evaluateScalar | Evaluate a compiled scalar slot at its checked invocation through the sole MOS session, memoizing the semantic slot |
| NetlistLoweringSession.lower | Emit CircuitIR once with supplied effective geometry scale and existing non-MOS emission options; retain it inside the session |
| NetlistLoweringSession.circuit | Read-only post-emission circuit for node/analysis setup, without transferring an executable device owner |
| NetlistLoweringSession.poison | Mark external static-consumer semantic validation failure terminal without drawing/evaluating again |
| NetlistLoweringSession.finish | Consume the healthy emitted session and return LoweredCircuit with final provenance after all static consumers |
| LoweredCircuit | Immutable circuit, exact shared snapshot and graph, and final evaluation provenance; no duplicate resolved-MOS list |

The concrete public signatures for IO integration are:

```swift
public static func compile(
    _ netlist: ParsedNetlist,
    additionalOverrideNames: [String] = [],
    limits: MOSResolutionLimits,
    control: (any MOSResolutionControlling)? = nil
) throws -> CompiledNetlist

public static func beginEvaluation(
    _ compiled: CompiledNetlist,
    profile: MOSInputProfile,
    limits: MOSResolutionLimits,
    seed: UInt64,
    parameterOverrides: [String: Double] = [:],
    control: (any MOSResolutionControlling)? = nil
) throws -> NetlistLoweringSession

public enum NetlistScalarAddress: Sendable, Hashable {
    case control(index: Int, field: String)
    case analysis(index: Int, field: String)
    case initialCondition(node: String)
    case nodeSet(node: String)
}

// CompiledNetlist owns these read-only members.
public var source: ParsedNetlist { get }
public var snapshot: MOSDeclarationSnapshot { get }
public func sameStorage(as other: CompiledNetlist) -> Bool
public func scalarSlot(at address: NetlistScalarAddress) throws -> NetlistScalarSlot

// NetlistLoweringSession is ~Copyable and owns these operations.
public var compiled: CompiledNetlist { get }
public mutating func evaluateScalar(_ slot: NetlistScalarSlot) throws -> Double
public mutating func lower(geometryScale: Double? = nil, expandModels: Bool = true) throws
public var circuit: CircuitIR? { get }
public mutating func poison(_ cause: MOSResolutionFailure)
public consuming func finish() throws -> LoweredCircuit
```

The static factories belong to NetlistLowering. CompiledNetlist is a final
immutable Sendable class, with sameStorage checking exact owner identity;
LoweredCircuit is an immutable Sendable value. LoweredCircuit has public read-only circuit,
snapshot, graph and evaluationProvenance members. NetlistScalarSlot is an immutable
checked identity without a caller-constructible initializer; evaluateScalar checks
its exact CompiledNetlist identity before program lookup. Public static control
slots use the root invocation; component invocation-specific slots remain internal.
The optional circuit is nil before successful lower and read-only afterward;
finish requires a healthy emitted circuit and consumes the session once.

Field names are checked inventory addresses matching the ParsedIR property, never
expression text: ordinary option/temp control field is value; static analysis
fields use their property names, with analysis. prefixes for nested MC analyses.
The descriptor table is the authority for supported addresses. Missing/unsupported
addresses fail explicitly. Initial-condition/node-set control and dictionary
addresses referring to the same effective source assignment alias one scalar slot,
so querying both cannot consume two random draws. Source duplicate controls remain
separate ordered occurrences; only an actual alias shares evaluation identity.

Slots address a control ordinal/field, analysis ordinal/field, initial-condition
node or node-set node; their descriptors retain actual source coordinates when
available. Unknown/text-valued controls remain typed raw payload. IO chooses the
recognized numeric slots, so a method name or unknown option does not become an
undefined numeric variable. Strings/vectors are explicitly rejected by scalar
consumers. Compile all needed static expressions before beginning evaluation;
post-publication callers cannot submit text or extend the program inventory.

Host inspection reads the original resolved instance from LoweredCircuit.circuit
and calls inspectResolvedMOS with that result and LoweredCircuit.snapshot under
explicit inspection limits/control. The returned graph and provenance identify
its concrete invocation and evaluation run; no inspection operation re-evaluates
a program or draws randomness. Numerical composition constructs a separate
prepared CircuitIR and preserves the original LoweredCircuit for inspection.
Snapshot/identity mismatch is a typed refusal, including across MC samples with
different compiled inputs; equal textual names never substitute for identity.

IO resolves its numeric options through evaluateScalar, validates option semantics,
passes the resulting scale to lower, consumes analysis/IC/node-set scalar slots
through the same session, and finishes only after those calls. Lowering-only
callers consume the last source .options scale slot through this session unless
an explicit finite positive override suppresses that slot. IO's same evaluated
scale is never re-evaluated by lower. Temperature is an operating-condition input,
not an implicitly injected numeric parameter. The old SPICEAnalysisOptions
makeEvaluationContext retry/RNG path cannot remain on the migrated execution path.
Option interpretation, analysis dispatch and source coverage remain IO-owned.
The IO adapter is SPICEAnalysisOptions.resolve(from: CompiledNetlist, session:
inout NetlistLoweringSession). It checks session.compiled.sameStorage at entry;
wrong identity poisons the run before reading even a text-only control list.
External semantic validation failure, including invalid option ranges or nonzero
ground voltage, calls session.poison(.invalidRequest) before propagating the
original typed IO error. This public terminal operation adds no RNG/work attempt
and allows no later scalar evaluation, emission or finish to succeed.

### Runtime payload and MOS emission

B V/I/time/temper expressions and runtime-dependent R expressions are typed
runtime payload, not scalar evaluation jobs. PWL numeric vectors and control-source
references preserve their typed roles. Existing BehavioralExpressionLowerer emits
canonical runtime expressions, using session-resolved parameter values and
compiled lexical function lookup rather than a new ExpressionEvaluator/RNG.
Function formal substitution and nested lexical function ownership remain exact;
ports, read-only node/branch references and internal names are mapped once.
Runtime hertz remains explicitly unsupported, including when a parameter has that
name. Runtime temper remains ambient Celsius supplied at binding/rebinding.

The MOS branch bypasses legacy context.model, mapComponentType, model flattening,
legacy geometry refusal and classical native admission. resolveMOS supplies the exact
selected source/release/schema and separate normalized values. Lowering emits
Instance.mos.resolved with physical nodes and zero owned auxiliary nodes. Generic
parameters, model and modelConsumption maps do not duplicate or override MOS
truth. IR/compiler refuse resolved or legacy MOS as numerical admission. Execution
composition alone prepares, allocates fresh auxiliary identities, replaces the
stage with its receipt, compiles, and consumes binding. Legacy native BSIM input
is rejected with its actual declaration source and explicit OSDI migration guidance.

## Runtime Flows

```text
compile once
  -> beginEvaluation(profile, limits, seed, root constants)
  -> same-session static option calls / validated effective scale
  -> lower: invocation entry bindings / ordered non-MOS slots / resolveMOS
  -> same-session analysis and node-voltage calls
  -> finish: LoweredCircuit with final counters and retained inspection storage
  -> execution-owned numerical preparation

Monte Carlo sample
  -> same CompiledNetlist + new root constants / graph / seed / session
  -> fresh resolved IR and later fresh executable owners
```

## State, Ownership, and Lifecycle

| State | Owner | Access / release |
|---|---|---|
| Lexical snapshot, source templates and program slots | CompiledNetlist | Immutable shared Sendable storage; retained through inspection |
| Concrete bindings and ancestry | MOSInvocationGraph | Checked immutable shared storage; root overrides belong to each run |
| RNG, scalar memo, work/capacity and terminal diagnostics | Exclusive frontend/MOS session | Synchronous inout calls; released or consumed at finish |
| Resolved MOS | Instance.mos | Immutable IR value; clones preserve the stage |
| Runtime expression | Canonical non-MOS Instance parameters | Finite captured parameters plus runtime variables; operating conditions supplied at binding |
| Kernel owner and auxiliary topology | Execution composition / Devices | Outside Lowering; consuming bind and deterministic release |

No new shared mutable Sendable state, unchecked concurrency, no-op lock or
Embedded-only raw storage is introduced. Existing LoweringContext may supply an
immutable-value emission view for non-MOS runtime conversion; it is not another
parameter/model evaluation authority. Its existing Mutex contract remains intact
where reachable during migration.

## Failure, Concurrency, and Constraints

Compilation, planning, scalar memo, source/template retention, AST traversal,
expansion jobs and publication use explicit byte/work/cardinality/depth budgets
and cancellation. The adapter does not hide unbounded arrays around bounded
MOSResolution calls. Duplicate actuals, missing references, cycles, wrong compiled
identity, invalid scalar type, nonfinite constants and unsupported selected input
fail explicitly. A poisoned session cannot publish LoweredCircuit. Numerical
preparation failure preserves resolved inspection and cannot select a substitute
release, family or backend.

## Verification and Change Impact

| Owner / test scope | Required counterexample or behavior |
|---|---|
| Lowering compiler | Ordered duplicate declarations, actual origin, lexical bodies/functions, 1:1 AST conversion and retained unused declarations |
| Lowering planner | Repeated/nested X identity, port remapping once, duplicate actuals, root constants, local last-wins and caller self pass-through |
| Shared scalar composition | Global/header/body/X/non-MOS/MOS/control rand share one deterministic stream; repeated same slot does not draw twice; sibling slots do |
| Model slot semantics | Enclosing coefficient names resolve as parameters; coefficient-only peer reference fails without publication/retry |
| Runtime boundary | B/R V/I/time/temper and PWL survive; lexical functions, node/branch mapping and temperature rebinding remain exact |
| MOS stage | Scale once, scoped exact/family selection, separate roles, actual selected origin, zero auxiliary nodes, source-positioned legacy native BSIM refusal |
| Public IO | Numeric options and analyses use the same session; option scale/rand are not re-evaluated; text options do not spuriously evaluate |
| Public native composition | Resolved IR is refused by compiler; admitted preparation/receipt/owned topology/consuming bind execute through actual CPU path |
| Reuse / failure | Same snapshot with fresh graph/constants/seed/session; wrong identity, cancellation, budgets and poison produce typed failure |

The S4 adapter worker owns Sources/CoreSpiceLowering/** and
Tests/CoreSpiceLoweringTests/** only. New implementation lives beside this design
in Frontend/. NetlistLowering.swift remains the module composition root. Existing
helpers touched for this responsibility move into Frontend/ when migrated; unrelated
legacy files are not reorganized. IO owns source policy, option interpretation,
public parse/lower entry points and simulation preparation. Root owns Package.swift,
CLI and adoption pins. Compiler/snapshot, planner, exclusive session/scalar slots,
result/provenance and runtime emission are one Lowering ownership boundary; these
files are implemented serially against the reviewed S3 stage/preparation contract.
Source implementation follows reviewed S3 commit f816ee6.

Focused tests belong to CoreSpiceLoweringTests. Parser intake, scalar options and
public parse-to-native execution belong to the corresponding ParserSPICE/IO tests;
IR, Compile and Devices own their stage/preparation invariants. Shared evidence is
reused only while its owner inputs remain unchanged. Native CPU evidence does not
qualify device physics, a foundry deck, Metal, WASM or Embedded. Revalidate direct
and transitive public callers when this API replaces legacy lower-to-CircuitIR.

## Canonical PWL Source Migration

Parsed numeric vectors preserve alternating PWL time/value values. SPICE PWL syntax
parses and serializes this vector, lowering retains `ParameterValue.realVector`,
and device admission owns strict time/value validation. Partial/unknown source
waveforms produce typed parse/binding failure, never successful DC substitution.
Scalar option/measurement/expression consumers reject vectors explicitly.

## Static Resistor Composition

Scoped/include model resolution consumes only `ParsedComponent.passiveModelCandidate`
for ambiguous bare tokens. An explicit numeric identifier keeps its original role
when an equally named model exists. Subcircuit remapping preserves the candidate
without adding it to physical parameter dictionaries. A braced, quoted or named
numeric expression is never reclassified from its expression shape.

The expander retains resolved resistor model name/type/parameters in
`ResolvedDeviceModel`, with supplied instance values in their own map, regardless
of `expandModels`. Scoped references and static expressions use the shared
frontend session. Unknown or mismatched models fail explicitly. Runtime-dependent R
expressions consume `BehavioralExpressionLowerer` and preserve read-only node
and branch dependencies; subcircuit remapping uses the existing voltage-reference
mapper. The runtime contract now explicitly includes `temper` as a binding-time ambient
Celsius variable. It must survive lowering/rebinding rather than resolving from
LoweringContext.temperature. Runtime frequency (`hertz`) is classified as runtime
and explicitly refused, even when a same-named parameter exists. Nested expansion
propagates the already-mapped-node contract into child subcircuits so ports and
read-only dependencies retain canonical identities. Binding is owned by the
complete admitted Devices runtime profile. Static geometry and
temperature/noise physics belong to
[Devices](../../CoreSpiceDevices/Devices/DESIGN.md#resistor-execution-contract).

The focused owners are [ResistorParserTests](../../../Tests/CoreSpiceParserSPICETests/ResistorParserTests.swift),
[ResistorLoweringTests](../../../Tests/CoreSpiceLoweringTests/ResistorLoweringTests.swift),
[StaticResistorTests](../../../Tests/CoreSpiceDevicesTests/StaticResistorTests.swift), and
[public IO execution](../../../Tests/CoreSpiceIOTests/SPICEIOEndToEndTests.swift).
Their owned paths are native CPU DC, independent AC and thermal/flicker noise;
compilation or parser intake is not physical qualification. Supplied static R l/w
consume the finite positive document scale exactly once; model defaults stay in
SI and the separate instance resistance scale retains its meaning. Non-MOS
selected model identity/parameters remain separate from supplied instance values.
Generated JFET/MESFET series elements and URC ladder/shunt elements inherit the
actual selected source model metadata; cloning preserves it. Unavailable model
origin is not inferred as model-free.

## Capacitor Source Resolution and Admission

Bare C `passiveModelCandidate` resolution occurs after global and invocation-local
parameters have resolved in the final invocation graph. Numeric parameter
binding presence wins over lexical model presence, regardless of numeric sign
or zero. Unresolved/cyclic parameters fail before this choice; functions alone do not
count as bare parameter declarations. Reserved bare `c` does not resolve to a same-named model.

For an actual model reference, missing and mismatched types are typed failures.
Matching static C models retain `ResolvedDeviceModel` separately from instance
parameters, so [Devices](../../CoreSpiceDevices/Devices/DESIGN.md) owns model/geometry
capacitance, temperature and multiplicity semantics. Explicit instance capacitance
and global-scaled source geometry retain their separate roles. Numerical binding
uses the selected model and never silently discards it. Unused C declarations are
not evaluated. R source roles and URC-generated ideal capacitors remain separate.

## Charge and Runtime Capacitance Source Admission

Selected `q` is always retained as `BehavioralExpression`, including a numeric
constant. Its numerical meaning is total charge. Runtime `c` is retained under
its distinct key as differential capacitance; it is not converted to `C*V` charge.
The existing behavioral lowerer retains lexical parameter values, AST structure,
canonical referenced nodes/branches, temperature binding and resource limits.
Unselected subcircuit bodies remain unevaluated. Mixed Q/C or Q/model inputs fail;
runtime C plus a model fails because that combined reference semantics is not
admitted. Static model C follows the source model contract above.

Inherited capacitor multiplicity uses the same admitted source expansion as
resistors. Instance L/W uses document scale before Devices preparation. Functional
C/Q fields and initial conditions do not become scalar sensitivity targets. The
numerical owner verifies dQ/dt versus C*dV/dt, Jacobian, AC and trial/accepted history
in its own tests; frontend tests prove source roles, expression/dependency retention
and exact failure paths rather than claiming numerical qualification.

## Frontend Capacity Envelope and Inspection Link

The public `resourceEnvelope(limits:)` uses checked arithmetic with B equal to
`maximumRetainedBytes`. The adapter ledger bounds retained parsed source (including
ignored control/analysis payload and origins), templates, scalar slots, planner
buffers, scalar memoization, runtime-expression buffers and the circuit builder.
The immutable compiled snapshot is included in this adapter ledger after compile.
The snapshot builder and its finish output ledger can coexist with the adapter
ledger during compilation: the simultaneous upper bound is 3B. Graph construction
has one B ledger and ends before the B evaluation session starts; graph/session
retention coexists with the B adapter ledger. Public reservation is retained 2B,
temporary B, simultaneous 3B. Buffer element capacities and UTF-8 payload follow
MOSStorageBudget accounting; allocator metadata is outside that shared contract.

`CompiledNetlist.sameStorage(as:)` checks exact immutable source ownership.
`modelOrigin(for:)` validates resolved identity and selected declaration/source
before returning only the retained parser origin. Missing origins stay absent.
IC/nodeSet control occurrences and effective dictionary keys share one scalar slot,
with normalized node spelling, so repeated lookups reuse the same evaluated value.

`NetlistEvaluationProvenance` exposes profile, evaluation, evaluationSteps,
retainedBytes and peakOwnedBufferBytes. Its seed, randomDraws,
randomGeneratorVersion and rootVisits are read-only views of the one finished
MOSEvaluationSession. Runtime constant leaves use Resolution's package binaryMOSValue and
builtinMOSValue contracts, including the same shared session RNG. Runtime
quantities remain typed BehavioralExpression; no scalar operator or random
implementation is duplicated in Lowering.

Runtime lowering records the occurrence-owned component parameter program as one
shared-session root visit before traversing its AST, at the same granularity as
ordinary evaluateMOSProgram. Static conditional and logical branches remain lazy.
A random scalar capture beneath a dynamic conditional or dynamic short-circuit
branch is a typed refusal; both runtime branches are never eagerly sampled.
Pure unary, binary and function operations beneath a dynamic conditional remain
typed runtime operations, including constant operands. Lowering therefore does
not reject a potentially inactive arithmetic/domain error; the existing runtime
conditional evaluates and validates only the selected branch. This deferral does
not change the existing runtime logical-operator semantics. Outside dynamic
conditional branches, static capture uses the shared Resolution arithmetic law;
`pwrs` preserves a negative base's sign while `pwr` returns its unsigned magnitude.

## MOS Initial Condition Operand Projection

Ordered MOS `ic` assignments retain the supplied first operand and remaining
`additionalValues`. Frontend compiles each of the one to three supplied operands
once, in source operand order, to the existing canonical schema names ic_vds,
ic_vgs and ic_vbs. Parser dictionary projections do not supply another program
or another evaluation; omitted coordinates remain absent in resolved bindings.
Existing numerical preparation owns its initial-condition defaults.

A repeated vector or a vector combined with an explicit canonical IC assignment
is a selected-component typed refusal in both profiles. Non-scalar operands,
more than three operands and multi-value assignments outside IC are also refused.
Unselected body source remains retained. After model selection, the selected
release schema must admit the source `ic` vector kind as well as its canonical
scalar components. A source vector is never admitted merely because a different
release exposes similarly named scalar parameters. Instance.mos.resolved retains
the final evaluated canonical components; preparation consumes those held values.

### MOS source-admission repairs

MOS non-scalar coefficients are retained as a declaration intake failure marker
rather than omitted as unsupplied. A supplied version must be exact text; a different
ParsedIR value kind is marked invalid and cannot trigger version defaults. ParsedIR keeps the complete original assignment
list. The resolver owns active-candidate refusal and profile-specific duplicate
admission; compilation alone never evaluates or rejects a discarded model card.
The adapter passes Parser-owned version spelling unchanged, including numeric-looking
exponents and suffixes. Release/profile admission belongs to the schema; neither
the adapter nor numerical preparation repairs the spelling. Public frontend and
CLI tests verify the selected binding's raw version and profile-specific rejection.

The exclusive lowering session owns the global MOS width selection input.
`lower(geometryScale:globalWidthPerFinger:expandModels:)` accepts an optional typed
width flag; absent an explicit flag, ordered root `.options wnflag=0|1` settings
choose the final value, otherwise false. The pinned profile alone admits this
setting. Subcircuit placement is rejected during source compilation. Strict input rejects a supplied source flag or true typed flag. Source
flags are always validated even when a typed override is supplied. Non-scalar,
missing, non-finite and non-binary values fail before circuit publication.
`evaluateMOSWidthPerFingerOption(at:)` is the shared checked option entrance used
by IO and lowering; it uses the same scalar memo, so random operands draw once.
The final flag enters every MOSResolutionRequest and its semantic identity.
Resolved rules and selection geometry retain its applied effect; physical W and NF
remain separately normalized and unchanged. This is a CoreSpice source spelling
for the explicitly selected pinned ordinary-MOS contract, not a claim that every
ngspice control-language spelling is implemented.

## Designed Frozen Environment and Diode Adapter

Status: D2 frozen evaluation implemented; D3 diode adapter is implemented. The [Environment contract](../../CoreSpiceEvaluationContracts/Environment/DESIGN.md)
owns the new bootstrap/freeze ordering. Frontend retains one evaluator across
that transition. D3 will compose [DiodeResolution](../DiodeResolution/DESIGN.md) through
its source/index adapter. The current generic non-MOS merge must no longer serve
diodes. Evaluation-free invocation planning remains here; new diode model buffers
are charged by declaration/invocation, not copied into every instance dictionary.

## D2 Temperature Frontend Implementation Contract

NetlistTemperaturePolicy supplies checked defaults and optional typed ambient and
nominal overrides. The documented standard convenience policy is 27 C for both;
IO profile preparation supplies ParserConfiguration.defaultTemperature explicitly.
The last ordered global .temp/.options temp wins for ambient, and the last global
.options tnom wins for nominal; caller overrides precede source. All condition
syntax is checked at compile time, including dead settings. Only winning condition
programs are evaluated. Local condition controls are refused; literal temperature
families require the explicit selection contract below. Condition provenance retains selected control indices and origin;
CompiledNetlist retains their actual source locations.

Planning remains evaluation-free. beginEvaluation bootstraps/freeze using the same
MOSEvaluationSession before resolving ordinary root bindings. The returned lowering
session holds the frozen environment; winning condition scalar slots are memoized
without replay. CircuitIR publication carries the exact identity, including scalar
resistors and all source-derived constants. Runtime resistor temper remains a
runtime expression and uses the same checked binding environment. Public ordinary
scalar evaluation cannot enter an unfinished bootstrap owner.

TemperatureEnvironmentExecutionTests verifies public scalar/runtime resistor DC,
MOS resolved/receipt identity, local/model temperature separation, caller override,
whole-circuit refusal before reservation and direct Analysis binding refusal.

## D3 Change Impact

The [D3 resolution owner](../DiodeResolution/DESIGN.md) defines occurrence admission, frozen
evaluation, immutable result transport and explicit numerical refusal. This layer
consumes that contract; D4 numerical preparation and D5 downstream adoption remain
separate. Its affected production path and behavioral tests are verified in D3.

07C checked diode modelOrigin/modelName inspection validates the actual frontend
model index, lexical scope and captured occurrence against ResolvedDiodeInstance.
It never interprets that index as a MOS declaration ID or selects by model name.
Wrong identity throws the existing frontend conditionMismatch failure; missing
origin stays absent and cannot authorize canonical source-bound receipt publication.

## S3 Explicit Typed OSDI Injection

```text
coefficient-free N + lexical .model OSDI
 + caller map: exact flattened instance name -> OSDIResolvedInstance
 -> checked matching declaration/binding, bounded transport
 -> Instance(typeName: "osdi", osdi: .resolved(...))
 -> existing native setup and StandardCompiler
```

`NetlistLoweringSession.lower` accepts `osdiInstances: [String:
OSDIResolvedInstance] = [:]`. Keys are exact fully flattened instance names;
selection does not case-fold caller keys or infer model parameters. Every selected
N must have a catalog value whose binding model name matches the selected lexical
OSDI declaration under SPICE case-insensitive model lookup. Surplus catalog keys
are refused, so a misspelled or unused requested binding cannot become apparent
success. Direct ParsedIR with coefficients, levels, missing terminals, or
hierarchical multiplier intent fails explicitly before circuit publication.

OSDI emission bypasses generic model expansion and numeric scalar evaluation.
Model/instance assignment scopes and kinds and previous state are retained
unchanged in the immutable resolved value. The frontend storage ledger charges
retained arrays and variable-sized strings before transport; native ownership
separately charges runtime preparation. Circuit clone emission preserves the OSDI
stage. The existing frozen evaluation environment remains the temperature
authority; this source profile has no independent catalog temperature.

`CoreSpiceOSDIFrontendTests` verifies parsed source through actual lowering,
lexical selection and expanded port order, both assignment scopes, explicit state,
clone transport, bounded failures, source diagnostics and strict X lookup. Native
DC numerical and artifact loading evidence belongs to the native owners.

## BJT Private Topology

The non-MOS emitter materializes one owned intrinsic node for each finite positive
`rc`, `rb`, `re`, in collector/base/emitter order. Physical ports remain unchanged.
The bounded builder charges node names, node storage and owned-node storage before
publication; compiler topology includes both ports and owned nodes. Invalid
resistance types/domains fail before emission. Numerical meaning and atomic binding
are owned by [native devices](../../CoreSpiceDevices/Devices/DESIGN.md#bjt-physical-parameter-ownership).

## Fresh Source Reexecution and Temperature Families

`NetlistLowering.compile` accepts checked `NetlistSourceScalarOverride` entries
and an optional `NetlistSourceTemperature` selection. The immutable compiled owner
retains the original parsed source and the explicit overlay/selection as separate
provenance. Evaluated source scalar inventory is explicitly opt-in with
`captureSourceScalars`; ordinary lowering leaves it off and retains no per-instance
model inventory arrays/text. Sensitivity/Monte Carlo owners request capture once
and share that evidence, separately from repeated numerical samples. Root parameter overrides remain invocation bindings and are not used
to impersonate literal device assignments.

| Input | Owner and effect | Failure contract |
|---|---|---|
| Full hierarchical instance plus scalar role/name/value | Compiler registers bounded constant programs; session replaces that instance's source binding before fresh resolution | Unknown instance, duplicate target, nonfinite value or unsupported role/kind fails |
| Instance scalar | Target instance's original source-unit scalar before scale, selection and topology preparation | No stale resolved/prepared object mutation |
| Model scalar | Per-instance effective model overlay; source declaration and other instances remain unchanged | [Selection admission](../../CoreSpiceMOSResolution/Selection/DESIGN.md#fresh-source-effective-model-overlay) |
| Winning `.temp` numeric vector | `temperatureSchedule(in:)` returns ordered source control/value coordinates and checked Kelvin values | No implicit first/last selection |
| Explicit family selection | Compiler verifies original control/value; only selected scalar enters the frozen environment | Missing/mismatched selection fails |

```text
Original ParsedNetlist + explicit overlay + exact temperature selection
  -> fresh compiled snapshot and constant programs
  -> fresh invocation/evaluation owner and frozen condition identity
  -> instance bindings / effective model overlay
  -> fresh resolved circuit -> numerical owner -> fresh topology and binding
```

The last global ambient control wins, including `.options temp`; superseded
vectors do not create extra runs. Single scalar/expression source temperature uses
the existing evaluation contract. Multi-temperature orchestration belongs to IO,
which preserves each selection and its distinct frozen condition identity. The
parser stores a literal list as `.numericVector`; expression-dependent families
remain explicitly unsupported. All retained overlay names, arrays, programs and
validation work use the existing bounded frontend storage ledger.

Temperature discovery does not compile models or copy the parsed graph. Its
control scan compares option names directly as ASCII case-insensitive UTF-8,
without allocating lowercase strings. A missing or scalar winning control
returns an empty array without reserving a dynamic buffer. For a winning vector,
the optional synchronous `temperatureSchedule(..., reserveStorage:)` callback
admits incremental selection-array capacity payload bytes: requested capacity
before allocation, then any actual allocator capacity excess before appending
or publishing selections. This follows the frontend budget's existing
before-request/after-actual capacity contract; allocator metadata and fixed
construction state are excluded. The caller owns reservation lifetime through
the schedule's last use and releases reservations on failure. Callback refusal,
frontend capacity/work refusal, cancellation or invalid temperature publishes no
schedule. No model-compilation resource envelope applies to this operation.

`SourceScalarOverrideTests` owns original-source retention, literal hierarchical
W/L substitution, model cache isolation, invalid target rejection and exact raw
value evidence. `SourceTemperatureFamilyTests` owns ordered selection, winning
control policy, missing/mismatched selection and distinct frozen environments.
Its storage cases verify zero reservation without a winning vector, exact actual
array-capacity accounting, callback refusal and prestart cancellation.

## Immutable Evaluation Provenance Capacity

`NetlistEvaluationProvenance.retainedBytes` and `peakOwnedBufferBytes` preserve their
session-ledger/statistical meaning. A separate package-only
`retainedPayloadByteCount()` composes Evaluation's immutable provenance payload
with the actual-capacity source-scalar buffer and its UTF-8 instance/parameter
names. Temperature/profile/condition IDs and value headers remain inline. Shared
source, compiled snapshot, invocation graph, evaluator caches and diagnostic
buffers are not retained by this provenance value and do not enter its payload
capacity. Checked arithmetic refuses overflow; measurement does not allocate.

The active frontend owner continues to admit all compilation/evaluation storage.
A longer-lived caller admits this result's header and dynamic payload before
publishing the independent retained value. `ImmutableProvenanceStorageTests`
verifies exact dynamic payload, source text/array capacity, unchanged evaluation
facts and diagnostic-budget independence through actual lowering.


## Classical and OSDI Model Separation
Native MOS resolution accepts classical Levels 1/2/3. Legacy BSIM declarations
fail with the actual model source occurrence and explicit OSDI binding guidance;
no level/version conversion or classical fallback occurs. The OSDI emitter and
its caller-supplied exact typed catalog are unchanged by native schema removal.

### Explicit external preparation of original MOS source

`ExternalMOSPreparing` is an opt-in source preparation boundary for an original
`M` statement. A canonical full-instance-name selection is checked before the
classic MOS resolver; absent selection preserves its original typed refusal.
Neither source text nor `.model` type is rewritten to `N` or `.osdi`.

```text
Original M + scoped declaration programs + concrete invocation
    -> Lowering-owned lexical candidates and nonescaping scalar/work callbacks
    -> Explicit IO bin/normalization profile
    -> Exact OSDIResolvedInstance + source/geometry/Given facts
    -> Checked source association -> existing OSDI CircuitIR stage
```

The request retains the original parsed component, exact declaration snapshot and
invocation graph, effective ordered instance/model overrides, inherited multiplier,
terminal order and evaluation environment. Candidate ownership is selected once by
`mosOwningCandidates`; no external profile may replace lexical scope or the shared
scalar/RNG/budget owner. Scalar addresses are checked against those candidates and
memoized within this preparation call. Every actual value is retained separately
from profile claims. Non-escaping callbacks cannot retain the exclusive evaluator.

The explicit profile owns original bin, geometry/scale/width/NF/multiplicity,
Given and descriptor assignment semantics. Lowering owns association checks,
finite numeric facts, terminal order, complete selection consumption and storage
admission. Profile temporary storage uses the caller's source resource accounting;
its work callback charges the same frontend cancellation/work ledger before each
candidate/metadata step. Published facts and scalar trace capacity are charged to
the frontend before publication. Failure poisons the run and publishes no circuit.

`LoweredCircuit.externalMOSPreparations` retains the checked source association,
actual evaluated scalar trace and typed preparation result. It is preparation
provenance, not proof of foreign setup, numerical execution, range completeness,
all roots, flow, history or timing. Model equations and descriptor semantics remain
external-provider responsibilities. Tests must distinguish source-hook admission
from actual provider qualification; a test preparer does not qualify a real PDK.

### Exclusive component-template construction buffer

`ParsedNetlistCompiler.compileBody` owns one initially empty local
`[FrontendComponentTemplate]` while the noncopyable compiler is being consumed by
`compile`. This buffer is distinct from the caller's parsed-component array. Its
only mutation is append in the component loop. It is not passed to a callback,
returned, read through a copied array or placed in a scope during that loop.
Recursive child compilation uses separate local buffers. The first publication is
one immutable `FrontendScopeTemplate.components` assignment after the loop and
child construction; no mutation or reserve of the local buffer follows it.

| Buffer phase | Owner | Reservation contract |
|---|---|---|
| Empty through final local append | Consuming noncopyable ParsedNetlistCompiler | Existing MOSStorageBudget.reserveExclusive, with cancellation even on capacity reuse |
| First scope publication and compiled result | Immutable frontend scope / CompiledNetlist | No further mutation of that backing |
| Any extracted/shared array, other array or dictionary | Existing caller | Conservative COW reserve remains unchanged |

Only that local component-template buffer may use the frontend's narrowly named
exclusive helper. The helper delegates to the existing MOSStorageBudget exclusive
API; it introduces no new work or byte ceiling and does not infer uniqueness for
other arrays. Growth still preadmits old plus requested capacity, then checks
actual allocator capacity before append. Refusal/cancellation publishes no compiled
result; consumed work remains charged. The general reserve path retains its
conservative full-capacity charge because an input may share backing.

The focused `FrontendExclusiveComponentBufferTests` use the public compile path
for N and 2N components and measure the same MOSResolutionControlling retained-byte
charges mapped to source projected-byte work by SPICEFrontendControl. A bound on
cumulative compile work distinguishes geometric growth from repeated full-capacity
charging. Exact retained source and expected ordered IR remain required. Additional
focused ownership tests cover reused capacity, growth peak/refusal/cancellation,
ledger release and general shared-array COW admission. This contract changes no
parser, source selection, physical model or IR meaning; other private buffers are
outside this optimization. The root owns red/green builds and actual full-PEX
preparation under the unchanged caller quota.

### Exclusive execution-job construction buffer

`NetlistInvocationPlanner` is a noncopyable construction owner consumed by `plan`.
The only caller constructs it within `NetlistLowering.beginEvaluation` and consumes
it once. Its initially empty private `[FrontendExecutionJob]` is never extracted or
copied during recursive `visit`: both the invocation-entry append and component
append mutate that same private backing. Child visits mutate the same owner in
depth-first order. After the last append, the scalar-override validation loop only
reads jobs. The first publication is the immutable `FrontendPlan.jobs` assignment
in the consuming return; no planner mutation follows publication. The session
retains the published jobs read-only.

| Phase | Owner | Storage contract |
|---|---|---|
| Entry/component append, including nested visits | Noncopyable planner within consuming plan | Narrowly named FrontendStorage.reserveExclusiveJobs delegates to existing reserveExclusive |
| Final override scan | Same planner | Read-only; no append or reserve |
| Plan/session publication | Immutable jobs array | No subsequent mutation of its backing |

This exclusivity proof applies only to jobs. Invocation arrays, mapped nodes,
actuals, dictionaries and all other reservations keep their existing conservative
COW accounting. Capacity reuse still checks cancellation; growth still admits the
old-plus-new peak and actual allocator capacity. Refusal/cancellation publishes no
plan or session, releases construction-owned memory through normal lifetime, and
does not reset cumulative work. The existing caller-owned outer resource lease
continues to own source-budget refunds; this component does not add a refund or
change any quota.

`FrontendExclusiveJobBufferTests` measures the public beginEvaluation N/2N path
separately from compile, then verifies unchanged retained source and exact ordered
IR. It also covers both job kinds through nested invocation expansion, reuse and
growth accounting, peak refusal, prestart/post-admission cancellation, explicit
owned-capacity release and the unchanged general COW reservation. Central focused
red/green and full-PEX preparation retain the original caller work/byte ceilings.

### Exclusive circuit-instance construction buffer

`BoundedFrontendNetlist` is a noncopyable construction owner local to
`NetlistLoweringSession.lower`. Emitters receive only an `inout` borrow. Its private
`instances` array is initially empty and never extracted, copied into another
array, captured by a callback, or published while append remains possible.
`build` consumes the builder, resolves forward branch names, replaces individual
immutable `Instance` values, and publishes the array once in immutable `CircuitIR`.
Copying an individual instance in that final loop shares only its immutable nested
values, not the outer array backing. No builder survives publication.

| Phase | Owner | Admission and publication |
|---|---|---|
| Append emitted instances | Private noncopyable builder | Narrow `reserveExclusiveInstances` uses existing `MOSStorageBudget.reserveExclusive` |
| Resolve forward/deferred branch references | Consuming builder | Indexed replacement only; no outer array copy or append |
| Published circuit, copied/read circuit values | Immutable `CircuitIR` | No further mutation through the builder; ordinary caller COW semantics remain |

This proof applies only to the outer instance array. Node/branch/reference arrays,
instance-index dictionaries, scalar memoization and every other generic reservation
keep conservative COW accounting. Exclusive reuse checks cancellation without
charging retained capacity again. Growth still preadmits old-plus-new capacity,
charges actual allocator capacity, preserves peak accounting and consumes work;
release never refunds cumulative work. The frontend adds no resource owner,
quota reset or outer lease refund. Failure publishes no circuit and poisons the
existing evaluation session under its established failure contract.

`FrontendExclusiveInstanceBufferTests` owns the focused checks. N=256/512 helper
admissions attribute geometric backing-growth work to the exact helper called by
the production builder. The complete public `beginEvaluation -> lower -> finish`
path separately measures whole-path work and verifies exact source, ordered
instances, parameters, ports and immutable result sharing. It does not infer
linear total lowering work while unrelated conservative reservations remain.
Further checks cover reused-capacity polling, old-plus-new peak refusal, charged
work after release, prestart/post-admission cancellation, public no-publication
failure, unchanged generic shared-array COW, forward controlled-source references
and source-deferred mutual-inductor references. The parent owns central red/green
execution and actual full-circuit preparation within the unchanged caller budget.
