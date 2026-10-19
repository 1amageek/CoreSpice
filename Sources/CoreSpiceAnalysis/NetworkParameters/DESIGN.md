# Fixed-Bias Network Parameters

## Purpose and Scope

This component owns fixed-operating-point multiport Y, real-reference power-wave S,
conditionally defined Z, and pointwise two-port algebraic stability observations.
Parent: [CoreSpiceAnalysis](../DESIGN.md). It has no child components.

## Responsibilities and Boundaries

The existing DC analysis owns operating-point convergence. Bound devices own model
equations and OSDI storage. This component owns small-signal excitation, signed port
observation, matrix conversion and original-equation numerical checks. File codecs
and native source preparation remain outside this component.

## Related Designs

| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [Analysis](../DESIGN.md) | parent | Analysis, DC physical validation, completion | Existing analysis composition | Native CPU evidence does not qualify WASM or Embedded |
| [Sparse execution](../SparseExecution/DESIGN.md) | depends on | Controlled complex sparse factorization | Swift factorization and repeated RHS substitution | Actual fill/work/storage are admitted by the solver |
| [Native execution](../../CoreSpice/NativeExecution/DESIGN.md) | used by | Injected cumulative budget and storage | Source-backed public composition | No second invocation allowance |

## Architecture

```text
Original prepared circuit -> unchanged DC solve -> fixed linearization state
 -> original AC matrix (all stamped RHS discarded), once per frequency
 -> one factorization -> one unit voltage RHS per selected source
 -> inward current = negative source branch current -> Y
 -> normalized Y -> S; invertible Y -> Z
 -> two-port sampled algebraic observations
```

## Contracts and Invariants

Ports name distinct, concrete independent voltage sources with explicit unique
branch ownership. Voltage is positive-terminal minus negative-terminal potential;
current enters the network at that positive terminal. Coincident endpoints and
cycles in selected ideal-source constraints are refused before DC. Unowned legacy
branch numbering is not inferred. Existing DC source values are preserved.

Frequencies are finite, positive and strictly increasing. Reference impedances are
finite positive real values and may differ by port. Matrices are immutable finite
row-major arrays: row is response port, column is excited port. For R=diag(z0),
A=sqrt(R)Ysqrt(R), S=(I+A)^-1(I-A); the factors commute algebraically. Z=Y^-1 is
undefined for a singular Y, while a singular I+A refuses S publication. No NaN or
infinite matrix is a successful result.

Every solve is checked against its original unmodified matrix using a rowwise
componentwise backward residual. The caller supplies the admissible tolerance;
overflow or nonfinite residual arithmetic refuses the result. This is a numerical
backward-error observation, not a forward-error or global-model certificate.

### Original-equation complex refinement

A pivoted complex substitution can retain a small nonzero in an exactly homogeneous
row. A componentwise relative residual can then be one even when normwise error is
small. The unilateral transform `[[1.25,0],[2,1.5]] x = [0,0.5]` exhibits this:
fused substitution retains `x[0]=2^-56` after rounding `x[1]` to binary64 `1/3`.
The source stamp and sparsity pattern are correct; accepting this vector would
violate the original row's backward-residual contract.

Network circuit and port-transform solves therefore reuse their existing complex
LU factors for standard correction `A delta = rhs - A x`, then update `x+delta`
and recheck the unchanged original matrix. The two correction buffers are allocated
once per solve owner and reused across RHS and iterations. Correction attempts,
matrix products, vector work, solver work, cancellation and live storage share the
same caller budget. No new iteration ceiling or tolerance is inferred: the existing
finite solve/work ceilings bound the complete loop. An unchanged represented vector,
nonfinite arithmetic, cancellation or quota failure refuses publication.

Row equilibration was considered, but the counterexample has modest conditioning
and avoiding its particular pivot would not repair a general rounded substitution.
Exact-zero thresholding would alter observations. Same-factor refinement corrects
the original equation defect directly and leaves every publication gate intact.
For the stated dyadic counterexample the first correction has `delta[0]=-2^-56`;
its represented sum is exactly zero and the unchanged residual gate succeeds.
This does not assert convergence for every matrix; uncorrectable systems retain
their explicit residual/resource failure.

