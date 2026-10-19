# OSDI Binding Values

## Purpose and Scope

Parent: [CoreSpiceOSDIContracts](../DESIGN.md). This component owns validated
selection, resolved instance input, and immutable preparation inspection. No children.
Status: S3 source implemented; focused contract and transport verification is pending.

## Responsibilities and Boundaries

OSDIModelBinding identifies source model name, exact artifact, descriptor index and
expected descriptor name, and model-scoped typed assignments. OSDIResolvedInstance
adds instance-scoped typed assignments and explicit previousState. The host adapter
owns matching that selection to a loaded descriptor and checking metadata.

OSDIPreparationReceipt carries the exact resolved instance, effective Kelvin,
OSDIPreparedTopology and OSDIResolvedParameter facts copied after actual setup.
Its complete immutable value is its comparison identity. The receipt carries no
library, evaluator, executable pointer, callback, provider or load authority.

## Related Designs

| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [Contracts](../DESIGN.md) | parent | Portable dependency boundary | Owns module composition | No host runtime imports |
| [S2 model evaluation](../../../../../swift-osdi/Sources/OSDIContracts/ModelEvaluation/DESIGN.md) | depends on | OSDIParameterAssignment, OSDIPreparedTopology, OSDIResolvedParameter | Foreign type/scope and setup facts | Metadata admission occurs at actual setup |
| [OSDI instances](../../CoreSpiceIR/OSDIInstances/DESIGN.md) | used by | Resolved input and preparation receipt | Stage transport | Receipt cannot restore executable ownership |

## Architecture

```text
exact binding + instance assignments + explicit previousState
    -> OSDIResolvedInstance
        -> host setup using final ambient Kelvin
            -> OSDIPreparationReceipt
```

## Contracts and Invariants

Selection names are nonempty and NUL-free; descriptorIndex is nonnegative.
Assignments keep their caller-provided scalar type and scope. Each list rejects
wrong scope and repeated exact assignment names. Alias equivalence and foreign
parameter-kind admission require actual S2 metadata and are not guessed here.
previousState is explicit and finite. Preparation requires positive finite Kelvin,
previousState.count equal to topology.stateCount and unique parameter index/scope
facts. Every copied effective parameter fact is finite and valid under S2's own
constructor. All source/descriptor/assignment/state/topology/temperature/fact values
participate in exact receipt equality.

Initial source admission uses explicit N instances and `.model name osdi` without
source parameters. The caller's typed catalog supplies all assignments. Source
parameters are rejected by the frontend rather than silently dropped or inferred.

## State, Ownership, and Lifecycle

Values own their arrays and strings through ordinary Swift value semantics.
There is no mutable shared state, runtime session, or retained foreign address.
Explicit previous-state input remains unchanged during every Newton trial; host
execution owns candidate state and final adoption.

## Failure, Concurrency, and Constraints

OSDIIntegrationFailure reports invalid selection, wrong assignment scope, duplicate
assignment, invalid state, invalid temperature, state dimension mismatch and duplicate
effective parameter facts. Constructors reject invalid input; they do not default
or silently coerce it. Executable capacity, loading, callback and analysis-capability
failures belong to the host adapter.

## Verification and Change Impact

Contract tests cover each constructor failure and distinct model/instance same-name
assignments. Receipt equality distinguishes binding, descriptor, typed assignments,
previous state, temperature, topology and effective facts. Host tests additionally
verify that receipts come from real setup and match consumed executable owners.
