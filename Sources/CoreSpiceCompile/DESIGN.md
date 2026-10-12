# CoreSpiceCompile

## Purpose and Scope

This SwiftPM module owns sparse topology and numerical compile products. Parent: [CoreSpice](../../DESIGN.md). This module has no newly introduced child components.

## Responsibilities and Boundaries

Compilation consumes canonical node and branch connectivity and validates prepared MOS receipts before constructing sparse topology. It does not prepare devices or infer compact-model auxiliary topology.

## Related Designs

| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [CoreSpice](../../DESIGN.md) | parent | Package composition | Owned module boundary | Revalidate direct consumers when contracts change |
| [IR MOS instances](../CoreSpiceIR/MOSInstances/DESIGN.md) | depends on | Prepared stage | Sole MOS value authority | Reject resolved or absent stage |
| [Preparation contracts](../CoreSpiceMOSContracts/Preparation/DESIGN.md) | depends on | Receipt identity and topology | Portable admission evidence | No Devices dependency |

## Architecture

```mermaid
flowchart LR
    Input[Typed inputs] --> Owner[CoreSpiceCompile]
    Owner --> Output[Validated outputs or typed failure]
```

## Contracts and Invariants

All physical, owned auxiliary, and referenced node pairs receive the required local CSR entries. Auxiliary variables have ordinary MNA indices and are never collapsed into physical ports.

MOS types nmos/pmos and their l1/l2/l3/l49/l54 forms require prepared stage.
The exact receipt release and polarity must match the type, and receipt instance
identity must match Instance.name. Four physical ports, exact private auxiliary
count, node inventory membership, and private ownership are checked before sparse
construction. Resolved stage and generic legacy model/parameter dictionaries do
not admit MOS compilation. Non-MOS compilation retains its existing algorithm.

```text
Instance.mos -> type/release/polarity/identity/topology admission
             -> MatrixTopology -> ExecutionPlan
```

## State, Ownership, and Lifecycle

Compiled topology is an immutable Sendable value. Runtime sparse matrices are exclusively mutated by the analysis.

## Failure, Concurrency, and Constraints

Compilation returns typed CompileError for missing or resolved MOS stage, mismatched identity/type, or invalid topology. Device binding separately validates its receipt against the numerical owner before execution.

## Verification and Change Impact

MOS stage admission tests exercise actual compile success and refusal for legacy/resolved stages, identity/type mismatch, and malformed topology. Existing integration tests inspect required BSIM3 local sparse entries and execute CPU SparseLU on series/NQS circuits. Revalidate device binding and analyses when topology changes.

The portable release no longer owns execution admission. Compiler validates
prepared receipt level, identity and topology; NativeMOSDevicePreparer owns
supported numerical releases and explicitly rejects BSIM4 4.5.0 until adoption.

## D3 Change Impact

The [D3 resolution owner](../CoreSpiceLowering/DiodeResolution/DESIGN.md) defines occurrence admission, frozen
evaluation, immutable result transport and explicit numerical refusal. This layer
consumes that contract; D4 numerical preparation and D5 downstream adoption remain
separate. Its affected production path and behavioral tests are verified in D3.
