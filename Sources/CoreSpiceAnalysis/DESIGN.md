# CoreSpiceAnalysis

## Purpose and Scope

This SwiftPM module owns solver and analysis execution. Parent: [CoreSpice](../../DESIGN.md). This module has no newly introduced child components.

## Responsibilities and Boundaries

Analyses own Newton iteration, timestep acceptance, and the lifetime of explicit transient device sessions. Device implementations own their physics/history.

## Related Designs

| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [CoreSpice](../../DESIGN.md) | parent | Package composition | Owned module boundary | Revalidate direct consumers when contracts change |
| [Devices BSIM3](../CoreSpiceDevices/BSIM3/DESIGN.md) | uses | Throwing stamps and transient session | Native solver composition | All run exits must end acquired sessions |
## Architecture

```mermaid
flowchart LR
    Input[Typed inputs] --> Owner[CoreSpiceAnalysis]
    Owner --> Output[Validated outputs or typed failure]
```

## Contracts and Invariants

### Bound selected-origin identity

PreparedCircuit rejects a bound model whose declarationID differs from the plan's
selected model, even if model names/types match. This closes the concrete same-name
wrong-source substitution counterexample; permitted parameter perturbations still
retain their original model identity. Origin consistency proves binding composition,
not actual analysis execution or qualification.


Bound-device stamps and accepted history commits may throw; all actual callers propagate errors. Newton residual re-stamps obey the same throwing contract. Numerical convergence retries handle AnalysisError only, preserving device failures. Noise admission is checked before execution for devices with an explicit unsupported noise contract.

### MOS perturbation authority

IR dictionary perturbation cannot change an immutable MOS resolution or reuse its
prepared receipt. Generic sensitivity and generic Monte Carlo refuse any circuit
containing a MOS stage with `AnalysisError.requiresFreshMOSResolution` before
solving or sampling. Source-level Monte Carlo belongs to the frontend caller:
each sample opens a new evaluation session and prepares a new executable owner.
This migration changes no solver or finite-difference algorithm. Focused tests
must detect refusal even when the requested perturbation names a non-MOS device,
because generic whole-circuit rebinding would otherwise reprepare the MOS.

## State, Ownership, and Lifecycle

A transient run begins sessions once after its initial solution; a scope defer ends every acquired session on success, throw, cancellation, or partial acquisition failure. One bound BSIM3 owner admits one transient run; rejected concurrent acquisition cannot reset accepted state. Trial stamps never commit history. Accepted steps re-evaluate the accepted bias and commit only its valid kernel token.

## Failure, Concurrency, and Constraints

PreparedCircuit validates physical and auxiliary identities. Sessions remain common Mutex-protected contracts across target compilation; native host CPU is the verified runtime scope. WASM/Embedded and Metal are not qualified by CPU evidence.

## Verification and Change Impact

Actual DC/AC/transient integration tests cover BSIM3 QS/NQS and series nodes, repeated run reset, rejected trial history, concurrent admission, cancellation and failure release. Existing L3 and affected analysis regressions cover the widened throwing boundary.

## Execution backend impact

| Production path | Actual implementation | Changed stamp contract | Evidence owner |
|---|---|---|---|
| CLI electrical analyses | Explicit SparseLUSolver; AC uses ComplexSparseLUSolver | Yes, fallible MNA stamping | BSIM3 integration and affected analysis suites |
| Optoelectrical DAG | OpticalNetworkEvaluator uses CPU emitter/receiver/propagate protocols | Electrical fallback stamps are throwing; optical requirements remain nonthrowing | Affected analysis/optical regressions |
| Metal photonic mesh | PhotonicExecutor.execute takes PhotonicMesh512 and PhotonicComputeBackend; dispatches MZI layers | No BoundDevice, MNA or Newton solver path | Existing Metal execution owner, unchanged by this sprint |

MetalBackend is a ComputeBackend/PhotonicComputeBackend, not a LinearSolver. The
package has no production selector that executes BSIM3 on Metal. CPU BSIM3 evidence
does not qualify GPU execution, and no GPU compact-model capability is advertised.


### Noise ownership and checked failure

NoiseAnalysis consumes fallible NoisyDevice current PSDs after the actual DC
operating point. It validates positive finite frequency and finite nonnegative
PSDs and known nodes before a transfer solve. Coincident source nodes inject
+1 and -1 additively and cancel. A source name/node identity list is fixed by
the first frequency; subsequent identity changes fail rather than misattribute
contributions. Four BSIM sources map through the full series/NQS complex matrix.

