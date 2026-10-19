# DC Equation Convergence

## Purpose and Scope

This component owns explicit global-row DC convergence policy and the final physical-residual validation boundary. Parent: [CoreSpiceAnalysis](../DESIGN.md). No children.

## Responsibilities and Boundaries

The caller supplies one immutable policy row per compiled global unknown. The analysis owns policy admission, Newton update/residual checks and electrical-only gmin selection. Device physics and independent direct physical residual assembly remain in the adapter supplied through `DCPhysicalResidualValidating`.

## Related Designs

| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [Analysis](../DESIGN.md) | parent | Existing DC/Newton/SparseLU composition | Optional explicit convergence profile | Nil policy preserves legacy behavior |
| [Package](../../../DESIGN.md#s3-osdi-dc-integration-contract) | coordinates with | V/A, A/V, K/W and physical result admission | OSDI integration requires caller validator | Native CPU evidence does not qualify other targets |

## Architecture

```text
Compiled global rows + explicit policy
 -> existing Newton update and candidate Ax-rhs check
 -> caller direct physical validator at original source conditions
 -> accepted-state commit -> completed event/result
```

## Contracts and Invariants

| Row kind | Variable unit | Equation unit | Gmin diagonal |
|---|---|---|---|
| Electrical potential | V | A | Eligible |
| Electrical flow | A | V | Never |
| Thermal potential | temperature rise K | W | Never |

Each row requires finite positive variable/equation absolute tolerances. Policy count must equal compiled dimension; variable-map indices must form a complete unique 0..<dimension range. Flow rows map to branch-current variables; potential rows map to node variables. Explicit-profile updates use caller absolute tolerance plus `config.reltol * abs(current)`. Candidate equation and linear-refinement checks use strict caller absolute equation tolerance without RHS-relative inflation. The same policy reaches direct, gmin and source recovery. Nil policy retains every legacy tolerance and diagonal choice.

Final caller validation runs after numerical convergence but before any accepted-state commit or completed event. Its original error propagates and produces a failed terminal event. The OSDI composition must supply this validator; ordinary legacy analyses remain backward compatible.

## State, Ownership, and Lifecycle

Policies contain immutable Sendable values. The optional validator is retained by the DCAnalysis value throughout one run; its implementation owns any synchronized native session. No new shared mutable state, foreign calls, solver, or OSDI dependency is introduced here.

## Failure, Concurrency, and Constraints

Invalid counts, indices or tolerances fail before numerical allocation/stamping. Explicit policy validates finite nonnegative relative tolerance/gmin, positive iteration limit and valid damping. Cancellation is checked before final validation and publication. Native/WASM/Embedded share identical value and protocol declarations; only native host runtime evidence is claimed.

## Verification and Change Impact

[CoreSpiceOSDIAnalysisTests](../../../Tests/CoreSpiceOSDIAnalysisTests) falsifies cross-unit tolerance substitution, flow/thermal gmin contamination, RHS-inflated residual acceptance, invalid policy, singular/nonconvergent/cancelled solves and physical failure publication. Existing DC convergence/refinement suites own nil-profile compatibility. Adapter/native tests own direct physical assembly and required validator injection.

## Original-residual Newton corrections

`NonlinearPhysicalResidualEvaluating.accumulateResidual(state:add:) throws` optionally supplies original signed equations at the current unknown vector. The existing Newton engine then solves `J*delta=-F` directly, refines that correction against the same Jacobian/RHS, forms the full candidate `x+delta`, and retains existing limiting/damping/update/device gates. The regularized system includes `gmin*x` only on policy-eligible electrical rows. Nil evaluator preserves the full-solution matrix/RHS algorithm.

Direct evaluation uses existing residual and scratch vectors for compensated per-row accumulation, checks callback row bounds before indexing and rejects nonfinite terms/sums. Candidate convergence and terminal failure diagnostics use freshly evaluated original residuals with the same absolute row tolerance; `J*x-rhs` cannot certify this path. Each evaluation charges the existing accurate-residual work envelope and checks cancellation before and after callbacks. Evaluation failures propagate without retry or commit.

The demonstrated failure is a transient matrix with a large reactive Jacobian whose reconstructed RHS loses a small physical current. A focused coupled voltage/current fixture has `Jvv=1e12`, `Jvi=Jiv=1`, voltage target 1 and current target 1e-6. Its matrix residual can vanish at the wrong current. Original residual correction must recover the current at the unchanged strict tolerance. Invalid callback rows, nonfinite terms, callback failure and cancellation cannot publish a converged result.
