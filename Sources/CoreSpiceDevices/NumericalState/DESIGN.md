# Numerical State

## Purpose and Scope

This component owns the S4D compensated scalar representation and the corresponding `SolutionState` views. Parent: [CoreSpiceDevices](../DESIGN.md). No children. This document defines the numerical-state side of D1; D1 is frozen; S4D.7 owns implementation and focused evidence.

## Responsibilities and Boundaries

The state represents an unknown without losing an update smaller than the spacing of its absolute value. It does not evaluate a model, infer a charge law from a Jacobian, choose tolerances, or certify an equation. Analysis owns mutable trial/history vectors; a device receives an immutable view. Model evaluation owns the meaning and error enclosure of its response at that represented state.

## Related Designs

| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [Devices](../DESIGN.md) | parent | SolutionState and bound-device lifecycle | Public state boundary | Existing Double access remains a rounded view |
| [Compensated transient](../../CoreSpiceAnalysis/CompensatedTransient/DESIGN.md) | used by | Normalized pairs and immutable accepted references | Newton and integration retain low components | A low component must survive every history wrapper |
| [Transient lifecycle](../TransientLifecycle/DESIGN.md) | coordinates with | Session initialization and accepted commit | State is published only on acceptance | A trial view never changes accepted native history |

## Architecture

```text
Analysis-owned high[] + low[]
  -> immutable SolutionState (one compiled variable map)
  -> checked compensated scalar access
  -> model-owned precision evaluation

Existing voltage/current/value access -> rounded high component
```

## Contracts and Invariants

A represented scalar is the real sum `high + low` of two finite binary64 values, not the binary64 evaluation of that addition. A pair is normalized by error-free addition followed by renormalization: `high` is the nearest representable projection of the pair and `low` retains its residual. Zero uses canonical positive zero components. Overflow, unsupported underflow handling, nonfinite values, invalid dimensions, and nonnormalized externally supplied pairs fail explicitly. Implementations must verify the arithmetic assumptions used by error-free transformations; fast-math reassociation is incompatible with this contract.

The proposed compatible `SolutionState` extension carries optional current, previous, and two-previous low-component arrays alongside its existing high arrays. Absence means the exact zero low vector, preserving legacy callers without allocating zero storage. A present low vector has exactly the corresponding high-vector dimension and the same variable map. No history low vector may exist without its high vector. Precise initialization validates finite normalized pairs before device evaluation.

Existing scalar accessors return the rounded high projection. New checked compensated access returns both components; ground is exactly `(0, 0)`. A precision-admitted device must use the compensated accessor for every state-dependent contribution. It may use the rounded projection only under a model-owned enclosure covering the discarded low value. In particular, `F(high) + G(high)*low` alone is not evaluation of the original nonlinear model.

`checkedPreviousSnapshot` and every reconstructed history view preserve both arrays and the exact compiled identities. A checked difference computes the expansion of two represented scalars without first rounding either absolute scalar or their difference. Adding a Newton correction, scaling it by damping, subtracting two histories, and forming LTE linear combinations preserve the low residual through normalized expansion operations.

## State, Ownership, and Lifecycle

The mutable arrays belong to one numerical run/solve. `SolutionState` is an immutable Sendable snapshot/view using the existing Swift array ownership mechanism. It does not acquire a second synchronization domain or own foreign memory. Current and accepted arrays cannot alias mutable candidate storage. A callback cannot retain a borrowed pointer past its documented call scope.

| State | Owner | Mutation boundary | Lifetime |
|---|---|---|---|
| Current high/low vectors | Analysis run | Accepted rotation only | Run |
| Trial high/low vectors | One Newton solve | Compensated update/limiting | Trial |
| SolutionState | Caller value | Immutable | Evaluation call or retained immutable snapshot |
| Native history | Device/session owner | Accepted commit | Acquired session |

Native, WASM and Embedded use identical value/storage declarations. This state introduces no shared mutable singleton. Existing budget/session `Mutex` owners remain unchanged across targets.

## Failure, Concurrency, and Constraints

Legacy devices are not silently admitted to a precision-requested operation. Composition must prove all requested contributions either consume the pairs or supply a sound error enclosure. Missing capability is a typed failure before sessions/stamps. Invalid pair input is not Newton nonconvergence and must not trigger timestep retry. Pair storage has two scalar slots per coordinate and is admitted before allocation; no pair materialization is allocated per coordinate or iteration.

## Verification and Change Impact

