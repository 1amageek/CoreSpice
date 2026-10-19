# Compensated Transient State

## Purpose and Scope

This component owns the S4D numerical path retaining sub-ULP unknown increments through the existing Newton and BE/TR transient algorithms. Parent: [CoreSpiceAnalysis](../DESIGN.md). No children. D1 is frozen. S4D.7 owns this kernel implementation and focused evidence; Native adoption and independent model replay remain subsequent work.

## Responsibilities and Boundaries

Analysis owns compensated state updates, immutable accepted references, integration algebra, bounded equation acceptance and resource admission. Devices/compiler own original model evaluation at that state and model-owned charge differences. Native composition owns capability admission and exact model identity. Artifact composition owns serialization; Analysis exposes the complete represented trajectory rather than silently exporting only its rounded projection. This change adds neither a solver nor a new integration method and does not alter row selection or tolerances.

## Related Designs

| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [Analysis](../DESIGN.md) | parent | Newton, BE/TR and execution budget | Numerical orchestration | Legacy Double behavior remains an explicit lane |
| [Numerical state](../../CoreSpiceDevices/NumericalState/DESIGN.md) | depends on | Finite normalized high/low pairs | Preserve sub-ULP corrections and histories | Rounded scalar access does not certify precision |
| [Equation convergence](../EquationConvergence/DESIGN.md) | coordinates with | Original residual correction and per-row absolute tolerances | Same strict physical equation gates | A reconstructed matrix residual is not the final certificate |
| [Transient validation](../TransientValidation/DESIGN.md) | coordinates with | Fresh candidate validation and accepted records | Same trial/commit/finalization sequence | Preserve exact integration context and native accepted history |
| [OSDI model precision](../../../../swift-osdi/Sources/OSDIContracts/ModelEvaluation/DESIGN.md#s4d-precision-boundary--d1-proposal) | depends on | Versioned source-faithful enclosed F/DeltaQ response | Model owns nonlinear evaluation and precision semantics | New capability is not implemented by the existing binary64 backend |

## Architecture

```text
Capability-admitted circuit + exact initialization
  -> five paired trial/history vectors
  -> model original F and DeltaQ with sound error enclosures
  -> existing J * delta = -residual solve
  -> normalized pair update, damping and LTE
  -> fresh bounded original-equation check
  -> candidate bounds -> accepted pair/Iq/native commit
  -> full high/low trajectory + exact integration records
```

## Contracts and Invariants

### Current implementation facts and demonstrated gap

`NewtonRaphsonSolver` currently forms `dx += solution` and then interpolates full absolute Double candidates. A correction below the spacing of an absolute thermal coordinate can disappear before the next original-residual evaluation. `TransientAnalysis` rotates current/previous/two-previous Double arrays and keeps full/quarter trial arrays; `TransientStepPhysicalResidualEvaluator` reconstructs accepted history using only those arrays. `SolutionTrace` and `TransientResult` retain only the rounded vector.

The exact IMG thermal case reaches a state near 0.418 K and an accepted interval approximately 5.73e-17 s. With source-derived thermal capacity approximately 1e-11 W*s/K, even an exact affine charge difference evaluated on absolute binary64 temperatures has a derivative grid approximately 9.70e-12 W; the original thermal equation tolerance is 1e-12 W. Rounded total charge has a still coarser grid. The observed prerequisite state LTE concerns drain/source coordinates, so excluding thermal or those electrical coordinates does not resolve the contract. The retained diagnostic evidence establishes this precision feasibility gap, not a theorem that every particular rejected trial lacks a satisfying lattice point.

### Original-model response assumption

A precision-requested operation supplies current and accepted normalized high/low arrays, exact per-endpoint time/mode, and the same accepted native-state identity to a versioned model capability. Four equally dimensioned coordinate arrays are required at the model boundary. Initialization supplies exact zero lows; no accepted derivative history is invented for UIC.

The model returns signed original static residual `F`, original reactive difference `DeltaQ = Q(candidate) - Q(accepted)`, and finite Jacobian contributions at the represented candidate, together with sound absolute error enclosures. The enclosure concerns the original model expressions, including coordinate lows, time, branches, cached values and native state. Two rounded total-Q evaluations, a sampled constant Jacobian, or unbounded `F(high)+G*low` do not meet this assumption. No model-specific law is reproduced in Analysis. Unsupported model evaluation or an enclosure too wide for the requested precision is a typed capability/precision failure, never a successful rounded fallback.

The compiler/runtime child must establish its linked capability before D1 freezes. The v1 proposal requires `stateCount == 0`; a precision-requested stateful model is explicitly unsupported while ordinary S4 stateful behavior remains unchanged. The proposed Jacobian profile uses finite interval midpoints of the original derivative SSA at the compensated candidate, declared as an inexact Newton matrix. This preserves the same model/context as the certified residual; the fresh residual gate remains authoritative. Existing binary64-only model capability does not satisfy this assumption.

### Integration and bounded acceptance

For BE, `Iq = DeltaQ/h`. For TR, `Iq = 2*DeltaQ/h - acceptedIq`. The signed residual is the sum of all admitted static and reactive contributions. The model error enclosures, division/scaling error, contributor accumulation error and accepted-Iq enclosure propagate outward into a residual center/radius per row. The strict acceptance rule is `abs(center) + radius <= original equation absolute tolerance`. Electrical gmin is included only on existing eligible rows during regularized solves; final physical validation uses the original circuit equations.

An enclosure spanning the tolerance boundary is not a successful residual. The existing Newton/work ceilings bound further correction/evaluation; capability/precision errors remain terminal. Repeated shrink is reserved for genuine recoverable convergence/LTE failures, since smaller h can amplify an irreducible charge enclosure. The matrix solve may use finite binary64 inexact Jacobians/corrections; it cannot replace the fresh original-equation enclosure gate. No interval, global trajectory, or all-output temporal error guarantee is inferred from this per-point gate.

### Newton update and LTE

The precision lane keeps the linear solve result as a correction. It never first forms a rounded absolute candidate to recover that correction by subtraction. Apply damping to the correction with a product-error residual, add it to the current expansion, and renormalize. Adaptive damping and convergence use represented update differences, including lows. A legacy voltage limiter that rewrites only absolute high values cannot discard a low component: precision admission requires an explicit compatible limiter or refuses that device. Existing S4 RLCVI/OSDI composition does not require inventing a limiter.

Bootstrap quarter/half/full, same-interval BE/TR recovery, ordinary BE/TR and LTE variable selection retain their existing algorithms. Their linear combinations and differences operate on expansions; only the final normalized heuristic indicator is rounded, with arithmetic error accounted conservatively. Both absolute/relative scaling and all row physical gates retain the existing units and thresholds.

## Runtime Flows

```text
accepted pair + accepted Iq enclosure + accepted model state
  -> immutable reference for every independent trial
  -> quarter/half/TR/full paired candidate (existing order)
  -> LTE and fresh model bounds/original equations
  -> reject: discard candidates; keep all accepted references unchanged
  -> accept: commit pair, Iq enclosure and native state for same candidate
```

A retry resets both candidate components from the accepted pair. BE/TR bootstrap never advances accepted history between reference trials. The existing original errors, cancellation checks and end-session-before-finalization ordering remain in force. Accepted temperature lows must survive a subsequent step even when the saved high component does not change.

## State, Ownership, and Lifecycle

| Storage | Owner | Precision state | Advance point |
|---|---|---|---|
| Current/previous/two-previous | Transient run | Three high/low pairs | Accepted rotation |
| Newton full and quarter/reference trial | Transient run | Two high/low pairs | Trial mutation only |
| Newton prior iterate/correction/scratch | One solve | Preallocated paired update scratch where required | Iteration only |
| Accepted reactive current | Device/session | Center plus certified radius | Accepted commit |
| Saved trajectory | Result/storage lease | Matching high and low SolutionTrace layouts | Admitted append |

Current five run vectors gain exactly five n-scalar low arrays in precision mode. Each Newton solve additionally owns one n-scalar prior-iterate low array and one n-scalar equation-radius array. The existing correction, linear-refinement and compensated-residual scratch arrays are reused; damping products and pair normalization use scalar temporaries. The existing GMIN recovery also needs one n-scalar low guess alongside its high guess, bringing the admitted peak envelope to eight n-scalar arrays beyond the legacy path, excluding separately admitted model/session storage. Checked `8*n*MemoryLayout<Double>.stride` is admitted before allocation. No uncounted per-iteration array/object conversion is permitted. Saved points count both n-scalar coordinate arrays, time and existing integration audit. Optional actual OP retains its own represented state/lease. A result exposes high/low point borrows; existing value access remains a documented rounded projection. The operation's high/low convention and initial state are part of precision/replay identity.

No shared mutable owner is added. Array scratch is exclusively owned by one run/solve. Existing budget and device-session state use the same `Mutex` declarations on Native/WASM/Embedded; callback evaluation and I/O remain outside locks. Native runtime evidence does not qualify foreign model loading on other targets.

## Failure, Concurrency, and Constraints

Before any session or stamp, admission checks complete pair dimensions/map, normalization, model precision capability, all admitted device contributions and compatible limiting. Every radius must be finite and nonnegative. Invalid indices, overflow, nonfinite pairs/responses, invalid enclosures, unsupported precision, cancellation and budget exhaustion propagate as terminal typed errors without candidate publication. A bounded inexact response cannot pass by comparing its center alone. All extra evaluation/normalization/enclosure work and result bytes consume the existing invocation budget; quota values are caller policy and are not guessed from machine capacity.

## Verification and Change Impact

Planned focused fixture: a thermal state near 0.418 K, capacity 1e-11 W*s/K, a known power forcing and h near 5e-17 s produce a true increment smaller than one temperature ULP. Legacy absolute-Double evaluation must expose the strict-residual gap. The compensated state plus model-owned affine DeltaQ fixture must retain a nonzero low, pass the unchanged 1pW original-equation gate, and match independently computed higher-precision BE/TR states and currents. Add a nonlinear static temperature term so a fixture returning only `F(high)+G*low` with a falsely zero enclosure is rejected by the independent oracle; this prevents an affine-only success claim.

A reproducible binary-exact variant uses reference temperature `1/2`, `h=2^-54`, `C=2^-37`, and target increment `2^-56` per step. Its rounded temperature stays at `1/2` while the affine derivative current is `2^-39 W`, above 1pW. A static term `2^77 * (T-1/2)^2` contributes `2^-35 W` at the first target; a source power equal to the sum of these two exact powers of two makes the target an original-equation root. The static derivative at the rounded reference is zero, so an uncertified first-order low correction cannot substitute for evaluating the nonlinear term. These binary identities provide a compact independent oracle before actual model integration.

The same fixture verifies forced damping, quarter/half/full retries, rejected native/Iq history, accepted pair continuation, initial UIC, BE/TR history, fresh candidate bounds, terminal callback/cancellation/budget errors and completion ordering. Include an enclosure whose center passes but radius crosses tolerance, invalid radii/dimensions and a capability refusal. Save/reload must retain exact high/low bits and reproduce subsequent original residuals with the independent reference. Actual IMG thermal and all previously passing four-family schedules remain required integration proof. Lower model capability changes require revalidation of this component; representation/result changes require Native and artifact/replay revalidation before S4D completion.

## S4D C7 API Seam

The following spelling is frozen by D1 and implemented in S4D.7.

| Public boundary | Proposed exact declaration or addition | Consumer |
|---|---|---|
| Original Newton residual | `NonlinearPhysicalResidualEnclosing: Sendable` with `func accumulateResidualEnclosure(state: SolutionState, add: (Int, CompensatedValue, Double) -> Void) throws` | Existing Newton engine; callback arguments are global row, normalized signed center and absolute radius |
| Original transient residual | `TransientPhysicalResidualEnclosing: TransientPhysicalResidualValidating` with `func accumulateResidualEnclosure(state: SolutionState, integration: IntegrationState, add: (Int, CompensatedValue, Double) -> Void) throws` | Per-trial adapter binds immutable accepted high/low histories and precise interval |
| Newton dependency | Trailing `physicalResidualEncloser: (any NonlinearPhysicalResidualEnclosing)? = nil` initializer input/property | Explicit precision selection; legacy evaluator and encloser cannot both select one solve |
| Newton paired solve | Existing inout solve signature plus `initialLowComponents: [Double]` after `initialGuess`, and `solutionLowComponents: inout [Double]` after `solution` | Avoid allocating/reconstructing low arrays at each trial |
| Transient dependency | Trailing `physicalResidualEncloser: (any TransientPhysicalResidualEnclosing)? = nil` initializer input/property | Explicit precision operation, admitted complete-circuit enclosure provider |
| Accepted audit | Trailing `timeStepLowComponent: Double = 0` and `previousTimeStepLowComponent: Double? = nil` initializer inputs/properties on `TransientAcceptedStep` | Exact interval replay |
| Result low storage | Trailing `solutionLowTrace: SolutionTrace? = nil` initializer input/property on `TransientResult` | Matching point/coordinate order; nil denotes legacy zero lows |
| Result pair access | `checkedCompensatedValue(variableIndex:timeIndex:) throws -> CompensatedValue` | Complete represented scalar |
| Result point borrow | `withCompensatedSolution<R>(at: Int, _: (UnsafeBufferPointer<Double>, UnsafeBufferPointer<Double>?) throws -> R) throws -> R` | Native converter/serialization; optional nil is an exact zero low vector |

An enclosing evaluator supplies complete circuit `F+Iq`, not separate model F and DeltaQ. Device/Native composition, which already owns original contributor assembly and reactive history, consumes the model F/DeltaQ response and produces this enclosure. Analysis does not duplicate model mapping, reactive-history storage or compiler semantics. A fresh enclosing callback is the original-equation acceptance authority; the existing optional final validator remains an additional rejection hook and does not replace the enclosure certificate. Callback radii are in each row's existing equation unit. No row may be omitted because its center or radius happens to be zero.

The paired Newton overload requires the encloser and matching finite normalized vectors. The old Double overload remains the ordinary lane; calling it with a precision-selected encloser is an explicit configuration error rather than a silent projection. Precision execution rejects simultaneous legacy residual-evaluator selection. In the precision Transient path, all ordinary/GMIN trial constructors use the paired overload and the per-step enclosing adapter. The existing direct residual evaluator remains unchanged for ordinary operation.

Clock authority is the scheduler-selected binary64 endpoint with zero low. The precise `IntegrationState` interval is its exact expansion difference from the immutable accepted endpoint; audit stores both interval components. Endpoint/context identity is not reconstructed from a rounded coefficient or `time - h`. Final `timePoints.last` therefore remains exactly the configured stop time and the existing strictly increasing high time axis remains valid. The optional low trace is only for solved coordinates, not an alternate time axis.

### Propagation and serialization ownership

| Existing call site | Required C7 propagation |
|---|---|
| Initial DC/UIC solution and session begin | Retain the DC result pair when its device-owned enclosure capability is available; otherwise high plus exact zero low. Ordinary transient explicitly keeps binary64 DC; validate precision admission before sessions |
| `solveTransientTrial` and `tryGminStepping` | Current/previous high and low arrays, paired candidate buffer, exact interval low; recovery guesses preserve both arrays |
| `TransientStepPhysicalResidualEvaluator` sibling enclosing adapter | Reconstruct `SolutionState` without losing current/previous/two-previous lows; keep same integration object |
| Device stamps, bounds, convergence and commit | Receive the same paired `SolutionState`; precise-capability admission prevents rounded-only contribution substitution |
| LTE bootstrap, smooth history and embedded recovery | Read paired arrays and existing mask/tolerance policy |
| Accepted rotation and save | Rotate each high/low buffer together; append both traces after admission; accepted native/Iq commit sees that exact pair |
| `TransientResult` validation/retaining initializer | Validate low trace dimensions/finite normalization against high trace, preserve it and the same storage lease |
| `TransientAnalysis+NativeCircuit` reconstruction | Forward the encloser; validate high/low output rather than dropping the newly selected lane |
| Native result/artifact conversion | Serialize both trace components and both interval components with numerical profile identity; existing rounded waveform remains a projection |

Analysis exposes exact binary64 component values in matching traces; Native/artifact schema owns their durable encoding and version. The precision record must preserve both component bit patterns, including the accepted interval pair, without recomputing lows from rounded waveform values. Reload/refinement must use this precision record and original endpoint contexts. Missing low metadata for a precision-profile record is a typed failure; absent low metadata is valid only for an explicitly ordinary record. The old `onStepAccepted` hook remains its documented rounded output projection; precision serialization consumes the result pair access, not this callback.

### C7 test ownership

`CoreSpiceDevicesTests` owns normalized scalar admission, ground/private identity and `SolutionState` history-low preservation. `CoreSpiceAnalysisTests` owns pair Newton update/damping, rigorous center-plus-radius acceptance, exact endpoint-difference interval, bootstrap/recovery/accepted rotations, low trace/audit retention and numerical resource admission. The binary-exact nonlinear thermal fixture above is the minimal shared behavioral counterexample. OSDI runtime tests own four-span transport and model response validation. Adapter/Native tests own complete contributor enclosure and precision-lane forwarding. Artifact/oracle tests own bit-exact save/reload and independent original-model replay. Production implementation is owned by S4D.7; focused build/runtime evidence remains required.
