# Initial Condition Node Binding

## Purpose and Scope

Parent: [CoreSpiceIO](../DESIGN.md). No children. Own conversion of retained initial
condition and nodeset assignments to actual CircuitIR nodes and finite voltages.
This component does not apply voltages, choose analysis, or execute numerical work.
The S4 implementation status is tracked by the package PROGRESS.md.

## Responsibilities and Boundaries

The protocol-first resolver consumes compiled assignments and the caller's exclusive
Lowering session. It owns node/ground/ambiguity validation; scalar programs, RNG,
slot memoization and final provenance remain Lowering-owned. Ordinary and bounded
callers share this scalar authority. No local evaluator, retry or literal fallback
can bypass a failure.

## Related Designs

| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [IO](../DESIGN.md) | parent | Static intent composition | Shared CLI/host intake | Application remains analysis-owned |
| [Frontend](../../CoreSpiceLowering/Frontend/DESIGN.md) | depends on | Compiled identity, canonical slots and exclusive session | Sole expression/RNG authority | Semantic failures poison before returning |
| [IR](../../CoreSpiceIR/DESIGN.md) | depends on | CircuitIR and Node | Actual node identities | Ground aliases use actual circuit ground |
| [ParsedIR](../../CoreSpiceParsedIR/DESIGN.md) | depends on | Resource accounting and accounted collection | Bounded output ownership | Input backing is retained by compiled source |
| [CLI](../../CoreSpiceCLI/DESIGN.md) | used by | Shared assignment resolver | Broad ordinary analyses | Finish only after required static consumers |

## Architecture

```text
compiled source + exclusive session + emitted CircuitIR
    -> canonical initial-condition / nodeset slot -> same-session scalar value
    -> actual node / ground / ambiguity validation
    -> ordinary dictionary OR source-accounted owned bindings
analysis caller -> applies values or explicitly refuses required intent
```

## Contracts and Invariants

SPICENodeVoltageAssignmentKind selects initialConditions or nodeSets. Public protocol
requirements are resolve(_:compiled:session:circuit:) returning [Node:Double], and
resolveBounded(_:compiled:session:circuit:resources:) returning SPICEOwnedNodeVoltages.
The resolver borrows the noncopyable session inout. It first verifies compiled
storage identity, then reads assignments only from compiled.source; callers cannot
substitute another dictionary under an existing compiled identity.

Available matching control ordinals determine source order, with deterministic
case-normalized key order only for manually constructed dictionary-only ParsedIR.
The final parsed assignment is authoritative for repeated case-normalized spelling.
The iterator takes both name and value directly from that final control, including
controls-only manually constructed input. An absent or stale dictionary projection
cannot omit the control or change its scalar capability. Dictionaries provide only
keys without a matching control, in deterministic fallback order.
Canonical dictionary/control slot aliases share memo identity, so a second consumer
cannot draw again. Distinct semantic slots retain distinct draws.
Hand-built dictionary aliases with different ParsedParameterValue inputs fail in
the compiler before evaluation; identical inputs share one canonical scalar slot.

Node names and ground aliases 0/gnd are matched against actual emitted circuit
identities. Unknown nodes and nonzero ground fail. All voltages must be finite.
Bounded ASCII name traversal avoids normalization buffers; unsupported Unicode
remains an explicit capability failure. Bounded colliding circuit names for distinct
nodes or conflicting voltages for aliases of one node fail as ambiguous; identical
alias values coalesce. Ordinary Unicode case handling and alias overwrite capability
remain available, with the explicit source/fallback traversal order determining the
last applied assignment rather than an unrecorded dictionary iteration order.

Scalar evaluation errors preserve their actual cause. External node/ground/value
validation failures poison(.invalidRequest) before propagating the typed node error.
A failed resolver cannot leave a session able to emit, evaluate or finish success.
Bounded diagnostics use input indexes rather than uncharged derived input strings.

## State, Ownership, and Lifecycle

The resolver is stateless and Sendable. The caller retains compiled input and owns
the exclusive session; no escaping closure retains a borrow. Ordinary dictionaries
are caller-owned and make no source-accounted storage claim. Bounded output uses
SPICEAccountedCollection capacity receipts through final-copy release. A later
required dictionary is a separately admitted materialization.

| State | Storage / isolation | Read / mutation | Release |
|---|---|---|---|
| Resolver | Stateless value, same host branches | Protocol requirements | Call scope |
| Scalar state | Exclusive noncopyable session | Synchronous inout operation | Consuming finish or failure cleanup |
| Bounded output | Accounted immutable snapshot/COW slots | Checked collection append | Last copied owner |
| Resource counters | Injected synchronized owner | Reserve/check outside collection mutation | Receipt callback |

No target branch changes storage, synchronization or Sendable contracts.

## Failure, Concurrency, and Constraints

Check cancellation and charge traversal before assignment, node-name byte,
circuit-node and output comparison boundaries. Scalar work/storage/cancellation
uses the frontend's explicit limits and control. Output growth admits actual capacity
before allocation. A source resource failure preserves the injected cause and
poisons the frontend; no failed conversion publishes owned successful output.
Native evidence does not establish WASM/Embedded execution.

## Verification and Change Impact

Owner: [CoreSpiceInitialConditionTests](../../../Tests/CoreSpiceInitialConditionTests/NodeVoltageResolutionTests.swift).
Prove actual parser last-assignment behavior, same-session parameter/random values,
slot reuse without extra draws, Unicode/case/ground aliases, unknown/nonfinite/
nonzero-ground refusal and preserved evaluation causes. Bounded proof covers name
ambiguity, identical aliases, compile refusal of conflicting canonical inputs,
work/live quotas, cancellation and final
copy receipt release. Invalid external semantics must prevent subsequent finish.
[CLI tests](../../../Tests/CoreSpiceCLITests/AnalysisSetupTests.swift) own actual UIC
application. Changes affect IO/CLI static intake, not solver or waveform algorithms.