Two-port delta, Rollett K, mu and reverse mu are pointwise formulas. Zero divisors
and nonfinite formula arithmetic produce explicit undefined observations. Their
inequality results do not establish internal, pole, broadband, periodic, nonlinear,
or PR20 stability. Formula basis: [Keysight measurement expressions](https://edadownload.software.keysight.com/eedl/ads/2011/pdf/expmeas.pdf)
and [scikit-rf network conversions](https://scikit-rf.readthedocs.io/en/latest/api/network.html).

### Saved-point internal consistency

`NetworkParameterLimits.validate()` is the shared policy admission owner for native
composition, IO and analysis. `NetworkParameterPoint.validatingSaved` re-executes
the same normalized-Y transforms and two-port formulas under caller-owned cumulative
work, cancellation and live-storage admission. It compares S, Z availability/reason,
every matrix component and every stability field by exact binary64 bit pattern.
The producer and validator use the same deterministic CSR order, ordering-disabled
port LU, RHS order and expression order. No new tolerance is introduced for saved
value comparison; replay after an arithmetic change must be versioned by the upper
artifact owner rather than silently accepting approximate values.

The supplied cumulative resource owner or package budget must have exactly the
declared `executionLimits`. A mismatch is rejected before creating a budget or
reserving scratch; one policy cannot silently replace another. Matching owners
retain cumulative usage across saved points and never reset work on replay.

The saved frequency is finite and positive, all port references are supplied,
matrix dimensions match those ports and stored backward residual lies in
`[recomputedTransformResidual, limits.residualTolerance]`. The residual includes
an original circuit solve that this model-free check cannot reproduce: the upper
bound validates the saved observation's allowed class, not its source authenticity.
For N other than two, stability must be absent (not applicable).

This operation establishes network mathematics' internal consistency only. It does
not recreate an operating point, execute devices, authenticate source/equation
authority, or recover actual port endpoints. Native persistence must retain those
endpoints and branch identities from the same compiled IR and bind them to the
source-backed result independently. An imported matrix cannot become execution
evidence through this operation. True singular-Y classification is obtained only
from the same LU refusal; a caller's replacement of finite Z by undefined is rejected.

## Runtime Flows

Validate admission -> reserve owned storage -> run DC -> stamp/factor/solve each
frequency -> validate transforms -> append complete point -> finalize -> publish.
Failure and cancellation propagate; no partial successful sweep is returned.

## State, Ownership, and Lifecycle

One run retains its fixed DC result and reused matrix/RHS/solution buffers.
Completed headers retain the injected result-storage owner. A local Mutex-owned
scratch ledger admits live bytes before allocation; lease destruction refunds them
on success, failure and cancellation. Upstream storage leases share the same scope.
No callback, model operation, or I/O occurs under that ledger lock.

| Target | Storage | Isolation | Mutation / release |
|---|---|---|---|
| Native | Same byte ledger | Mutex | Reserve / lease destruction |
| WASM | Same byte ledger | Mutex | Same entry points; runtime unverified |
| Embedded | Same byte ledger | Mutex | Same entry points; runtime unverified |

## Failure, Concurrency, and Constraints

Explicit limits bound ports, frequencies, retained scalar count, temporary bytes,
matrix dimensions, solve/Newton attempts and weighted work. Integer products are
checked before allocation. The existing cumulative budget is propagated into DC
and sparse work; direct calls create one budget from their required explicit
limits. Sparse allocations retain individual leases. Scratch floors cover owned
vectors, original matrices, port transforms and validation metadata; factor fill
is admitted separately. Arrays use existing owned storage and nonescaping access;
the component introduces no unsafe pointer boundary.

Cancellation is checked before admission, DC, stamps, each RHS, residual rows,
transform work and completion; solver checkpoints also inspect cancellation.
One complex circuit factorization serves all port RHS at each frequency. Dense
port conversion uses the existing Swift sparse solver on a dense CSR pattern;
no external equations, solver or automatic numerical fallback is introduced.

## Verification and Change Impact

[NetworkParametersTests](../../../Tests/CoreSpiceAnalysisTests/NetworkParametersTests.swift)
owns analytic resistor/RC/passive/controlled-source fixtures, nonuniform reference
normalization, orientation, reciprocity, singular/open cases, invalid ports and
frequency plans, nonfinite arithmetic, numerical/resource refusal, cancellation,
and storage refund. Native composition and Touchstone tests own their boundaries.
Saved-point tests alter finite Z, its availability, S, references, metrics and
residual class, and verify exact replay, singular replay and shared work/refund.
Any excitation sign, matrix ordering, source owner or result lifetime change
requires rechecking those direct consumers. Build/runtime evidence is supplied by
the task owner; this document alone is not completion evidence.
