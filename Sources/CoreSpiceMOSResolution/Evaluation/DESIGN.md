# MOS Invocation and Evaluation

## Purpose and Scope

Parent: [Resolution](../DESIGN.md). This component owns immutable concrete
invocation environments and the shared noncopyable evaluation session. Declaration
construction and geometric model selection belong to their respective components.
No children.

## Responsibilities and Boundaries

Declarations are never duplicated per X invocation. An invocation graph associates
each caller-provided UInt64 identity with a lexical scope, an exact caller identity,
and explicit actual occurrences. The graph is the sole parameter environment;
requests do not carry binding overrides. Both input profiles use the same numeric
and function evaluation rules.

## Related Designs

| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [Values](../../CoreSpiceMOSContracts/Values/DESIGN.md) | depends on | IDs, limits, typed failures | Checked retained payload | No implicit unlimited budget |
| [Declarations](../Declarations/DESIGN.md) | depends on | Immutable snapshot identity and ordered bindings | Shared declaration storage | Preserve all source occurrences |
| [Selection](../Selection/DESIGN.md) | coordinates with | Shared session operations | Model/instance evaluation and selection | Selection never owns another RNG or binding cache |
| [Frontend](../../CoreSpiceLowering/Frontend/DESIGN.md) | used by | Program/binding evaluation and package scalar operators/builtins | Runtime expression constant leaves share arithmetic and RNG authority | No separate random owner |

## Architecture

```text
immutable declaration snapshot + ordered concrete invocations
    -> checked immutable invocation graph
    -> exclusive noncopyable session
       <- non-MOS binding/program evaluation
       <- MOS selection
    -> immutable values or terminal typed failure + bounded diagnostic
```

## Contracts and Invariants

Invocation IDs are unique; callers precede their children and only the declared
root lexical scope may have no caller. Graph construction preserves invocation and
explicit-actual source order. Ordered scope defaults are merged last-wins, then
unique explicit actual symbols replace or add final entries. Actual symbols need
not have a header/body declaration. Duplicate explicit actuals are rejected in both
profiles. Final bindings retain optional declaration binding identity and source;
actual values retain a snapshot program or a checked finite constant; program
actual self-reference retains the exact caller invocation identity when a caller exists.
Root actuals provide global overrides without duplicating the snapshot; their
self-reference has no caller redirect and is rejected as a normal binding cycle.

`maximumInvocations` and `maximumInvocationBindings` separately bound concrete
environments; they do not reuse lexical-scope or declaration-binding limits.
`maximumFunctionDepth` bounds runtime call chains independently of AST depth.

Numeric lookup visits the current invocation and its exact caller ancestry. Only
an explicit actual's own symbol redirects to the caller. Other references see the
final child environment. Function formals have first priority. Entering a named
binding clears function formals and evaluates in that binding owner's invocation.
Model/function declaration lookup follows lexical scope ancestry; the selected
declaration scope maps to its concrete owning invocation. Nonlexical caller models
and functions do not leak. Function bodies use callsite numeric invocation, while
nested function names use the function declaration's lexical scope.

Operands and function arguments evaluate left-to-right. Arguments are eager even
when their formals are unused. Conditionals evaluate only their selected branch;
logical AND/OR short-circuit. The versioned CoreSpice PRNG and explicit root-call
order are part of evaluation provenance, not an ngspice RNG/macro compatibility
claim. No implicit temperature parameter exists on this numeric path.
The shared builtin arithmetic law distinguishes `pwr(x,y) = abs(x)^y` from
`pwrs(x,y)`, which negates that magnitude when x is negative. Frontend static
capture and scalar programs consume this same law.

## Runtime Flows

The session installs the incoming opaque diagnostic identity and resets geometry
and candidate detail before checking seed, snapshot-local IDs or other request
conditions. It checks snapshot/graph identity, seed, profile, semantic request
identity and schema admission before applicable cached values can be reused.
Semantic request identity excludes retained-capacity accounting metadata.
Every lexical-scope and concrete-caller hop on evaluation/selection owner lookup
consumes the session work budget. Final result validation synchronously borrows
that same ledger through `withValidationBudget`; failures poison the session. Binding memo keys
are (owning invocation, symbol); model keys are (declaration-owning invocation,
declaration, profile). Supplied instance expressions are cached by complete request
identity. Program IDs alone are not memo keys: distinct semantic slots may share
one random expression program without sharing its draw.

Public binding/program roots, including cache hits, are retained in a bounded
ordered `MOSRootVisit` buffer under the same work/storage/cancellation ledger.
`finishProvenance()` consumes the session and transfers seed, PRNG/evaluator
versions, draw count and roots, so no shared trace array can race a later mutation.
The evaluator uses an explicit bounded work stack. Visiting bindings/functions
detect cycles. A failure after any random draw is terminal and cannot retry.

