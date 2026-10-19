# CoreSpiceDevices

## Purpose and Scope

This SwiftPM module owns native electrical device binding and stamping. Its
parent is the [CoreSpice package](../../DESIGN.md), and its device implementation
children are [ContinuousEquationStructure](ContinuousEquationStructure/DESIGN.md), [Devices](Devices/DESIGN.md), [MOSPreparation](MOSPreparation/DESIGN.md), and
[output-referred noise](OutputReferredNoise/DESIGN.md), [Diode](Diode/DESIGN.md),
[TransientLifecycle](TransientLifecycle/DESIGN.md), and proposed S4D [NumericalState](NumericalState/DESIGN.md).

## Responsibilities and Boundaries

Descriptors validate model parameters and bind IR terminals to compiled indices.
Bound devices own physical currents, derivatives, capacitances, and accepted-step
history. Analyses own Newton iteration, factorization, timestep acceptance, and
typed numerical failures; devices never label an analysis successful.

## Related Designs

| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [CoreSpice](../../DESIGN.md) | parent | Simulation domain | Package composition | Native evidence does not qualify a foundry model |
| [ContinuousEquationStructure](ContinuousEquationStructure/DESIGN.md) | child | Package-only actual bound F/Q support, native R/C/V coefficient bits and source value-law facts | Structural and represented-law composition input | No rank/root/jet/history authority |
| [Devices](Devices/DESIGN.md) | child | Descriptors and bound devices | Physical models | Current and Jacobian must change together |
| [Diode](Diode/DESIGN.md) | child | Checked exact/generic input and consuming preparation | Diode ownership boundary | Generic numerical graduation remains separate |
| [MOSPreparation](MOSPreparation/DESIGN.md) | child | Single-owner preparation and consuming binding | Approved S3 boundary | Runtime evidence remains migration-owned |
| [Output-referred noise](OutputReferredNoise/DESIGN.md) | child | Correlated spectrum composition | Full-node gain input | Success does not imply qualification |
| [NumericalState](NumericalState/DESIGN.md) | child | Proposed compensated SolutionState views | S4D numerical representation | Cross-owner D1 freeze precedes implementation |
| [TransientLifecycle](TransientLifecycle/DESIGN.md) | child | Sessions and original F / alphaDeltaQ capabilities | Accepted history and independent equation contribution | Complete-circuit composition owns admission and bounded row buffers |
| [ParsedIR](../CoreSpiceParsedIR/DESIGN.md) | coordinates with | Original model and instance source roles | Resistor declaration provenance | Unused declaration acceptance is not execution admission |
| [Lowering](../CoreSpiceLowering/DESIGN.md) | used by | Device preparation and supported parameter roles | Canonical model/instance values and runtime dependencies | Model values must not be flattened into instance overrides |
| [Analysis](../CoreSpiceAnalysis/DESIGN.md) | used by | Fallible stamps and noise admission | Numerical execution and current PSD consumption | Unsupported requested noise cannot disappear from a successful result |

## Architecture

```mermaid
flowchart LR
    IR[Instance / compiled topology] --> Registry[DeviceRegistry]
    Registry --> Descriptor[DeviceDescriptor.bind]
    Descriptor --> Bound[BoundDevice]
    Bound --> Stamps[DC / AC / transient stamps]
    Stamps --> Analysis[CoreSpiceAnalysis]
    Analysis --> Commit[Accepted transient step]
    Commit --> History[TransientCapacitanceStore]
```

## Contracts and Invariants

`DeviceRegistry.standard()` selects concrete descriptors. Binding reports invalid
parameters through `DeviceBindingError`. L3 DC current residuals and AC real stamps
share the same derivative. Transient stamping combines that current with the
selected integration companion, and commits history only after acceptance.

## State, Ownership, and Lifecycle

