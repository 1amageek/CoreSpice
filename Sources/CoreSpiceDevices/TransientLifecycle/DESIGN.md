# Transient Device Lifecycle

## Purpose and Scope

The session boundary distinguishes operating-point initialization from explicit initial conditions. A fresh candidate bound can reject a trial without publishing accepted state.

## Responsibilities and Boundaries

This component owns its generic public boundary. Concrete callers own physics, resources and error diagnostics.

## Related Designs

| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [Parent](../DESIGN.md) | parent | Analysis/device composition | Invocation lifecycle | Preserve failure propagation |

## Architecture

```text
caller -> generic boundary -> validated acceptance or original failure
```

## Contracts and Invariants

`TransientPhysicalEquationDecomposing` is an explicit capability for independent
whole-circuit charge balance. Admission calls
`validateTransientPhysicalEquationDecomposition()` before execution. The initial
`accumulateTransientStaticResidual(state:time:add:)` supplies the original
time-dependent static equation F, without a DC-mode substitution. Each trial's
`accumulateTransientPhysicalEquation(state:integration:add:)`
supplies F at the candidate and reactive terms in a scoped typed callback
`(globalRow, TransientPhysicalEquationTerm, value)`. Conservative devices emit
unadjusted alpha*(Qcandidate-Qaccepted) as `.chargeDifference`.
`transientPhysicalEquationForm` explicitly distinguishes conservative charge
from differential capacitance. The latter emits Ccandidate*alpha*DeltaV as
`.differentialIncrement` and, for TR, (Caccepted-Ccandidate)*Daccepted as
`.differentialHistoryCorrection`. Its accepted C and D are the exact coefficients
and derivatives promoted by the device's accepted-step lifecycle; these terms
do not assert charge conservation or Q=C*V. Conservative charge terms exclude
accepted derivative subtraction; differential history appears only through its
explicit correction term. F is never reconstructed from a companion, RHS, or
prior residual. Native composition owns
accepted global F, row summation, BE/TR balance, and dimension-bounded buffers.

`TransientPhysicalEquationEnclosureDecomposing` is a separately admitted precise
capability, with `accumulateTransientStaticResidualEnclosure` and
`accumulateTransientPhysicalEquationEnclosure` using the corresponding argument
labels; its typed trial callback adds a normalized center and absolute radius.
The initial callback remains `(row, CompensatedValue, absoluteRadius)`. There is no
ordinary-to-enclosed default and no unsupported-device zero contribution.
Both interfaces preserve accepted device history and propagate typed failures.
The complete device companion residual remains a separate required check.

TransientInitialization; TransientTrialTimeStepConstraintDevice.maximumTransientTimeStep(state:integration:) throws -> Double?
`TransientPhysicalResidualContributing.accumulateTransientPhysicalResidual(state:integration:add:) throws` contributes original physical residual terms at compiled global rows. The scoped nonescaping callback receives summed signed terms in the equation row's units. It is independent of the stamped Jacobian/RHS, preserves accepted history, and propagates original evaluation failures. Native composition owns complete-circuit summation and unit-aware admission.

All requirements are Sendable. A thrown error prevents successful publication.

## State, Ownership, and Lifecycle

Values are immutable. Caller implementations own mutable state under their existing synchronization. Trial queries never advance accepted history.

## Failure, Concurrency, and Constraints

Nil candidate bound means no bound; a present bound is finite positive seconds. Session initialization is explicit, never inferred from time zero. Invocation limits admit scratch and records before retention.

## Verification and Change Impact

[Transient equation decomposition tests](../../../Tests/CoreSpiceDevicesTests/TransientEquationDecompositionTests.swift)
verify analytic static/charge separation, signed branch charge, paired sub-ULP
differences, and independence from accepted derivative history. Capability changes
require revalidation of the Native whole-circuit composition and its OSDI owner.

[Transient startup tests](../../../Tests/CoreSpiceAnalysisTests/TransientStartupContractTests.swift) and dynamic contract tests verify original failures, accepted history, candidate rejection and finalization ordering. Revalidate parent Analysis and bound session implementers when these contracts change.

## S4D Enclosed Residual Contribution

`TransientPhysicalResidualEnclosureContributing.accumulateTransientPhysicalResidualEnclosure(state:integration:add:) throws` receives the complete paired current/accepted histories and exact interval in the existing views. Its nonescaping callback receives global row, normalized `CompensatedValue` signed center, and finite nonnegative absolute radius in that row's equation unit. It includes the original static and integrated reactive contribution, with arithmetic and model error. Native composition owns complete summation. There is no default precise conformance derived from the old Double callback. Capability, precision and evaluation failures propagate without advancing accepted history.