CoreSpice integrates sampled output PSD by its existing trapezoidal rule over
exactly [firstFrequency,lastFrequency]. A single frequency has zero bandwidth
and zero integrated RMS; it does not imply an unsampled 0..f band. A validated
NoiseResult is constructed before emitting completed. Device errors and invalid
spectra emit failed and propagate unchanged. The independent oracle supplies
sampled PSDs; its SPICE log-interpolated integral is not the CoreSpice integral.
No new retained state is introduced. Per-device output is bounded by existing
prepared circuit and sampled sweep, and kernel work remains fixed-size.

## Bounded Transient Run Ownership

A transient run owns one Mutex-protected execution budget from initial admission
through DC initialization, DC GMIN/source recovery, transient Newton/GMIN solves,
accepted state publication and terminal events. Solver attempts and Newton
iterations are admitted before their allocations/stamps. Output admission counts
the time scalar and all MNA scalars, including t=0, before reserve/save/publication.
Count/product overflow, budget exhaustion, invalid timestep constraints, nonfinite
LTE and nonprogressing time are typed failures, never nonconvergence retries or
completed partial trajectories. Cancellation remains a cancelled terminal event.
Callbacks and event I/O execute outside the counter lock.

Caller policy specifies accepted steps, solve attempts, Newton iterations, saved
scalars, matrix dimension, breakpoint count and weighted work units. A missing policy fails before execution; callers explicitly supply resource
ceilings. Machine integer capacity is not treated as a practical resource budget. Decoded limits are
validated by the same run admission as constructed values. Statistics include DC
and recovery work and retain the exact accepted time axis. Weighted work is an
operation-count surrogate: each Newton iteration charges n^3 + 2*nnz + 2*devices
+ 8*n; it is not measured FLOPS or a wall-time guarantee.

Matrix dimension bounds the existing SparseLU dense n*n factor storage and sparse
L/U fill (each at most n*n entries), in addition to O(n) work vectors and the
input sparse structure. Checked n*n, n^3 and byte-size products are required before
analysis allocation. This assumes the supplied LinearSolver and custom device
implementations honor their declared size contracts; the verified concrete solver
is the original SparseLUSolver. No new solver or Metal MNA execution is introduced.
Breakpoint scheduling never enlarges the proposed step and uses representable
relative lookahead rather than a fixed absolute time tolerance. If a breakpoint
is between one and two proposed steps away, the final approach is split into two
steps to avoid a rounding-sized history interval while retaining the exact point.

```mermaid
flowchart TD
  Request[Transient config and caller limits] --> Budget[One run execution budget]
  Budget --> DC[DC and recovery Newton solves]
  DC --> Transient[Transient and GMIN Newton solves]
  Budget --> Transient
  Transient --> Accept[Budget admitted accepted state]
  Accept --> Output[Exact time axis and statistics]
  Budget --> Fail[Typed failure or cancellation]
```

Synchronization review: Native/WASM/Embedded all use the same `Mutex<State>`
storage, read/statistics and mutation admission entry points; the budget owns no
shutdown resource. Runtime evidence is native host CPU only. WASM/Embedded are
unverified; native evidence does not qualify those targets or Metal.

| Target | Storage and isolation | Read / mutation entry points | Owner release | Runtime evidence |
|---|---|---|---|---|
| Native | `Mutex<State>` | `statistics` / admission methods | Run exit releases budget | CPU tested |
| WASM | Same shared source | Same shared source | Same run owner | Unverified |
| Embedded | Same shared source | Same shared source | Same run owner | Unverified |

## BSIM4 analysis composition

[BSIM4](../CoreSpiceDevices/BSIM4/DESIGN.md) participates through existing throwing
BoundDevice and transient-session protocols. The unchanged analysis run owns
begin/defer-end and accepted-step commits. Complex AC uses the device's original
frequency response and reserved-q constraint. Noise admission requires caller-owned
noise-capable preparation before OP; correlated composition follows the contract
below. Actual host CPU public DC/AC/transient and noise evidence bounds admission.

## Correlated Output-Referred Noise