The [resistor execution contract](Devices/DESIGN.md#resistor-execution-contract)
is the authority for the implemented ideal and static model-backed R boundary
and the target runtime resistor profile in B8.6.5.4. This module composes that child through the existing
registry and BoundDevice/noise interfaces. Declaration parsing, device admission,
and process-model qualification are separate completion claims. The target
runtime contract is not a statement that the current implementation supports
voltage-dependent R; that binding path remains an explicit refusal.

L3 parameters and topology are immutable after binding. The bound device owns a
`TransientCapacitanceStore` whose accepted currents use `Mutex`; its read and
mutation paths are common across targets without conditional synchronization.
No external callback or I/O runs while the history lock is held.

## Verification and Change Impact

The [L3 behavioral suite](../../Tests/CoreSpiceDevicesTests/MOSL3ConsistencyTests.swift)
owns current, derivative, polarity, capacitance, registry, and analysis evidence.
Changes to stamping require revalidation of DC/AC/transient analyses and the
parent contract; parser/lowering model-level selection remains unchanged.

## Fallible execution and transient sessions

BoundDevice DC/AC/transient stamps and accepted-step commits are throwing protocol
requirements. Existing nonthrowing implementations satisfy those requirements.
TransientSessionDevice begins history from an initial SolutionState and ends it
on every analysis-scope exit. NoiseAnalysisAdmissionDevice rejects unsupported
noise before a result can be labeled successful. NoisyDevice contributes
fallible current PSDs through the checked noise contract owned by
[Analysis](../CoreSpiceAnalysis/DESIGN.md).

## Compact-model boundary

Native BSIM3/BSIM4.5/BSIM4.8 components and registry entries are removed.
[MOSPreparation](MOSPreparation/DESIGN.md) prepares classic L1/L2/L3 only and
has no BSIM release or schema cases. Source admission rejects legacy BSIM
selection before native preparation. Compact-model execution uses
[CoreSpiceOSDI](../CoreSpiceOSDI/DESIGN.md) with exact compiled model artifacts;
no simplified native fallback or version reinterpretation is provided.

## Atomic Private-Node Binding

Status: approved S3 implementation target. BindingContext owns invocation-local,
synchronously mutated compiled-variable and ownership-claim state. It performs no
I/O or await. This module owns the claim transaction; MOS-specific identity, CSR
and IC admission belong to [MOSPreparation](MOSPreparation/DESIGN.md).

```text
validate all proposed owned nodes -> complete all other fallible binding work
    -> nonthrowing commit of validated claims -> publish complete bound device
```

`validateOwnedNodes(for:)` checks the entire proposed set without mutation: no
ground, physical-port alias, duplicate within the proposal, previously claimed
node, missing compiled node voltage or out-of-range matrix index. After successful
preflight the single synchronous caller performs all remaining fallible work and
constructs the complete bound device. `commitValidatedOwnedNodes(for:)` is an
internal/package nonthrowing operation invoked only at that final point. No await,
callback or competing context access intervenes between preflight and commit.

`claimOwnedNodes(for:)` itself uses complete preflight followed by commit, so its
throwing interface cannot leave a partial claim. MOS consuming binding uses the
split phases to avoid claims before CSR/IC/owner construction succeeds. Do not
copy the whole context as rollback: repeated Set COW would make binding quadratic
in total device count. The claimed-node set grows once for each successful claim.

Binding tests must show that a valid first node followed by an invalid/duplicate
node leaves both unclaimed, that failed CSR/IC checks claim nothing, and that a
later valid bind can claim the same nodes. Existing successful duplicate-ownership
refusal remains.

Explicit branch proposals use the same preflight/commit transaction through
`validateOwnedBranches(for:)` and `commitValidatedOwnedBranches(for:)`: every
proposed branch must have a unique, in-range compiled current variable and must
not already be claimed. OSDI binding preflights both sets, completes fallible
mapping and construction, then commits both sets without intervening callbacks.
Legacy `claimBranch(for:)` retains its individual fallback allocation contract.
The context is invocation-local and is never shared across concurrent binders.

### Finite Pole-Zero Applicability

`BoundDevice.poleZeroStampApplicability` is a device-owned declaration that the
entire fixed-bias matrix is exactly the affine pencil `G + s*C`. Its default is
an explicit unsupported reason. Pole-zero analysis admits all devices before
stamping and rejects a non-affine or unestablished realization. Delayed lines
contain `exp(-s*delay)` and require a separate infinite-spectrum method; two
frequency samples do not establish an affine realization. AC analysis retains
its full frequency-dependent stamp contract. Analytic RC/TF and delayed-line
refusal regressions are owned by
[ReleaseNumericalRegressionTests](../../Tests/CoreSpiceAnalysisTests/ReleaseNumericalRegressionTests.swift).

## Designed Diode Preparation Composition

Status: proposed migration. [Diode](Diode/DESIGN.md) is a new direct child and owns
the replacement checked diode preparation/binding/evaluation path. Existing diode
files in Devices remain the current implementation until moved in that unit.
Consume [DiodeContracts](../CoreSpiceDiodeContracts/DESIGN.md) and adapt the shared
[Environment](../CoreSpiceEvaluationContracts/Environment/DESIGN.md) to the existing
OperatingConditions API. That adapter must validate semantic identity rather than
silently choosing a second nominal or operating temperature.

## D2 Operating Conditions

| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [EvaluationContracts](../CoreSpiceEvaluationContracts/DESIGN.md) | depends on | Checked environment identity | D2 temperature meaning | Standard Library only; source policy stays outside this module |

07N replaces generic diode legacy I/G and variable-C history with the exact
[diode-owned numerical and session contract](Diode/DESIGN.md#07n-generic-numerical-law).
The shared capacitance store and unrelated model families remain independent.

## S4 Transient Boundary

[TransientLifecycle](TransientLifecycle/DESIGN.md) owns explicit initialization and fresh candidate-step queries. The existing session protocol adds a requirement with a default witness delegating to the original begin method, preserving existing devices. Accepted step constraints may change after commits and are read before each next proposal; positive infinity denotes no accepted-state limit. Candidate constraints are optional finite positive seconds, queried from a freshly solved full candidate before acceptance. No query publishes native/Q/current history.

## S4 Residual Noise Composition

[ResidualNoise](ResidualNoise/DESIGN.md) owns canonical residual-row source metadata, scoped PSD borrowing and the separate noise matrix stamp requirement. Existing electrical and correlated device contracts remain unchanged.

### Checked Physical History Snapshot

SolutionState keeps its variable map private. An internal checkedPreviousSnapshot factory
uses that same map and requires an explicitly present, finite previous vector of identical
width. Direct physical residual helpers consume this snapshot; absent history is an error
and never substitutes the current candidate. The factory preserves array backing through
Swift value semantics and exposes no mutable map authority.