## State, Ownership, and Lifecycle

The graph is a final immutable Sendable class sharing the immutable snapshot.
The session is noncopyable and exclusively borrowed by synchronous inout calls;
it is not a shared mutable Sendable owner. Native, WASM and Embedded use the same
storage and entry points, without target-dependent synchronization branches.

| State | Storage owner | Entry points | Release |
|---|---|---|---|
| Graph | immutable class | checked constructor/read accessors | last strong owner |
| Memo/RNG/work/diagnostic | exclusive session | synchronous inout operations | session lifetime |
| Snapshot | immutable class shared by graph/session | checked accessors | last strong owner |

## Failure, Concurrency, and Constraints

Graph construction charges source text, occurrence arrays, final bindings, indices,
scratch capacities and work before retaining/growing them using MOSStorageBudget.
The counted payload metric follows Values. Caller depth and graph cardinality are
explicitly bounded. Failed construction publishes no graph.

The first evaluation failure poisons the session. Later operations return
poisonedSession without retrying, drawing randomness, or publishing partial
success. A bounded read-only diagnostic retains instance/source, invocation/scope,
model reference, evaluated geometry, shared snapshot candidate ranges/reasons and
the cause. Diagnostic detail obeys maximumDiagnosticBytes; exhaustion retains a
minimal preadmitted header/reference and static truncation flags without another
allocation attempt.

## Verification and Change Impact

MOSInvocationTests owns distinct repeated/nested caller identities, final-default
precedence, undeclared actual symbols, duplicate rejection, numeric caller lookup,
lexical model/function isolation, invalid IDs/ancestry, cancellation and source/
capacity limits. Evaluation tests own shared memo/random draws, function frames,
short-circuiting, cycles, poison and diagnostic behavior. Selection tests consume
these contracts without inspecting session internals. Root owns build and target
verification; constructor tests alone do not qualify numerical MOS execution.

## Evaluator and Selector Collaborator Contract

The graph, session and evaluator implement the following synchronous collaborator
contract. Selection consumes these operations without accessing mutable internals.

* `MOSEvaluationSession(snapshot:graph:seed:limits:control:)` owns checked identity,
  a versioned random generator, storage/work ledgers, caches and terminal failure.
* `evaluateMOSBinding(symbol:invocation:from:session:) -> Double` and
  `evaluateMOSProgram(program:invocation:lexicalScope:from:session:) -> Double` are
  checked public free functions; non-MOS consumers use these same operations.
* Package `beginRequest(_:from:)` validates request and initializes the preadmitted
  attempt header; it pins profile on first MOS request and rejects changed seed,
  snapshot, graph, invocation/scope or full reused-instance request conditions.
* Package `cachedInstance(for:)` / `storeInstance(_:for:)` reuse complete admitted
  request keys and finite supplied values without re-evaluation.
* Package `cachedModel(declaration:invocation:profile:)` /
  `storeModel(_:declaration:invocation:profile:)` retain canonical coefficient
  values. Selection validates schema identity/release through its provider on
  every resolve before consulting this cache.
* Package `spend(_:units:)` and checked buffer reservation share the session's
  mandatory live-capacity/work limits and cancellation controller. Selection
  cannot reset a budget or reserve unchecked temporary buffers.
* Package attempt updates record evaluated raw/normalized/selection geometry and
  candidate snapshot range plus bounded dispositions. `poison(_:)` preserves the
  first cause and closes every evaluation/selection entry point.
* Read-only session counters expose cumulative steps, random draws and retained/
  peak capacity; `failureDiagnostic` remains readable after poison.

Implemented synchronous signatures (all fallible methods throw
`MOSResolutionFailure`):

```swift
public struct MOSEvaluationSession: ~Copyable
public func evaluateMOSBinding(_ symbol: MOSSymbolID, invocation: UInt64,
    from snapshot: MOSDeclarationSnapshot, session: inout MOSEvaluationSession) throws -> Double
public func evaluateMOSProgram(_ program: MOSProgramID, invocation: UInt64,
    lexicalScope: MOSScopeID, from snapshot: MOSDeclarationSnapshot,
    session: inout MOSEvaluationSession) throws -> Double

// Package session operations used by Selection.
mutating func beginRequest(_ request: MOSResolutionRequest, from snapshot: MOSDeclarationSnapshot) throws
mutating func cachedInstance(for request: MOSResolutionRequest) throws -> [MOSNumericParameter]?
mutating func storeInstance(_ values: [MOSNumericParameter], for request: MOSResolutionRequest) throws
mutating func cachedModel(declaration: MOSDeclarationID, invocation: UInt64,
    profile: MOSInputProfile) throws -> [MOSNumericParameter]?
mutating func storeModel(_ values: [MOSNumericParameter], declaration: MOSDeclarationID,
    invocation: UInt64, profile: MOSInputProfile) throws
mutating func spend(_ kind: MOSResolutionWork, units: UInt64) throws
mutating func reserve<Element>(_ buffer: inout [Element], required: Int) throws
mutating func releaseStorage<Element>(for buffer: [Element]) throws
mutating func recordGeometry(raw: MOSInputGeometry?, normalized: MOSNormalizedGeometry?,
    selection: MOSSelectionGeometry?)
mutating func recordCandidates(_ range: Range<Int>, family: Bool) throws
mutating func recordCandidate(_ candidate: MOSCandidateEvidence)
mutating func poison(_ cause: MOSResolutionFailure)
```