[Output-referred device noise](../CoreSpiceDevices/OutputReferredNoise/DESIGN.md)
is accumulated separately from independent current sources. After actual OP and
original complex AC factorization at each frequency, the analysis solves one unit
injection per unique requested node and forms output-minus-reference transfer.
Ground gain is zero; requested private nodes must be compiled in the variable map.
Factorization and solve buffers are reused; no callback runs under a device lock.

Device-returned channels must remain finite, nonnegative and stable by name.
Validation precedes completed; failure/cancellation propagates and does not emit
a successful waveform. Cancellation is checked during added node solves and
before completion. Public integration remains trapezoidal on output V²/Hz,
with zero bandwidth for one frequency; independent oracle spectra are integrated
with that same documented method, not original ngspice Nintegrate.

### Prepared native DC budget composition

[NativeExecution](../CoreSpice/NativeExecution/DESIGN.md) uses the package-scoped
`TransientExecutionBudget` owner with DCAnalysis. This shares pre-operation
solve/Newton/work/saved-scalar admission across the complete `.op` or `.dc` schedule,
including convergence recovery. The underlying numerical algorithm and public
ordinary DC API are unchanged. The owner retains its common `Mutex<State>` storage;
package visibility does not expose direct mutable counter access.

## Native Concrete Operation Budget Transport

Concrete native composition injects one package execution budget into AC, noise,
TF, PZ, sensitivity and AC sensitivity. Embedded DC, its recovery solves and every
sensitivity perturbation retain that same owner. Linear phases admit solve attempts
and the existing dense cubic/stamp/vector work envelope before factorization or
RHS/eigen solves; complex phases charge four real envelopes. Saved real/complex
scalars and derivative outputs are admitted before append/reserve. These checks
preserve numerical algorithms and propagate exhaustion without convergence retry.
Raw lower analysis entry points retain their existing optional budget contract.

Fourier shares the injected owner with its transient analysis, then admits actual
completed-sample harmonic work and saved coefficients before column extraction and
integration. The transient result's statistics describe transient work; the native
run's statistics describe the complete operation. Harmonic arrays reserve their
checked component count once.

All concrete native result headers implement the package-only
`AnalysisResultStorageRetaining` contract. Each header privately retains an opaque
Sendable storage owner attached by native composition. Copying the complete result
retains that owner even after its native run/facts are released; the final result
copy releases the reservation. TF/sensitivity/Fourier typed nested results share
that owner, and DC sweep point results retain it before invoking callbacks.
Numerical fields remain immutable and Analysis does not depend on the source
accounting implementation. Extracting individual Array/Dictionary values, creating
new result headers with public initializers or materializing derived waveforms is
a caller-owned value boundary; those values do not inherit an invocation lease.
Common Mutex storage and admission entry points are identical across target source;
this change qualifies native CPU behavior only.

## Native Result Storage Admission Boundary

Package-only `AnalysisResultStorageAccounting` supplies pre-allocation capacity
admission and scoped postprocessing scratch. Native composition injects the
execution-owned implementation defined in [Native execution](../CoreSpice/NativeExecution/DESIGN.md#incremental-result-capacity-ownership).
Analysis owns buffer growth and reports required capacity before allocation; it
does not interpret native byte policy or source accounting. Transient native
storage starts at one point and grows geometrically before either accepted-step
branch mutates device state or publishes a point. Direct lower Analysis calls
retain their existing estimated-capacity behavior. Fourier transports the same
owner into transient execution, and requests scratch for the completed trace
before allocating final-period pairs. Numerical algorithms, scalar/work counters,
cancellation and terminal event behavior are unchanged.

The injected owner is retained by completed transient/nested result headers.
Capacity refusal propagates as failure, not a numerical retry or partial result.
Tests in CoreSpiceNativeExecutionTests verify admission ordering and lifetime; the
full CoreSpiceAnalysisTests target verifies unchanged numerical behavior.

Result-storage retention exposes its optional opaque owner within the package.
[Waveform conversion](../CoreSpiceWaveform/DESIGN.md) transports that lease without
retaining discarded numerical payload arrays or changing admission policy.

## D2 Source Evaluation Guard

StandardCircuitDeviceBinding checks plan.ir evaluationEnvironment against its
OperatingConditions before binding any instances. Monte Carlo/sensitivity retain
the plan and guard through this same binding entry. Source-free typed plans remain
bindable under explicitly supplied conditions.
