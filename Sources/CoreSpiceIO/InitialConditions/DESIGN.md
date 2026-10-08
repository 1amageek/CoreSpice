# Initial Condition Node Binding

## Purpose and Scope

Parent: [CoreSpiceIO](../DESIGN.md). No children. Own conversion of parsed initial
condition and nodeset assignments to actual CircuitIR nodes and finite voltages.
This component does not apply voltages, choose analysis, or execute numerical work.

## Responsibilities and Boundaries

The protocol-first resolver uses ParsedParameterValue, CircuitIR node names and
ordinary ExpressionEvaluator semantics. CLI and later native hosts consume it
without a second node/ground/expression policy. Ordinary evaluation remains owned
by Lowering; bounded conversion does not claim a generic bounded expression evaluator.

## Related Designs

| Design | Relationship | Contract Used | Cautions |
|---|---|---|---|
| [IO](../DESIGN.md) | parent | Parsed intent composition | Application remains analysis-owned |
| [Lowering](../../CoreSpiceLowering/DESIGN.md) | depends on | ExpressionEvaluator | Ordinary evaluator has no cooperative accounting |
| [IR](../../CoreSpiceIR/DESIGN.md) | depends on | CircuitIR, Node | Ground aliases use actual circuit ground |
| [ParsedIR](../../CoreSpiceParsedIR/DESIGN.md) | depends on | Parsed values, resource accounting, accounted collection | Retain source owner while borrowing inputs |
| [CLI](../../CoreSpiceCLI/DESIGN.md) | used by | Shared node assignment resolution | Existing numerical callers remain unchanged |

## Architecture

```text
parsed assignments + CircuitIR node names
    -> ordinary resolver + ExpressionEvaluator -> node-voltage dictionary
    -> bounded resolver + resource owner -> owned node-voltage binding collection
analysis caller -> applies resolved values or explicitly refuses required intent
```

## Contracts and Invariants

`SPICENodeVoltageResolving.resolve(assignments:circuit:evaluator:)` returns the
ordinary node-voltage dictionary. It preserves existing CLI behavior: lowercase
node names, ground aliases `0`/`gnd`, expression evaluation, finite voltages,
unknown-node and nonzero-ground refusal. Name collisions and repeated aliases
retain existing dictionary-iteration overwrite behavior. Parser-normalized repeated
assignments already retain the last parsed value in ParsedNetlist; this resolver
cannot recover textual order from a dictionary. Evaluation errors retain the actual
underlying cause. CLI maps ordinary failures to its existing invalid-argument text.

`resolveBounded(assignments:circuit:resources:)` returns `SPICEOwnedNodeVoltages`.
It supports numeric values, booleans and literal expressions without invoking the
ordinary evaluator. Nonliteral expressions, unsupported scalar values and Unicode
case normalization explicitly refuse with typed capability errors. Missing bounded
expression/Unicode support is marked on its actual callable refusal branches.
ASCII names compare cooperatively without materializing normalized strings or
hash tables. Ground aliases override ordinary node names. Colliding circuit names
for different nodes and assignments resolving to one node with different values
refuse as ambiguous; identical alias values may coalesce. All supported voltages
must be finite and ground must be zero.

Ordinary and bounded overloads have intentionally distinct capabilities. Neither
silently falls back to the other. Bounded failures use static reasons and numeric
input indexes, avoiding uncharged derived diagnostic strings. Resource errors retain
the actual injected cause. No source acquisition, PDK dependency or host facade exists.

## State, Ownership, and Lifecycle

The resolver is stateless and Sendable. Ordinary dictionaries remain caller-owned,
with no bounded-storage claim. Bounded output uses SPICEAccountedCollection slots;
capacity/work is admitted before allocation, comparisons and writes. Output receipts
remain through last-copy release. Input assignment/expression/node-name backing is
borrowed under the caller's existing immutable owner. Bounded result exports bindings,
not a fabricated accounted Dictionary; any later dictionary materialization is a
separate caller-owned admission boundary. No mutable shared state is introduced.

| State | Storage / isolation | Read / mutation | Release |
|---|---|---|---|
| Resolver | Stateless value, all host branches identical | Protocol requirements | Call scope |
| Bounded output | Accounted immutable snapshot/COW slots | Checked collection writes | Last copied owner |
| Resource counters | Injected owner; native test owner uses Mutex | Reserve/check outside output mutation | Receipt callback |

No conditional compilation changes storage, synchronization or Sendable.

## Failure, Concurrency, and Constraints

Check cancellation at entry, every name byte, circuit/assignment/output boundary and
before publication. Charge actual traversal/comparison work before each step.
Bounded conversion creates no normalization or evaluator scratch allocations.
Output slot growth uses the checked collection's actual capacity-before-allocation
and COW receipts. No evaluator call occurs before capability refusal. Failures
publish no owned successful result. No Embedded/WASM capability is asserted.

## Verification and Change Impact

Owner: [CoreSpiceInitialConditionTests](../../../Tests/CoreSpiceInitialConditionTests/NodeVoltageResolutionTests.swift). Prove ordinary parameter expressions,
Unicode/case/ground aliases, unknown nodes, nonfinite/nonzero ground, real parser
last-assignment behavior and preserved evaluation cause. Bounded tests prove supported
scalar values, identical/conflicting aliases, name ambiguity, nonliteral/Unicode
refusal, cumulative work/live quota, cancellation and final-copy receipt release.
Existing [CLI AnalysisSetupTests](../../../Tests/CoreSpiceCLITests/AnalysisSetupTests.swift) owns actual UIC application and unknown-node failure.
Changes affect CLI assignment intake and future host composition, not solvers,
waveforms, model transport or physical PVT interpretation.