`reserve` owns the caller's temporary buffer capacity charge until releaseStorage.
Cache storage charges its own immutable retention boundary; callers release their
temporary charge after store or failure. Candidate ranges refer to the shared
snapshot's exactDeclarationIDs/familyDeclarationIDs. Diagnostic dispositions are
bounded separately from result evidence; recordCandidate truncates detail rather
than fabricating a candidate or silently changing selection. Attempt updates and
poison never attempt fresh allocation after resource exhaustion.

Session publicly exposes immutable `snapshot`, `graph`, `seed`, `limits`, optional
`profile`, `evaluationSteps`, `randomDraws`, `retainedBytes`, `peakOwnedBufferBytes`
and `failureDiagnostic`; package collaborators do not access cache/RNG internals.

Result construction passes `snapshot.identitySpace`. Inspection checks exact token
identity before any ID dereference and requires the shared snapshot to remain
alive; the identity token alone does not retain declaration/source tables.

Selection evaluates active-card coefficient assignments in source order, including
assignments overwritten through canonical aliases. Strict rejects duplicate exact
symbols/canonical IDs; pinned retains the last canonical assignment. Later cards
discarded by FIRST model-declaration authority are not evaluated. Source
occurrences remain in the snapshot.

## Designed Scalar Temperature Dependency

Status: proposed. The shared [Environment contract](../../CoreSpiceEvaluationContracts/Environment/DESIGN.md)
is the authority for builtin temper, condition roots, freeze and identity. This
component continues to own all scalar execution, memoization, RNG and poisoning.
Implement the condition-graph phase in this engine, not in a second IO evaluator.
Preserve validated dependency results and PRNG state through the consuming freeze;
record evaluator-V2 visitation and revalidate existing MOS/resistor callers.

## D2 Bootstrap and Freeze Implementation Contract

MOSEvaluationBootstrapSession exclusively owns one MOSEvaluationSession. Consuming
freeze evaluates ambient then nominal roots through the existing interpreter and
returns that same owner, including binding memo, PRNG, diagnostic reserve and work
ledger. It creates no second interpreter or RNG. Root inputs are checked Kelvin
values or snapshot-owned expression programs. The frozen environment is immutable.
Before ambient completes, reaching builtin temper is a condition cycle; nominal
may read the completed ambient. Function formals precede builtin lookup. Binding
declarations/actuals named temper are reserved and refused; absent time/hertz are
explicit unsupported scalar variables. Failure poisons the existing session.

Provenance records evaluator V2, ordered condition roots and exact environment.
Condition-cycle diagnostics retain bounded active binding dependencies; diagnostic
capacity is reserved by the same session owner. Plain source-free resolver sessions
have no environment and refuse temper. Frozen sessions stamp resolved MOS values;
MOS preparation identity rejects conditions that differ from that stamp.

ConditionEvaluationTests owns memo/random continuity, direct/indirect cycles, formal
shadowing, reserved names, invalid temperature, work/storage/cancel and poisoning.
Native/WASM/Embedded probes use the same stored state and access implementation.

Condition source is admitted into the already reserved diagnostic capacity before
executing its root. It is cleared after successful freeze. Oversized path/capture
text sets truncation and cannot increase the diagnostic budget. Source location and
active binding path remain separate fields.

## Immutable Provenance Payload Capacity

The completed `MOSEvaluationProvenance` retains only inline environment/seed/counters,
version text and the actual-capacity ordered root-visit buffer. Its package-only
`retainedPayloadByteCount()` reports that dynamic payload using the shared checked
buffer-capacity and UTF-8 accounting convention. It does not inherit the consumed
session's snapshot/graph, memo caches, candidate/condition diagnostic reserve, or
interpreter storage. Existing session `retainedBytes` remains an execution-ledger
statistic and is not the capacity of this immutable result.

This measurement performs no allocation or copy. A caller retaining the value
outside the active session admits its inline header separately and owns the
reported buffer/text payload for the result's lifetime. Session construction,
source evaluation and failure diagnostics retain their existing complete admission.
`ImmutableProvenanceStorageTests` in Lowering verifies actual root capacity and
independence from diagnostic policy through real session completion.