Planned component tests reconstruct exact represented sums with an independent higher-precision oracle, detect lost sub-ULP increments and nonnormalized input, preserve previous/two-previous low arrays, test ground/private variable identity, and falsify rounded-only device access in a precision-admitted fixture. Cross-target compile/link and arithmetic runtime evidence must be scoped to the fixed toolchain/platform. Analysis and model/runtime owners must revalidate when representation, normalization, or access changes.

## S4D C7 API Seam

The proposed concrete public value is `CompensatedValue`, with immutable `high: Double` and `low: Double`, checked `init(high:low:) throws`, and `.zero`. Construction validates the normalized pair; arithmetic helpers normalize their output without collapsing the represented real sum. Its arithmetic implementation owns no model evaluation or numerical tolerance.

`SolutionState` retains its existing high-array names and adds trailing optional initializer inputs/properties `variableLowComponents`, `previousVariableLowComponents`, and `twoPreviousVariableLowComponents`, each `[Double]? = nil`. Nil is an exact zero low vector. New checked accessors are `checkedCompensatedValue(at:)`, `checkedCompensatedVoltage(at:)`, and `checkedCompensatedCurrent(through:)`, returning `CompensatedValue`. Existing checked/unchecked Double accessors retain their rounded projection semantics. Precise run admission performs whole-vector validation once; element access still validates identity/index as required by the existing checked boundary. `checkedPreviousSnapshot` preserves its corresponding low array.

`IntegrationState` gains trailing `timeStepLowComponent: Double = 0` and `previousTimeStepLowComponent: Double? = nil`; a nonnil previous high with nil previous low denotes zero low. Its new `compensatedTimeStep` and optional `compensatedPreviousTimeStep` views retain both components. Existing `coefficient` remains a rounded ordinary-lane convenience and must not implement the precise residual denominator.

The scheduler selects existing binary64 absolute endpoints, represented exactly as `(time, 0)` in precision requests. There is no accumulated low absolute clock or arbitrary sub-ULP scheduling. The precise interval is the exact expansion difference of the selected candidate and accepted endpoints. Thus `timeStep + timeStepLowComponent` is the actual interval used for DeltaQ division, while `currentTime` remains the selected exact binary64 endpoint. Model adapter requests provide explicit zero endpoint lows and preserve original endpoint contexts. The ordinary scheduler/IntegrationState construction remains unchanged outside the precision lane.

## Bound Adapter Identity Read

`SolutionState.checkedBoundCompensatedValue(at:for:)` exposes the existing private
binding-identity check together with the checked paired read. A consumer supplies
both its prebound index and the original `MNAVariable`; same-width row swaps,
node/branch substitution, missing identities and out-of-range storage fail through
`SolutionStateAccessError`. The operation then validates low-array dimensions,
finite components and normalization through `checkedCompensatedValue(at:)`.
Missing lows remain exact zero. It never infers identity from equal sample values
or exposes the private variable map. Ground is read through
`checkedCompensatedVoltage(at: .ground)` without an implicit bound row.

[BoundCompensatedStateTests](../../../Tests/CoreSpiceDevicesTests/BoundCompensatedStateTests.swift)
owns wrong-row, node/branch, same-width swap, ground, finite/pair/dimension and
zero-low behavior. The OSDI adapter's precise gather must retain its admitted
typed identities and use this operation for every non-ground active input.

## Arithmetic Error Ownership

Compensated iterate arithmetic may round a new iterate to two components; its original equations are independently evaluated at that represented point. Physical arithmetic uses `CompensatedEnclosure`. Addition retains large cancellation with a TwoSum expansion and bounds only discarded tails. Multiplication sums all four high/low FMA TwoProducts; one least-subnormal per nonzero product encloses FMA residual underflow, and input radii propagate outward. Division computes a twofold quotient q and encloses its error from `(A-B*q)/B` using a proven nonzero denominator lower magnitude. Nonnegative radius additions/products and final bounds use outward `nextUp`; nonfinite/overflow/domain failures are typed. Absolute-coordinate pairs are never projected to binary64 intervals before subtraction. `bounds` is used only for final magnitude bounds and denominator nonzero proofs, where its conservative projection does not discard a small coordinate difference.

The arithmetic assumes IEEE binary64 round-to-nearest with gradual underflow and an actual fused `addingProduct`. Focused runtime tests exercise subnormal loss and the exact `.5 + 2^-56` charge-difference counterexample; unsupported arithmetic environments cannot claim this contract from syntax alone.
